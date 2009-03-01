-module(mqtt_client).
-author(hellomatty@gmail.com).

%%
%% An erlang client for MQTT (http://www.mqtt.org/)
%%

-include_lib("mqtt.hrl").

-export([connect/1, connect/3, publish/3, subscribe/2, unsubscribe/2, disconnect/1, get_message/0, default_client_id/0, client_loop/1, send_ping/1, resend_unack/1]).

connect(Host) ->
  connect(Host, ?MQTT_PORT, []).
connect(Host, Port, Options) ->
  O = mqtt_core:set_connect_options(Options),
  OwnerPid = self(),
  Pid = case gen_tcp:connect(Host, Port, [binary, {active, false}, {packet, raw}, {nodelay, true}]) of
    {ok, Socket} ->
      spawn_link(fun() ->
        process_flag(trap_exit, true),
        Context = #context{
          pid = self(),
          socket = Socket
        },
        ClientState = #client{
          context = Context,
          owner_pid = OwnerPid,
          connect_options = O
        },
        ok = send(#mqtt{type = ?CONNECT, arg = {Host, Port, O}}, ClientState),
        spawn_link(fun() -> mqtt_core:recv_loop(Context) end),
        client_loop(ClientState)
      end);
    {error, Reason} ->
      exit({connect, socket, fail, Reason})
  end,
  receive
    {?MODULE, connected} ->
      {ok, Pid}
    after
      O#connect_options.connect_timeout * 1000 ->
        exit(Pid, cancel),
        {error, connect_timeout}
  end.

publish(Pid, Topic, Message) ->
  Pid ! {?MODULE, publish, Topic, Message, []},
  ok.

