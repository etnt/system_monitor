%%--------------------------------------------------------------------------------
%% Copyright 2020 Klarna Bank AB
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%--------------------------------------------------------------------------------
-module(system_monitor_sup).

-ifdef(USE_OTP_SUPERVISOR).
-define(SUPERVISOR, supervisor).
-define(PERMANENT_15, permanent).
-else.
-define(SUPERVISOR, supervisor3).
-define(PERMANENT_15, {permanent,15}).
-endif.

%% TODO: Dialyzer doesn't like this one:
%-behaviour(?SUPERVISOR).

%% External exports
-export([start_link/0]).

%% supervisor callbacks
-export([init/1, post_init/1]).

%%--------------------------------------------------------------------
%% Macros
%%--------------------------------------------------------------------
-define(SERVER, ?MODULE).
-define(SUP2, system_monitor2_sup).

%%%----------------------------------------------------------------------
%%% API
%%%----------------------------------------------------------------------
start_link() ->
    ?SUPERVISOR:start_link({local, ?SERVER}, ?MODULE, ?SERVER).

%%%----------------------------------------------------------------------
%%% Callback functions from supervisor
%%%----------------------------------------------------------------------

server(Name, Type) ->
    server(Name, Type, 2000).

server(Name, Type, Shutdown) ->
    {Name, {Name, start_link, []}, ?PERMANENT_15, Shutdown, Type, [Name]}.

worker(Name) -> server(Name, worker).

post_init(_) ->
    ignore.

init(?SERVER) ->
    %% The top level supervisor *does not allow restarts*; if a component
    %% directly under this supervisor crashes, the entire node will shut
    %% down and restart. Thus, only those components that must never be
    %% unavailable should be directly under this supervisor.

    SecondSup = {?SUP2,
                 {?SUPERVISOR, start_link,
                  [{local, ?SUP2}, ?MODULE, ?SUP2]},
                 permanent, 2000, supervisor, [?MODULE]},

    {ok, {{one_for_one,0,1},  % no restarts allowed!
          [SecondSup]
         }};
init(?SUP2) ->
    %% The second-level supervisor allows some restarts. This is where the
    %% normal services live.
    {MaxR, MaxT} = get_restart_intensity(),
    {ok, {{one_for_one, MaxR, MaxT},
          [ worker(system_monitor_top)
          , worker(system_monitor_events)
          , worker(system_monitor)
          ]
          ++ producer_callback()
          ++ custom_metric_collectors()
         }}.

producer_callback() ->
    case system_monitor_callback:get_callback_mod() of
      undefined -> [];
      Mod -> [worker(Mod)]
    end.

custom_metric_collectors() ->
    case application:get_env(system_monitor, custom_metrics) of
        {ok, CMs} ->
            [worker(CallbackMod) || {_Type, CallbackMod} <- CMs];
        _ ->
            []
    end.

get_restart_intensity() ->
    application:get_env(system_monitor, restart_intensity, {10,20}).
