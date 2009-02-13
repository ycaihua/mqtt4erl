-module(mqtt_core).
-author(hellomatty@gmail.com).

%%
%% An erlang client for MQTT (http://www.mqtt.org/)
%%

-include_lib("mqtt.hrl").

-export([construct_message/1, construct_message/2,  set_connect_options/1, set_publish_options/1, decode_message/2, recv_loop/1, send_ping/1, send/2]).

construct_message(Request) ->
  construct_message(Request, #mqtt{}).
construct_message({connack, ReturnCode}, Prototype) ->
  Prototype#mqtt{
    type = ?CONNACK,
    variable_header = <<?UNUSED:8, ReturnCode:8/big>>
  };
construct_message({connect, _Host, _Port, #connect_options{} = Options}, Prototype) ->
  ?LOG({options, Options}),
  CleanStart = case Options#connect_options.clean_start of
    true ->
      1;
    false ->
      0
  end,
  {WillFlag, WillQoS, WillRetain, Payload} = case Options#connect_options.will of
    {will, WillTopic, WillMessage, WillOptions} ->
      O = set_publish_options(WillOptions),
      {
        1, O#publish_options.qos, O#publish_options.retain,
        list_to_binary([encode_string(Options#connect_options.client_id), encode_string(WillTopic), encode_string(WillMessage)])
      }; 
    undefined ->
      {0, 0, 0, encode_string(Options#connect_options.client_id)}
  end,
  Prototype#mqtt{
    type = ?CONNECT,
    variable_header = list_to_binary([
      encode_string(?PROTOCOL_NAME),
      <<?PROTOCOL_VERSION:8/big, ?UNUSED:2, WillRetain:1, WillQoS:2/big, WillFlag:1, CleanStart:1, ?UNUSED:1, (Options#connect_options.keepalive):16/big>>]
    ),
    payload = Payload
  };
construct_message({publish, Topic, Payload, Options}, Prototype) ->
  Message = if
    Options#publish_options.qos =:= 0 ->
      Prototype#mqtt{
        type = ?PUBLISH,
        retain = Options#publish_options.retain,
        variable_header = encode_string(Topic),
        payload = encode_string(Payload)
      };
    Options#publish_options.qos =:= 1; Options#publish_options.qos =:= 2 ->
      MessageId = Prototype#mqtt.id,
      Prototype#mqtt{
        type = ?PUBLISH,
        qos = Options#publish_options.qos,
        retain = Options#publish_options.retain,
        variable_header = list_to_binary([encode_string(Topic), <<MessageId:16/big>>]),
        payload = encode_string(Payload)
      }
  end,
  Message;
construct_message({puback, MessageId}, Prototype) ->
  Prototype#mqtt{
    type = ?PUBACK,
    variable_header = <<MessageId:16/big>>
  };
construct_message({subscribe, Subs}, Prototype) ->
  MessageId = Prototype#mqtt.id,
  Prototype#mqtt{
    id = MessageId,
    type = ?SUBSCRIBE, 
    qos = 1,
    variable_header = <<MessageId:16/big>>,
    payload = list_to_binary( lists:flatten( lists:map(fun({sub, Topic, RequestedQoS}) -> [encode_string(Topic), <<?UNUSED:6, RequestedQoS:2/big>>] end, Subs))),
    hint = Subs
  };
construct_message({suback, {MessageId, Subs}}, Prototype) ->
  Prototype#mqtt{
    type = ?SUBACK,
    variable_header = <<MessageId:16/big>>,
    payload = list_to_binary(lists:map(fun(S) -> <<?UNUSED:6, (S#sub.qos):2/big>> end, Subs))
  }; 
construct_message({unsubscribe, Subs}, Prototype) ->
  MessageId = Prototype#mqtt.id,
  Prototype#mqtt{
    id = MessageId,
    type = ?UNSUBSCRIBE,
    qos = 1,
    variable_header = <<MessageId:16/big>>,
    payload = list_to_binary(lists:map(fun({sub, T, _Q}) -> encode_string(T) end, Subs)),
    hint = Subs
  };
construct_message(pingreq, Prototype) ->
  Prototype#mqtt{
    type = ?PINGREQ
  };
construct_message(pingresp, Prototype) ->
  Prototype#mqtt{
    type = ?PINGRESP
  };
construct_message({pubrec, MessageId}, Prototype) ->
  Prototype#mqtt{
    type = ?PUBREC,
    variable_header = <<MessageId:16/big>>
  };
construct_message({pubrel, MessageId}, Prototype) ->
  Prototype#mqtt{
    type = ?PUBREL,
    variable_header = <<MessageId:16/big>>
  };
construct_message({pubcomp, MessageId}, Prototype) ->
  Prototype#mqtt{
    type = ?PUBCOMP,
    variable_header = <<MessageId:16/big>>
  };
construct_message(disconnect, Prototype) ->
  Prototype#mqtt{
    type = ?DISCONNECT
  };
