-module(gleam_bitcoin_node_ffi).
-export([sha256/1, cmd/1, hex_encode/1, hex_decode/1]).

sha256(Bin) ->
    crypto:hash(sha256, Bin).

cmd(Command) when is_binary(Command) ->
    cmd(binary_to_list(Command));
cmd(Command) ->
    Output = os:cmd(Command),
    case unicode:characters_to_binary(Output) of
        Bin when is_binary(Bin) -> Bin;
        _ -> <<>>
    end.

hex_encode(Bin) ->
    string:lowercase(binary:encode_hex(Bin)).

hex_decode(Hex) ->
    try binary:decode_hex(Hex) of
        Bin -> {ok, Bin}
    catch
        _:_ -> {error, nil}
    end.
