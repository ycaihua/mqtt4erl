-module(mqtt_broker).
-behaviour(gen_server).

-include_lib("mqtt.hrl").

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).
-export([start_link/0, owner_loop/0, distribute/1, route/2]).

-record(owner, {
  will
}).

-define(BACKLOG, 100).

start_link() -> gen_server:start_link({global, ?MODULE}, ?MODULE, [], []).


init([]) ->
  ?LOG(start),
  case gen_tcp:listen(?MQTT_PORT, [binary, {active, false}, {packet, raw}, {nodelay, true}, {keepalive, true}, {backlog, ?BACKLOG}]) of
    {ok, ListenSocket} ->
      Pid = self(),
      spawn_link(fun() ->
        server_loop(Pid, ListenSocket)
      end),
      {ok, ListenSocket};
    {error, Reason} ->
      ?LOG({listen_socket, fail, Reason}),
      {stop, Reason}
  end.

handle_call(Message, _FromPid, State) ->
  ?LOG({unexpected_message, Message}),
  {reply, ok, State}.

handle_cast({accepted, Socket}, State) ->
  ?LOG({socket, accepted, Socket}),
  OwnerPid = spawn(?MODULE, owner_loop, []),
  {ok, _ClientPid} = mqtt_client:start(Socket, OwnerPid),
  {noreply, State};
handle_cast(Message, State) ->
  ?LOG({unexpected_message, Message}),
  {noreply, State}.

handle_info(_, State) ->
  {noreply, State}.

terminate(_Reason, ListenSocket) ->
  gen_tcp:close(ListenSocket),
  ok.

code_change(_OldVersion, State, _Extra) -> {ok, State}.

server_loop(Pid, ListenSocket) ->
  {ok, ClientSocket} = gen_tcp:accept(ListenSocket),
  gen_server:cast(Pid, {accepted, ClientSocket}),
  server_loop(Pid, ListenSocket).

owner_loop() ->
  owner_loop(#owner{}).
owner_loop(#owner{} = State) ->
  NewState = receive
    {mqtt_client, escrow, Will} when is_record(Will, will) ->
      ?LOG({escrowing, Will}),
      State#owner{will = will_message(Will)};
    {mqtt_client, escrow, _Will} ->
      State;
    #mqtt{type = ?PUBLISH, retain = 1} = Message ->
      mqtt_registry:retain(Message),
      State;
    #mqtt{type = ?PUBLISH} = Message ->
      distribute(Message),
      State;
    {mqtt_client,disconnected} ->
      case State#owner.will of
        #mqtt{} = Will ->
          distribute(Will);
        _ ->
          noop
      end,
      exit(normal);
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

route(#mqtt{} = Message, {ClientId, SubscribedQoS}) ->
  DampedMessage = if
    Message#mqtt.qos > SubscribedQoS ->
      Message#mqtt{qos = SubscribedQoS};
    true ->
      Message
  end,
  ?LOG({passing, mqtt_core:pretty(DampedMessage), to, ClientId}),
  case mqtt_registry:lookup_pid(ClientId) of
    Pid when is_pid(Pid) ->
      mqtt_client:deliver(Pid, DampedMessage);
    undefined ->
      if
        DampedMessage#mqtt.qos =:= 0 ->
          drop_on_the_floor;
        DampedMessage#mqtt.qos > 0 ->
          mqtt_store:put_message({ClientId, pending}, Message)
      end;
    _ ->
      ?LOG({no_route_to, ClientId})
  end.

will_message(#will{topic = Topic, message = Message, publish_options = Opts}) ->
  #mqtt{
    type = ?PUBLISH,
    qos = Opts#publish_options.qos,
    retain = Opts#publish_options.retain,
    arg = {Topic, Message}
  };
will_message(undefined) ->
  undefined.
