-module(mqtt_client).
-author(hellomatty@gmail.com).

%%
%% An erlang client for MQTT (http://www.mqtt.org/)
%%

-include_lib("mqtt.hrl").

-export([connect/1, connect/3, publish/3, subscribe/2, unsubscribe/2, disconnect/1, subscriptions/1, get_message/0, resend_unack/1, send_ping/1]).

connect(Host) ->
  connect(Host, ?MQTT_PORT, []).
connect(Host, Port, Options) ->
  Configuration = apply_options(Options, #client{client_id = default_client_id()}),
  OwnerPid = self(),
  Pid = case gen_tcp:connect(Host, Port, [binary, {active, false}]) of
    {ok, Socket} ->
      spawn(fun() ->
        process_flag(trap_exit, true),
        InitialState = Configuration#client{
          owner_pid = OwnerPid,
          pid = self(),
          socket = Socket,
          id_pid = spawn_link(fun() -> id_loop() end),
          store_pid = spawn_link(fun() -> store:start() end)
        },
        send(construct_message({connect, Host, Port, Options}, InitialState), InitialState),
        RecvPid = spawn_link(fun() -> recv_loop(InitialState)  end),
        ?LOG({recv, pid, RecvPid}),
        receive
          connected ->
            InitialState#client.owner_pid ! {mqtt, connected},
            client_loop(InitialState#client{
              recv_pid = RecvPid,
              retry_timer = timer:apply_interval(InitialState#client.retry * 1000, ?MODULE, resend_unack, [InitialState]),
              ping_timer = timer:apply_interval(InitialState#client.keepalive * 1000, ?MODULE, send_ping, [InitialState])
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
      Configuration#client.connect_timeout * 1000 ->
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
    {mqtt, published, _, _} = Message ->
      Message
  end.

client_loop(State) ->
  NewState = receive
    {publish, _Topic, _Message, _QoS} = Request ->
      self() ! {send, construct_message(Request, State)},
      State;
    {published, Topic, Message} ->
      State#client.owner_pid ! {mqtt, published, Topic, Message},
      State;
    {subscribe, _Topics} = Request ->
      self() ! {send, construct_message(Request, State)},
      State;
    {subscribed, {MessageId, GrantedQoS}} ->
      State#client.owner_pid ! {mqtt, subscription, updated},
      PendingSubs = (get_stored_message(MessageId, State))#mqtt.hint,
      State#client{
        subscriptions = add_subscriptions(PendingSubs, GrantedQoS, State#client.subscriptions)
      };
    {unsubscribe, _Subs} = Request ->
      self() ! {send, construct_message(Request, State)},
      State;
    {unsubscribed, MessageId} ->
      State#client.owner_pid ! {mqtt, subscription, updated},
      PendingUnsubs = (get_stored_message(MessageId, State))#mqtt.hint,
      State#client{
        subscriptions = remove_subscriptions(PendingUnsubs, State#client.subscriptions)
      };
    disconnect ->
      self() ! {send, construct_message(disconnect, State)},
      State;
    {send, Message} when is_record(Message, mqtt) ->
      ?LOG({send,pretty(Message)}),
      ok = send(Message, State),
      if
        Message#mqtt.dup =:= 0, Message#mqtt.qos > 0, Message#mqtt.qos < 3 ->
          put_stored_message(Message, State);
        true ->
          do_not_keep
      end,
      State;
    {ack, MessageId} ->
      delete_stored_message(MessageId, State),
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
    Msg ->
      ?LOG({client, unexpected_message, Msg}),
      State
  end,
  client_loop(NewState).

default_client_id() ->
  {{Y,Mon,D},{H,Min,S}} = erlang:localtime(),
  lists:flatten(io_lib:format("~B-~2.10.0B-~2.10.0B-~2.10.0B-~2.10.0B-~2.10.0B-~w",[Y, Mon, D, H, Min, S, self()])).

apply_options([], State) ->
  State;
apply_options([{keepalive, KeepAlive}|T], State) ->
  apply_options(T, State#client{keepalive = KeepAlive});
apply_options([{retry, Retry}|T], State) ->
  apply_options(T, State#client{retry = Retry});
apply_options([{client_id, ClientId}|T], State) ->
  apply_options(T, State#client{client_id = ClientId});
apply_options([{clean_start, Flag}|T], State) ->
  apply_options(T, State#client{clean_start = Flag});
apply_options([Will|T], State) when is_record(Will, will) ->
  apply_options(T, State#client{will = Will});
apply_options([UnknownOption|_T], _State) ->
  exit({connect, unknown_option, UnknownOption}).

add_subscriptions([], [], Subscriptions) ->
  Subscriptions;
add_subscriptions([{sub, Topic, _QoS} = S|Subs], [Q|QoS], Subscriptions) ->
  NewSubs = [S#sub{qos = Q}|lists:keydelete(Topic, 2, Subscriptions)],
  add_subscriptions(Subs, QoS, NewSubs).

remove_subscriptions([], Subscriptions) ->
  Subscriptions;
remove_subscriptions([{sub, Topic, _QoS}|Unsubs], Subscriptions) ->
  remove_subscriptions(Unsubs, lists:keydelete(Topic, 2, Subscriptions)).

construct_message({connect, _Host, _Port, _Options}, State) ->
  CleanStart = case State#client.clean_start of
    true ->
      1;
    false ->
      0
  end,
  {WillFlag, WillQoS, WillRetain, Payload} = case State#client.will of
    {will, WillTopic, WillMessage, WillOptions} ->
      {QoS, Retain} = get_publish_options(WillOptions),
      {
        1, QoS, Retain,
        list_to_binary([encode_string(State#client.client_id), encode_string(WillTopic), encode_string(WillMessage)])
      }; 
    undefined ->
      {0, 0, 0, encode_string(State#client.client_id)}
  end,
  #mqtt{
    type = ?CONNECT,
    variable_header = list_to_binary([
      encode_string(?PROTOCOL_NAME),
      <<?PROTOCOL_VERSION:8/big, ?UNUSED:2, WillRetain:1, WillQoS:2/big, WillFlag:1, CleanStart:1, ?UNUSED:1, (State#client.keepalive):16/big>>]
    ),
    payload = Payload
  };
construct_message({publish, Topic, Payload, Options}, State) ->
  {QoS, Retain} = get_publish_options(Options),
  Message = if
    QoS =:= 0 ->
      #mqtt{
        type = ?PUBLISH,
        retain = Retain,
        variable_header = encode_string(Topic),
        payload = encode_string(Payload)
      };
    QoS =:= 1; QoS =:= 2 ->
      MessageId = id_get_incr(State),
      #mqtt{
        id = MessageId,
        type = ?PUBLISH,
        qos = QoS,
        retain = Retain,
        variable_header = list_to_binary([encode_string(Topic), <<MessageId:16/big>>]),
        payload = encode_string(Payload)
      }
  end,
  Message;
construct_message({puback, MessageId}, _State) ->
  #mqtt{
    type = ?PUBACK,
    variable_header = <<MessageId:16/big>>
  };
construct_message({subscribe, Subs}, State) ->
  MessageId = id_get_incr(State),
  #mqtt{
    id = MessageId,
    type = ?SUBSCRIBE, 
    qos = 1,
    variable_header = <<MessageId:16/big>>,
    payload = list_to_binary( lists:flatten( lists:map(fun({sub, Topic, RequestedQoS}) -> [encode_string(Topic), <<?UNUSED:6, RequestedQoS:2/big>>] end, Subs))),
    hint = Subs
  };
construct_message({unsubscribe, Subs}, State) ->
  MessageId = id_get_incr(State),
  #mqtt{
    id = MessageId,
    type = ?UNSUBSCRIBE,
    qos = 1,
    variable_header = <<MessageId:16/big>>,
    payload = list_to_binary(lists:map(fun({sub, T, _Q}) -> encode_string(T) end, Subs)),
    hint = Subs
  };
construct_message(pingreq, _State) ->
  #mqtt{
    type = ?PINGREQ
  };
construct_message({pubrec, MessageId}, _State) ->
  #mqtt{
    type = ?PUBREC,
    variable_header = <<MessageId:16/big>>
  };
construct_message({pubrel, MessageId}, _State) ->
  #mqtt{
    type = ?PUBREL,
    variable_header = <<MessageId:16/big>>
  };
construct_message({pubcomp, MessageId}, _State) ->
  #mqtt{
    type = ?PUBCOMP,
    variable_header = <<MessageId:16/big>>
  };
construct_message(disconnect, _State) ->
  #mqtt{
    type = ?DISCONNECT
  };
construct_message(Request, _State) ->
  exit({contruct_message, unknown_type, Request}).

get_publish_options(Options) ->
  Retain = case lists:member(retain, Options) of
    true ->
      1;
    false ->
      0
  end,
  QoS = case lists:keysearch(qos, 1, Options) of
    {value, {qos, Q}} ->
      Q;
    false ->
      0
  end,
  {QoS, Retain}.

decode_message(Message, _Rest)
  when is_record(Message, mqtt), Message#mqtt.type =:= ?CONNACK ->
  Message;
decode_message(Message, _Rest)
  when is_record(Message, mqtt), Message#mqtt.type =:= ?PINGRESP ->
  Message;
decode_message(Message, Rest)
  when is_record(Message, mqtt), Message#mqtt.type =:= ?PUBLISH, Message#mqtt.qos =:= 0 ->
  {<<TopicLength:16/big>>, _} = split_binary(Rest, 2),
  {<<_:16, Topic/binary>> = VariableHeader, Payload} = split_binary(Rest, 2 + TopicLength),
  Message#mqtt{variable_header = VariableHeader, payload = Payload, hint = {undefined, binary_to_list(Topic), Payload}};
decode_message(Message, Rest)
  when is_record(Message, mqtt), Message#mqtt.type =:= ?PUBLISH, Message#mqtt.qos >0, Message#mqtt.qos < 3 ->
  {<<TopicLength:16/big>>, _} = split_binary(Rest, 2),
  {<<_:16, Topic:TopicLength/binary, MessageId:16/big>> = VariableHeader, Payload} = split_binary(Rest, 4 + TopicLength),
   Message#mqtt{variable_header = VariableHeader, payload = Payload, hint = {MessageId, binary_to_list(Topic), Payload}};
decode_message(Message, Rest)
    when
      is_record(Message, mqtt), Message#mqtt.type =:= ?PUBACK;
      is_record(Message, mqtt), Message#mqtt.type =:= ?PUBREC;
      is_record(Message, mqtt), Message#mqtt.type =:= ?PUBREL;
      is_record(Message, mqtt), Message#mqtt.type =:= ?PUBCOMP ->
  <<MessageId:16/big>> = Rest,
  Message#mqtt{variable_header = Rest, hint = MessageId};
decode_message(Message, Rest)
    when is_record(Message, mqtt), Message#mqtt.type =:= ?SUBACK ->
  {VariableHeader, Payload} = split_binary(Rest, 2),
  <<MessageId:16/big>> = VariableHeader,
  GrantedQoS  = lists:map(fun(Item) ->
      <<_:6, QoS:2/big>> = <<Item>>,
      QoS
    end,
    binary_to_list(Payload)
  ),
  Message#mqtt{variable_header = VariableHeader, payload = Payload, hint={MessageId, GrantedQoS}};
decode_message(Message, Rest)
    when is_record(Message, mqtt), Message#mqtt.type =:= ?UNSUBACK ->
  <<MessageId:16/big>> = Rest,
  Message#mqtt{variable_header = Rest, hint = MessageId};
decode_message(Message, Rest) ->
  exit({decode_message, unexpected_message, {Message, Rest}}).

put_stored_message(Message, State) ->
  State#client.store_pid ! {store, put, Message}.

get_all_stored_messages(State) ->
  State#client.store_pid ! {store, get, all, self()},
  receive
    {store, get, ok, Results} ->
      Results
  end.

get_stored_message(MessageId, State) ->
  State#client.store_pid ! {store, get, MessageId, self()},
  receive
    {store, get, ok, Result} ->
      Result;
    {store, get, not_found} ->
      exit({store, get, MessageId, not_found})
  end.

delete_stored_message(MessageId, State) ->
  State#client.store_pid ! {store, delete, MessageId}.

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

send_ping(State) ->
  ?LOG({send, ping}),
  State#client.pid ! {send, construct_message(pingreq, State)}.

resend_unack(State) ->
  ?LOG({resend_unack}),
  lists:foreach(fun({_Id, Message}) ->
      State#client.pid ! {send, Message#mqtt{dup = 1}}
    end,
    get_all_stored_messages(State)
  ).
    
recv_loop(State) ->
  FixedHeader = recv(1, State),
  RemainingLength = recv_length(State),
  Rest = recv(RemainingLength, State),
  Message = decode_message(decode_fixed_header(FixedHeader), Rest),
  ?LOG({recv, pretty(Message)}),
  ok = process(Message, State),
  recv_loop(State).

process(#mqtt{type = ?CONNACK}, State) ->
  ?LOG({recv, process, connack}),
  State#client.pid ! connected,
  ok;
process(#mqtt{type = ?PINGRESP}, _State) ->
  ?LOG({recv, process, pingresp}),
  ok;
process(#mqtt{type = ?PUBLISH, qos = 0} = Message, State) ->
  {_, Topic, Payload} = Message#mqtt.hint,
  ?LOG({recv, publish, Topic, Payload, qos, Message#mqtt.qos}),
  State#client.pid ! {published, Topic, Payload},
  ok;
process(#mqtt{type = ?PUBLISH} = Message, State) ->
  {MessageId, Topic, Payload} = Message#mqtt.hint,
  ?LOG({recv, publish, Topic, Message#mqtt.payload, qos, Message#mqtt.qos}),
  State#client.pid ! {published, Topic, Payload},
  case Message#mqtt.qos of
    1 ->
      State#client.pid ! {send, construct_message({puback, MessageId}, State)};
    2 ->
      State#client.pid ! {send, construct_message({pubrec, MessageId}, State)}
  end,
  ok;
process(#mqtt{type = ?PUBACK} = Message, State) ->
  MessageId = Message#mqtt.hint,
  ?LOG({recv, puback, MessageId}),
  State#client.pid ! {ack, MessageId},
  ok;
process(#mqtt{type = ?PUBREC} = Message, State) ->
  MessageId = Message#mqtt.hint,
  ?LOG({recv, pubrec, MessageId}),
  State#client.pid ! {send, construct_message({pubrel, MessageId}, State)},
  ok;
process(#mqtt{type = ?PUBREL} = Message, State) ->
  MessageId = Message#mqtt.hint,
  ?LOG({recv, pubrel, MessageId}),
  State#client.pid ! {send, construct_message({pubcomp, MessageId}, State)},
  ok;
process(#mqtt{type = ?PUBCOMP} = Message, State) ->
  MessageId = Message#mqtt.hint,
  ?LOG({recv, pubcomp, MessageId}),
  State#client.pid ! {ack, MessageId},
  ok;
process(#mqtt{type = ?SUBACK} = Message, State) ->
  ?LOG({recv, suback, Message#mqtt.hint}),
  State#client.pid ! {subscribed, Message#mqtt.hint},
  {MessageId, _} = Message#mqtt.hint,
  State#client.pid ! {ack, MessageId},
  ok;
process(#mqtt{type = ?UNSUBACK} = Message, State) ->
  MessageId = Message#mqtt.hint,
  ?LOG({recv, unsuback, id, MessageId}),
  State#client.pid ! {unsubscribed, MessageId},
  State#client.pid !{ack, MessageId},
  ok;
process(Msg, _State) ->
  ?LOG({recv, process, unexpected_message, Msg}),
  ok.

recv_length(State) ->
  recv_length(recv(1, State), 1, 0, State).
recv_length(<<0:1, Length:7>>, Multiplier, Value, _State) ->
  Value + Multiplier * Length;
recv_length(<<1:1, Length:7>>, Multiplier, Value, State) ->
  recv_length(recv(1, State), Multiplier * 128, Value + Multiplier * Length, State).

send_length(Length, State) when Length div 128 > 0 ->
  Digit = Length rem 128,
  send(<<1:1, Digit:7/big>>, State),
  send_length(Length div 128, State);
send_length(Length, State) ->
  Digit = Length rem 128,
  send(<<0:1, Digit:7/big>>, State).
 
encode_fixed_header(Message) when is_record(Message, mqtt) ->
  <<(Message#mqtt.type):4/big, (Message#mqtt.dup):1, (Message#mqtt.qos):2/big, (Message#mqtt.retain):1>>.

decode_fixed_header(Byte) ->
  <<Type:4/big, Dup:1, QoS:2/big, Retain:1>> = Byte,
  #mqtt{type = Type, dup = Dup, qos = QoS, retain = Retain}.
  
encode_string(String) ->
  Bytes = list_to_binary(String),
  Length = size(Bytes),
  <<Length:16/big, Bytes/binary>>.

recv(Length, State) ->
  case gen_tcp:recv(State#client.socket, Length) of
    {ok, Bytes} ->
%%    ?LOG({recv,bytes,binary_to_list(Bytes)}),
      Bytes;
    {error, Reason} ->
      ?LOG({recv, socket, error, Reason}),
      exit(Reason)
  end.
send(Message, State) when is_record(Message, mqtt) ->
%%?LOG({sending,header}),
  ok = send(encode_fixed_header(Message), State),
%%?LOG({sending,length}),
  ok = send_length(size(Message#mqtt.variable_header) + size(Message#mqtt.payload), State),
%%?LOG({sending,variable_hedder}),
  ok = send(Message#mqtt.variable_header, State),
%%?LOG({sending,payload}),
  ok = send(Message#mqtt.payload, State),
  ok;
send(<<>>, _State) ->
%%?LOG({send, no_bytes}),
  ok;
send(Bytes, State) when is_binary(Bytes) ->
%%?LOG({send,bytes,binary_to_list(Bytes)}),
  case gen_tcp:send(State#client.socket, Bytes) of
    ok ->
      ok;
    {error, Reason} ->
      ?LOG({send, socket, error, Reason}),
      exit(Reason)
  end.

pretty(Message) when is_record(Message, mqtt) ->
  lists:flatten(
    io_lib:format(
      "<matt id=~w type=~w dup=~w qos=~w retain=~w variable_header=~w payload=~w, hint=~w>", 
      [Message#mqtt.id, Message#mqtt.type, Message#mqtt.dup, Message#mqtt.qos, Message#mqtt.retain, Message#mqtt.variable_header, Message#mqtt.payload, Message#mqtt.hint]
    )
  ).
