import gleam/bit_array
import gleam/int
import gleam/list
import gleam_bitcoin_node/hash

pub type Input {
  Input(
    prev_hash: BitArray,
    prev_index: Int,
    script_sig: BitArray,
    sequence: Int,
    witness: List(BitArray),
  )
}

pub type Output {
  Output(value: Int, script_pubkey: BitArray)
}

pub type Tx {
  Tx(
    version: Int,
    inputs: List(Input),
    outputs: List(Output),
    locktime: Int,
    raw: BitArray,
    txid: BitArray,
    wtxid: BitArray,
    has_witness: Bool,
    base_size: Int,
  )
}

pub type ParsedBlock {
  ParsedBlock(header: BitArray, merkle: BitArray, txs: List(Tx))
}

pub fn decode_block(raw: BitArray) -> Result(ParsedBlock, String) {
  case bit_array.slice(raw, 0, 80) {
    Error(_) -> Error("truncated")
    Ok(header) ->
      case header {
        <<_:32-little, _:bytes-size(32), merkle:bytes-size(32), _:32-little, _:32-little, _:32-little>> ->
          case bit_array.slice(raw, 80, bit_array.byte_size(raw) - 80) {
            Error(_) -> Error("truncated")
            Ok(body) ->
              case compact(body) {
                Error(reason) -> Error(reason)
                Ok(#(count, rest)) ->
                  case read_n(count, rest, decode, []) {
                    Error(reason) -> Error(reason)
                    Ok(#(txs, left)) ->
                      case bit_array.byte_size(left) {
                        0 -> Ok(ParsedBlock(header, merkle, txs))
                        _ -> Error("trailing-bytes")
                      }
                  }
              }
          }
        _ -> Error("truncated")
      }
  }
}

pub fn encode_block(block: ParsedBlock) -> BitArray {
  <<block.header:bits, encode_compact(list.length(block.txs)):bits, encode_txs(block.txs):bits>>
}

pub fn decode(raw: BitArray) -> Result(#(Tx, BitArray), String) {
  case raw {
    <<version:32-little, rest:bits>> -> decode_after_version(raw, version, rest)
    _ -> Error("truncated")
  }
}

pub fn encode(tx: Tx) -> BitArray {
  let witness = list.any(tx.inputs, fn(input) { input.witness != [] })
  let marker = case witness {
    True -> <<0, 1>>
    False -> <<>>
  }
  let witnesses = case witness {
    True -> encode_witnesses(tx.inputs)
    False -> <<>>
  }
  <<
    tx.version:32-little,
    marker:bits,
    encode_inputs(tx.inputs):bits,
    encode_outputs(tx.outputs):bits,
    witnesses:bits,
    tx.locktime:32-little,
  >>
}

pub fn weight(tx: Tx) -> Int {
  tx.base_size * 3 + bit_array.byte_size(tx.raw)
}

fn decode_after_version(bin: BitArray, version: Int, rest: BitArray) -> Result(#(Tx, BitArray), String) {
  case decode_inputs(rest) {
    Error(reason) -> Error(reason)
    Ok(#([], rest)) -> decode_marker(bin, version, rest)
    Ok(#(vin, rest)) ->
      case decode_outputs(rest) {
        Error(reason) -> Error(reason)
        Ok(#(vout, rest)) -> finish(bin, version, 0, vin, vout, rest, -1)
      }
  }
}

// An empty vin is the segwit marker. The next byte is the flag.
fn decode_marker(bin: BitArray, version: Int, rest: BitArray) -> Result(#(Tx, BitArray), String) {
  case rest {
    <<0, rest:bits>> -> finish(bin, version, 0, [], [], rest, -1)
    <<flags, rest:bits>> -> {
      let body_start = bit_array.byte_size(bin) - bit_array.byte_size(rest)
      case decode_inputs(rest) {
        Error(reason) -> Error(reason)
        Ok(#(vin, after_in)) ->
          case decode_outputs(after_in) {
            Error(reason) -> Error(reason)
            Ok(#(vout, after_out)) ->
              finish(bin, version, flags, vin, vout, after_out, body_start)
          }
      }
    }
    _ -> Error("truncated")
  }
}

fn finish(
  bin: BitArray,
  version: Int,
  flags: Int,
  vin: List(Input),
  vout: List(Output),
  rest: BitArray,
  body_start: Int,
) -> Result(#(Tx, BitArray), String) {
  let body_end = bit_array.byte_size(bin) - bit_array.byte_size(rest)
  case apply_witness(flags, vin, rest) {
    Error(reason) -> Error(reason)
    Ok(#(flags, vin, rest)) ->
      case flags {
        0 ->
          case rest {
            <<locktime:32-little, left:bits>> ->
              Ok(#(build_tx(bin, version, vin, vout, locktime, left, body_start, body_end), left))
            _ -> Error("truncated")
          }
        _ -> Error("unknown-tx-optional-data")
      }
  }
}

fn build_tx(
  bin: BitArray,
  version: Int,
  vin: List(Input),
  vout: List(Output),
  locktime: Int,
  left: BitArray,
  body_start: Int,
  body_end: Int,
) -> Tx {
  let total = bit_array.byte_size(bin) - bit_array.byte_size(left)
  let assert Ok(raw) = bit_array.slice(bin, 0, total)
  let has_witness = body_start >= 0 && any_witness(vin)
  let wtxid = hash.hash256(raw)
  let txid = case has_witness {
    True -> {
      let assert Ok(ver) = bit_array.slice(bin, 0, 4)
      let assert Ok(body) = bit_array.slice(bin, body_start, body_end - body_start)
      hash.hash256(<<ver:bits, body:bits, locktime:32-little>>)
    }
    False -> wtxid
  }
  let base_size = case has_witness {
    True -> 4 + body_end - body_start + 4
    False -> total
  }
  Tx(version, vin, vout, locktime, raw, txid, wtxid, has_witness, base_size)
}

fn apply_witness(
  flags: Int,
  vin: List(Input),
  rest: BitArray,
) -> Result(#(Int, List(Input), BitArray), String) {
  case int.bitwise_and(flags, 1) == 1 {
    False -> Ok(#(flags, vin, rest))
    True ->
      case decode_witnesses(vin, rest, []) {
        Error(reason) -> Error(reason)
        Ok(#(vin, rest)) ->
          case any_witness(vin) {
            False -> Error("superfluous-witness")
            True -> Ok(#(int.bitwise_exclusive_or(flags, 1), vin, rest))
          }
      }
  }
}

fn any_witness(vin: List(Input)) -> Bool {
  list.any(vin, fn(input) { input.witness != [] })
}

fn decode_inputs(rest: BitArray) -> Result(#(List(Input), BitArray), String) {
  case compact(rest) {
    Error(reason) -> Error(reason)
    Ok(#(n, rest)) -> read_n(n, rest, decode_input, [])
  }
}

fn decode_outputs(rest: BitArray) -> Result(#(List(Output), BitArray), String) {
  case compact(rest) {
    Error(reason) -> Error(reason)
    Ok(#(n, rest)) -> read_n(n, rest, decode_output, [])
  }
}

fn decode_input(rest: BitArray) -> Result(#(Input, BitArray), String) {
  case rest {
    <<prev:bytes-size(32), index:32-little, rest:bits>> ->
      case take_bytes(rest) {
        Error(reason) -> Error(reason)
        Ok(#(script_sig, rest)) ->
          case rest {
            <<sequence:32-little, rest:bits>> ->
              Ok(#(Input(prev, index, script_sig, sequence, []), rest))
            _ -> Error("truncated")
          }
      }
    _ -> Error("truncated")
  }
}

fn decode_output(rest: BitArray) -> Result(#(Output, BitArray), String) {
  case rest {
    <<value:64-little, rest:bits>> ->
      case take_bytes(rest) {
        Error(reason) -> Error(reason)
        Ok(#(script, rest)) -> Ok(#(Output(signed_64(value), script), rest))
      }
    _ -> Error("truncated")
  }
}

fn decode_witnesses(
  inputs: List(Input),
  rest: BitArray,
  acc: List(Input),
) -> Result(#(List(Input), BitArray), String) {
  case inputs {
    [] -> Ok(#(list.reverse(acc), rest))
    [input, ..tail] ->
      case compact(rest) {
        Error(reason) -> Error(reason)
        Ok(#(n, rest)) ->
          case read_n(n, rest, take_bytes, []) {
            Error(reason) -> Error(reason)
            Ok(#(stack, rest)) ->
              decode_witnesses(tail, rest, [Input(..input, witness: stack), ..acc])
          }
      }
  }
}

fn read_n(
  n: Int,
  rest: BitArray,
  f: fn(BitArray) -> Result(#(a, BitArray), String),
  acc: List(a),
) -> Result(#(List(a), BitArray), String) {
  case n {
    0 -> Ok(#(list.reverse(acc), rest))
    _ ->
      case f(rest) {
        Error(reason) -> Error(reason)
        Ok(#(item, rest)) -> read_n(n - 1, rest, f, [item, ..acc])
      }
  }
}

fn encode_inputs(inputs: List(Input)) -> BitArray {
  <<encode_compact(list.length(inputs)):bits, concat(list.map(inputs, encode_input)):bits>>
}

fn encode_outputs(outputs: List(Output)) -> BitArray {
  <<encode_compact(list.length(outputs)):bits, concat(list.map(outputs, encode_output)):bits>>
}

fn encode_input(input: Input) -> BitArray {
  <<
    input.prev_hash:bits,
    input.prev_index:32-little,
    encode_bytes(input.script_sig):bits,
    input.sequence:32-little,
  >>
}

fn encode_output(output: Output) -> BitArray {
  <<encode_amount(output.value):bits, encode_bytes(output.script_pubkey):bits>>
}

fn encode_witnesses(inputs: List(Input)) -> BitArray {
  concat(list.map(inputs, fn(input) { encode_stack(input.witness) }))
}

fn encode_stack(stack: List(BitArray)) -> BitArray {
  <<encode_compact(list.length(stack)):bits, concat(list.map(stack, encode_bytes)):bits>>
}

fn encode_txs(txs: List(Tx)) -> BitArray {
  concat(list.map(txs, encode))
}

fn encode_bytes(bytes: BitArray) -> BitArray {
  <<encode_compact(bit_array.byte_size(bytes)):bits, bytes:bits>>
}

fn encode_compact(n: Int) -> BitArray {
  case n < 253 {
    True -> <<n>>
    False ->
      case n < 0x10000 {
        True -> <<253, n:16-little>>
        False ->
          case n < 0x100000000 {
            True -> <<254, n:32-little>>
            False -> <<255, n:64-little>>
          }
      }
  }
}

fn encode_amount(value: Int) -> BitArray {
  let value = case value < 0 {
    True -> value + 18_446_744_073_709_551_616
    False -> value
  }
  <<value:64-little>>
}

fn signed_64(value: Int) -> Int {
  case value >= 9_223_372_036_854_775_808 {
    True -> value - 18_446_744_073_709_551_616
    False -> value
  }
}

fn take_bytes(rest: BitArray) -> Result(#(BitArray, BitArray), String) {
  case compact(rest) {
    Error(reason) -> Error(reason)
    Ok(#(len, rest)) ->
      case bit_array.slice(rest, 0, len), bit_array.slice(rest, len, bit_array.byte_size(rest) - len) {
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
    <<253, _:16-little, _:bits>> | <<254, _:32-little, _:bits>> | <<255, _:64-little, _:bits>> ->
      Error("non-canonical")
    _ -> Error("truncated")
  }
}

fn concat(parts: List(BitArray)) -> BitArray {
  concat_loop(parts, <<>>)
}

fn concat_loop(parts: List(BitArray), acc: BitArray) -> BitArray {
  case parts {
    [] -> acc
    [part, ..rest] -> concat_loop(rest, <<acc:bits, part:bits>>)
  }
}
