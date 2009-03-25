-module(mqtt_client).
-behaviour(gen_server).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).
-export([connect/1, connect/3, subscribe/2, unsubscribe/2, publish/3, publish/4, get_message/1, disconnect/1, deliver/2, start/2, default_client_id/0]).

-include_lib("mqtt.hrl").

connect(Host) ->
  connect(Host, ?MQTT_PORT, []).
connect(Host, Port, Options) ->
  O = mqtt_core:set_connect_options(Options),
  case gen_tcp:connect(Host, Port, [binary, {active, false}, {packet, raw}, {keepalive, true}], O#connect_options.connect_timeout * 1000) of
    {ok, Socket} ->
      {ok, ClientPid} = start(Socket, self()),
      ok = gen_server:call(ClientPid, {?MODULE, connect, O}),
      receive
        {?MODULE, connected} ->
          {ok, ClientPid}
        after
          O#connect_options.connect_timeout * 1000 ->
            exit(ClientPid, cancel),
            {error, connect_timeout}
      end;
    {error, Reason} ->
      {error, Reason}
  end.

subscribe(Pid, Topic) ->
  ok = gen_server:call(Pid, {?MODULE, subscribe, [{sub, Topic, 0}]}),
  receive
    {?MODULE, subscribed, _} ->
      ok
  end.

unsubscribe(Pid, Topic) ->
  ok = gen_server:call(Pid, {?MODULE, unsubscribe, [{sub, Topic, 0}]}),
  receive
    {?MODULE, unsubscribed, _} ->
      ok
  end.

publish(Pid, Topic, Message) ->
  publish(Pid, Topic, Message, []).
publish(Pid, Topic, Message, Options) ->
  ok = gen_server:call(Pid, {?MODULE, publish, Topic, Message, Options}).

get_message(_Pid) ->
  receive
    Message when is_record(Message, mqtt) ->
      Message
  end.

disconnect(Pid) ->
  ok = gen_server:call(Pid, {?MODULE, disconnect}),
  receive
    {?MODULE, disconnected} ->
      ok
  end.

deliver(Pid, Message) when is_record(Message, mqtt) ->
  gen_server:call(Pid, {?MODULE, '_deliver', Message}).

start(Socket, OwnerPid) ->
  gen_server:start(?MODULE, [Socket, OwnerPid], []).

init([Socket, OwerPid]) ->
  process_flag(trap_exit, true),
  Pid = self(),
  RecvPid = spawn_link(fun() -> recv_loop(Socket, Pid) end),
  ?LOG({init, Pid, RecvPid}),
  {ok, #mqtt_client{
    socket = Socket,
    owner_pid = OwerPid,
    id_pid = id:start_link()
  }}.

