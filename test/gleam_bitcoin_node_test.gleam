import gleam/bit_array
import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{Some}
import gleam/string
import gleam_bitcoin_node
import gleam_bitcoin_node/address
import gleam_bitcoin_node/chain
import gleam_bitcoin_node/codec
import gleam_bitcoin_node/compact
import gleam_bitcoin_node/consensus
import gleam_bitcoin_node/esplora
import gleam_bitcoin_node/hash
import gleam_bitcoin_node/headers
import gleam_bitcoin_node/index
import gleam_bitcoin_node/kernel
import gleam_bitcoin_node/limits
import gleam_bitcoin_node/mempool
import gleam_bitcoin_node/merkle
import gleam_bitcoin_node/p2p
import gleam_bitcoin_node/params
import gleam_bitcoin_node/pow
import gleam_bitcoin_node/script
import gleam_bitcoin_node/tx
import gleeunit
import gleeunit/should

@external(erlang, "gleam_bitcoin_node_ffi", "cmd")
fn cmd(command: String) -> String

@external(erlang, "gleam_bitcoin_node_ffi", "hex_decode")
fn hex_decode(hex: String) -> Result(BitArray, Nil)

@external(erlang, "gleam_bitcoin_node_ffi", "hex_encode")
fn hex_encode(data: BitArray) -> String

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
  expect_common(
    params.mainnet(),
    <<0xf9, 0xbe, 0xb4, 0xd9>>,
    8333,
    227_931,
    388_381,
    363_725,
    419_328,
    481_824,
    "000000000000024b89b42a942fe0d9fea3bb44ab7bd1b19115dd6a759c0808b8",
    "000000000000000000000000000000000000000145ec036acc5ba740052af1a0",
    "00000000000000000000748969ec33043c0e52a763c6dd5193861f559f2c72e3",
    1815,
    2016,
    -2,
  )
  expect_common(
    params.testnet(),
    <<0x0b, 0x11, 0x09, 0x07>>,
    18_333,
    21_111,
    581_885,
    330_776,
    770_112,
    834_624,
    "0000000023b3a96d3484e5abb3755c413e7d41500f8e2a5c3f0dd01299cd8ef8",
    "0000000000000000000000000000000000000000000017f49f702147f10c0eb6",
    "00000000b318a3703d14a844c55ef507f4c2fc8f8766e24271fd43c180c51637",
    1512,
    2016,
    -2,
  )
  expect_common(
    params.testnet4(),
    <<0x1c, 0x16, 0x3f, 0x28>>,
    48_333,
    1,
    1,
    1,
    1,
    1,
    zero,
    "000000000000000000000000000000000000000000000e346a558455ade8eca9",
    "0000000021df65b91665a342e26ceb05e54826ad7d8fcd40316230058fa3b865",
    1512,
    2016,
    -2,
  )
  expect_common(
    params.signet(),
    <<0x0a, 0x03, 0xcf, 0x40>>,
    38_333,
    1,
    1,
    1,
    1,
    1,
    zero,
    "00000000000000000000000000000000000000000000000000001090e9dc1520",
    "00000002a5e0ba0498f1e9f4591af0b66b63c654665efe65206fd0ae7bbaf923",
    1815,
    2016,
    -2,
  )
  expect_common(
    params.regtest(),
    <<0xfa, 0xbf, 0xb5, 0xda>>,
    18_444,
    1,
    1,
    1,
    1,
    0,
    zero,
    zero,
    zero,
    108,
    144,
    0,
  )

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
        <<0x6a, 0x24, 0xaa, 0x21, 0xa9, 0xed, got:bytes-size(32), _:bits>> ->
          Ok(got)
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
  let assert Ok(#(_, rest)) =
    string.split_once(json, "\n  \"" <> key <> "\": \"")
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
  let assert Error("bad-txnmrklroot") =
    gleam_bitcoin_node.submit_block(chain, bad_merkle)
  gleam_bitcoin_node.tip_hex(chain) |> should.equal(parent)

  let bad_amount = bump_subsidy(raw)
  same_reject(chain, bad_amount, "bad-cb-amount", parent)

  let bad_height = rewrite_coinbase(raw, break_height)
  same_reject(chain, bad_height, "bad-cb-height", parent)

  let bad_final = rewrite_coinbase(raw, break_final)
  same_reject(chain, bad_final, "bad-txns-nonfinal", parent)

  let chain = submit_hashes(chain, [block_hex_hash(hashes)])
  gleam_bitcoin_node.tip_hex(chain) |> should.equal(cli("getbestblockhash"))
}

fn same_reject(chain, raw: BitArray, reason: String, parent: String) -> Nil {
  let assert Error(got) = gleam_bitcoin_node.submit_block(chain, raw)
  got |> should.equal(reason)
  // The real tip has the same work, so Core will not connect a sibling and
  // submitblock stays "inconclusive". Drop that tip, then the reject runs.
  let tip = cli("getbestblockhash")
  let _ = cli("invalidateblock " <> tip)
  submit_core(raw) |> should.equal(reason)
  let _ = cli("reconsiderblock " <> tip)
  gleam_bitcoin_node.tip_hex(chain) |> should.equal(parent)
}

fn submit_core(raw: BitArray) -> String {
  cmd(
    "bitcoin-cli -regtest -rpcuser=e2e -rpcpassword=e2e submitblock "
    <> hex_encode(raw)
    <> " 2>&1",
  )
  |> string.trim
}