construct_message(Request, _Prototype) ->
  exit({contruct_message, unknown_type, Request}).

set_connect_options(Options) ->
  set_connect_options(Options, #connect_options{}).
set_connect_options([], Options) ->
  Options;
set_connect_options([{keepalive, KeepAlive}|T], Options) ->
  set_connect_options(T, Options#connect_options{keepalive = KeepAlive});
set_connect_options([{retry, Retry}|T], Options) ->
  set_connect_options(T, Options#connect_options{retry = Retry});
set_connect_options([{client_id, ClientId}|T], Options) ->
  set_connect_options(T, Options#connect_options{client_id = ClientId});
set_connect_options([{clean_start, Flag}|T], Options) ->
  set_connect_options(T, Options#connect_options{clean_start = Flag});
set_connect_options([#will{} = Will|T], Options) ->
  set_connect_options(T, Options#connect_options{will = Will});
set_connect_options([UnknownOption|_T], _Options) ->
  exit({connect, unknown_option, UnknownOption}).

set_publish_options(Options) ->
  set_publish_options(Options, #publish_options{}).
set_publish_options([], Options) ->
  Options;
set_publish_options([{qos, QoS}|T], Options) when QoS >= 0, QoS =< 2 ->
  set_publish_options(T, Options#publish_options{qos = QoS});
set_publish_options([{retain, true}|T], Options) ->
  set_publish_options(T, Options#publish_options{retain = 1});
set_publish_options([{retain, false}|T], Options) ->
  set_publish_options(T, Options#publish_options{retain = 0});
set_publish_options([UnknownOption|_T], _Options) ->
  exit({unknown, publish_option, UnknownOption}).

decode_message(#mqtt{type = ?CONNECT} = Message, _Rest) ->
  Message;
decode_message(#mqtt{type = ?CONNACK} = Message, Rest) ->
  <<_:8, ResponseCode:8/big>> = Rest,
  Message#mqtt{variable_header = Rest, hint = ResponseCode};
decode_message(#mqtt{type = ?PINGRESP} = Message, _Rest) ->
  Message;
decode_message(#mqtt{type = ?PINGREQ} = Message, _Rest) ->
  Message;
decode_message(#mqtt{type = ?PUBLISH, qos = 0} = Message, Rest) ->
  {<<TopicLength:16/big>>, _} = split_binary(Rest, 2),
  {<<_:16, Topic/binary>> = VariableHeader, Payload} = split_binary(Rest, 2 + TopicLength),
  Message#mqtt{
    variable_header = VariableHeader,
    payload = Payload,
    hint = {undefined, binary_to_list(Topic), Payload}
  };
decode_message(#mqtt{type = ?PUBLISH} = Message, Rest) ->
  {<<TopicLength:16/big>>, _} = split_binary(Rest, 2),
  {<<_:16, Topic:TopicLength/binary, MessageId:16/big>> = VariableHeader, Payload} = split_binary(Rest, 4 + TopicLength),
   Message#mqtt{
    id = MessageId,
    variable_header = VariableHeader,
    payload = Payload,
    hint = {MessageId, binary_to_list(Topic), Payload}
  };
decode_message(#mqtt{type = Type} = Message, Rest)
    when
      Type =:= ?PUBACK;
      Type =:= ?PUBREC;
      Type =:= ?PUBREL;
      Type =:= ?PUBCOMP ->
  <<MessageId:16/big>> = Rest,
  Message#mqtt{
    variable_header = Rest,
    hint = MessageId
  };
decode_message(#mqtt{type = ?SUBSCRIBE} = Message, Rest) ->
  {VariableHeader, Payload} = split_binary(Rest, 2),
  <<MessageId:16/big>> = VariableHeader,
  Message#mqtt{
    id = MessageId,
    variable_header = VariableHeader,
    payload = Payload,
    hint = {MessageId, decode_subs(Payload, [])}
  };
decode_message(#mqtt{type = ?SUBACK} = Message, Rest) ->
  {VariableHeader, Payload} = split_binary(Rest, 2),
  <<MessageId:16/big>> = VariableHeader,
  GrantedQoS  = lists:map(fun(Item) ->
      <<_:6, QoS:2/big>> = <<Item>>,
      QoS
    end,
    binary_to_list(Payload)
  ),
  Message#mqtt{
    variable_header = VariableHeader,
    payload = Payload,
    hint = {MessageId, GrantedQoS}
  };
decode_message(#mqtt{type = ?UNSUBACK} = Message, Rest) ->
  <<MessageId:16/big>> = Rest,
  Message#mqtt{
    variable_header = Rest,
    hint = MessageId
  };
decode_message(Message, Rest) ->
  exit({decode_message, unexpected_message, {Message, Rest}}).

decode_subs(<<>>, Subs) ->
  lists:reverse(Subs);
decode_subs(Bytes, Subs) ->
  <<TopicLength:16/big, _/binary>> = Bytes,
  <<_:16, Topic:TopicLength/binary, ?UNUSED:6, QoS:2/big, Rest/binary>> = Bytes,
  decode_subs(Rest, [#sub{topic = binary_to_list(Topic), qos = QoS}|Subs]). 

recv_loop(Context) ->
  FixedHeader = recv(1, Context),
  RemainingLength = recv_length(Context),
  Rest = recv(RemainingLength, Context),
  Message = decode_message(decode_fixed_header(FixedHeader), Rest),
  ?LOG({recv, pretty(Message)}),
  ok = process(Message, Context),
  recv_loop(Context).

process(#mqtt{type = ?CONNECT}, Context) ->
  ?LOG({recv, process, connect}),
  Context#context.pid ! connect,
  ok;
process(#mqtt{type = ?CONNACK} = Message, Context) ->
  ?LOG({recv, process, connack}),
  ReturnCode = Message#mqtt.hint,
  case ReturnCode of
    0 ->
      Context#context.pid ! connected;
    1 ->
      exit({connect_refused, wrong_protocol_version});
    2 ->
      exit({connect_refused, identifier_rejectedn});
    3 ->
      exit({connect_refused, broker_unavailable})
  end,
  ok;
process(#mqtt{type = ?PINGRESP}, _Context) ->
  ?LOG({recv, process, pingresp}),
  ok;
process(#mqtt{type = ?PINGREQ}, Context) ->
  ?LOG({recv, process, pingreq}),
  send(construct_message(pingresp), Context),
  ok;
process(#mqtt{type = ?PUBLISH, qos = 0} = Message, Context) ->
  ?LOG({recv, publish, Message}),
  Context#context.pid ! {received, Message},
  ok;
process(#mqtt{type = ?PUBLISH} = Message, Context) ->
  {MessageId, _, _} = Message#mqtt.hint,
  ?LOG({recv, publish, Message}),
  Context#context.pid ! {received, Message},
  case Message#mqtt.qos of
    1 ->
      send(construct_message({puback, MessageId}), Context);
    2 ->
      send(construct_message({pubrec, MessageId}), Context)
  end,
  ok;
process(#mqtt{type = ?PUBACK} = Message, Context) ->
  MessageId = Message#mqtt.hint,
  ?LOG({recv, puback, MessageId}),
  Context#context.pid ! {ack, MessageId},
  ok;
process(#mqtt{type = ?PUBREC} = Message, Context) ->
  MessageId = Message#mqtt.hint,
  ?LOG({recv, pubrec, MessageId}),
  send(construct_message({pubrel, MessageId}), Context),
  ok;
process(#mqtt{type = ?PUBREL} = Message, Context) ->
  MessageId = Message#mqtt.hint,
  ?LOG({recv, pubrel, MessageId}),
  Context#context.pid ! {release, MessageId},
  send(construct_message({pubcomp, MessageId}), Context),
  ok;
process(#mqtt{type = ?PUBCOMP} = Message, Context) ->
  MessageId = Message#mqtt.hint,
  ?LOG({recv, pubcomp, MessageId}),
  Context#context.pid ! {ack, MessageId},
  ok;
process(#mqtt{type = ?SUBSCRIBE} = Message, Context) ->
  ?LOG({recv, subscribe, Message#mqtt.hint}),
  Context#context.pid ! {subscribe, Message#mqtt.hint},
  ok;
process(#mqtt{type = ?SUBACK} = Message, Context) ->
  ?LOG({recv, suback, Message#mqtt.hint}),
  Context#context.pid ! {subscribed, Message#mqtt.hint},
  {MessageId, _} = Message#mqtt.hint,
  Context#context.pid ! {ack, MessageId},
  ok;
process(#mqtt{type = ?UNSUBSCRIBE} = Message, Context) ->
  ?LOG({recv, unsubscribe, Message#mqtt.hint}),
  Context#context.pid ! {unsubscribe, Message#mqtt.hint},
  ok;
process(#mqtt{type = ?UNSUBACK} = Message, Context) ->
  MessageId = Message#mqtt.hint,
  ?LOG({recv, unsuback, id, MessageId}),
  Context#context.pid ! {unsubscribed, MessageId},
  Context#context.pid !{ack, MessageId},
  ok;
process(Msg, _Context) ->
  ?LOG({recv, process, unexpected_message, Msg}),
  ok.

send_ping(Context) ->
  ?LOG({send, ping}),
  mqtt_core:send(mqtt_core:construct_message(pingreq), Context).

%%put_stored_message(Message, Context) ->
%%  Context#context.store_pid ! {store, put, Message}.

%%get_stored_message(MessageId, Context) ->
%%  Context#context.store_pid ! {store, get, MessageId, self()},
%%  receive
%%    {store, get, ok, Result} ->
%%      Result;
%%    {store, get, not_found} ->
%%      exit({store, get, MessageId, not_found})
%%  end.

recv_length(Context) ->
  recv_length(recv(1, Context), 1, 0, Context).
recv_length(<<0:1, Length:7>>, Multiplier, Value, _Context) ->
  Value + Multiplier * Length;
recv_length(<<1:1, Length:7>>, Multiplier, Value, Context) ->
  recv_length(recv(1, Context), Multiplier * 128, Value + Multiplier * Length, Context).

send_length(Length, Context) when Length div 128 > 0 ->
  Digit = Length rem 128,
  send(<<1:1, Digit:7/big>>, Context),
  send_length(Length div 128, Context);
send_length(Length, Context) ->
  Digit = Length rem 128,
  send(<<0:1, Digit:7/big>>, Context).
 
encode_fixed_header(Message) when is_record(Message, mqtt) ->
  <<(Message#mqtt.type):4/big, (Message#mqtt.dup):1, (Message#mqtt.qos):2/big, (Message#mqtt.retain):1>>.

decode_fixed_header(Byte) ->
  <<Type:4/big, Dup:1, QoS:2/big, Retain:1>> = Byte,
  #mqtt{type = Type, dup = Dup, qos = QoS, retain = Retain}.
  
encode_string(String) ->
  Bytes = list_to_binary(String),
  Length = size(Bytes),
  <<Length:16/big, Bytes/binary>>.

recv(Length, Context) ->
  case gen_tcp:recv(Context#context.socket, Length) of
    {ok, Bytes} ->
%%    ?LOG({recv,bytes,binary_to_list(Bytes)}),
      Bytes;
    {error, Reason} ->
      ?LOG({recv, socket, error, Reason}),
      exit(Reason)
  end.

send(#mqtt{} = Message, Context) ->
  ?LOG({send, Message}),
  if
    Message#mqtt.dup =:= 0, Message#mqtt.qos > 0, Message#mqtt.qos < 3 ->
      %% put_stored_message(Message, Context);
      keep;
    true ->
      do_not_keep
  end,
  ok = send(encode_fixed_header(Message), Context),
  ok = send_length(size(Message#mqtt.variable_header) + size(Message#mqtt.payload), Context),
  ok = send(Message#mqtt.variable_header, Context),
  ok = send(Message#mqtt.payload, Context),
  ok;
send(<<>>, _Context) ->
%%?LOG({send, no_bytes}),
  ok;
send(Bytes, Context) when is_binary(Bytes) ->
%%?LOG({send,bytes,binary_to_list(Bytes)}),
  case gen_tcp:send(Context#context.socket, Bytes) of
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
