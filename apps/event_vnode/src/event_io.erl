%%%-------------------------------------------------------------------
%%% @author Heinz Nikolaus Gies <heinz@schroedinger.local>
%%% @copyright (C) 2014, Heinz Nikolaus Gies
%%% @doc
%%%
%%% @end
%%% Created : 24 Sep 2014 by Heinz Nikolaus Gies <heinz@schroedinger.local>
%%%-------------------------------------------------------------------
-module(event_io).

-behaviour(gen_server).

-include_lib("mmath/include/mmath.hrl").

%% API
-export([start_link/1, count/1,
         fold/3, delete/1,
         %%delete/2, delete/3,
         close/1, read/6, write/4]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(SERVER, ?MODULE).
-define(WEEK, 604800). %% Seconds in a week.
-define(MAX_Q_LEN, 20).

-type entry() :: estore:estore().

-record(state, {
          partition,
          node,
          estores = gb_trees:empty() :: gb_trees:tree(binary(), entry()),
          dir,
          fold_size,
          max_open_stores
         }).

-type state() :: #state{}.

%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%%
%% @spec start_link() -> {ok, Pid} | ignore | {error, Error}
%% @end
%%--------------------------------------------------------------------
start_link(Partition) ->
    gen_server:start_link(?MODULE, [Partition], []).

write(Pid, Bucket, Events, MaxLen) ->
    case erlang:process_info(Pid, message_queue_len) of
        {message_queue_len, N} when N > MaxLen ->
            swrite(Pid, Bucket, Events);
        _ ->
            gen_server:cast(Pid, {write, Bucket, Events})
    end.

swrite(Pid, Bucket, Events) ->
    gen_server:call(Pid, {write, Bucket, Events}).

read(Pid, Bucket, Start, End, ReqID, Sender) ->
    lager:info("read1: ~p ~p ~p", [Bucket, Start, End]),
    gen_server:cast(Pid, {read, Bucket, Start, End, ReqID, Sender}).

count(Pid) ->
    gen_server:call(Pid, count).

fold(Pid, Fun, Acc0) ->
    gen_server:call(Pid, {fold, Fun, Acc0}).

delete(Pid) ->
    gen_server:call(Pid, delete).

close(Pid) ->
    gen_server:call(Pid, close).

%% delete(Pid, Bucket) ->
%%     gen_server:call(Pid, {delete, Bucket}).

%% delete(Pid, Bucket, Before) ->
%%     gen_server:call(Pid, {delete, Bucket, Before}).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Initializes the server
%%
%% @spec init(Args) -> {ok, State} |
%%                     {ok, State, Timeout} |
%%                     ignore |
%%                     {stop, Reason}
%% @end
%%--------------------------------------------------------------------
init([Partition]) ->
    process_flag(trap_exit, true),
    DataDir = case application:get_env(riak_core, platform_data_dir) of
                  {ok, DD} ->
                      DD;
                  _ ->
                      "data"
              end ++ "/events",
    FoldSize = case application:get_env(event_vnode, handoff_chunk) of
                   {ok, FS} ->
                       FS;
                   _ ->
                       10*1024
               end,
    PartitionDir = [DataDir, $/,  integer_to_list(Partition)],

    {ok, #state{ partition = Partition,
                 node = node(),
                 dir = PartitionDir,
                 fold_size = FoldSize
               }}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages
%%
%% @spec handle_call(Request, From, State) ->
%%                                   {reply, Reply, State} |
%%                                   {reply, Reply, State, Timeout} |
%%                                   {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, Reply, State} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------

handle_call(count, _From, State) ->
    case list_buckets(State) of
        {ok, Buckets} ->
            Count = length(Buckets),
            {reply, Count, State};
        _ ->
            {reply, 0, State}
    end;

handle_call({fold, _Fun, _Acc0}, _From, State) ->
    case list_buckets(State) of
        {ok, Buckets} ->
            {reply, {ok, Buckets}, State};
        _ ->
            {reply, empty, State}
    end;

