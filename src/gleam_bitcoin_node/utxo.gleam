import gleam/bit_array
import gleam/dict
import gleam/int
import gleam/list
import gleam/string
import gleam_bitcoin_node/consensus
import gleam_bitcoin_node/hash

pub type Stats {
  Stats(
    hash: String,
    txouts: Int,
    transactions: Int,
    bogosize: Int,
    total_amount: Int,
  )
}

pub type Row {
  Row(txid: BitArray, vout: Int, coin: consensus.Coin)
}

pub fn stats(coins: dict.Dict(String, consensus.Coin)) -> Stats {
  let rows = dict.to_list(coins) |> list.map(row) |> sort_rows
  fold(rows, <<>>, 0, 0, 0, 0, <<>>)
}

fn fold(
  rows: List(Row),
  prev: BitArray,
  txouts: Int,
  transactions: Int,
  bogosize: Int,
  total: Int,
  acc: BitArray,
) -> Stats {
  case rows {
    [] ->
      Stats(
        hash: hash.display(hash.hash256(acc)),
        txouts: txouts,
        transactions: transactions,
        bogosize: bogosize,
        total_amount: total,
      )
    [row, ..rest] -> {
      let transactions = case same_txid(prev, row.txid) {
        True -> transactions
        False -> transactions + 1
      }
      let script = row.coin.script
      fold(
        rest,
        row.txid,
        txouts + 1,
        transactions,
        bogosize + 50 + bit_array.byte_size(script),
        total + row.coin.value,
        <<acc:bits, ser(row):bits>>,
      )
    }
  }
}

fn ser(row: Row) -> BitArray {
  let code =
    int.bitwise_shift_left(row.coin.height, 1)
    + case row.coin.coinbase {
      True -> 1
      False -> 0
    }
  <<
    row.txid:bits,
    row.vout:32-little,
    code:32-little,
    row.coin.value:64-little,
    compact(bit_array.byte_size(row.coin.script)):bits,
    row.coin.script:bits,
  >>
}

fn row(pair: #(String, consensus.Coin)) -> Row {
  let #(key, coin) = pair
  let txid_hex = string.slice(key, 0, 64)
  let assert Ok(index) = int.parse(string.drop_start(key, 65))
  let assert Ok(txid) = hash.from_display(txid_hex)
  Row(txid, index, coin)
}

fn same_txid(prev: BitArray, txid: BitArray) -> Bool {
  bit_array.byte_size(prev) == 32 && prev == txid
}

fn sort_rows(rows: List(Row)) -> List(Row) {
  case rows {
    [] -> []
    [row, ..rest] -> insert_row(row, sort_rows(rest))
  }
}

fn insert_row(row: Row, rest: List(Row)) -> List(Row) {
  case rest {
    [] -> [row]
    [head, ..tail] ->
      case before(row, head) {
        True -> [row, ..rest]
        False -> [head, ..insert_row(row, tail)]
      }
  }
}

fn before(a: Row, b: Row) -> Bool {
  case compare(a.txid, b.txid) {
    -1 -> True
    1 -> False
    _ -> a.vout < b.vout
  }
}

fn compare(a: BitArray, b: BitArray) -> Int {
  case a, b {
    <<>>, <<>> -> 0
    <<x, as_:bits>>, <<y, bs:bits>> ->
      case x == y {
        True -> compare(as_, bs)
        False ->
          case x < y {
            True -> -1
            False -> 1
          }
      }
    _, _ -> 0
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
