import gleam/bit_array
import gleam/int
import gleam/list
import gleam/string
import gleam_bitcoin_node
import gleam_bitcoin_node/codec
import gleam_bitcoin_node/hash
import gleeunit
import gleeunit/should

@external(erlang, "gleam_bitcoin_node_ffi", "cmd")
fn cmd(command: String) -> String

@external(erlang, "gleam_bitcoin_node_ffi", "hex_decode")
fn hex_decode(hex: String) -> Result(BitArray, Nil)

pub fn main() {
  gleeunit.main()
}

pub fn regtest_tip_and_reject_test() {
  let chain = gleam_bitcoin_node.new()
  chain |> gleam_bitcoin_node.tip_hex |> should.equal(cli("getblockhash 0"))

  let hashes = mine(20)
  let parent_hashes = list.take(hashes, 19)
  let chain = submit_hashes(chain, parent_hashes)
  let parent = gleam_bitcoin_node.tip_hex(chain)

  let assert Ok(raw) = hex_decode(block_hex(hashes))
  let bad_merkle = regrind(raw, <<0:size(256)>>)
  let assert Error("bad-txnmrklroot") = gleam_bitcoin_node.submit_block(chain, bad_merkle)
  gleam_bitcoin_node.tip_hex(chain) |> should.equal(parent)

  let bad_amount = bump_subsidy(raw)
  let assert Error("bad-cb-amount") = gleam_bitcoin_node.submit_block(chain, bad_amount)
  gleam_bitcoin_node.tip_hex(chain) |> should.equal(parent)

  let chain = submit_hashes(chain, [block_hex_hash(hashes)])
  gleam_bitcoin_node.tip_hex(chain) |> should.equal(cli("getbestblockhash"))
}

fn block_hex_hash(hashes: List(String)) -> String {
  let assert Ok(hash) = list.last(hashes)
  hash
}

fn submit_hashes(chain, hashes) {
  list.fold(hashes, chain, fn(chain, hash) {
    let assert Ok(raw) = hex_decode(block_hex([hash]))
    let assert Ok(chain) = gleam_bitcoin_node.submit_block(chain, raw)
    chain
  })
}

fn block_hex(hashes: List(String)) -> String {
  let assert Ok(hash) = list.last(hashes)
  cli("getblock " <> hash <> " 0")
}

fn mine(n: Int) -> List(String) {
  cli("generatetodescriptor " <> int.to_string(n) <> " \"raw(51)\"")
  |> extract_hashes([])
  |> list.reverse
}

fn extract_hashes(json: String, acc: List(String)) -> List(String) {
  case string.split_once(json, "\"") {
    Error(_) -> acc
    Ok(#(_, rest)) ->
      case string.split_once(rest, "\"") {
        Error(_) -> acc
        Ok(#(item, rest)) ->
          case string.length(item) == 64 {
            True -> extract_hashes(rest, [item, ..acc])
            False -> extract_hashes(rest, acc)
          }
      }
  }
}

fn bump_subsidy(raw: BitArray) -> BitArray {
  let at = find_value(raw, 0)
  let assert Ok(before) = bit_array.slice(raw, 0, at)
  let assert Ok(<<value:64-little, after:bits>>) =
    bit_array.slice(raw, at, bit_array.byte_size(raw) - at)
  let bumped = <<before:bits, { value + 1 }:64-little, after:bits>>
  let assert Ok(parsed) = codec.decode_block(bumped)
  regrind(bumped, parsed.coinbase.txid)
}

fn find_value(raw: BitArray, index: Int) -> Int {
  let assert Ok(window) = bit_array.slice(raw, index, 8)
  case window {
    <<5_000_000_000:64-little>> -> index
    _ -> find_value(raw, index + 1)
  }
}

fn regrind(raw: BitArray, merkle: BitArray) -> BitArray {
  let assert Ok(before) = bit_array.slice(raw, 0, 36)
  let assert Ok(after) = bit_array.slice(raw, 68, bit_array.byte_size(raw) - 68)
  let joined = <<before:bits, merkle:bits, after:bits>>
  let assert Ok(prefix) = bit_array.slice(joined, 0, 76)
  let assert Ok(tail) = bit_array.slice(joined, 80, bit_array.byte_size(joined) - 80)
  <<grind(prefix, 0):bits, tail:bits>>
}

fn grind(prefix: BitArray, nonce: Int) -> BitArray {
  let header = <<prefix:bits, nonce:32-little>>
  let digest = hash.little_endian_int(hash.hash256(header))
  let limit = int.bitwise_shift_left(0x7fffff, 232)
  case digest <= limit {
    True -> header
    False -> grind(prefix, nonce + 1)
  }
}

fn cli(args: String) -> String {
  cmd("bitcoin-cli -regtest -rpcuser=e2e -rpcpassword=e2e " <> args <> " 2>/dev/null")
  |> string.trim
}
