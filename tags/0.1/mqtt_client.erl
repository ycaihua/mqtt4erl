-module(mqtt_client).
-author(hellomatty@gmail.com).

%%
%% An erlang client for MQTT (http://www.mqtt.org/)
%%

-include_lib("mqtt.hrl").

-export([connect/1, connect/3, publish/3, subscribe/2, unsubscribe/2, disconnect/1, subscriptions/1, get_message/0, default_client_id/0, resend_unack/1]).

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
          send_store_pid = spawn_link(fun() -> store:start() end),
          recv_store_pid = spawn_link(fun() -> store:start() end)
        },
        ok = send(mqtt_core:construct_message({connect, Host, Port, O}), ClientState),
        spawn_link(fun() -> mqtt_core:recv_loop(Context)  end),
        receive
          connected ->
            ClientState#client.owner_pid ! {mqtt, connected},
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
    {mqtt, connected} ->
      {ok, Pid}
    after
      O#connect_options.connect_timeout * 1000 ->
        exit(Pid, cancel),
        {error, connect_timeout}
  end.

publish(Pid, Topic, Message) ->
  Pid ! {publish, Topic, Message, []},
  ok.

subscribe(Pid, Topic) ->
  Pid ! {subscribe, [#sub{topic = Topic}]},
  receive
    {mqtt, subscription, updated} ->
      ok
  end.

unsubscribe(Pid, Topic) ->
  Pid ! {unsubscribe, [#sub{topic = Topic}]},
  receive
    {mqtt, subscription, updated} ->
      ok
  end.

disconnect(Pid) ->
  Pid ! disconnect,
  ok.

subscriptions(Pid) ->
  Pid ! {subscriptions, self()},
  receive
    {mqtt, subscriptions, Subscriptions} ->
      Subscriptions
  end.

get_message() ->
  receive
    {mqtt, received, _, _} = Message ->
      Message
  end.

client_loop(State) ->
  NewState = receive
    {publish, Topic, Payload, Options} ->
      O = mqtt_core:set_publish_options(Options),
      Message = if
        O#publish_options.qos > 0 ->
          construct_id_message({publish, Topic, Payload, O}, State);
        true ->
          mqtt_core:construct_message({publish, Topic, Payload, O})
      end,
      ok = send(Message, State),
      State;
    {received, Message} when Message#mqtt.qos =:= 2 ->
      ?LOG({client, received, Message}),
      put_stored_message(Message, State#client.recv_store_pid),
      State;
    {received, Message} ->
      {_, Topic, Payload} = Message#mqtt.hint,
      ?LOG({client, received, Message}),
      State#client.owner_pid ! {mqtt, received, Topic, Payload},
      State;
    {release, MessageId} ->
      Message = get_stored_message(MessageId, State#client.recv_store_pid),
      ?LOG({client, release, Message}),
      {_, Topic, Payload} = Message#mqtt.hint,
      State#client.owner_pid ! {mqtt, received, Topic, Payload},
      delete_stored_message(MessageId, State#client.recv_store_pid),
      State;
    {subscribe, _Topics} = Request ->
      ok = send(construct_id_message(Request, State), State),
      State;
    {subscribed, {MessageId, GrantedQoS}} ->
      State#client.owner_pid ! {mqtt, subscription, updated},
      PendingSubs = (get_stored_message(MessageId, State#client.send_store_pid))#mqtt.hint,
      State#client{
        subscriptions = add_subscriptions(PendingSubs, GrantedQoS, State#client.subscriptions)
      };
    {unsubscribe, _Subs} = Request ->
      ok = send(construct_id_message(Request, State), State),
      State;
    {unsubscribed, MessageId} ->
      State#client.owner_pid ! {mqtt, subscription, updated},
      PendingUnsubs = (get_stored_message(MessageId, State#client.send_store_pid))#mqtt.hint,
      State#client{
        subscriptions = remove_subscriptions(PendingUnsubs, State#client.subscriptions)
      };
    disconnect ->
      ok = send(mqtt_core:construct_message(disconnect), State),
      State;
    {ack, MessageId} ->
      delete_stored_message(MessageId, State#client.send_store_pid),
      State;
    {subscriptions, FromPid} ->
      FromPid ! {mqtt, subscriptions, State#client.subscriptions},
      State;
    {'EXIT', FromPid, Reason} ->
      ?LOG({got, exit, FromPid, Reason}),
      timer:cancel(State#client.ping_timer),
      timer:cancel(State#client.retry_timer),
      State#client.owner_pid ! {mqtt, disconnected},
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

put_stored_message(Message, StorePid) ->
  StorePid ! {store, put, Message}.

get_all_stored_messages(StorePid) ->
  StorePid ! {store, get, all, self()},
  receive
    {store, get, ok, Results} ->
      Results
  end.

get_stored_message(MessageId, StorePid) ->
  StorePid ! {store, get, MessageId, self()},
  receive
    {store, get, ok, Result} ->
      Result;
    {store, get, not_found} ->
      exit({store, get, MessageId, not_found})
  end.

delete_stored_message(MessageId, StorePid) ->
  StorePid ! {store, delete, MessageId}.

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
  ?LOG({resend_unack}),
  lists:foreach(fun({_Id, Message}) ->
      spawn(fun() -> mqtt_core:send(Message#mqtt{dup = 1}) end)
    end,
    get_all_stored_messages(State)
  ).

send(#mqtt{} = Message, State) ->
  ?LOG({client, send, Message}),
  if
    Message#mqtt.dup =:= 0, Message#mqtt.qos > 0, Message#mqtt.qos < 3 ->
      put_stored_message(Message, State#client.send_store_pid);
    true ->
      do_not_keep
  end,
  mqtt_core:send(Message, State#client.context).
