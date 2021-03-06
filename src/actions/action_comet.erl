% vim: sw=4 ts=4 et ft=erlang
% Nitrogen Web Framework for Erlang
% Copyright (c) 2008-2010 Rusty Klophaus
% See MIT-LICENSE for licensing information.

-module (action_comet).
-include_lib ("wf.hrl").
-compile(export_all).
-define (COMET_INTERVAL, 10 * 1000).
-define (TEN_SECONDS, 10 * 1000).
-define (TWENTY_SECONDS, 20 * 1000).

% Comet and polling/continuations are now handled using Nitrogen's asynchronous
% processing scheme. This allows you to fire up an asynchronous process with the
% #comet { fun=AsyncFunction } action.
%
% TERMINOLOGY:

% AsyncFunction - An Erlang function that executes in the background. The function
% generates Actions that are then sent to the browser via the accumulator. In addition
% each AsyncFunction is part of one (and only one) pool. The pool name provides a way
% to identify previously spawned processes, much like a Pid. Messages sent to the pool
% are distributed to all AsyncFunction processes in that pool.
%
% Pool - A pool contains one or more running AsyncFunctions. Any messages sent to the pool
% are distributed to all processes within the pool. Pools can either have a local
% or global scope. Local scope means that the pool applies only to the current
% series of page requests by a user. Global means that the pool applies to
% the entire system. Global pools provide the foundation for chat applets and 
% other interactive/multi-user software.
%
% Series - A series of requests to a Nitrogen resource. A series consists of 
% the first request plus any postbacks by the same visitor in the same browser
% window.
% 
% Accumulator - There is one accumulator per series. The accumulator holds
% Nitrogen actions generated by AsyncFunctions, and is checked at the end
% of each Nitrogen request for anything that should be sent to the browser.
%
% AsyncGuardian - There is one AsyncGuardian for each AsyncFunction. The
% Guardian is responsible for informing the Accumulator when an AsyncFunction
% dies, and vice versa.

%%% INTERFACE %%%

%% NOTE: For comet/1, comet/2, and comet_global/2, there was a bug that would
%% cause the process to loop forever without being killed in the event that
%% wf:comet was called without javascript being loaded.  This bug is documented
%% here: https://github.com/nitrogen/nitrogen/issues/37
%%
%% The "Easy" fix would be to change those functions to start the comet call
%% inside the postback by changing function=Pid to function=F. Then we would
%% be guaranteed that the accumulator would be watching the pid and can kill it
%% on its own. But the drawback to this is that the comet function itself would
%% not start until the postback is received, meaning the function wouldn't be started
%% until javascript is loaded on the client and the postback received by the server.
%% This may be too much latency, so I've introduced a couple of hacks to make sure that
%% the pid is killed if the accumulator is never started (meaning never posted back).

%% @doc Convenience method to start a comet process.
comet(F) -> 
    comet(F, default).

