-module(dalmatiner_idx_handler).
-behaviour(cowboy_http_handler).

-export([send/4, content_type/1, allowed_methods/2, init/3, handle/2,
         terminate/3]).

-ignore_xref([init/3, handle/2, terminate/3]).

init(_Transport, Req, []) ->
    {ok, Req, undefined}.

allowed_methods(Req, State) ->
    {[<<"GET">>, <<"POST">>], Req, State}.

-dialyzer({no_opaque, handle/2}).
handle(Req, State) ->
    {Method, Req1} = cowboy_req:method(Req),
    handle(Method, Req1, State).

-dialyzer({no_opaque, handle/3}).
handle(<<"POST">>, Req0, State) ->
    {ok, CType, Req} = cowboy_req:parse_header(<<"content-type">>, Req0,
                                               {<<"text">>, <<"plain">>, []}),
    ReqHasBody = cowboy_req:has_body(Req),
    case CType of
        {<<"text">>, <<"plain">>, _Charset}
          when ReqHasBody =:= true ->
            {ok, Query, Req1} = read_req_body(Req),
            run_query(Query, Req1, State);
        {<<"application">>, <<"x-www-form-urlencoded">>, _Charset}
          when ReqHasBody =:= true ->
            {ok, PostVals, Req1} = cowboy_req:body_qs(Req),
            Query = proplists:get_value(<<"q">>, PostVals),
            run_query(Query, Req1, State);
        _Other
          when ReqHasBody =:= true ->
            Headers = [{<<"content-type">>, <<"text/plain">>}],
            {ok, ErrReq} = cowboy_req:reply(415, Headers,
                                <<"Content type not supported">>, Req),
            {ok, ErrReq, State};
        _Else ->
            {ok, Req1} = cowboy_req:reply(400, [], <<"Missing body.">>, Req),
            {ok, Req1, State}
    end;

handle(<<"GET">>, Req, State) ->
    case cowboy_req:qs_val(<<"q">>, Req) of
        {undefined, Req1} ->
            F = fun (Socket, Transport) ->
                        File = code:priv_dir(dalmatiner_frontend) ++
                            "/static/index.html",
                        Transport:sendfile(Socket, File)
                end,
            Req2 = cowboy_req:set_resp_body_fun(F, Req1),
            {ok, Req3} = cowboy_req:reply(200, Req2),
            {ok, Req3, State};
        {Q, Req1} ->
            run_query(Q, Req1, State)
    end.

run_query(Q, Req1, State) ->
    %% Keep broken indention, so git have better chance of automatically
    %% merging from upstram
    begin begin
           {Opts, Req2} = build_opts(Req1),
            TraceID = proplists:get_value(trace_id, Opts, undefined),
            ParentID = proplists:get_value(parent_id, Opts, undefined),
            S = otters:start(dfe, TraceID, ParentID),
            S1 = otters:tag(S, query, Q, dfe),
            ReqR = Req2,
            case timer:tc(dqe, run, [Q, Opts]) of
                {_, {error, E}} ->
                    S2 = otters:tag(S1, result, error, dfe),
                    S3 = otters:tag(S2, error, E, dfe),
                    Error = list_to_binary(dqe:error_string({error, E})),
                    lager:warning("Error in query [~s]: ~p", [Q, E]),
                    StatusCode = error_code(E),
                    {ok, ErrReq} =
                        cowboy_req:reply(StatusCode,
                                        [{<<"content-type">>,
                                          <<"text/plain">>}],
                                         Error, ReqR),
                    otters:finish(S3),
                    {ok, ErrReq, State};
                {T, {ok, Start, R2}} ->
                    S2 = otters:tag(S1, result, success, dfe),
                    S3 = otters:log(S2, "query finished", dfe),
                    {D, ReqR0} = encode_versioned_reply(Start, T, R2, ReqR),
                    S4 = otters:log(S3, "translated", dfe),
                    {ContentType, ReqR1} = content_type(ReqR0),
                    S5 = otters:tag(S4, content_type, ContentType, dfe),
                    send(ContentType, D, ReqR1, S5, State)
            end end end.

encode_versioned_reply(Start, T, R, Req) ->
    case cowboy_req:header(<<"version">>, Req, <<"1">>) of
        {<<"1">>, Req1} ->
            D = encode_v1_reply(Start, T, R),
            {D, Req1};
        {<<"2">>, Req1} ->
            D = encode_reply(Start, T, R),
            {D, Req1}
    end.

encode_v1_reply(Start, T, R2) ->
    R3 = [#{n => Name,
            r => Resolution,
            v => mmath_bin:to_list(Data),
            metadata => Mdata}
          || #{name := Name,
               data := Data,
               type := metrics,
               metadata := Mdata,
               resolution := Resolution} <- R2],
    D = #{s => Start / 1000,
          t => T,
          d => R3},
    case R2 of
        [#{type := graph,
           value := Graph} | _] ->
            maps:put(graph, Graph, D);
        _ ->
            D
    end.

