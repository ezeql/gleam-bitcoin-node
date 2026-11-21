import gleam/bit_array
import gleam/int

const mask = 0xffffffffffffffff

pub fn hash(k0: Int, k1: Int, message: BitArray) -> Int {
  let k0 = int.bitwise_and(k0, mask)
  let k1 = int.bitwise_and(k1, mask)
  let state = #(
    int.bitwise_exclusive_or(0x736f6d6570736575, k0),
    int.bitwise_exclusive_or(0x646f72616e646f6d, k1),
    int.bitwise_exclusive_or(0x6c7967656e657261, k0),
    int.bitwise_exclusive_or(0x7465646279746573, k1),
  )
  let #(state, tail) = blocks(message, state)
  let last =
    int.bitwise_or(
      int.bitwise_shift_left(
        int.bitwise_and(bit_array.byte_size(message), 0xff),
        56,
      ),
      le(tail, 0, 0),
    )
  let #(v0, v1, v2, v3) = compress(state, last)
  let #(v0, v1, v2, v3) =
    rounds(#(v0, v1, int.bitwise_exclusive_or(v2, 0xff), v3), 4)
  int.bitwise_exclusive_or(
    int.bitwise_exclusive_or(v0, v1),
    int.bitwise_exclusive_or(v2, v3),
  )
}

fn blocks(
  message: BitArray,
  state: #(Int, Int, Int, Int),
) -> #(#(Int, Int, Int, Int), BitArray) {
  case message {
    <<word:64-little, rest:bits>> -> blocks(rest, compress(state, word))
    tail -> #(state, tail)
  }
}

fn compress(state: #(Int, Int, Int, Int), word: Int) -> #(Int, Int, Int, Int) {
  let #(v0, v1, v2, v3) = state
  let #(v0, v1, v2, v3) =
    rounds(#(v0, v1, v2, int.bitwise_exclusive_or(v3, word)), 2)
  #(int.bitwise_exclusive_or(v0, word), v1, v2, v3)
}

fn rounds(state: #(Int, Int, Int, Int), left: Int) -> #(Int, Int, Int, Int) {
  case left {
    0 -> state
    _ -> rounds(sipround(state), left - 1)
  }
}

fn sipround(state: #(Int, Int, Int, Int)) -> #(Int, Int, Int, Int) {
  let #(v0, v1, v2, v3) = state
  let v0 = add(v0, v1)
  let v1 = int.bitwise_exclusive_or(rotl(v1, 13), v0)
  let v0 = rotl(v0, 32)
  let v2 = add(v2, v3)
  let v3 = int.bitwise_exclusive_or(rotl(v3, 16), v2)
  let v0 = add(v0, v3)
  let v3 = int.bitwise_exclusive_or(rotl(v3, 21), v0)
  let v2 = add(v2, v1)
  let v1 = int.bitwise_exclusive_or(rotl(v1, 17), v2)
  #(v0, v1, rotl(v2, 32), v3)
}

fn add(a: Int, b: Int) -> Int {
  int.bitwise_and(a + b, mask)
}

fn rotl(value: Int, bits: Int) -> Int {
  let value = int.bitwise_and(value, mask)
  int.bitwise_and(
    int.bitwise_or(
      int.bitwise_shift_left(value, bits),
      int.bitwise_shift_right(value, 64 - bits),
    ),
    mask,
  )
}

fn le(bytes: BitArray, acc: Int, shift: Int) -> Int {
  case bytes {
    <<byte, rest:bits>> ->
      le(rest, acc + int.bitwise_shift_left(byte, shift), shift + 8)
    _ -> acc
  }
}
