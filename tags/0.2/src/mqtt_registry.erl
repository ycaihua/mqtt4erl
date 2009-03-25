-module(mqtt_registry).
-behaviour(gen_server).
 
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).
 
-export([start_link/0, get_subscribers/1, subscribe/2, unsubscribe/2, register_client/2, lookup_pid/1, retain/1, subscriptions/0, connected_clients/0]).

-include_lib("mqtt.hrl").
 
-record(mqtt_registry, {
  table
}).

-define(TABLE, registry.dets).

start_link() -> gen_server:start_link({global, ?MODULE}, ?MODULE, [], []).

init([]) ->
  process_flag(trap_exit, true),
  ?LOG(start),
  ?LOG({dets, opening, ?TABLE}),
  {ok, Table} = dets:open_file(?TABLE, [{type, set}]),
  {ok, #mqtt_registry{table = Table}}.

handle_call({subscribe, ClientId, Subs}, _From, State) ->
  ?LOG({subscribe, ClientId, Subs}),
  lists:foreach(fun(#sub{topic = Topic, qos = QoS}) ->
    ok = dets:insert(State#mqtt_registry.table, {{Topic, ClientId}, {ClientId, QoS}}),
    gen_server:cast(self(), {deliver_retained, Topic, {ClientId, QoS}})
  end, Subs),
  {reply, ok, State};
handle_call({unsubscribe, ClientId, all}, _From, State) ->
  ?LOG({unsubscribe, ClientId, all}),
  dets:match_delete(State#mqtt_registry.table, {{'_', ClientId}, '_'}),
  {reply, ok, State};
handle_call({unsubscribe, ClientId, Unubs}, _From, State) ->
  ?LOG({unsubscribe, ClientId, Unubs}),
  lists:foreach(fun(#sub{topic = Topic}) ->
    ok = dets:delete(State#mqtt_registry.table, {Topic, ClientId})
  end, Unubs),
  {reply, ok, State};
handle_call({get_subscribers, Topic}, _From, State) ->
  Subscribers = [Result || [Result] <- dets:match(State#mqtt_registry.table, {{Topic, '_'}, '$1'})],
  {reply, Subscribers, State};
handle_call({retain, #mqtt{arg = {Topic, _}} = Message}, _From, State) ->
  ?LOG({retaining, mqtt_core:pretty(Message), for, Topic}),
  ok = dets:insert(State#mqtt_registry.table, {{retained, Topic}, Message}),
  {reply, ok, State};
handle_call(subscriptions, _FromPid, State) ->
  Subscriptions = dets:foldl(fun({{Topic, ClientId}, {ClientId, QoS}}, Accum) ->
    dict:append(Topic, {ClientId, QoS}, Accum)
  end, dict:new(), State#mqtt_registry.table), 
  {reply, dict:to_list(Subscriptions), State};
handle_call(Message, _From, State) ->
  ?LOG({unexpected_message, Message}),
  {reply, ok, State}.

handle_cast({deliver_retained, Topic, Session}, State) ->
  case retained_message(Topic, State) of
    Message when is_record(Message, mqtt) ->
      mqtt_broker:route(Message, Session);
    _ ->
      noop
  end,
  {noreply, State};  
handle_cast(_Msg, State) -> {noreply, State}.

terminate(_Reason, State) ->
  ?LOG({dets, closing, ?TABLE}),
  dets:close(State#mqtt_registry.table),
  ok.

handle_info(_Msg, State) -> {noreply, State}.
code_change(_OldVersion, State, _Extra) -> {ok, State}.

retained_message(Topic, State) ->
  case dets:lookup(State#mqtt_registry.table, {retained, Topic}) of
    [{_Key, #mqtt{} = Message}] ->
      Message;
    _ ->
      none
  end.

subscribe(ClientId, Subs) ->
  gen_server:call({global, ?MODULE}, {subscribe, ClientId, Subs}).

unsubscribe(ClientId, Unsubs) ->
  gen_server:call({global, ?MODULE}, {unsubscribe, ClientId, Unsubs}).

get_subscribers(Topic) ->
  gen_server:call({global, ?MODULE}, {get_subscribers, Topic}).

register_client(ClientId, Pid) ->
  Handle = handle(ClientId),
  case global:register_name(Handle, Pid) of
    yes ->
      ?LOG({register, ClientId, at, Pid}),
      ok;
    no ->
      OldPid = global:whereis_name(Handle), 
      ?LOG({register, found, ClientId, at, OldPid, killing}),
      exit(OldPid, client_id_represented),
      global:register_name(Handle, Pid)
  end.

connected_clients() ->
  connected_clients(global:registered_names(), []).
connected_clients([], Accum) ->
  Accum;
connected_clients([{mqtt_client, ClientId}|T], Accum) ->
  connected_clients(T, [ClientId|Accum]);
connected_clients([_H|T], Accum) ->
  connected_clients(T, Accum).

lookup_pid(ClientId) ->
  global:whereis_name(handle(ClientId)).

subscriptions() ->
  gen_server:call({global, ?MODULE}, subscriptions).

retain(Message) ->
  gen_server:call({global, ?MODULE}, {retain, Message}).

handle(ClientId) ->
  {mqtt_client, ClientId}.
