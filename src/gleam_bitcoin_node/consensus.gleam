import gleam/bit_array
import gleam/int
import gleam/list
import gleam_bitcoin_node/hash
import gleam_bitcoin_node/script
import gleam_bitcoin_node/tx

const max_money = 2_100_000_000_000_000

const max_block_sigops_cost = 80_000

const sequence_final = 0xffffffff

const locktime_threshold = 500_000_000

const coinbase_maturity = 100

pub type Coin {
  Coin(value: Int, script: BitArray, height: Int, coinbase: Bool)
}

pub fn is_coinbase(tx: tx.Tx) -> Bool {
  case tx.inputs {
    [input] -> null_input(input)
    _ -> False
  }
}

pub fn is_final(tx: tx.Tx, height: Int, cutoff: Int) -> Bool {
  case tx.locktime {
    0 -> True
    locktime -> {
      let limit = case locktime < locktime_threshold {
        True -> height
        False -> cutoff
      }
      locktime < limit || list.all(tx.inputs, fn(input) { input.sequence == sequence_final })
    }
  }
}

pub fn sequence_ok(
  tx: tx.Tx,
  coins: List(Coin),
  csv: Bool,
  height: Int,
  prev_mtp: Int,
  coin_mtp: fn(Int) -> Int,
) -> Bool {
  case tx.version < 2 || csv == False {
    True -> True
    False -> {
      let #(min_height, min_time) = relative(tx.inputs, coins, -1, -1, coin_mtp)
      case min_height == -1 && min_time == -1 {
        True -> True
        False -> min_height < height && min_time < prev_mtp
      }
    }
  }
}

pub fn check_tx(tx: tx.Tx) -> Result(Nil, String) {
  case tx.inputs {
    [] -> Error("bad-txns-vin-empty")
    _ ->
      case tx.outputs {
        [] -> Error("bad-txns-vout-empty")
        _ ->
          case tx.base_size * 4 > 4_000_000 {
            True -> Error("bad-txns-oversize")
            False ->
              case check_outputs(tx.outputs, 0) {
                Error(reason) -> Error(reason)
                Ok(_) ->
                  case duplicate_inputs(tx.inputs, []) {
                    Error(reason) -> Error(reason)
                    Ok(_) -> coinbase_or_prevouts(tx)
                  }
              }
          }
      }
  }
}

pub fn fee(tx: tx.Tx, coins: List(Coin), height: Int) -> Result(Int, String) {
  case input_sum(coins, height, 0) {
    Error(reason) -> Error(reason)
    Ok(value_in) -> {
      let value_out = output_sum(tx.outputs)
      case value_in < value_out {
        True -> Error("bad-txns-in-belowout")
        False -> {
          let fee = value_in - value_out
          case fee < 0 || fee > max_money {
            True -> Error("bad-txns-fee-outofrange")
            False -> Ok(fee)
          }
        }
      }
    }
  }
}

pub fn sigop_cost(tx: tx.Tx, coins: List(Coin), coinbase: Bool) -> Int {
  let legacy = legacy_sigops(tx) * 4
  case coinbase {
    True -> legacy
    False -> legacy + p2sh_sigops(tx.inputs, coins, 0) * 4 + witness_sigops(tx.inputs, coins, 0)
  }
}

pub fn too_many_sigops(total: Int) -> Bool {
  total > max_block_sigops_cost
}

pub fn output_sum(outputs: List(tx.Output)) -> Int {
  list.fold(outputs, 0, fn(sum, output) { sum + output.value })
}

pub fn money_ok(value: Int) -> Bool {
  value >= 0 && value <= max_money
}

fn relative(
  inputs: List(tx.Input),
  coins: List(Coin),
  min_height: Int,
  min_time: Int,
  coin_mtp: fn(Int) -> Int,
) -> #(Int, Int) {
  case inputs {
    [] -> #(min_height, min_time)
    [input, ..inputs] ->
      case coins {
        [] -> #(min_height, min_time)
        [coin, ..coins] -> {
          let #(min_height, min_time) = case int.bitwise_and(input.sequence, 0x80000000) != 0 {
            True -> #(min_height, min_time)
            False ->
              case int.bitwise_and(input.sequence, 0x00400000) != 0 {
                True -> {
                  let ancestor = int.max(coin.height - 1, 0)
                  let locked =
                    coin_mtp(ancestor)
                    + int.bitwise_shift_left(int.bitwise_and(input.sequence, 0xffff), 9)
                    - 1
                  #(min_height, int.max(min_time, locked))
                }
                False -> #(
                  int.max(
                    min_height,
                    coin.height + int.bitwise_and(input.sequence, 0xffff) - 1,
                  ),
                  min_time,
                )
              }
          }
          relative(inputs, coins, min_height, min_time, coin_mtp)
        }
      }
  }
}

