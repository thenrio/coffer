%%% -*- erlang -*-
%%%
%%% This file is part of coffer released under the Apache license 2.
%%% See the NOTICE for more information.

-module(coffer_server).
-behaviour(gen_server).
-define(SERVER, ?MODULE).

-include_lib("coffer/includes/coffer.hrl").

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------

-export([start_link/1]).
-export([list/0]).
-export([add/3, remove/1]).
-export([get/1]).

%% ------------------------------------------------------------------
%% gen_server Function Exports
%% ------------------------------------------------------------------

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

start_link(Args) ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, Args, []).

list() ->
    gen_server:call(?MODULE, {list}).

add(StorageName, Backend, Config) ->
    gen_server:call(?MODULE, {add, StorageName, Backend, Config}).

remove(StorageName) ->
    gen_server:call(?MODULE, {remove, StorageName}).

get(StorageName) ->
    gen_server:call(?MODULE, {get, StorageName}).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------

% gen_server state records
-record(state, {
    storages = [],
    options = []
}).
-record(storage, {
    name,
    backend,
    config = [],
    pid
}).

init([]) ->
    %
    % storages : [
    %     { StorageName, Backend, Config } 
    % ]
    %
    StoragesConfig = case application:get_env(coffer, storages) of
        undefined ->
            [];
        {ok, Other} ->
            Other
    end,
    FinalState = lists:foldl(
        fun({StorageName, Backend, Config}, State) ->
            {_, NewState} = do_add_storage(StorageName, Backend, Config, State),
            NewState
        end,
        #state{},
        StoragesConfig
    ),
    {ok, FinalState}.

handle_call({list}, _From, #state{storages=Storages}=State) ->
    Reply = lists:foldl(
        fun({StorageName, _Storage}, Acc) ->
            [StorageName|Acc]
        end,
        [],
        Storages
    ),
    {reply, Reply, State};
handle_call({add, StorageName, Backend, Config}, _From, State) ->
    {Reply, NewState} = do_add_storage(StorageName, Backend, Config, State),
    {reply, Reply, NewState};
handle_call({remove, StorageName}, _From, State) ->
    {Reply, NewState} = do_remove_storage(StorageName, State),
    {reply, Reply, NewState};
handle_call({get, StorageName}, _From, #state{storages=Storages}=State) ->
    Reply = case proplists:get_value(StorageName, Storages) of
        undefined ->
            {error, not_found};
        #storage{pid=Pid} ->
            Pid
    end,
    {reply, Reply, State};
handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, #state{storages=Storages}=_State) ->
    lists:foldl(
        fun(#storage{backend=Backend}=_Storage, _Acc) ->
            Backend:stop()
        end,
        [],
        Storages
    ),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

do_add_storage(StorageName, Backend, Config, #state{storages=Storages}=State) ->
    case proplists:get_value(StorageName, Storages) of
        undefined ->
            lager:info("Starting storage: ~p with backend: ~p", [StorageName, Backend]),
            case Backend:start(Config) of
                {ok, Pid} ->
                    lager:info("Storage ~p successfully started!", [StorageName]),
                    Storage = #storage{name=StorageName, backend=Backend, config=Config, pid=Pid},
                    UpdatedStorages = [ {StorageName, Storage} | Storages ],
                    NewState = State#state{storages=UpdatedStorages},
                    {ok, NewState};
                ErrorAtLoad ->
                    lager:error("An error occured loading the storage ~p with error: ~p~n", [StorageName, ErrorAtLoad]),
                    {{error, cant_start}, State}
            end;
        _AlreadyThere ->
            lager:error("Storage ~p already exists!", [StorageName]),
            {{error, already_exists}, State}
    end.

 do_remove_storage(StorageName, #state{storages=Storages}=State) ->
    case proplists:get_value(StorageName, Storages) of
        undefined ->
            {{error, not_found}, State};
        #storage{backend=Backend}=_Storage ->
            lager:info("Stopping storage ~p", [StorageName]),
            case Backend:stop() of
                ok ->
                    lager:info("Storage ~p is now stopped", [StorageName]),
                    UpdatedStorages = proplists:delete(StorageName, Storages),
                    {ok, State#state{storages=UpdatedStorages}};
                {error, Reason} ->
                    {{error, Reason}, State}
            end
    end.
