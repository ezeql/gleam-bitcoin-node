import gleam/bit_array
import gleam/int
import gleam_bitcoin_node/hash

pub type Header {
  Header(raw: BitArray, prev: BitArray, merkle: BitArray, bits: Int)
}

pub type Coinbase {
  Coinbase(
    txid: BitArray,
    script_sig: BitArray,
    output_sum: Int,
    nonce: BitArray,
    commitment: BitArray,
  )
}

pub type Parsed {
  Parsed(header: Header, coinbase: Coinbase)
}

pub fn decode_block(raw: BitArray) -> Result(Parsed, String) {
  case bit_array.slice(raw, 0, 80) {
    Error(_) -> Error("truncated")
    Ok(header_raw) -> {
      case header_raw {
        <<
          _:32-little,
          prev:bytes-size(32),
          merkle:bytes-size(32),
          _:32-little,
          bits:32-little,
          _:32-little,
        >> -> {
          let header =
            Header(raw: header_raw, prev: prev, merkle: merkle, bits: bits)
          case bit_array.slice(raw, 80, bit_array.byte_size(raw) - 80) {
            Error(_) -> Error("truncated")
            Ok(body) ->
              case decode_txs(body) {
                Error(reason) -> Error(reason)
                Ok(coinbase) -> Ok(Parsed(header, coinbase))
              }
          }
        }
        _ -> Error("truncated")
      }
    }
  }
}

