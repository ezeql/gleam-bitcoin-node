-module(gleam_bitcoin_node_secp).
-export([create/2, xdh/4]).
-on_load(load/0).

load() ->
    erlang:load_nif("/usr/local/lib/gleam_secp_nif", 0).

create(Sk, Aux) ->
    create_nif(Sk, Aux).

xdh(A, B, Sk, Party) ->
    xdh_nif(A, B, Sk, Party).

create_nif(_Sk, _Aux) ->
    erlang:nif_error(nif_not_loaded).

xdh_nif(_A, _B, _Sk, _Party) ->
    erlang:nif_error(nif_not_loaded).
