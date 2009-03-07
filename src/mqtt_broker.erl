-module(mqtt_broker).
-behaviour(gen_server).

%% TODO
%% - clean up topics with no subscribers
%% - support clean starts

-include_lib("mqtt.hrl").

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).
-export([start_link/0, owner_loop/0, distribute/1, route/2]).

-record(broker, {
  socket
}).

-record(owner, {
  will
}).

start_link() -> gen_server:start_link({global, ?MODULE}, ?MODULE, [], []).


init([]) ->
  ?LOG(start),
  case gen_tcp:listen(?MQTT_PORT, [binary, {active, false}, {packet, raw}, {nodelay, true}]) of
    {ok, ListenSocket} ->
      Pid = spawn_link(fun() ->
        server_loop(#broker{
          socket = ListenSocket
        })
      end),
      {ok, Pid};
    {error, Reason} ->
      ?LOG({listen_socket, fail, Reason}),
      {stop, Reason}
  end.

handle_call(Message, _FromPid, State) ->
  ?LOG({unexpected_message, Message}),
  {reply, ok, State}.

handle_cast(Message, State) ->
  ?LOG({unexpected_message, Message}),
  {noreply, State}.

handle_info(_, State) ->
  {noreply, State}.

terminate(_Reason, _State) -> ok.

code_change(_OldVersion, State, _Extra) -> {ok, State}.

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
      mqtt_store:pass_messages({ClientId, pending}, Pid),
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
          mqtt_store:put_message({ClientId, pending}, Message)
      end;
    _ ->
      mqtt_client:deliver(ClientPid, DampedMessage)
  end.