%% @doc Convenience method to start a comet process.
comet({Name, F, Msg}, Pool) when is_function(F) ->
    Pid = spawn_with_context({Name, F, Msg}, page),
    wf:wire(page, page, #comet { function={Name, F, Msg}, pool=Pool, scope=local }),
    {ok, Pid};
comet({Name, F}, Pool) when is_function(F) ->
    Pid = spawn_with_context({Name, F}, page),
    wf:wire(page, page, #comet { function={Name, F}, pool=Pool, scope=local }),
    {ok, Pid};
comet(F, Pool) ->
    Pid = spawn_with_context(F,page),
    wf:wire(page, page, #comet { function=Pid, pool=Pool, scope=local }),
    {ok, Pid}.

%% @doc Convenience method to start a comet process with global pool.
comet_global({Name, F, Msg}, Pool) ->
    Pid = spawn_with_context({Name, F, Msg}, page),
    wf:wire(page, page, #comet { function={Name, F, Msg}, pool=Pool, scope=global }),
    {ok, Pid};
comet_global({Name, F}, Pool) ->
    Pid = spawn_with_context({Name, F}, page),
    wf:wire(page, page, #comet { function={Name, F}, pool=Pool, scope=global }),
    {ok, Pid};
comet_global(F, Pool) ->
    Pid = spawn_with_context(F,page),
    wf:wire(page, page, #comet { function=Pid, pool=Pool, scope=global }),
    {ok, Pid}.

%% @doc Gather all wired actions, and send to the accumulator.
flush() ->
    SeriesID = wf_context:series_id(),
    {ok, AccumulatorPid} = get_accumulator_pid(SeriesID),
    Actions = wf_context:actions(),
    AccumulatorPid!{add_actions, Actions},
    ok.

%% @doc Send a message to all processes in the specified local pool.
send(Pool, Message) ->
    inner_send(Pool, local, Message).

%% @doc Send a message to all processes in the specified global pool.
send_global(Pool, Message) ->
    inner_send(Pool, global, Message).

%%% - ACTION - %%%

render_action(Record) -> 
    % If the pool is undefined, then give it a random value.
    Record1 = case Record#comet.pool == undefined of
        true -> Record#comet { pool=wf:temp_id() };
        false -> Record
    end,

    % This will immediately trigger a postback to event/1 below.
    #event {
        delegate=?MODULE,
        postback={spawn_async_function, Record1}
    }.

% This event is called to start a Nitrogen async loop.
% In the process of starting the function, it will create
% an accumulator and a pool if they don't already exist.
event({spawn_async_function, Record}) ->
    % Some values...
    SeriesID = wf_context:series_id(),
    Pool = Record#comet.pool,
    Scope = Record#comet.scope,


    % Get or start the accumulator process, which is used to hold any Nitrogen Actions 
    % that are generated by async processes.
    {ok, AccumulatorPid} = get_accumulator_pid(SeriesID),

    % Get or start the pool process, which is a distributor that sends Erlang messages
    % to the running async function.
    {ok, PoolPid} = get_pool_pid(SeriesID, Pool, Scope), 

    % Create a process for the AsyncFunction...
    FunctionPid = case Record#comet.function of
        {Name, F, Msg} when is_function(F) ->
            P = spawn_with_context({Name, F, Msg}, postback),
            notify_accumulator_checker(P),
            P;
        {Name, F} when is_function(F) ->
            P = spawn_with_context({Name, F}, postback),
            notify_accumulator_checker(P),
            P;
        F when is_function(F) ->
            spawn_with_context(F, postback);
        P when is_pid(P) -> 
            notify_accumulator_checker(P),
            P
    end,

    % Create a process for the AsyncGuardian...
    DyingMessage = Record#comet.dying_message,
    GuardianPid = erlang:spawn(fun() -> guardian_process(FunctionPid, AccumulatorPid, PoolPid, DyingMessage) end),

    % Register the function with the accumulator and the pool.
    AccumulatorPid!{add_guardian, GuardianPid},
    PoolPid!{add_process, FunctionPid},

    % Only start the async event loop if it has not already been started...
    Actions = [
        "if (!document.comet_started) { document.comet_started=true; ", make_async_event(0), " }"
    ],
    wf:wire(page, page, Actions);



% This clause is the heart of async functions. It
% is first triggered by the event/1 function above,
% and then continues to trigger itself in a loop,
% but in different ways depending on whether the
% page is doing comet-based or polling-based
% background updates.
%
% To update the page, the function gathers actions 
% in the accumulator and wires both the actions and
% the looping event.
event(start_async) ->
    case wf_context:async_mode() of
        comet ->
            % Tell the accumulator to stay alive until
            % we call back, with some padding...
            set_lease(?COMET_INTERVAL + ?TEN_SECONDS),

            % Start the polling postback...
            Actions = get_actions_blocking(?COMET_INTERVAL),
            Event = make_async_event(0),
            wf:wire(page, page, [Actions, Event]),

            % Renew the lease, because the blocking call
            % could have used up a significant amount of time.
            set_lease(?COMET_INTERVAL + ?TEN_SECONDS);


        {poll, Interval} ->
            % Tell the accumulator to stay alive until
            % we call back, with some padding.
            set_lease(Interval + ?TEN_SECONDS),

            % Start the polling postback...
            Actions = get_actions(),
            Event = make_async_event(Interval),
            wf:wire(page, page, [Actions, Event])
    end.



%% - POOL - %%

% Retrieve a Pid from the process_registry for the specified pool.
% A pool can either be local or global. In a local pool, messages sent
% to the pool are only sent to async processes for one browser window.
% In a global pool, messages sent to the pool are sent to all processes
% in the pool across the entire system. This is useful for multi-user applications.
get_pool_pid(SeriesID, Pool, Scope) ->
    PoolID = case Scope of
        local  -> {Pool, SeriesID};
        global -> {Pool, global}
    end,
    {ok, _Pid} = process_registry_handler:get_pid({async_pool, PoolID}, fun() -> pool_loop([]) end).

% The pool loop keeps track of the AsyncFunction processes in a pool, 
% and is responsible for distributing messages to all processes in the pool.
pool_loop(Processes) -> 
    receive
        {add_process, JoinPid} ->
            erlang:monitor(process, JoinPid), 
            case Processes of
                [] -> JoinPid!'INIT';
                _  -> [Pid!{'JOIN', JoinPid} || Pid <- Processes]
            end,
            pool_loop([JoinPid|Processes]);

        {'DOWN', _, process, LeavePid, _} ->
            [Pid!{'LEAVE', LeavePid} || Pid <- Processes],
            NewProcesses = Processes -- [LeavePid],
            case NewProcesses == [] of 
                false -> pool_loop(NewProcesses);
                true  -> erlang:exit({pool_loop, exiting_empty_pool})
            end;

        Message ->
            [Pid!Message || Pid <- Processes],
            pool_loop(Processes)

    after ?TWENTY_SECONDS ->
        NewProcesses = [X || X <- Processes, is_remote_process_alive(X)],
        case NewProcesses == [] of
            true  -> erlang:exit({pool_loop, exiting_empty_pool});
            false -> pool_loop(NewProcesses)
        end
    end.



%% - ACCUMULATOR - %%

% Retrieve a Pid from the process registry for the specified Series.
get_accumulator_pid(SeriesID) ->
    {ok, _Pid} = process_registry_handler:get_pid({async_accumulator, SeriesID}, fun() -> accumulator_loop([], [], none, undefined) end).

% The accumulator_loop keeps track of guardian processes within a pool,
% and gathers actions from the various AsyncFunctions in order 
% to send it the page when the actions are requested.
accumulator_loop(Guardians, Actions, Waiting, TimerRef) ->
    receive
        {add_guardian, Pid} ->
            erlang:monitor(process, Pid),
            accumulator_loop([Pid|Guardians], Actions, Waiting, TimerRef);

        {'DOWN', _, process, Pid, _} ->
            accumulator_loop(Guardians -- [Pid], Actions, Waiting, TimerRef);

        {add_actions, NewActions} ->
            case is_remote_process_alive(Waiting) of
                true -> 
                    Waiting!{actions, [NewActions|Actions]},
                    accumulator_loop(Guardians, [], none, TimerRef);
                false ->
                    accumulator_loop(Guardians, [NewActions|Actions], none, TimerRef)
            end;

        {get_actions_blocking, Pid} when Actions == [] ->
            accumulator_loop(Guardians, [], Pid, TimerRef);

        {get_actions_blocking, Pid} when Actions /= [] ->
            Pid!{actions, lists:reverse(Actions)},
            accumulator_loop(Guardians, [], none, TimerRef);

        {get_actions, Pid} ->
            Pid!{actions, lists:reverse(Actions)},
            accumulator_loop(Guardians, [], none, TimerRef);

        {set_lease, LengthInMS} ->
            timer:cancel(TimerRef),
            {ok, NewTimerRef} = timer:send_after(LengthInMS, die),
            accumulator_loop(Guardians, Actions, Waiting, NewTimerRef);

        die -> 
            % Guardian_process will detect that we've died and update
            % the pool.
            erlang:exit({accumulator_loop, exiting_lease_expired});

        Other ->
            ?PRINT({accumulator_loop, unhandled_event, Other}),
            accumulator_loop(Guardians, Actions, Waiting, TimerRef)

    after ?TWENTY_SECONDS ->
        %% If we have no TimerRef, then the browser never performed
        %% the callback, so kill this process after 20 seconds.
        case TimerRef == undefined of
            true  -> erlang:exit({accumulator_loop, timeout});
            false -> accumulator_loop(Guardians, Actions, Waiting, TimerRef)
        end
    end.

% The guardian process monitors the running AsyncFunction and
% the running Accumulator. If either one dies, then send 
% DyingMessage to the pool, and end.
guardian_process(FunctionPid, AccumulatorPid, PoolPid, DyingMessage) ->
    erlang:monitor(process, FunctionPid),
    erlang:monitor(process, AccumulatorPid),
    erlang:monitor(process, PoolPid),   
    receive
        {'DOWN', _, process, FunctionPid, _} ->
            % The AsyncFunction process has died. 
            % Communicate dying_message to the pool and exit.
            case DyingMessage of
                undefined -> ignore;
                _ -> PoolPid!DyingMessage
            end,
            exit(async_function_died);

        {'DOWN', _, process, AccumulatorPid, _} -> 
            % The accumulator process has died. 
            % Communicate dying_message to the pool, 
            % kill the AsyncFunction process, and exit.
            case DyingMessage of
                undefined -> ignore;
                _ -> PoolPid!DyingMessage
            end,
            erlang:exit(FunctionPid, async_die),
            erlang:exit({guardian_process, exiting_accumulator_died});

        {'DOWN', _, process, PoolPid, Info} ->
            % The pool should never die on us.
            ?PRINT({unexpected_pool_death, Info}),
            erlang:exit({guardian_process, exiting_pool_died});

        Other ->
            ?PRINT({FunctionPid, AccumulatorPid, PoolPid}),
            ?PRINT({guardian_process, unhandled_event, Other}),
            guardian_process(FunctionPid, AccumulatorPid, PoolPid, DyingMessage)
    end.


%%% PRIVATE FUNCTIONS %%%

%% @doc Mode can be either atoms 'page' or 'postback'.
%% page means it's spawned from wf:comet(), meaning that the accumulator and whatnot
%% is not started until after the comet postback. So we have to run a checker to fix it
%% postbak means it's spawned from the postback event already along with the accumulator
%% and everything. So no need to check for it.
spawn_with_context({Name, Function, Msg}, Mode) ->
    Context = wf_context:context(),
    SeriesID = wf_context:series_id(),
    Key = {SeriesID, Name},
    {ok, Pid} = process_registry_handler:get_pid(Key, fun() ->
        wf_context:context(Context),
        wf_context:clear_action_queue(),
        case erlang:fun_info(Function, arity) of
        {arity, 1} -> Function(Mode);
        {arity, 0} -> Function()
        end,
        flush() 
    end),
    Pid ! {comet, Mode, Msg},
    start_accumulator_check_timer(Mode, Pid),
    Pid;
spawn_with_context({Name, Function}, Mode) ->
    Context = wf_context:context(),
    SeriesID = wf_context:series_id(),
    Key = {SeriesID, Name},
    {ok, Pid} = process_registry_handler:get_pid(Key, fun() ->
        wf_context:context(Context),
        wf_context:clear_action_queue(),
        case erlang:fun_info(Function, arity) of
        {arity, 1} -> Function(Mode);
        {arity, 0} -> Function()
        end,
        flush() 
    end),
    start_accumulator_check_timer(Mode, Pid),
    Pid;
spawn_with_context(Function,Mode) ->
    Context = wf_context:context(),
    Pid = erlang:spawn(fun() -> 
        wf_context:context(Context),
        wf_context:clear_action_queue(),
        Function(),
        flush() 
    end),
    start_accumulator_check_timer(Mode, Pid),
    Pid.

start_accumulator_check_timer(page, Pid) ->
    %% This function gets called before we've verified that the browser
    %% is even doing JS, and without JS, this will never get assigned 
    %% an accumulator.  So here's a hack to make sure that the accumulator
    %% exists after 20 seconds, and if not, it simply kills the pid
    start_accumulator_check_timer(Pid);
start_accumulator_check_timer(_, _) ->
    do_nothing.

%% If P is a pid, then it was initiated on the page
%% and that means we have to kill the checker pid that's
%% waiting to kill it for us.  Hacky, I know. Real
%% spaghetti-like. I don't particularly like it, but it
%% fixes the bug.
notify_accumulator_checker(Pid) ->
    case get_accumulator_checker_pid(Pid) of
    {ok, CheckerPid} when is_pid(CheckerPid) ->
        CheckerPid ! accumulator_started;
    _ ->
        ok
    end.

get_accumulator_checker_pid(Pid) ->
    Key = get_accumulator_checker_key(Pid),
    process_registry_handler:get_pid(Key).

get_accumulator_checker_key(Pid) ->
    _Key = {accumulator_check_timer,Pid}.

start_accumulator_check_timer(Pid) ->
    Key = get_accumulator_checker_key(Pid),
    CheckFunction = fun() ->
        receive
            accumulator_started -> ok
        after ?TWENTY_SECONDS + ?TEN_SECONDS ->
            %% The page never posted back at all (Hey, we gave it 30 seconds), and so the accumulator
            %% loop doesn't exist for this pid, and so we have nothing
            %% to check for it. So let's just kill the pid
            exit(Pid,accumulator_never_started)
        end
    end,

    {ok, _CheckPid} = process_registry_handler:get_pid(Key,CheckFunction).


inner_send(Pool, Scope, Message) ->
    % ?PRINT({Pool, Scope, Message}),
    SeriesID = wf_context:series_id(),
    {ok, PoolPid} = get_pool_pid(SeriesID, Pool, Scope),
    PoolPid!Message,
    ok.

% Get actions from accumulator. If there are no actions currently in the
% accumulator, then [] is immediately returned.
get_actions() ->
    SeriesID = wf_context:series_id(),
    {ok, AccumulatorPid} = get_accumulator_pid(SeriesID),
    AccumulatorPid!{get_actions, self()},
    receive
        {actions, X} -> X;
        Other -> ?PRINT({unhandled_event, Other}), []
    end.

% Get actions from accumulator in a blocking fashion. If there are no actions
% currently in the accumulator, then this blocks for up to Timeout milliseconds.
% This works by telling Erlang to send a dummy 'add_actions' command to the accumulator
% that will be executed when the timeout expires.
get_actions_blocking(Timeout) ->
    SeriesID = wf_context:series_id(),
    {ok, AccumulatorPid} = get_accumulator_pid(SeriesID),
    AccumulatorNode = node(AccumulatorPid),
    TimerRef = rpc:call(AccumulatorNode, erlang, send_after, [Timeout, AccumulatorPid, {add_actions, []}]),
    AccumulatorPid!{get_actions_blocking, self()},
    receive 
        {actions, X} -> erlang:cancel_timer(TimerRef), X;           
        Other -> ?PRINT({unhandled_event, Other}), []
    end.

set_lease(LengthInMS) ->
    SeriesID = wf_context:series_id(),
    {ok, AccumulatorPid} = get_accumulator_pid(SeriesID),
    AccumulatorPid!{set_lease, LengthInMS}.

% Convenience function to return an #event that will call event(start_async) above.
make_async_event(Interval) ->
    #event { type=system, delay=Interval, delegate=?MODULE, postback=start_async }.


% Return true if the process is alive, accounting for processes on other nodes. 
is_remote_process_alive(Pid) ->
    is_pid(Pid) andalso
    pong == net_adm:ping(node(Pid)) andalso
    rpc:call(node(Pid), erlang, is_process_alive, [Pid]).
