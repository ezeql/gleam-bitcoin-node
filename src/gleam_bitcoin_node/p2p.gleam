@external(erlang, "gleam_bitcoin_node_p2p", "handshake_v1")
pub fn handshake_v1(host: String, port: Int) -> Result(Nil, String)

@external(erlang, "gleam_bitcoin_node_p2p", "handshake_v2")
pub fn handshake_v2(host: String, port: Int) -> Result(Nil, String)

@external(erlang, "gleam_bitcoin_node_p2p", "addrman_count")
pub fn addrman_count() -> Int

@external(erlang, "gleam_bitcoin_node_p2p", "sync_headers")
pub fn sync_headers(host: String, port: Int) -> Result(List(BitArray), String)
