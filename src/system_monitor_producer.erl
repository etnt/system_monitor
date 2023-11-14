%%%-------------------------------------------------------------------
%%% @author Torbjörn Törnkvist <kruskakli@gmail.com>
%%% @copyright (C) 2023, Torbjörn Törnkvist
%%% @doc Callback module producing websocket output of monitor data
%%%
%%% @end
%%%-------------------------------------------------------------------
-module(system_monitor_producer).

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

-behaviour(system_monitor_callback).
-export([ produce/2
        ]).

-include_lib("system_monitor/include/system_monitor.hrl").
-include_lib("kernel/include/logger.hrl").

%%-define(dbg(FmtStr, Args), ok).
-define(dbg(FmtStr, Args), io:format("~p~p: "++FmtStr,[?MODULE,?LINE|Args])).

-define(SERVER, ?MODULE).


%%%===================================================================
%%% API
%%%===================================================================
produce(Type, Events) ->
    gen_server:cast(?SERVER, {produce, Type, Events}).

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
    {ok, #{}, {continue, start_producer}}.


handle_continue(start_producer, CfgMap) ->
    continue(get_producer_config(CfgMap)).

continue(CfgMap) ->
    case maps:get(producer_enable, CfgMap, false) of
        true -> proceed(CfgMap);
        _    -> {noreply, CfgMap}
    end.

proceed(CfgMap) ->
    try
        {ok, ConnPid} = gun_open(CfgMap),
        {ok, _Protocol} = gun:await_up(ConnPid),

        gun:ws_upgrade(ConnPid, "/", []),

        %% Now, wait for the gun_upgrade message to arrive in handle_info/2
        {noreply, CfgMap}

    catch
        _Etype:_Err:_Estack ->
            %% FIXME log error
            ?dbg("<ERROR> ~p~n",[{_Etype,_Err,_Estack}]),
            {noreply, CfgMap}
    end.


gun_open(#{producer_use_tls := true} = CfgMap) ->
    IP = maps:get(producer_ip, CfgMap),
    Port = maps:get(producer_port, CfgMap),
    TLS_opts = maps:get(producer_tls_opts, CfgMap),
    ?dbg("connecting to: https://~p:~p~nTLS-opts: ~p~n",[IP,Port,TLS_opts]),
    gun:open(IP, Port, #{transport => tls
                         %% Note: default protocols are: [http2,http]
                         %% but `http2` will complicate matters here and
                         %% is not really needed for our purposes; we just
                         %% want to bring up the websocket as quickly
                         %% as possible.
                        , protocols => [http]
                        , tls_opts => TLS_opts
                        });
%%
gun_open(CfgMap) ->
    IP = maps:get(producer_ip, CfgMap),
    Port = maps:get(producer_port, CfgMap),
    ?dbg("connecting to: http://~p:~p~n",[IP,Port]),
    gun:open(IP, Port).


get_producer_config(CfgMap) ->
    system_monitor_consumer:get_config(producer_config(), CfgMap).

producer_config() ->
    [producer_enable, producer_ip, producer_port,
     producer_use_tls, producer_tls_opts].


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

%% Locally produced Event; send it to the Consumer backend!
handle_cast({produce, _Type, _Events} = Msg,
            #{conn_pid := ConnPid,
              stream_ref := StreamRef} = CfgMap) ->
    MsgBin = erlang:term_to_binary(Msg),
    ok = gun:ws_send(ConnPid, StreamRef, {binary, MsgBin}),
    {noreply, CfgMap};
%%
handle_cast(_Request, CfgMap) ->
    %%?dbg("handle_cast got: Type=~p~n",[_Request]),
    {noreply, CfgMap}.

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

handle_info({gun_upgrade, ConnPid, StreamRef, [<<"websocket">>], _Headers},
            CfgMap) ->
    ?dbg("got: gun_upgrade~n",[]),
    {noreply, CfgMap#{conn_pid => ConnPid,
                      stream_ref => StreamRef}};
%%
handle_info({gun_ws, _ConnPid, _StreamRef, Msg}, State) ->
    ?dbg("got msg: ~p~n",[Msg]),
    {noreply, State};
%%
handle_info(_Info, State) ->
    ?dbg("handle_info got: ~p~n",[_Info]),
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

