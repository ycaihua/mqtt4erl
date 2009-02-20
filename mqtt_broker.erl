-module(mqtt_broker).

-include_lib("mqtt.hrl").

-compile(export_all).

-export([start/0]).

-record(broker, {
  sub_pid,
  registry_pid
}).

-record(client_proxy, {
  broker,
  context,
  client_id,
  ping_timer,
  retry_timer,
  id_pid,
  inbox_pid,
  outbox_pid
}).

start() ->
  case gen_tcp:listen(?MQTT_PORT, [binary, {active, false}]) of
    {ok, ListenSocket} ->
      Pid = spawn(fun() ->
        gen_tcp:controlling_process(ListenSocket, self()),
        server_loop(ListenSocket)
      end),
      {ok, Pid};
    {error, Reason} ->
        exit(Reason)
  end.

server_loop(ListenSocket) ->
  Broker = #broker{
    sub_pid = spawn_link(fun() -> subscriber_loop() end),
    registry_pid = spawn_link(fun() -> registry_loop() end)
  },
  {ok, ClientSocket} = gen_tcp:accept(ListenSocket),
  _ClientPid = spawn_link(fun() ->
    process_flag(trap_exit, true),
    Context = #context{
      socket = ClientSocket,
      pid = self()
    },
    spawn_link(fun() -> mqtt_core:recv_loop(Context) end),
    clientproxy_loop(#client_proxy{
      broker = Broker,
      context = Context
    })
  end),
  server_loop(ListenSocket).

