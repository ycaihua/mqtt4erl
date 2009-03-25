-module(mqtt_core).
-author(hellomatty@gmail.com).

%%
%% An erlang client for MQTT (http://www.mqtt.org/)
%%

-include_lib("mqtt.hrl").

-compile(export_all).

-export([set_connect_options/1, set_publish_options/1, decode_message/2, recv_loop/2, encode_message/1, send/2]).

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
set_connect_options([{connect_timeout, Timeout}|T], Options) ->
  set_connect_options(T, Options#connect_options{connect_timeout = Timeout});
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

decode_message(#mqtt{type = ?CONNECT} = Message, Rest) ->
  <<ProtocolNameLength:16/big, _/binary>> = Rest,
  {VariableHeader, Payload} = split_binary(Rest, 2 + ProtocolNameLength + 4),
  <<_:16, ProtocolName:ProtocolNameLength/binary, ProtocolVersion:8/big, _:2, WillRetain:1, WillQoS:2/big, WillFlag:1, CleanStart:1, _:1, KeepAlive:16/big>> = VariableHeader,
  {ClientId, Will} = case WillFlag of
    1 ->
      [C, WT, WM] = decode_strings(Payload),
      W = #will{
        topic = WT,
        message = WM,
        publish_options = #publish_options{qos = WillQoS, retain = WillRetain}
      },
      {C, W};
    0 ->
      [C] = decode_strings(Payload),
      {C, undefined}
  end,
  Message#mqtt{
    arg = #connect_options{
      client_id = ClientId,
      protocol_name = binary_to_list(ProtocolName),
      protocol_version = ProtocolVersion,
      clean_start = CleanStart =:= 1,
      will = Will,
      keepalive = KeepAlive
    }
  };
