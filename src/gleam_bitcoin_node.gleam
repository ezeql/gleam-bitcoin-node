import gleam_bitcoin_node/chain

pub fn new() -> chain.Chain {
  chain.new()
}

pub fn submit_block(chain: chain.Chain, raw: BitArray) -> Result(chain.Chain, String) {
  chain.submit_block(chain, raw)
}

pub fn tip_hex(chain: chain.Chain) -> String {
  chain.tip_hex(chain)
}
