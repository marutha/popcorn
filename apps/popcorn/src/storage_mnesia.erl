%%%
%%% Copyright 2012
%%%
%%% Licensed under the Apache License, Version 2.0 (the "License");
%%% you may not use this file except in compliance with the License.
%%% You may obtain a copy of the License at
%%%
%%%     http://www.apache.org/licenses/LICENSE-2.0
%%%
%%% Unless required by applicable law or agreed to in writing, software
%%% distributed under the License is distributed on an "AS IS" BASIS,
%%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%%% See the License for the specific language governing permissions and
%%% limitations under the License.
%%%


%%%-------------------------------------------------------------------
%%% File:      storage_mnesia.erl
%%% @author    Marc Campbell <marc.e.campbell@gmail.com>
%%% @doc
%%% @end
%%%-----------------------------------------------------------------

-module(storage_mnesia).
-author('marc.e.campbell@gmail.com').
-behavior(gen_server).

-include("include/popcorn.hrl").
-include_lib("stdlib/include/qlc.hrl").
-include_lib("stdlib/include/ms_transform.hrl").

-export([start_link/0,
         pre_init/0]).

-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

start_link() -> gen_server:start_link(?MODULE, [], []).
pre_init() ->
    stopped = mnesia:stop(),
    case mnesia:create_schema([node()]) of
      ok -> io:format(" initializing schema...");
      {error, {_Node, {already_exists,_Node}}} -> io:format(" recovering schema...")
    end,
    ok = mnesia:start(),

    io:format("Ensuring required mnesia tables exist..."),
    io:format("\n\t[popcorn_history: ~p]",
       [mnesia:create_table(known_nodes,  [{disc_copies, [node()]},
                                           {record_name, popcorn_node},
                                           {attributes,  record_info(fields, popcorn_node)}])]),
    io:format("\n\t[popcorn_history: ~p]",
       [mnesia:create_table(popcorn_history, [{disc_copies, [node()]},
                                              {record_name, log_message},
                                              {type,        ordered_set},
                                              {index,       [#log_message.severity,
                                                             #log_message.log_product,
                                                             #log_message.log_version,
                                                             #log_message.log_module,
                                                             #log_message.log_line,
                                                             #log_message.timestamp]},
                                              {attributes,  record_info(fields, log_message)}])]),

    io:format("\n\t[alert_key: ~p]",
        [mnesia:create_table(popcorn_alert_keyset, [{disc_copies, [node()]},
                                           {record_name, alert_key},
                                           {type,        bag},
                                           {attributes,  record_info(fields, alert_key)}])]),
    io:format("\n\t[alert_counter: ~p]",
        [mnesia:create_table(popcorn_alert_keyset, [{disc_copies, [node()]},
                                           {record_name, alert_counter},
                                           {type,        set},
                                           {attributes,  record_info(fields, alert_counter)}])]),
    io:format("\n\t[alert: ~p]",
        [mnesia:create_table(popcorn_alert, [{disc_copies, [node()]},
                                           {record_name, alert},
                                           {type,        ordered_set},
                                           {index,       [#alert.timestamp]},
                                           {attributes,  record_info(fields, alert)}])]),

    io:format("\n\t[popcorn_scm: ~p]",
        [mnesia:create_table(popcorn_release_scm, [{disc_copies, [node()]},
                                           {record_name, release_scm},
                                           {type,        ordered_set},
                                           {index,       [#release_scm.role,
                                                          #release_scm.version]},
                                           {attributes,  record_info(fields, release_scm)}])]),

    io:format("\n\t[popcorn_scm_mapping: ~p]",
        [mnesia:create_table(popcorn_release_scm_mapping, [{disc_copies, [node()]},
                                           {record_name, release_scm_mapping},
                                           {type,        ordered_set},
                                           {index,       [#release_scm_mapping.role,
                                                          #release_scm_mapping.version]},
                                           {attributes,  record_info(fields, release_scm_mapping)}])]),

    io:format("\n\t[popcorn_counters: ~p]",
       [mnesia:create_table(popcorn_counters, [{disc_copies, [node()]}])]),
    io:format("\n... done!\n").

init([]) ->
    process_flag(trap_exit, true),

    pg2:join('storage', self()),
    {ok, undefined}.   %% we don't have state here, because this is only one worker process

handle_call(start_phase, _From, State) ->
    io:format("Reloading previously known nodes...\n"),
    lists:foreach(fun(Known_Node) ->
        io:format("Node: ~s\n", [binary_to_list(Known_Node)]),
        Popcorn_Node = lists:nth(1, mnesia:dirty_read(known_nodes, Known_Node)),
        {ok, Pid} = supervisor:start_child(node_sup, []),
        ok = gen_fsm:sync_send_event(Pid, {deserialize_popcorn_node, Popcorn_Node}),
        ets:insert(current_nodes, {Popcorn_Node#popcorn_node.node_name, Pid})
      end, mnesia:dirty_all_keys(known_nodes)),
    io:format(" done!\n"),

    io:format("Ensuring counters have a default value...\n"),
      io:format("\n\t[TOTAL_EVENT_COUNTER: ~p]",
        [mnesia:dirty_update_counter(popcorn_counters, ?TOTAL_EVENT_COUNTER, 0)]),
      io:format("\n\t[TOTAL_ALERT_COUNTER: ~p]",
        [mnesia:dirty_update_counter(popcorn_counters, ?TOTAL_ALERT_COUNTER, 0)]),
    io:format("\n done!\n"),

    Severity_Counters =
      lists:map(fun({_, Severity}) ->
          F = fun() -> mnesia:select(popcorn_history, ets:fun2ms(fun(#log_message{severity = LS}) when LS == Severity -> true end)) end,
          {atomic, Matches} = mnesia:transaction(F),
          {Severity, length(Matches)}
        end, popcorn_util:all_severities()),
    system_counters:set_severity_counters(Severity_Counters),

    {reply, ok, State};

handle_call({counter_value, Counter}, _From, State) ->
    Counter_Value =
      case mnesia:dirty_read(popcorn_counters, Counter) of
          [{popcorn_counters, _, V}] -> V;
          _ -> 0
      end,

    {reply, Counter_Value, State};

handle_call({is_known_node, Node_Name}, _From, State) ->
    ?RPS_INCREMENT(storage_total),
    {reply,
     mnesia:dirty_read(known_nodes, Node_Name) =/= [],
     State};

%% @doc returns all alerts for a given {role, version, module, line} tuple
handle_call({get_alert, Key}, _From, State) ->
    ?RPS_INCREMENT(storage_total),
    F = fun() ->
          mnesia:select(popcorn_alert, ets:fun2ms(fun(Alert = #alert{location=K}) when K == Key -> Alert end))
        end,
    case mnesia:transaction(F) of
        {atomic, [Alert]} -> {reply, Alert, State};
        {atomic, []} -> {reply, undefined, State}
    end;

handle_call({get_alerts, Severities}, _From, State) ->
    Transaction = fun() ->
        Query =
          case Severities of
            all -> qlc:q([Alert || Alert = #alert{} <- mnesia:table(popcorn_alert)]);
            Severities -> qlc:q([Alert || Alert = #alert{log = #log_message{severity = Severity}} <- mnesia:table(popcorn_alert), lists:member(Severity, Severities)])
          end,
        Order =
            fun(A, B) ->
                B#alert.incident > A#alert.incident
            end,
        qlc:eval(qlc:sort(Query, [{order, Order}]))
    end,
    {atomic, Alerts} = mnesia:transaction(Transaction),
    {reply, Alerts, State};

%% @doc returns all alerts for a given {severity, role, version, module, line} tuple
handle_call({get_alert_keys, Type}, _From, State) ->
    ?RPS_INCREMENT(storage_total),
    F = fun() ->
          mnesia:select(popcorn_alert_keyset, ets:fun2ms(fun(#alert_key{type=T, key=Key}) when T == Type -> Key end))
        end,
    {atomic, Db_Reply} = mnesia:transaction(F),
    {reply, Db_Reply, State};

%% @doc returns the URL as a binary if the mapping exists, or undefined
handle_call({get_release_module_link, Role, Version, Module}, _From, State) ->
    ?RPS_INCREMENT(storage_total),
    F = fun() ->
        Link = #release_scm_mapping{key=iolist_to_binary([Role, $:, Version, $:, Module]), url='$1', _='_'},
        mnesia:select(popcorn_release_scm_mapping, [{Link, [], ['$1']}])
    end,
    {atomic, Db_Reply} = mnesia:transaction(F),
    {reply, case Db_Reply of 
                [] -> undefined;
                [URL] -> URL
            end, State};

handle_call({search_messages, {S, P, V, M, L, Page_Size, Starting_Timestamp}}, _From, State) ->
    %% TODO: make better use of the cursor object to avoid repeated queries
    Transaction = fun() ->
        Query = qlc:q([Log_Message || Log_Message = #log_message{timestamp = TS, log_product = LP, log_version = LV, 
                                                     severity = LS, log_module = LM, log_line = LL}
                                <- mnesia:table(popcorn_history), LP == P, LV == V, LS == S, LM == M, LL == L, (Starting_Timestamp == undefined orelse TS < Starting_Timestamp)]),
        Order =
            fun(A, B) ->
                B#log_message.timestamp < A#log_message.timestamp
            end,
        Cursor = qlc:cursor(qlc:sort(Query, [{order, Order}])),
        qlc:next_answers(Cursor, Page_Size)
    end,
    {atomic, Messages} = mnesia:transaction(Transaction),
    {reply, Messages, State};

handle_call(Request, _From, State)  -> {stop, {unknown_call, Request}, State}.

handle_cast({expire_logs_matching, Params}, State) ->
    Deleted_Counts = delete_recent_log_line(Params, undefined, []),
    history_optimizer:expire_logs_complete(),

    Updated_Severity_Counters =
      lists:map(fun({Severity, Count}) ->
          case proplists:get_value(Severity, Deleted_Counts) of
              undefined  -> {Severity, Count};
              Last_Value -> {Severity, Last_Value - Count}
          end
        end, system_counters:get_severity_counters()),

    system_counters:set_severity_counters(Updated_Severity_Counters),
    {noreply, State};

handle_cast({send_recent_matching_log_lines, Pid, Count, Filters}, State) ->
    send_recent_log_line(Pid, Count, undefined, Filters),
    {noreply, State};

handle_cast({new_log_message, Log_Message}, State) ->
    ?RPS_INCREMENT(storage_log_write),
    ?RPS_INCREMENT(storage_total),
    mnesia:dirty_write(popcorn_history, Log_Message),

    system_counters:increment_severity_counter(Log_Message#log_message.severity),
    {noreply, State};

handle_cast({new_release_scm, Record}, State) ->
    ?RPS_INCREMENT(storage_scm_write),
    ?RPS_INCREMENT(storage_total),
    mnesia:dirty_write(popcorn_release_scm, Record),
    {noreply, State};

handle_cast({new_alert, Key, #alert{} = Record}, State) ->
    ?RPS_INCREMENT(storage_total),
    mnesia:dirty_write(popcorn_alert, Record#alert{location=Key}),
    {noreply, State};

handle_cast({new_alert_key, Type, Key}, State) ->
    ?RPS_INCREMENT(storage_total),
    mnesia:dirty_write(popcorn_alert_keyset, #alert_key{type=Type, key=Key}),
    {noreply, State};

handle_cast({new_release_scm_mapping, Record}, State) ->
    ?RPS_INCREMENT(storage_scm_write),
    ?RPS_INCREMENT(storage_total),
    mnesia:dirty_write(popcorn_release_scm_mapping, Record),
    {noreply, State};

handle_cast({delete_counter, Counter}, State) ->
    ?RPS_INCREMENT(storage_total),
    mnesia:dirty_delete(popcorn_counters, Counter),
    {noreply, State};

handle_cast({increment_counter, Counter, Increment_By}, State) ->
    ?RPS_INCREMENT(storage_counter_write),
    ?RPS_INCREMENT(storage_total),
    mnesia:dirty_update_counter(popcorn_counters, Counter, Increment_By),
    {noreply, State};

handle_cast({add_node, Popcorn_Node}, State) ->
    ?RPS_INCREMENT(storage_total),
    mnesia:dirty_write(known_nodes, Popcorn_Node),
    {noreply, State};

handle_cast(_Msg, State)            -> {noreply, State}.
handle_info(_Msg, State)            -> {noreply, State}.
terminate(_Reason, _State)          -> ok.
code_change(_OldVsn, State, _Extra) -> {ok, State}.

%% private, internal functions
send_recent_log_line(_, 0, _, _) -> ok;
send_recent_log_line(_, _, '$end_of_table', _) -> ok;
send_recent_log_line(Pid, Count, Last_Key_Checked, Filters) ->
    Key = case Last_Key_Checked of
              undefined -> ?RPS_INCREMENT(storage_total),
                           ?RPS_INCREMENT(storage_index_read),
                           mnesia:dirty_last(popcorn_history);
              _         -> ?RPS_INCREMENT(storage_total),
                           ?RPS_INCREMENT(storage_index_read),
                           mnesia:dirty_prev(popcorn_history, Last_Key_Checked)
          end,

    case Key of
        '$end_of_table' -> ok;
        _               -> ?RPS_INCREMENT(storage_log_read),
                           ?RPS_INCREMENT(stoage_total),
                           Log_Message = lists:nth(1, mnesia:dirty_read(popcorn_history, Key)),
                           case is_filtered_out(Log_Message, Filters) of
                               false -> gen_fsm:send_all_state_event(Pid, {new_message, older, Log_Message}),
                                        send_recent_log_line(Pid, Count - 1, Key, Filters);
                               true  -> send_recent_log_line(Pid, Count, Key, Filters)
                           end
    end.

delete_recent_log_line(_, '$end_of_table', Deleted_By_Severity) -> Deleted_By_Severity;
delete_recent_log_line([], _, Deleted_By_Severity) -> Deleted_By_Severity;
delete_recent_log_line(Params, Last_Key_Checked, Deleted_By_Severity) ->
    %%?POPCORN_DEBUG_MSG("#checking key for #retention_deletion ~p with #params ~p", [Last_Key_Checked, Params]),
    %% get the key to check, if this is the first iteration, then start that the oldest record
    Key = case Last_Key_Checked of
              undefined -> ?RPS_INCREMENT(storage_total),
                           ?RPS_INCREMENT(storage_index_read),
                           mnesia:dirty_first(popcorn_history);
              _         -> ?RPS_INCREMENT(storage_total),
                           ?RPS_INCREMENT(storage_index_read),
                           mnesia:dirty_next(popcorn_history, Last_Key_Checked)
          end,

    case Key of
        '$end_of_table' -> Deleted_By_Severity;
        _               -> ?RPS_INCREMENT(storage_total),
                           ?RPS_INCREMENT(storage_log_read),
                           Log_Message = lists:nth(1, mnesia:dirty_read(popcorn_history, Key)),

                           %% are we still looking for messages for this severity?
                           Severity_Params = proplists:lookup(Log_Message#log_message.severity, Params),
                           case Severity_Params of
                               none ->
                                  %% not checking this severity, continue to the next key
                                  delete_recent_log_line(Params, Key, Deleted_By_Severity);
                               {_, Oldest_TS} when Oldest_TS > Log_Message#log_message.timestamp ->
                                  %% we need to delete this message, since it's older than the min timestamp
                                  ?RPS_INCREMENT(storage_total),
                                  mnesia:dirty_delete(popcorn_history, Log_Message#log_message.message_id),
                                  case ets:lookup(current_nodes, Log_Message#log_message.log_nodename) of
                                      Node_Pids when length(Node_Pids) =:= 1 ->
                                          {_, Node_Pid} = lists:nth(1, Node_Pids),
                                          gen_fsm:send_all_state_event(Node_Pid, decrement_counter);
                                      _ ->
                                         ok
                                  end,
                                  system_counters:decrement(total_event_counter, 1),
                                  Last_Deleted_Count = proplists:get_value(Log_Message#log_message.severity, Deleted_By_Severity, 0),
                                  Now_Deleted = proplists:delete(Log_Message#log_message.severity, Deleted_By_Severity) ++
                                                [{Log_Message#log_message.severity, Last_Deleted_Count + 1}],
                                  delete_recent_log_line(Params, Key, Now_Deleted);
                              {S, T} ->
                                  %% stop checking for this severity now
                                  New_Params = lists:delete({S, T}, Params),
                                  delete_recent_log_line(New_Params, Key, Deleted_By_Severity)
                           end
    end.

%%
%% TODO this is duplicated from log_stream_fsm for now
%% we need to expose this so that other storage backend developers aren't required to implement
is_filtered_out(Log_Message, Filters) ->
    Severity_Restricted = not lists:member(Log_Message#log_message.severity, proplists:get_value('severities', Filters, [])),
    Time_Restricted = case proplists:get_value('max_timestamp', Filters) of
                          undefined       -> false;
                          Max_Timestamp   -> Log_Message#log_message.timestamp > Max_Timestamp
                      end,

    Severity_Restricted orelse Time_Restricted.