handle_call(delete, _From, State = #state{dir = PartitionDir}) ->
    gb_trees:map(fun(Bucket, _EStore) ->
                         lager:error("Can't delete event buckets yet"),
                         %%estore:delete(EStore),
                         file:del_dir([PartitionDir, $/, Bucket])
                 end, State#state.estores),
    {reply, ok, State#state{estores = gb_trees:empty()}};

handle_call(close, _From, State) ->
    gb_trees:map(fun(_, EStore) ->
                         estore:close(EStore)
                 end, State#state.estores),
    State1 = State#state{estores = gb_trees:empty()},
    {reply, ok, State1};

%% handle_call({delete, Bucket}, _From,
%%             State = #state{dir = Dir}) ->
%%     {R, State1} = case get_set(Bucket, State) of
%%                       {ok, {EStore, S1}} ->
%%                           estore:delete(EStore),
%%                           file:del_dir([Dir, $/, Bucket]),
%%                           Estore = gb_trees:delete(Bucket, S1#state.estores),
%%                           {ok, S1#state{estores = Estore}};
%%                       _ ->
%%                           {not_found, State}
%%                   end,
%%     {reply, R, State1};

%% handle_call({delete, Bucket, Before}, _From, State) ->
%%     {R, State1} = case get_set(Bucket, State) of
%%                       {ok, {EStore, S1}} ->
%%                           {ok, EStore1} = estore:delete(Before, EStore),
%%                           Estore = gb_trees:enter(
%%                                      Bucket, EStore1, S1#state.estores),
%%                           {ok, S1#state{estores = Estore}};
%%                       _ ->
%%                           {not_found, State}
%%                   end,
%%     {reply, R, State1};

handle_call(buckets, _From, State) ->
    Buckets1 = case list_buckets(State) of
                   {ok, Buckets} ->
                       btrie:from_list([{list_to_binary(B), t}
                                        || B <- Buckets]);
                   _ ->
                       btrie:new()
               end,
    {reply, {ok, Buckets1}, State};


handle_call({write, Bucket, Events}, _From, State) ->
    State1 = do_write(Bucket, Events, State),
    {reply, ok, State1};

handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages
%%
%% @spec handle_cast(Msg, State) -> {noreply, State} |
%%                                  {noreply, State, Timeout} |
%%                                  {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_cast({write, Bucket, Events}, State) ->
    State1 = do_write(Bucket, Events, State),
    {noreply, State1};

handle_cast({read, Bucket, Start, End, ReqID, Sender},
            State = #state{node = N, partition = P}) ->
    lager:info("read2: ~p ~p ~p", [Bucket, Start, End]),
    {D, State1} = do_read(Bucket, Start, End, State),
    riak_core_vnode:reply(Sender, {ok, ReqID, {P, N}, D}),
    {noreply, State1};


handle_cast(_Msg, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages
%%
%% @spec handle_info(Info, State) -> {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_info({'EXIT', _From, _Reason}, State = #state{estores = Estore}) ->
    gb_trees:map(fun(_, EStore) ->
                         estore:close(EStore)
                 end, Estore),
    {stop, normal, State#state{estores = gb_trees:empty()}};

handle_info(_Info, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%%
%% @spec terminate(Reason, State) -> void()
%% @end
%%--------------------------------------------------------------------
terminate(_Reason, #state{estores = Estore}) ->
    gb_trees:map(fun(_, EStore) ->
                         estore:close(EStore)
                 end, Estore),
    ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @spec code_change(OldVsn, State, Extra) -> {ok, NewState}
%% @end
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

-spec bucket_dir(binary(), non_neg_integer()) -> string().

bucket_dir(Bucket, Partition) ->
    DataDir = application:get_env(riak_core, platform_data_dir, "data"),
    PartitionDir = DataDir ++ [$/, integer_to_list(Partition)],
    BucketDir = PartitionDir ++ [$/, binary_to_list(Bucket)],
    file:make_dir(PartitionDir),
    file:make_dir(BucketDir),
    BucketDir.

-spec new_store(non_neg_integer(), binary()) ->
                       estore:estore().
new_store(Partition, Bucket) when is_binary(Bucket) ->
    BucketDir = bucket_dir(Bucket, Partition),
    %% Default bucket points are stored in ms
    PointsPerFile = dalmatiner_opt:ppf(Bucket),
    Resolution = dalmatiner_opt:resolution(Bucket),
    PPF = {PointsPerFile * Resolution, ms},
    lager:debug("[event_io:~p] Opening ~s@~p",
                [Partition, Bucket, PointsPerFile]),
    {ok, EStore} = estore:new(BucketDir, [{file_size, PPF}]),
    EStore.

-spec get_set(binary(), state()) ->
                     {ok, {entry(), state()}} |
                     {error, not_found}.
get_set(Bucket, State=#state{estores = Store}) ->
    case gb_trees:lookup(Bucket, Store) of
        {value, EStore} ->
            {ok, {EStore, State}};
        none ->
            case bucket_exists(State#state.partition, Bucket) of
                true ->
                    R = new_store(State#state.partition, Bucket),
                    Store1 = gb_trees:insert(Bucket, R, Store),
                    {ok, {R, State#state{estores = Store1}}};
                _ ->
                    {error, not_found}
            end
    end.

-spec get_or_create_set(binary(), state()) ->
                               {entry(), state()}.
get_or_create_set(Bucket, State=#state{estores = Store}) ->
    case get_set(Bucket, State) of
        {ok, R} ->
            R;
        {error, not_found} ->
            EStore = new_store(State#state.partition, Bucket),
            Store1 = gb_trees:insert(Bucket, EStore, Store),
            {EStore, State#state{estores = Store1}}
    end.

bucket_exists(Partition, Bucket) ->
    DataDir = case application:get_env(riak_core, platform_data_dir) of
                  {ok, DD} ->
                      DD;
                  _ ->
                      "data"
              end,
    PartitionDir = [DataDir | [$/ |  integer_to_list(Partition)]],
    BucketDir = [PartitionDir, [$/ | binary_to_list(Bucket)]],
    filelib:is_dir(BucketDir).

-spec do_write(binary(), [efile:event()], state()) ->
                      state().
do_write(Bucket, Events, State) ->
    {EStore, State1} = get_or_create_set(Bucket, State),
    {ok, EStore1} = estore:append(Events, EStore),
    Store1 = gb_trees:enter(Bucket, EStore1, State1#state.estores),
    State1#state{estores = Store1}.

-spec do_read(binary(), pos_integer(), pos_integer(), state()) ->
                     {sets:set(), state()}.
do_read(Bucket, Start, End, State = #state{})
  when is_binary(Bucket), is_integer(Start), is_integer(End),
       Start =< End, Start > 0 ->
    lager:info("read: ~p ~p ~p", [Bucket, Start, End]),
    case get_set(Bucket, State) of
        {ok, {EStore, S2}} ->
            lager:info("reading: ~p", [{Start, End, EStore}]),
            {ok, Events, EStore1} = estore:read(Start, End, EStore),
            lager:info("=> ~p @ ~p", [Events, EStore1]),

            Stores = gb_trees:enter(Bucket, EStore1, S2#state.estores),
            {sets:from_list(Events), S2#state{estores = Stores}};
        _ ->
            lager:warning("[IO] Unknown event: ~p", [Bucket]),
            {sets:new(), State}
    end.

list_buckets(#state{dir = PartitionDir}) ->
    file:list_dir(PartitionDir).
