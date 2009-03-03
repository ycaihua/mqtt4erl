-module(mqtt_broker).

%% TODO
%% - clean up topics with no subscribers
%% - support clean starts

-include_lib("mqtt.hrl").

-compile(export_all).

-export([start/0, distribute/1, route/2]).

-record(broker, {
  socket
}).

-record(owner, {
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
    mqtt_client:client_loop(#client{
      context = Context,
      owner_pid = spawn(?MODULE, owner_loop, [])
    })
  end),
  server_loop(State).

owner_loop() ->
  owner_loop(#owner{}).
owner_loop(State) ->
  NewState = receive
    {mqtt_client, connect, ClientId, Pid, Will} ->
      ?LOG({connect, from, ClientId, at, Pid}),
      State#owner{will = Will};
    #mqtt{type = ?PUBLISH, retain = Retain} = Message ->
      distribute(Message),
      case Retain =:= 1 of
        true ->
          mqtt_registry:retain(Message);
        _ ->
          noop
      end,
      State;
    {mqtt_client, disconnected, ClientId} ->
      ?LOG({disconnect, from, ClientId, will, State#owner.will}),
      case State#owner.will of
        #mqtt{} = Will ->
          distribute(Will);
        _ ->
          noop
      end,
      mqtt_registry:unregister_client(ClientId),
      exit(normal),
      State;
    Message ->
      ?LOG({owner, unexpected_message, Message}),
      State
  end,
  owner_loop(NewState).

distribute(#mqtt{arg = {Topic, _}} = Message) ->
  Subscribers = mqtt_registry:get_subscribers(Topic),
  ?LOG({distribute, mqtt_core:pretty(Message), to, Subscribers}),
  lists:foreach(fun(Client) ->
    route(Message, Client)
  end, Subscribers),
  ok.

route(#mqtt{} = Message, {ClientId, ClientPid, SubscribedQoS}) ->
  DampedMessage = if
    Message#mqtt.qos > SubscribedQoS ->
      Message#mqtt{qos = SubscribedQoS};
    true ->
      Message
  end,
  ?LOG({passing, mqtt_core:pretty(DampedMessage), to, ClientId, ClientPid}),
  case ClientPid of
    not_connected ->
      if
        DampedMessage#mqtt.qos =:= 0 ->
          drop_on_the_floor;
        DampedMessage#mqtt.qos > 0 ->
%% TODO
          noop
      end;
    _ ->
      mqtt_client:deliver(ClientPid, DampedMessage)
  end.
