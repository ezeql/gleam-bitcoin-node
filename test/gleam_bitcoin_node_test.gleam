import gleam/bit_array
import gleam/int
import gleam/list
import gleam/string
import gleam_bitcoin_node
import gleam_bitcoin_node/codec
import gleam_bitcoin_node/hash
import gleam_bitcoin_node/merkle
import gleam_bitcoin_node/params
import gleam_bitcoin_node/tx
import gleeunit
import gleeunit/should

@external(erlang, "gleam_bitcoin_node_ffi", "cmd")
fn cmd(command: String) -> String

@external(erlang, "gleam_bitcoin_node_ffi", "hex_decode")
fn hex_decode(hex: String) -> Result(BitArray, Nil)

pub fn main() {
  gleeunit.main()
}

pub fn core_genesis_hashes_test() {
  expect_genesis("", params.mainnet())
  expect_genesis("-testnet", params.testnet())
  expect_genesis("-testnet4", params.testnet4())
  expect_genesis("-signet", params.signet())
  expect_genesis("-regtest", params.regtest())
}

pub fn core_chain_params_test() {
  let zero = string.repeat("0", 64)
  expect_common(params.mainnet(), <<0xf9, 0xbe, 0xb4, 0xd9>>, 8333, 227_931, 388_381, 363_725, 419_328, 481_824, "000000000000024b89b42a942fe0d9fea3bb44ab7bd1b19115dd6a759c0808b8", "000000000000000000000000000000000000000145ec036acc5ba740052af1a0", "00000000000000000000748969ec33043c0e52a763c6dd5193861f559f2c72e3", 1815, 2016, -2)
  expect_common(params.testnet(), <<0x0b, 0x11, 0x09, 0x07>>, 18_333, 21_111, 581_885, 330_776, 770_112, 834_624, "0000000023b3a96d3484e5abb3755c413e7d41500f8e2a5c3f0dd01299cd8ef8", "0000000000000000000000000000000000000000000017f49f702147f10c0eb6", "00000000b318a3703d14a844c55ef507f4c2fc8f8766e24271fd43c180c51637", 1512, 2016, -2)
  expect_common(params.testnet4(), <<0x1c, 0x16, 0x3f, 0x28>>, 48_333, 1, 1, 1, 1, 1, zero, "000000000000000000000000000000000000000000000e346a558455ade8eca9", "0000000021df65b91665a342e26ceb05e54826ad7d8fcd40316230058fa3b865", 1512, 2016, -2)
  expect_common(params.signet(), <<0x0a, 0x03, 0xcf, 0x40>>, 38_333, 1, 1, 1, 1, 1, zero, "00000000000000000000000000000000000000000000000000001090e9dc1520", "00000002a5e0ba0498f1e9f4591af0b66b63c654665efe65206fd0ae7bbaf923", 1815, 2016, -2)
  expect_common(params.regtest(), <<0xfa, 0xbf, 0xb5, 0xda>>, 18_444, 1, 1, 1, 1, 0, zero, zero, zero, 108, 144, 0)

  params.mainnet().signet_blocks |> should.equal(False)
  params.testnet().signet_blocks |> should.equal(False)
  params.testnet4().signet_blocks |> should.equal(False)
  params.regtest().signet_blocks |> should.equal(False)
  params.mainnet().signet_challenge |> should.equal(<<>>)
  params.signet().signet_blocks |> should.equal(True)
  let assert Ok(challenge) =
    hex_decode(
      "512103ad5e0edad18cb1f0fc0d28a3d4f1f3e445640337489abb10404f2d1e086be430210359ef5021964fe22d6f8e05b2463c9540ce96883fe3b278760f048f5189f2e6c452ae",
    )
  params.signet().signet_challenge |> should.equal(challenge)
  params.get(params.Mainnet).genesis_hash
  |> should.equal(params.mainnet().genesis_hash)
}

fn expect_genesis(flag: String, p: params.Params) {
  p.genesis_hash |> should.equal(netcli(flag, "getblockhash 0"))
}

fn expect_common(
  p: params.Params,
  magic: BitArray,
  port: Int,
  bip34: Int,
  bip65: Int,
  bip66: Int,
  csv: Int,
  segwit: Int,
  bip34_hash: String,
  work: String,
  assume: String,
  threshold: Int,
  period: Int,
  start: Int,
) {
  p.magic |> should.equal(magic)
  p.port |> should.equal(port)
  p.bip34_height |> should.equal(bip34)
  p.bip65_height |> should.equal(bip65)
  p.bip66_height |> should.equal(bip66)
  p.csv_height |> should.equal(csv)
  p.segwit_height |> should.equal(segwit)
  p.bip34_hash |> should.equal(bip34_hash)
  p.minimum_chain_work |> should.equal(work)
  p.assume_valid |> should.equal(assume)
  p.testdummy.bit |> should.equal(28)
  p.testdummy.threshold |> should.equal(threshold)
  p.testdummy.period |> should.equal(period)
  p.testdummy.start_time |> should.equal(start)
  p.testdummy.timeout |> should.equal(9_223_372_036_854_775_807)
  p.testdummy.min_activation_height |> should.equal(0)
}

