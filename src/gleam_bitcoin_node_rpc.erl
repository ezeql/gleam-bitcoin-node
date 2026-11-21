-module(gleam_bitcoin_node_rpc).
-export([start/1, publish/1]).

start(Port) ->
    Opts = [binary, {active, false}, {reuseaddr, true}],
    case gen_tcp:listen(Port, Opts) of
        {ok, Listen} ->
            Pid = spawn(fun() -> serve(undefined, Listen) end),
            true = erlang:register(gleam_rpc, Pid),
            {ok, nil};
        {error, Reason} ->
            {error, iolist_to_binary(io_lib:format("~p", [Reason]))}
    end.

publish(View) ->
    gleam_rpc ! {publish, self(), View},
    receive
        published -> nil
    after 2000 ->
        nil
    end.

serve(View, Listen) ->
    receive
        {publish, From, New} ->
            From ! published,
            serve(New, Listen)
    after 0 ->
        case gen_tcp:accept(Listen, 100) of
            {ok, Sock} ->
                View1 = take_publish(View),
                View2 = reply(Sock, View1),
                serve(View2, Listen);
            {error, timeout} ->
                serve(View, Listen);
            {error, closed} ->
                ok
        end
    end.

take_publish(View) ->
    receive
        {publish, From, New} ->
            From ! published,
            New
    after 0 ->
        View
    end.

reply(Sock, undefined) ->
    send_resp(Sock, 503, <<"{\"result\":null,\"error\":{\"code\":-28,\"message\":\"starting\"},\"id\":null}">>),
    gen_tcp:close(Sock),
    undefined;
reply(Sock, View) ->
    Next =
        try
            Body = read_body(Sock),
            {Resp, View2} = gleam_bitcoin_node@rpc:handle(View, Body),
            send_resp(Sock, 200, Resp),
            View2
        catch
            _:Reason ->
                Text = iolist_to_binary(io_lib:format("~p", [Reason])),
                send_resp(Sock, 500, <<"{\"result\":null,\"error\":{\"code\":-1,\"message\":", Text/binary, "},\"id\":null}">>),
                View
        end,
    gen_tcp:close(Sock),
    Next.

read_body(Sock) ->
    read_head(Sock, <<>>).

read_head(Sock, Buf) ->
    case binary:split(Buf, <<"\r\n\r\n">>) of
        [Head, Rest] ->
            Len = content_length(binary:split(Head, <<"\r\n">>, [global])),
            take(Sock, Rest, Len);
        _ ->
            {ok, More} = gen_tcp:recv(Sock, 0, 5000),
            read_head(Sock, <<Buf/binary, More/binary>>)
    end.

content_length([<<"Content-Length: ", Rest/binary>> | _]) ->
    binary_to_integer(string:trim(Rest));
content_length([<<"content-length: ", Rest/binary>> | _]) ->
    binary_to_integer(string:trim(Rest));
content_length([_ | Rest]) ->
    content_length(Rest);
content_length([]) ->
    0.

take(_Sock, Buf, Len) when byte_size(Buf) >= Len ->
    <<Body:Len/binary, _/binary>> = Buf,
    Body;
take(Sock, Buf, Len) ->
    {ok, More} = gen_tcp:recv(Sock, 0, 5000),
    take(Sock, <<Buf/binary, More/binary>>, Len).

send_resp(Sock, Status, Body) ->
    Bin = iolist_to_binary(Body),
    Reason = case Status of 200 -> <<"OK">>; _ -> <<"Error">> end,
    gen_tcp:send(Sock, [
        <<"HTTP/1.1 ">>, integer_to_binary(Status), <<" ">>, Reason,
        <<"\r\nContent-Type: application/json\r\nContent-Length: ">>,
        integer_to_binary(byte_size(Bin)),
        <<"\r\nConnection: close\r\n\r\n">>,
        Bin
    ]).
