import gleam/bit_array
import gleam/int
import gleam/string

@external(erlang, "gleam_bitcoin_node_ffi", "sha256")
fn sha256(data: BitArray) -> BitArray

@external(erlang, "gleam_bitcoin_node_ffi", "hex_encode")
fn hex_encode(data: BitArray) -> String

@external(erlang, "gleam_bitcoin_node_ffi", "hex_decode")
fn hex_decode(hex: String) -> Result(BitArray, Nil)

pub fn hash256(data: BitArray) -> BitArray {
  sha256(sha256(data))
}

pub fn display(internal: BitArray) -> String {
  case bit_array.slice(internal, 0, bit_array.byte_size(internal)) {
    Ok(bytes) -> hex_encode(reverse(bytes))
    Error(_) -> ""
  }
}

pub fn from_display(hex: String) -> Result(BitArray, Nil) {
  case hex_decode(string.lowercase(string.trim(hex))) {
    Ok(bytes) -> Ok(reverse(bytes))
    Error(_) -> Error(Nil)
  }
}

pub fn little_endian_int(bytes: BitArray) -> Int {
  do_le(bytes, 0, 0)
}

fn do_le(bytes: BitArray, acc: Int, shift: Int) -> Int {
  case bytes {
    <<byte, rest:bits>> ->
      do_le(rest, acc + int.bitwise_shift_left(byte, shift), shift + 8)
    _ -> acc
  }
}

fn reverse(bytes: BitArray) -> BitArray {
  reverse_loop(bytes, <<>>)
}

fn reverse_loop(bytes: BitArray, acc: BitArray) -> BitArray {
  case bytes {
    <<byte, rest:bits>> -> reverse_loop(rest, <<byte, acc:bits>>)
    _ -> acc
  }
}