encode_reply(Start, T, R2) ->
    R3 = [#{name => Name,
            resolution => Resolution,
            values => mmath_bin:to_list(Data),
            metadata => Mdata,
            type => <<"metrics">>}
          || #{name := Name,
               data := Data,
               type := metrics,
               metadata := Mdata,
               resolution := Resolution} <- R2],
    R4 = [#{name => Name,
            metadata => Mdata,
            values => [#{timestamp => Ts, event => E}
                       || {Ts, E} <- Data],
            type => <<"events">>}
          || #{name := Name,
               metadata := Mdata,
               data := Data,
               type := events} <- R2],
    D = #{start => Start,
          query_time => T,
          results => R3 ++ R4},
    case R2 of
        [#{type := graph,
           value := Graph} | _] ->
            maps:put(graph, Graph, D);
        _ ->
            D
    end.

read_req_body(Req) ->
    read_req_body(Req, <<>>).

read_req_body(Req, Acc) ->
    case cowboy_req:body(Req) of
        {ok, Data, Req1} ->
            {ok, <<Acc/binary, Data/binary>>, Req1};
        {more, Data, Req1} ->
            read_req_body(Req1, <<Acc/binary, Data/binary>>)
    end.

content_type(Req) ->
    {ok, A, Req1} = cowboy_req:parse_header(<<"accept">>, Req),
    {content_type_(A), Req1}.

content_type_(undefined) ->
    json;
content_type_([]) ->
    other;
content_type_([{{<<"text">>, <<"html">>, _}, _, _} | _]) ->
    html;
content_type_([{{<<"application">>, <<"xhtml+xml">>, _}, _, _} | _]) ->
    html;
content_type_([{{<<"application">>, <<"json">>, _}, _, _} | _]) ->
    json;
content_type_([{{<<"application">>, <<"msgpack">>, _}, _, _} | _]) ->
    msgpack;
content_type_([{{<<"application">>, <<"x-msgpack">>, _}, _, _} | _]) ->
    msgpack;
content_type_([_ | R]) ->
    content_type_(R).

error_code(no_results) ->
    404;
error_code(_) ->
    400.
send(Type, D, Req, State) ->
    send(Type, D, Req, undefined, State).
send(json, D, Req, S, State) ->
    {ok, Req1} =
        cowboy_req:reply(
          200, [{<<"content-type">>, <<"application/json">>}],
          jsone:encode(D), Req),
    otters:finish(S),
    {ok, Req1, State};
send(msgpack, D, Req, S, State) ->
    {ok, Req1} =
        cowboy_req:reply(
          200, [{<<"content-type">>, <<"application/x-msgpack">>}],
          msgpack:pack(D, [jsx, {allow_atom, pack}]), Req),
    otters:finish(S),
    {ok, Req1, State};
send(_, _D, Req, S, State) ->
    {ok, Req1} = cowboy_req:reply(415, Req),
    otters:finish(S),
    {ok, Req1, State}.

terminate(_Reason, _Req, _State) ->
    ok.

build_opts(Req) ->
    O0 = case application:get_env(dalmatiner_frontend, log_slow) of
             {ok, true} ->
                 [{timeout, infinity}, log_slow_queries];
             _ ->
                 [{timeout, infinity}]
         end,
    {O1, R1} = case cowboy_req:qs_val(<<"debug">>, Req) of
                   {undefined, ReqX} ->
                       {O0, ReqX};
                   {<<>>, ReqX} ->
                       {[debug | O0], ReqX};
                   {true, ReqX} ->
                       {[debug | O0], ReqX};
                   {Token, ReqX} ->
                       {[debug, {token, Token} | O0], ReqX}
               end,
    {O2, R2} = case cowboy_req:qs_val(<<"trace_id">>, R1) of
                   {undefined, ReqX1} ->
                       {O1, ReqX1};
                   {<<>>, ReqX1} ->
                       {[{trace_id, otters_lib:id()} | O1], ReqX1};
                   {true, ReqX1} ->
                       {[{trace_id, otters_lib:id()} | O1], ReqX1};
                   {TraceID, ReqX1} ->
                       {[{trace_id, binary_to_integer(TraceID)} | O1], ReqX1}
               end,
    {O3, R3} = case cowboy_req:qs_val(<<"parent_id">>, R2) of
                   {undefined, ReqX2} ->
                       {O2, ReqX2};
                   {<<>>, ReqX2} ->
                       {O2, ReqX2};
                   {true, ReqX2} ->
                       {O2, ReqX2};
                   {ParentID, ReqX2} ->
                       {[{parent_id, binary_to_integer(ParentID)} | O2], ReqX2}
               end,
    case cowboy_req:qs_val(<<"graph">>, R3) of
        {undefined, Rx1} ->
            {O3, Rx1};
        {_, Rx1} ->
            {[return_graph | O3], Rx1}
    end.
