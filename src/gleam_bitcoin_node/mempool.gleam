import gleam/bit_array
import gleam/dict
import gleam/int
import gleam/list
import gleam_bitcoin_node/chain
import gleam_bitcoin_node/consensus
import gleam_bitcoin_node/hash
import gleam_bitcoin_node/kernel
import gleam_bitcoin_node/script
import gleam_bitcoin_node/tx

const min_relay = 100

const incremental_relay = 100

const max_standard_weight = 400_000

const min_standard_size = 65

const max_scriptsig = 1650

const max_standard_sigops = 16_000

const max_package_count = 25

const max_package_weight = 404_000

type Entry {
  Entry(tx: tx.Tx, fee: Int, vsize: Int)
}

pub opaque type Pool {
  Pool(
    entries: dict.Dict(String, Entry),
    spent: dict.Dict(String, String),
    relay: List(String),
  )
}

pub type Verdict {
  Verdict(txid: String, allowed: Bool, reason: String)
}

pub fn new() -> Pool {
  Pool(entries: dict.new(), spent: dict.new(), relay: [])
}

pub fn relay_inv(pool: Pool) -> List(String) {
  pool.relay
}

pub fn well_formed(txs: List(tx.Tx)) -> Result(Nil, String) {
  let weight = list.fold(txs, 0, fn(sum, item) { sum + tx.weight(item) })
  case list.length(txs) > max_package_count {
    True -> Error("package-too-many-transactions")
    False ->
      case list.length(txs) > 1 && weight > max_package_weight {
        True -> Error("package-too-large")
        False ->
          case unique_ids(txs, []) {
            Error(reason) -> Error(reason)
            Ok(_) ->
              case topo_sorted(txs, ids(txs)) {
                False -> Error("package-not-sorted")
                True ->
                  case consistent(txs, []) {
                    False -> Error("conflict-in-package")
                    True -> Ok(Nil)
                  }
              }
          }
      }
  }
}

pub fn test_package(
  chain: chain.Chain,
  pool: Pool,
  raws: List(BitArray),
) -> Result(List(Verdict), String) {
  case raws {
    [] -> Error("package-empty")
    _ ->
      case decode_all(raws) {
        Error(reason) -> Error(reason)
        Ok(txs) ->
          case well_formed(txs) {
            Error(reason) -> Error(reason)
            Ok(_) -> Ok(walk(chain, pool, txs, dict.new(), [], [], [], False))
          }
      }
  }
}

