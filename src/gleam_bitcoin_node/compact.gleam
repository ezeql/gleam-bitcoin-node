import gleam/bit_array
import gleam_bitcoin_node/hash
import gleam_bitcoin_node/merkle
import gleam_bitcoin_node/tx

pub fn reconstruct(payload: BitArray) -> Result(BitArray, String) {
  case bit_array.slice(payload, 0, 80) {
    Error(_) -> Error("truncated")
    Ok(header) ->
      case bit_array.slice(payload, 88, bit_array.byte_size(payload) - 88) {
        Error(_) -> Error("truncated")
        Ok(rest) ->
          case compact(rest) {
            Error(_) -> Error("truncated")
            Ok(#(short_count, rest)) ->
              case skip_shortids(short_count, rest) {
                Error(reason) -> Error(reason)
                Ok(rest) ->
                  case compact(rest) {
                    Error(_) -> Error("truncated")
                    Ok(#(prefilled, rest)) ->
                      case read_prefilled(prefilled, rest, -1, []) {
                        Error(reason) -> Error(reason)
                        Ok(txs) ->
                          case header {
                            <<_:32-little, _:bytes-size(32), root:bytes-size(32), _:bits>> -> {
                              let #(got, _) = merkle.block_root(txs)
                              case got == root {
                                False -> Error("bad-txnmrklroot")
                                True ->
                                  Ok(tx.encode_block(tx.ParsedBlock(header, root, txs)))
                              }
                            }
                            _ -> Error("truncated")
                          }
                      }
                  }
              }
          }
      }
  }
}

pub fn header_hex(raw: BitArray) -> String {
  let assert Ok(header) = bit_array.slice(raw, 0, 80)
  hash.display(hash.hash256(header))
}

fn skip_shortids(count: Int, rest: BitArray) -> Result(BitArray, String) {
  case count {
    0 -> Ok(rest)
    n ->
      case bit_array.slice(rest, 6, bit_array.byte_size(rest) - 6) {
        Error(_) -> Error("truncated")
        Ok(rest) -> skip_shortids(n - 1, rest)
      }
  }
}

fn read_prefilled(
  left: Int,
  rest: BitArray,
  prev: Int,
  acc: List(tx.Tx),
) -> Result(List(tx.Tx), String) {
  case left {
    0 -> Ok(reverse(acc))
    _ ->
      case compact(rest) {
        Error(_) -> Error("truncated")
        Ok(#(diff, rest)) -> {
          let index = prev + 1 + diff
          case tx.decode(rest) {
            Error(_) -> Error("truncated")
            Ok(#(item, rest)) ->
              case index == list_len(acc) {
                False -> Error("gap")
                True -> read_prefilled(left - 1, rest, index, [item, ..acc])
              }
          }
        }
      }
  }
}

fn reverse(txs: List(tx.Tx)) -> List(tx.Tx) {
  reverse_loop(txs, [])
}

fn reverse_loop(txs: List(tx.Tx), acc: List(tx.Tx)) -> List(tx.Tx) {
  case txs {
    [] -> acc
    [tx, ..rest] -> reverse_loop(rest, [tx, ..acc])
  }
}

fn list_len(txs: List(tx.Tx)) -> Int {
  list_len_loop(txs, 0)
}

fn list_len_loop(txs: List(tx.Tx), n: Int) -> Int {
  case txs {
    [] -> n
    [_, ..rest] -> list_len_loop(rest, n + 1)
  }
}

fn compact(rest: BitArray) -> Result(#(Int, BitArray), String) {
  case rest {
    <<n, rest:bits>> if n < 253 -> Ok(#(n, rest))
    <<253, n:16-little, rest:bits>> -> Ok(#(n, rest))
    <<254, n:32-little, rest:bits>> -> Ok(#(n, rest))
    _ -> Error("truncated")
  }
}
