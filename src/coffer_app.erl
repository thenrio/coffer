-module(coffer_app).

-behaviour(application).

%% Application callbacks
-export([start/2, stop/1]).
-export([ensure_deps_started/0, ensure_started/1]).
-export([get_app_env/1, get_app_env/2]).

-include_lib("hackney/include/hackney.hrl").

%% ===================================================================
%% Application callbacks
%% ===================================================================

start(_StartType, _StartArgs) ->
    coffer_deps:ensure(),
    ensure_deps_started(),
    coffer_sup:start_link().

stop(_State) ->
    ok.

ensure_deps_started() ->
    {ok, Deps} = application:get_key(coffer, applications),
    true = lists:all(fun ensure_started/1, Deps).

ensure_started(App) ->
    case application:start(App) of
        ok ->
            true;
        {error, {already_started, App}} ->
            true;
        Else ->
            error_logger:error_msg("Couldn't start ~p: ~p", [App, Else]),
            Else
    end.

get_app_env(Env) ->
    get_app_env(Env, undefined).

get_app_env(Env, Default) ->
    case application:get_env(coffer, Env) of
        {ok, Val} -> Val;
        undefined -> Default
    end.
