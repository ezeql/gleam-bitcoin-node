import gleam_bitcoin_node/chain
import gleam_bitcoin_node/mempool
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

pub fn new_mempool() -> mempool.Pool {
  mempool.new()
}

pub fn test_package(
  chain: chain.Chain,
  pool: mempool.Pool,
  raws: List(BitArray),
) -> Result(List(mempool.Verdict), String) {
  mempool.test_package(chain, pool, raws)
}

pub fn send_raw(
  chain: chain.Chain,
  pool: mempool.Pool,
  raw: BitArray,
) -> Result(#(mempool.Pool, String), String) {
  mempool.send_raw(chain, pool, raw)
}

pub fn relay_inv(pool: mempool.Pool) -> List(String) {
  mempool.relay_inv(pool)
}
