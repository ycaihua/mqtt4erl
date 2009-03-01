-module(mqtt_client).
-author(hellomatty@gmail.com).

%%
%% An erlang client for MQTT (http://www.mqtt.org/)
%%

-include_lib("mqtt.hrl").

-export([connect/1, connect/3, publish/3, subscribe/2, unsubscribe/2, disconnect/1, get_message/0, default_client_id/0, resend_unack/1]).

-record(client, {
  context,
  id_pid,
  owner_pid,
  inbox_pid,
  outbox_pid,
  ping_timer,
  retry_timer
}).

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
          id_pid = spawn_link(fun() -> id:start() end),
          inbox_pid = spawn_link(fun() -> store:start() end),
          outbox_pid = spawn_link(fun() -> store:start() end)
        },
        ok = send(#mqtt{type = ?CONNECT, arg = {Host, Port, O}}, ClientState),
        spawn_link(fun() -> mqtt_core:recv_loop(Context)  end),
        receive
          #mqtt{type = ?CONNACK} ->
            ClientState#client.owner_pid ! {?MODULE, connected},
            client_loop(ClientState#client{
              context = Context,
              retry_timer = timer:apply_interval(O#connect_options.retry * 1000, ?MODULE, resend_unack, [ClientState]),
              ping_timer = timer:apply_interval(O#connect_options.keepalive * 1000, mqtt_core, send_ping, [Context])
            })
        end
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
      State;
    #mqtt{type = ?PUBLISH, qos = 2, arg = {Topic, Payload}} = Message ->
      ?LOG({client, received, qos, 2, Topic, Payload}),
      store:put_message(Message, State#client.inbox_pid),
      State;
    #mqtt{type = ?PUBLISH, arg = {Topic, Payload}} ->
      ?LOG({client, received, qos_less_than, 2, Topic, Payload}),
      State#client.owner_pid ! {?MODULE, received, Topic, Payload},
      State;
    #mqtt{type = ?SUBACK, arg = {MessageId, GrantedQoS}} ->
      PendingSubs = (store:get_message(MessageId, State#client.outbox_pid))#mqtt.arg,
      ?LOG({suback, PendingSubs}),
      State#client.owner_pid ! {?MODULE, subscription, updated, merge_subs(PendingSubs, GrantedQoS)},
      store:delete_message(MessageId, State#client.outbox_pid),
      State;
    #mqtt{type = ?UNSUBACK, arg = MessageId} ->
      PendingUnsubs = (store:get_message(MessageId, State#client.outbox_pid))#mqtt.arg,
      ?LOG({unsuback, PendingUnsubs}),
      State#client.owner_pid ! {?MODULE, subscription, updated, PendingUnsubs},
      store:delete_message(MessageId, State#client.outbox_pid),
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
    {'EXIT', FromPid, Reason} ->
      ?LOG({got, exit, FromPid, Reason}),
      timer:cancel(State#client.ping_timer),
      timer:cancel(State#client.retry_timer),
      State#client.owner_pid ! {?MODULE, disconnected},
      exit(Reason);
    Message ->
      ?LOG({?MODULE, unexpected_message, Message}),
      State
  end,
  client_loop(NewState).

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

resend_unack(State) ->
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
