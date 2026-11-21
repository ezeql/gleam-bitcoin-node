import gleam/bit_array
import gleam/dict
import gleam/int
import gleam/list
import gleam/string
import gleam_bitcoin_node/codec
import gleam_bitcoin_node/consensus
import gleam_bitcoin_node/hash
import gleam_bitcoin_node/headers
import gleam_bitcoin_node/kernel
import gleam_bitcoin_node/merkle
import gleam_bitcoin_node/pow
import gleam_bitcoin_node/script
import gleam_bitcoin_node/tx
import gleam_bitcoin_node/utxo

@external(erlang, "gleam_bitcoin_node_ffi", "append")
fn append_file(path: String, data: BitArray) -> Nil

const outputs_path = "/tmp/gleam-archive/outputs.seg"

const inputs_path = "/tmp/gleam-archive/inputs.seg"

const witness_path = "/tmp/gleam-archive/witness.seg"

pub type Undo {
  Undo(
    prev: BitArray,
    spent: List(#(String, consensus.Coin)),
    created: List(String),
  )
}

pub type Known {
  Known(raw: BitArray, prev: BitArray, height: Int)
}

pub type Chain {
  Chain(
    height: Int,
    tip: BitArray,
    times: List(Int),
    coins: dict.Dict(String, consensus.Coin),
    undos: List(Undo),
    blocks: dict.Dict(String, Known),
  )
}

const required_bits = 0x207fffff

const max_block_weight = 4_000_000

const bip30_repeat_a =
  "00000000000a4d0a398161ffc163c503763b1f4360639393e0e4c8e300e0caec"

const bip30_repeat_b =
  "00000000000743f190a18c5577a3c2d2a1f610ae9601ac046a38084ccb7cd721"

type View {
  View(
    base: dict.Dict(String, consensus.Coin),
    extra: List(#(String, consensus.Coin)),
    spent: List(String),
  )
}

pub fn new() -> Chain {
  let genesis = headers.regtest_genesis_entry()
  Chain(
    height: 0,
    tip: genesis.hash,
    times: [genesis.time],
    coins: dict.new(),
    undos: [],
    blocks: dict.new(),
  )
}

pub fn tip_hex(chain: Chain) -> String {
  hash.display(chain.tip)
}

pub fn utxo_stats(chain: Chain) -> utxo.Stats {
  utxo.stats(chain.coins)
}

pub fn disconnect_tip(chain: Chain) -> Result(Chain, String) {
  case chain.undos {
    [] -> Error("no-tip")
    [undo, ..rest] -> {
      let coins = delete_keys(chain.coins, undo.created)
      let coins = restore(coins, undo.spent)
      Ok(Chain(
        height: chain.height - 1,
        tip: undo.prev,
        times: drop_last(chain.times),
        coins: coins,
        undos: rest,
        blocks: chain.blocks,
      ))
    }
  }
}

pub fn submit_block(chain: Chain, raw: BitArray) -> Result(Chain, String) {
  case tx.decode_block(raw) {
    Error(reason) -> Error(reason)
    Ok(block) -> route(chain, raw, block)
  }
}

fn route(
  chain: Chain,
  raw: BitArray,
  block: tx.ParsedBlock,
) -> Result(Chain, String) {
  case block.header {
    <<_:32-little, prev:bytes-size(32), _:bits>> ->
      case prev == chain.tip {
        True -> extend(chain, raw, block)
        False -> consider(chain, raw, block, prev)
      }
    _ -> Error("truncated")
  }
}

fn extend(
  chain: Chain,
  raw: BitArray,
  block: tx.ParsedBlock,
) -> Result(Chain, String) {
  case connect(chain, block) {
    Error(reason) -> Error(reason)
    Ok(chain) -> Ok(remember(chain, raw, block))
  }
}

fn consider(
  chain: Chain,
  raw: BitArray,
  block: tx.ParsedBlock,
  prev: BitArray,
) -> Result(Chain, String) {
  let digest = hash.hash256(block.header)
  case on_active(chain, digest) {
    True -> Ok(chain)
    False ->
      case path_from(chain, raw, prev) {
        Error(reason) -> Error(reason)
        Ok(#(ancestor, path)) -> {
          let new_height = height_of(chain, ancestor) + list.length(path)
          let old_height = chain.height
          let old_branch = branch_raws(chain, ancestor)
          case rollback_to(chain, ancestor) {
            Error(reason) -> Error(reason)
            Ok(base) ->
              case connect_all(base, path) {
                Error(reason) -> {
                  let _ = connect_all(base, old_branch)
                  Error(reason)
                }
                Ok(forked) ->
                  case new_height > old_height {
                    True -> Ok(forked)
                    False -> {
                      let assert Ok(back) = rollback_to(forked, ancestor)
                      connect_all(back, old_branch)
                    }
                  }
              }
          }
        }
      }
  }
}

fn connect_all(chain: Chain, raws: List(BitArray)) -> Result(Chain, String) {
  case raws {
    [] -> Ok(chain)
    [raw, ..rest] ->
      case tx.decode_block(raw) {
        Error(reason) -> Error(reason)
        Ok(block) ->
          case extend(chain, raw, block) {
            Error(reason) -> Error(reason)
            Ok(chain) -> connect_all(chain, rest)
          }
      }
  }
}

fn path_from(
  chain: Chain,
  raw: BitArray,
  prev: BitArray,
) -> Result(#(BitArray, List(BitArray)), String) {
  case on_active(chain, prev) {
    True -> Ok(#(prev, [raw]))
    False ->
      case dict.get(chain.blocks, hash.display(prev)) {
        Error(_) -> Error("prev-blk-not-found")
        Ok(known) ->
          case path_from(chain, known.raw, known.prev) {
            Error(reason) -> Error(reason)
            Ok(#(ancestor, older)) -> Ok(#(ancestor, list.append(older, [raw])))
          }
      }
  }
}

fn rollback_to(chain: Chain, ancestor: BitArray) -> Result(Chain, String) {
  case chain.tip == ancestor {
    True -> Ok(chain)
    False ->
      case disconnect_tip(chain) {
        Error(reason) -> Error(reason)
        Ok(chain) -> rollback_to(chain, ancestor)
      }
  }
}

fn branch_raws(chain: Chain, ancestor: BitArray) -> List(BitArray) {
  collect_branch(chain, chain.tip, ancestor, [])
}

fn collect_branch(
  chain: Chain,
  cursor: BitArray,
  ancestor: BitArray,
  acc: List(BitArray),
) -> List(BitArray) {
  case cursor == ancestor {
    True -> acc
    False ->
      case dict.get(chain.blocks, hash.display(cursor)) {
        Error(_) -> acc
        Ok(known) ->
          collect_branch(chain, known.prev, ancestor, [known.raw, ..acc])
      }
  }
}

fn on_active(chain: Chain, hash: BitArray) -> Bool {
  hash == chain.tip || walk_active(chain, chain.tip, hash)
}

fn walk_active(chain: Chain, cursor: BitArray, target: BitArray) -> Bool {
  case cursor == target {
    True -> True
    False ->
      case dict.get(chain.blocks, hash.display(cursor)) {
        Error(_) -> False
        Ok(known) ->
          known.prev == target || walk_active(chain, known.prev, target)
      }
  }
}

fn height_of(chain: Chain, digest: BitArray) -> Int {
  case digest == chain.tip {
    True -> chain.height
    False ->
      case dict.get(chain.blocks, hash.display(digest)) {
        Ok(known) -> known.height
        Error(_) -> 0
      }
  }
}

fn remember(chain: Chain, raw: BitArray, block: tx.ParsedBlock) -> Chain {
  let assert <<
    _:32-little,
    prev:bytes-size(32),
    _:bytes-size(32),
    _:32-little,
    _:32-little,
    _:32-little,
  >> = block.header
  let digest = hash.hash256(block.header)
  Chain(
    ..chain,
    blocks: dict.insert(
      chain.blocks,
      hash.display(digest),
      Known(raw, prev, chain.height),
    ),
  )
}

fn connect(chain: Chain, block: tx.ParsedBlock) -> Result(Chain, String) {
  case block.header {
    <<
      _:32-little,
      prev:bytes-size(32),
      merkle:bytes-size(32),
      time:32-little,
      bits:32-little,
      _:32-little,
    >> ->
      case prev == chain.tip {
        False -> Error("prev-blk-not-found")
        True ->
          case bits == required_bits {
            False -> Error("bad-diffbits")
            True ->
              case pow.check(block.header, bits) {
                Error(reason) -> Error(reason)
                Ok(_) ->
                  check_body(chain, block, merkle, time, chain.height + 1)
              }
          }
      }
    _ -> Error("truncated")
  }
}

fn check_body(
  chain: Chain,
  block: tx.ParsedBlock,
  merkle: BitArray,
  time: Int,
  height: Int,
) -> Result(Chain, String) {
  case merkle_ok(block.txs, merkle) {
    Error(reason) -> Error(reason)
    Ok(_) ->
      case length_ok(block.txs) {
        Error(reason) -> Error(reason)
        Ok(_) ->
          case coinbases_ok(block.txs) {
            Error(reason) -> Error(reason)
            Ok(_) ->
              case txs_ok(block.txs) {
                Error(reason) -> Error(reason)
                Ok(_) ->
                  case consensus.too_many_sigops(legacy_cost(block.txs)) {
                    True -> Error("bad-blk-sigops")
                    False -> contextual(chain, block, time, height)
                  }
              }
          }
      }
  }
}

fn contextual(
  chain: Chain,
  block: tx.ParsedBlock,
  time: Int,
  height: Int,
) -> Result(Chain, String) {
  let cutoff = case height >= 1 {
    True -> median_time(chain.times)
    False -> time
  }
  case list.all(block.txs, fn(tx) { consensus.is_final(tx, height, cutoff) }) {
    False -> Error("bad-txns-nonfinal")
    True ->
      case bip34_ok(block.txs, height) {
        False -> Error("bad-cb-height")
        True ->
          case witness_ok(block.txs) {
            Error(reason) -> Error(reason)
            Ok(_) ->
              case weight(block.txs) > max_block_weight {
                True -> Error("bad-blk-weight")
                False ->
                  case bip30_ok(chain, block) {
                    Error(reason) -> Error(reason)
                    Ok(_) -> spend(chain, block, time, height, cutoff)
                  }
              }
          }
      }
  }
}

fn spend(
  chain: Chain,
  block: tx.ParsedBlock,
  time: Int,
  height: Int,
  prev_mtp: Int,
) -> Result(Chain, String) {
  let view = View(base: chain.coins, extra: [], spent: [])
  case connect_txs(view, block.txs, chain.times, height, prev_mtp, 0, 0, []) {
    Error(reason) -> Error(reason)
    Ok(#(view, fees, _, jobs)) -> {
      let assert [coinbase, ..] = block.txs
      case
        consensus.output_sum(coinbase.outputs) > fees + codec.subsidy(height)
      {
        True -> Error("bad-cb-amount")
        False ->
          case kernel.verify_jobs(jobs, height, hash.hash256(block.header)) {
            Error(_) -> Error("block-script-verify-flag-failed")
            Ok(_) -> {
              let coins = materialize(view)
              let undo =
                Undo(chain.tip, spent_pairs(view), created_keys(view.extra))
              store_block(height, block.txs, undo)
              Ok(Chain(
                height: height,
                tip: hash.hash256(block.header),
                times: list.append(chain.times, [time]),
                coins: coins,
                undos: [undo, ..chain.undos],
                blocks: chain.blocks,
              ))
            }
          }
      }
    }
  }
}

fn connect_txs(
  view: View,
  txs: List(tx.Tx),
  times: List(Int),
  height: Int,
  prev_mtp: Int,
  fees: Int,
  sigops: Int,
  jobs: List(#(BitArray, List(#(BitArray, Int)))),
) -> Result(
  #(View, Int, Int, List(#(BitArray, List(#(BitArray, Int))))),
  String,
) {
  case txs {
    [] -> Ok(#(view, fees, sigops, list.reverse(jobs)))
    [tx, ..rest] -> {
      let coinbase = consensus.is_coinbase(tx)
      case load_inputs(view, tx, coinbase) {
        Error(reason) -> Error(reason)
        Ok(coins) ->
          case tx_fee(tx, coins, height, coinbase) {
            Error(reason) -> Error(reason)
            Ok(fee) -> {
              let fees = fees + fee
              case consensus.money_ok(fees) == False {
                True -> Error("bad-txns-accumulated-fee-outofrange")
                False ->
                  case
                    coinbase
                    || consensus.sequence_ok(
                      tx,
                      coins,
                      height >= 1,
                      height,
                      prev_mtp,
                      fn(at) { median_at(times, at) },
                    )
                  {
                    False -> Error("bad-txns-nonfinal")
                    True -> {
                      let sigops =
                        sigops + consensus.sigop_cost(tx, coins, coinbase)
                      case consensus.too_many_sigops(sigops) {
                        True -> Error("bad-blk-sigops")
                        False ->
                          connect_txs(
                            add_tx(view, tx, height, coinbase),
                            rest,
                            times,
                            height,
                            prev_mtp,
                            fees,
                            sigops,
                            case coinbase {
                              True -> jobs
                              False -> [script_job(tx, coins), ..jobs]
                            },
                          )
                      }
                    }
                  }
              }
            }
          }
      }
    }
  }
}

fn spent_pairs(view: View) -> List(#(String, consensus.Coin)) {
  list.filter_map(view.spent, fn(key) {
    case dict.get(view.base, key) {
      Ok(coin) -> Ok(#(key, coin))
      Error(_) -> Error(Nil)
    }
  })
}

fn created_keys(extra: List(#(String, consensus.Coin))) -> List(String) {
  list.map(extra, fn(pair) {
    let #(key, _) = pair
    key
  })
}

fn delete_keys(
  coins: dict.Dict(String, consensus.Coin),
  keys: List(String),
) -> dict.Dict(String, consensus.Coin) {
  list.fold(keys, coins, fn(acc, key) { dict.delete(acc, key) })
}

fn restore(
  coins: dict.Dict(String, consensus.Coin),
  spent: List(#(String, consensus.Coin)),
) -> dict.Dict(String, consensus.Coin) {
  list.fold(spent, coins, fn(acc, pair) {
    let #(key, coin) = pair
    dict.insert(acc, key, coin)
  })
}

fn drop_last(times: List(Int)) -> List(Int) {
  case list.length(times) {
    0 -> []
    n -> list.take(times, n - 1)
  }
}

fn store_block(height: Int, txs: List(tx.Tx), undo: Undo) -> Nil {
  append_file(outputs_path, output_records(height, undo.created))
  append_file(inputs_path, input_records(height, undo.spent))
  append_file(witness_path, witness_records(height, txs))
}

fn output_records(height: Int, created: List(String)) -> BitArray {
  list.fold(created, <<>>, fn(acc, key) {
    let #(txid, vout) = key_parts(key)
    <<acc:bits, 1, height:32-little, txid:bits, vout:32-little>>
  })
}

fn input_records(
  height: Int,
  spent: List(#(String, consensus.Coin)),
) -> BitArray {
  list.fold(spent, <<>>, fn(acc, pair) {
    let #(key, _) = pair
    let #(txid, vout) = key_parts(key)
    <<acc:bits, 2, height:32-little, txid:bits, vout:32-little>>
  })
}

fn witness_records(height: Int, txs: List(tx.Tx)) -> BitArray {
  list.fold(txs, <<>>, fn(acc, tx) {
    list.fold(tx.inputs, acc, fn(acc, input) {
      case input.witness {
        [] -> acc
        stack -> <<
          acc:bits,
          3,
          height:32-little,
          tx.txid:bits,
          stack_bytes(stack):bits,
        >>
      }
    })
  })
}

fn stack_bytes(stack: List(BitArray)) -> BitArray {
  list.fold(stack, <<list.length(stack)>>, fn(acc, item) {
    <<acc:bits, bit_array.byte_size(item), item:bits>>
  })
}

fn key_parts(key: String) -> #(BitArray, Int) {
  let txid_hex = string.slice(key, 0, 64)
  let assert Ok(vout) = int.parse(string.drop_start(key, 65))
  let assert Ok(txid) = hash.from_display(txid_hex)
  #(txid, vout)
}

fn script_job(
  tx: tx.Tx,
  coins: List(consensus.Coin),
) -> #(BitArray, List(#(BitArray, Int))) {
  #(tx.raw, list.map(coins, fn(coin) { #(coin.script, coin.value) }))
}

fn merkle_ok(txs: List(tx.Tx), merkle: BitArray) -> Result(Nil, String) {
  let #(root, mutated) = merkle.block_root(txs)
  case root == merkle {
    False -> Error("bad-txnmrklroot")
    True ->
      case mutated {
        True -> Error("bad-txns-duplicate")
        False -> Ok(Nil)
      }
  }
}

fn length_ok(txs: List(tx.Tx)) -> Result(Nil, String) {
  let count = list.length(txs)
  case
    count == 0
    || count * 4 > max_block_weight
    || base_size(txs) * 4 > max_block_weight
  {
    True -> Error("bad-blk-length")
    False -> Ok(Nil)
  }
}

fn coinbases_ok(txs: List(tx.Tx)) -> Result(Nil, String) {
  case txs {
    [] -> Error("bad-cb-missing")
    [first, ..rest] ->
      case consensus.is_coinbase(first) {
        False -> Error("bad-cb-missing")
        True ->
          case list.any(rest, consensus.is_coinbase) {
            True -> Error("bad-cb-multiple")
            False -> Ok(Nil)
          }
      }
  }
}

fn txs_ok(txs: List(tx.Tx)) -> Result(Nil, String) {
  case txs {
    [] -> Ok(Nil)
    [tx, ..rest] ->
      case consensus.check_tx(tx) {
        Error(reason) -> Error(reason)
        Ok(_) -> txs_ok(rest)
      }
  }
}

fn bip34_ok(txs: List(tx.Tx), height: Int) -> Bool {
  case height >= 1 {
    False -> True
    True ->
      case txs {
        [coinbase, ..] ->
          case coinbase.inputs {
            [input, ..] -> codec.bip34_ok(height, input.script_sig)
            _ -> False
          }
        _ -> False
      }
  }
}

fn witness_ok(txs: List(tx.Tx)) -> Result(Nil, String) {
  case commitment(txs) {
    Error(_) ->
      case list.any(txs, fn(tx) { tx.has_witness }) {
        True -> Error("unexpected-witness")
        False -> Ok(Nil)
      }
    Ok(script) ->
      case txs {
        [coinbase, ..] ->
          case coinbase.inputs {
            [input, ..] -> nonce_ok(txs, input.witness, script)
            _ -> Error("bad-witness-nonce-size")
          }
        _ -> Error("bad-witness-nonce-size")
      }
  }
}

fn nonce_ok(
  txs: List(tx.Tx),
  witness: List(BitArray),
  script: BitArray,
) -> Result(Nil, String) {
  case witness {
    [nonce] ->
      case bit_array.byte_size(nonce) == 32 {
        False -> Error("bad-witness-nonce-size")
        True -> {
          let expect =
            hash.hash256(<<merkle.witness_root(txs):bits, nonce:bits>>)
          case script {
            <<0x6a, 0x24, 0xaa, 0x21, 0xa9, 0xed, got:bytes-size(32), _:bits>> ->
              case got == expect {
                True -> Ok(Nil)
                False -> Error("bad-witness-merkle-match")
              }
            _ -> Error("bad-witness-merkle-match")
          }
        }
      }
    _ -> Error("bad-witness-nonce-size")
  }
}

fn commitment(txs: List(tx.Tx)) -> Result(BitArray, Nil) {
  case txs {
    [coinbase, ..] -> last_commitment(coinbase.outputs, Error(Nil))
    _ -> Error(Nil)
  }
}

fn last_commitment(
  outputs: List(tx.Output),
  found: Result(BitArray, Nil),
) -> Result(BitArray, Nil) {
  case outputs {
    [] -> found
    [output, ..rest] ->
      case output.script_pubkey {
        <<0x6a, 0x24, 0xaa, 0x21, 0xa9, 0xed, _:bytes-size(32), _:bits>> ->
          last_commitment(rest, Ok(output.script_pubkey))
        _ -> last_commitment(rest, found)
      }
  }
}

fn bip30_ok(chain: Chain, block: tx.ParsedBlock) -> Result(Nil, String) {
  let hash = hash.display(hash.hash256(block.header))
  case hash == bip30_repeat_a || hash == bip30_repeat_b {
    True -> Ok(Nil)
    False ->
      case list.any(block.txs, fn(tx) { tx_overwrites(chain.coins, tx, 0) }) {
        True -> Error("bad-txns-BIP30")
        False -> Ok(Nil)
      }
  }
}

fn tx_overwrites(
  coins: dict.Dict(String, consensus.Coin),
  item: tx.Tx,
  index: Int,
) -> Bool {
  case item.outputs {
    [] -> False
    [_, ..rest] ->
      case dict.get(coins, coin_key(item.txid, index)) {
        Ok(_) -> True
        Error(_) ->
          tx_overwrites(coins, tx.Tx(..item, outputs: rest), index + 1)
      }
  }
}

fn load_inputs(
  view: View,
  tx: tx.Tx,
  coinbase: Bool,
) -> Result(List(consensus.Coin), String) {
  case coinbase {
    True -> Ok([])
    False -> each_input(view, tx.inputs, [])
  }
}

fn each_input(
  view: View,
  inputs: List(tx.Input),
  acc: List(consensus.Coin),
) -> Result(List(consensus.Coin), String) {
  case inputs {
    [] -> Ok(list.reverse(acc))
    [input, ..rest] ->
      case lookup(view, input.prev_hash, input.prev_index) {
        Error(reason) -> Error(reason)
        Ok(coin) -> each_input(view, rest, [coin, ..acc])
      }
  }
}

fn tx_fee(
  tx: tx.Tx,
  coins: List(consensus.Coin),
  height: Int,
  coinbase: Bool,
) -> Result(Int, String) {
  case coinbase {
    True -> Ok(0)
    False -> consensus.fee(tx, coins, height)
  }
}

fn lookup(
  view: View,
  txid: BitArray,
  index: Int,
) -> Result(consensus.Coin, String) {
  let key = coin_key(txid, index)
  case list.contains(view.spent, key) {
    True -> Error("bad-txns-inputs-missingorspent")
    False ->
      case find_extra(view.extra, key) {
        Ok(coin) -> Ok(coin)
        Error(_) ->
          case dict.get(view.base, key) {
            Ok(coin) -> Ok(coin)
            Error(_) -> Error("bad-txns-inputs-missingorspent")
          }
      }
  }
}

fn add_tx(view: View, tx: tx.Tx, height: Int, coinbase: Bool) -> View {
  let view = case coinbase {
    True -> view
    False -> spend_inputs(view, tx.inputs)
  }
  add_outputs(view, tx, height, coinbase, 0)
}

fn spend_inputs(view: View, inputs: List(tx.Input)) -> View {
  case inputs {
    [] -> view
    [input, ..rest] -> {
      let key = coin_key(input.prev_hash, input.prev_index)
      spend_inputs(
        View(..view, extra: drop_extra(view.extra, key), spent: [
          key,
          ..view.spent
        ]),
        rest,
      )
    }
  }
}

fn add_outputs(
  view: View,
  item: tx.Tx,
  height: Int,
  coinbase: Bool,
  index: Int,
) -> View {
  case item.outputs {
    [] -> view
    [output, ..rest] -> {
      let view = case script.unspendable(output.script_pubkey) {
        True -> view
        False ->
          View(..view, extra: [
            #(
              coin_key(item.txid, index),
              consensus.Coin(
                value: output.value,
                script: output.script_pubkey,
                height: height,
                coinbase: coinbase,
              ),
            ),
            ..view.extra
          ])
      }
      add_outputs(
        view,
        tx.Tx(..item, outputs: rest),
        height,
        coinbase,
        index + 1,
      )
    }
  }
}

fn materialize(view: View) -> dict.Dict(String, consensus.Coin) {
  insert_all(delete_all(view.base, view.spent), view.extra)
}

fn delete_all(
  coins: dict.Dict(String, consensus.Coin),
  spent: List(String),
) -> dict.Dict(String, consensus.Coin) {
  case spent {
    [] -> coins
    [key, ..rest] -> delete_all(dict.delete(coins, key), rest)
  }
}

fn insert_all(
  coins: dict.Dict(String, consensus.Coin),
  extra: List(#(String, consensus.Coin)),
) -> dict.Dict(String, consensus.Coin) {
  case extra {
    [] -> coins
    [#(key, coin), ..rest] -> insert_all(dict.insert(coins, key, coin), rest)
  }
}

fn find_extra(
  extra: List(#(String, consensus.Coin)),
  key: String,
) -> Result(consensus.Coin, Nil) {
  case extra {
    [] -> Error(Nil)
    [#(found, coin), ..] if found == key -> Ok(coin)
    [_, ..rest] -> find_extra(rest, key)
  }
}

fn drop_extra(
  extra: List(#(String, consensus.Coin)),
  key: String,
) -> List(#(String, consensus.Coin)) {
  case extra {
    [] -> []
    [#(found, _), ..rest] if found == key -> rest
    [item, ..rest] -> [item, ..drop_extra(rest, key)]
  }
}

fn legacy_cost(txs: List(tx.Tx)) -> Int {
  list.fold(txs, 0, fn(total, tx) { total + consensus.sigop_cost(tx, [], True) })
}

fn weight(txs: List(tx.Tx)) -> Int {
  base_size(txs) * 3 + total_size(txs)
}

fn base_size(txs: List(tx.Tx)) -> Int {
  80
  + compact_len(list.length(txs))
  + list.fold(txs, 0, fn(total, tx) { total + tx.base_size })
}

fn total_size(txs: List(tx.Tx)) -> Int {
  80
  + compact_len(list.length(txs))
  + list.fold(txs, 0, fn(total, tx) { total + bit_array.byte_size(tx.raw) })
}

fn compact_len(n: Int) -> Int {
  case n < 253 {
    True -> 1
    False ->
      case n < 0x10000 {
        True -> 3
        False ->
          case n < 0x100000000 {
            True -> 5
            False -> 9
          }
      }
  }
}

fn median_time(times: List(Int)) -> Int {
  median_at(times, list.length(times) - 1)
}

fn median_at(times: List(Int), height: Int) -> Int {
  let start = int.max(0, height - 10)
  let window = list.take(list.drop(times, start), height - start + 1)
  let sorted = sort(window)
  at(sorted, list.length(sorted) / 2)
}

fn at(values: List(Int), index: Int) -> Int {
  case values {
    [] -> 0
    [value, ..rest] ->
      case index {
        0 -> value
        _ -> at(rest, index - 1)
      }
  }
}

fn sort(values: List(Int)) -> List(Int) {
  case values {
    [] -> []
    [value, ..rest] -> insert(value, sort(rest))
  }
}

fn insert(value: Int, rest: List(Int)) -> List(Int) {
  case rest {
    [] -> [value]
    [head, ..tail] ->
      case value <= head {
        True -> [value, ..rest]
        False -> [head, ..insert(value, tail)]
      }
  }
}

fn coin_key(txid: BitArray, index: Int) -> String {
  hash.display(txid) <> ":" <> int.to_string(index)
}
