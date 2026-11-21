#!/bin/sh
set -eu
mkdir -p /tmp/btc
bitcoind -regtest -datadir=/tmp/btc -daemonwait \
  -rpcuser=e2e -rpcpassword=e2e -fallbackfee=0.0002 \
  -listen=0 -txindex=1
cd /src
gleam test
bitcoin-cli -regtest -datadir=/tmp/btc -rpcuser=e2e -rpcpassword=e2e stop
