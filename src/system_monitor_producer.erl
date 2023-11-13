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

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-define(dbg(FmtStr, Args), io:format("~p~p: "++FmtStr,[?MODULE,?LINE|Args])).

-define(SERVER, ?MODULE).
-define(FIVE_SECONDS, 5000).
-define(ONE_HOUR, 60*60*1000).

-record(state,
        { conn_pid
        , stream_ref
        , cfg_map
        , state :: undefined | init | auth | handshake | running
        , client_challenge
        }).

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
    {ok, #state{state = init}, {continue, start_producer}}.


handle_continue(start_producer, State) ->
    CfgMap = get_producer_config(),
    case maps:get(producer_enable, CfgMap, false) of
        true -> continue(State#state{cfg_map = CfgMap});
        _    -> {noreply, State}
    end.

continue(State) ->
    try
        CfgMap = State#state.cfg_map,
        IP = maps:get(producer_ip, CfgMap),
        Port = maps:get(producer_port, CfgMap),

        {ok, ConnPid} = gun:open(IP, Port),
        {ok, _Protocol} = gun:await_up(ConnPid),

        Challenge = mk_challenge(),
        Challenge64 = base64:encode(Challenge),
        gun:ws_upgrade(ConnPid, "/",
                       [
                        {<<"authorization">>, <<"Bearer ", Challenge64/binary>>}
                       ]),

        %% Now, wait for the gun_upgrade message to arrive.
        {noreply, State#state{state = sent_challenge,
                              client_challenge = Challenge}}

    catch
        _Etype:_Err:_Estack ->
            %% FIXME log error
            ?dbg("<ERROR> ~p~n",[{_Etype,_Err,_Estack}]),
            {noreply, State}
    end.


get_producer_config() ->
    system_monitor_consumer:get_config(producer_config()).

producer_config() ->
    [producer_enable, producer_ip, producer_port, consumer_secret].



mk_challenge() ->
    system_monitor_consumer:nonce().


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

handle_cast({produce, _Type, _Events} = Msg,
            #state{state      = running,
                   conn_pid   = ConnPid,
                   stream_ref = StreamRef} = State) ->
    MsgBin = erlang:term_to_binary(Msg),
    ok = gun:ws_send(ConnPid, StreamRef, {binary, MsgBin}),
    {noreply, State};
%%
handle_cast(_Request, State) ->
    ?dbg("handle_cast got: Type=~p~n",[_Request]),
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

handle_info({gun_upgrade, ConnPid, StreamRef, [<<"websocket">>], _Headers},
            State) ->
    ?dbg("got: gun_upgrade~n",[]),
    %%gun:ws_send(ConnPid, StreamRef, {text, "Hello!"}),
    {noreply, State#state{state      = upgraded,
                          conn_pid   = ConnPid,
                          stream_ref = StreamRef} };
%%
handle_info({gun_ws, _ConnPid, _StreamRef, {binary, Bin}},
            #state{state = upgraded,
                   conn_pid   = ConnPid,
                   stream_ref = StreamRef,
                   cfg_map = CfgMap,
                   client_challenge = ClientChallenge} = State) ->
    try erlang:binary_to_term(Bin) of
        {server_challenge, ServerChallenge, ClientDigest} ->
            ?dbg("got server_challenge: ~p~n", [ServerChallenge]),
            ?dbg("...and ClientDigest: ~p~n", [ClientDigest]),
            Secret = maps:get(consumer_secret, CfgMap),
            case system_monitor_consumer:verify_digest(Secret,
                                                       ClientChallenge,
                                                       ClientDigest) of
                true ->
                    ?dbg("client digest verified ok~n",[]),
                    ?dbg("sending server digest ok~n",[]),
                    Digest = system_monitor_consumer:digest(Secret,
                                                            ServerChallenge),
                    DigestBin = erlang:term_to_binary({digest, Digest}),
                    ok = gun:ws_send(ConnPid, StreamRef, {binary, DigestBin}),
                    {noreply, State#state{state = sent_digest}};
                false ->
                    ?dbg("failed server digest ok~n",[]),
                    {stop, verify_digest, State}
            end;
        _X ->
            ?dbg("got wrong msg state=upgraded: ~p~n", [?MODULE]),
            {stop, upgraded, State}
    catch
        _Etype:_Err:_Estack ->
            %% FIXME log error
            ?dbg("<ERROR> ~p~n", [{_Etype,_Err,_Estack}]),
            {stop, binary_to_term, State}
    end;
%%
handle_info({gun_ws, _ConnPid, _StreamRef, {text, <<"welcome">>}},
            #state{state = sent_digest} = State) ->
    ?dbg("got Welcome from Consumer, starting...~n", []),
    %% Ok, we are now ready to start sending output to the Consumer!
    {noreply, State#state{state = running}};
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

