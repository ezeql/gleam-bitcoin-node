import gleam/bit_array
import gleam/int
import gleam/list
import gleam/string
import gleam_bitcoin_node/hash

const bech32 = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"

const base58 = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"

const bech32_const = 1

const bech32m_const = 0x2bc830a3

pub fn to_script(addr: String) -> Result(BitArray, Nil) {
  case witness("bcrt", addr) {
    Ok(#(version, program)) -> Ok(witness_script(version, program))
    Error(_) -> base58_script(addr, 0x6f, 0xc4)
  }
}

pub fn witness(hrp: String, addr: String) -> Result(#(Int, BitArray), Nil) {
  let lower = string.lowercase(addr)
  case addr != lower && addr != string.uppercase(addr) {
    True -> Error(Nil)
    False ->
      case string.split_once(lower, "1") {
        Ok(#(got, data)) if got == hrp -> decode_data(hrp, data)
        _ -> Error(Nil)
      }
  }
}

fn decode_data(hrp: String, data: String) -> Result(#(Int, BitArray), Nil) {
  case values(string.to_graphemes(data), []) {
    Error(_) -> Error(Nil)
    Ok(values) ->
      case
        list.length(values) < 7
        || string.length(hrp) + 1 + list.length(values) > 90
      {
        True -> Error(Nil)
        False -> check_payload(hrp, values)
      }
  }
}

fn check_payload(
  hrp: String,
  values: List(Int),
) -> Result(#(Int, BitArray), Nil) {
  let sum = polymod(list.append(hrp_expand(hrp), values))
  let version = case values {
    [version, ..] -> version
    _ -> -1
  }
  let payload = drop_last(values, 6)
  let data = case payload {
    [_, ..rest] -> rest
    _ -> []
  }
  let ok = case version == 0 && sum == bech32_const {
    True -> True
    False -> version > 0 && version <= 16 && sum == bech32m_const
  }
  case ok {
    False -> Error(Nil)
    True ->
      case convert(data, 0, 0, []) {
        Error(_) -> Error(Nil)
        Ok(bytes) -> program(version, bytes)
      }
  }
}

fn program(version: Int, bytes: List(Int)) -> Result(#(Int, BitArray), Nil) {
  let size = list.length(bytes)
  let ok = case version {
    0 -> size == 20 || size == 32
    _ -> size >= 2 && size <= 40
  }
  case ok {
    True -> Ok(#(version, from_bytes(bytes)))
    False -> Error(Nil)
  }
}

fn witness_script(version: Int, program: BitArray) -> BitArray {
  let op = case version {
    0 -> 0
    _ -> 0x50 + version
  }
  <<op, bit_array.byte_size(program), program:bits>>
}

fn base58_script(addr: String, pkh: Int, sh: Int) -> Result(BitArray, Nil) {
  case base58_decode(addr) {
    Error(_) -> Error(Nil)
    Ok(bin) ->
      case check_base58(bin) {
        Error(_) -> Error(Nil)
        Ok(payload) ->
          case payload {
            <<ver, hash:bytes-size(20)>> if ver == pkh ->
              Ok(<<0x76, 0xa9, 20, hash:bits, 0x88, 0xac>>)
            <<ver, hash:bytes-size(20)>> if ver == sh ->
              Ok(<<0xa9, 20, hash:bits, 0x87>>)
            _ -> Error(Nil)
          }
      }
  }
}

fn check_base58(bin: BitArray) -> Result(BitArray, Nil) {
  let size = bit_array.byte_size(bin)
  case size >= 4 {
    False -> Error(Nil)
    True ->
      case
        bit_array.slice(bin, 0, size - 4),
        bit_array.slice(bin, size - 4, 4)
      {
        Ok(payload), Ok(sum) ->
          case bit_array.slice(hash.hash256(payload), 0, 4) {
            Ok(got) if got == sum -> Ok(payload)
            _ -> Error(Nil)
          }
        _, _ -> Error(Nil)
      }
  }
}

fn base58_decode(addr: String) -> Result(BitArray, Nil) {
  let chars = string.to_graphemes(addr)
  case b58_int(chars, 0) {
    Error(_) -> Error(Nil)
    Ok(n) -> Ok(pad(leading(chars), int_bytes(n)))
  }
}

fn leading(chars: List(String)) -> Int {
  case chars {
    ["1", ..rest] -> 1 + leading(rest)
    _ -> 0
  }
}

fn b58_int(chars: List(String), acc: Int) -> Result(Int, Nil) {
  case chars {
    [] -> Ok(acc)
    [char, ..rest] ->
      case index_of(base58, char, 0) {
        Error(_) -> Error(Nil)
        Ok(n) -> b58_int(rest, acc * 58 + n)
      }
  }
}

fn int_bytes(n: Int) -> BitArray {
  case n <= 0 {
    True -> <<>>
    False -> <<int_bytes(n / 256):bits, int.bitwise_and(n, 255)>>
  }
}

fn pad(n: Int, bytes: BitArray) -> BitArray {
  case n {
    0 -> bytes
    _ -> pad(n - 1, <<0, bytes:bits>>)
  }
}

fn values(chars: List(String), acc: List(Int)) -> Result(List(Int), Nil) {
  case chars {
    [] -> Ok(list.reverse(acc))
    [char, ..rest] ->
      case index_of(bech32, char, 0) {
        Error(_) -> Error(Nil)
        Ok(n) -> values(rest, [n, ..acc])
      }
  }
}

fn hrp_expand(hrp: String) -> List(Int) {
  let codes =
    list.map(string.to_utf_codepoints(hrp), string.utf_codepoint_to_int)
  list.flatten([
    list.map(codes, fn(n) { n / 32 }),
    [0],
    list.map(codes, fn(n) { int.bitwise_and(n, 31) }),
  ])
}

fn polymod(values: List(Int)) -> Int {
  list.fold(values, 1, fn(chk, value) {
    let top = int.bitwise_shift_right(chk, 25)
    let chk =
      int.bitwise_exclusive_or(
        int.bitwise_shift_left(int.bitwise_and(chk, 0x1ffffff), 5),
        value,
      )
    xor_gen(top, chk, 0, [
      0x3b6a57b2,
      0x26508e6d,
      0x1ea119fa,
      0x3d4233dd,
      0x2a1462b3,
    ])
  })
}

fn xor_gen(top: Int, chk: Int, i: Int, gen: List(Int)) -> Int {
  case gen {
    [] -> chk
    [g, ..rest] -> {
      let chk = case int.bitwise_and(int.bitwise_shift_right(top, i), 1) == 1 {
        True -> int.bitwise_exclusive_or(chk, g)
        False -> chk
      }
      xor_gen(top, chk, i + 1, rest)
    }
  }
}

fn convert(
  data: List(Int),
  acc: Int,
  bits: Int,
  out: List(Int),
) -> Result(List(Int), Nil) {
  case data {
    [] ->
      case
        bits >= 5
        || int.bitwise_and(int.bitwise_shift_left(acc, 8 - bits), 255) != 0
      {
        True -> Error(Nil)
        False -> Ok(list.reverse(out))
      }
    [value, ..rest] -> {
      let acc = int.bitwise_or(int.bitwise_shift_left(acc, 5), value)
      let #(acc, bits, out) = emit(acc, bits + 5, out)
      convert(rest, acc, bits, out)
    }
  }
}

fn emit(acc: Int, bits: Int, out: List(Int)) -> #(Int, Int, List(Int)) {
  case bits >= 8 {
    True -> {
      let bits = bits - 8
      let byte = int.bitwise_and(int.bitwise_shift_right(acc, bits), 255)
      emit(int.bitwise_and(acc, mask(bits)), bits, [byte, ..out])
    }
    False -> #(acc, bits, out)
  }
}

fn mask(bits: Int) -> Int {
  case bits {
    0 -> 0
    _ -> int.bitwise_shift_left(1, bits) - 1
  }
}

fn from_bytes(bytes: List(Int)) -> BitArray {
  list.fold(bytes, <<>>, fn(acc, byte) { <<acc:bits, byte>> })
}

fn index_of(alphabet: String, char: String, i: Int) -> Result(Int, Nil) {
  case string.pop_grapheme(alphabet) {
    Error(_) -> Error(Nil)
    Ok(#(got, rest)) ->
      case got == char {
        True -> Ok(i)
        False -> index_of(rest, char, i + 1)
      }
  }
}

fn drop_last(values: List(Int), n: Int) -> List(Int) {
  list.take(values, int.max(list.length(values) - n, 0))
}
