%%%-------------------------------------------------------------------
%%% @author Torbjorn Tornkvist <kruskakli@gmail.com>
%%% @copyright (C) 2023, Torbjorn Tornkvist
%%% @doc Consume monitor data and push it to Postgres
%%%
%%%   FIXME when the "consumer" receive data over the Websocket
%%%         it should invoke: system_monitor_pg:produce/2
%%%
%%% @end
%%%-------------------------------------------------------------------
-module(system_monitor_consumer).

-behaviour(gen_server).

%% gen_server callbacks
-export([ start_link/0
        , init/1
        , handle_continue/2
        , handle_call/3
        , handle_info/2
        , handle_cast/2
        , format_status/2
        , terminate/2
        , code_change/3
        ]).

%% cowboy callbacks
-export([ init/2
        , websocket_init/1
        , websocket_handle/2
        , websocket_info/2
        ]).

-export([ get_config/2
        ]).

-include_lib("system_monitor/include/system_monitor.hrl").
-include_lib("kernel/include/logger.hrl").

-define(dbg(FmtStr, Args), io:format("~p~p: "++FmtStr,[?MODULE,?LINE|Args])).

-define(SERVER, ?MODULE).

%% Close codes, see: RFC-6455 section: 7.4
-define(CC_1000_NORMAL, 1000).
-define(CC_1002_PROTO_ERROR, 1002).

%%%===================================================================
%%% API
%%%===================================================================

%% @doc Get the relevant Application config
%%
%% @end
-spec(get_config([Key :: atom()], Map :: map()) -> map()).
get_config(Keys, CfgMap) ->
    lists:foldl(
      fun(Key, Map) ->
              case application:get_env(system_monitor, Key) of
                  {ok, Val} ->
                      maps:put(Key, Val, Map);
                  _ ->
                      throw({missing_config, Key})
              end
      end, CfgMap, Keys).


%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%% @end
%%--------------------------------------------------------------------
-spec start_link() -> {ok, Pid :: pid()} |
          {error, Error :: {already_started, pid()}} |
          {error, Error :: term()} |
          ignore.
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Initializes the server
%% @end
%%--------------------------------------------------------------------
-spec init(Args :: term()) -> {ok, State :: term()} |
          {ok, State :: term(), Timeout :: timeout()} |
          {ok, State :: term(), hibernate} |
          {stop, Reason :: term()} |
          ignore.
init([]) ->
    process_flag(trap_exit, true),
    {ok, #{}, {continue, start_consumer}}.


handle_continue(start_consumer, CfgMap) ->
    continue(get_consumer_config(CfgMap)).

continue(CfgMap) ->
    case start_pg() of
        {ok, PgPid} ->
            case maps:get(consumer_enable, CfgMap, false) of
                true -> proceed(CfgMap#{pg_pid => PgPid,
                                        cfg_map => CfgMap});
                _    -> {stop, {error, "consumer is disabled"}, CfgMap}
            end;
        _ ->
            {stop, {error, "failed to start pg"}, CfgMap}
    end.

%% Start Postgres backend
start_pg() ->
    case system_monitor_pg:start_link() of
        {ok, _Pid} = X                  -> X;
        {error, {already_started, Pid}} -> {ok, Pid};
        Else                            -> Else
    end.


proceed(CfgMap) ->
    try
        Dispatch =
            cowboy_router:compile(
              [
               %% {HostMatch, list({PathMatch, Handler, InitialState})}
               {'_', [{"/", ?MODULE, CfgMap}]}
              ]),

        {ok,_} = start_listener(CfgMap, Dispatch),

        {noreply, CfgMap}

    catch
        _Etype:_Err:_Estack ->
            %% FIXME log error
            ?dbg("<ERROR> ~p~n", [{_Etype,_Err,_Estack}]),
            {noreply, CfgMap}
    end.