fn decode_txs(body: BitArray) -> Result(Coinbase, String) {
  case compact(body) {
    Error(_) -> Error("truncated")
    Ok(#(count, rest)) ->
      case count {
        1 ->
          case decode_tx(rest) {
            Error(reason) -> Error(reason)
            Ok(#(tx, left)) ->
              case bit_array.byte_size(left) {
                0 -> Ok(tx)
                _ -> Error("trailing-bytes")
              }
          }
        _ -> Error("bad-cb-multiple")
      }
  }
}

fn decode_tx(raw: BitArray) -> Result(#(Coinbase, BitArray), String) {
  case raw {
    <<version:bytes-size(4), rest:bits>> -> decode_after_version(version, rest)
    _ -> Error("truncated")
  }
}

fn decode_after_version(
  version: BitArray,
  rest: BitArray,
) -> Result(#(Coinbase, BitArray), String) {
  case rest {
    <<0, 1, rest:bits>> -> decode_segwit(version, rest)
    _ -> Error("unexpected-witness")
  }
}

fn decode_segwit(
  version: BitArray,
  rest: BitArray,
) -> Result(#(Coinbase, BitArray), String) {
  case inputs(rest) {
    Error(reason) -> Error(reason)
    Ok(#(vin, script_sig, after_in)) ->
      case outputs(after_in, 0, <<>>) {
        Error(reason) -> Error(reason)
        Ok(#(sum, commitment, vout_raw, after_out)) ->
          case witness(after_out) {
            Error(reason) -> Error(reason)
            Ok(#(nonce, after_wit)) ->
              case after_wit {
                <<locktime:bytes-size(4), left:bits>> -> {
                  let txid =
                    hash.hash256(<<
                      version:bits,
                      vin:bits,
                      vout_raw:bits,
                      locktime:bits,
                    >>)
                  let coin = Coinbase(txid, script_sig, sum, nonce, commitment)
                  Ok(#(coin, left))
                }
                _ -> Error("truncated")
              }
          }
      }
  }
}

fn inputs(rest: BitArray) -> Result(#(BitArray, BitArray, BitArray), String) {
  let start = rest
  case compact(rest) {
    Error(_) -> Error("truncated")
    Ok(#(1, rest)) ->
      case rest {
        <<prev:bytes-size(32), index:32-little, rest:bits>> -> {
          case prev == <<0:size(256)>> && index == 0xffffffff {
            False -> Error("bad-cb-missing")
            True ->
              case script(rest) {
                Error(_) -> Error("truncated")
                Ok(#(script_sig, rest)) -> {
                  let size = bit_array.byte_size(script_sig)
                  case size >= 2 && size <= 100 {
                    False -> Error("bad-cb-length")
                    True ->
                      case rest {
                        <<_:32-little, rest:bits>> -> {
                          let consumed =
                            bit_array.byte_size(start)
                            - bit_array.byte_size(rest)
                          case bit_array.slice(start, 0, consumed) {
                            Ok(vin) -> Ok(#(vin, script_sig, rest))
                            Error(_) -> Error("truncated")
                          }
                        }
                        _ -> Error("truncated")
                      }
                  }
                }
              }
          }
        }
        _ -> Error("truncated")
      }
    Ok(#(_, _)) -> Error("bad-cb-multiple")
  }
}

fn outputs(
  rest: BitArray,
  sum: Int,
  commitment: BitArray,
) -> Result(#(Int, BitArray, BitArray, BitArray), String) {
  let start = rest
  case compact(rest) {
    Error(_) -> Error("truncated")
    Ok(#(n, rest)) -> read_outputs(n, rest, sum, commitment, start)
  }
}

fn read_outputs(
  n: Int,
  rest: BitArray,
  sum: Int,
  commitment: BitArray,
  start: BitArray,
) -> Result(#(Int, BitArray, BitArray, BitArray), String) {
  case n {
    0 -> {
      let consumed = bit_array.byte_size(start) - bit_array.byte_size(rest)
      case bit_array.slice(start, 0, consumed) {
        Ok(raw) -> Ok(#(sum, commitment, raw, rest))
        Error(_) -> Error("truncated")
      }
    }
    _ ->
      case rest {
        <<value:64-little, rest:bits>> -> {
          case value < 0 {
            True -> Error("bad-txns-vout-negative")
            False ->
              case value > 21_000_000 * 100_000_000 {
                True -> Error("bad-txns-vout-toolarge")
                False ->
                  case sum + value > 21_000_000 * 100_000_000 {
                    True -> Error("bad-txns-txouttotal-toolarge")
                    False ->
                      case script(rest) {
                        Error(_) -> Error("truncated")
                        Ok(#(script, rest)) -> {
                          let commitment = case
                            value == 0 && commitment == <<>>
                          {
                            True -> script
                            False -> commitment
                          }
                          read_outputs(
                            n - 1,
                            rest,
                            sum + value,
                            commitment,
                            start,
                          )
                        }
                      }
                  }
              }
          }
        }
        _ -> Error("truncated")
      }
  }
}

fn witness(rest: BitArray) -> Result(#(BitArray, BitArray), String) {
  case compact(rest) {
    Ok(#(1, rest)) ->
      case script(rest) {
        Ok(#(item, rest)) ->
          case bit_array.byte_size(item) == 32 {
            True -> Ok(#(item, rest))
            False -> Error("bad-witness-nonce-size")
          }
        Error(_) -> Error("truncated")
      }
    _ -> Error("bad-witness-nonce-size")
  }
}

fn script(rest: BitArray) -> Result(#(BitArray, BitArray), String) {
  case compact(rest) {
    Error(_) -> Error("truncated")
    Ok(#(len, rest)) ->
      case
        bit_array.slice(rest, 0, len),
        bit_array.slice(rest, len, bit_array.byte_size(rest) - len)
      {
        Ok(item), Ok(left) -> Ok(#(item, left))
        _, _ -> Error("truncated")
      }
  }
}

fn compact(rest: BitArray) -> Result(#(Int, BitArray), String) {
  case rest {
    <<n, rest:bits>> if n < 253 -> Ok(#(n, rest))
    <<253, n:16-little, rest:bits>> if n >= 253 -> Ok(#(n, rest))
    <<254, n:32-little, rest:bits>> if n >= 0x10000 -> Ok(#(n, rest))
    <<255, n:64-little, rest:bits>> if n >= 0x100000000 -> Ok(#(n, rest))
    <<253, _:16-little, _:bits>>
    | <<254, _:32-little, _:bits>>
    | <<255, _:64-little, _:bits>> -> Error("non-canonical")
    _ -> Error("truncated")
  }
}

pub fn commitment_ok(nonce: BitArray, script: BitArray) -> Bool {
  let expect = hash.hash256(<<0:size(256), nonce:bits>>)
  case script {
    <<0x6a, 0x24, 0xaa, 0x21, 0xa9, 0xed, got:bytes-size(32), _:bits>> ->
      got == expect
    _ -> False
  }
}

pub fn bip34_ok(height: Int, script_sig: BitArray) -> Bool {
  let prefix = case height >= 1 && height <= 16 {
    True -> <<{ 0x50 + height }>>
    False -> {
      let body = script_num(height)
      <<{ bit_array.byte_size(body) }, body:bits>>
    }
  }
  case bit_array.slice(script_sig, 0, bit_array.byte_size(prefix)) {
    Ok(got) -> got == prefix
    Error(_) -> False
  }
}

fn script_num(n: Int) -> BitArray {
  case n {
    0 -> <<0>>
    _ -> sign_extend(le_bytes(n, <<>>))
  }
}

fn le_bytes(n: Int, acc: BitArray) -> BitArray {
  case n {
    0 -> acc
    _ -> le_bytes(n / 256, <<acc:bits, { n % 256 }>>)
  }
}

fn sign_extend(bytes: BitArray) -> BitArray {
  let size = bit_array.byte_size(bytes)
  let assert Ok(<<last>>) = bit_array.slice(bytes, size - 1, 1)
  case last >= 128 {
    True -> <<bytes:bits, 0>>
    False -> bytes
  }
}

pub fn subsidy(height: Int) -> Int {
  let halvings = height / 150
  case halvings >= 64 {
    True -> 0
    False -> int.bitwise_shift_right(50 * 100_000_000, halvings)
  }
}
