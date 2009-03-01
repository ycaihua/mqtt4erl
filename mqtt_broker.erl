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
      context = Context,
      owner_pid = spawn(?MODULE, owner_loop, [])
    })
  end),
  server_loop(State).

owner_loop() ->
  receive
    {mqtt_client, connect, ClientId, Pid} ->
      ?LOG({connect, from, ClientId, at, Pid});
    #mqtt{type = ?PUBLISH} = Message ->
      distribute(Message);
    {mqtt_client, disconnected, ClientId} ->
      ?LOG({disconnect, from, ClientId}),
      mqtt_registry:unregister_client(ClientId),
      exit(normal);
    Message ->
      ?LOG({owner, unexpected_message, Message})
  end,
  owner_loop().

%%clientproxy_loop(State) ->
%%  NewState = receive
%%    #mqtt{type = ?PUBLISH, retain = 1} = Message ->
%%      mqtt_registry:retain(Message),
%%      ok;
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
  ?LOG({distribute, mqtt_core:pretty(Message)}),
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
        ClientPid ! {'_deliver', AdjustedMessage}
    end
  end, mqtt_registry:get_subscribers(Topic)),
  ok.
