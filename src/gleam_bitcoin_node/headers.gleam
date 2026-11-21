import gleam/int
import gleam/list
import gleam_bitcoin_node/hash
import gleam_bitcoin_node/params
import gleam_bitcoin_node/pow

@external(erlang, "gleam_bitcoin_node_ffi", "hex_decode")
fn hex_decode(hex: String) -> Result(BitArray, Nil)

const max_future = 7200

const max_timewarp = 600

const regtest_genesis = "0100000000000000000000000000000000000000000000000000000000000000000000003ba3edfd7a7b12b27ac72c3e67768f617fc81bc3888a51323a9fb8aa4b1e5e4adae5494dffff7f2002000000"

pub type Header {
  Header(
    raw: BitArray,
    hash: BitArray,
    version: Int,
    prev: BitArray,
    time: Int,
    bits: Int,
  )
}

pub type Entry {
  Entry(hash: BitArray, height: Int, time: Int, bits: Int, version: Int)
}

pub type Chain {
  Chain(params: params.Params, entries: List(Entry))
}

pub fn regtest() -> Chain {
  let assert Ok(header) = decode_hex(regtest_genesis)
  Chain(params.regtest(), [entry(header, 0)])
}

pub fn regtest_genesis_entry() -> Entry {
  let assert Ok(header) = decode_hex(regtest_genesis)
  entry(header, 0)
}

pub fn tip_hex(chain: Chain) -> String {
  hash.display(tip(chain).hash)
}

pub fn submit(chain: Chain, raw: BitArray, now: Int) -> Result(Chain, String) {
  case decode(raw) {
    Error(reason) -> Error(reason)
    Ok(header) -> submit_header(chain, header, now)
  }
}

pub fn submit_header(chain: Chain, header: Header, now: Int) -> Result(Chain, String) {
  let limit = pow_limit(chain.params)
  case pow.target_of(header.bits) {
    Error(reason) -> Error(reason)
    Ok(target) ->
      case target == 0 || target > limit {
        True -> Error("high-hash")
        False ->
          case hash.little_endian_int(header.hash) <= target {
            False -> Error("high-hash")
            True ->
              case header.prev == tip(chain).hash {
                False -> Error("prev-blk-not-found")
                True ->
                  case contextual(chain.params, chain.entries, tip(chain), header, now) {
                    Error(reason) -> Error(reason)
                    Ok(_) ->
                      Ok(Chain(
                        chain.params,
                        list.append(chain.entries, [entry(header, tip(chain).height + 1)]),
                      ))
                  }
              }
          }
      }
  }
}

pub fn contextual(
  p: params.Params,
  entries: List(Entry),
  prev: Entry,
  header: Header,
  now: Int,
) -> Result(Nil, String) {
  let height = prev.height + 1
  let interval = p.pow_target_timespan / p.pow_target_spacing
  let expected = next_bits(p, entries, prev, header.time)
  case header.bits == expected {
    False -> Error("bad-diffbits")
    True ->
      case header.time <= median_time(entries, prev.height) {
        True -> Error("time-too-old")
        False ->
          case p.enforce_bip94
            && rem(height, interval) == 0
            && header.time < prev.time - max_timewarp
          {
            True -> Error("time-timewarp-attack")
            False ->
              case header.time > now + max_future {
                True -> Error("time-too-new")
                False ->
                  case version_ok(p, height, header.version) {
                    False -> Error("bad-version(0x" <> hex8(header.version) <> ")")
                    True -> Ok(Nil)
                  }
              }
          }
      }
  }
}

