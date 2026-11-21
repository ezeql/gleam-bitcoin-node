# gleam-bitcoin-node

Port experimental de exnode a Gleam. El paquete se llama `gleam_bitcoin_node`. Este corte conecta bloques de regtest sin ejecutar scripts: BIP30, comisiones, locktime, BIP68, sigops, peso y malleación del testigo. No usa libbitcoinkernel ni disco, no habla por la red y no guarda una billetera. No sirve para fondos reales.

Los issues del port completo están en https://github.com/ezeql/gleam-bitcoin-node/issues.

## Probar

No instala nada en la máquina. Hace falta Docker.

```
make test
```

Eso construye una imagen con Gleam y Bitcoin Core 32.1, mina bloques vacíos en regtest y compara el tip. Un bloque con merkle mala se rechaza sin mover el tip. `submitblock` de bitcoind y Gleam dan la misma razón para bad-cb-amount, bad-txns-nonfinal y bad-cb-height. El hash de génesis de mainnet, testnet, testnet4, signet y regtest tiene que coincidir con bitcoind. Las cabeceras que mina bitcoind se aceptan; una con bits o tiempo ilegal no mueve el tip de cabeceras.
