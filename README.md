# gleam-bitcoin-node

Port experimental de exnode a Gleam. El paquete se llama `gleam_bitcoin_node`. Este corte conecta bloques de regtest, verifica los scripts con libbitcoinkernel v32.1 y guarda outputs, inputs y witnesses solo dentro de Docker. `hash_serialized_3` es el del UTXO activo. Más trabajo reemplaza el tip; igual trabajo no lo mueve, y un reorg desconecta y reconecta. El transporte P2P completa version/verack en v1 y en BIP324. Las cabeceras se piden con getheaders. Los cuerpos bajan de a 16, y un compact block se reconstruye al mismo hash. El mempool acepta un paquete y rechaza un reemplazo con fee de menos, igual que `testmempoolaccept` y `sendrawtransaction`. Un par que manda un mensaje más largo que el límite, o que llena el presupuesto de decode, el búfer de envío o el cupo de huérfanos, se desconecta; el tip y el mempool quedan como estaban. Esplora responde el tip, el bloque, la tx, la dirección, sus UTXO y `POST /tx`; el índice de scripthash se rebobina en un reorg. Los flags de consenso dependen de la altura; assumevalid en cero no salta esas pruebas. No guarda la cadena en disco, no habla por la red y no guarda una billetera. No sirve para fondos reales.

Los issues del port completo están en https://github.com/ezeql/gleam-bitcoin-node/issues.

## Probar

No instala nada en la máquina. Hace falta Docker.

```
make test
```

Eso también corre, dentro de la imagen, `gleam format --check` y `gleam build --warnings-as-errors`. Son los controles que Gleam documenta para CI: el formateador oficial y las advertencias del compilador.

Eso construye una imagen con Gleam y Bitcoin Core 32.1, mina bloques vacíos en regtest y compara el tip. Un bloque con merkle mala se rechaza sin mover el tip. `submitblock` de bitcoind y Gleam dan la misma razón para bad-cb-amount, bad-txns-nonfinal y bad-cb-height. Un bloque con un gasto real se acepta; un script inválido no mueve el tip. El hash de génesis de mainnet, testnet, testnet4, signet y regtest tiene que coincidir con bitcoind. Las cabeceras que mina bitcoind se aceptan; una con bits o tiempo ilegal no mueve el tip de cabeceras.
