%%% -*- erlang -*-
%%%
%%% This file is part of coffer-server released under the Apache license 2.
%%% See the NOTICE for more information.

-module(coffer_http_blob).

-export([init/3]).
-export([handle/2]).
-export([terminate/2]).

-compile([{parse_transform, lager_transform}]).

init(_Transport, Req, []) ->
    {ok, Req, undefined}.

handle(Req, State) ->
    {Method, Req2} = cowboy_req:method(Req),
    {StorageName, Req3} = cowboy_req:binding(container, Req2),
    {BlobRef, Req4} = cowboy_req:binding(blob, Req3),
    {HasBody, Req5} = cowboy_req:has_body(Req4),
    {ok, Req6} = maybe_process(StorageName, BlobRef, Method, HasBody, Req5),
    {ok, Req6, State}.

maybe_process(StorageName, BlobRef, <<"DELETE">>, false, Req) ->
    case coffer:get_storage(StorageName) of
        {error, not_found} ->
            coffer_http_util:not_found(Req);
        {error, Reason} ->
            coffer_http_util:error(Reason, Req);
        _ ->
            StoragePid = coffer:get_storage(StorageName),
            case coffer:delete(StoragePid, BlobRef) of
                ok ->
                    StatusMessage = [
                        { <<"deleted">>,
                            [
                                {<<"blobRef">>, BlobRef}
                            ]
                        }
                    ],
                    {Json, Req1} = coffer_http_util:to_json(StatusMessage),
                    cowboy_req:reply(202, [], Json, Req1);
                {error, not_found} ->
                    coffer_http_util:not_found(Req)
            end
    end;
maybe_process(StorageName, BlobRef, <<"PUT">>, true, Req) ->
    case coffer:get_storage(StorageName) of
        {error, not_found} ->
            coffer_http_util:not_found(Req);
        {error, Reason} ->
            coffer_http_util:error(Reason, Req);
        _ ->
            StoragePid = coffer:get_storage(StorageName),
            case coffer:new_upload(StoragePid, BlobRef) of
                {ok, Receiver} ->
                    case stream_in_blob(Receiver, Req) of
                        {ok, UploadSize, Req2} ->
                            StatusMessage = [
                                { <<"received">>, [
                                    [
                                        {<<"blobRef">>, BlobRef},
                                        {<<"size">>, UploadSize}]
                                    ]
                                }
                            ],
                            {Json, Req3} = coffer_http_util:to_json(StatusMessage,
                                                                    Req2),
                            cowboy_req:reply(201, [], Json, Req3);
                        {Error, Req2} ->
                            ErrorMessage = <<"CHANGEME! ERROR DURING UPLOAD!">>,
                            lager:error("problem uploading blob id ~p: ~p",
                                        [BlobRef, Error]),
                            cowboy_req:reply(500, [], ErrorMessage, Req2)
                    end;
                {error, {already_exists, _, _}} ->
                    ErrorMessage = <<"CHANGME! ALREADY EXIST ERROR!">>,
                    lager:error("problem uploading blob id ~p with error: ~p",
                                [BlobRef, already_exists]),
                    cowboy_req:reply(409, [], ErrorMessage, Req);
                UnknownError ->
                    ErrorMessage = <<"CHANGME! UPLOAD UNKOWN ERROR!">>,
                    lager:error("problem uploading blob id ~p with error: ~p",
                                [BlobRef, UnknownError]),
                    cowboy_req:reply(500, [], ErrorMessage, Req)
            end
    end;
maybe_process(StorageName, BlobRef, <<"GET">>, false, Req) ->
    case coffer:get_storage(StorageName) of
        {error, not_found} ->
            coffer_http_util:not_found(Req);
        {error, Reason} ->
            coffer_http_util:error(Reason, Req);
        _ ->
            Storage = coffer:get_storage(StorageName),

            case coffer:new_stream(Storage, BlobRef) of
                {ok, Stream} ->
                    {ok, Req2} = cowboy_req:chunked_reply(200, Req),
                    stream_out_blob(Stream, Req2);
                {error, Error} ->
                    lager:error("Error fetching the blob ~p with reason: ~p", [BlobRef, Error]),
                    coffer_http_util:not_found(Req)
            end
    end;
maybe_process(_, _, _, _, Req) ->
    coffer_http_util:not_allowed([<<"GET">>, <<"PUT">>, <<"DELETE">>], Req).

terminate(_Req, _State) ->
    ok.

%% ---

stream_in_blob(Receiver, Req) ->
    case cowboy_req:stream_body(Req) of
        {ok, Bin, Req2} ->
            case coffer:upload(Receiver, Bin) of
                {ok, Receiver1} ->
                    stream_in_blob(Receiver1, Req2);
                Error ->
                    {Error, Req2}
            end;
        {done, Req2} ->
            case coffer:upload(Receiver, eob) of
                {ok, UploadSize} ->
                    {ok, UploadSize, Req2};
                Error ->
                    {Error, Req2}
            end
    end.

stream_out_blob(Stream, Req) ->
    Result = case coffer:fetch(Stream) of
        {ok, Value} ->
            Value;
        {error, Error} ->
            {error, Error}
    end,
    send_chunk(Stream, Result, Req).

send_chunk(_Stream, {error, Error}, Req) ->
    lager:error("error during fetching: ~p", [Error]),
    {ok, Req};
send_chunk(_Stream, coffer_eob, Req) ->
    {ok, Req};
send_chunk(Stream, Bin, Req) ->
    ok = cowboy_req:chunk(Bin, Req),
    Result = case coffer:fetch(Stream) of
        {ok, Value} ->
            Value;
        {error, Error} ->
            {error, Error}
    end,
    send_chunk(Stream, Result, Req).

