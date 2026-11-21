import gleam/bit_array
import gleam/dict
import gleam/int
import gleam/list
import gleam/string
import gleam_bitcoin_node/chain
import gleam_bitcoin_node/consensus
import gleam_bitcoin_node/hash
import gleam_bitcoin_node/index
import gleam_bitcoin_node/json
import gleam_bitcoin_node/mempool
import gleam_bitcoin_node/params
import gleam_bitcoin_node/tx
import gleam_bitcoin_node/utxo

@external(erlang, "gleam_bitcoin_node_rpc", "start")
pub fn start(port: Int) -> Result(Nil, String)

@external(erlang, "gleam_bitcoin_node_rpc", "publish")
pub fn publish(view: index.View) -> Nil

pub fn handle(view: index.View, body: String) -> #(String, index.View) {
  case json.decode(body) {
    Error(_) -> #(
      envelope(json.Null, error_obj(-32_700, "Parse error"), json.Null),
      view,
    )
    Ok(request) -> {
      let id = case json.field(request, "id") {
        Ok(value) -> value
        Error(_) -> json.Null
      }
      case json.field(request, "method") {
        Ok(json.String(method)) -> {
          let #(result, view) = dispatch(view, method, params_of(request))
          case result {
            Error(message) -> #(
              envelope(json.Null, error_obj(-1, message), id),
              view,
            )
            Ok(value) -> #(envelope(value, json.Null, id), view)
          }
        }
        _ -> #(
          envelope(json.Null, error_obj(-32_600, "Invalid Request"), id),
          view,
        )
      }
    }
  }
}

fn dispatch(
  view: index.View,
  method: String,
  params: List(json.Value),
) -> #(Result(json.Value, String), index.View) {
  case method {
    "getblockchaininfo" -> #(Ok(blockchain_info(view)), view)
    "getblockhash" -> #(block_hash(view, params), view)
    "getblock" -> #(block(view, params), view)
    "gettxout" -> #(txout(view, params), view)
    "getrawtransaction" -> #(raw_tx(view, params), view)
    "gettxoutsetinfo" -> #(Ok(txout_set(view)), view)
    "submitblock" -> submit(view, params)
    _ -> #(Error("Method not found"), view)
  }
}

fn blockchain_info(view: index.View) -> json.Value {
  let chain = view.chain
  json.Object([
    #("chain", json.String("regtest")),
    #("blocks", json.Int(chain.height)),
    #("headers", json.Int(chain.height)),
    #("bestblockhash", json.String(chain.tip_hex(chain))),
    #("bits", json.String(hex8(tip_bits(chain)))),
    #("difficulty", json.Int(1)),
    #("time", json.Int(tip_time(chain.times))),
    #("mediantime", json.Int(median_time(chain.times))),
    #("pruned", json.Bool(False)),
  ])
}

fn block_hash(
  view: index.View,
  params: List(json.Value),
) -> Result(json.Value, String) {
  case arg_int(params, 0) {
    Error(_) -> Error("Block height out of range")
    Ok(height) ->
      case height == 0 {
        True -> Ok(json.String(params.regtest().genesis_hash))
        False ->
          case index.block_at(view, height) {
            Ok(saved) -> Ok(json.String(saved.hash))
            Error(_) -> Error("Block height out of range")
          }
      }
  }
}

fn block(
  view: index.View,
  params: List(json.Value),
) -> Result(json.Value, String) {
  case arg_string(params, 0) {
    Error(_) -> Error("Block not found")
    Ok(hash) ->
      case index.block(view, hash), dict.get(view.chain.blocks, hash) {
        Ok(saved), Ok(chain.Known(raw, _, _)) ->
          case nth(params, 1) {
            Ok(json.Int(0)) -> Ok(json.String(hash.encode_hex(raw)))
            _ ->
              Ok(
                json.Object([
                  #("hash", json.String(hash)),
                  #(
                    "confirmations",
                    json.Int(view.chain.height - saved.height + 1),
                  ),
                  #("height", json.Int(saved.height)),
                  #("nTx", json.Int(list.length(saved.txids))),
                  #("previousblockhash", json.String(saved.prev)),
                  #("time", json.Int(saved.time)),
                  #("tx", json.Array(list.map(saved.txids, json.String))),
                ]),
              )
          }
        _, _ -> Error("Block not found")
      }
  }
}

