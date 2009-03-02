-module(mqtt_registry).
-behaviour(gen_server).
 
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).
 
-export([start_link/0, get_subscribers/1, subscribe/2, unsubscribe/2, register_client/2, unregister_client/1, retain/1]).

-include_lib("mqtt.hrl").
 
-record(mqtt_registry, {
  registry = dict:new(),
  subscriptions = dict:new(),
  retainedMessages = dict:new()
}).

start_link() -> gen_server:start_link({global, ?MODULE}, ?MODULE, [], []).

init([]) ->
  {ok, #mqtt_registry{}}.

handle_call({register, ClientId, Pid}, _From, State) ->
  ?LOG({mqtt_registry, register, ClientId, Pid}),
  case dict:find(ClientId, State#mqtt_registry.registry) of
    {ok, OldPid} ->
      ?LOG({killing_previous_client, OldPid}),
      exit(OldPid, client_id_represented);
    error ->
      ignore
  end,
  {reply, ok, State#mqtt_registry{registry = dict:store(ClientId, Pid, State#mqtt_registry.registry)}};
handle_call({unregister, ClientId}, _From, State) ->
  ?LOG({unregister, ClientId}),
  {reply, ok, State#mqtt_registry{
        registry = dict:erase(ClientId, State#mqtt_registry.registry)
  }};
handle_call({subscribe, ClientId, Subs}, _From, State) ->
  ?LOG({subscribe, ClientId, Subs}),
  NewSubscriptions = lists:foldl(fun(#sub{topic = Topic, qos = QoS}, InterimState) ->
    gen_server:cast(self(), {deliver_retained, Topic}),
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
      {reply, lookup_subscribers(Topic, State), State};
handle_call({retain, #mqtt{arg = {Topic, _}} = Message}, _From, State) ->
  ?LOG({retaining, mqtt_core:pretty(Message), for, Topic}),
  {reply, ok, State#mqtt_registry{retainedMessages = dict:append(Topic, Message, State#mqtt_registry.retainedMessages)}};
handle_call(Message, _From, State) ->
  ?LOG({unexpected_message, Message}),
  {reply, ok, State}.



handle_cast({deliver_retained, Topic}, State) ->
  ?LOG({deliver_retained, Topic}),
  case dict:find(Topic, State#mqtt_registry.retainedMessages) of
    {ok, RetainedMessages} ->
      Subscribers = lookup_subscribers(Topic, State),
      ?LOG({delivering, RetainedMessages, to, Subscribers}),
      lists:foreach(fun(M) ->
        mqtt_broker:distribute(M, Subscribers)
      end, RetainedMessages);
    error ->
      noop
  end,
  {noreply, State};
handle_cast(_Msg, State) -> {noreply, State}.
handle_info(_Msg, State) -> {noreply, State}.
terminate(_Reason, _State) -> ok.
code_change(_OldVersion, State, _Extra) -> {ok, State}.

lookup_subscribers(Topic, State) ->
  case dict:find(Topic, State#mqtt_registry.subscriptions) of
    {ok, Subscribers} ->
      lists:map(fun({ClientId, QoS}) ->
        case dict:find(ClientId, State#mqtt_registry.registry) of
          {ok, Pid} ->
            {ClientId, Pid, QoS};
          error ->
            {ClientId, not_connected, QoS}
        end
      end, Subscribers);
    error ->
      []
  end.

subscribe(ClientId, Subs) ->
  gen_server:call({global, ?MODULE}, {subscribe, ClientId, Subs}).

unsubscribe(ClientId, Unsubs) ->
  gen_server:call({global, ?MODULE}, {unsubscribe, ClientId, Unsubs}).

get_subscribers(Topic) ->
  gen_server:call({global, ?MODULE}, {get_subscribers, Topic}).

register_client(ClientId, Pid) ->
  gen_server:call({global, ?MODULE}, {register, ClientId, Pid}).

unregister_client(ClientId) ->
  gen_server:call({global, ?MODULE}, {unregister, ClientId}).

retain(Message) ->
  gen_server:call({global, ?MODULE}, {retain, Message}).