pub fn legacy_tx_roundtrip_test() {
  let raw = <<
    1:32-little,
    1,
    0:size(256),
    0xffffffff:32-little,
    1,
    0x51,
    0xfffffffe:32-little,
    1,
    1000:64-little,
    1,
    0x51,
    7:32-little,
  >>
  let assert Ok(#(decoded, rest)) = tx.decode(raw)
  bit_array.byte_size(rest) |> should.equal(0)
  tx.encode(decoded) |> should.equal(raw)
  decoded.locktime |> should.equal(7)
  decoded.has_witness |> should.equal(False)
  decoded.txid |> should.equal(decoded.wtxid)
  tx.weight(decoded) |> should.equal(bit_array.byte_size(raw) * 4)
}

pub fn superfluous_witness_test() {
  let raw = <<
    2:32-little,
    0,
    1,
    1,
    0:size(256),
    0xffffffff:32-little,
    0,
    0xffffffff:32-little,
    1,
    1:64-little,
    0,
    0,
    0:32-little,
  >>
  tx.decode(raw) |> should.equal(Error("superfluous-witness"))
}

pub fn merkle_root_test() {
  let hash = <<1:size(256)>>
  let #(root, mutated) = merkle.compute_root([hash])
  root |> should.equal(hash)
  mutated |> should.equal(False)
  let #(_, mutated) = merkle.compute_root([hash, hash])
  mutated |> should.equal(True)
  let #(zero, _) = merkle.compute_root([])
  zero |> should.equal(<<0:size(256)>>)
}

pub fn real_tx_roundtrip_test() {
  start_node("/tmp/btc-tx", "18447", "18448")
  tx_cli("createwallet e2e")
  let addr = tx_cli("getnewaddress")
  addr |> should.not_equal("")
  tx_cli("generatetoaddress 101 \"" <> addr <> "\"")
  let sent = tx_cli("sendtoaddress \"" <> addr <> "\" 0.1")
  sent |> should.not_equal("")
  tx_cli("generatetoaddress 1 \"" <> addr <> "\"")

  let tip = tx_cli("getbestblockhash")
  let assert Ok(raw) = hex_decode(tx_cli("getblock " <> tip <> " 0"))
  let assert Ok(block) = tx.decode_block(raw)
  tx.encode_block(block) |> should.equal(raw)
  list.length(block.txs) |> should.not_equal(1)

  let #(root, mutated) = merkle.block_root(block.txs)
  root |> should.equal(block.merkle)
  mutated |> should.equal(False)

  let assert [coinbase, ..] = block.txs
  let assert [input, ..] = coinbase.inputs
  let assert [nonce] = input.witness
  let assert Ok(committed) = commitment(coinbase.outputs)
  hash.hash256(<<merkle.witness_root(block.txs):bits, nonce:bits>>)
  |> should.equal(committed)

  list.each(block.txs, check_tx)
}

fn check_tx(t: tx.Tx) -> Nil {
  let id = hash.display(t.txid)
  let info = tx_cli("getrawtransaction " <> id <> " true")
  json_string(info, "txid") |> should.equal(id)
  json_field(info, "hash") |> should.equal(hash.display(t.wtxid))
  json_int(info, "weight") |> should.equal(tx.weight(t))
  json_int(info, "locktime") |> should.equal(t.locktime)
  let assert Ok(raw_tx) = hex_decode(tx_cli("getrawtransaction " <> id))
  t.raw |> should.equal(raw_tx)
  tx.encode(t) |> should.equal(raw_tx)
}

fn commitment(outputs: List(tx.Output)) -> Result(BitArray, Nil) {
  case outputs {
    [] -> Error(Nil)
    [output, ..rest] ->
      case output.script_pubkey {
        <<0x6a, 0x24, 0xaa, 0x21, 0xa9, 0xed, got:bytes-size(32), _:bits>> -> Ok(got)
        _ -> commitment(rest)
      }
  }
}

fn json_string(json: String, key: String) -> String {
  let assert Ok(#(_, rest)) = string.split_once(json, "\"" <> key <> "\": \"")
  let assert Ok(#(value, _)) = string.split_once(rest, "\"")
  value
}

fn json_field(json: String, key: String) -> String {
  let assert Ok(#(_, rest)) = string.split_once(json, "\n  \"" <> key <> "\": \"")
  let assert Ok(#(value, _)) = string.split_once(rest, "\"")
  value
}

fn json_int(json: String, key: String) -> Int {
  let assert Ok(#(_, rest)) = string.split_once(json, "\"" <> key <> "\": ")
  take_int(rest, "")
}

fn take_int(rest: String, acc: String) -> Int {
  case string.pop_grapheme(rest) {
    Ok(#(digit, rest)) ->
      case string.contains("0123456789", digit) {
        True -> take_int(rest, acc <> digit)
        False -> {
          let assert Ok(n) = int.parse(acc)
          n
        }
      }
    Error(_) -> {
      let assert Ok(n) = int.parse(acc)
      n
    }
  }
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
  netcli("-regtest", args)
}

fn netcli(flag: String, args: String) -> String {
  let prefix = case flag {
    "" -> ""
    _ -> flag <> " "
  }
  cmd(
    "bitcoin-cli " <> prefix <> "-rpcuser=e2e -rpcpassword=e2e " <> args <> " 2>/dev/null",
  )
  |> string.trim
}

fn start_node(dir: String, rpc: String, p2p: String) -> Nil {
  let _ = cmd("mkdir -p " <> dir)
  let _ =
    cmd(
      "bitcoind -regtest -datadir="
      <> dir
      <> " -daemonwait -listen=0 -txindex=1 -fallbackfee=0.0002 -rpcuser=e2e -rpcpassword=e2e -rpcport="
      <> rpc
      <> " -port="
      <> p2p,
    )
  Nil
}

fn tx_cli(args: String) -> String {
  node_cli("/tmp/btc-tx", "18447", args)
}

fn node_cli(dir: String, rpc: String, args: String) -> String {
  cmd(
    "bitcoin-cli -regtest -datadir="
    <> dir
    <> " -rpcport="
    <> rpc
    <> " -rpcuser=e2e -rpcpassword=e2e "
    <> args
    <> " 2>&1",
  )
  |> string.trim
}
