import gleam/bit_array
import gleam/int
import gleam/list
import gleam/string
import gleam_bitcoin_node/address
import gleam_bitcoin_node/hash
import gleam_bitcoin_node/index
import gleam_bitcoin_node/tx

@external(erlang, "gleam_bitcoin_node_esplora", "start")
pub fn start(port: Int) -> Result(Nil, String)

@external(erlang, "gleam_bitcoin_node_esplora", "publish")
pub fn publish(view: index.View) -> Nil

pub fn answer(
  view: index.View,
  method: String,
  path: String,
  body: String,
) -> #(Int, String, String, index.View) {
  let path = case string.split_once(path, "?") {
    Ok(#(path, _)) -> path
    Error(_) -> path
  }
  case method, string.split(path, "/") {
    "GET", ["", "blocks", "tip", "hash"] -> text(view, index.tip(view))
    "GET", ["", "blocks", "tip", "height"] ->
      text(view, int.to_string(index.height(view)))
    "GET", ["", "block", hash] -> block(view, hash)
    "GET", ["", "tx", txid] -> transaction(view, txid)
    "GET", ["", "address", addr] -> stats(view, addr)
    "GET", ["", "address", addr, "utxo"] -> utxo(view, addr)
    "POST", ["", "tx"] -> post_tx(view, body)
    _, _ -> plain(view, 404, "not found")
  }
}

fn text(view: index.View, body: String) -> #(Int, String, String, index.View) {
  #(200, "text/plain", body, view)
}

fn json(view: index.View, body: String) -> #(Int, String, String, index.View) {
  #(200, "application/json", body, view)
}

fn plain(
  view: index.View,
  status: Int,
  body: String,
) -> #(Int, String, String, index.View) {
  #(status, "text/plain", body, view)
}

fn block(view: index.View, hash: String) -> #(Int, String, String, index.View) {
  case index.block(view, hash) {
    Error(_) -> plain(view, 404, "Block not found")
    Ok(saved) ->
      json(
        view,
        "{"
          <> str("id", saved.hash)
          <> ","
          <> num("height", saved.height)
          <> ","
          <> num("timestamp", saved.time)
          <> ","
          <> num("tx_count", list.length(saved.txids))
          <> ","
          <> str("previousblockhash", saved.prev)
          <> "}",
      )
  }
}

fn transaction(
  view: index.View,
  txid: String,
) -> #(Int, String, String, index.View) {
  case index.transaction(view, txid) {
    Error(_) -> plain(view, 404, "Transaction not found")
    Ok(seen) ->
      case index.block_at(view, seen.height) {
        Error(_) -> plain(view, 404, "Transaction not found")
        Ok(saved) ->
          json(
            view,
            "{"
              <> str("txid", txid)
              <> ","
              <> num("version", seen.item.version)
              <> ","
              <> num("locktime", seen.item.locktime)
              <> ",\"status\":{"
              <> "\"confirmed\":true,"
              <> num("block_height", saved.height)
              <> ","
              <> str("block_hash", saved.hash)
              <> ","
              <> num("block_time", saved.time)
              <> "},\"vout\":"
              <> vouts(seen.item.outputs)
              <> "}",
          )
      }
  }
}

fn stats(view: index.View, addr: String) -> #(Int, String, String, index.View) {
  case address.to_script(addr) {
    Error(_) -> plain(view, 400, "Invalid address")
    Ok(_) -> {
      let rows = utxo_rows(view, addr)
      json(
        view,
        "{\"address\":"
          <> quote(addr)
          <> ",\"chain_stats\":"
          <> tally(rows, True)
          <> ",\"mempool_stats\":"
          <> tally(rows, False)
          <> "}",
      )
    }
  }
}

fn utxo(view: index.View, addr: String) -> #(Int, String, String, index.View) {
  case address.to_script(addr) {
    Error(_) -> plain(view, 400, "Invalid address")
    Ok(_) ->
      json(view, "[" <> join(list.map(utxo_rows(view, addr), utxo_json)) <> "]")
  }
}

fn post_tx(
  view: index.View,
  body: String,
) -> #(Int, String, String, index.View) {
  case hash.decode_hex(string.trim(body)) {
    Error(_) -> plain(view, 400, "Invalid transaction hex")
    Ok(raw) ->
      case tx.decode(raw) {
        Error(_) -> plain(view, 400, "Invalid transaction hex")
        Ok(#(item, rest)) ->
          case bit_array.byte_size(rest) {
            0 ->
              case index.accept(view, raw) {
                Error(reason) -> plain(view, 400, reason)
                Ok(view) -> text(view, hash.display(item.txid))
              }
            _ -> plain(view, 400, "Invalid transaction hex")
          }
      }
  }
}

fn utxo_rows(
  view: index.View,
  addr: String,
) -> List(#(String, Int, Int, Int, Bool)) {
  case address.to_script(addr) {
    Error(_) -> []
    Ok(script) -> index.script_utxos(view, script)
  }
}

fn utxo_json(row: #(String, Int, Int, Int, Bool)) -> String {
  let #(txid, vout, value, height, confirmed) = row
  case confirmed {
    False ->
      "{\"txid\":"
      <> quote(txid)
      <> ",\"vout\":"
      <> int.to_string(vout)
      <> ",\"value\":"
      <> int.to_string(value)
      <> ",\"status\":{\"confirmed\":false}}"
    True ->
      "{\"txid\":"
      <> quote(txid)
      <> ",\"vout\":"
      <> int.to_string(vout)
      <> ",\"value\":"
      <> int.to_string(value)
      <> ",\"status\":{\"confirmed\":true,\"block_height\":"
      <> int.to_string(height)
      <> "}}"
  }
}

fn tally(
  rows: List(#(String, Int, Int, Int, Bool)),
  confirmed: Bool,
) -> String {
  let rows = list.filter(rows, fn(row) { row.4 == confirmed })
  let count = list.length(rows)
  let sum = list.fold(rows, 0, fn(sum, row) { sum + row.2 })
  "{\"funded_txo_count\":"
  <> int.to_string(count)
  <> ",\"funded_txo_sum\":"
  <> int.to_string(sum)
  <> ",\"spent_txo_count\":0,\"spent_txo_sum\":0,\"tx_count\":"
  <> int.to_string(count)
  <> "}"
}

fn vouts(outputs: List(tx.Output)) -> String {
  "["
  <> join(
    list.index_map(outputs, fn(output, index) {
      "{\"n\":"
      <> int.to_string(index)
      <> ",\"value\":"
      <> int.to_string(output.value)
      <> ",\"scriptpubkey\":"
      <> quote(hash.encode_hex(output.script_pubkey))
      <> "}"
    }),
  )
  <> "]"
}

fn str(key: String, value: String) -> String {
  quote(key) <> ":" <> quote(value)
}

fn num(key: String, value: Int) -> String {
  quote(key) <> ":" <> int.to_string(value)
}

fn quote(value: String) -> String {
  "\"" <> value <> "\""
}

fn join(parts: List(String)) -> String {
  case parts {
    [] -> ""
    [one] -> one
    [one, ..rest] -> one <> "," <> join(rest)
  }
}