start_listener(#{consumer_use_tls := true} = CfgMap, Dispatch) ->
    IP = maps:get(consumer_listen_ip, CfgMap),
    Port = maps:get(consumer_listen_port, CfgMap),
    TLS_opts = maps:get(consumer_tls_opts, CfgMap),

    Opts = [ {ip, IP}
           , {port, Port}
           ] ++ TLS_opts,

    ?dbg("starting HTTPS listener on Port: ~p , TLS_opts = ~p~n",[Port,TLS_opts]),
    cowboy:start_tls(consumer_tls_listener,
                     Opts,
                     #{env => #{dispatch => Dispatch}}
     );
%%
start_listener(CfgMap, Dispatch) ->
    IP = maps:get(consumer_listen_ip, CfgMap),
    Port = maps:get(consumer_listen_port, CfgMap),

    ?dbg("starting HTTP listener on Port: ~p~n",[Port]),
    cowboy:start_clear(
      consumer_tcp_listener,
      [ {ip, IP}
      , {port, Port}
      ],
      #{env => #{dispatch => Dispatch}}
     ).


get_consumer_config(CfgMap) ->
    get_config(consumer_config(), CfgMap).

consumer_config() ->
    [consumer_enable, consumer_listen_ip, consumer_listen_port,
     consumer_use_tls, consumer_tls_opts].



%%
%% Cowboy callback
%%
init(Req0, StateMap) ->
    ?dbg("server got connected, upgrading to Websocket!~n", []),
    {cowboy_websocket,
     Req0,
     StateMap}.

%%
%% Cowboy Websocket callbacks
%%
websocket_init(StateMap) ->
    ?dbg("server websocket init, sending Welcome!~n",[]),
    {[{text,"Welcome to the gunsmoke server!"}], StateMap}.


%%
%% Expecting client data.
%%
websocket_handle({binary,Bin}, StateMap) ->
    case erlang:binary_to_term(Bin) of
        {produce, Type, Events} ->
            ?dbg("storing: Type=~p~n", [Type]),
            system_monitor_pg:produce(Type, Events),
            {ok, StateMap};
        _X ->
            ?dbg("got wrong client data: ~p~n", [_X]),
            {[{close, ?CC_1002_PROTO_ERROR, <<"wrong client data">>}],
             StateMap}
    end;
%%
websocket_handle(_Frame, StateMap) ->
    ?dbg("got unknown frame: ~p~n",[_Frame]),
    {[{close, ?CC_1002_PROTO_ERROR, <<"go away">>}], StateMap}.


websocket_info(_Info, StateMap) ->
    ?dbg("got unknown info: ~p~n",[_Info]),
    {ok, StateMap}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages
%% @end
%%--------------------------------------------------------------------
-spec handle_call(Request :: term(), From :: {pid(), term()}, State :: term()) ->
          {reply, Reply :: term(), NewState :: term()} |
          {reply, Reply :: term(), NewState :: term(), Timeout :: timeout()} |
          {reply, Reply :: term(), NewState :: term(), hibernate} |
          {noreply, NewState :: term()} |
          {noreply, NewState :: term(), Timeout :: timeout()} |
          {noreply, NewState :: term(), hibernate} |
          {stop, Reason :: term(), Reply :: term(), NewState :: term()} |
          {stop, Reason :: term(), NewState :: term()}.

handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages
%% @end
%%--------------------------------------------------------------------
-spec handle_cast(Request :: term(), State :: term()) ->
          {noreply, NewState :: term()} |
          {noreply, NewState :: term(), Timeout :: timeout()} |
          {noreply, NewState :: term(), hibernate} |
          {stop, Reason :: term(), NewState :: term()}.

handle_cast(_Request, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages
%% @end
%%--------------------------------------------------------------------
-spec handle_info(Info :: timeout() | term(), State :: term()) ->
          {noreply, NewState :: term()} |
          {noreply, NewState :: term(), Timeout :: timeout()} |
          {noreply, NewState :: term(), hibernate} |
          {stop, Reason :: normal | term(), NewState :: term()}.

handle_info(_Info, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%% @end
%%--------------------------------------------------------------------
-spec terminate(Reason :: normal | shutdown | {shutdown, term()} | term(),
                State :: term()) -> any().

terminate(_Reason, _State) ->
    ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%% @end
%%--------------------------------------------------------------------
-spec code_change(OldVsn :: term() | {down, term()},
                  State :: term(),
                  Extra :: term()) -> {ok, NewState :: term()} |
          {error, Reason :: term()}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called for changing the form and appearance
%% of gen_server status when it is returned from sys:get_status/1,2
%% or when it appears in termination error logs.
%% @end
%%--------------------------------------------------------------------
-spec format_status(Opt :: normal | terminate,
                    Status :: list()) -> Status :: term().

format_status(_Opt, Status) ->
    Status.

%%%===================================================================
%%% Internal functions
%%%===================================================================

