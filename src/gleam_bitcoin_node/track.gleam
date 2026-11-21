import gleam/bit_array
import gleam/list
import gleam_bitcoin_node/chain
import gleam_bitcoin_node/compact
import gleam_bitcoin_node/filter
import gleam_bitcoin_node/hash
import gleam_bitcoin_node/mempool
import gleam_bitcoin_node/pow
import gleam_bitcoin_node/tx

pub type Verdict {
  Accepted(String)
  Rejected(String)
}

pub type Manifest {
  Manifest(last_hash: String, count: Int)
}

pub fn shadow(chain: chain.Chain, raw: BitArray) -> #(chain.Chain, Verdict) {
  case chain.submit_block(chain, raw) {
    Ok(next) -> #(next, Accepted(chain.tip_hex(next)))
    Error(reason) -> #(chain, Rejected(reason))
  }
}

pub fn dataset(raws: List(BitArray)) -> #(BitArray, Manifest) {
  let blob =
    list.fold(raws, <<>>, fn(acc, raw) {
      <<acc:bits, bit_array.byte_size(raw):32-little, raw:bits>>
    })
  let last = case list.last(raws) {
    Ok(raw) -> header_hex(raw)
    Error(_) -> ""
  }
  #(blob, Manifest(last_hash: last, count: list.length(raws)))
}

pub fn replay(blob: BitArray) -> Result(chain.Chain, String) {
  case records(blob, []) {
    Error(reason) -> Error(reason)
    Ok(raws) -> list.try_fold(raws, chain.new(), chain.submit_block)
  }
}

pub fn property(
  chain: chain.Chain,
  last: BitArray,
  cmpct: BitArray,
  expected_filter: String,
) -> Result(String, String) {
  case tx.decode_block(last) {
    Error(reason) -> Error(reason)
    Ok(block) ->
      case roundtrip(block) {
        False -> Error("roundtrip")
        True ->
          case retarget_ok(last) {
            False -> Error("retarget")
            True ->
              case reorg(chain, last) {
                Error(reason) -> Error(reason)
                Ok(chain) ->
                  case filter_ok(chain, last, expected_filter) {
                    Error(reason) -> Error(reason)
                    Ok(_) ->
                      case compact_ok(cmpct, chain) {
                        Error(reason) -> Error(reason)
                        Ok(_) -> mempool_ok(chain)
                      }
                  }
              }
          }
      }
  }
}

fn roundtrip(block: tx.ParsedBlock) -> Bool {
  case tx.encode_block(block) {
    <<header:bytes-size(80), _:bits>> ->
      hash.hash256(header) == hash.hash256(block.header)
    _ -> False
  }
}

fn retarget_ok(raw: BitArray) -> Bool {
  case raw {
    <<
      _:32-little,
      _:bytes-size(32),
      _:bytes-size(32),
      _:32-little,
      bits:32-little,
      _:bits,
    >> -> pow.retarget(bits, 1, 0, bits, True, False, 1_209_600, 1) == bits
    _ -> False
  }
}

fn reorg(chain: chain.Chain, last: BitArray) -> Result(chain.Chain, String) {
  let tip = chain.tip_hex(chain)
  case chain.disconnect_tip(chain) {
    Error(reason) -> Error(reason)
    Ok(back) ->
      case chain.submit_block(back, last) {
        Error(reason) -> Error(reason)
        Ok(chain) ->
          case chain.tip_hex(chain) == tip {
            True -> Ok(chain)
            False -> Error("reorg")
          }
      }
  }
}

fn filter_ok(
  chain: chain.Chain,
  last: BitArray,
  expected: String,
) -> Result(Nil, String) {
  case filter.push(filter.new(), chain, last) {
    Error(reason) -> Error(reason)
    Ok(index) ->
      case index.entries {
        [entry, ..] ->
          case hash.encode_hex(entry.filter) == expected {
            True -> Ok(Nil)
            False -> Error("filter")
          }
        _ -> Error("filter")
      }
  }
}

fn compact_ok(cmpct: BitArray, chain: chain.Chain) -> Result(Nil, String) {
  case compact.reconstruct(cmpct) {
    Error(reason) -> Error(reason)
    Ok(raw) ->
      case header_hex(raw) == chain.tip_hex(chain) {
        True -> Ok(Nil)
        False -> Error("compact")
      }
  }
}

fn mempool_ok(chain: chain.Chain) -> Result(String, String) {
  case mempool.test_package(chain, mempool.new(), []) {
    Error("package-empty") -> Ok(chain.tip_hex(chain))
    Error(reason) -> Error(reason)
    Ok(_) -> Error("mempool")
  }
}

fn records(
  blob: BitArray,
  acc: List(BitArray),
) -> Result(List(BitArray), String) {
  case blob {
    <<>> -> Ok(list.reverse(acc))
    <<len:32-little, rest:bits>> ->
      case
        bit_array.slice(rest, 0, len),
        bit_array.slice(rest, len, bit_array.byte_size(rest) - len)
      {
        Ok(raw), Ok(rest) -> records(rest, [raw, ..acc])
        _, _ -> Error("truncated")
      }
    _ -> Error("truncated")
  }
}

fn header_hex(raw: BitArray) -> String {
  case bit_array.slice(raw, 0, 80) {
    Ok(header) -> hash.display(hash.hash256(header))
    Error(_) -> ""
  }
}