subscribe(Pid, Topic) ->
  Pid ! {?MODULE, subscribe, [#sub{topic = Topic}]},
  receive
    {?MODULE, subscription, updated, _} ->
      ok
  end.

unsubscribe(Pid, Topic) ->
  Pid ! {?MODULE, unsubscribe, [#sub{topic = Topic}]},
  receive
    {?MODULE, subscription, updated, _} ->
      ok
  end.

disconnect(Pid) ->
  Pid ! {?MODULE, disconnect},
  ok.

get_message() ->
  receive
    {?MODULE, received, _, _} = Message ->
      Message
  end.

client_loop(State) ->
  NewState = receive
    {?MODULE, subscribe, Subs} ->
      ok = send(#mqtt{type = ?SUBSCRIBE, qos = 1, arg = Subs}, State),
      State;
    {?MODULE, unsubscribe, Unsubs} ->
      ok = send(#mqtt{type = ?UNSUBSCRIBE, qos = 1, arg = Unsubs}, State),
      State;
    {?MODULE, publish, Topic, Payload, Options} ->
      O = mqtt_core:set_publish_options(Options),
      Message = if
        O#publish_options.qos > 0 ->
          #mqtt{
            type = ?PUBLISH,
            qos = O#publish_options.qos,
            retain = O#publish_options.retain,
            arg = {Topic, Payload}
           };
        true ->
          #mqtt{
            type = ?PUBLISH,
            qos = O#publish_options.qos,
            retain = O#publish_options.retain,
            arg = {Topic, Payload}
          }
      end,
      ok = send(Message, State),
      State;
    {?MODULE, disconnect} ->
      ok = send(#mqtt{type = ?DISCONNECT}, State),
      exit(disconnect);
    #mqtt{type = ?CONNACK, arg = 0} ->
      State#client.owner_pid ! {?MODULE, connected},
      start_client(State);
    #mqtt{type = ?CONNACK, arg = 1} ->
      exit({connect_refused, wrong_protocol_version});
    #mqtt{type = ?CONNACK, arg = 2} ->
      exit({connect_refused, identifier_rejectedn});
    #mqtt{type = ?CONNACK, arg = 3} ->
      exit({connect_refused, broker_unavailable});
    #mqtt{type = ?CONNECT, arg = Arg} 
        when Arg#connect_options.protocol_version /= ?PROTOCOL_VERSION ->
      send(#mqtt{type = ?CONNACK, arg = 1}, State),
      exit({connect_refused, wrong_protocol_version});
    #mqtt{type = ?CONNECT, arg = Arg}
        when length(Arg#connect_options.client_id) < 1;
        length(Arg#connect_options.client_id) > 23 ->
      send(#mqtt{type = ?CONNACK, arg = 2}, State),
      exit({connect_refused, invalid_clientid});
    #mqtt{type = ?CONNECT, arg = Arg} ->
      ?LOG({connect, Arg}),
      ok = mqtt_registry:register_client(Arg#connect_options.client_id, self()),
      send(#mqtt{type = ?CONNACK, arg = 0}, State),
      start_client(State#client{connect_options = Arg});
    #mqtt{type = ?PINGRESP} ->
      State;
    #mqtt{type = ?PINGREQ}  ->
      send(#mqtt{type = ?PINGRESP}, State),
      State;
    #mqtt{type = ?SUBSCRIBE, id = MessageId, arg = Subs} ->
      ?LOG({subscribe, Subs}),
      ok = mqtt_registry:subscribe((State#client.connect_options)#connect_options.client_id, Subs),
      send(#mqtt{type = ?SUBACK, arg = {MessageId, Subs}}, State),
      State;
    #mqtt{type = ?SUBACK, arg = {MessageId, GrantedQoS}} ->
      PendingSubs = (store:get_message(MessageId, State#client.outbox_pid))#mqtt.arg,
      ?LOG({suback, PendingSubs}),
      State#client.owner_pid ! {?MODULE, subscription, updated, merge_subs(PendingSubs, GrantedQoS)},
      store:delete_message(MessageId, State#client.outbox_pid),
      State;
    #mqtt{type = ?UNSUBSCRIBE, id = MessageId, arg = {_, Unsubs}} ->
      ?LOG({unsubscribe, Unsubs}),
      ok = mqtt_registry:unsubscribe((State#client.connect_options)#connect_options.client_id, Unsubs),
      send(#mqtt{type = ?UNSUBACK, arg = MessageId}, State),
      State;
    #mqtt{type = ?UNSUBACK, arg = MessageId} ->
      PendingUnsubs = (store:get_message(MessageId, State#client.outbox_pid))#mqtt.arg,
      ?LOG({unsuback, PendingUnsubs}),
      State#client.owner_pid ! {?MODULE, subscription, updated, PendingUnsubs},
      store:delete_message(MessageId, State#client.outbox_pid),
      State;
    #mqtt{type = ?PUBLISH, qos = 2, arg = {Topic, Payload}} = Message ->
      ?LOG({client, received, qos, 2, Topic, Payload}),
      store:put_message(Message, State#client.inbox_pid),
      State;
    #mqtt{type = ?PUBLISH, arg = {Topic, Payload}} ->
      ?LOG({client, received, qos_less_than, 2, Topic, Payload}),
      State#client.owner_pid ! {?MODULE, received, Topic, Payload},
      State;
    #mqtt{type = ?PUBACK, arg = MessageId} ->
      store:delete_message(MessageId, State#client.outbox_pid),
      State;
    #mqtt{type = ?PUBREL, arg = MessageId} ->
      #mqtt{type = ?PUBLISH, arg = {Topic, Payload}} = store:get_message(MessageId, State#client.inbox_pid),
      State#client.owner_pid ! {?MODULE, received, Topic, Payload},
      store:delete_message(MessageId, State#client.inbox_pid),
      State;
    #mqtt{type = ?PUBCOMP, arg = MessageId} ->
      store:delete_message(MessageId, State#client.outbox_pid),
      State;
    #mqtt{type = ?DISCONNECT} ->
      exit(client_disconnect);
    {'EXIT', FromPid, Reason} ->
      ?LOG({got, exit, FromPid, Reason}),
      stop_client(State),
      State#client.owner_pid ! {?MODULE, disconnected},
      exit(Reason);
    Message ->
      ?LOG({?MODULE, unexpected_message, mqtt_core:pretty(Message)}),
      State
  end,
  client_loop(NewState).

start_client(State) ->
  PingInterval = (State#client.connect_options)#connect_options.keepalive,
  RetryInterval = (State#client.connect_options)#connect_options.retry,
  InitialState = State#client{
    id_pid = spawn_link(fun() -> id:start() end),
    inbox_pid = spawn_link(fun() -> store:start() end),
    outbox_pid = spawn_link(fun() -> store:start() end)
  },
  InitialState#client{
    ping_timer = timer:apply_interval(PingInterval * 1000, ?MODULE, send_ping, [InitialState]),
    retry_timer = timer:apply_interval(RetryInterval * 1000, ?MODULE, resend_unack, [InitialState])
  }.

stop_client(State) ->
  timer:cancel(State#client.ping_timer),
  timer:cancel(State#client.retry_timer),
  ok.

default_client_id() ->
  {{_Y,Mon,D},{H,Min,S}} = erlang:localtime(),
  lists:flatten(io_lib:format(
    "~2.10.0B~2.10.0B~2.10.0B~2.10.0B~2.10.0B~w",
    [Mon, D, H, Min, S, self()]
  )).

merge_subs(PendingSubs, GrantedQoS) ->
  merge_subs(PendingSubs, GrantedQoS, []).
merge_subs([], [], GrantedSubs) ->
  lists:reverse(GrantedSubs);
merge_subs([{sub, Topic, _}|PendingTail], [QoS|GrantedTail], GrantedSubs) ->
  merge_subs(PendingTail, GrantedTail, [{sub, Topic, QoS}|GrantedSubs]).

send_ping(State) ->
  ?LOG({send, ping}),
  send(#mqtt{type = ?PINGREQ}, State).

resend_unack(State) ->
  ?LOG(resend_unack),
  lists:foreach(fun({_MessageId, Message}) ->
    ?LOG({resend, mqtt_core:pretty(Message)}),
    send(Message#mqtt{dup = 1}, State) 
  end, store:get_all_messages(State#client.outbox_pid)).

send(#mqtt{} = Message, State) ->
  ?LOG({client, send, mqtt_core:pretty(Message)}),
  SendableMessage = if
    Message#mqtt.dup =:= 0, Message#mqtt.qos > 0 ->
      IdMessage = Message#mqtt{id = id:get_incr(State#client.id_pid)},
      ok = store:put_message(IdMessage, State#client.outbox_pid),
      IdMessage;
    true ->
      Message
  end,
  mqtt_core:send(SendableMessage, State#client.context).
