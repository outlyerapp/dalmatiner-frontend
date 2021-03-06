-module(dalmatiner_dl_collection_h).
-behaviour(cowboy_http_handler).

-export([init/3, handle/2, terminate/3]).

-ignore_xref([init/3, handle/2, terminate/3]).

init(_Transport, Req, []) ->
    {ok, Req, undefined}.


-dialyzer({no_opaque, handle/2}).
handle(Req, State) ->
    Req0 = cowboy_req:set_resp_header(
             <<"access-control-allow-origin">>, <<"*">>, Req),

    {ContentType, Req1} = dalmatiner_idx_handler:content_type(Req0),
    case ContentType of
        html ->
            F = fun (Socket, Transport) ->
                        File = code:priv_dir(dalmatiner_frontend) ++
                            "/static/collection.html",
                        Transport:sendfile(Socket, File)
                end,
            Req2 = cowboy_req:set_resp_body_fun(F, Req1),
            {ok, Req3} = cowboy_req:reply(200, Req2),
            {ok, Req3, State};
        _ ->
            {UserId, Req2} = cowboy_req:meta(dl_auth_user, Req1),
            {ok, Orgs} = dalmatiner_dl_data:user_orgs(UserId),
            Json = [#{key => base16:encode(Id),
                      label => <<TName/binary, ":", OName/binary>>}
                    || #{<<"_id">> := {Id},
                         <<"name">> := OName,
                         <<"tenant">> :=
                             #{<<"name">> := TName}} <- Orgs],
            dalmatiner_idx_handler:send(ContentType, Json, Req2, State)
    end.

terminate(_Reason, _Req, _State) ->
    ok.
