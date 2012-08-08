%% @doc Distributed consistent key-value store
%%
%% Reads use the local copy, all data is replicated to all nodes.
%%
%% Writing is done in two phases, in the first phase the key is
%% locked, if a quorum can be made, the value is written.

-module(locker).
-behaviour(gen_server).
-author('Knut Nesheim <knutin@gmail.com>').

%% API
-export([start_link/1, start_link/4]).
-export([set_w/2, set_nodes/3]).

-export([lock/2, lock/3, extend_lease/3, release/2]).
-export([dirty_read/1]).
-export([lag/0, summary/0]).


-export([get_write_lock/4, do_write/6, release_write_lock/3]).
-export([get_meta/0, get_meta_ets/1, get_debug_state/0]).


%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-record(state, {
          %% The masters queue writes in the trans_log for batching to
          %% the replicas, triggered every N milliseconds by the
          %% push_replica timer
          trans_log = [],

          %% Timer references
          lease_expire_ref,
          write_locks_expire_ref,
          push_trans_log_ref
}).

-define(LEASE_LENGTH, 2000).
-define(DB, locker_db).
-define(LOCK_DB, locker_lock_db).
-define(META_DB, locker_meta_db).

%%%===================================================================
%%% API
%%%===================================================================

start_link(W) ->
    start_link(W, 10000, 1000, 100).

start_link(W, LeaseExpireInterval, LockExpireInterval, PushTransInterval) ->
    Args = [W, LeaseExpireInterval, LockExpireInterval, PushTransInterval],
    gen_server:start_link({local, ?MODULE}, ?MODULE, Args, []).

lock(Key, Value) ->
    lock(Key, Value, ?LEASE_LENGTH).

lock(Key, Value, LeaseLength) ->
    lock(Key, Value, LeaseLength, 5000).

%% @doc: Tries to acquire the lock. In case of unreachable nodes, the
%% timeout is 1 second per node which might need tuning. Returns {ok,
%% W, V, C} where W is the number of agreeing nodes required for a
%% quorum, V is the number of nodes that voted in favor of this lock
%% in the case of contention and C is the number of nodes who
%% acknowledged commit of the lock successfully.
lock(Key, Value, LeaseLength, Timeout) ->
    Nodes = get_meta_ets(nodes),
    W = get_meta_ets(w),

    %% Try getting the write lock on all nodes
    {Tag, RequestReplies, _BadNodes} = get_write_lock(Nodes, Key, not_found, Timeout),

    case ok_responses(RequestReplies) of
        {OkNodes, _} when length(OkNodes) >= W ->
            %% Majority of nodes gave us the lock, go ahead and do the
            %% write on all masters. The write also releases the
            %% lock. Replicas are synced asynchronously by the
            %% masters.
            {WriteReplies, _} = do_write(Nodes,
                                         Tag, Key, Value,
                                         LeaseLength, Timeout),
            {OkWrites, _} = ok_responses(WriteReplies),
            {ok, W, length(OkNodes), length(OkWrites)};
        _ ->
            {_AbortReplies, _} = release_write_lock(Nodes, Tag, Timeout),
            {error, no_quorum}
    end.

release(Key, Value) ->
    release(Key, Value, 5000).

release(Key, Value, Timeout) ->
    Nodes = get_meta_ets(nodes),
    Replicas = get_meta_ets(replicas),
    W = get_meta_ets(w),

    %% Try getting the write lock on all nodes
    {Tag, WriteLockReplies, _} = get_write_lock(Nodes, Key, Value, Timeout),

    case ok_responses(WriteLockReplies) of
        {OkNodes, _} when length(OkNodes) >= W ->
            Request = {release, Key, Value, Tag},
            {ReleaseReplies, _BadNodes} =
                gen_server:multi_call(Nodes ++ Replicas, locker, Request, Timeout),

            {OkWrites, _} = ok_responses(ReleaseReplies),

            {ok, W, length(OkNodes), length(OkWrites)};
        _ ->
            {_AbortReplies, _} = release_write_lock(Nodes, Tag, Timeout),
            {error, no_quorum}
    end.