pub fn send_raw(
  chain: chain.Chain,
  pool: Pool,
  raw: BitArray,
) -> Result(#(Pool, String), String) {
  case decode_one(raw) {
    Error(reason) -> Error(reason)
    Ok(item) ->
      case assess(chain, pool, dict.new(), item, True) {
        Error(reason) -> Error(reason)
        Ok(#(entry, evict)) ->
          case fee_reason(entry) {
            Error(reason) -> Error(reason)
            Ok(_) ->
              case replacement_ok(pool, entry, evict) {
                Error(reason) -> Error(reason)
                Ok(_) -> Ok(commit(pool, entry, evict))
              }
          }
      }
  }
}

fn walk(
  chain: chain.Chain,
  pool: Pool,
  txs: List(tx.Tx),
  extra: dict.Dict(String, consensus.Coin),
  acc: List(Verdict),
  staged: List(Entry),
  lows: List(Entry),
  hard: Bool,
) -> List(Verdict) {
  case txs {
    [] -> rescue(list.reverse(acc), list.reverse(staged), lows, hard)
    [item, ..rest] ->
      case assess(chain, pool, extra, item, False) {
        Error(reason) ->
          walk(
            chain,
            pool,
            rest,
            extra,
            [reject(item, reason), ..acc],
            staged,
            lows,
            True,
          )
        Ok(#(entry, _)) ->
          case fee_reason(entry) {
            Error(reason) ->
              walk(
                chain,
                pool,
                rest,
                stage(extra, entry, chain.height + 1),
                [reject(item, reason), ..acc],
                [entry, ..staged],
                [entry, ..lows],
                hard,
              )
            Ok(_) ->
              walk(
                chain,
                pool,
                rest,
                stage(extra, entry, chain.height + 1),
                [Verdict(txid_of(item), True, ""), ..acc],
                [entry, ..staged],
                lows,
                hard,
              )
          }
      }
  }
}

fn rescue(
  verdicts: List(Verdict),
  staged: List(Entry),
  lows: List(Entry),
  hard: Bool,
) -> List(Verdict) {
  let package_ok =
    hard == False
    && lows != []
    && child_with_parents(list.map(staged, fn(entry) { entry.tx }))
    && package_fee_ok(staged)
  case package_ok {
    False -> verdicts
    True ->
      list.map(verdicts, fn(verdict) {
        case verdict.reason == "min relay fee not met" {
          True -> Verdict(verdict.txid, True, "")
          False -> verdict
        }
      })
  }
}

fn child_with_parents(txs: List(tx.Tx)) -> Bool {
  case list.length(txs) < 2 {
    True -> False
    False -> {
      let assert Ok(child) = list.last(txs)
      list.all(list.take(txs, list.length(txs) - 1), fn(parent) {
        list.any(child.inputs, fn(input) { input.prev_hash == parent.txid })
      })
    }
  }
}

fn package_fee_ok(entries: List(Entry)) -> Bool {
  let #(fee, size) =
    list.fold(entries, #(0, 0), fn(acc, entry) {
      let #(fee, size) = acc
      #(fee + entry.fee, size + entry.vsize)
    })
  fee >= fee_for(min_relay, size)
}

fn assess(
  chain: chain.Chain,
  pool: Pool,
  extra: dict.Dict(String, consensus.Coin),
  item: tx.Tx,
  allow_replacement: Bool,
) -> Result(#(Entry, List(String)), String) {
  case consensus.is_coinbase(item) {
    True -> Error("coinbase")
    False ->
      case consensus.check_tx(item) {
        Error(reason) -> Error(reason)
        Ok(_) ->
          case standard(item) {
            Error(reason) -> Error(reason)
            Ok(_) ->
              case known(pool, item) {
                Error(reason) -> Error(reason)
                Ok(_) -> {
                  let ids = conflict_ids(pool, item)
                  case ids != [] && allow_replacement == False {
                    True -> Error("txn-mempool-conflict")
                    False -> {
                      let evict = case allow_replacement {
                        True -> with_descendants(pool, ids, [])
                        False -> []
                      }
                      case
                        inputs_of(
                          chain,
                          pool,
                          extra,
                          item,
                          evict,
                          chain.height + 1,
                        )
                      {
                        Error(reason) -> Error(reason)
                        Ok(coins) -> checked(chain, item, coins, evict)
                      }
                    }
                  }
                }
              }
          }
      }
  }
}

fn checked(
  chain: chain.Chain,
  item: tx.Tx,
  coins: List(consensus.Coin),
  evict: List(String),
) -> Result(#(Entry, List(String)), String) {
  let next = chain.height + 1
  let mtp = median_time(chain.times)
  case consensus.is_final(item, next, mtp) {
    False -> Error("non-final")
    True ->
      case consensus.sequence_ok(item, coins, True, next, mtp, fn(_) { mtp }) {
        False -> Error("non-BIP68-final")
        True ->
          case consensus.sigop_cost(item, coins, False) > max_standard_sigops {
            True -> Error("bad-txns-too-many-sigops")
            False ->
              case consensus.fee(item, coins, next) {
                Error(reason) -> Error(reason)
                Ok(fee) ->
                  case
                    kernel.verify_tx(
                      item.raw,
                      list.map(coins, fn(coin) { #(coin.script, coin.value) }),
                      kernel.block_flags(next),
                    )
                  {
                    Ok(True) -> Ok(#(Entry(item, fee, vsize(item)), evict))
                    _ -> Error("mempool-script-verify-flag-failed")
                  }
              }
          }
      }
  }
}

fn replacement_ok(
  pool: Pool,
  entry: Entry,
  evict: List(String),
) -> Result(Nil, String) {
  case evict {
    [] -> Ok(Nil)
    _ -> {
      let old = replaced_fee(pool, evict)
      case entry.fee < old {
        True -> Error("insufficient fee")
        False ->
          case entry.fee - old < fee_for(incremental_relay, entry.vsize) {
            True -> Error("insufficient fee")
            False ->
              case improves(pool, entry, evict) {
                True -> Ok(Nil)
                False -> Error("replacement-failed")
              }
          }
      }
    }
  }
}

fn improves(pool: Pool, entry: Entry, evict: List(String)) -> Bool {
  list.all(evict, fn(id) {
    case dict.get(pool.entries, id) {
      Error(_) -> True
      Ok(old) -> entry.fee * old.vsize > old.fee * entry.vsize
    }
  })
}

fn replaced_fee(pool: Pool, ids: List(String)) -> Int {
  list.fold(ids, 0, fn(sum, id) {
    case dict.get(pool.entries, id) {
      Ok(entry) -> sum + entry.fee
      Error(_) -> sum
    }
  })
}

fn fee_reason(entry: Entry) -> Result(Nil, String) {
  case entry.fee < fee_for(min_relay, entry.vsize) {
    True -> Error("min relay fee not met")
    False -> Ok(Nil)
  }
}

fn fee_for(rate: Int, vbytes: Int) -> Int {
  case vbytes {
    0 -> 0
    _ -> { rate * vbytes + 999 } / 1000
  }
}

fn vsize(item: tx.Tx) -> Int {
  { tx.weight(item) + 3 } / 4
}

fn commit(pool: Pool, entry: Entry, evict: List(String)) -> #(Pool, String) {
  let pool = list.fold(evict, pool, drop_id)
  let id = txid_of(entry.tx)
  let spent =
    list.fold(entry.tx.inputs, pool.spent, fn(spent, input) {
      dict.insert(spent, coin_key(input.prev_hash, input.prev_index), id)
    })
  #(
    Pool(entries: dict.insert(pool.entries, id, entry), spent: spent, relay: [
      id,
      ..list.filter(pool.relay, fn(item) { item != id })
    ]),
    id,
  )
}

fn drop_id(pool: Pool, id: String) -> Pool {
  let spent =
    list.fold(dict.to_list(pool.spent), pool.spent, fn(spent, pair) {
      let #(key, spender) = pair
      case spender == id {
        True -> dict.delete(spent, key)
        False -> spent
      }
    })
  Pool(
    entries: dict.delete(pool.entries, id),
    spent: spent,
    relay: list.filter(pool.relay, fn(item) { item != id }),
  )
}

fn stage(
  extra: dict.Dict(String, consensus.Coin),
  entry: Entry,
  height: Int,
) -> dict.Dict(String, consensus.Coin) {
  add_outputs(extra, entry.tx, height, 0)
}

fn add_outputs(
  extra: dict.Dict(String, consensus.Coin),
  item: tx.Tx,
  height: Int,
  index: Int,
) -> dict.Dict(String, consensus.Coin) {
  case item.outputs {
    [] -> extra
    [output, ..rest] -> {
      let extra = case script.unspendable(output.script_pubkey) {
        True -> extra
        False ->
          dict.insert(
            extra,
            coin_key(item.txid, index),
            consensus.Coin(
              value: output.value,
              script: output.script_pubkey,
              height: height,
              coinbase: False,
            ),
          )
      }
      add_outputs(extra, tx.Tx(..item, outputs: rest), height, index + 1)
    }
  }
}

fn inputs_of(
  chain: chain.Chain,
  pool: Pool,
  extra: dict.Dict(String, consensus.Coin),
  item: tx.Tx,
  ignore: List(String),
  height: Int,
) -> Result(List(consensus.Coin), String) {
  each_input(chain, pool, extra, item.inputs, ignore, height, [])
}

fn each_input(
  chain: chain.Chain,
  pool: Pool,
  extra: dict.Dict(String, consensus.Coin),
  inputs: List(tx.Input),
  ignore: List(String),
  height: Int,
  acc: List(consensus.Coin),
) -> Result(List(consensus.Coin), String) {
  case inputs {
    [] -> Ok(list.reverse(acc))
    [input, ..rest] ->
      case resolve(chain, pool, extra, input, ignore, height) {
        Error(reason) -> Error(reason)
        Ok(coin) ->
          each_input(chain, pool, extra, rest, ignore, height, [coin, ..acc])
      }
  }
}

fn resolve(
  chain: chain.Chain,
  pool: Pool,
  extra: dict.Dict(String, consensus.Coin),
  input: tx.Input,
  ignore: List(String),
  height: Int,
) -> Result(consensus.Coin, String) {
  let key = coin_key(input.prev_hash, input.prev_index)
  case dict.get(extra, key) {
    Ok(coin) -> Ok(coin)
    Error(_) ->
      case dict.get(pool.spent, key) {
        Ok(spender) ->
          case list.contains(ignore, spender) {
            False -> Error("txn-mempool-conflict")
            True ->
              from_set(chain, pool, input.prev_hash, input.prev_index, height)
          }
        Error(_) ->
          from_set(chain, pool, input.prev_hash, input.prev_index, height)
      }
  }
}

fn from_set(
  chain: chain.Chain,
  pool: Pool,
  txid: BitArray,
  index: Int,
  height: Int,
) -> Result(consensus.Coin, String) {
  case dict.get(chain.coins, coin_key(txid, index)) {
    Ok(coin) -> Ok(coin)
    Error(_) ->
      case dict.get(pool.entries, hash.display(txid)) {
        Error(_) -> Error("bad-txns-inputs-missingorspent")
        Ok(entry) -> nth_output(entry.tx, index, height)
      }
  }
}

fn nth_output(
  item: tx.Tx,
  index: Int,
  height: Int,
) -> Result(consensus.Coin, String) {
  case list.drop(item.outputs, index) {
    [output, ..] ->
      case script.unspendable(output.script_pubkey) {
        True -> Error("bad-txns-inputs-missingorspent")
        False ->
          Ok(consensus.Coin(
            value: output.value,
            script: output.script_pubkey,
            height: height,
            coinbase: False,
          ))
      }
    _ -> Error("bad-txns-inputs-missingorspent")
  }
}

fn known(pool: Pool, item: tx.Tx) -> Result(Nil, String) {
  case dict.get(pool.entries, txid_of(item)) {
    Error(_) -> Ok(Nil)
    Ok(entry) ->
      case entry.tx.wtxid == item.wtxid {
        True -> Error("txn-already-in-mempool")
        False -> Error("txn-same-nonwitness-data-in-mempool")
      }
  }
}

fn conflict_ids(pool: Pool, item: tx.Tx) -> List(String) {
  list.fold(item.inputs, [], fn(acc, input) {
    case dict.get(pool.spent, coin_key(input.prev_hash, input.prev_index)) {
      Error(_) -> acc
      Ok(id) ->
        case list.contains(acc, id) {
          True -> acc
          False -> [id, ..acc]
        }
    }
  })
}

fn with_descendants(
  pool: Pool,
  ids: List(String),
  seen: List(String),
) -> List(String) {
  case ids {
    [] -> seen
    [id, ..rest] ->
      case list.contains(seen, id) {
        True -> with_descendants(pool, rest, seen)
        False -> {
          let kids = case dict.get(pool.entries, id) {
            Error(_) -> []
            Ok(entry) -> children(pool, entry.tx.txid)
          }
          with_descendants(pool, list.append(rest, kids), [id, ..seen])
        }
      }
  }
}

fn children(pool: Pool, txid: BitArray) -> List(String) {
  list.filter_map(dict.to_list(pool.entries), fn(pair) {
    let #(id, entry) = pair
    case list.any(entry.tx.inputs, fn(input) { input.prev_hash == txid }) {
      True -> Ok(id)
      False -> Error(Nil)
    }
  })
}

fn standard(item: tx.Tx) -> Result(Nil, String) {
  case item.version >= 1 && item.version <= 3 {
    False -> Error("version")
    True ->
      case tx.weight(item) > max_standard_weight {
        True -> Error("tx-size")
        False ->
          case item.base_size < min_standard_size {
            True -> Error("tx-size-small")
            False -> scriptsigs(item.inputs)
          }
      }
  }
}

fn scriptsigs(inputs: List(tx.Input)) -> Result(Nil, String) {
  case inputs {
    [] -> Ok(Nil)
    [input, ..rest] ->
      case bit_array.byte_size(input.script_sig) > max_scriptsig {
        True -> Error("scriptsig-size")
        False -> scriptsigs(rest)
      }
  }
}

fn unique_ids(txs: List(tx.Tx), seen: List(BitArray)) -> Result(Nil, String) {
  case txs {
    [] -> Ok(Nil)
    [item, ..rest] ->
      case list.contains(seen, item.txid) {
        True -> Error("package-contains-duplicates")
        False -> unique_ids(rest, [item.txid, ..seen])
      }
  }
}

fn ids(txs: List(tx.Tx)) -> List(BitArray) {
  list.map(txs, fn(item) { item.txid })
}

fn topo_sorted(txs: List(tx.Tx), later: List(BitArray)) -> Bool {
  case txs {
    [] -> True
    [item, ..rest] -> {
      let later = list.filter(later, fn(id) { id != item.txid })
      case
        list.any(item.inputs, fn(input) {
          list.contains(later, input.prev_hash)
        })
      {
        True -> False
        False -> topo_sorted(rest, later)
      }
    }
  }
}

fn consistent(txs: List(tx.Tx), seen: List(String)) -> Bool {
  case txs {
    [] -> True
    [item, ..rest] ->
      case item.inputs {
        [] -> False
        _ ->
          case add_outpoints(item.inputs, seen) {
            Error(_) -> False
            Ok(seen) -> consistent(rest, seen)
          }
      }
  }
}

fn add_outpoints(
  inputs: List(tx.Input),
  seen: List(String),
) -> Result(List(String), Nil) {
  case inputs {
    [] -> Ok(seen)
    [input, ..rest] -> {
      let key = coin_key(input.prev_hash, input.prev_index)
      case list.contains(seen, key) {
        True -> Error(Nil)
        False -> add_outpoints(rest, [key, ..seen])
      }
    }
  }
}

fn decode_all(raws: List(BitArray)) -> Result(List(tx.Tx), String) {
  case raws {
    [] -> Ok([])
    [raw, ..rest] ->
      case decode_one(raw) {
        Error(reason) -> Error(reason)
        Ok(item) ->
          case decode_all(rest) {
            Error(reason) -> Error(reason)
            Ok(more) -> Ok([item, ..more])
          }
      }
  }
}

fn decode_one(raw: BitArray) -> Result(tx.Tx, String) {
  case tx.decode(raw) {
    Error(reason) -> Error(reason)
    Ok(#(item, left)) ->
      case bit_array.byte_size(left) {
        0 -> Ok(item)
        _ -> Error("trailing-bytes")
      }
  }
}

fn reject(item: tx.Tx, reason: String) -> Verdict {
  Verdict(txid_of(item), False, reason)
}

fn txid_of(item: tx.Tx) -> String {
  hash.display(item.txid)
}

fn coin_key(txid: BitArray, index: Int) -> String {
  hash.display(txid) <> ":" <> int.to_string(index)
}

fn median_time(times: List(Int)) -> Int {
  let height = list.length(times) - 1
  let start = int.max(0, height - 10)
  let window = list.take(list.drop(times, start), height - start + 1)
  let sorted = sort_ints(window)
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

fn sort_ints(values: List(Int)) -> List(Int) {
  case values {
    [] -> []
    [value, ..rest] -> insert_int(value, sort_ints(rest))
  }
}

fn insert_int(value: Int, rest: List(Int)) -> List(Int) {
  case rest {
    [] -> [value]
    [head, ..tail] ->
      case value <= head {
        True -> [value, ..rest]
        False -> [head, ..insert_int(value, tail)]
      }
  }
}
