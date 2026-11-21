# gleam-bitcoin-node

Port experimental de exnode a Gleam. El paquete se llama `gleam_bitcoin_node`. Este corte solo acepta bloques de regtest que tienen una sola coinbase. No verifica scripts, no habla por la red y no guarda una billetera. No sirve para fondos reales.

Los issues del port completo están en https://github.com/ezeql/gleam-bitcoin-node/issues.

## Probar

No instala nada en la máquina. Hace falta Docker.

```
make test
```

Eso construye una imagen con Gleam y Bitcoin Core 32.1, mina bloques vacíos en regtest y compara el tip. Un bloque con merkle mala y otro con subsidio de más tienen que ser rechazados sin mover el tip.
