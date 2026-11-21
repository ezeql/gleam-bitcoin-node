-module(gleam_bitcoin_node_kernel).
-export([verify/3]).
-on_load(load/0).

load() ->
    erlang:load_nif("/usr/local/lib/gleam_kernel_nif", 0).

verify(Tx, Spent, Flags) ->
    case verify_nif(Tx, Spent, Flags) of
        {ok, true} -> {ok, true};
        {ok, false} -> {ok, false};
        {error, Atom} -> {error, atom_to_binary(Atom, utf8)}
    end.

verify_nif(_Tx, _Spent, _Flags) ->
    erlang:nif_error(nif_not_loaded).