handle_call({?MODULE, connect, Options}, _FromPid, State) ->
  ok = send(#mqtt{type = ?CONNECT, arg = Options}, State),
  {reply, ok, State#mqtt_client{connect_options = Options}};
handle_call({?MODULE, subscribe, Subs}, _FromPid, State) ->
  ok = send(#mqtt{type = ?SUBSCRIBE, qos = 1, arg = Subs}, State),
  {reply, ok, State};
handle_call({?MODULE, unsubscribe, Unsubs}, _FromPid, State) ->
  ok = send(#mqtt{type = ?UNSUBSCRIBE, qos = 1, arg = Unsubs}, State),
  {reply, ok, State};
handle_call({?MODULE, publish, Topic, Message, Opts}, _FromPid, State) ->
  Publish = mqtt_core:set_publish_options(Opts),
  ok = send(#mqtt{type = ?PUBLISH, retain = Publish#publish_options.retain, qos = Publish#publish_options.qos, arg = {Topic, Message}}, State),
  {reply, ok, State};
handle_call({?MODULE, disconnect}, _FromPid, State) ->
  ok = send(#mqtt{type = ?DISCONNECT}, State),
  {stop, disconnect, State};
handle_call({?MODULE, '_deliver', Message}, _FromPid, State) ->
  send(Message, State),
  {reply, ok, State};
handle_call(#mqtt{type = ?CONNACK, arg = 0}, _FromPid, State) ->
  gen_server:cast(self(), {?MODULE, start}),
  notify_owner({?MODULE, connected}, State),
  {reply, ok, State};
handle_call(#mqtt{type = ?CONNACK, arg = 1}, _FromPid, State) ->
  {stop, {connect_refused, wrong_protocol_version}, State};
handle_call(#mqtt{type = ?CONNACK, arg = 2}, _FromPid, State) ->
  {stop, {connect_refused, identifier_rejectedn}, State};
handle_call(#mqtt{type = ?CONNACK, arg = 3}, _FromPid, State) ->
  {stop, {connect_refused, broker_unavailable}, State};
handle_call(#mqtt{type = ?CONNECT, arg = Arg}, _FromPid, State)
    when Arg#connect_options.protocol_version /= ?PROTOCOL_VERSION ->
  send(#mqtt{type = ?CONNACK, arg = 1}, State),
  {stop, {connect_refused, wrong_protocol_version}, State};
handle_call(#mqtt{type = ?CONNECT, arg = Arg}, _FromPid, State)
    when length(Arg#connect_options.client_id) < 1;
    length(Arg#connect_options.client_id) > 23 ->
  ok = send(#mqtt{type = ?CONNACK, arg = 2}, State),
  {stop, {connect_refused, invalid_clientid}, State};
handle_call(#mqtt{type = ?CONNECT, arg = Opts}, _FromPid, State) ->
  ClientId = Opts#connect_options.client_id,
  mqtt_registry:register_client(ClientId, self()),
  case Opts#connect_options.clean_start of
    true ->
      ?LOG({clean_start, ClientId}),
      mqtt_registry:unsubscribe(ClientId, all),
      mqtt_store:delete_messages({ClientId, all});
    false ->
      mqtt_store:pass_messages({ClientId, pending}, self())
  end,
  notify_owner({?MODULE, escrow, Opts#connect_options.will}, State),
  ok = send(#mqtt{type = ?CONNACK, arg = 0}, State),
  gen_server:cast(self(), {?MODULE, start}),
  {reply, ok, State#mqtt_client{connect_options = Opts}};
handle_call(#mqtt{type = ?PINGRESP}, _FromPid, State) ->
  timer:cancel(State#mqtt_client.pong_timer),
  {reply, ok, State};
handle_call(#mqtt{type = ?PINGREQ}, _FromPid, State)  ->
  ok = send(#mqtt{type = ?PINGRESP}, State),
  {reply, ok, State};
handle_call(#mqtt{type = ?SUBSCRIBE, id = MessageId, arg = Subs}, _FromPid, State) ->
  ok = mqtt_registry:subscribe(client_id(State), Subs),
  ok = send(#mqtt{type = ?SUBACK, arg = {MessageId, Subs}}, State),
  {reply, ok, State};
handle_call(#mqtt{type = ?SUBACK, arg = {MessageId, GrantedQoS}}, _FromPid, State) ->
  SubMessage = mqtt_store:get_message({client_id(State), outbox}, MessageId),
  PendingSubs = SubMessage#mqtt.arg,
  notify_owner({?MODULE, subscribed, merge_subs(PendingSubs, GrantedQoS)}, State),
  mqtt_store:delete_message({client_id(State), outbox}, MessageId),
  {reply, ok, State};
handle_call(#mqtt{type = ?UNSUBSCRIBE, id = MessageId, arg = {_, Unsubs}}, _FromPid, State) ->
  ok = mqtt_registry:unsubscribe(client_id(State), Unsubs),
  ok = send(#mqtt{type = ?UNSUBACK, arg = MessageId}, State),
  {reply, ok, State};
handle_call(#mqtt{type = ?UNSUBACK, arg = MessageId}, _FromPid, State) ->
  UnsubMessage = mqtt_store:get_message({client_id(State), outbox}, MessageId),
  notify_owner({?MODULE, unsubscribed, UnsubMessage#mqtt.arg}, State),
  mqtt_store:delete_message({client_id(State), outbox}, MessageId),
  {reply, ok, State};
handle_call(#mqtt{type = ?PUBLISH, qos = 0} = Message, _FromPid, State) ->
  notify_owner(Message, State),
  {reply, ok, State};
handle_call(#mqtt{type = ?PUBLISH, qos = 1} = Message, _FromPid, State) ->
  notify_owner(Message, State),
  send(#mqtt{type = ?PUBACK, arg = Message#mqtt.id}, State),
  {reply, ok, State};
handle_call(#mqtt{type = ?PUBACK, arg = MessageId}, _FromPid, State) ->
  mqtt_store:delete_message({client_id(State), outbox}, MessageId),
  {reply, ok, State};
handle_call(#mqtt{type = ?PUBLISH, qos = 2} = Message, _FromPid, State) ->
  mqtt_store:put_message({client_id(State), inbox}, Message),
  send(#mqtt{type = ?PUBREC, arg = Message#mqtt.id}, State),
  {reply, ok, State};
handle_call(#mqtt{type = ?PUBREC, arg = MessageId}, _FromPid, State) ->
  send(#mqtt{type = ?PUBREL, arg = MessageId}, State),
  {reply, ok, State};
handle_call(#mqtt{type = ?PUBREL, arg = MessageId}, _FromPid, State) ->
  Message = mqtt_store:get_message({client_id(State), inbox}, MessageId),
  notify_owner(Message, State),
  mqtt_store:delete_message({client_id(State), inbox}, MessageId),
  send(#mqtt{type = ?PUBCOMP, arg = MessageId}, State),
  {reply, ok, State};
handle_call(#mqtt{type = ?PUBCOMP, arg = MessageId}, _FromPid, State) ->
  mqtt_store:delete_message({client_id(State), outbox}, MessageId),
  {reply, ok, State};
handle_call(#mqtt{type = ?DISCONNECT}, _FromPid, State) ->
  {stop, client_disconnected, State};
handle_call(Message, _FromPid, State) ->
  ?LOG({unexpected_message, Message}),
  {reply, ok, State}.

handle_cast({?MODULE, send_ping}, State) ->
  ?LOG(ping),
  send(#mqtt{type = ?PINGREQ}, State),
  {ok, PongTimer} = timer:exit_after(ping_interval(State), self(), no_response_to_ping),
  {noreply, State#mqtt_client{pong_timer = PongTimer}};

handle_cast({?MODULE, resend_unack}, State) ->
  ?LOG(resend_unack),
  lists:foreach(fun(Message) ->
    send(Message#mqtt{dup = 1}, State) 
  end, mqtt_store:get_all_messages({client_id(State), outbox})),
  {noreply, State};
handle_cast({?MODULE, start}, State) ->
  ?LOG(start),
  {ok, PingTimer} = timer:apply_interval(ping_interval(State), gen_server, cast, [self(), {?MODULE, send_ping}]),
  {ok, RetryTimer} = timer:apply_interval(retry_interval(State), gen_server, cast, [self(),{?MODULE,  resend_unack}]),
  {noreply, State#mqtt_client{
    ping_timer = PingTimer,
    retry_timer = RetryTimer
  }};
handle_cast(Message, State) ->
  ?LOG({unexpected_message, Message}),
  {noreply, State}.

handle_info({'EXIT', FromPid, Reason}, State) ->
  ?LOG({'EXIT', from, FromPid, Reason}),
  {stop, Reason, State};
handle_info(Message, State) ->
  ?LOG({unexpected_info, Message}),
  {noreply, State}.

terminate(Reason, State) ->
  ?LOG({terminate, Reason}),
  notify_owner({?MODULE, disconnected}, State),
  ok.
code_change(_OldVersion, State, _Extra) -> {ok, State}.

notify_owner(Message, State) when is_pid(State#mqtt_client.owner_pid) ->
  ?LOG({notify_owner, Message}),
  State#mqtt_client.owner_pid ! Message;
notify_owner(_Message, _State) ->
  ?LOG({notify, noop}),
  noop.

retry_interval(State) ->
  1000 * (State#mqtt_client.connect_options)#connect_options.retry.

ping_interval(State) ->
  1000 * (State#mqtt_client.connect_options)#connect_options.keepalive.

client_id(State) ->
  (State#mqtt_client.connect_options)#connect_options.client_id.

merge_subs(PendingSubs, GrantedQoS) ->
  merge_subs(PendingSubs, GrantedQoS, []).
merge_subs([], [], GrantedSubs) ->  lists:reverse(GrantedSubs);
merge_subs([{sub, Topic, _}|PendingTail], [QoS|GrantedTail], GrantedSubs) ->
  merge_subs(PendingTail, GrantedTail, [{sub, Topic, QoS}|GrantedSubs]).

send(#mqtt{} = Message, State) ->
  ?LOG({send, mqtt_core:pretty(Message)}),
  SendableMessage = if
    Message#mqtt.dup =:= 0, Message#mqtt.qos > 0 ->
      IdMessage = Message#mqtt{id = id:get_incr(State#mqtt_client.id_pid)},
      ok = mqtt_store:put_message({client_id(State), outbox}, IdMessage),
      IdMessage;
    true ->
      Message
  end,
  Socket = State#mqtt_client.socket,
  {VariableHeader, Payload} = mqtt_core:encode_message(SendableMessage),
  ok = send(mqtt_core:encode_fixed_header(SendableMessage), Socket),
  ok = send_length(size(VariableHeader) + size(Payload), Socket),
  ok = send(VariableHeader, Socket),
  ok = send(Payload, Socket),
  ok;
send(<<>>, _Socket) ->
%%?LOG({send, no_bytes}),
  ok;
send(Bytes, Socket) when is_binary(Bytes) ->
%%?LOG({send,bytes,binary_to_list(Bytes)}),
  case gen_tcp:send(Socket, Bytes) of
    ok ->
      ok;
    {error, Reason} ->
      ?LOG({send, socket, error, Reason}),
      exit(Reason)
  end.

recv_loop(Socket, Pid) ->
  FixedHeader = recv(1, Socket),
  RemainingLength = recv_length(Socket),
  Rest = recv(RemainingLength, Socket),
  Message = mqtt_core:decode_message(mqtt_core:decode_fixed_header(FixedHeader), Rest),
  ?LOG({recv, mqtt_core:pretty(Message)}),
  ok = gen_server:call(Pid, Message),
  recv_loop(Socket, Pid).

recv_length(Socket) ->
  recv_length(recv(1, Socket), 1, 0, Socket).
recv_length(<<0:1, Length:7>>, Multiplier, Value, _Socket) ->
  Value + Multiplier * Length;
recv_length(<<1:1, Length:7>>, Multiplier, Value, Socket) ->
  recv_length(recv(1, Socket), Multiplier * 128, Value + Multiplier * Length, Socket).

send_length(Length, Socket) when Length div 128 > 0 ->
  Digit = Length rem 128,
  send(<<1:1, Digit:7/big>>, Socket),
  send_length(Length div 128, Socket);
send_length(Length, Socket) ->
  Digit = Length rem 128,
  send(<<0:1, Digit:7/big>>, Socket).
 
recv(0, _Socket) ->
  <<>>;
recv(Length, Socket) ->
  case gen_tcp:recv(Socket, Length) of
    {ok, Bytes} ->
%%    ?LOG({recv,bytes,binary_to_list(Bytes)}),
      Bytes;
    {error, Reason} ->
      ?LOG({recv, socket, error, Reason}),
      exit(Reason)
  end.

default_client_id() ->
  {{_Y,Mon,D},{H,Min,S}} = erlang:localtime(),
  lists:flatten(io_lib:format(
    "~2.10.0B~2.10.0B~2.10.0B~2.10.0B~2.10.0B~w",
    [Mon, D, H, Min, S, self()]
  )).
