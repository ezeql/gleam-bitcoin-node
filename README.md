# gleam-bitcoin-node

Experimental Gleam port of exnode. The package name is `gleam_bitcoin_node`. This cut connects regtest blocks, verifies scripts with libbitcoinkernel v32.1, and stores outputs, inputs, and witnesses only inside Docker. `hash_serialized_3` is the hash of the active UTXO set. More work replaces the tip. Equal work does not move it, and a reorg disconnects and reconnects. The P2P transport completes version/verack for v1 and for BIP324. Headers are requested with getheaders. Bodies are downloaded 16 at a time, and a compact block rebuilds to the same hash. The mempool accepts a package and rejects a replacement that pays a lower fee, matching `testmempoolaccept` and `sendrawtransaction`. A peer that sends a message over the size limit, or that fills the decode budget, the send buffer, or the orphan cap, is disconnected. The tip and the mempool stay as they were. Esplora serves the tip, the block, the transaction, the address, its UTXOs, and `POST /tx`. The scripthash index rewinds on a reorg. Chain JSON-RPC serves `getblockchaininfo`, `getblock`, `gettxout`, `getrawtransaction`, `gettxoutsetinfo`, and `submitblock` with the same tip, the same `hash_serialized_3`, and the same BIP22 reason as bitcoind. The basic BIP158 filter uses GCS with P=19 and M=784931. Its header and the `getcfilters`/`cfheaders` messages match Core `getblockfilter`. Shadow, a dataset replay, and the differential property leave the same tip and the same verdict as Core. Consensus flags depend on height. assumevalid set to zero does not skip those checks. It does not store the chain on disk, it does not listen on the network, and it does not keep a wallet. It is not safe for real funds.

The issues for the full port are at https://github.com/ezeql/gleam-bitcoin-node/issues.

## Test

Nothing is installed on the machine. Docker is required.

```
make test
```

That also runs `gleam format --check` and `gleam build --warnings-as-errors` inside the image. Those are the checks Gleam documents for CI: the official formatter and compiler warnings.

It builds an image with Gleam and Bitcoin Core 32.1, mines empty regtest blocks, and compares the tip. A block with a bad merkle root is rejected and the tip stays put. bitcoind and Gleam `submitblock` return the same reason for bad-cb-amount, bad-txns-nonfinal, and bad-cb-height. A block with a real spend is accepted. An invalid script does not move the tip. The genesis hash of mainnet, testnet, testnet4, signet, and regtest must match bitcoind. Headers mined by bitcoind are accepted. One with illegal bits or time does not move the header tip.
