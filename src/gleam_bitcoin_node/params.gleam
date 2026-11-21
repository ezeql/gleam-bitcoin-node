import gleam/bit_array
import gleam_bitcoin_node/hash

pub type Network {
  Mainnet
  Testnet
  Testnet4
  Signet
  Regtest
}

pub type Bip9 {
  Bip9(
    bit: Int,
    start_time: Int,
    timeout: Int,
    min_activation_height: Int,
    threshold: Int,
    period: Int,
  )
}

pub type Params {
  Params(
    network: Network,
    genesis_hash: String,
    magic: BitArray,
    port: Int,
    bip34_height: Int,
    bip34_hash: String,
    bip65_height: Int,
    bip66_height: Int,
    csv_height: Int,
    segwit_height: Int,
    testdummy: Bip9,
    minimum_chain_work: String,
    assume_valid: String,
    pow_limit_bits: Int,
    pow_target_timespan: Int,
    pow_target_spacing: Int,
    pow_allow_min_difficulty: Bool,
    pow_no_retargeting: Bool,
    enforce_bip94: Bool,
    signet_blocks: Bool,
    signet_challenge: BitArray,
  )
}

const zero_hash =
  "0000000000000000000000000000000000000000000000000000000000000000"

const never_active = -2

const no_timeout = 9_223_372_036_854_775_807

const signet_challenge_hex =
  "512103ad5e0edad18cb1f0fc0d28a3d4f1f3e445640337489abb10404f2d1e086be430210359ef5021964fe22d6f8e05b2463c9540ce96883fe3b278760f048f5189f2e6c452ae"

@external(erlang, "gleam_bitcoin_node_ffi", "hex_decode")
fn hex_decode(hex: String) -> Result(BitArray, Nil)

pub fn mainnet() -> Params {
  Params(
    network: Mainnet,
    genesis_hash: "000000000019d6689c085ae165831e934ff763ae46a2a6c172b3f1b60a8ce26f",
    magic: <<0xf9, 0xbe, 0xb4, 0xd9>>,
    port: 8333,
    bip34_height: 227_931,
    bip34_hash: "000000000000024b89b42a942fe0d9fea3bb44ab7bd1b19115dd6a759c0808b8",
    bip65_height: 388_381,
    bip66_height: 363_725,
    csv_height: 419_328,
    segwit_height: 481_824,
    testdummy: testdummy(1815, 2016, never_active),
    minimum_chain_work: "000000000000000000000000000000000000000145ec036acc5ba740052af1a0",
    assume_valid: "00000000000000000000748969ec33043c0e52a763c6dd5193861f559f2c72e3",
    pow_limit_bits: 0x1d00ffff,
    pow_target_timespan: 1_209_600,
    pow_target_spacing: 600,
    pow_allow_min_difficulty: False,
    pow_no_retargeting: False,
    enforce_bip94: False,
    signet_blocks: False,
    signet_challenge: <<>>,
  )
}

pub fn testnet() -> Params {
  Params(
    network: Testnet,
    genesis_hash: "000000000933ea01ad0ee984209779baaec3ced90fa3f408719526f8d77f4943",
    magic: <<0x0b, 0x11, 0x09, 0x07>>,
    port: 18_333,
    bip34_height: 21_111,
    bip34_hash: "0000000023b3a96d3484e5abb3755c413e7d41500f8e2a5c3f0dd01299cd8ef8",
    bip65_height: 581_885,
    bip66_height: 330_776,
    csv_height: 770_112,
    segwit_height: 834_624,
    testdummy: testdummy(1512, 2016, never_active),
    minimum_chain_work: "0000000000000000000000000000000000000000000017f49f702147f10c0eb6",
    assume_valid: "00000000b318a3703d14a844c55ef507f4c2fc8f8766e24271fd43c180c51637",
    pow_limit_bits: 0x1d00ffff,
    pow_target_timespan: 1_209_600,
    pow_target_spacing: 600,
    pow_allow_min_difficulty: True,
    pow_no_retargeting: False,
    enforce_bip94: False,
    signet_blocks: False,
    signet_challenge: <<>>,
  )
}