fn txout(
  view: index.View,
  params: List(json.Value),
) -> Result(json.Value, String) {
  case arg_string(params, 0), arg_int(params, 1) {
    Ok(txid), Ok(n) -> {
      let include = case nth(params, 2) {
        Ok(json.Bool(False)) -> False
        _ -> True
      }
      case find_coin(view, txid, n, include) {
        Error(_) -> Ok(json.Null)
        Ok(#(coin, confirmations)) ->
          Ok(
            json.Object([
              #("bestblock", json.String(chain.tip_hex(view.chain))),
              #("confirmations", json.Int(confirmations)),
              #("value", json.String(amount(coin.value))),
              #(
                "scriptPubKey",
                json.Object([
                  #("hex", json.String(hash.encode_hex(coin.script))),
                ]),
              ),
              #("coinbase", json.Bool(coin.coinbase)),
            ]),
          )
      }
    }
    _, _ -> Error("Invalid parameter")
  }
}

fn raw_tx(
  view: index.View,
  params: List(json.Value),
) -> Result(json.Value, String) {
  case arg_string(params, 0) {
    Error(_) -> Error("Invalid parameter")
    Ok(txid) ->
      case find_tx(view, txid) {
        Error(_) ->
          Error(
            "No such mempool or blockchain transaction. Use gettransaction for wallet transactions.",
          )
        Ok(#(item, height, block_hash)) -> {
          let verbose = case arg_int(params, 1) {
            Ok(n) -> n
            Error(_) -> 0
          }
          case verbose {
            0 -> Ok(json.String(hash.encode_hex(item.raw)))
            _ ->
              Ok(
                json.Object([
                  #("txid", json.String(txid)),
                  #("hash", json.String(hash.display(item.wtxid))),
                  #("version", json.Int(item.version)),
                  #("size", json.Int(bit_array.byte_size(item.raw))),
                  #("locktime", json.Int(item.locktime)),
                  #("hex", json.String(hash.encode_hex(item.raw))),
                  #("blockhash", json.String(block_hash)),
                  #(
                    "confirmations",
                    json.Int(case height < 0 {
                      True -> 0
                      False -> view.chain.height - height + 1
                    }),
                  ),
                ]),
              )
          }
        }
      }
  }
}

fn txout_set(view: index.View) -> json.Value {
  let stats = utxo.stats(view.chain.coins)
  json.Object([
    #("height", json.Int(view.chain.height)),
    #("bestblock", json.String(chain.tip_hex(view.chain))),
    #("txouts", json.Int(stats.txouts)),
    #("bogosize", json.Int(stats.bogosize)),
    #("hash_serialized_3", json.String(stats.hash)),
    #("total_amount", json.String(amount(stats.total_amount))),
    #("transactions", json.Int(stats.transactions)),
  ])
}

fn submit(
  view: index.View,
  params: List(json.Value),
) -> #(Result(json.Value, String), index.View) {
  case arg_string(params, 0) {
    Error(_) -> #(Error("Block decode failed"), view)
    Ok(hex) ->
      case hash.decode_hex(hex) {
        Error(_) -> #(Error("Block decode failed"), view)
        Ok(raw) ->
          case tx.decode_block(raw) {
            Error(_) -> #(Error("Block decode failed"), view)
            Ok(block) -> {
              let digest = hash.display(hash.hash256(block.header))
              case
                digest == chain.tip_hex(view.chain)
                || dict.has_key(view.chain.blocks, digest)
              {
                True -> #(Ok(json.String("duplicate")), view)
                False ->
                  case index.connect(view, raw) {
                    Ok(view) -> #(Ok(json.Null), view)
                    Error(reason) -> #(Ok(json.String(reason)), view)
                  }
              }
            }
          }
      }
  }
}

fn find_coin(
  view: index.View,
  txid: String,
  n: Int,
  include_mempool: Bool,
) -> Result(#(consensus.Coin, Int), Nil) {
  let key = txid <> ":" <> int.to_string(n)
  let #(outputs, spent_keys) = mempool.relay_outputs(view.pool)
  let spent = case include_mempool {
    True -> list.contains(spent_keys, key)
    False -> False
  }
  case spent {
    True -> Error(Nil)
    False ->
      case include_mempool {
        True ->
          case
            list.find(outputs, fn(output) {
              output.txid == txid && output.vout == n
            })
          {
            Ok(output) ->
              Ok(#(
                coin(output.value, output.script, view.chain.height, False),
                0,
              ))
            Error(_) -> chain_coin(view, key)
          }
        False -> chain_coin(view, key)
      }
  }
}

