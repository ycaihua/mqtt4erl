-module(mqtt_broker).

%% TODO
%% - send retained messages on subscribe
%% - clean up topics with no subscribers
%% - support clean starts

-include_lib("mqtt.hrl").

-compile(export_all).

-export([start/0]).

-record(broker, {
  socket
}).

-record(client_proxy, {
  broker,
  context,
  client_id,
  ping_timer,
  retry_timer,
  id_pid,
  inbox_pid,
  outbox_pid,
  will
}).

start() ->
  case gen_tcp:listen(?MQTT_PORT, [binary, {active, false}, {packet, raw}, {nodelay, true}]) of
    {ok, ListenSocket} ->
      Pid = spawn(fun() ->
        gen_tcp:controlling_process(ListenSocket, self()),
        Broker = #broker{
          socket = ListenSocket
        },
        server_loop(Broker)
      end),
      {ok, Pid};
    {error, Reason} ->
        exit(Reason)
  end.

server_loop(State) ->
  {ok, ClientSocket} = gen_tcp:accept(State#broker.socket),
  _ClientPid = spawn(fun() ->
    process_flag(trap_exit, true),
    inet:setopts(ClientSocket, [{nodelay,true}]),
    Context = #context{
      socket = ClientSocket,
      pid = self()
    },
    spawn_link(fun() -> mqtt_core:recv_loop(Context) end),
    clientproxy_loop(#client_proxy{
      broker = State,
      context = Context
    })
  end),
  server_loop(State).

clientproxy_loop(State) ->
  NewState = receive
    #mqtt{type = ?CONNECT, arg = O} ->
      ?LOG({client_loop, connect, O}),
      ok = mqtt_registry:register_client(O#connect_options.client_id, self()),
      send(#mqtt{type = ?CONNACK, arg = 0}, State),
      State#client_proxy{
        client_id = O#connect_options.client_id,
        ping_timer = timer:apply_interval(O#connect_options.keepalive * 1000, mqtt_core, send_ping, [State#client_proxy.context]),
        id_pid = spawn_link(fun() -> id:start() end),
        inbox_pid = spawn_link(fun() -> store:start() end),
        outbox_pid = spawn_link(fun() -> store:start() end),
        will = O#connect_options.will
      };
    #mqtt{type = ?SUBSCRIBE, arg = Subs} ->
      ?LOG({client_loop, subscribe, Subs}),
      ok = mqtt_registry:subscribe(State#client_proxy.client_id, Subs),
      State;
    #mqtt{type = ?UNSUBSCRIBE, arg = {_, Unsubs}} ->
      ?LOG({client_loop, unsubscribe, Unsubs}),
      ok = mqtt_registry:unsubscribe(State#client_proxy.client_id, Unsubs),
      State;
    #mqtt{type = ?PUBLISH, retain = 1} = Message ->
      mqtt_registry:retain(Message),
      ok;
    #mqtt{type = ?PUBLISH, qos = 2} = Message ->
      ok = store:put_message(Message, State#client_proxy.inbox_pid),
      State;
    #mqtt{type = ?PUBLISH} = Message ->
      ?LOG({client_loop, got, mqtt_core:pretty(Message)}),
      ok = distribute(Message),
      State;
    #mqtt{type = ?PUBACK, arg = MessageId} ->
      store:delete_message(MessageId, State#client_proxy.outbox_pid),
      State;
    #mqtt{type = ?PUBREL, arg = MessageId} ->
      Message = store:get_message(MessageId, State#client_proxy.inbox_pid),
      store:delete_message(MessageId, State#client_proxy.inbox_pid),
      distribute(Message),
      State;
    #mqtt{type = ?PUBCOMP, arg = MessageId} ->
      store:delete_message(MessageId, State#client_proxy.outbox_pid),
      State;
    {deliver, #mqtt{} = Message} ->
      ?LOG({client_loop, delivering, mqtt_core:pretty(Message)}),
      send(Message, State),
      State;
    {'EXIT', FromPid, Reason} ->
      ?LOG({exti, Reason, from, FromPid}),
      timer:cancel(State#client_proxy.ping_timer),
      send_will(State),
      mqtt_registry:unregister_client(State#client_proxy.client_id, store:get_all_messages(State#client_proxy.outbox_pid)), 
      exit(Reason);
    Message ->
      ?LOG({client_loop, got, Message}),
      State
  end,  
  clientproxy_loop(NewState).

send_will(#client_proxy{will = W}) when is_record(W, will) ->
  ?LOG({send_will, W}),
  ok = distribute(#mqtt{type = ?PUBLISH, qos = (W#will.publish_options)#publish_options.qos, retain = (W#will.publish_options)#publish_options.retain, arg = {W#will.topic, W#will.message}});
send_will(_State) ->
  noop.

distribute(#mqtt{arg = {Topic, _}} = Message) ->
  lists:foreach(fun({ClientId, ClientPid, SubscribedQoS}) ->
    AdjustedMessage = if
      Message#mqtt.qos > SubscribedQoS ->
        Message#mqtt{qos = SubscribedQoS};
      true ->
        Message
    end,
    ?LOG({passing, mqtt_core:pretty(AdjustedMessage), to, ClientId, ClientPid}),
    case ClientPid of
      not_connected ->
        if
          AdjustedMessage#mqtt.qos =:= 0 ->
            drop_on_the_floor;
          AdjustedMessage#mqtt.qos > 0 ->
            ok = gen_server:call({global, mqtt_postroom}, {put_by, AdjustedMessage, for, ClientId}, 1)
        end;
      _ ->
        ClientPid ! {deliver, AdjustedMessage}
    end
  end, mqtt_registry:get_subscribers(Topic)),
  ok.

send(#mqtt{} = Message, State) ->
  ?LOG({send, mqtt_core:pretty(Message)}),
  SendableMessage = if
    Message#mqtt.dup =:= 0, Message#mqtt.qos > 0 ->
      IdMessage = Message#mqtt{id = id:get_incr(State#client_proxy.id_pid)},
      ok = store:put_message(IdMessage, State#client_proxy.outbox_pid),
      IdMessage;
    true ->
      Message
  end,
  mqtt_core:send(SendableMessage, State#client_proxy.context).
