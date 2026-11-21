-module(gleam_bitcoin_node_p2p).
-export([handshake_v1/2, handshake_v2/2, addrman_count/0, sync_headers/2, download_blocks/2, fetch_cmpct/3]).

-define(MAGIC, <<16#fa, 16#bf, 16#b5, 16#da>>).
-define(REKEY, 224).

handshake_v1(Host, Port) ->
    try
        Sock = connect(Host, Port),
        ok = gen_tcp:send(Sock, frame(<<"version">>, version_payload())),
        ok = await_verack(Sock, <<>>, false),
        ok = gen_tcp:send(Sock, frame(<<"verack">>, <<>>)),
        remember(v1),
        {ok, nil}
    catch
        _:Reason -> {error, reason(Reason)}
    end.

handshake_v2(Host, Port) ->
    try
        Sock = connect(Host, Port),
        {Sk, Ours} = ellswift_key(),
        ok = gen_tcp:send(Sock, Ours),
        {Buf, Theirs} = read_key(Sock, <<>>),
        Cipher0 = init_cipher(Sk, Ours, Theirs),
        {Cipher1, TermPacket} = encrypt(Cipher0, <<>>, <<>>, false),
        ok = gen_tcp:send(Sock, <<(send_term(Cipher1))/binary, TermPacket/binary>>),
        {Cipher2, Rest} = recv_peer_version(Sock, Cipher1, Buf),
        Version = app_message(<<"version">>, version_payload()),
        {Cipher3, VerPkt} = encrypt(Cipher2, Version, <<>>, false),
        ok = gen_tcp:send(Sock, VerPkt),
        Cipher4 = await_v2_verack(Sock, Cipher3, Rest, false),
        Verack = app_message(<<"verack">>, <<>>),
        {_Cipher5, Ack} = encrypt(Cipher4, Verack, <<>>, false),
        ok = gen_tcp:send(Sock, Ack),
        remember(v2),
        {ok, nil}
    catch
        _:Reason -> {error, reason(Reason)}
    end.

addrman_count() ->
    length(book()).

sync_headers(Host, Port) ->
    try
        Sock = connect(Host, Port),
        ok = gen_tcp:send(Sock, frame(<<"version">>, version_payload())),
        Rest = await_verack_rest(Sock, <<>>),
        ok = gen_tcp:send(Sock, frame(<<"verack">>, <<>>)),
        ok = gen_tcp:send(Sock, frame(<<"getheaders">>, getheaders())),
        Headers = collect_headers(Sock, Rest, []),
        remember(v1),
        {ok, Headers}
    catch
        _:Reason -> {error, reason(Reason)}
    end.

download_blocks(Host, Port) ->
    try
        Sock = connect(Host, Port),
        ok = gen_tcp:send(Sock, frame(<<"version">>, version_payload())),
        Rest0 = await_verack_rest(Sock, <<>>),
        ok = gen_tcp:send(Sock, frame(<<"verack">>, <<>>)),
        ok = gen_tcp:send(Sock, frame(<<"getheaders">>, getheaders())),
        {Headers, Rest} = collect_headers_rest(Sock, Rest0, []),
        Hashes = [block_hash(H) || H <- Headers],
        Got = pipeline(Sock, Hashes, #{}, [], Rest, false),
        remember(v1),
        {ok, [maps:get(H, Got) || H <- Hashes]}
    catch
        _:Reason -> {error, reason(Reason)}
    end.

fetch_cmpct(Host, Port, Hex) ->
    try
        Hash = reverse(binary:decode_hex(Hex)),
        Sock = connect(Host, Port),
        ok = gen_tcp:send(Sock, frame(<<"version">>, version_payload())),
        Rest = await_verack_rest(Sock, <<>>),
        ok = gen_tcp:send(Sock, frame(<<"verack">>, <<>>)),
        ok = gen_tcp:send(Sock, frame(<<"sendcmpct">>, <<0, 2:64/little>>)),
        ok = gen_tcp:send(Sock, frame(<<"getdata">>, <<1, 4:32/little, Hash/binary>>)),
        remember(v1),
        {ok, wait_cmd(Sock, Rest, <<"cmpctblock">>)}
    catch
        _:Reason -> {error, reason(Reason)}
    end.

block_hash(Header) ->
    crypto:hash(sha256, crypto:hash(sha256, Header)).

pipeline(_Sock, [], Got, [], _Buf, _Retried) ->
    Got;
pipeline(Sock, Remaining, Got, Inflight, Buf, Retried) ->
    {Remaining1, Inflight1} = fill_window(Sock, Remaining, Inflight),
    case read_block(Sock, Buf) of
        timeout when Retried ->
            error(stall);
        timeout ->
            ok = send_getdata(Sock, Inflight1),
            pipeline(Sock, Remaining1, Got, Inflight1, <<>>, true);
        {Hash, Raw, Rest} ->
            pipeline(Sock, Remaining1, Got#{Hash => Raw}, lists:delete(Hash, Inflight1), Rest, false)
    end.

fill_window(Sock, Remaining, Inflight) ->
    Room = 16 - length(Inflight),
    case Room > 0 andalso Remaining =/= [] of
        false -> {Remaining, Inflight};
        true ->
            {Ask, Rest} = take(Room, Remaining),
            ok = send_getdata(Sock, Ask),
            {Rest, Inflight ++ Ask}
    end.

take(0, List) -> {[], List};
take(_, []) -> {[], []};
take(N, [H | T]) ->
    {Ask, Rest} = take(N - 1, T),
    {[H | Ask], Rest}.

send_getdata(Sock, Hashes) ->
    Invs = << <<16#40000002:32/little, H/binary>> || H <- Hashes >>,
    gen_tcp:send(Sock, frame(<<"getdata">>, <<(length(Hashes)), Invs/binary>>)).

read_block(Sock, Buf) ->
    case one_frame(Buf) of
        need_more ->
            case gen_tcp:recv(Sock, 0, 3000) of
                {ok, More} -> read_block(Sock, <<Buf/binary, More/binary>>);
                {error, timeout} -> timeout
            end;
        {<<"block">>, Payload, Rest} ->
            {block_hash(binary:part(Payload, 0, 80)), Payload, Rest};
        {<<"ping">>, Nonce, Rest} ->
            ok = gen_tcp:send(Sock, frame(<<"pong">>, Nonce)),
            read_block(Sock, Rest);
        {_, _, Rest} ->
            read_block(Sock, Rest)
    end.

wait_cmd(Sock, Buf, Want) ->
    case one_frame(Buf) of
        need_more ->
            {ok, More} = gen_tcp:recv(Sock, 0, 10000),
            wait_cmd(Sock, <<Buf/binary, More/binary>>, Want);
        {<<"ping">>, Nonce, Rest} ->
            ok = gen_tcp:send(Sock, frame(<<"pong">>, Nonce)),
            wait_cmd(Sock, Rest, Want);
        {Want, Payload, _Rest} ->
            Payload;
        {_, _, Rest} ->
            wait_cmd(Sock, Rest, Want)
    end.

collect_headers_rest(Sock, Buf, Acc) ->
    case one_frame(Buf) of
        need_more ->
            {ok, More} = gen_tcp:recv(Sock, 0, 10000),
            collect_headers_rest(Sock, <<Buf/binary, More/binary>>, Acc);
        {<<"ping">>, Nonce, Rest} ->
            ok = gen_tcp:send(Sock, frame(<<"pong">>, Nonce)),
            collect_headers_rest(Sock, Rest, Acc);
        {<<"headers">>, Payload, Rest} ->
            Batch = parse_headers(Payload),
            Acc1 = Acc ++ Batch,
            case length(Batch) < 2000 of
                true -> {Acc1, Rest};
                false -> collect_headers_rest(Sock, Rest, Acc1)
            end;
        {_, _, Rest} ->
            collect_headers_rest(Sock, Rest, Acc)
    end.

await_verack_rest(Sock, Buf) ->
    case one_frame(Buf) of
        need_more ->
            {ok, More} = gen_tcp:recv(Sock, 0, 10000),
            await_verack_rest(Sock, <<Buf/binary, More/binary>>);
        {<<"verack">>, _, Rest} -> Rest;
        {_, _, Rest} -> await_verack_rest(Sock, Rest)
    end.

getheaders() ->
    <<70016:32/little, 1, (genesis_internal())/binary, 0:256>>.

genesis_internal() ->
    reverse(binary:decode_hex(<<"0f9188f13cb7b2c71f2a335e3a4fc328bf5beb436012afca590b1a11466e2206">>)).

reverse(Bin) ->
    reverse(Bin, <<>>).

reverse(<<>>, Acc) -> Acc;
reverse(<<B, Rest/binary>>, Acc) ->
    reverse(Rest, <<B, Acc/binary>>).

collect_headers(Sock, Buf, Acc) ->
    case one_frame(Buf) of
        need_more ->
            {ok, More} = gen_tcp:recv(Sock, 0, 10000),
            collect_headers(Sock, <<Buf/binary, More/binary>>, Acc);
        {<<"ping">>, Nonce, Rest} ->
            ok = gen_tcp:send(Sock, frame(<<"pong">>, Nonce)),
            collect_headers(Sock, Rest, Acc);
        {<<"headers">>, Payload, Rest} ->
            Batch = parse_headers(Payload),
            Acc1 = Acc ++ Batch,
            case length(Batch) < 2000 of
                true -> Acc1;
                false -> collect_headers(Sock, Rest, Acc1)
            end;
        {_, _, Rest} ->
            collect_headers(Sock, Rest, Acc)
    end.

parse_headers(Bin) ->
    {Count, Rest} = compact(Bin),
    take_hdrs(Count, Rest, []).

take_hdrs(0, _, Acc) ->
    lists:reverse(Acc);
take_hdrs(N, <<Hdr:80/binary, 0, Rest/binary>>, Acc) ->
    take_hdrs(N - 1, Rest, [Hdr | Acc]).

compact(<<N, Rest/binary>>) when N < 253 ->
    {N, Rest};
compact(<<253, N:16/little, Rest/binary>>) ->
    {N, Rest};
compact(<<254, N:32/little, Rest/binary>>) ->
    {N, Rest}.

one_frame(Buf) when byte_size(Buf) < 24 ->
    need_more;
one_frame(<<16#FA, 16#BF, 16#B5, 16#DA, Cmd:12/binary, Len:32/little, _Sum:4/binary, Rest/binary>>) ->
    case byte_size(Rest) >= Len of
        false -> need_more;
        true ->
            <<Payload:Len/binary, Rest2/binary>> = Rest,
            {cmd_bin(Cmd), Payload, Rest2}
    end;
one_frame(_) ->
    error(bad_magic).

cmd_bin(Cmd) ->
    hd(binary:split(Cmd, <<0>>)).

connect(Host, Port) ->
    {ok, Sock} = gen_tcp:connect(binary_to_list(Host), Port, [binary, {active, false}, {nodelay, true}], 10000),
    Sock.

remember(Kind) ->
    persistent_term:put({?MODULE, book}, [{Kind, 127, 0, 0, 1} | book()]).

book() ->
    persistent_term:get({?MODULE, book}, []).

version_payload() ->
    Time = os:system_time(second),
    Nonce = crypto:strong_rand_bytes(8),
    Agent = <<"/gleam-bitcoin-node:0.1.0/">>,
    <<70016:32/little-signed,
      9:64/little,
      Time:64/little-signed,
      (netaddr(9, <<127, 0, 0, 1>>, 18470))/binary,
      (netaddr(9, <<127, 0, 0, 1>>, 0))/binary,
      Nonce/binary,
      (byte_size(Agent)), Agent/binary,
      0:32/little-signed,
      0>>.

netaddr(Services, Ip, Port) ->
    <<Services:64/little, 0:80, 16#FFFF:16, Ip/binary, Port:16/big>>.

frame(Cmd, Payload) ->
    Check = crypto:hash(sha256, crypto:hash(sha256, Payload)),
    <<Sum:4/binary, _/binary>> = Check,
    <<?MAGIC/binary, (pad(Cmd))/binary, (byte_size(Payload)):32/little, Sum/binary, Payload/binary>>.

pad(Cmd) ->
    N = byte_size(Cmd),
    <<Cmd/binary, 0:( (12 - N) * 8 )>>.

await_verack(Sock, Buf, Seen) ->
    {Frames, Rest} = frames(Buf),
    Seen1 = lists:member(verack, Frames) orelse Seen,
    case Seen1 of
        true -> ok;
        false ->
            {ok, More} = gen_tcp:recv(Sock, 0, 10000),
            await_verack(Sock, <<Rest/binary, More/binary>>, Seen1)
    end.

frames(Buf) ->
    frames(Buf, []).

frames(Buf, Acc) when byte_size(Buf) < 24 ->
    {lists:reverse(Acc), Buf};
frames(<<16#FA, 16#BF, 16#B5, 16#DA, Cmd:12/binary, Len:32/little, _Sum:4/binary, Rest/binary>> = Buf, Acc) ->
    case byte_size(Rest) >= Len of
        false -> {lists:reverse(Acc), Buf};
        true ->
            <<_Payload:Len/binary, Rest2/binary>> = Rest,
            Name = cmd_name(Cmd),
            frames(Rest2, [Name | Acc])
    end;
frames(_, Acc) ->
    {lists:reverse(Acc), <<>>}.

cmd_name(Cmd) ->
    Name = hd(binary:split(Cmd, <<0>>)),
    case Name of
        <<"verack">> -> verack;
        <<"version">> -> version;
        _ -> other
    end.

ellswift_key() ->
    Sk = crypto:strong_rand_bytes(32),
    Aux = crypto:strong_rand_bytes(32),
    case gleam_bitcoin_node_secp:create(Sk, Aux) of
        {ok, Ell} -> {Sk, Ell};
        error -> ellswift_key()
    end.

read_key(_Sock, Buf) when byte_size(Buf) >= 64 ->
    <<Theirs:64/binary, Rest/binary>> = Buf,
    {Rest, Theirs};
read_key(Sock, Buf) ->
    {ok, More} = gen_tcp:recv(Sock, 0, 10000),
    read_key(Sock, <<Buf/binary, More/binary>>).

init_cipher(Sk, Ours, Theirs) ->
    {ok, Ecdh} = gleam_bitcoin_node_secp:xdh(Ours, Theirs, Sk, 0),
    Prk = crypto:mac(hmac, sha256, <<"bitcoin_v2_shared_secret", ?MAGIC/binary>>, Ecdh),
    Expand = fun(Info) -> crypto:mac(hmac, sha256, Prk, <<Info/binary, 1>>) end,
    Terms = Expand(<<"garbage_terminators">>),
    <<SendTerm:16/binary, RecvTerm:16/binary>> = Terms,
    #{
        send_l => fs_new(Expand(<<"initiator_L">>)),
        send_p => aead_new(Expand(<<"initiator_P">>)),
        recv_l => fs_new(Expand(<<"responder_L">>)),
        recv_p => aead_new(Expand(<<"responder_P">>)),
        send_term => SendTerm,
        recv_term => RecvTerm
    }.

send_term(#{send_term := T}) -> T.

recv_peer_version(Sock, Cipher, Buf) ->
    Term = maps:get(recv_term, Cipher),
    case find_term(Buf, Term) of
        need_more ->
            {ok, More} = gen_tcp:recv(Sock, 0, 10000),
            recv_peer_version(Sock, Cipher, <<Buf/binary, More/binary>>);
        {Garbage, Rest} ->
            {Cipher1, Contents, Rest1} = read_packet(Sock, Cipher, Rest, Garbage),
            <<>> = Contents,
            {Cipher1, Rest1}
    end.

find_term(Buf, Term) ->
    case binary:match(Buf, Term) of
        {Pos, 16} when Pos =< 4095 ->
            <<Garbage:Pos/binary, _:16/binary, Rest/binary>> = Buf,
            {Garbage, Rest};
        nomatch when byte_size(Buf) > 4095 + 16 ->
            error(missing_terminator);
        nomatch ->
            need_more
    end.

read_packet(Sock, Cipher, Buf, Aad) ->
    Buf1 = fill(Sock, Buf, 3),
    <<LenEnc:3/binary, Rest/binary>> = Buf1,
    {RecvL, PlainLen} = fs_crypt(maps:get(recv_l, Cipher), LenEnc),
    <<Len:24/little>> = PlainLen,
    Need = Len + 17,
    Rest1 = fill(Sock, Rest, Need),
    <<Packet:Need/binary, Rest2/binary>> = Rest1,
    {RecvP, Result} = aead_decrypt(maps:get(recv_p, Cipher), Packet, Aad),
    {ok, <<_Header, Contents/binary>>} = Result,
    {Cipher#{recv_l => RecvL, recv_p => RecvP}, Contents, Rest2}.

fill(_Sock, Buf, N) when byte_size(Buf) >= N -> Buf;
fill(Sock, Buf, N) ->
    {ok, More} = gen_tcp:recv(Sock, 0, 10000),
    fill(Sock, <<Buf/binary, More/binary>>, N).

await_v2_verack(Sock, Cipher, Buf, Seen) ->
    case Seen of
        true -> Cipher;
        false ->
            {Cipher1, Contents, Rest} = read_packet(Sock, Cipher, Buf, <<>>),
            Seen1 = is_verack(Contents) orelse Seen,
            await_v2_verack(Sock, Cipher1, Rest, Seen1)
    end.

is_verack(<<0, "verack", _Pad:6/binary, _/binary>>) -> true;
is_verack(_) -> false.

app_message(Cmd, Payload) ->
    <<0, (pad(Cmd))/binary, Payload/binary>>.

encrypt(Cipher, Contents, Aad, Ignore) ->
    Header = case Ignore of true -> 16#80; false -> 0 end,
    {SendL, Len} = fs_crypt(maps:get(send_l, Cipher), <<(byte_size(Contents)):24/little>>),
    {SendP, Body} = aead_encrypt(maps:get(send_p, Cipher), <<Header, Contents/binary>>, Aad),
    {Cipher#{send_l => SendL, send_p => SendP}, <<Len/binary, Body/binary>>}.

fs_new(Key) ->
    #{key => Key, rekey => 0, chunk => 0, stream => chacha(Key, 0)}.

chacha(Key, Rekey) ->
    crypto:crypto_init(chacha20, Key, <<0:32, 0:32, Rekey:64/little>>, true).

fs_crypt(St, Input) ->
    Out = iolist_to_binary(crypto:crypto_update(maps:get(stream, St), Input)),
    case maps:get(chunk, St) + 1 of
        ?REKEY ->
            NewKey = iolist_to_binary(crypto:crypto_update(maps:get(stream, St), <<0:256>>)),
            Rekey = maps:get(rekey, St) + 1,
            {St#{key => NewKey, rekey => Rekey, chunk => 0, stream => chacha(NewKey, Rekey)}, Out};
        Chunk ->
            {St#{chunk => Chunk}, Out}
    end.

aead_new(Key) ->
    #{key => Key, packet => 0, rekey => 0}.

nonce(#{packet := P, rekey := R}) ->
    <<P:32/little, R:64/little>>.

aead_encrypt(St, Plain, Aad) ->
    {Ct, Tag} = crypto:crypto_one_time_aead(chacha20_poly1305, maps:get(key, St), nonce(St), Plain, Aad, 16, true),
    {next_packet(St), <<Ct/binary, Tag/binary>>}.

aead_decrypt(St, Input, Aad) ->
    CtLen = byte_size(Input) - 16,
    <<Ct:CtLen/binary, Tag:16/binary>> = Input,
    Result = case crypto:crypto_one_time_aead(chacha20_poly1305, maps:get(key, St), nonce(St), Ct, Aad, Tag, false) of
        error -> error;
        Plain -> {ok, Plain}
    end,
    {next_packet(St), Result}.

next_packet(St = #{packet := P, rekey := R, key := Key}) ->
    case P + 1 of
        ?REKEY ->
            Iv = <<1:32/little, 16#FFFFFFFF:32/little, R:64/little>>,
            NewKey = crypto:crypto_one_time(chacha20, Key, Iv, <<0:256>>, true),
            St#{key => NewKey, packet => 0, rekey => R + 1};
        N ->
            St#{packet => N}
    end.

reason(Reason) ->
    iolist_to_binary(io_lib:format("~p", [Reason])).