fn chain_coin(
  view: index.View,
  key: String,
) -> Result(#(consensus.Coin, Int), Nil) {
  case dict.get(view.chain.coins, key) {
    Error(_) -> Error(Nil)
    Ok(coin) -> Ok(#(coin, view.chain.height - coin.height + 1))
  }
}

fn find_tx(
  view: index.View,
  txid: String,
) -> Result(#(tx.Tx, Int, String), Nil) {
  let #(outputs, _) = mempool.relay_outputs(view.pool)
  case list.find(outputs, fn(output) { output.txid == txid }) {
    Ok(_) -> mempool_tx(view, txid)
    Error(_) ->
      case index.transaction(view, txid) {
        Error(_) -> Error(Nil)
        Ok(seen) ->
          case index.block_at(view, seen.height) {
            Ok(saved) -> Ok(#(seen.item, seen.height, saved.hash))
            Error(_) -> Error(Nil)
          }
      }
  }
}

fn mempool_tx(
  view: index.View,
  txid: String,
) -> Result(#(tx.Tx, Int, String), Nil) {
  case index.transaction(view, txid) {
    Ok(seen) -> Ok(#(seen.item, -1, ""))
    Error(_) -> Error(Nil)
  }
}

fn coin(
  value: Int,
  script: BitArray,
  height: Int,
  coinbase: Bool,
) -> consensus.Coin {
  consensus.Coin(
    value: value,
    script: script,
    height: height,
    coinbase: coinbase,
  )
}

fn params_of(request: json.Value) -> List(json.Value) {
  case json.field(request, "params") {
    Ok(json.Array(items)) -> items
    _ -> []
  }
}

fn arg_string(params: List(json.Value), index: Int) -> Result(String, Nil) {
  case nth(params, index) {
    Ok(json.String(text)) -> Ok(text)
    _ -> Error(Nil)
  }
}

fn arg_int(params: List(json.Value), index: Int) -> Result(Int, Nil) {
  case nth(params, index) {
    Ok(json.Int(n)) -> Ok(n)
    _ -> Error(Nil)
  }
}

fn nth(items: List(json.Value), index: Int) -> Result(json.Value, Nil) {
  case items {
    [] -> Error(Nil)
    [first, ..rest] ->
      case index {
        0 -> Ok(first)
        _ -> nth(rest, index - 1)
      }
  }
}

fn tip_bits(chain: chain.Chain) -> Int {
  case dict.get(chain.blocks, chain.tip_hex(chain)) {
    Ok(chain.Known(raw, _, _)) ->
      case raw {
        <<
          _:32-little,
          _:bytes-size(32),
          _:bytes-size(32),
          _:32-little,
          bits:32-little,
          _:bits,
        >> -> bits
        _ -> 0x207fffff
      }
    Error(_) -> 0x207fffff
  }
}

fn tip_time(times: List(Int)) -> Int {
  case list.last(times) {
    Ok(time) -> time
    Error(_) -> 0
  }
}

fn median_time(times: List(Int)) -> Int {
  let window = list.take(list.reverse(times), 11)
  let sorted = list.sort(window, by: int.compare)
  at_int(sorted, list.length(sorted) / 2)
}

fn at_int(items: List(Int), index: Int) -> Int {
  case items {
    [] -> 0
    [first, ..rest] ->
      case index {
        0 -> first
        _ -> at_int(rest, index - 1)
      }
  }
}

fn hex8(n: Int) -> String {
  hex_digits(n, 8, "")
}

fn hex_digits(n: Int, left: Int, acc: String) -> String {
  case left {
    0 -> acc
    _ -> hex_digits(n / 16, left - 1, nibble(int.bitwise_and(n, 15)) <> acc)
  }
}

fn nibble(n: Int) -> String {
  case n {
    0 -> "0"
    1 -> "1"
    2 -> "2"
    3 -> "3"
    4 -> "4"
    5 -> "5"
    6 -> "6"
    7 -> "7"
    8 -> "8"
    9 -> "9"
    10 -> "a"
    11 -> "b"
    12 -> "c"
    13 -> "d"
    14 -> "e"
    _ -> "f"
  }
}

fn amount(sats: Int) -> String {
  let whole = sats / 100_000_000
  let frac = sats % 100_000_000
  int.to_string(whole)
  <> "."
  <> string.repeat("0", 8 - string.length(int.to_string(frac)))
  <> int.to_string(frac)
}

fn envelope(result: json.Value, error: json.Value, id: json.Value) -> String {
  json.encode(
    json.Object([
      #("result", result),
      #("error", error),
      #("id", id),
    ]),
  )
}

fn error_obj(code: Int, message: String) -> json.Value {
  json.Object([
    #("code", json.Int(code)),
    #("message", json.String(message)),
  ])
}