extend_lease(Key, Value, LeaseLength) ->
    extend_lease(Key, Value, LeaseLength, 5000).

%% @doc: Extends the lease for the lock on all nodes that are up. What
%% really happens is that the expiration is scheduled for (now + lease
%% time), to allow for nodes that just joined to set the correct
%% expiration time without knowing the start time of the lease.
extend_lease(Key, Value, LeaseLength, Timeout) ->
    Nodes = get_meta_ets(nodes),
    W = get_meta_ets(w),

    {Tag, WriteLockReplies, _} = get_write_lock(Nodes, Key, Value, Timeout),

    case ok_responses(WriteLockReplies) of
        {N, _E} when length(N) >= W ->

            Request = {extend_lease, Tag, Key, Value, LeaseLength},
            {Replies, _} = gen_server:multi_call(Nodes, locker, Request, Timeout),
            {_, FailedExtended} = ok_responses(Replies),
            release_write_lock(FailedExtended, Tag, Timeout),
            ok;
        _ ->
            {_AbortReplies, _} = release_write_lock(Nodes, Tag, Timeout),
            {error, no_quorum}
    end.

%% @doc: A dirty read does not create a read-quorum so consistency is
%% not guaranteed. The value is read directly from a local ETS-table,
%% so the performance should be very high.
dirty_read(Key) ->
    case ets:lookup(?DB, Key) of
        [{Key, Value, _Lease}] ->
            {ok, Value};
        [] ->
            {error, not_found}
    end.

%%
%% Helpers for operators
%%

lag() ->
    {Time, Result} = timer:tc(fun() ->
                                      lock({'__lock_lag_probe', os:timestamp()},
                                           foo, 10)
                              end),
    {Time / 1000, Result}.

summary() ->
    {ok, WriteLocks, Leases, _LeaseExpireRef, _WriteLocksExpireRef} =
        get_debug_state(),
    [{write_locks, length(WriteLocks)},
     {leases, length(Leases)}].

get_meta() ->
    {get_meta_ets(nodes), get_meta_ets(replicas), get_meta_ets(w)}.



%%
%% Helpers
%%

get_write_lock(Nodes, Key, Value, Timeout) ->
    Tag = make_ref(),
    Request = {get_write_lock, Key, Value, Tag},
    {Replies, Down} = gen_server:multi_call(Nodes, locker, Request, Timeout),
    {Tag, Replies, Down}.

do_write(Nodes, Tag, Key, Value, LeaseLength, Timeout) ->
    gen_server:multi_call(Nodes, locker,
                          {write, Tag, Key, Value, LeaseLength},
                          Timeout).


release_write_lock(Nodes, Tag, Timeout) ->
    gen_server:multi_call(Nodes, locker, {release_write_lock, Tag}, Timeout).

get_meta_ets(Key) ->
    case ets:lookup(?META_DB, Key) of
        [] ->
            throw({locker, no_such_meta_key});
        [{Key, Value}] ->
            Value
    end.



%% @doc: Replaces the primary and replica node list on all nodes in
%% the cluster. Assumes no failures.
set_nodes(Cluster, Primaries, Replicas) ->
    {_Replies, []} = gen_server:multi_call(Cluster, locker,
                                           {set_nodes, Primaries, Replicas}),
    ok.

set_w(Cluster, W) when is_integer(W) ->
    {_Replies, []} = gen_server:multi_call(Cluster, locker, {set_w, W}),
    ok.

get_debug_state() ->
    gen_server:call(?MODULE, get_debug_state).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================
