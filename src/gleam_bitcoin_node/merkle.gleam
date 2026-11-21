import gleam/int
import gleam/list
import gleam_bitcoin_node/hash
import gleam_bitcoin_node/tx

pub fn compute_root(hashes: List(BitArray)) -> #(BitArray, Bool) {
  compute(hashes, False)
}

pub fn block_root(txs: List(tx.Tx)) -> #(BitArray, Bool) {
  compute_root(list.map(txs, fn(tx) { tx.txid }))
}

pub fn witness_root(txs: List(tx.Tx)) -> BitArray {
  case txs {
    [] -> <<0:size(256)>>
    [_, ..rest] -> {
      let hashes = [<<0:size(256)>>, ..list.map(rest, fn(tx) { tx.wtxid })]
      let #(root, _) = compute_root(hashes)
      root
    }
  }
}

fn compute(hashes: List(BitArray), mutated: Bool) -> #(BitArray, Bool) {
  case hashes {
    [] -> #(<<0:size(256)>>, mutated)
    [root] -> #(root, mutated)
    _ -> {
      let mutated = mutated || equal_pair(hashes)
      let hashes = case int.bitwise_and(list.length(hashes), 1) {
        1 -> list.append(hashes, [last(hashes)])
        _ -> hashes
      }
      compute(pair_up(hashes, []), mutated)
    }
  }
}

fn equal_pair(hashes: List(BitArray)) -> Bool {
  case hashes {
    [a, b, ..rest] -> a == b || equal_pair(rest)
    _ -> False
  }
}

fn pair_up(hashes: List(BitArray), acc: List(BitArray)) -> List(BitArray) {
  case hashes {
    [a, b, ..rest] -> pair_up(rest, [hash.hash256(<<a:bits, b:bits>>), ..acc])
    _ -> list.reverse(acc)
  }
}

fn last(hashes: List(BitArray)) -> BitArray {
  let assert Ok(hash) = list.last(hashes)
  hash
}
