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
    size > 34
    || { word > 0xff && size > 33 }
    || { word > 0xffff && size > 32 }
  }
}

fn pow_limit() -> Int {
  int.bitwise_shift_left(0x7fffff, 232)
}
