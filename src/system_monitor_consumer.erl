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

-export([ get_config/1
        , nonce/0
        , digest/2
        , verify_digest/3
        , encode_token/2
        , decode_token/1
        ]).

-include_lib("system_monitor/include/system_monitor.hrl").
-include_lib("kernel/include/logger.hrl").

-define(dbg(FmtStr, Args), io:format("~p~p: "++FmtStr,[?MODULE,?LINE|Args])).

-define(SERVER, ?MODULE).
-define(FIVE_SECONDS, 5000).
-define(ONE_HOUR, 60*60*1000).

%% Close codes, see: RFC-6455 section: 7.4
-define(CC_1000_NORMAL, 1000).
-define(CC_1002_PROTO_ERROR, 1002).
-record(state,
        { conn_pid
        , stream_ref
        , pg_pid
        , cfg_map
        }).

%%%===================================================================
%%% API
%%%===================================================================

%% @doc Get the relevant Application config
%%
%% Get the relevant Application config and make it possible
%% to override it through Envirionment Variables.
%%
%% @end
-spec(get_config([Key :: atom()]) -> map()).

get_config(Keys) ->
    %% First get the application config
    CfgMap =
        lists:foldl(
          fun(Key, Map) ->
                  case application:get_env(system_monitor, Key) of
                      {ok, Val} ->
                          maps:put(Key, Val, Map);
                      _ ->
                          throw({missing_config, Key})
                  end
          end, #{}, Keys),

    %% Make it possible to override config through Env.Vars
    lists:foldl(
      fun(Key, Map) ->
              case get_env_config(Key) of
                  {ok, Val} ->
                      maps:put(Key, Val, Map);
                  _ ->
                      Map
              end
      end, CfgMap, Keys).


get_env_config(Key) when is_atom(Key) ->
    case os:getenv(string:uppercase(erlang:atom_to_list(Key))) of
        false -> false;
        Val   -> env_convert(Key, Val)
    end.


env_convert(consumer_enable, Val) ->
    erlang:list_to_atom(Val);
env_convert(consumer_listen_ip, Val) ->
    {ok, IP} = inet:parse_address(Val),
    IP;
env_convert(consumer_listen_port, Val) ->
    erlang:list_to_integer(Val);
env_convert(consumer_secret, Secret) ->
    erlang:list_to_binary(Secret);
env_convert(producer_enable, Val) ->
    erlang:list_to_atom(Val);
env_convert(producer_ip, Val) ->
    {ok, IP} = inet:parse_address(Val),
    IP;
env_convert(producer_port, Val) ->
    erlang:list_to_integer(Val).


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
    {ok, #state{}, {continue, start_consumer}}.


handle_continue(start_consumer, State) ->
    case start_pg() of
        {ok, PgPid} ->
            CfgMap = get_consumer_config(),
            case maps:get(consumer_enable, CfgMap, false) of
                true -> continue(State#state{pg_pid  = PgPid,
                                             cfg_map = CfgMap});
                _    -> {stop, {error, "consumer is disabled"}, State}
            end;
        _ ->
            {stop, {error, "failed to start pg"}, State}
    end.

start_pg() ->
    case system_monitor_pg:start_link() of
        {ok, _Pid} = X                  -> X;
        {error, {already_started, Pid}} -> {ok, Pid};
        Else                            -> Else
    end.


continue(State) ->
    try
        CfgMap = State#state.cfg_map,
        IP = maps:get(consumer_listen_ip, CfgMap),
        Port = maps:get(consumer_listen_port, CfgMap),

        Dispatch =
            cowboy_router:compile(
              [
               %% {HostMatch, list({PathMatch, Handler, InitialState})}
               {'_', [{"/", ?MODULE, CfgMap#{state => init}}]}
              ]),

        {ok, _} = cowboy:start_clear(
                    consumer_http_listener,
                    [{ip, IP},
                     {port, Port}],
                    #{env => #{dispatch => Dispatch}}
                   ),

        {noreply, State}

    catch
        _Etype:_Err:_Estack ->
            %% FIXME log error
            ?dbg("<ERROR> ~p~n", [{_Etype,_Err,_Estack}]),
            {noreply, State}
    end.


get_consumer_config() ->
    get_config(consumer_config()).

consumer_config() ->
    [consumer_enable,consumer_listen_ip,consumer_listen_port,consumer_secret].



%%
%% Cowboy callback
%%
init(Req0, StateMap) ->
    case cowboy_req:parse_header(<<"authorization">>, Req0, undefined) of
        undefined ->
            ?dbg("got no authorization header~n",[]),
            Req = cowboy_req:reply(401, Req0),
            {ok, Req, StateMap};
        Auth ->
            case get_challenge(Auth) of
                {ok, Challenge} ->
                    ?dbg("got Client Challenge: ~p~n", [Challenge]),
                    {cowboy_websocket,
                     Req0,
                     StateMap#{state := client_challenge,
                               client_challenge => Challenge}};
                not_found ->
                    ?dbg("failed, no Client challenge~n",[]),
                    Req = cowboy_req:reply(401, Req0),
                    {ok, Req, StateMap}
            end
    end.

get_challenge({bearer, Challenge64}) ->
    {ok, base64:decode(Challenge64)};
get_challenge(_) ->
    not_found.


%%
%% Cowboy Websocket callbacks
%%
websocket_init(#{state := client_challenge,
                 client_challenge := ClientChallenge,
                 consumer_secret := Secret} = State) ->
    %%
    %% We got a Client Challenge, send back:
    %%   -  the Client Digest
    %%   -  our Server Challenge
    %%
    ClientDigest = digest(Secret, ClientChallenge),
    ?dbg("mk Client Digest: ~p~n", [ClientDigest]),

    ServerChallenge = mk_challenge(),

    ?dbg("send server challenge: ~p~n", [ServerChallenge]),

    Reply = {server_challenge, ServerChallenge, ClientDigest},

    {[{binary, erlang:term_to_binary(Reply)}],
     State#{state := server_challenge,
            server_challenge => ServerChallenge}}.


%%
%% Expecting client reply with server digest.
%%
websocket_handle({binary,Bin},
                 #{state := server_challenge,
                   consumer_secret := Secret,
                   server_challenge := ServerChallenge} = State) ->
    case erlang:binary_to_term(Bin) of
        {digest, ServerDigest} ->
            ?dbg("got client digest~n",[]),
            case verify_digest(Secret, ServerChallenge, ServerDigest) of
                true ->
                    %% Ok, we are ready to receive data!
                    {[{text,<<"welcome">>}], State#{state := running}};
                false ->
                    ?dbg("got wrong server digest : ~p~n", [ServerDigest]),
                    {[{close, ?CC_1002_PROTO_ERROR, <<"wrong server digest">>}],
                     State}
            end;
        _X ->
            ?dbg("got no client digest : ~p~n", [_X]),
            {[{close, ?CC_1002_PROTO_ERROR, <<"no server digest">>}],
             State}
    end;
%%
%% Expecting client data.
%%
websocket_handle({binary,Bin}, #{state := running} = State) ->
    case erlang:binary_to_term(Bin) of
        {produce, Type, Events} ->
            ?dbg("storing: Type=~p~n", [Type]),
            system_monitor_pg:produce(Type, Events),
            {ok, State};
        _X ->
            ?dbg("got wrong client data: ~p~n", [_X]),
            {[{close, ?CC_1002_PROTO_ERROR, <<"wrong client data">>}],
             State}
    end;
%%
websocket_handle(_Frame, State) ->
    ?dbg("got unknown frame: ~p~n",[_Frame]),
    {[{close, ?CC_1002_PROTO_ERROR, <<"go away">>}], State}.


websocket_info(_Info, State) ->
    ?dbg("got unknown info: ~p~n",[_Info]),
    {ok, State}.


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

%%
%% Simple digest token creation
%%
-define(NONCE_LEN, 21).

nonce() ->
    crypto:strong_rand_bytes(?NONCE_LEN).

digest(Secret, Nonce) ->
    crypto:mac(hmac, sha512, Secret, Nonce).

verify_digest(Secret, Nonce, Digest) ->
    case crypto:mac(hmac, sha512, Secret, Nonce) of
        Digest -> true;
        _      -> false
    end.

encode_token(Nonce, Digest) ->
    base64:encode(<<Nonce/binary,Digest/binary>>).

decode_token(Token) ->
    case base64:decode(Token) of
        <<Nonce:?NONCE_LEN/binary,Digest/binary>> ->
            {ok, {Nonce, Digest}};
        _ ->
            {error, decode_token}
    end.

-ifdef(EUNIT).

digest_test_() ->
    Secret = <<"my-secret-key">>,
    Secret2 = <<"my-secret-key2">>,
    Nonce = nonce(),
    Digest = digest(Secret, Nonce),
    Token = encode_token(Nonce, Digest),

    {ok, {Nonce2, Digest2}} = decode_token(Token),

    [?_assertMatch(true, verify_digest(Secret, Nonce2, Digest2)),
     ?_assertMatch(false, verify_digest(Secret2, Nonce2, Digest2))].

-endif.
