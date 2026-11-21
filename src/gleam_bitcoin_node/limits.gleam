import gleam/bit_array
import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order.{type Order, Eq, Gt, Lt}
import gleam_bitcoin_node/hash

// Core v32.1 net.h / protocol.h caps. A breach disconnects the peer.
const max_message_length = 4_000_000

const max_receive_buffer = 5_000_000

const max_inv = 50_000

const max_addr = 1000

const max_headers = 2000

const send_buffer_bytes = 1_000_000

const timeout_interval_s = 1200

const decode_min = 65_536

const stall_default_ms = 2000

const stall_max_ms = 64_000

const max_orphans = 1000

const orphan_peer_weight = 404_000

const max_orphan_score = 3000

pub type Peer {
  Peer(
    id: String,
    connected: Int,
    min_ping: Option(Int),
    last_block_time: Int,
    last_tx_time: Int,
    relevant_services: Bool,
    relay_txs: Bool,
    bloom_filter: Bool,
    keyed_netgroup: Int,
    prefer_evict: Bool,
    is_local: Bool,
    network: String,
    noban: Bool,
    conn_type: String,
  )
}

pub type Budget {
  Budget(total: Int, available: Int, held: List(#(String, Int)))
}

pub type Stalls {
  Stalls(timeout_ms: Int, marks: List(#(String, Int)))
}

pub type Ann {
  Ann(peer: String, seq: Int)
}

pub type Orphan {
  Orphan(id: String, weight: Int, inputs: Int, seq: Int, anns: List(Ann))
}

pub type House {
  House(items: List(Orphan), seq: Int)
}

type Step {
  NeedMore(BitArray)
  Skip(BitArray)
  Message(String, BitArray)
}

type Net {
  Net(local: Bool, id: String, count: Int)
}

pub fn candidate(id: String) -> Peer {
  Peer(
    id: id,
    connected: 0,
    min_ping: Some(1),
    last_block_time: 0,
    last_tx_time: 0,
    relevant_services: False,
    relay_txs: True,
    bloom_filter: False,
    keyed_netgroup: 0,
    prefer_evict: False,
    is_local: False,
    network: "ipv4",
    noban: False,
    conn_type: "inbound",
  )
}

pub fn recv_flood(available: Int) -> Bool {
  available > max_receive_buffer
}

pub fn absorb(
  magic: BitArray,
  buf: BitArray,
) -> Result(#(BitArray, List(String)), String) {
  take_all(magic, buf, [])
}

pub fn command_limit(
  command: String,
  payload: BitArray,
) -> Result(Nil, String) {
  case command {
    "inv" | "getdata" -> vector_limit(payload, 36, max_inv, "inv-too-large")
    "addr" -> vector_limit(payload, 30, max_addr, "addr-too-large")
    "headers" -> header_count(payload)
    _ -> Ok(Nil)
  }
}

pub fn new_budget(total: Int) -> Budget {
  Budget(total: total, available: total, held: [])
}

pub fn charge(
  budget: Budget,
  peer: String,
  bytes: Int,
) -> Result(Budget, String) {
  case bytes < decode_min {
    True -> Ok(budget)
    False -> {
      let n = int.min(bytes, budget.total)
      case budget.available >= n {
        True ->
          Ok(
            Budget(total: budget.total, available: budget.available - n, held: [
              #(peer, n),
              ..budget.held
            ]),
          )
        False -> Error("decode-budget")
      }
    }
  }
}

pub fn release(budget: Budget, peer: String) -> Budget {
  case list.key_pop(budget.held, peer) {
    Ok(#(n, rest)) ->
      Budget(..budget, available: budget.available + n, held: rest)
    Error(_) -> budget
  }
}

pub fn new_stalls() -> Stalls {
  Stalls(timeout_ms: stall_default_ms, marks: [])
}

pub fn mark_stall(stalls: Stalls, peer: String, now: Int) -> Stalls {
  case list.key_find(stalls.marks, peer) {
    Ok(_) -> stalls
    Error(_) -> Stalls(..stalls, marks: [#(peer, now), ..stalls.marks])
  }
}

pub fn clear_stall(stalls: Stalls, peer: String) -> Stalls {
  Stalls(
    ..stalls,
    marks: list.filter(stalls.marks, fn(mark) { mark.0 != peer }),
  )
}

pub fn take_stalls(stalls: Stalls, now: Int) -> #(Stalls, List(String)) {
  let #(due, left) =
    list.partition(stalls.marks, fn(mark) { now - mark.1 > stalls.timeout_ms })
  let ids = list.map(due, fn(mark) { mark.0 })
  #(Stalls(timeout_ms: bump(stalls.timeout_ms, ids), marks: left), ids)
}

pub fn decay_stall(stalls: Stalls) -> Stalls {
  Stalls(
    ..stalls,
    timeout_ms: int.max(stalls.timeout_ms * 85 / 100, stall_default_ms),
  )
}

pub fn send_buffer(
  queued: Int,
  paused_since: Int,
  now: Int,
) -> Result(Int, String) {
  case queued > send_buffer_bytes {
    False -> Ok(-1)
    True ->
      case paused_since < 0 {
        True -> Ok(now)
        False ->
          case now > paused_since + timeout_interval_s {
            True -> Error("send-buffer")
            False -> Ok(paused_since)
          }
      }
  }
}

pub fn new_house() -> House {
  House(items: [], seq: 0)
}

pub fn park(
  house: House,
  id: String,
  weight: Int,
  inputs: Int,
  peer: String,
) -> House {
  limit(add_orphan(house, id, weight, inputs, peer))
}

pub fn orphan_count(house: House) -> Int {
  list.length(house.items)
}

pub fn orphan_ids(house: House) -> List(String) {
  list.map(list.sort(house.items, by: cmp_orphan), fn(item) { item.id })
}

pub fn select(peers: List(Peer)) -> Result(String, Nil) {
  let cs =
    peers
    |> list.filter(fn(peer) { no(peer.noban) })
    |> list.filter(fn(peer) { peer.conn_type == "inbound" })
    |> erase_last(cmp_netgroup, 4, fn(_) { True })
    |> erase_last(cmp_ping, 8, fn(_) { True })
    |> erase_last(cmp_tx, 4, fn(_) { True })
    |> erase_last(cmp_block_relay, 8, fn(peer) {
      no(peer.relay_txs) && peer.relevant_services
    })
    |> erase_last(cmp_block, 4, fn(_) { True })
    |> protect_ratio
  case cs {
    [] -> Error(Nil)
    _ -> {
      let cs = case list.any(cs, fn(peer) { peer.prefer_evict }) {
        True -> list.filter(cs, fn(peer) { peer.prefer_evict })
        False -> cs
      }
      let group = most_group(cs)
      case list.find(cs, fn(peer) { peer.keyed_netgroup == group }) {
        Ok(peer) -> Ok(peer.id)
        Error(_) -> Error(Nil)
      }
    }
  }
}

fn take_all(
  magic: BitArray,
  buf: BitArray,
  cmds: List(String),
) -> Result(#(BitArray, List(String)), String) {
  case step(magic, buf) {
    Error(reason) -> Error(reason)
    Ok(NeedMore(rest)) -> Ok(#(rest, list.reverse(cmds)))
    Ok(Skip(rest)) -> take_all(magic, rest, cmds)
    Ok(Message(cmd, rest)) -> take_all(magic, rest, [cmd, ..cmds])
  }
}

fn step(magic: BitArray, buf: BitArray) -> Result(Step, String) {
  case bit_array.byte_size(buf) < 24 {
    True -> prefix(magic, buf)
    False -> header(magic, buf)
  }
}

fn prefix(magic: BitArray, buf: BitArray) -> Result(Step, String) {
  let n = int.min(4, bit_array.byte_size(buf))
  case bit_array.slice(magic, 0, n), bit_array.slice(buf, 0, n) {
    Ok(want), Ok(got) ->
      case want == got {
        True -> Ok(NeedMore(buf))
        False -> Error("bad-magic")
      }
    _, _ -> Error("bad-magic")
  }
}

fn header(magic: BitArray, buf: BitArray) -> Result(Step, String) {
  case buf {
    <<
      got:bytes-size(4),
      cmd:bytes-size(12),
      len:32-little,
      sum:bytes-size(4),
      rest:bits,
    >> ->
      case got == magic {
        False -> Error("bad-magic")
        True ->
          case len > max_message_length {
            True -> Error("oversized")
            False -> body(cmd, len, sum, rest, buf)
          }
      }
    _ -> Error("bad-magic")
  }
}

fn body(
  cmd: BitArray,
  len: Int,
  sum: BitArray,
  rest: BitArray,
  buf: BitArray,
) -> Result(Step, String) {
  case bit_array.byte_size(rest) < len {
    True ->
      case recv_flood(bit_array.byte_size(buf)) {
        True -> Error("receive-buffer")
        False -> Ok(NeedMore(buf))
      }
    False ->
      case
        bit_array.slice(rest, 0, len),
        bit_array.slice(rest, len, bit_array.byte_size(rest) - len)
      {
        Ok(payload), Ok(left) ->
          case checksum_ok(sum, payload) {
            False -> Ok(Skip(left))
            True ->
              case command_limit(command_of(cmd), payload) {
                Error(reason) -> Error(reason)
                Ok(_) -> Ok(Message(command_of(cmd), left))
              }
          }
        _, _ -> Error("truncated")
      }
  }
}

fn checksum_ok(sum: BitArray, payload: BitArray) -> Bool {
  case bit_array.slice(hash.hash256(payload), 0, 4) {
    Ok(got) -> got == sum
    Error(_) -> False
  }
}

fn command_of(cmd: BitArray) -> String {
  case bit_array.slice(cmd, 0, command_len(cmd, 0)) {
    Ok(bytes) ->
      case bit_array.to_string(bytes) {
        Ok(name) -> name
        Error(_) -> ""
      }
    Error(_) -> ""
  }
}

fn command_len(cmd: BitArray, n: Int) -> Int {
  case cmd {
    <<0, _:bits>> -> n
    <<_, rest:bits>> -> command_len(rest, n + 1)
    _ -> n
  }
}

fn header_count(payload: BitArray) -> Result(Nil, String) {
  case compact(payload) {
    Error(_) -> Ok(Nil)
    Ok(#(n, _)) ->
      case n > max_headers {
        True -> Error("headers-too-large")
        False -> Ok(Nil)
      }
  }
}

fn vector_limit(
  payload: BitArray,
  item: Int,
  max: Int,
  reason: String,
) -> Result(Nil, String) {
  case compact(payload) {
    Error(_) -> Ok(Nil)
    Ok(#(n, rest)) ->
      case n > max && bit_array.byte_size(rest) >= n * item {
        True -> Error(reason)
        False -> Ok(Nil)
      }
  }
}

fn compact(rest: BitArray) -> Result(#(Int, BitArray), Nil) {
  case rest {
    <<n, rest:bits>> if n < 253 -> Ok(#(n, rest))
    <<253, n:16-little, rest:bits>> if n >= 253 -> Ok(#(n, rest))
    <<254, n:32-little, rest:bits>> if n >= 0x10000 -> Ok(#(n, rest))
    <<255, n:64-little, rest:bits>> if n >= 0x100000000 -> Ok(#(n, rest))
    _ -> Error(Nil)
  }
}

fn bump(timeout: Int, ids: List(String)) -> Int {
  case ids {
    [] -> timeout
    [_, ..rest] -> bump(int.min(timeout * 2, stall_max_ms), rest)
  }
}

fn add_orphan(
  house: House,
  id: String,
  weight: Int,
  inputs: Int,
  peer: String,
) -> House {
  case list.find(house.items, fn(item) { item.id == id }) {
    Ok(item) ->
      case announced(item, peer) {
        True -> house
        False ->
          House(
            ..house,
            items: replace_orphan(
              house.items,
              Orphan(..item, anns: [Ann(peer: peer, seq: item.seq), ..item.anns]),
            ),
          )
      }
    Error(_) ->
      House(
        items: [
          Orphan(id: id, weight: weight, inputs: inputs, seq: house.seq, anns: [
            Ann(peer: peer, seq: house.seq),
          ]),
          ..house.items
        ],
        seq: house.seq + 1,
      )
  }
}

fn replace_orphan(items: List(Orphan), item: Orphan) -> List(Orphan) {
  list.map(items, fn(cur) {
    case cur.id == item.id {
      True -> item
      False -> cur
    }
  })
}

fn limit(house: House) -> House {
  house
  |> trim_count
  |> trim_weights
  |> trim_score
}

fn trim_count(house: House) -> House {
  case list.length(house.items) > max_orphans {
    True -> trim_count(drop_oldest(house))
    False -> house
  }
}

fn trim_weights(house: House) -> House {
  list.fold(peers_of(house.items), house, trim_peer)
}

fn trim_peer(house: House, peer: String) -> House {
  case peer_weight(house.items, peer) > orphan_peer_weight {
    True -> trim_peer(drop_ann(house, peer), peer)
    False -> house
  }
}

fn trim_score(house: House) -> House {
  case total_score(house) > max_orphan_score {
    False -> house
    True ->
      case hottest(house.items) {
        Error(_) -> house
        Ok(peer) -> {
          let next = drop_ann(house, peer)
          case next == house {
            True -> house
            False -> trim_score(next)
          }
        }
      }
  }
}

fn drop_oldest(house: House) -> House {
  case oldest(house.items, None) {
    None -> house
    Some(id) ->
      House(
        ..house,
        items: list.filter(house.items, fn(item) { item.id != id }),
      )
  }
}

fn oldest(items: List(Orphan), best: Option(Orphan)) -> Option(String) {
  case items {
    [] ->
      case best {
        Some(item) -> Some(item.id)
        None -> None
      }
    [item, ..rest] -> {
      let best = case best {
        None -> Some(item)
        Some(cur) ->
          case item.seq < cur.seq {
            True -> Some(item)
            False -> Some(cur)
          }
      }
      oldest(rest, best)
    }
  }
}

fn drop_ann(house: House, peer: String) -> House {
  case oldest_ann(house.items, peer, None) {
    None -> house
    Some(#(id, seq)) ->
      House(
        ..house,
        items: list.filter_map(house.items, fn(item) {
          case item.id == id {
            False -> Ok(item)
            True -> {
              let anns =
                list.filter(item.anns, fn(ann) {
                  no(ann.peer == peer && ann.seq == seq)
                })
              case anns {
                [] -> Error(Nil)
                _ -> Ok(Orphan(..item, anns: anns))
              }
            }
          }
        }),
      )
  }
}

fn oldest_ann(
  items: List(Orphan),
  peer: String,
  best: Option(#(String, Int)),
) -> Option(#(String, Int)) {
  case items {
    [] -> best
    [item, ..rest] -> {
      let best = case ann_seq(item, peer) {
        None -> best
        Some(seq) ->
          case best {
            None -> Some(#(item.id, seq))
            Some(#(_, old)) ->
              case seq < old {
                True -> Some(#(item.id, seq))
                False -> best
              }
          }
      }
      oldest_ann(rest, peer, best)
    }
  }
}

fn ann_seq(item: Orphan, peer: String) -> Option(Int) {
  case list.find(item.anns, fn(ann) { ann.peer == peer }) {
    Ok(ann) -> Some(ann.seq)
    Error(_) -> None
  }
}

fn announced(item: Orphan, peer: String) -> Bool {
  list.any(item.anns, fn(ann) { ann.peer == peer })
}

fn peers_of(items: List(Orphan)) -> List(String) {
  list.fold(items, [], fn(acc, item) {
    list.fold(item.anns, acc, fn(acc, ann) {
      case list.contains(acc, ann.peer) {
        True -> acc
        False -> [ann.peer, ..acc]
      }
    })
  })
}

fn peer_weight(items: List(Orphan), peer: String) -> Int {
  list.fold(items, 0, fn(sum, item) {
    case announced(item, peer) {
      True -> sum + item.weight
      False -> sum
    }
  })
}

fn peer_score(items: List(Orphan), peer: String) -> Int {
  list.fold(items, 0, fn(sum, item) {
    case announced(item, peer) {
      True -> sum + 1 + item.inputs / 10
      False -> sum
    }
  })
}

fn total_score(house: House) -> Int {
  list.fold(house.items, 0, fn(sum, item) {
    sum + item.inputs / 10 + list.length(item.anns)
  })
}

fn hottest(items: List(Orphan)) -> Result(String, Nil) {
  case peers_of(items) {
    [] -> Error(Nil)
    [first, ..rest] ->
      Ok(hottest_of(rest, first, peer_score(items, first), items))
  }
}

fn hottest_of(
  peers: List(String),
  best: String,
  best_score: Int,
  items: List(Orphan),
) -> String {
  case peers {
    [] -> best
    [peer, ..rest] -> {
      let score = peer_score(items, peer)
      case score > best_score {
        True -> hottest_of(rest, peer, score, items)
        False -> hottest_of(rest, best, best_score, items)
      }
    }
  }
}

fn cmp_orphan(a: Orphan, b: Orphan) -> Order {
  int.compare(a.seq, b.seq)
}

fn erase_last(
  peers: List(Peer),
  compare: fn(Peer, Peer) -> Order,
  k: Int,
  pred: fn(Peer) -> Bool,
) -> List(Peer) {
  let sorted = list.sort(peers, by: compare)
  let #(head, tail) =
    list.split(sorted, at: int.max(list.length(sorted) - k, 0))
  list.append(head, list.filter(tail, fn(peer) { no(pred(peer)) }))
}

fn protect_ratio(peers: List(Peer)) -> List(Peer) {
  let total = list.length(peers) / 2
  let #(peers, protected) =
    protect_networks(peers, counted(peers), total / 2, 0)
  erase_last(peers, cmp_connected, int.max(total - protected, 0), fn(_) { True })
}

fn counted(peers: List(Peer)) -> List(Net) {
  let networks = [
    Net(local: False, id: "cjdns", count: 0),
    Net(local: False, id: "i2p", count: 0),
    Net(local: True, id: "", count: 0),
    Net(local: False, id: "onion", count: 0),
  ]
  list.sort(
    list.map(networks, fn(net) { Net(..net, count: count_net(peers, net)) }),
    by: fn(a, b) { int.compare(a.count, b.count) },
  )
}

fn count_net(peers: List(Peer), net: Net) -> Int {
  list.length(list.filter(peers, fn(peer) { on_net(peer, net) }))
}

fn protect_networks(
  peers: List(Peer),
  networks: List(Net),
  max: Int,
  protected: Int,
) -> #(List(Peer), Int) {
  case protected >= max {
    True -> #(peers, protected)
    False ->
      case count_positive(networks) {
        0 -> #(peers, protected)
        num -> {
          let per = int.max({ max - protected } / num, 1)
          let before = protected
          let #(peers, networks, protected) =
            protect_round(peers, networks, per, max, before, [])
          case protected == before {
            True -> #(peers, protected)
            False -> protect_networks(peers, networks, max, protected)
          }
        }
      }
  }
}

fn count_positive(networks: List(Net)) -> Int {
  list.length(list.filter(networks, fn(net) { net.count > 0 }))
}

fn protect_round(
  peers: List(Peer),
  networks: List(Net),
  per: Int,
  max: Int,
  protected: Int,
  done: List(Net),
) -> #(List(Peer), List(Net), Int) {
  case networks {
    [] -> #(peers, list.reverse(done), protected)
    [net, ..rest] ->
      case net.count {
        0 -> protect_round(peers, rest, per, max, protected, [net, ..done])
        _ -> {
          let left =
            erase_last(peers, cmp_network(net.local, net.id), per, fn(peer) {
              on_net(peer, net)
            })
          let delta = list.length(peers) - list.length(left)
          case protected + delta >= max {
            True -> #(left, [], protected + delta)
            False ->
              protect_round(left, rest, per, max, protected + delta, [
                Net(..net, count: net.count - delta),
                ..done
              ])
          }
        }
      }
  }
}

fn on_net(peer: Peer, net: Net) -> Bool {
  case net.local {
    True -> peer.is_local
    False -> peer.network == net.id
  }
}

fn most_group(peers: List(Peer)) -> Int {
  let groups: dict.Dict(Int, #(Int, Int)) = dict.new()
  let #(_, #(_, group)) =
    list.fold(peers, #(groups, #(#(0, -1), -1)), fn(state, peer) {
      let #(groups, best) = state
      let #(best_score, _) = best
      let #(size, time) = case dict.get(groups, peer.keyed_netgroup) {
        Ok(pair) -> pair
        Error(_) -> #(0, peer.connected)
      }
      let score = #(size + 1, time)
      let best = case score_gt(score, best_score) {
        True -> #(score, peer.keyed_netgroup)
        False -> best
      }
      #(dict.insert(groups, peer.keyed_netgroup, score), best)
    })
  group
}

fn score_gt(a: #(Int, Int), b: #(Int, Int)) -> Bool {
  let #(a_size, a_time) = a
  let #(b_size, b_time) = b
  case a_size > b_size {
    True -> True
    False -> a_size == b_size && a_time > b_time
  }
}

fn cmp_netgroup(a: Peer, b: Peer) -> Order {
  int.compare(a.keyed_netgroup, b.keyed_netgroup)
}

fn cmp_ping(a: Peer, b: Peer) -> Order {
  case a.min_ping, b.min_ping {
    None, None -> Eq
    None, Some(_) -> Lt
    Some(_), None -> Gt
    Some(left), Some(right) -> int.compare(right, left)
  }
}

fn cmp_tx(a: Peer, b: Peer) -> Order {
  chain([
    int.compare(a.last_tx_time, b.last_tx_time),
    cmp_bool(a.relay_txs, b.relay_txs),
    cmp_bool(no(a.bloom_filter), no(b.bloom_filter)),
    int.compare(-a.connected, -b.connected),
  ])
}

fn cmp_block(a: Peer, b: Peer) -> Order {
  chain([
    int.compare(a.last_block_time, b.last_block_time),
    cmp_bool(a.relevant_services, b.relevant_services),
    int.compare(-a.connected, -b.connected),
  ])
}

fn cmp_block_relay(a: Peer, b: Peer) -> Order {
  chain([
    cmp_bool(no(a.relay_txs), no(b.relay_txs)),
    int.compare(a.last_block_time, b.last_block_time),
    cmp_bool(a.relevant_services, b.relevant_services),
    int.compare(-a.connected, -b.connected),
  ])
}

fn cmp_connected(a: Peer, b: Peer) -> Order {
  int.compare(b.connected, a.connected)
}

fn cmp_network(local: Bool, net: String) -> fn(Peer, Peer) -> Order {
  fn(a: Peer, b: Peer) {
    chain([
      cmp_bool(local && a.is_local, local && b.is_local),
      cmp_bool(a.network == net, b.network == net),
      int.compare(-a.connected, -b.connected),
    ])
  }
}

fn chain(orders: List(Order)) -> Order {
  case orders {
    [] -> Eq
    [Eq, ..rest] -> chain(rest)
    [order, ..] -> order
  }
}

fn cmp_bool(a: Bool, b: Bool) -> Order {
  case a, b {
    False, True -> Lt
    True, False -> Gt
    _, _ -> Eq
  }
}

fn no(value: Bool) -> Bool {
  case value {
    True -> False
    False -> True
  }
}
