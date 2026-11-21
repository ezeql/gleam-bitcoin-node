import gleam/int
import gleam_bitcoin_node/hash
import gleam_bitcoin_node/params

const zero_hash =
  "0000000000000000000000000000000000000000000000000000000000000000"

const p2sh = 1

const dersig = 4

const nulldummy = 16

const cltv = 512

const csv_flag = 1024

const witness = 2048

const taproot = 131_072

@external(erlang, "gleam_bitcoin_node_kernel", "verify")
fn verify_nif(
  raw: BitArray,
  spent: List(#(BitArray, Int)),
  flags: Int,
) -> Result(Bool, String)

pub fn block_flags(height: Int) -> Int {
  let p = params.regtest()
  int.bitwise_or(p2sh, witness)
  |> int.bitwise_or(taproot)
  |> bor_if(height >= p.bip66_height, dersig)
  |> bor_if(height >= p.bip65_height, cltv)
  |> bor_if(height >= p.csv_height, csv_flag)
  |> bor_if(height >= p.segwit_height, nulldummy)
}

pub fn assume_valid_covers(block_hash: BitArray, configured: String) -> Bool {
  case configured == zero_hash {
    True -> False
    False -> hash.display(block_hash) == configured
  }
}

pub fn verify_tx(
  raw: BitArray,
  spent: List(#(BitArray, Int)),
  flags: Int,
) -> Result(Bool, String) {
  verify_nif(raw, spent, flags)
}

pub fn verify_jobs(
  jobs: List(#(BitArray, List(#(BitArray, Int)))),
  height: Int,
  block_hash: BitArray,
) -> Result(Nil, String) {
  case assume_valid_covers(block_hash, params.regtest().assume_valid) {
    True -> Ok(Nil)
    False -> verify_all(jobs, block_flags(height))
  }
}

fn verify_all(
  jobs: List(#(BitArray, List(#(BitArray, Int)))),
  flags: Int,
) -> Result(Nil, String) {
  case jobs {
    [] -> Ok(Nil)
    [#(raw, spent), ..rest] ->
      case verify_nif(raw, spent, flags) {
        Error(reason) -> Error(reason)
        Ok(True) -> verify_all(rest, flags)
        Ok(False) -> Error("block-script-verify-flag-failed")
      }
  }
}

fn bor_if(flags: Int, enabled: Bool, bit: Int) -> Int {
  case enabled {
    True -> int.bitwise_or(flags, bit)
    False -> flags
  }
}
