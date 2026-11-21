#!/bin/sh
set -eu

start_chain() {
  name="$1"
  shift
  dir="/tmp/btc-$name"
  mkdir -p "$dir"
  bitcoind "$@" -datadir="$dir" -daemonwait \
    -rpcuser=e2e -rpcpassword=e2e \
    -listen=0 -dnsseed=0 -connect=0
}

start_chain regtest -regtest -fallbackfee=0.0002 -txindex=1
start_chain main
start_chain test -testnet
start_chain testnet4 -testnet4
start_chain signet -signet

cd /src
gleam test
bitcoin-cli -regtest -rpcuser=e2e -rpcpassword=e2e stop
bitcoin-cli -rpcuser=e2e -rpcpassword=e2e stop
bitcoin-cli -testnet -rpcuser=e2e -rpcpassword=e2e stop
bitcoin-cli -testnet4 -rpcuser=e2e -rpcpassword=e2e stop
bitcoin-cli -signet -rpcuser=e2e -rpcpassword=e2e stop
