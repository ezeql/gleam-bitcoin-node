import gleam/bit_array
import gleam/dict
import gleam/int
import gleam/list
import gleam_bitcoin_node/chain
import gleam_bitcoin_node/consensus
import gleam_bitcoin_node/hash
import gleam_bitcoin_node/siphash
import gleam_bitcoin_node/tx

const p = 19

const m = 784_931

const range_mask = 0x7ffff

pub type Index {
  Index(prev: BitArray, entries: List(Entry))
}

pub type Entry {
  Entry(
    hash: BitArray,
    filter: BitArray,
    header: BitArray,
    filter_hash: BitArray,
  )
}

pub fn new() -> Index {
  Index(prev: <<0:size(256)>>, entries: [])
}

pub fn push(
  index: Index,
  chain: chain.Chain,
  raw: BitArray,
) -> Result(Index, String) {
  case tx.decode_block(raw) {
    Error(reason) -> Error(reason)
    Ok(block) -> {
      let block_hash = hash.hash256(block.header)
      let filter =
        basic(
          block_hash,
          output_scripts(block.txs),
          spent_scripts(chain, block.txs),
        )
      let header = header(filter, index.prev)
      Ok(
        Index(prev: header, entries: [
          Entry(
            hash: block_hash,
            filter: filter,
            header: header,
            filter_hash: hash.hash256(filter),
          ),
          ..index.entries
        ]),
      )
    }
  }
}

pub fn get(index: Index, block_hash: BitArray) -> Result(Entry, String) {
  case list.find(index.entries, fn(entry) { entry.hash == block_hash }) {
    Ok(entry) -> Ok(entry)
    Error(_) -> Error("index")
  }
}

pub fn basic(
  block_hash: BitArray,
  outputs: List(BitArray),
  spent: List(BitArray),
) -> BitArray {
  let elements =
    unique(list.append(
      list.filter(outputs, keep_output),
      list.filter(spent, keep_spent),
    ))
  let assert <<k0:64-little, k1:64-little, _:bits>> = block_hash
  encode(elements, k0, k1)
}

pub fn header(filter: BitArray, prev: BitArray) -> BitArray {
  hash.hash256(<<hash.hash256(filter):bits, prev:bits>>)
}

pub fn cfilter(block_hash: BitArray, filter: BitArray) -> BitArray {
  <<
    0,
    block_hash:bits,
    compact(bit_array.byte_size(filter)):bits,
    filter:bits,
  >>
}

pub fn cfheaders(
  stop_hash: BitArray,
  prev_header: BitArray,
  filter_hashes: List(BitArray),
) -> BitArray {
  <<
    0,
    stop_hash:bits,
    prev_header:bits,
    compact(list.length(filter_hashes)):bits,
    concat(filter_hashes):bits,
  >>
}

fn output_scripts(txs: List(tx.Tx)) -> List(BitArray) {
  list.flat_map(txs, fn(item) {
    list.map(item.outputs, fn(output) { output.script_pubkey })
  })
}

fn spent_scripts(chain: chain.Chain, txs: List(tx.Tx)) -> List(BitArray) {
  list.flat_map(txs, fn(item) {
    case consensus.is_coinbase(item) {
      True -> []
      False ->
        list.filter_map(item.inputs, fn(input) {
          let key =
            hash.display(input.prev_hash)
            <> ":"
            <> int.to_string(input.prev_index)
          case dict.get(chain.coins, key) {
            Ok(coin) ->
              case coin.script {
                <<>> -> Error(Nil)
                script -> Ok(script)
              }
            Error(_) -> Error(Nil)
          }
        })
    }
  })
}

fn keep_output(script: BitArray) -> Bool {
  case script {
    <<>> -> False
    <<0x6a, _:bits>> -> False
    _ -> True
  }
}

fn keep_spent(script: BitArray) -> Bool {
  case script {
    <<>> -> False
    _ -> True
  }
}

fn encode(elements: List(BitArray), k0: Int, k1: Int) -> BitArray {
  let n = list.length(elements)
  let modulus = n * m
  let values =
    list.sort(
      list.map(elements, fn(element) {
        int.bitwise_shift_right(siphash.hash(k0, k1, element) * modulus, 64)
      }),
      by: int.compare,
    )
  <<compact(n):bits, pad(deltas(values, 0, <<>>)):bits>>
}

fn deltas(values: List(Int), last: Int, acc: BitArray) -> BitArray {
  case values {
    [] -> acc
    [value, ..rest] -> {
      let delta = value - last
      let quotient = int.bitwise_shift_right(delta, p)
      let remainder = int.bitwise_and(delta, range_mask)
      deltas(rest, value, <<unary(acc, quotient):bits, 0:1, remainder:size(p)>>)
    }
  }
}

fn unary(acc: BitArray, count: Int) -> BitArray {
  case count {
    0 -> acc
    _ -> unary(<<acc:bits, 1:1>>, count - 1)
  }
}

fn pad(bits: BitArray) -> BitArray {
  let used = bit_array.bit_size(bits)
  let remainder = used - used / 8 * 8
  pad_zeros(bits, case remainder {
    0 -> 0
    n -> 8 - n
  })
}

fn pad_zeros(bits: BitArray, count: Int) -> BitArray {
  case count {
    0 -> bits
    _ -> pad_zeros(<<bits:bits, 0:1>>, count - 1)
  }
}

fn compact(n: Int) -> BitArray {
  case n < 253 {
    True -> <<n>>
    False ->
      case n < 0x10000 {
        True -> <<253, n:16-little>>
        False -> <<254, n:32-little>>
      }
  }
}

fn unique(items: List(BitArray)) -> List(BitArray) {
  list.fold(items, [], fn(acc, item) {
    case list.contains(acc, item) {
      True -> acc
      False -> [item, ..acc]
    }
  })
}

fn concat(items: List(BitArray)) -> BitArray {
  list.fold(items, <<>>, fn(acc, item) { <<acc:bits, item:bits>> })
}