init([W, LeaseExpireInterval, LockExpireInterval, PushTransInterval]) ->
    ?DB = ets:new(?DB, [named_table, protected,
                        {read_concurrency, true},
                        {write_concurrency, true}]),
    ?META_DB = ets:new(?META_DB, [named_table, protected,
                                  {read_concurrency, true}]),
    ets:insert(?META_DB, {w, W}),
    ets:insert(?META_DB, {nodes, []}),
    ets:insert(?META_DB, {replicas, []}),

    ?LOCK_DB = ets:new(?LOCK_DB, [named_table, protected,
                                  {read_concurrency, true}]),

    {ok, LeaseExpireRef} = timer:send_interval(LeaseExpireInterval, expire_leases),
    {ok, WriteLocksExpireRef} = timer:send_interval(LockExpireInterval, expire_locks),
    {ok, PushTransLog} = timer:send_interval(PushTransInterval, push_trans_log),
    {ok, #state{lease_expire_ref = LeaseExpireRef,
                write_locks_expire_ref = WriteLocksExpireRef,
                push_trans_log_ref = PushTransLog}}.


%%
%% WRITE-LOCKS
%%

handle_call({get_write_lock, Key, Value, Tag}, _From, State) ->
    %% Phase 1: Grant a write lock on the key if the value in the
    %% database is what the coordinator expects. If the atom
    %% 'not_found' is given as the expected value, the lock is granted
    %% if the key does not exist.
    %%
    %% Only one lock per key is allowed. Timeouts are triggered when
    %% handling 'expire_locks'

    case is_locked(Key) of
        true ->
            %% Key already has a write lock
            {reply, {error, already_locked}, State};
        false ->
            case ets:lookup(?DB, Key) of
                [{Key, DbValue, _Expire}] when DbValue =:= Value ->
                    true = set_lock(Tag, Key, now_to_ms()),
                    {reply, ok, State};
                [] when Value =:= not_found->
                    true = set_lock(Tag, Key, now_to_ms()),
                    {reply, ok, State};
                _Other ->
                    {reply, {error, not_expected_value}, State}
            end
    end;

handle_call({release_write_lock, Tag}, _From, State) ->
    del_lock(Tag),
    {reply, ok, State};


%%
%% DATABASE OPERATIONS
%%

