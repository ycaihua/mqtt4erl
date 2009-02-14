-module(mqtt_broker).

-include_lib("mqtt.hrl").

-export([start/0]).

-record(broker, {
  sub_pid
}).

-record(client_proxy, {
  broker,
  context,
  ping_timer
}).

start() ->
  Pid = spawn_link(fun() ->
    {ok, ListenSocket} = gen_tcp:listen(?MQTT_PORT, [binary, {active, false}]),
    server_loop(ListenSocket)
  end),
  {ok, Pid}.

server_loop(ListenSocket) ->
  Broker = #broker{sub_pid = spawn_link(fun() -> subscriber_loop() end)},
  {ok, ClientSocket} = gen_tcp:accept(ListenSocket),
  _ClientPid = spawn_link(fun() ->
    process_flag(trap_exit, true),
    Context = #context{
      socket = ClientSocket,
      pid = self()
    },
    spawn_link(fun() -> mqtt_core:recv_loop(Context) end),
    client_loop(#client_proxy{
      broker = Broker,
      context = Context
    })
  end),
  server_loop(ListenSocket).

client_loop(State) ->
  NewState = receive
    {connect, O} ->
      ?LOG({client_loop, connect, O}),
      %% TODO verify client-id
      mqtt_core:send(mqtt_core:construct_message({connack, 0}), State#client_proxy.context),
      State#client_proxy{
        ping_timer = timer:apply_interval(O#connect_options.keepalive * 1000, mqtt_core, send_ping, [State#client_proxy.context])
      };
    {subscribe, {_, Subs} = Hint} ->
      ?LOG({client_loop, subscribe, Hint}),
      lists:foreach(fun(S) -> State#broker.sub_pid ! {sub, add, self(), S} end, Subs),
      mqtt_core:send(mqtt_core:construct_message({suback, Hint}), State#client_proxy.context);
    {published, Message} ->
      ?LOG({client_loop, got, Message}),
      {_, Topic, _} = Message#mqtt.hint,
      Clients = get_subscribers(Topic, State),
      ?LOG({published, send_to, Clients}),
      State;
    {'EXIT', FromPid, Reason} ->
      %% send the will!
      ?LOG({client_loop, got, exit, FromPid, Reason}),
      timer:cancel(State#client_proxy.ping_timer),
      exit(Reason);
    Message ->
      ?LOG({client_loop, got, Message}),
      State
  end,  
  client_loop(NewState).

subscriber_loop() ->
  subscriber_loop(dict:new()).
subscriber_loop(State) ->
  NewState = receive
    {sub, add, ClientPid, Sub} ->
      ?LOG({subscribers, add, ClientPid, Sub}),
      dict:append(Sub#sub.topic, {ClientPid, Sub#sub.qos}, State);
    {sub, get, Topic, FromPid} ->
      case dict:find(Topic, State) of
        {ok, Subscribers} ->
          FromPid ! {sub, ok, Subscribers};
        error ->
          FromPid ! {sub, ok, []}
      end,
      State;
    Message ->
      ?LOG({subscribers, got, Message})
  end,
  subscriber_loop(NewState).

get_subscribers(Topic, State) ->
  State#broker.sub_pid ! {sub, get, Topic},
  receive 
    {sub, ok, Subscribers} ->
      Subscribers;
    Message ->
      ?LOG({get_subscribers, got, Message})
  end.