pub fn next_bits(p: params.Params, entries: List(Entry), prev: Entry, block_time: Int) -> Int {
  let interval = p.pow_target_timespan / p.pow_target_spacing
  let limit = pow.compact_of(pow_limit(p))
  let height = prev.height + 1
  case rem(height, interval) != 0 {
    True ->
      case p.pow_allow_min_difficulty {
        False -> prev.bits
        True ->
          case block_time > prev.time + p.pow_target_spacing * 2 {
            True -> limit
            False -> walk_back(entries, prev, interval, limit).bits
          }
      }
    False -> {
      let first = at(entries, prev.height - { interval - 1 })
      pow.retarget(
        prev.bits,
        prev.time,
        first.time,
        first.bits,
        p.pow_no_retargeting,
        p.enforce_bip94,
        p.pow_target_timespan,
        pow_limit(p),
      )
    }
  }
}

pub fn decode(raw: BitArray) -> Result(Header, String) {
  case raw {
    <<version:32-little, prev:bytes-size(32), _:bytes-size(32), time:32-little, bits:32-little, _:32-little>> ->
      Ok(Header(raw, hash.hash256(raw), version, prev, time, bits))
    _ -> Error("truncated")
  }
}

fn decode_hex(hex: String) -> Result(Header, String) {
  case hex_decode(hex) {
    Error(_) -> Error("truncated")
    Ok(raw) -> decode(raw)
  }
}

fn entry(header: Header, height: Int) -> Entry {
  Entry(header.hash, height, header.time, header.bits, header.version)
}

fn tip(chain: Chain) -> Entry {
  let assert Ok(entry) = list.last(chain.entries)
  entry
}

fn pow_limit(p: params.Params) -> Int {
  let assert Ok(limit) = pow.target_of(p.pow_limit_bits)
  limit
}

fn version_ok(p: params.Params, height: Int, version: Int) -> Bool {
  case version < 2 && height >= p.bip34_height {
    True -> False
    False ->
      case version < 3 && height >= p.bip66_height {
        True -> False
        False ->
          case version < 4 && height >= p.bip65_height {
            True -> False
            False -> True
          }
      }
  }
}

fn median_time(entries: List(Entry), height: Int) -> Int {
  median(sort(times_back(entries, height, 11, [])))
}

fn times_back(entries: List(Entry), height: Int, left: Int, acc: List(Int)) -> List(Int) {
  case left == 0 || height < 0 {
    True -> acc
    False -> times_back(entries, height - 1, left - 1, [at(entries, height).time, ..acc])
  }
}

fn median(sorted: List(Int)) -> Int {
  at_int(sorted, list.length(sorted) / 2)
}

fn walk_back(entries: List(Entry), entry: Entry, interval: Int, limit: Int) -> Entry {
  case entry.height == 0 {
    True -> entry
    False ->
      case rem(entry.height, interval) != 0 && entry.bits == limit {
        True -> walk_back(entries, at(entries, entry.height - 1), interval, limit)
        False -> entry
      }
  }
}

fn at(entries: List(Entry), height: Int) -> Entry {
  let assert Ok(entry) = list.find(entries, fn(entry) { entry.height == height })
  entry
}

fn at_int(values: List(Int), index: Int) -> Int {
  case values {
    [] -> 0
    [value, ..rest] ->
      case index {
        0 -> value
        _ -> at_int(rest, index - 1)
      }
  }
}

fn sort(values: List(Int)) -> List(Int) {
  case values {
    [] -> []
    [value, ..rest] -> insert(value, sort(rest))
  }
}

fn insert(value: Int, rest: List(Int)) -> List(Int) {
  case rest {
    [] -> [value]
    [head, ..tail] ->
      case value <= head {
        True -> [value, ..rest]
        False -> [head, ..insert(value, tail)]
      }
  }
}

fn rem(n: Int, d: Int) -> Int {
  n - { n / d } * d
}

fn hex8(n: Int) -> String {
  hex_digits(n, 8, "")
}

fn hex_digits(n: Int, left: Int, acc: String) -> String {
  case left {
    0 -> acc
    _ ->
      hex_digits(
        int.bitwise_shift_right(n, 4),
        left - 1,
        nibble(int.bitwise_and(n, 15)) <> acc,
      )
  }
}

fn nibble(d: Int) -> String {
  case d {
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