handle_call({write, LockTag, Key, Value, LeaseLength}, _From,
            #state{trans_log = TransLog} = State) ->
    %% Database write. LockTag might be a valid write-lock, in which
    %% case it is deleted to avoid the extra round-trip of explicit
    %% delete. If it is not valid, we assume the coordinator had a
    %% quorum before writing.
    del_lock(LockTag),
    NewTransLog = [{write, Key, Value, LeaseLength} | TransLog],
    true = ets:insert(?DB, {Key, Value, now_to_ms() + LeaseLength}),
    {reply, ok, State#state{trans_log = NewTransLog}};


%%
%% LEASES
%%

handle_call({extend_lease, LockTag, Key, Value, ExtendLength}, _From,
            #state{trans_log = TransLog} = State) ->
    %% Extending a lease sets a new expire time. As the coordinator
    %% holds a write lock on the key, it is not necessary to perform
    %% any validation.

    case ets:lookup(?DB, Key) of
        [{Key, Value, _}] ->
            del_lock(LockTag),
            NewTransLog = [{write, Key, Value, ExtendLength} | TransLog],
            true = ets:insert(?DB, {Key, Value, now_to_ms() + ExtendLength}),
            {reply, ok, State#state{trans_log = NewTransLog}};

        [{Key, _OtherValue, _}] ->
            {reply, {error, not_owner}, State};
        [] ->
            {reply, {error, not_found}, State}
    end;


handle_call({release, Key, Value, LockTag}, _From,
            #state{trans_log = TransLog} = State) ->
    case ets:lookup(?DB, Key) of
        [{Key, Value, _Lease}] ->
            del_lock(LockTag),
            NewTransLog = [{delete, Key} | TransLog],
            true = ets:delete(?DB, Key),
            {reply, ok, State#state{trans_log = NewTransLog}};

        [{Key, _OtherValue, _}] ->
            {reply, {error, not_owner}, State};
        [] ->
            {reply, {error, not_found}, State}
    end;




%%
%% ADMINISTRATION
%%

handle_call({set_w, W}, _From, State) ->
    ets:insert(?META_DB, {w, W}),
    {reply, ok, State};

handle_call({set_nodes, Primaries, Replicas}, _From, State) ->
    ets:insert(?META_DB, {nodes, ordsets:to_list(
                                   ordsets:from_list(Primaries))}),
    ets:insert(?META_DB, {replicas, ordsets:to_list(
                                      ordsets:from_list(Replicas))}),
    {reply, ok, State};

handle_call(get_debug_state, _From, State) ->
    {reply, {ok, ets:tab2list(?LOCK_DB),
             ets:tab2list(?DB),
             State#state.lease_expire_ref,
             State#state.write_locks_expire_ref}, State}.


%%
%% REPLICATION
%%

handle_cast({trans_log, _FromNode, TransLog}, State) ->
    %% Replay transaction log. Every master pushes it's log to us and
    %% for now we blindly write whatever we get. Hopefully we won't
    %% get interleaved write and deletes for the same key.

    %% In the future, we might want to offset the lease length in the
    %% master before writing it to the log to ensure the lease length
    %% is at least reasonably similar for all replicas.

    lists:foreach(fun ({write, Key, Value, LeaseLength}) ->
                          ets:insert(?DB, {Key, Value, now_to_ms() + LeaseLength});
                      ({delete, Key}) ->
                          ets:delete(?DB, Key)
                  end, TransLog),
    {noreply, State};

handle_cast(Msg, State) ->
    {stop, {badmsg, Msg}, State}.

%%
%% SYSTEM EVENTS
%%


handle_info(expire_leases, State) ->
    %% Run through each element in the ETS-table checking for expired
    %% keys so we can at the same time check if the key is locked. If
    %% we would use select_delet/2, we could not check for locks and
    %% we would still have to scan the entire table.
    %%
    %% If expiration of many keys becomes too expensive, we could keep
    %% a priority queue mapping expire to key.

    Now = now_to_ms(),
    ExpiredKeys = lists:foldl(
                    fun ({Key, _Value, ExpireTime}, Acc) ->
                            case is_expired(ExpireTime, Now)
                                andalso not is_locked(Key) of
                                true ->
                                    [Key | Acc];
                                false ->
                                    Acc
                            end
                    end, [], ets:tab2list(?DB)),

    lists:foreach(fun (Key) -> ets:delete(?DB, Key) end, ExpiredKeys),
    {noreply, State};


handle_info(expire_locks, State) ->
    %% Now = now_to_ms(),
    %% NewLocks = [L || {_, _, StartTimeMs} = L <- Locks, StartTimeMs + 1000 > Now],
    {noreply, State};

handle_info(push_trans_log, #state{trans_log = TransLog} = State) ->
    %% Push transaction log to *all* replicas. With multiple masters,
    %% each replica will receive the same write multiple times.
    gen_server:abcast(get_meta_ets(replicas), locker, {trans_log, node(), TransLog}),
    {noreply, State#state{trans_log = TransLog}};

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

now_to_ms() ->
    now_to_ms(now()).

now_to_ms({MegaSecs,Secs,MicroSecs}) ->
    (MegaSecs * 1000000 + Secs) * 1000 + MicroSecs div 1000.

%%
%% WRITE-LOCKS
%%

is_locked(Key) ->
    ets:match(?LOCK_DB, {{'_', Key}, '_'}) =/= [].

set_lock(Tag, Key, Timestamp) ->
    ets:insert_new(?LOCK_DB, {{Tag, Key}, Timestamp}).

del_lock(Tag) ->
    ets:match_delete(?LOCK_DB, {{Tag, '_'}, '_'}).

is_expired(ExpireTime, NowMs)->
    ExpireTime < NowMs.

ok_responses(Replies) ->
    lists:partition(fun ({_, ok}) -> true;
                        (_)       -> false
                    end, Replies).