fn legacy_sigops(tx: tx.Tx) -> Int {
  let inputs =
    list.fold(tx.inputs, 0, fn(total, input) {
      total + script.sigop_count(input.script_sig, False)
    })
  let outputs =
    list.fold(tx.outputs, 0, fn(total, output) {
      total + script.sigop_count(output.script_pubkey, False)
    })
  inputs + outputs
}

fn p2sh_sigops(inputs: List(tx.Input), coins: List(Coin), total: Int) -> Int {
  case inputs {
    [] -> total
    [input, ..inputs] ->
      case coins {
        [] -> total
        [coin, ..coins] -> {
          let total = case script.is_p2sh(coin.script) {
            True -> total + script.p2sh_sigops(coin.script, input.script_sig)
            False -> total
          }
          p2sh_sigops(inputs, coins, total)
        }
      }
  }
}

fn witness_sigops(inputs: List(tx.Input), coins: List(Coin), total: Int) -> Int {
  case inputs {
    [] -> total
    [input, ..inputs] ->
      case coins {
        [] -> total
        [coin, ..coins] ->
          witness_sigops(
            inputs,
            coins,
            total
              + script.witness_sigops(input.script_sig, coin.script, input.witness, True),
          )
      }
  }
}

fn input_sum(coins: List(Coin), height: Int, total: Int) -> Result(Int, String) {
  case coins {
    [] -> Ok(total)
    [coin, ..rest] -> {
      let total = total + coin.value
      case coin.coinbase && height - coin.height < coinbase_maturity {
        True -> Error("bad-txns-premature-spend-of-coinbase")
        False ->
          case money_ok(coin.value) == False || money_ok(total) == False {
            True -> Error("bad-txns-inputvalues-outofrange")
            False -> input_sum(rest, height, total)
          }
      }
    }
  }
}

fn check_outputs(outputs: List(tx.Output), total: Int) -> Result(Nil, String) {
  case outputs {
    [] -> Ok(Nil)
    [output, ..rest] ->
      case output.value < 0 {
        True -> Error("bad-txns-vout-negative")
        False ->
          case output.value > max_money {
            True -> Error("bad-txns-vout-toolarge")
            False ->
              case money_ok(total + output.value) == False {
                True -> Error("bad-txns-txouttotal-toolarge")
                False -> check_outputs(rest, total + output.value)
              }
          }
      }
  }
}

fn duplicate_inputs(inputs: List(tx.Input), seen: List(String)) -> Result(Nil, String) {
  case inputs {
    [] -> Ok(Nil)
    [input, ..rest] -> {
      let key = outpoint(input.prev_hash, input.prev_index)
      case list.contains(seen, key) {
        True -> Error("bad-txns-inputs-duplicate")
        False -> duplicate_inputs(rest, [key, ..seen])
      }
    }
  }
}

fn coinbase_or_prevouts(tx: tx.Tx) -> Result(Nil, String) {
  case is_coinbase(tx) {
    True -> {
      let assert [input] = tx.inputs
      let size = bit_array.byte_size(input.script_sig)
      case size < 2 || size > 100 {
        True -> Error("bad-cb-length")
        False -> Ok(Nil)
      }
    }
    False ->
      case list.any(tx.inputs, null_input) {
        True -> Error("bad-txns-prevout-null")
        False -> Ok(Nil)
      }
  }
}

fn null_input(input: tx.Input) -> Bool {
  input.prev_hash == <<0:size(256)>> && input.prev_index == 0xffffffff
}

fn outpoint(hash: BitArray, index: Int) -> String {
  hash.display(hash) <> ":" <> int.to_string(index)
}
