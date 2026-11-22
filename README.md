# gleam-bitcoin-node

A Bitcoin node written in Gleam. Experimental port of [exnode](https://github.com/ezeql/exnode).

> **Status: experimental. Do not use it with real funds.**

The package name is `gleam_bitcoin_node`. It connects regtest blocks, checks scripts with Bitcoin Core v32.1 **libbitcoinkernel**, and keeps the archive inside Docker. It does not listen for peers, it does not keep a wallet, and it does not resume a chain on the host. Lightning is out of this cut.

The issues for the port are at <https://github.com/ezeql/gleam-bitcoin-node/issues>.

## How it works

The library is one chain value plus the modules that feed it. There is no supervision tree.

```
gleam_bitcoin_node
├─ params, pow, headers     five networks, proof of work, header rules
├─ codec, tx, merkle        blocks, transactions, txid and witness roots
├─ chain, consensus         connect, disconnect, and pick the most work
├─ kernel, script           libbitcoinkernel v32.1, flags by height
├─ utxo                     active set and hash_serialized_3
├─ p2p, limits, compact     v1 and BIP324, headers, blocks, DoS caps
├─ mempool                  packages and replacement
└─ rpc, esplora, filter     JSON-RPC, Esplora, BIP158
```

Public entry points are in [`gleam_bitcoin_node`](src/gleam_bitcoin_node.gleam). Chain selection is in [`chain`](src/gleam_bitcoin_node/chain.gleam).

### A block from bitcoind to the tip

1. **P2P** completes `version`/`verack` on v1 or BIP324, then asks for headers with `getheaders`. Bodies are not requested during header sync.
2. **Headers** checks proof of work, bits, version, and time. More work moves the header tip. Illegal bits or time do not.
3. **Download** pulls bodies 16 at a time. A compact block is rebuilt to the same hash.
4. **Chain** checks the merkle root, the coinbase, and the subsidy, then connects the block. An invalid script does not move the tip.
5. **Kernel** runs the scripts. Consensus flags follow the height. `assumevalid` set to zero does not skip those checks.
6. **UTXO** records outputs, inputs, and witnesses for the active chain. `hash_serialized_3` is the hash of that set. More work replaces the tip. Equal work does not. A reorg disconnects and reconnects, and the scripthash index rewinds with it.

## Storage

Outputs, inputs, and witnesses are append-only segment files under `/tmp/gleam-archive` inside the container. `make test` uses `docker run --rm`, so those files go away with the container. There is no host datadir.

## Surfaces

These answers are checked against bitcoind in `make test`.

| Surface | What matches |
|---|---|
| JSON-RPC | `getblockchaininfo`, `getblockhash`, `getblock`, `gettxout`, `getrawtransaction`, `gettxoutsetinfo`, `submitblock`. Same tip, same `hash_serialized_3`, same BIP22 reason. |
| Esplora | `/blocks/tip/hash`, `/blocks/tip/height`, `/block/:hash`, `/tx/:txid`, `/address/:addr`, `/address/:addr/utxo`, `POST /tx`. |
| BIP158 | Basic filter, GCS P=19 and M=784931. Header and `getcfilters`/`cfheaders` match `getblockfilter`. |
| Mempool | An accepted package and a replacement that pays less. Same verdict as `testmempoolaccept` and `sendrawtransaction`. |
| DoS | An oversized message, a full decode budget, a full send buffer, or a full orphan cap disconnects the peer. The tip and the mempool stay as they were. |
| Shadow | A valid block and a bad coinbase get Core's verdict. A dataset replay ends at the manifest hash. |

`submitblock` of bitcoind and Gleam return the same reason for `bad-cb-amount`, `bad-txns-nonfinal`, and `bad-cb-height`. Genesis hashes for mainnet, testnet, testnet4, signet, and regtest match `getblockhash 0`.

## Tests

Nothing is installed on the machine. Docker is required.

```sh
make test
```

The image build runs the checks Gleam documents for CI, then the end-to-end tests:

```sh
gleam format --check
gleam build --warnings-as-errors
```

`make test` builds an image with Gleam and Bitcoin Core 32.1, mines empty regtest blocks, and compares the tip. A block with a bad merkle root is rejected and the tip stays put. A block with a real spend is accepted. Headers mined by bitcoind are accepted. One with illegal bits or time does not move the header tip.

## License

MIT. See [`LICENSE`](LICENSE).
