import gleam/int
import gleam_bitcoin_node/hash

pub fn check(header: BitArray, bits: Int) -> Result(Nil, String) {
  case target(bits) {
    Error(reason) -> Error(reason)
    Ok(limit) -> {
      let digest = hash.little_endian_int(hash.hash256(header))
      case digest <= limit {
        True -> Ok(Nil)
        False -> Error("high-hash")
      }
    }
  }
}

fn target(compact: Int) -> Result(Int, String) {
  let size = int.bitwise_shift_right(compact, 24)
  let word = int.bitwise_and(compact, 0x007fffff)
  case int.bitwise_and(compact, 0x00800000) != 0 {
    True -> Error("high-hash")
    False -> {
      let shifted = case size <= 3 {
        True -> int.bitwise_shift_right(word, 8 * { 3 - size })
        False -> int.bitwise_shift_left(word, 8 * { size - 3 })
      }
      case overflow(word, size) || shifted > pow_limit() {
        True -> Error("high-hash")
        False -> Ok(shifted)
      }
    }
  }
}

fn overflow(word: Int, size: Int) -> Bool {
  word != 0
  && {
    size > 34 || { word > 0xff && size > 33 } || { word > 0xffff && size > 32 }
  }
}

fn pow_limit() -> Int {
  int.bitwise_shift_left(0x7fffff, 232)
}

fn mask256() -> Int {
  int.bitwise_shift_left(1, 256) - 1
}

pub fn target_of(bits: Int) -> Result(Int, String) {
  let size = int.bitwise_shift_right(bits, 24)
  let word = int.bitwise_and(bits, 0x007fffff)
  let word = case size <= 3 {
    True -> int.bitwise_shift_right(word, 8 * { 3 - size })
    False -> word
  }
  let value = case size <= 3 {
    True -> word
    False ->
      int.bitwise_and(int.bitwise_shift_left(word, 8 * { size - 3 }), mask256())
  }
  let negative = word != 0 && int.bitwise_and(bits, 0x00800000) != 0
  let overflow =
    word != 0
    && {
      size > 34
      || { word > 0xff && size > 33 }
      || { word > 0xffff && size > 32 }
    }
  case negative || overflow {
    True -> Error("high-hash")
    False -> Ok(value)
  }
}

pub fn compact_of(value: Int) -> Int {
  let size = { bit_length(value) + 7 } / 8
  let compact = case size <= 3 {
    True ->
      int.bitwise_and(
        int.bitwise_shift_left(value, 8 * { 3 - size }),
        0xffffffff,
      )
    False ->
      int.bitwise_and(
        int.bitwise_shift_right(value, 8 * { size - 3 }),
        0xffffffff,
      )
  }
  let #(compact, size) = case int.bitwise_and(compact, 0x00800000) != 0 {
    True -> #(int.bitwise_shift_right(compact, 8), size + 1)
    False -> #(compact, size)
  }
  int.bitwise_or(compact, int.bitwise_shift_left(size, 24))
}

pub fn retarget(
  last_bits: Int,
  last_time: Int,
  first_time: Int,
  first_bits: Int,
  no_retarget: Bool,
  bip94: Bool,
  timespan: Int,
  pow_limit: Int,
) -> Int {
  case no_retarget {
    True -> last_bits
    False -> {
      let actual = clamp(last_time - first_time, timespan / 4, timespan * 4)
      let base_bits = case bip94 {
        True -> first_bits
        False -> last_bits
      }
      let assert Ok(base) = target_of(base_bits)
      let new = int.bitwise_and(base * actual, mask256()) / timespan
      let new = case new > pow_limit {
        True -> pow_limit
        False -> new
      }
      compact_of(new)
    }
  }
}

fn clamp(n: Int, lo: Int, hi: Int) -> Int {
  case n < lo {
    True -> lo
    False ->
      case n > hi {
        True -> hi
        False -> n
      }
  }
}

fn bit_length(value: Int) -> Int {
  bit_length_loop(value, 0)
}

fn bit_length_loop(value: Int, n: Int) -> Int {
  case value {
    0 -> n
    _ -> bit_length_loop(int.bitwise_shift_right(value, 1), n + 1)
  }
}
