import gleam_bitcoin_node/limits
import gleam_bitcoin_node/params

@external(erlang, "gleam_bitcoin_node_p2p", "handshake_v1")
pub fn handshake_v1(host: String, port: Int) -> Result(Nil, String)

@external(erlang, "gleam_bitcoin_node_p2p", "handshake_v2")
pub fn handshake_v2(host: String, port: Int) -> Result(Nil, String)

@external(erlang, "gleam_bitcoin_node_p2p", "addrman_count")
pub fn addrman_count() -> Int

@external(erlang, "gleam_bitcoin_node_p2p", "sync_headers")
pub fn sync_headers(host: String, port: Int) -> Result(List(BitArray), String)

@external(erlang, "gleam_bitcoin_node_p2p", "download_blocks")
pub fn download_blocks(
  host: String,
  port: Int,
) -> Result(List(BitArray), String)

@external(erlang, "gleam_bitcoin_node_p2p", "fetch_cmpct")
pub fn fetch_cmpct(
  host: String,
  port: Int,
  hash: String,
) -> Result(BitArray, String)

@external(erlang, "gleam_bitcoin_node_p2p", "hostile")
pub fn hostile(port: Int) -> Result(Nil, String)

@external(erlang, "gleam_bitcoin_node_p2p", "pull_abuse")
fn pull_abuse(host: String, port: Int) -> Result(BitArray, String)

pub fn punish(host: String, port: Int) -> Result(String, String) {
  case pull_abuse(host, port) {
    Error(reason) -> Error(reason)
    Ok(bytes) ->
      case limits.absorb(params.regtest().magic, bytes) {
        Error(reason) -> Ok(reason)
        Ok(_) -> Error("peer-kept")
      }
  }
}