clientproxy_loop(State) ->
  NewState = receive
    #mqtt{type = ?CONNECT, arg = O} ->
      ?LOG({client_loop, connect, O}),
      if
        O#connect_options.protocol_version /= ?PROTOCOL_VERSION ->
          send(#mqtt{type = ?CONNACK, arg = 1}, State),
          exit({connect_refused, wrong_protocol_version});
        length(O#connect_options.client_id) < 1;
        length(O#connect_options.client_id) > 23 ->
          send(#mqtt{type = ?CONNACK, arg = 2}, State),
          exit({connect_refused, invalid_clientid});
        true ->
          (State#client_proxy.broker)#broker.registry_pid ! {mqtt_registry, put, O#connect_options.client_id, self()},
          send(#mqtt{type = ?CONNACK, arg = 0}, State)
      end,
      State#client_proxy{
        client_id = O#connect_options.client_id,
        ping_timer = timer:apply_interval(O#connect_options.keepalive * 1000, mqtt_core, send_ping, [State#client_proxy.context]),
        id_pid = spawn_link(fun() -> id:start() end),
        inbox_pid = spawn_link(fun() -> store:start() end),
        outbox_pid = spawn_link(fun() -> store:start() end)
      };
    #mqtt{type = ?SUBSCRIBE, arg = Subs} = Message ->
      ?LOG({client_loop, subscribe, Subs}),
      (State#client_proxy.broker)#broker.sub_pid ! {sub, add, State#client_proxy.client_id, self(), Subs},
      send(#mqtt{type = ?SUBACK, arg = {Message#mqtt.id, Subs}}, State),
      State;
    #mqtt{type = ?UNSUBSCRIBE, arg = {MessageId, Unsubs}} ->
      ?LOG({client_loop, unsubscribe, Unsubs}),
      (State#client_proxy.broker)#broker.sub_pid ! {sub, remove, State#client_proxy.client_id, Unsubs},
      send(#mqtt{type = ?UNSUBACK, arg = MessageId}, State),
      State;
    #mqtt{type = ?PUBLISH, qos = 2} = Message ->
      ok = store:put_message(Message, State#client_proxy.inbox_pid),
      State;
    #mqtt{type = ?PUBLISH} = Message ->
      ?LOG({client_loop, got, mqtt_core:pretty(Message)}),
      ok = distribute(Message, State),
      State;
    #mqtt{type = ?PUBACK, arg = MessageId} ->
      store:delete_message(MessageId, State#client_proxy.outbox_pid),
      State;
    #mqtt{type = ?PUBREL, arg = MessageId} ->
      Message = store:get_message(MessageId, State#client_proxy.inbox_pid),
      store:delete_message(MessageId, State#client_proxy.inbox_pid),
      distribute(Message, State),
      State;
    #mqtt{type = ?PUBCOMP, arg = MessageId} ->
      store:delete_message(MessageId, State#client_proxy.outbox_pid),
      State;
    {deliver, #mqtt{} = Message} ->
      ?LOG({client_loop, delivering, mqtt_core:pretty(Message)}),
      send(Message, State),
      State;
    {'EXIT', FromPid, Reason} ->
      %% send the will!
      ?LOG({client_loop, got, exit, FromPid, Reason}),
      disconnect(State),
      exit(Reason);
    Message ->
      ?LOG({client_loop, got, Message}),
      State
  end,  
  clientproxy_loop(NewState).

disconnect(State) ->
  %% remove from registry
  %% deactivate subscriptions
  timer:cancel(State#client_proxy.ping_timer).

distribute(#mqtt{} = Message, State) ->
  {Topic, _} = Message#mqtt.arg,
  lists:foreach(fun({_ClientId, ClientPid, SubscribedQoS}) ->
    AdjustedMessage = if
      Message#mqtt.qos > SubscribedQoS ->
        Message#mqtt{qos = SubscribedQoS};
      true ->
        Message
    end,
    ClientPid ! {deliver, AdjustedMessage}
  end, get_subscribers(Topic, State)),
  ok.

send(#mqtt{} = Message, State) ->
  ?LOG({broker, send, mqtt_core:pretty(Message)}),
  SendableMessage = if
    Message#mqtt.dup =:= 0, Message#mqtt.qos > 0 ->
      IdMessage = Message#mqtt{id = id:get_incr(State#client_proxy.id_pid)},
      ok = store:put_message(IdMessage, State#client_proxy.outbox_pid),
      IdMessage;
    true ->
      Message
  end,
  mqtt_core:send(SendableMessage, State#client_proxy.context).

subscriber_loop() ->
  subscriber_loop(dict:new()).
subscriber_loop(State) ->
  NewState = receive
    {sub, add, ClientId, ClientPid, Subs} ->
      ?LOG({subscribers, add, ClientId, ClientPid, Subs}),
      lists:foldl(fun(#sub{topic = Topic, qos = QoS}, InterimState) ->
        case dict:find(Topic, InterimState) of
          {ok, Subscribers} ->
            dict:store(Topic, [{ClientId, ClientPid, QoS}|lists:keydelete(ClientId, 1, Subscribers)], InterimState);
          error ->
            dict:store(Topic, [{ClientId, ClientPid, QoS}], InterimState)
        end
      end, State, Subs);
    {sub, remove, ClientId, all} ->
      ?LOG({subscribers, remove, ClientId, all}),
      lists:foldl(fun(Topic, InterimState) ->
        Subscribers = dict:fetch(Topic, InterimState),
        dict:store(Topic, lists:keydelete(ClientId, 1, Subscribers), InterimState)
      end, State, dict:fetch_keys(State));
    {sub, remove, ClientId, Unubs} ->
      ?LOG({subscribers, remove, ClientId, Unubs}),
      lists:foldl(fun(#sub{topic = Topic}, InterimState) ->
        case dict:find(Topic, InterimState) of
          {ok, Subscribers} ->
            dict:store(Topic, lists:keydelete(ClientId, 1, Subscribers), InterimState);
          error ->
            InterimState
        end
      end, State, Unubs);
    {sub, get, Topic, FromPid} ->
      case dict:find(Topic, State) of
        {ok, Subscribers} ->
          FromPid ! {sub, ok, Subscribers};
        error ->
          FromPid ! {sub, ok, []}
      end,
      State;
    Message ->
      ?LOG({subscribers, got, Message}),
      State
  end,
  ?LOG({newstate, dict:to_list(NewState)}),
  subscriber_loop(NewState).

get_subscribers(Topic, State) ->
  (State#client_proxy.broker)#broker.sub_pid ! {sub, get, Topic, self()},
  receive 
    {sub, ok, Subscribers} ->
      ?LOG({get_subscribers, got, Subscribers}),
      Subscribers;
    Message ->
      ?LOG({get_subscribers, got, Message})
  end.

registry_loop() ->
  registry_loop(dict:new()).
registry_loop(State) ->
  NewState = receive
    {mqtt_registry, put, ClientId, Pid} ->
      ?LOG({mqtt_registry, put, ClientId, Pid}),
      case dict:find(ClientId, State) of
        {ok, OldPid} ->
          ?LOG({mqtt_registry, killing_old, OldPid}),
          exit(OldPid, client_id_represented);
        error ->
          ignore
      end,
      dict:store(ClientId, Pid, State);
    Message ->
      ?LOG({mqtt_registry, unexpected_message, Message}),
      State
  end,
  registry_loop(NewState).