pub fn testnet4() -> Params {
  Params(
    network: Testnet4,
    genesis_hash: "00000000da84f2bafbbc53dee25a72ae507ff4914b867c565be350b0da8bf043",
    magic: <<0x1c, 0x16, 0x3f, 0x28>>,
    port: 48_333,
    bip34_height: 1,
    bip34_hash: zero_hash,
    bip65_height: 1,
    bip66_height: 1,
    csv_height: 1,
    segwit_height: 1,
    testdummy: testdummy(1512, 2016, never_active),
    minimum_chain_work: "000000000000000000000000000000000000000000000e346a558455ade8eca9",
    assume_valid: "0000000021df65b91665a342e26ceb05e54826ad7d8fcd40316230058fa3b865",
    pow_limit_bits: 0x1d00ffff,
    pow_target_timespan: 1_209_600,
    pow_target_spacing: 600,
    pow_allow_min_difficulty: True,
    pow_no_retargeting: False,
    enforce_bip94: True,
    signet_blocks: False,
    signet_challenge: <<>>,
  )
}

pub fn signet() -> Params {
  let challenge = must_hex(signet_challenge_hex)
  Params(
    network: Signet,
    genesis_hash: "00000008819873e925422c1ff0f99f7cc9bbb232af63a077a480a3633bee1ef6",
    magic: signet_magic(challenge),
    port: 38_333,
    bip34_height: 1,
    bip34_hash: zero_hash,
    bip65_height: 1,
    bip66_height: 1,
    csv_height: 1,
    segwit_height: 1,
    testdummy: testdummy(1815, 2016, never_active),
    minimum_chain_work: "00000000000000000000000000000000000000000000000000001090e9dc1520",
    assume_valid: "00000002a5e0ba0498f1e9f4591af0b66b63c654665efe65206fd0ae7bbaf923",
    pow_limit_bits: 0x1e0377ae,
    pow_target_timespan: 1_209_600,
    pow_target_spacing: 600,
    pow_allow_min_difficulty: False,
    pow_no_retargeting: False,
    enforce_bip94: False,
    signet_blocks: True,
    signet_challenge: challenge,
  )
}

pub fn regtest() -> Params {
  Params(
    network: Regtest,
    genesis_hash: "0f9188f13cb7b2c71f2a335e3a4fc328bf5beb436012afca590b1a11466e2206",
    magic: <<0xfa, 0xbf, 0xb5, 0xda>>,
    port: 18_444,
    bip34_height: 1,
    bip34_hash: zero_hash,
    bip65_height: 1,
    bip66_height: 1,
    csv_height: 1,
    segwit_height: 0,
    testdummy: testdummy(108, 144, 0),
    minimum_chain_work: zero_hash,
    assume_valid: zero_hash,
    pow_limit_bits: 0x207fffff,
    pow_target_timespan: 86_400,
    pow_target_spacing: 600,
    pow_allow_min_difficulty: True,
    pow_no_retargeting: True,
    enforce_bip94: False,
    signet_blocks: False,
    signet_challenge: <<>>,
  )
}

pub fn get(network: Network) -> Params {
  case network {
    Mainnet -> mainnet()
    Testnet -> testnet()
    Testnet4 -> testnet4()
    Signet -> signet()
    Regtest -> regtest()
  }
}

fn testdummy(threshold: Int, period: Int, start_time: Int) -> Bip9 {
  Bip9(
    bit: 28,
    start_time: start_time,
    timeout: no_timeout,
    min_activation_height: 0,
    threshold: threshold,
    period: period,
  )
}

fn signet_magic(challenge: BitArray) -> BitArray {
  let digest = hash.hash256(prefix_compact(challenge))
  let assert Ok(magic) = bit_array.slice(digest, 0, 4)
  magic
}

fn prefix_compact(bytes: BitArray) -> BitArray {
  let size = bit_array.byte_size(bytes)
  case size < 253 {
    True -> <<size, bytes:bits>>
    False -> <<253, size:16-little, bytes:bits>>
  }
}

fn must_hex(hex: String) -> BitArray {
  let assert Ok(bytes) = hex_decode(hex)
  bytes
}
