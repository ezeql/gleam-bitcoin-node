import gleam/bit_array
import gleam/list

const op_1 = 0x51

const op_16 = 0x60

pub fn sigop_count(script: BitArray, accurate: Bool) -> Int {
  count(script, accurate, 0xff, 0)
}

pub fn is_p2sh(script: BitArray) -> Bool {
  case script {
    <<0xa9, 0x14, _:bytes-size(20), 0x87>> -> True
    _ -> False
  }
}

pub fn p2sh_sigops(script_pubkey: BitArray, script_sig: BitArray) -> Int {
  case is_p2sh(script_pubkey) {
    False -> sigop_count(script_pubkey, True)
    True ->
      case last_push(script_sig) {
        Ok(data) -> sigop_count(data, True)
        Error(_) -> 0
      }
  }
}

pub fn witness_sigops(
  script_sig: BitArray,
  script_pubkey: BitArray,
  witness: List(BitArray),
  enabled: Bool,
) -> Int {
  case enabled {
    False -> 0
    True ->
      case witness_program(script_pubkey) {
        Ok(#(version, program)) -> witness_for(version, program, witness)
        Error(_) ->
          case is_p2sh(script_pubkey) {
            False -> 0
            True ->
              case last_push(script_sig) {
                Ok(data) ->
                  case witness_program(data) {
                    Ok(#(version, program)) -> witness_for(version, program, witness)
                    Error(_) -> 0
                  }
                Error(_) -> 0
              }
          }
      }
  }
}

pub fn unspendable(script: BitArray) -> Bool {
  case script {
    <<0x6a, _:bits>> -> True
    _ -> bit_array.byte_size(script) > 10_000
  }
}

fn witness_for(version: Int, program: BitArray, witness: List(BitArray)) -> Int {
  let size = bit_array.byte_size(program)
  case version == 0 && size == 20 {
    True -> 1
    False ->
      case version == 0 && size == 32 {
        False -> 0
        True ->
          case list.last(witness) {
            Ok(item) -> sigop_count(item, True)
            Error(_) -> 0
          }
      }
  }
}

fn witness_program(script: BitArray) -> Result(#(Int, BitArray), Nil) {
  let size = bit_array.byte_size(script)
  case size >= 4 && size <= 42 {
    False -> Error(Nil)
    True ->
      case script {
        <<version, len, program:bits>> if len + 2 == size ->
          case version == 0 || { version >= op_1 && version <= op_16 } {
            False -> Error(Nil)
            True -> Ok(#(decode_op_n(version), program))
          }
        _ -> Error(Nil)
      }
  }
}

fn last_push(script: BitArray) -> Result(BitArray, Nil) {
  case bit_array.byte_size(script) {
    0 -> Ok(<<>>)
    _ -> push_only(script, <<>>)
  }
}

fn push_only(script: BitArray, data: BitArray) -> Result(BitArray, Nil) {
  case bit_array.byte_size(script) {
    0 -> Ok(data)
    _ ->
      case get_op(script) {
        Error(_) -> Error(Nil)
        Ok(#(op, pushed, rest)) ->
          case op > op_16 {
            True -> Error(Nil)
            False -> push_only(rest, pushed)
          }
      }
  }
}

fn count(script: BitArray, accurate: Bool, last: Int, total: Int) -> Int {
  case get_op(script) {
    Error(_) -> total
    Ok(#(op, _, rest)) -> {
      let total = case op == 0xac || op == 0xad {
        True -> total + 1
        False ->
          case op == 0xae || op == 0xaf {
            True ->
              case accurate && last >= op_1 && last <= op_16 {
                True -> total + decode_op_n(last)
                False -> total + 20
              }
            False -> total
          }
      }
      count(rest, accurate, op, total)
    }
  }
}

fn get_op(script: BitArray) -> Result(#(Int, BitArray, BitArray), Nil) {
  case script {
    <<op, rest:bits>> if op < 0x4c -> take_push(op, op, rest)
    <<0x4c, n, rest:bits>> -> take_push(0x4c, n, rest)
    <<0x4d, n:16-little, rest:bits>> -> take_push(0x4d, n, rest)
    <<0x4e, n:32-little, rest:bits>> -> take_push(0x4e, n, rest)
    <<op, rest:bits>> -> Ok(#(op, <<>>, rest))
    _ -> Error(Nil)
  }
}

fn take_push(op: Int, n: Int, rest: BitArray) -> Result(#(Int, BitArray, BitArray), Nil) {
  case bit_array.slice(rest, 0, n) {
    Error(_) -> Error(Nil)
    Ok(data) ->
      case bit_array.slice(rest, n, bit_array.byte_size(rest) - n) {
        Error(_) -> Error(Nil)
        Ok(left) -> Ok(#(op, data, left))
      }
  }
}

fn decode_op_n(op: Int) -> Int {
  case op {
    0 -> 0
    _ -> op - 0x50
  }
}