fn rewrite_coinbase(raw: BitArray, change: fn(tx.Tx) -> tx.Tx) -> BitArray {
  let assert Ok(block) = tx.decode_block(raw)
  let assert [coin, ..rest] = block.txs
  let txs = [reparse(change(coin)), ..rest]
  let #(root, _) = merkle.block_root(txs)
  regrind(tx.encode_block(tx.ParsedBlock(block.header, root, txs)), root)
}

fn reparse(item: tx.Tx) -> tx.Tx {
  let assert Ok(#(parsed, rest)) = tx.decode(tx.encode(item))
  let assert 0 = bit_array.byte_size(rest)
  parsed
}

fn break_height(coin: tx.Tx) -> tx.Tx {
  let assert [input, ..inputs] = coin.inputs
  let size = bit_array.byte_size(input.script_sig)
  let assert Ok(rest) = bit_array.slice(input.script_sig, 2, size - 2)
  tx.Tx(..coin, inputs: [
    tx.Input(..input, script_sig: <<1, 99, rest:bits>>),
    ..inputs
  ])
}

fn break_final(coin: tx.Tx) -> tx.Tx {
  let assert [input, ..inputs] = coin.inputs
  tx.Tx(..coin, locktime: 0xfffffffe, inputs: [
    tx.Input(..input, sequence: 0),
    ..inputs
  ])
}

pub fn sigop_and_lock_test() {
  script.sigop_count(<<0xac>>, False) |> should.equal(1)
  script.sigop_count(<<0x51, 0xae>>, True) |> should.equal(1)
  script.sigop_count(<<0x51, 0xae>>, False) |> should.equal(20)

  let open = bare_tx(2, 0, 0xfffffffe)
  consensus.is_final(open, 20, 1_000_000) |> should.equal(False)
  consensus.is_final(bare_tx(2, 0xffffffff, 0xfffffffe), 20, 1_000_000)
  |> should.equal(True)

  let coin = consensus.Coin(value: 1, script: <<>>, height: 5, coinbase: False)
  let locked = bare_tx(2, 10, 0)
  consensus.sequence_ok(locked, [coin], True, 14, 0, fn(_height) { 0 })
  |> should.equal(False)
  consensus.sequence_ok(locked, [coin], True, 15, 0, fn(_height) { 0 })
  |> should.equal(True)
  consensus.sequence_ok(locked, [coin], False, 14, 0, fn(_height) { 0 })
  |> should.equal(True)
  consensus.sequence_ok(
    bare_tx(2, 0x8000000a, 0),
    [coin],
    True,
    14,
    0,
    fn(_height) { 0 },
  )
  |> should.equal(True)
}

pub fn script_flags_test() {
  let height_one = kernel.block_flags(1)
  let height_zero = kernel.block_flags(0)
  int.bitwise_and(height_one, 4) |> should.equal(4)
  int.bitwise_and(height_zero, 4) |> should.equal(0)
  let assert Ok(hash) = hash.from_display("11")
  kernel.assume_valid_covers(hash, "22") |> should.equal(False)
  kernel.assume_valid_covers(hash, string.repeat("0", 64))
  |> should.equal(False)
  kernel.assume_valid_covers(hash, hash.display(hash)) |> should.equal(True)
}

pub fn script_spend_test() {
  start_node("/tmp/btc-script", "18451", "18452")
  script_cli("createwallet e2e")
  let addr = script_cli("getnewaddress")
  script_cli("generatetoaddress 101 \"" <> addr <> "\"")
  let sent = script_cli("sendtoaddress \"" <> addr <> "\" 1")
  sent |> should.not_equal("")
  script_cli("generatetoaddress 1 \"" <> addr <> "\"")
  let count = {
    let assert Ok(n) = int.parse(script_cli("getblockcount"))
    n
  }
  let before =
    range(1, count - 1)
    |> list.fold(gleam_bitcoin_node.new(), fn(chain, height) {
      let assert Ok(chain) =
        gleam_bitcoin_node.submit_block(chain, script_block(height))
      chain
    })
  let last = script_block(count)
  let assert Ok(chain) = gleam_bitcoin_node.submit_block(before, last)
  gleam_bitcoin_node.tip_hex(chain)
  |> should.equal(script_cli("getbestblockhash"))

  let parent = gleam_bitcoin_node.tip_hex(before)
  let bad = break_script(last)
  let assert Error("block-script-verify-flag-failed") =
    gleam_bitcoin_node.submit_block(before, bad)
  gleam_bitcoin_node.tip_hex(before) |> should.equal(parent)
  gleam_bitcoin_node.tip_hex(chain)
  |> should.equal(script_cli("getbestblockhash"))
}

pub fn utxo_set_test() {
  start_node("/tmp/btc-utxo", "18453", "18454")
  let chain = gleam_bitcoin_node.new()
  expect_utxo(chain)
  let chain = submit_utxo(chain, utxo_mine(4))
  expect_utxo(chain)

  let tip = utxo_cli("getbestblockhash")
  let _ = utxo_cli("invalidateblock " <> tip)
  let assert Ok(chain) = gleam_bitcoin_node.disconnect_tip(chain)
  let chain = submit_utxo(chain, utxo_mine(2))
  expect_utxo(chain)
  gleam_bitcoin_node.tip_hex(chain)
  |> should.equal(utxo_cli("getbestblockhash"))
}

fn expect_utxo(chain) -> Nil {
  let info = utxo_cli("gettxoutsetinfo")
  let stats = gleam_bitcoin_node.utxo_stats(chain)
  stats.hash |> should.equal(json_string(info, "hash_serialized_3"))
  stats.txouts |> should.equal(json_int(info, "txouts"))
  stats.transactions |> should.equal(json_int(info, "transactions"))
  stats.bogosize |> should.equal(json_int(info, "bogosize"))
}

fn submit_utxo(chain, hashes: List(String)) {
  list.fold(hashes, chain, fn(chain, hash) {
    let assert Ok(raw) = hex_decode(utxo_cli("getblock " <> hash <> " 0"))
    let assert Ok(chain) = gleam_bitcoin_node.submit_block(chain, raw)
    chain
  })
}

fn utxo_mine(n: Int) -> List(String) {
  utxo_cli("generatetodescriptor " <> int.to_string(n) <> " \"raw(51)\"")
  |> extract_hashes([])
  |> list.reverse
}

fn utxo_cli(args: String) -> String {
  cmd(
    "bitcoin-cli -regtest -datadir=/tmp/btc-utxo -rpcport=18453 -rpcuser=e2e -rpcpassword=e2e "
    <> args
    <> " 2>/dev/null",
  )
  |> string.trim
}

pub fn reorg_test() {
  start_node("/tmp/btc-reorg", "18455", "18456")
  let chain = submit_reorg(gleam_bitcoin_node.new(), reorg_mine(4))
  let old = gleam_bitcoin_node.tip_hex(chain)
  old |> should.equal(reorg_cli("getbestblockhash"))
  let before = gleam_bitcoin_node.utxo_stats(chain).hash

  let assert Ok(height) = int.parse(reorg_cli("getblockcount"))
  let _ = reorg_cli("invalidateblock " <> old)
  // The same empty block would be rebuilt and rejected as already invalid.
  // A different coinbase, one second later, is a real fork.
  let _ = reorg_cli("createwallet reorg")
  let addr = reorg_cli("getnewaddress")
  let _ = cmd("sleep 1")
  let _ = reorg_cli("generatetoaddress 2 \"" <> addr <> "\"")
  let first = reorg_cli("getblockhash " <> int.to_string(height))
  let second = reorg_cli("getblockhash " <> int.to_string(height + 1))
  string.length(first) |> should.equal(64)
  string.length(second) |> should.equal(64)
  let alt = [first, second]
  let chain = submit_reorg(chain, [first])
  gleam_bitcoin_node.tip_hex(chain) |> should.equal(old)
  gleam_bitcoin_node.utxo_stats(chain).hash |> should.equal(before)

  let chain = submit_reorg(chain, alt)
  gleam_bitcoin_node.tip_hex(chain)
  |> should.equal(reorg_cli("getbestblockhash"))
}

fn submit_reorg(chain, hashes: List(String)) {
  list.fold(hashes, chain, fn(chain, hash) {
    let assert Ok(raw) = hex_decode(reorg_cli("getblock " <> hash <> " 0"))
    let assert Ok(chain) = gleam_bitcoin_node.submit_block(chain, raw)
    chain
  })
}

fn reorg_mine(n: Int) -> List(String) {
  reorg_cli("generatetodescriptor " <> int.to_string(n) <> " \"raw(51)\"")
  |> extract_hashes([])
  |> list.reverse
}

fn reorg_cli(args: String) -> String {
  cmd(
    "bitcoin-cli -regtest -datadir=/tmp/btc-reorg -rpcport=18455 -rpcuser=e2e -rpcpassword=e2e "
    <> args
    <> " 2>&1",
  )
  |> string.trim
}

pub fn p2p_handshake_test() {
  start_node_listen("/tmp/btc-p2p", "18471", "18470")
  let assert Ok(Nil) = p2p.handshake_v1("127.0.0.1", 18_470)
  let assert Ok(Nil) = p2p.handshake_v2("127.0.0.1", 18_470)
  let info = p2p_cli("getpeerinfo")
  string.contains(info, "\"transport_protocol_type\": \"v1\"")
  |> should.equal(True)
  string.contains(info, "\"transport_protocol_type\": \"v2\"")
  |> should.equal(True)
  p2p.addrman_count() |> should.equal(2)
}

pub fn header_sync_test() {
  start_node_listen("/tmp/btc-hsync", "18473", "18472")
  hsync_cli("createwallet e2e")
  let addr = hsync_cli("getnewaddress")
  let _ = hsync_cli("generatetoaddress 5 \"" <> addr <> "\"")
  let assert 5 = hsync_count()
  let assert Ok(raws) = p2p.sync_headers("127.0.0.1", 18_472)
  list.length(raws) |> should.equal(5)
  let assert Ok(chain) = headers.ingest(headers.regtest(), raws, unix_now())
  headers.tip_hex(chain) |> should.equal(hsync_cli("getbestblockhash"))
}

pub fn presync_work_test() {
  headers.reached_minimum(
    headers.regtest(),
    params.regtest().minimum_chain_work,
  )
  |> should.equal(True)
  headers.reached_minimum(
    headers.regtest(),
    params.mainnet().minimum_chain_work,
  )
  |> should.equal(False)
}

pub fn block_download_test() {
  start_node_listen("/tmp/btc-bdl", "18475", "18474")
  bdl_cli("createwallet e2e")
  let addr = bdl_cli("getnewaddress")
  let _ = bdl_cli("generatetoaddress 20 \"" <> addr <> "\"")
  let assert 20 = bdl_count()
  let assert Ok(blocks) = p2p.download_blocks("127.0.0.1", 18_474)
  list.length(blocks) |> should.equal(20)
  let chain =
    list.fold(blocks, gleam_bitcoin_node.new(), fn(chain, raw) {
      let assert Ok(chain) = gleam_bitcoin_node.submit_block(chain, raw)
      chain
    })
  let tip = bdl_cli("getbestblockhash")
  gleam_bitcoin_node.tip_hex(chain) |> should.equal(tip)
  let assert Ok(cmpct) = p2p.fetch_cmpct("127.0.0.1", 18_474, tip)
  let assert Ok(rebuilt) = compact.reconstruct(cmpct)
  compact.header_hex(rebuilt) |> should.equal(tip)
}

pub fn package_shape_test() {
  let input = tx.Input(<<1:size(256)>>, 0, <<>>, 0xffffffff, [])
  let parent =
    tx.Tx(
      2,
      [input],
      [tx.Output(1, <<0x51>>)],
      0,
      <<>>,
      <<9:size(256)>>,
      <<9:size(256)>>,
      False,
      100,
    )
  let child =
    tx.Tx(
      2,
      [tx.Input(<<9:size(256)>>, 0, <<>>, 0xffffffff, [])],
      [tx.Output(1, <<0x51>>)],
      0,
      <<>>,
      <<8:size(256)>>,
      <<8:size(256)>>,
      False,
      100,
    )
  mempool.well_formed([child, parent])
  |> should.equal(Error("package-not-sorted"))
  let other =
    tx.Tx(
      2,
      [input],
      [tx.Output(1, <<0x51>>)],
      0,
      <<>>,
      <<2:size(256)>>,
      <<2:size(256)>>,
      False,
      100,
    )
  mempool.well_formed([parent, other])
  |> should.equal(Error("conflict-in-package"))
  mempool.well_formed([parent, child]) |> should.equal(Ok(Nil))
}

pub fn mempool_package_and_rbf_test() {
  start_node("/tmp/btc-mempool", "18477", "18476")
  mp_cli("createwallet e2e")
  let change = mp_cli("-rpcwallet=e2e getnewaddress")
  let sink = mp_cli("-rpcwallet=e2e getnewaddress")
  mp_cli("-rpcwallet=e2e generatetoaddress 101 \"" <> change <> "\"")
  let assert Ok(count) = int.parse(mp_cli("getblockcount"))
  let chain =
    range(1, count)
    |> list.fold(gleam_bitcoin_node.new(), fn(chain, height) {
      let assert Ok(chain) =
        gleam_bitcoin_node.submit_block(chain, mp_block(height))
      chain
    })
  gleam_bitcoin_node.tip_hex(chain) |> should.equal(mp_cli("getbestblockhash"))

  let #(txid, vout, value) = mature_outpoint(chain)
  value |> should.equal(5_000_000_000)
  let parent_value = value - 100_000
  let child_value = parent_value - 100_000
  let parent_hex = sign_spend(txid, vout, change, parent_value, False, "")
  let assert Ok(parent_raw) = hex_decode(parent_hex)
  let assert Ok(#(parent, rest)) = tx.decode(parent_raw)
  bit_array.byte_size(rest) |> should.equal(0)
  let assert [output, ..] = parent.outputs
  let child_hex =
    sign_spend(
      hash.display(parent.txid),
      0,
      sink,
      child_value,
      False,
      prevout(hash.display(parent.txid), output.script_pubkey, parent_value),
    )
  let assert Ok(child_raw) = hex_decode(child_hex)
  let core =
    mp_cli(
      "testmempoolaccept '[\"" <> parent_hex <> "\",\"" <> child_hex <> "\"]'",
    )
  string.contains(core, "\"allowed\": false") |> should.equal(False)
  let assert Ok(verdicts) =
    mempool.test_package(chain, mempool.new(), [parent_raw, child_raw])
  list.length(verdicts) |> should.equal(2)
  list.each(verdicts, fn(verdict) {
    verdict.reason |> should.equal("")
    verdict.allowed |> should.equal(True)
    string.contains(core, verdict.txid) |> should.equal(True)
  })

  let tx1 = sign_spend(txid, vout, sink, value - 10_000, True, "")
  let assert Ok(tx1_raw) = hex_decode(tx1)
  let sent = mp_cli("sendrawtransaction " <> tx1)
  let assert Ok(#(pool, id)) = mempool.send_raw(chain, mempool.new(), tx1_raw)
  id |> should.equal(sent)
  mempool.relay_inv(pool) |> should.equal([id])

  let tx2 = sign_spend(txid, vout, sink, value - 9000, True, "")
  let assert Ok(tx2_raw) = hex_decode(tx2)
  let rejected = mp_cli("sendrawtransaction " <> tx2)
  string.contains(rejected, "insufficient fee") |> should.equal(True)
  let assert Error(reason) = mempool.send_raw(chain, pool, tx2_raw)
  reason |> should.equal("insufficient fee")
  string.contains(rejected, reason) |> should.equal(True)
  mempool.relay_inv(pool) |> should.equal([id])
}

fn mature_outpoint(chain: chain.Chain) -> #(String, Int, Int) {
  let limit = chain.height - 100
  let assert Ok(#(key, coin)) =
    list.find(dict.to_list(chain.coins), fn(pair) {
      let #(_, coin) = pair
      coin.coinbase && coin.height > 0 && coin.height <= limit
    })
  let assert Ok(#(txid, vout)) = string.split_once(key, ":")
  let assert Ok(index) = int.parse(vout)
  #(txid, index, coin.value)
}

fn sign_spend(
  txid: String,
  vout: Int,
  addr: String,
  sats: Int,
  replaceable: Bool,
  prev: String,
) -> String {
  let flag = case replaceable {
    True -> " true"
    False -> " false"
  }
  let raw =
    mp_cli(
      "createrawtransaction '[{\"txid\":\""
      <> txid
      <> "\",\"vout\":"
      <> int.to_string(vout)
      <> "}]' '{\""
      <> addr
      <> "\":"
      <> btc(sats)
      <> "}' 0"
      <> flag,
    )
  let args = case prev {
    "" -> raw
    _ -> raw <> " '" <> prev <> "'"
  }
  let signed = mp_cli("-rpcwallet=e2e signrawtransactionwithwallet " <> args)
  string.contains(signed, "\"complete\": true") |> should.equal(True)
  json_string(signed, "hex")
}

fn prevout(txid: String, script: BitArray, sats: Int) -> String {
  "[{\"txid\":\""
  <> txid
  <> "\",\"vout\":0,\"scriptPubKey\":\""
  <> hex_encode(script)
  <> "\",\"amount\":"
  <> btc(sats)
  <> "}]"
}

fn btc(sats: Int) -> String {
  let whole = sats / 100_000_000
  let frac = sats % 100_000_000
  int.to_string(whole) <> "." <> pad_sats(int.to_string(frac))
}

fn pad_sats(text: String) -> String {
  string.repeat("0", 8 - string.length(text)) <> text
}

fn mp_block(height: Int) -> BitArray {
  let hex =
    mp_cli(
      "getblock " <> mp_cli("getblockhash " <> int.to_string(height)) <> " 0",
    )
  let assert Ok(raw) = hex_decode(hex)
  raw
}

fn mp_cli(args: String) -> String {
  node_cli("/tmp/btc-mempool", "18477", args)
}

fn bdl_count() -> Int {
  let assert Ok(n) = int.parse(bdl_cli("getblockcount"))
  n
}

fn bdl_cli(args: String) -> String {
  cmd(
    "bitcoin-cli -regtest -datadir=/tmp/btc-bdl -rpcport=18475 -rpcuser=e2e -rpcpassword=e2e "
    <> args
    <> " 2>/dev/null",
  )
  |> string.trim
}

fn hsync_count() -> Int {
  let assert Ok(n) = int.parse(hsync_cli("getblockcount"))
  n
}

fn hsync_cli(args: String) -> String {
  cmd(
    "bitcoin-cli -regtest -datadir=/tmp/btc-hsync -rpcport=18473 -rpcuser=e2e -rpcpassword=e2e "
    <> args
    <> " 2>/dev/null",
  )
  |> string.trim
}

fn start_node_listen(dir: String, rpc: String, p2p: String) -> Nil {
  let _ = cmd("mkdir -p " <> dir)
  let _ =
    cmd(
      "bitcoind -regtest -datadir="
      <> dir
      <> " -daemonwait -listen=1 -bind=127.0.0.1:"
      <> p2p
      <> " -port="
      <> p2p
      <> " -v2transport=1 -dnsseed=0 -connect=0 -txindex=1 -rpcuser=e2e -rpcpassword=e2e -rpcport="
      <> rpc,
    )
  Nil
}

fn p2p_cli(args: String) -> String {
  cmd(
    "bitcoin-cli -regtest -datadir=/tmp/btc-p2p -rpcport=18471 -rpcuser=e2e -rpcpassword=e2e "
    <> args
    <> " 2>/dev/null",
  )
  |> string.trim
}

fn script_block(height: Int) -> BitArray {
  let hex =
    script_cli(
      "getblock "
      <> script_cli("getblockhash " <> int.to_string(height))
      <> " 0",
    )
  let assert Ok(raw) = hex_decode(hex)
  raw
}

fn script_cli(args: String) -> String {
  node_cli("/tmp/btc-script", "18451", args)
}

fn break_script(raw: BitArray) -> BitArray {
  let assert Ok(block) = tx.decode_block(raw)
  let assert [coin, spend, ..rest] = block.txs
  let assert [input, ..inputs] = spend.inputs
  let spend = reparse(tx.Tx(..spend, inputs: [corrupt_input(input), ..inputs]))
  let txs = [coin, spend, ..rest]
  let assert [coin_input, ..] = coin.inputs
  let assert [nonce] = coin_input.witness
  let root = merkle.witness_root(txs)
  let expect = hash.hash256(<<root:bits, nonce:bits>>)
  let outputs =
    list.map(coin.outputs, fn(output) { patch_commitment(output, expect) })
  let coin = reparse(tx.Tx(..coin, outputs: outputs))
  let txs = [coin, spend, ..rest]
  let #(merkle, _) = merkle.block_root(txs)
  regrind(tx.encode_block(tx.ParsedBlock(block.header, merkle, txs)), merkle)
}

fn corrupt_input(input: tx.Input) -> tx.Input {
  case input.witness {
    [first, ..rest] -> tx.Input(..input, witness: [flip_last(first), ..rest])
    _ -> tx.Input(..input, script_sig: flip_last(input.script_sig))
  }
}

fn flip_last(bytes: BitArray) -> BitArray {
  let size = bit_array.byte_size(bytes)
  let assert Ok(head) = bit_array.slice(bytes, 0, size - 1)
  let assert Ok(<<last>>) = bit_array.slice(bytes, size - 1, 1)
  <<head:bits, { int.bitwise_exclusive_or(last, 1) }>>
}

fn patch_commitment(output: tx.Output, expect: BitArray) -> tx.Output {
  case output.script_pubkey {
    <<0x6a, 0x24, 0xaa, 0x21, 0xa9, 0xed, _:bytes-size(32), tail:bits>> ->
      tx.Output(output.value, <<
        0x6a,
        0x24,
        0xaa,
        0x21,
        0xa9,
        0xed,
        expect:bits,
        tail:bits,
      >>)
    _ -> output
  }
}

fn bare_tx(version: Int, sequence: Int, locktime: Int) -> tx.Tx {
  tx.Tx(
    version: version,
    inputs: [tx.Input(<<0:size(256)>>, 0, <<1, 2>>, sequence, [])],
    outputs: [tx.Output(1, <<0x51>>)],
    locktime: locktime,
    raw: <<>>,
    txid: <<0:size(256)>>,
    wtxid: <<0:size(256)>>,
    has_witness: False,
    base_size: 0,
  )
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
  let assert Ok(tail) =
    bit_array.slice(joined, 80, bit_array.byte_size(joined) - 80)
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
    "bitcoin-cli "
    <> prefix
    <> "-rpcuser=e2e -rpcpassword=e2e "
    <> args
    <> " 2>/dev/null",
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

pub fn header_rules_test() {
  let assert Ok(main_limit) = pow.target_of(0x1d00ffff)
  pow.compact_of(main_limit) |> should.equal(0x1d00ffff)
  let assert Ok(reg_limit) = pow.target_of(0x207fffff)
  pow.compact_of(reg_limit) |> should.equal(0x207fffff)
  pow.retarget(
    0x1d00ffff,
    1_209_600,
    0,
    0x1d00ffff,
    False,
    False,
    1_209_600,
    main_limit,
  )
  |> should.equal(0x1d00ffff)
  pow.retarget(
    0x1c00ffff,
    2_419_200,
    0,
    0x1c00ffff,
    False,
    False,
    1_209_600,
    main_limit,
  )
  |> should.equal(0x1c01fffe)

  let testnet = params.testnet()
  let entries = [
    headers.Entry(<<0:size(256)>>, 0, 1000, 0x1d00ffff, 1),
    headers.Entry(<<0:size(256)>>, 1, 2000, 0x1c00ffff, 4),
  ]
  let assert Ok(last) = list.last(entries)
  headers.next_bits(testnet, entries, last, 2000 + 1201)
  |> should.equal(0x1d00ffff)
  headers.next_bits(testnet, entries, last, 2100)
  |> should.equal(0x1c00ffff)

  let warped = [
    headers.Entry(<<0:size(256)>>, 0, 0, 0x207fffff, 1),
    headers.Entry(<<0:size(256)>>, 1, 0, 0x207fffff, 4),
    headers.Entry(<<0:size(256)>>, 2, 0, 0x207fffff, 4),
    headers.Entry(<<0:size(256)>>, 3, 0, 0x207fffff, 4),
    headers.Entry(<<0:size(256)>>, 4, 0, 0x207fffff, 4),
    headers.Entry(<<0:size(256)>>, 5, 0, 0x207fffff, 4),
    headers.Entry(<<0:size(256)>>, 6, 0, 0x207fffff, 4),
    headers.Entry(<<0:size(256)>>, 7, 0, 0x207fffff, 4),
    headers.Entry(<<0:size(256)>>, 8, 0, 0x207fffff, 4),
    headers.Entry(<<0:size(256)>>, 9, 0, 0x207fffff, 4),
    headers.Entry(<<0:size(256)>>, 10, 0, 0x207fffff, 4),
    headers.Entry(<<0:size(256)>>, 11, 20_000, 0x207fffff, 4),
  ]
  let assert Ok(prev) = list.last(warped)
  let p =
    params.Params(
      ..params.regtest(),
      pow_target_timespan: 600,
      enforce_bip94: True,
    )
  let attack = headers.Header(<<>>, <<>>, 4, <<>>, 1000, prev.bits)
  headers.contextual(p, warped, prev, attack, 1_000_000)
  |> should.equal(Error("time-timewarp-attack"))
  let old = headers.Header(<<>>, <<>>, 4, <<>>, 0, prev.bits)
  headers.contextual(p, warped, prev, old, 1_000_000)
  |> should.equal(Error("time-too-old"))
}

pub fn header_chain_test() {
  let _ = cmd("mkdir -p /tmp/btc-hdr")
  let _ =
    cmd(
      "bitcoind -regtest -datadir=/tmp/btc-hdr -daemonwait -listen=0 -rpcuser=e2e -rpcpassword=e2e -rpcport=18449 -port=18450",
    )
  hdr("generatetodescriptor 20 \"raw(51)\"")
  let now = unix_now()
  let chain =
    range(1, 20)
    |> list.fold(headers.regtest(), fn(chain, height) {
      let assert Ok(chain) = headers.submit(chain, header_at(height), now)
      chain
    })
  let tip = headers.tip_hex(chain)
  tip |> should.equal(hdr("getbestblockhash"))

  let assert Ok(prev) = hash.from_display(tip)
  let future = grind_header(prev, now + 3 * 60 * 60, 0x207fffff)
  headers.submit(chain, future, now) |> should.equal(Error("time-too-new"))
  headers.tip_hex(chain) |> should.equal(tip)

  let wrong_bits = grind_header(prev, now, 0x207ffffe)
  headers.submit(chain, wrong_bits, now) |> should.equal(Error("bad-diffbits"))
  headers.tip_hex(chain) |> should.equal(tip)
}

fn range(from: Int, to: Int) -> List(Int) {
  case from > to {
    True -> []
    False -> [from, ..range(from + 1, to)]
  }
}

fn header_at(height: Int) -> BitArray {
  let hex =
    hdr("getblock " <> hdr("getblockhash " <> int.to_string(height)) <> " 0")
  let assert Ok(raw) = hex_decode(hex)
  let assert Ok(header) = bit_array.slice(raw, 0, 80)
  header
}

fn grind_header(prev: BitArray, time: Int, bits: Int) -> BitArray {
  let prefix = <<
    4:32-little,
    prev:bits,
    0:size(256),
    time:32-little,
    bits:32-little,
  >>
  grind_nonce(prefix, bits, 0)
}

fn grind_nonce(prefix: BitArray, bits: Int, nonce: Int) -> BitArray {
  let header = <<prefix:bits, nonce:32-little>>
  let assert Ok(limit) = pow.target_of(bits)
  case hash.little_endian_int(hash.hash256(header)) <= limit {
    True -> header
    False -> grind_nonce(prefix, bits, nonce + 1)
  }
}

fn unix_now() -> Int {
  let assert Ok(now) = int.parse(string.trim(cmd("date +%s")))
  now
}

pub fn dos_limits_test() {
  let chain = gleam_bitcoin_node.new()
  let pool = mempool.new()
  let tip = gleam_bitcoin_node.tip_hex(chain)
  let inv = mempool.relay_inv(pool)

  limits.absorb(params.regtest().magic, <<1, 2, 3, 4>>)
  |> should.equal(Error("bad-magic"))
  limits.absorb(params.regtest().magic, oversized_header())
  |> should.equal(Error("oversized"))
  limits.command_limit("headers", <<253, 2001:16-little>>)
  |> should.equal(Error("headers-too-large"))
  limits.command_limit("inv", <<253, 50_001:16-little, 0>>)
  |> should.equal(Ok(Nil))
  limits.command_limit("inv", fat_inv())
  |> should.equal(Error("inv-too-large"))
  limits.command_limit("addr", fat_addr())
  |> should.equal(Error("addr-too-large"))
  limits.recv_flood(5_000_001) |> should.equal(True)
  limits.recv_flood(5_000_000) |> should.equal(False)

  let budget = limits.new_budget(200_000)
  let assert Ok(budget) = limits.charge(budget, "a", 100_000)
  let assert Ok(budget) = limits.charge(budget, "b", 100_000)
  limits.charge(budget, "c", 100_000) |> should.equal(Error("decode-budget"))
  let budget = limits.release(budget, "a")
  let assert Ok(_) = limits.charge(budget, "c", 100_000)

  let stalls =
    limits.new_stalls()
    |> limits.mark_stall("slow", 0)
    |> limits.mark_stall("later", 0)
  let #(stalls, ids) = limits.take_stalls(stalls, 2001)
  list.sort(ids, by: string.compare) |> should.equal(["later", "slow"])
  stalls.timeout_ms |> should.equal(8000)
  let stalls = limits.decay_stall(limits.clear_stall(stalls, "slow"))
  stalls.timeout_ms |> should.equal(6800)

  let assert Ok(paused) = limits.send_buffer(1_000_001, -1, 10)
  paused |> should.equal(10)
  limits.send_buffer(1_000_001, 10, 1211)
  |> should.equal(Error("send-buffer"))
  limits.send_buffer(1, 10, 99) |> should.equal(Ok(-1))

  limits.orphan_count(limits.park(limits.new_house(), "k", 404_000, 0, "p"))
  |> should.equal(1)
  limits.orphan_count(limits.park(limits.new_house(), "d", 404_001, 0, "p"))
  |> should.equal(0)
  let house =
    limits.new_house()
    |> limits.park("old", 300_000, 0, "p")
    |> limits.park("new", 300_000, 0, "p")
  limits.orphan_ids(house) |> should.equal(["new"])
  limits.orphan_count(limits.park(limits.new_house(), "big", 100, 30_000, "p"))
  |> should.equal(0)
  limits.orphan_count(limits.park(limits.new_house(), "edge", 100, 29_990, "p"))
  |> should.equal(1)

  let crowd =
    range(0, 20)
    |> list.map(fn(i) {
      limits.Peer(
        ..limits.candidate("p" <> int.to_string(i)),
        connected: i,
        min_ping: Some(i),
        last_block_time: i,
        last_tx_time: i,
        keyed_netgroup: i,
      )
    })
  let outbound = limits.Peer(..limits.candidate("out"), conn_type: "outbound")
  let banned = limits.Peer(..limits.candidate("ban"), noban: True)
  limits.select([outbound, banned, ..crowd]) |> should.equal(Ok("p8"))

  let assert Ok(Nil) = p2p.hostile(18_479)
  let assert Ok(reason) = p2p.punish("127.0.0.1", 18_479)
  reason |> should.equal("oversized")
  gleam_bitcoin_node.tip_hex(chain) |> should.equal(tip)
  mempool.relay_inv(pool) |> should.equal(inv)
}

fn oversized_header() -> BitArray {
  <<
    0xfa,
    0xbf,
    0xb5,
    0xda,
    "ping":utf8,
    0:size(64),
    4_000_001:32-little,
    0:size(32),
  >>
}

fn fat_inv() -> BitArray {
  let n = 50_001
  <<253, n:16-little, zero_bytes(n * 36):bits>>
}

fn fat_addr() -> BitArray {
  let n = 1001
  <<253, n:16-little, zero_bytes(n * 30):bits>>
}

fn zero_bytes(n: Int) -> BitArray {
  zero_blocks(n / 8192, n % 8192, <<>>)
}

fn zero_blocks(blocks: Int, rest: Int, acc: BitArray) -> BitArray {
  case blocks {
    0 -> zero_pages(rest / 256, rest % 256, acc)
    _ -> zero_blocks(blocks - 1, rest, <<acc:bits, 0:size(65_536)>>)
  }
}

fn zero_pages(pages: Int, rest: Int, acc: BitArray) -> BitArray {
  case pages {
    0 -> zero_tail(rest, acc)
    _ -> zero_pages(pages - 1, rest, <<acc:bits, 0:size(2048)>>)
  }
}

fn zero_tail(n: Int, acc: BitArray) -> BitArray {
  case n {
    0 -> acc
    _ -> zero_tail(n - 1, <<acc:bits, 0>>)
  }
}

pub fn esplora_index_test() {
  let _ = cmd("rm -rf /tmp/btc-esplora")
  start_node("/tmp/btc-esplora", "18481", "18480")
  let _ = es_cli("createwallet e2e")
  let addr = es_cli("-rpcwallet=e2e getnewaddress")
  let _ = es_cli("-rpcwallet=e2e generatetoaddress 2 \"" <> addr <> "\"")
  let assert Ok(count) = int.parse(es_cli("getblockcount"))
  let view =
    range(1, count)
    |> list.fold(index.new(), fn(view, height) {
      let assert Ok(view) = index.connect(view, es_block(height))
      view
    })
  index.tip(view) |> should.equal(es_cli("getbestblockhash"))

  let assert Ok(#(0, program)) =
    address.witness("bc", "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4")
  bit_array.byte_size(program) |> should.equal(20)

  let info = es_cli("-rpcwallet=e2e getaddressinfo " <> addr)
  let assert Ok(script) = address.to_script(addr)
  hash.encode_hex(script) |> should.equal(json_string(info, "scriptPubKey"))

  let assert Ok(Nil) = esplora.start(18_482)
  esplora.publish(view)
  http_get("/blocks/tip/hash") |> should.equal(es_cli("getbestblockhash"))
  must_contain(http_get("/block/" <> index.tip(view)), "\"height\":2")
  must_contain(http_get("/address/" <> addr), addr)

  let body = http_get("/address/" <> addr <> "/utxo")
  let scan = es_cli("scantxoutset start '[\"addr(" <> addr <> ")\"]'")
  let txids = json_strings(scan, "txid", [])
  list.each(txids, fn(txid) { must_contain(body, txid) })
  count_text(body, "\"value\":5000000000") |> should.equal(2)

  let assert Ok(txid) = list.first(txids)
  must_contain(http_get("/tx/" <> txid), "\"confirmed\":true")
  let raw =
    es_cli(
      "createrawtransaction '[{\"txid\":\""
      <> txid
      <> "\",\"vout\":0}]' '{\""
      <> addr
      <> "\":49.999}'",
    )
  let signed = es_cli("-rpcwallet=e2e signrawtransactionwithwallet " <> raw)
  let hex = json_string(signed, "hex")
  let posted = http_post("/tx", hex)
  must_contain(posted, "bad-txns-premature-spend-of-coinbase")
  must_contain(es_cli("sendrawtransaction " <> hex), posted)

  let assert Ok(view) = index.disconnect(view)
  esplora.publish(view)
  http_get("/blocks/tip/hash") |> should.equal(es_cli("getblockhash 1"))
  count_text(http_get("/address/" <> addr <> "/utxo"), "\"value\":5000000000")
  |> should.equal(1)
  http_post("/tx", "zz") |> should.equal("Invalid transaction hex")
}

fn es_block(height: Int) -> BitArray {
  let hex =
    es_cli(
      "getblock " <> es_cli("getblockhash " <> int.to_string(height)) <> " 0",
    )
  let assert Ok(raw) = hex_decode(hex)
  raw
}

fn es_cli(args: String) -> String {
  node_cli("/tmp/btc-esplora", "18481", args)
}

fn http_get(path: String) -> String {
  string.trim(cmd("curl -sf http://127.0.0.1:18482" <> path))
}

fn http_post(path: String, body: String) -> String {
  string.trim(cmd(
    "curl -s -X POST --data " <> body <> " http://127.0.0.1:18482" <> path,
  ))
}

fn count_text(text: String, needle: String) -> Int {
  list.length(string.split(text, needle)) - 1
}

fn must_contain(text: String, needle: String) -> Nil {
  case string.contains(text, needle) {
    True -> Nil
    False -> text |> should.equal(needle)
  }
}

fn json_strings(json: String, key: String, acc: List(String)) -> List(String) {
  case string.split_once(json, "\"" <> key <> "\": \"") {
    Error(_) -> list.reverse(acc)
    Ok(#(_, rest)) ->
      case string.split_once(rest, "\"") {
        Error(_) -> list.reverse(acc)
        Ok(#(value, rest)) -> json_strings(rest, key, [value, ..acc])
      }
  }
}

fn hdr(args: String) -> String {
  cmd(
    "bitcoin-cli -regtest -datadir=/tmp/btc-hdr -rpcport=18449 -rpcuser=e2e -rpcpassword=e2e "
    <> args
    <> " 2>/dev/null",
  )
  |> string.trim
}
