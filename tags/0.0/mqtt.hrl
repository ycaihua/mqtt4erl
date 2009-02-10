%%
%% An erlang client for MQTT (http://www.mqtt.org/)
%%

-define(LOG(Msg), io:format("{~p:~p}: ~p~n", [?MODULE, ?LINE, Msg])).

-define(MQTT_PORT, 1883).

-define(PROTOCOL_NAME, "MQIsdp").
-define(PROTOCOL_VERSION, 3).

-define(UNUSED, 0).

-define(DEFAULT_KEEPALIVE, 120).
-define(DEFAULT_RETRY, 120).
-define(DEFAULT_CONNECT_TIMEOUT, 5).

-define(CONNECT, 1).
-define(CONNACK, 2).
-define(PUBLISH, 3).
-define(PUBACK, 4).
-define(PUBREC, 5).
-define(PUBREL, 6).
-define(PUBCOMP, 7).
-define(SUBSCRIBE, 8).
-define(SUBACK, 9).
-define(UNSUBSCRIBE, 10).
-define(UNSUBACK, 11).
-define(PINGREQ, 12).
-define(PINGRESP, 13).
-define(DISCONNECT, 14).

-record(client, {
  pid,
  id_pid,
  owner_pid,
  recv_pid,
  store_pid,
  socket,
  status = not_connected,
  client_id,
  subscriptions = [],
  keepalive = ?DEFAULT_KEEPALIVE,
  retry = ?DEFAULT_RETRY,
  connect_timeout = ?DEFAULT_CONNECT_TIMEOUT,
  clean_start = true,
  will,
  ping_timer,
  retry_timer
}).

-record(mqtt, {
  id,
  type,
  dup = 0,
  qos = 0,
  retain = 0,
  variable_header = <<>>,
  payload = <<>>,
  hint
}).

-record(sub, {
  topic,
  qos = 0
}).

-record(will, {
  topic,
  message,
  options = []
}).