decode_message(#mqtt{type = ?CONNACK} = Message, Rest) ->
  <<_:8, ResponseCode:8/big>> = Rest,
  Message#mqtt{arg = ResponseCode};
decode_message(#mqtt{type = ?PINGRESP} = Message, _Rest) ->
  Message;
decode_message(#mqtt{type = ?PINGREQ} = Message, _Rest) ->
  Message;
decode_message(#mqtt{type = ?PUBLISH, qos = 0} = Message, Rest) ->
  {<<TopicLength:16/big>>, _} = split_binary(Rest, 2),
  {<<_:16, Topic/binary>>, Payload} = split_binary(Rest, 2 + TopicLength),
  Message#mqtt{
    arg = {binary_to_list(Topic), binary_to_list(Payload)}
  };
decode_message(#mqtt{type = ?PUBLISH} = Message, Rest) ->
  {<<TopicLength:16/big>>, _} = split_binary(Rest, 2),
  {<<_:16, Topic:TopicLength/binary, MessageId:16/big>>, Payload} = split_binary(Rest, 4 + TopicLength),
   Message#mqtt{
    id = MessageId,
    arg = {binary_to_list(Topic), binary_to_list(Payload)}
  };
decode_message(#mqtt{type = Type} = Message, Rest)
    when
      Type =:= ?PUBACK;
      Type =:= ?PUBREC;
      Type =:= ?PUBREL;
      Type =:= ?PUBCOMP ->
  <<MessageId:16/big>> = Rest,
  Message#mqtt{
    arg = MessageId
  };
decode_message(#mqtt{type = ?SUBSCRIBE} = Message, Rest) ->
  {<<MessageId:16/big>>, Payload} = split_binary(Rest, 2),
  Message#mqtt{
    id = MessageId,
    arg = decode_subs(Payload, [])
  };
decode_message(#mqtt{type = ?SUBACK} = Message, Rest) ->
  {<<MessageId:16/big>>, Payload} = split_binary(Rest, 2),
  GrantedQoS  = lists:map(fun(Item) ->
      <<_:6, QoS:2/big>> = <<Item>>,
      QoS
    end,
    binary_to_list(Payload)
  ),
  Message#mqtt{
    arg = {MessageId, GrantedQoS}
  };
decode_message(#mqtt{type = ?UNSUBSCRIBE} = Message, Rest) ->
  {<<MessageId:16/big>>, Payload} = split_binary(Rest, 2),
  Message#mqtt{
    id = MessageId,
    arg = {MessageId, lists:map(fun(T) -> #sub{topic = T} end, decode_strings(Payload))}
  };
decode_message(#mqtt{type = ?UNSUBACK} = Message, Rest) ->
  <<MessageId:16/big>> = Rest,
  Message#mqtt{
    arg = MessageId
  };
decode_message(#mqtt{type = ?DISCONNECT} = Message, _Rest) ->
  Message;
decode_message(Message, Rest) ->
  exit({decode_message, unexpected_message, {Message, Rest}}).

decode_subs(<<>>, Subs) ->
  lists:reverse(Subs);
decode_subs(Bytes, Subs) ->
  <<TopicLength:16/big, _/binary>> = Bytes,
  <<_:16, Topic:TopicLength/binary, ?UNUSED:6, QoS:2/big, Rest/binary>> = Bytes,
  decode_subs(Rest, [#sub{topic = binary_to_list(Topic), qos = QoS}|Subs]). 

recv_loop(Socket, Pid) ->
  FixedHeader = recv(1, Socket),
  RemainingLength = recv_length(Socket),
  Rest = recv(RemainingLength, Socket),
  Message = decode_message(decode_fixed_header(FixedHeader), Rest),
  ?LOG({recv, pretty(Message)}),
  Pid ! Message,
  recv_loop(Socket, Pid).

encode_message(#mqtt{type = ?CONNACK, arg = ReturnCode}) ->
  {<<?UNUSED:8, ReturnCode:8/big>>,<<>>};
encode_message(#mqtt{type = ?CONNECT, arg = Options}) ->
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
  {
    list_to_binary([
      encode_string(Options#connect_options.protocol_name),
      <<(Options#connect_options.protocol_version)/big>>, 
      <<?UNUSED:2, WillRetain:1, WillQoS:2/big, WillFlag:1, CleanStart:1, ?UNUSED:1, (Options#connect_options.keepalive):16/big>>
    ]),
    Payload
  };
encode_message(#mqtt{type = ?PUBLISH, arg = {Topic, Payload}} = Message) ->
  if
    Message#mqtt.qos =:= 0 ->
        {
          encode_string(Topic),
          encode_string(Payload)
        };
    Message#mqtt.qos > 0 ->
        {
          list_to_binary([encode_string(Topic), <<(Message#mqtt.id):16/big>>]),
          encode_string(Payload)
        }
  end;
encode_message(#mqtt{type = ?PUBACK, arg = MessageId}) ->
  {
    <<MessageId:16/big>>,
    <<>>
  };
encode_message(#mqtt{type = ?SUBSCRIBE, arg = Subs} = Message) ->
  {
    <<(Message#mqtt.id):16/big>>,
    list_to_binary( lists:flatten( lists:map(fun({sub, Topic, RequestedQoS}) -> [encode_string(Topic), <<?UNUSED:6, RequestedQoS:2/big>>] end, Subs)))
  };
encode_message(#mqtt{type = ?SUBACK, arg = {MessageId, Subs}}) ->
  {
    <<MessageId:16/big>>,
    list_to_binary(lists:map(fun(S) -> <<?UNUSED:6, (S#sub.qos):2/big>> end, Subs))
  }; 
encode_message(#mqtt{type = ?UNSUBSCRIBE, arg = Subs} = Message) ->
  {
    <<(Message#mqtt.id):16/big>>,
    list_to_binary(lists:map(fun({sub, T, _Q}) -> encode_string(T) end, Subs))
  };
encode_message(#mqtt{type = ?UNSUBACK, arg = MessageId}) ->
  {<<MessageId:16/big>>, <<>>}; 
encode_message(#mqtt{type = ?PINGREQ}) ->
  {<<>>, <<>>};
encode_message(#mqtt{type = ?PINGRESP}) ->
  {<<>>, <<>>};
encode_message(#mqtt{type = ?PUBREC, arg = MessageId}) ->
  {<<MessageId:16/big>>, <<>>};
encode_message(#mqtt{type = ?PUBREL, arg = MessageId}) ->
  {<<MessageId:16/big>>, <<>>};
encode_message(#mqtt{type = ?PUBCOMP, arg = MessageId}) ->
  {<<MessageId:16/big>>, <<>>};
encode_message(#mqtt{type = ?DISCONNECT}) ->
  {<<>>, <<>>};
encode_message(#mqtt{} = Message) ->
  exit({encode_message, unknown_type, Message}).

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
 
encode_fixed_header(Message) when is_record(Message, mqtt) ->
  <<(Message#mqtt.type):4/big, (Message#mqtt.dup):1, (Message#mqtt.qos):2/big, (Message#mqtt.retain):1>>.

decode_fixed_header(Byte) ->
  <<Type:4/big, Dup:1, QoS:2/big, Retain:1>> = Byte,
  #mqtt{type = Type, dup = Dup, qos = QoS, retain = Retain}.
 
command_for_type(Type) ->
  case Type of
    ?CONNECT -> connect;
    ?CONNACK -> connack;
    ?PUBLISH -> publish;
    ?PUBACK  -> puback;
    ?PUBREC -> pubrec;
    ?PUBREL -> pubrel;
    ?PUBCOMP -> pubcomp;
    ?SUBSCRIBE -> subscribe;
    ?SUBACK -> suback;
    ?UNSUBSCRIBE -> unsubscribe;
    ?UNSUBACK -> unsuback;
    ?PINGREQ -> pingreq;
    ?PINGRESP -> pingresp;
    ?DISCONNECT -> disconnect;
    _ -> unknown
  end.
 
encode_string(String) ->
  Bytes = list_to_binary(String),
  Length = size(Bytes),
  <<Length:16/big, Bytes/binary>>.

decode_strings(Bytes) when is_binary(Bytes) ->
  decode_strings(Bytes, []).
decode_strings(<<>>, Strings) ->
  lists:reverse(Strings);
decode_strings(<<Length:16/big, _/binary>> = Bytes, Strings) ->
  <<_:16, Binary:Length/binary, Rest/binary>> = Bytes,
  decode_strings(Rest, [binary_to_list(Binary)|Strings]).

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

send(#mqtt{} = Message, Socket) ->
%%?LOG({mqtt_core, send, pretty(Message)}),
  {VariableHeader, Payload} = encode_message(Message),
  ok = send(encode_fixed_header(Message), Socket),
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

pretty(Message) when is_record(Message, mqtt) ->
  lists:flatten(
    io_lib:format(
      "<matt id=~w type=~w (~w) dup=~w qos=~w retain=~w arg=~w>", 
      [Message#mqtt.id, Message#mqtt.type, command_for_type(Message#mqtt.type), Message#mqtt.dup, Message#mqtt.qos, Message#mqtt.retain, Message#mqtt.arg]
    )
  ).
