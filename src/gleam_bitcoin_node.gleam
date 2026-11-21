import gleam_bitcoin_node/chain
import gleam_bitcoin_node/utxo

pub fn new() -> chain.Chain {
  chain.new()
}

pub fn submit_block(
  chain: chain.Chain,
  raw: BitArray,
) -> Result(chain.Chain, String) {
  chain.submit_block(chain, raw)
}

pub fn tip_hex(chain: chain.Chain) -> String {
  chain.tip_hex(chain)
}

pub fn utxo_stats(chain: chain.Chain) -> utxo.Stats {
  chain.utxo_stats(chain)
}

pub fn disconnect_tip(chain: chain.Chain) -> Result(chain.Chain, String) {
  chain.disconnect_tip(chain)
}
