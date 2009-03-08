-module(mqtt_registry).
-behaviour(gen_server).
 
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).
 
-export([start_link/0, get_subscribers/1, subscribe/2, unsubscribe/2, register_client/2, unregister_client/1, lookup_pid/1, retain/1]).

-include_lib("mqtt.hrl").
 
-record(mqtt_registry, {
  subscriptions = dict:new(),
  retainedMessages = dict:new()
}).

start_link() -> gen_server:start_link({global, ?MODULE}, ?MODULE, [], []).

init([]) ->
  ?LOG(start),
  {ok, #mqtt_registry{}}.

handle_call({subscribe, ClientId, Subs}, _From, State) ->
  ?LOG({subscribe, ClientId, Subs}),
  NewSubscriptions = lists:foldl(fun(#sub{topic = Topic, qos = QoS}, InterimState) ->
    gen_server:cast(self(), {deliver_retained, Topic, ClientId}),
    case dict:find(Topic, InterimState) of
      {ok, Subscribers} ->
        dict:store(Topic, [{ClientId, QoS}|lists:keydelete(ClientId, 1, Subscribers)], InterimState);
      error ->
        dict:store(Topic, [{ClientId, QoS}], InterimState)
    end
  end, State#mqtt_registry.subscriptions, Subs),
  {reply, ok, State#mqtt_registry{subscriptions = NewSubscriptions}};
handle_call({unsubscribe, ClientId, Unubs}, _From, State) ->
      ?LOG({unsubscribe, ClientId, Unubs}),
      NewSubscriptions = lists:foldl(fun(#sub{topic = Topic}, InterimState) ->
        case dict:find(Topic, InterimState) of
          {ok, Subscribers} ->
            dict:store(Topic, lists:keydelete(ClientId, 1, Subscribers), InterimState);
          error ->
            InterimState
        end
      end, State#mqtt_registry.subscriptions, Unubs),
      {reply, ok, State#mqtt_registry{subscriptions = NewSubscriptions}};
handle_call({get_subscribers, Topic}, _From, State) ->
      Subscribers = case dict:find(Topic, State#mqtt_registry.subscriptions) of
        {ok, S} ->
          S;
        error ->
          []
      end,
      {reply, Subscribers, State};
handle_call({retain, #mqtt{arg = {Topic, _}} = Message}, _From, State) ->
  ?LOG({retaining, mqtt_core:pretty(Message), for, Topic}),
  {reply, ok, State#mqtt_registry{retainedMessages = dict:store(Topic, Message, State#mqtt_registry.retainedMessages)}};
handle_call(Message, _From, State) ->
  ?LOG({unexpected_message, Message}),
  {reply, ok, State}.

handle_cast({deliver_retained, Topic, ClientId}, State) ->
  ?LOG({deliver_retained, Topic, to, ClientId}),
  case dict:find(Topic, State#mqtt_registry.retainedMessages) of
    {ok, RetainedMessage} ->
      Client = case dict:find(Topic , State#mqtt_registry.subscriptions) of
        {ok, Subscribers} ->
          lists:keysearch(ClientId, 1, Subscribers);
        error ->
          exit({deliver_retained, topic, Topic, not_subscriber, ClientId})
      end,
      mqtt_broker:route(RetainedMessage, Client);
    error ->
      noop
  end,
  {noreply, State};
handle_cast(_Msg, State) -> {noreply, State}.

handle_info(_Msg, State) -> {noreply, State}.
terminate(_Reason, _State) -> ok.
code_change(_OldVersion, State, _Extra) -> {ok, State}.

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
      ok;
    no ->
      case global:whereis_name(Handle) of
        undefined ->
          exit({lookup, failed, Handle});
        OldPid ->
          exit(OldPid, client_id_represented),
          global:reregister_name(ClientId, Pid),
          ok
      end
  end.

unregister_client(ClientId) ->
  global:unregister_name(handle(ClientId)).

lookup_pid(ClientId) ->
  global:whereis_name(handle(ClientId)).

retain(Message) ->
  gen_server:call({global, ?MODULE}, {retain, Message}).

handle(ClientId) ->
  {mqtt_client, ClientId}.
