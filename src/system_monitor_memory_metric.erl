%%%-------------------------------------------------------------------
%%% @author Torbjorn Tornkvist <kruskakli@gmail.com>
%%% @copyright (C) 2023, Torbjorn Tornkvist
%%% @doc BEAM memory metric collector.
%%%
%%% @end
%%%-------------------------------------------------------------------
-module(system_monitor_memory_metric).

-behaviour(gen_server).

%% API
-export([start_link/0
        , collect/0
        , monitor/0
        , query/1
        , params/2
        , table/1
        ]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3, format_status/2]).

-define(SERVER, ?MODULE).

-record(state, {}).

%%%===================================================================
%%% API
%%%===================================================================

%% @doc Return what collector callback function to invoke and how often.
%%
%% Example: {Module, Function, RunMonitorAtTerminate, NumberOfTicks}
%%
monitor() ->
    {?MODULE, collect, false, 5}.

%% @doc Collector callback function.
collect() ->
    gen_server:cast(?SERVER, collect).

%% @doc Return SQL statement for inserting collected data into the DB.
query(memory) ->
    <<"insert into memory (node, ts, total, free, allocated, used) VALUES ($1, $2, $3, $4, $5, $6);">>;
%%
query(ertsalloc) ->
    <<"insert into ertsalloc (node, ts, ebinary, driver, eheap, ets, fix, ll, sl, std, temp) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11);">>.

%% @doc Transform the data values to be inserted into the DB.
params(memory, {memory, Node, TS, Tot, Free, Allocated, Used} = _Event) ->
  [ to_str(Node)
  , system_monitor_pg:ts_to_timestamp(TS)
  , Tot
  , Free
  , Allocated
  , Used
  ];
%%
params(ertsalloc, {ertsalloc, Node, TS, Binary, Driver, Eheap, Ets, Fix, LL, SL, Std, Temp} = _Event) ->
  [ to_str(Node)
  , system_monitor_pg:ts_to_timestamp(TS)
  , Binary
  , Driver
  , Eheap
  , Ets
  , Fix
  , LL
  , SL
  , Std
  , Temp
  ].

%% @doc Return the DB table name.
table(memory) ->
    <<"memory">>;
%%
table(ertsalloc) ->
    <<"ertsalloc">>.

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
    {ok, #state{}}.

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

handle_cast(collect, State) ->
    Node = node(),
    TS = os:system_time(),
    {MemTotal, MemFree} = get_memory_from_os(),
    Allocated = recon_alloc:memory(allocated),
    Used = recon_alloc:memory(used),

    [ BinaryAlloc
    , DriverAlloc
    , EheapAlloc
    , EtsAlloc
    , FixAlloc
    , LlAlloc
    , SlAlloc
    , StdAlloc
    , TempAlloc
    ] = allocated_types(),

    M = [{memory, Node, TS, MemTotal, MemFree, Allocated, Used}],
    system_monitor_callback:produce(memory, M),

    E = [{ertsalloc, Node, TS, BinaryAlloc, DriverAlloc, EheapAlloc,
          EtsAlloc, FixAlloc, LlAlloc, SlAlloc, StdAlloc, TempAlloc}],
    system_monitor_callback:produce(ertsalloc, E),

    {noreply, State};
%%
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

%% Get allocated memory for all the ERTS allocator types;
%% preserve the Key order and allow for non-existant allocator.
allocated_types() ->
    L = recon_alloc:memory(allocated_types),
    Keys = [binary_alloc,driver_alloc,eheap_alloc,ets_alloc,
            fix_alloc,ll_alloc,sl_alloc,std_alloc,temp_alloc],
    lists:foldr(
      fun(Key, Acc) ->
              case lists:keyfind(Key, 1, L) of
                  false      -> [0 | Acc];
                  {Key, Val} -> [Val | Acc]
              end
      end, [], Keys).

%% get_memory_from_os() -> {Total, Free}
%%
%% Code based on RabbitMQ: vm_memory_monitor.erl
%% Original code was part of OTP and released under:
%% "Mozilla Public License, v. 2.0.""
%%
get_memory_from_os() ->
    try
        get_memory(os:type())
    catch
        _:_ ->
            0
    end.

get_memory({unix, darwin}) ->
    {sysctl("hw.memsize"),
     sysctl("hw.physmem")};
%%
get_memory({unix, linux}) ->
    Dict = read_meminfo(),
    {%% Total usable ram (i.e. physical ram minus a few reserved
     %% bits and the kernel binary code)
     dict:fetch('MemTotal', Dict),
     %% The amount of physical RAM, in kilobytes, left unused by the system.
     dict:fetch('MemFree', Dict)
    }.

read_meminfo() ->
    File = read_proc_file("/proc/meminfo"),
    Lines = string:tokens(File, "\n"),
    dict:from_list(lists:map(fun parse_line_linux/1, Lines)).


sysctl(Def) ->
    R = cmd("/usr/bin/env sysctl -n " ++ Def) -- "\n",
    try
        list_to_integer(R)
    catch
        _:_ ->
            0
    end.

cmd(Command) ->
    cmd(Command, true).

cmd(Command, ThrowIfMissing) ->
    Exec = hd(string:tokens(Command, " ")),
    case {ThrowIfMissing, os:find_executable(Exec)} of
        {true, false} ->
            throw({command_not_found, Exec});
        {false, false} ->
            {error, command_not_found};
        {_, _Filename} ->
            os:cmd(Command)
    end.

%% A line looks like "MemTotal:         502968 kB"
%% or (with broken OS/modules) "Readahead      123456 kB"
parse_line_linux(Line) ->
    {Name, Value, UnitRest} =
        case string:tokens(Line, ":") of
            %% no colon in the line
            [S] ->
                [K, RHS] = re:split(S, "\s", [{parts, 2}, {return, list}]),
                [V | Unit] = string:tokens(RHS, " "),
                {K, V, Unit};
            [K, RHS | _Rest] ->
                [V | Unit] = string:tokens(RHS, " "),
                {K, V, Unit}
        end,
    Value1 = case UnitRest of
        []     -> list_to_integer(Value); %% no units
        ["kB"] -> list_to_integer(Value) * 1024;
        ["KB"] -> list_to_integer(Value) * 1024
    end,
    {list_to_atom(Name), Value1}.

%% file:read_file does not work on files in /proc as it seems to get
%% the size of the file first and then read that many bytes. But files
%% in /proc always have length 0, we just have to read until we get
%% eof.
read_proc_file(File) ->
    {ok, IoDevice} = file:open(File, [read, raw]),
    Res = read_proc_file(IoDevice, []),
    _ = file:close(IoDevice),
    lists:flatten(lists:reverse(Res)).

-define(BUFFER_SIZE, 1024).
read_proc_file(IoDevice, Acc) ->
    case file:read(IoDevice, ?BUFFER_SIZE) of
        {ok, Res} -> read_proc_file(IoDevice, [Res | Acc]);
        eof       -> Acc
    end.

to_str(I) when is_integer(I) ->
    erlang:integer_to_list(I);
to_str(A) when is_atom(A) ->
    erlang:atom_to_list(A);
to_str(L) when is_list(L) ->
    L.
