import gleam/dict
import gleam/int
import gleam/list
import gleam_bitcoin_node/chain
import gleam_bitcoin_node/consensus
import gleam_bitcoin_node/hash
import gleam_bitcoin_node/mempool
import gleam_bitcoin_node/script
import gleam_bitcoin_node/tx

pub type Event {
  Fund(script: String, height: Int, txid: String, vout: Int, value: Int)
  Spend(script: String, height: Int, txid: String, vout: Int)
}

pub type Saved {
  Saved(height: Int, hash: String, time: Int, prev: String, txids: List(String))
}

pub type Seen {
  Seen(height: Int, item: tx.Tx)
}

pub type View {
  View(
    chain: chain.Chain,
    pool: mempool.Pool,
    events: List(Event),
    blocks: List(Saved),
    txs: List(Seen),
  )
}

pub fn new() -> View {
  View(chain: chain.new(), pool: mempool.new(), events: [], blocks: [], txs: [])
}

pub fn tip(view: View) -> String {
  chain.tip_hex(view.chain)
}

pub fn height(view: View) -> Int {
  view.chain.height
}

pub fn connect(view: View, raw: BitArray) -> Result(View, String) {
  case tx.decode_block(raw) {
    Error(reason) -> Error(reason)
    Ok(block) ->
      case chain.submit_block(view.chain, raw) {
        Error(reason) -> Error(reason)
        Ok(next) -> Ok(record(view, next, block))
      }
  }
}

pub fn disconnect(view: View) -> Result(View, String) {
  let height = view.chain.height
  case chain.disconnect_tip(view.chain) {
    Error(reason) -> Error(reason)
    Ok(chain) ->
      Ok(View(
        chain: chain,
        pool: view.pool,
        events: list.filter(view.events, fn(event) {
          event_height(event) != height
        }),
        blocks: list.filter(view.blocks, fn(block) { block.height != height }),
        txs: list.filter(view.txs, fn(seen) { seen.height != height }),
      ))
  }
}

pub fn accept(view: View, raw: BitArray) -> Result(View, String) {
  case mempool.send_raw(view.chain, view.pool, raw) {
    Error(reason) -> Error(reason)
    Ok(#(pool, _)) -> Ok(View(..view, pool: pool))
  }
}

pub fn script_utxos(
  view: View,
  script: BitArray,
) -> List(#(String, Int, Int, Int, Bool)) {
  let id = script_id(script)
  let #(created, spent) = mempool.relay_outputs(view.pool)
  let confirmed =
    list.fold(view.events, dict.new(), fn(acc, event) {
      case event {
        Fund(script: sid, height: height, txid: txid, vout: vout, value: value)
          if sid == id
        ->
          dict.insert(acc, txid <> ":" <> int.to_string(vout), #(
            height,
            txid,
            vout,
            value,
          ))
        Spend(script: sid, txid: txid, vout: vout, ..) if sid == id ->
          dict.delete(acc, txid <> ":" <> int.to_string(vout))
        _ -> acc
      }
    })
  let confirmed =
    list.filter_map(dict.to_list(confirmed), fn(pair) {
      let #(key, row) = pair
      let #(height, txid, vout, value) = row
      case list.contains(spent, key) {
        True -> Error(Nil)
        False -> Ok(#(txid, vout, value, height, True))
      }
    })
  let pending =
    list.filter_map(created, fn(output) {
      let key = output.txid <> ":" <> int.to_string(output.vout)
      case script_id(output.script) == id && no(list.contains(spent, key)) {
        True -> Ok(#(output.txid, output.vout, output.value, 0, False))
        False -> Error(Nil)
      }
    })
  list.append(confirmed, pending)
}

pub fn block(view: View, hash: String) -> Result(Saved, Nil) {
  list.find(view.blocks, fn(block) { block.hash == hash })
}

pub fn block_at(view: View, height: Int) -> Result(Saved, Nil) {
  list.find(view.blocks, fn(block) { block.height == height })
}

pub fn transaction(view: View, txid: String) -> Result(Seen, Nil) {
  list.find(view.txs, fn(seen) { hash.display(seen.item.txid) == txid })
}

fn record(view: View, next: chain.Chain, block: tx.ParsedBlock) -> View {
  let height = next.height
  let #(prev, time) = header_parts(block.header)
  let txids = list.map(block.txs, fn(item) { hash.display(item.txid) })
  let saved =
    Saved(
      height: height,
      hash: chain.tip_hex(next),
      time: time,
      prev: prev,
      txids: txids,
    )
  let seen = list.map(block.txs, fn(item) { Seen(height: height, item: item) })
  View(
    chain: next,
    pool: view.pool,
    events: list.append(view.events, block_events(view.chain, block, height)),
    blocks: [saved, ..view.blocks],
    txs: list.append(view.txs, seen),
  )
}

fn block_events(
  chain: chain.Chain,
  block: tx.ParsedBlock,
  height: Int,
) -> List(Event) {
  list.fold(block.txs, [], fn(acc, item) {
    spend_inputs(chain, item, height, fund_outputs(item, height, 0, acc))
  })
}

fn fund_outputs(
  item: tx.Tx,
  height: Int,
  index: Int,
  acc: List(Event),
) -> List(Event) {
  case item.outputs {
    [] -> acc
    [output, ..rest] -> {
      let acc = case script.unspendable(output.script_pubkey) {
        True -> acc
        False ->
          list.append(acc, [
            Fund(
              script: script_id(output.script_pubkey),
              height: height,
              txid: hash.display(item.txid),
              vout: index,
              value: output.value,
            ),
          ])
      }
      fund_outputs(tx.Tx(..item, outputs: rest), height, index + 1, acc)
    }
  }
}

fn spend_inputs(
  chain: chain.Chain,
  item: tx.Tx,
  height: Int,
  acc: List(Event),
) -> List(Event) {
  case consensus.is_coinbase(item) {
    True -> acc
    False ->
      list.fold(item.inputs, acc, fn(acc, input) {
        let txid = hash.display(input.prev_hash)
        case find_script(chain, acc, txid, input.prev_index) {
          Error(_) -> acc
          Ok(sid) ->
            list.append(acc, [
              Spend(
                script: sid,
                height: height,
                txid: txid,
                vout: input.prev_index,
              ),
            ])
        }
      })
  }
}

fn find_script(
  chain: chain.Chain,
  events: List(Event),
  txid: String,
  vout: Int,
) -> Result(String, Nil) {
  let key = txid <> ":" <> int.to_string(vout)
  case dict.get(chain.coins, key) {
    Ok(coin) -> Ok(script_id(coin.script))
    Error(_) ->
      case
        list.find(events, fn(event) {
          case event {
            Fund(txid: id, vout: n, ..) -> id == txid && n == vout
            _ -> False
          }
        })
      {
        Ok(Fund(script: sid, ..)) -> Ok(sid)
        _ -> Error(Nil)
      }
  }
}

fn header_parts(header: BitArray) -> #(String, Int) {
  let assert <<
    _:32-little,
    prev:bytes-size(32),
    _:bytes-size(32),
    time:32-little,
    _:32-little,
    _:32-little,
  >> = header
  #(hash.display(prev), time)
}

fn event_height(event: Event) -> Int {
  case event {
    Fund(height: height, ..) -> height
    Spend(height: height, ..) -> height
  }
}

pub fn script_id(script: BitArray) -> String {
  hash.encode_hex(hash.sha256(script))
}

fn no(value: Bool) -> Bool {
  case value {
    True -> False
    False -> True
  }
}
