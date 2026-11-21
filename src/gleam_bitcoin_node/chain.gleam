import gleam_bitcoin_node/codec
import gleam_bitcoin_node/hash
import gleam_bitcoin_node/pow

pub type Chain {
  Chain(height: Int, tip: BitArray)
}

const required_bits = 0x207fffff

pub fn new() -> Chain {
  Chain(height: 0, tip: genesis())
}

pub fn tip_hex(chain: Chain) -> String {
  hash.display(chain.tip)
}

pub fn submit_block(chain: Chain, raw: BitArray) -> Result(Chain, String) {
  case codec.decode_block(raw) {
    Error(reason) -> Error(reason)
    Ok(parsed) -> connect(chain, parsed)
  }
}

fn connect(chain: Chain, parsed: codec.Parsed) -> Result(Chain, String) {
  let header = parsed.header
  let coin = parsed.coinbase
  let height = chain.height + 1
  case header.prev == chain.tip {
    False -> Error("prev-blk-not-found")
    True ->
      case header.bits == required_bits {
        False -> Error("bad-diffbits")
        True ->
          case pow.check(header.raw, header.bits) {
            Error(reason) -> Error(reason)
            Ok(_) ->
              case header.merkle == coin.txid {
                False -> Error("bad-txnmrklroot")
                True ->
                  case codec.commitment_ok(coin.nonce, coin.commitment) {
                    False -> Error("bad-witness-merkle-match")
                    True ->
                      case codec.bip34_ok(height, coin.script_sig) {
                        False -> Error("bad-cb-height")
                        True ->
                          case coin.output_sum > codec.subsidy(height) {
                            True -> Error("bad-cb-amount")
                            False ->
                              Ok(Chain(height: height, tip: hash.hash256(header.raw)))
                          }
                      }
                  }
              }
          }
      }
  }
}

fn genesis() -> BitArray {
  let assert Ok(hash) =
    hash.from_display("0f9188f13cb7b2c71f2a335e3a4fc328bf5beb436012afca590b1a11466e2206")
  hash
}
