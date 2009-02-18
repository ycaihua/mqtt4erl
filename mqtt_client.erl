-module(mqtt_client).
-author(hellomatty@gmail.com).

%%
%% An erlang client for MQTT (http://www.mqtt.org/)
%%

-include_lib("mqtt.hrl").

-export([connect/1, connect/3, publish/3, subscribe/2, unsubscribe/2, disconnect/1, subscriptions/1, get_message/0, default_client_id/0, resend_unack/1]).

-record(client, {
  context,
  id_pid,
  owner_pid,
  inbox_pid,
  outbox_pid,
  subscriptions = [],
  ping_timer,
  retry_timer
}).

connect(Host) ->
  connect(Host, ?MQTT_PORT, []).
connect(Host, Port, Options) ->
  O = mqtt_core:set_connect_options(Options),
  OwnerPid = self(),
  Pid = case gen_tcp:connect(Host, Port, [binary, {active, false}]) of
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
          id_pid = spawn_link(fun() -> id_loop() end),
          inbox_pid = spawn_link(fun() -> store:start() end),
          outbox_pid = spawn_link(fun() -> store:start() end)
        },
        ok = send(mqtt_core:construct_message({connect, Host, Port, O}), ClientState),
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
    {?MODULE, subscription, updated} ->
      ok
  end.

unsubscribe(Pid, Topic) ->
  Pid ! {?MODULE, unsubscribe, [#sub{topic = Topic}]},
  receive
    {?MODULE, subscription, updated} ->
      ok
  end.

disconnect(Pid) ->
  Pid ! {?MODULE, disconnect},
  ok.

subscriptions(Pid) ->
  Pid ! {?MODULE, subscriptions, self()},
  receive
    {?MODULE, subscriptions, Subscriptions} ->
      Subscriptions
  end.

get_message() ->
  receive
    {?MODULE, received, _, _} = Message ->
      Message
  end.

client_loop(State) ->
  NewState = receive
    {?MODULE, subscribe, Topics} ->
      ok = send(construct_id_message({subscribe, Topics}, State), State),
      State;
    {?MODULE, unsubscribe, Unsubs} ->
      ok = send(construct_id_message({unsubscribe, Unsubs}, State), State),
      State;
    {?MODULE, publish, Topic, Payload, Options} ->
      O = mqtt_core:set_publish_options(Options),
      Message = if
        O#publish_options.qos > 0 ->
          construct_id_message({publish, Topic, Payload, O}, State);
        true ->
          mqtt_core:construct_message({publish, Topic, Payload, O})
      end,
      ok = send(Message, State),
      State;
    {?MODULE, disconnect} ->
      ok = send(mqtt_core:construct_message(disconnect), State),
      State;
    {?MODULE, subscriptions, FromPid} ->
      FromPid ! {?MODULE, subscriptions, State#client.subscriptions},
      State;
    #mqtt{type = ?PUBLISH, qos = 2, hint = {_, Topic, Payload}} = Message ->
      ?LOG({client, received, qos, 2, Topic, Payload}),
      store:put_message(Message, State#client.inbox_pid),
      State;
    #mqtt{type = ?PUBLISH, hint = {_, Topic, Payload}} ->
      ?LOG({client, received, qos_less_than, 2, Topic, Payload}),
      State#client.owner_pid ! {?MODULE, received, Topic, Payload},
      State;
    #mqtt{type = ?SUBACK, hint = {MessageId, GrantedQoS}} ->
      State#client.owner_pid ! {?MODULE, subscription, updated},
      PendingSubs = (store:get_message(MessageId, State#client.outbox_pid))#mqtt.hint,
      store:delete_message(MessageId, State#client.outbox_pid),
      State#client{
        subscriptions = add_subscriptions(PendingSubs, GrantedQoS, State#client.subscriptions)
      };
    #mqtt{type = ?UNSUBACK, hint = MessageId} ->
      State#client.owner_pid ! {?MODULE, subscription, updated},
      PendingUnsubs = (store:get_message(MessageId, State#client.outbox_pid))#mqtt.hint,
      store:delete_message(MessageId, State#client.outbox_pid),
      State#client{
        subscriptions = remove_subscriptions(PendingUnsubs, State#client.subscriptions)
      };
    #mqtt{type = ?PUBACK, hint = MessageId} ->
      store:delete_message(MessageId, State#client.outbox_pid),
      State;
    #mqtt{type = ?PUBREL, hint = MessageId} ->
      #mqtt{type = ?PUBLISH, hint = {_, Topic, Payload}} = store:get_message(MessageId, State#client.inbox_pid),
      State#client.owner_pid ! {?MODULE, received, Topic, Payload},
      store:delete_message(MessageId, State#client.inbox_pid),
      State;
    #mqtt{type = ?PUBCOMP, hint = MessageId} ->
      store:delete_message(MessageId, State#client.outbox_pid),
      State;
    {subscriptions, FromPid} ->
      FromPid ! {?MODULE, subscriptions, State#client.subscriptions},
      State;
    {'EXIT', FromPid, Reason} ->
      ?LOG({got, exit, FromPid, Reason}),
      timer:cancel(State#client.ping_timer),
      timer:cancel(State#client.retry_timer),
      State#client.owner_pid ! {?MODULE, disconnected},
      exit(Reason);
    Message ->
      ?LOG({client, unexpected_message, Message}),
      State
  end,
  client_loop(NewState).

default_client_id() ->
  {{Y,Mon,D},{H,Min,S}} = erlang:localtime(),
  lists:flatten(io_lib:format("~B-~2.10.0B-~2.10.0B-~2.10.0B-~2.10.0B-~2.10.0B-~w",[Y, Mon, D, H, Min, S, self()])).

add_subscriptions([], [], Subscriptions) ->
  Subscriptions;
add_subscriptions([{sub, Topic, _QoS} = S|Subs], [Q|QoS], Subscriptions) ->
  NewSubs = [S#sub{qos = Q}|lists:keydelete(Topic, 2, Subscriptions)],
  add_subscriptions(Subs, QoS, NewSubs).

remove_subscriptions([], Subscriptions) ->
  Subscriptions;
remove_subscriptions([{sub, Topic, _QoS}|Unsubs], Subscriptions) ->
  remove_subscriptions(Unsubs, lists:keydelete(Topic, 2, Subscriptions)).

construct_id_message(Request, State) ->
  mqtt_core:construct_message(Request, #mqtt{id = id_get_incr(State)}).

id_get_incr(State) ->
  State#client.id_pid ! {get_incr, self()},
  receive
    {id, Id} ->
      Id
  end.

id_loop() ->
  id_loop(1).
id_loop(Sequence) ->
  receive
    {get_incr, From} ->
      From ! {id, Sequence}
  end,
  id_loop(Sequence + 1).

resend_unack(State) ->
  lists:foreach(fun({_MessageId, Message}) ->
    ?LOG({resend, mqtt_core:pretty(Message)}),
    send(Message#mqtt{dup = 1}, State) 
  end, store:get_all_messages(State#client.outbox_pid)).

send(#mqtt{} = Message, State) ->
  ?LOG({client, send, Message}),
  if
    Message#mqtt.dup =:= 0, Message#mqtt.qos > 0, Message#mqtt.qos < 3 ->
      ok = store:put_message(Message, State#client.outbox_pid);
    true ->
      do_not_keep
  end,
  mqtt_core:send(Message, State#client.context).
