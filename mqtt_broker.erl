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
    mqtt_client:client_loop(#client{
      context = Context
    })
  end),
  server_loop(State).

%%clientproxy_loop(State) ->
%%  NewState = receive
%%    #mqtt{type = ?PUBLISH, retain = 1} = Message ->
%%      mqtt_registry:retain(Message),
%%      ok;
%%    #mqtt{type = ?PUBLISH, qos = 2} = Message ->
%%      ok = store:put_message(Message, State#client_proxy.inbox_pid),
%%      State;
%%    #mqtt{type = ?PUBLISH} = Message ->
%%      ?LOG({client_loop, got, mqtt_core:pretty(Message)}),
%%      ok = distribute(Message),
%%      State;
%%    #mqtt{type = ?PUBACK, arg = MessageId} ->
%%      store:delete_message(MessageId, State#client_proxy.outbox_pid),
%%      State;
%%    #mqtt{type = ?PUBREL, arg = MessageId} ->
%%      Message = store:get_message(MessageId, State#client_proxy.inbox_pid),
%%      store:delete_message(MessageId, State#client_proxy.inbox_pid),
%%      distribute(Message),
%%      State;
%%    #mqtt{type = ?PUBCOMP, arg = MessageId} ->
%%      store:delete_message(MessageId, State#client_proxy.outbox_pid),
%%      State;
%%    {deliver, #mqtt{} = Message} ->
%%      ?LOG({client_loop, delivering, mqtt_core:pretty(Message)}),
%%      send(Message, State),
%%      State;
%%    {'EXIT', FromPid, Reason} ->
%%      ?LOG({exti, Reason, from, FromPid}),
%%      timer:cancel(State#client_proxy.ping_timer),
%%      send_will(State),
%%      mqtt_registry:unregister_client(State#client_proxy.client_id, store:get_all_messages(State#client_proxy.outbox_pid)), 
%%      exit(Reason);
%%    Message ->
%%      ?LOG({client_loop, got, Message}),
%%      State
%%  end,  
%%  clientproxy_loop(NewState).

%%send_will(#client{will = W}) when is_record(W, will) ->
%%  ?LOG({send_will, W}),
%%  ok = distribute(#mqtt{type = ?PUBLISH, qos = (W#will.publish_options)#publish_options.qos, retain = (W#will.publish_options)#publish_options.retain, arg = {W#will.topic, W#will.message}});
%%send_will(_State) ->
%%  noop.

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
