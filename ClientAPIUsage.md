Start the message persistence service:

```
mqtt_store:start().
```

> # Connecting #

> ## Simple ##
```
mqtt_client:connect("172.16.50.128").
```

> returns `{ok, Pid`} on success

This call is synchronous.

> ## Advanced ##
```
mqtt_client:connect("172.16.50.128", Port, Options).
```

where:
  * `Port` is the port to connect to, eg `1883`
  * `Options` is an array which can contain:
    * `{connect_timeout, Seconds` specifies how long the client should wait for a socket connection to the broker, or for the broker to acknowledge the connection attempt
    * `{client_id, ClientId`} specifies the id to connect as
    * `{keepalive, Seconds`} specifies how frequently in seconds to ping the broker eg `10` - note the client will explode if it does not receive a ping response before the next ping
    * `{retry, Seconds`} how frequently in seconds to resend QoS 1 or 2 messages that have not been acknowledged by the broker
    * `{clean_start, true`} forces the broker to drop pending messages and subscriptions for this client id
    * `{will, WillTopic, WillMessage, WillOptions`} specifies a message the broker will pass on when the client disconnects. `WillOptions` is an array that can contain the following elements:
      * `{qos, QoS`} indicating the quality of service to be used in delivering the message, either `0`, `1` or `2`
      * `{retain, true`} to indicate that the message should be retained, and delivered automatically to clients subscribing to the designated topic

> # Subscribing to a Topic #
> ## Simple ##

```
mqtt_client:subscribe(R, Topic).
```

where:
  * `Pid` is a client pid returned by `mqtt_client:connect`
  * `Topic` is the name of a topic to subscribe to, eg `"topic"`.

This call is synchronous.

> ## Advanced ##

```
gen_server:call(Pid, {mqtt_client, subscribe, [Topics]}).
```

where:
  * `Pid` is a client pid returned by `mqtt_client:connect`
  * `Topics` is an array of `sub` records, which feature the following fields:
    * `topic` the name of a topic to subscribe to, eg `"topic"`
    * `qos` the quality of service to request, either `0`, `1` or `2`

The definition for the `sub` record type is included in `include/mqtt.hrl`.

This call is asynchronous - your process will be sent a message of the form

```
{mqtt_client, subscribed, Subscriptions|
```

when the broker acknowledges your request. `Subscriptions` is an array of `sub` records containing the topics you requested a subscription for, and the quality of service levels you were granted by the broker.

> # Unsubscribing to a Topic #
> ## Simple ##

```
mqtt_client:unsubscribe(Pid, Topic).
```

where:
  * `Pid` is a client pid returned by `mqtt_client:connect`.
  * `Topic` is the name of a topic to unsubscribe from, eg `"topic"`.

This call is synchronous.

> ## Advanced ##

```
gen_server:call(Pid, {mqtt_client, unsubscribe, [Topics]}).
```

where:
  * `Pid` is a client pid returned by `mqtt_client:connect`
  * `Topics` is an array of `sub` records, which feature the following fields:
    * `topic` the name of a topic to subscribe to, eg `"topic"`

The definition for the `sub` record type is included in `include/mqtt.hrl`.

This call is asynchronous - your process will be sent a message of the form

```
{mqtt_client, unsubscribed, Subscriptions|
```

when the broker acknowledges your request. `Subscriptions` is an array of `sub` records containing the topics you requested to be unsubscribed from.

> # Publishing a Message #
> ## Simple ##

```
mqtt_client:publish(Pid, Topic, Message).
```

where:
  * `Pid` is a client pid returned by `mqtt_client:connect`
  * `Topic` is the name of the topic to publish to, eg `"topic"`
  * `Message` is the content of the message to send, eg `"message"`

This will publish a non-retained message, with a quality of service of 0 (no delivery guarantees)

> ## Advanced ##

```
mqtt_client:publish(Pid, Topic, Message, Options).
```

where:
  * `Pid` is a client pid returned by `mqtt_client:connect`
  * `Topic` is the name of the topic to publish to, eg `"topic"`
  * `Message` is the content of the message to send, eg `"message"`
  * `Options` is an array which may contain the following elements:
    * `{qos, QoS`} indicating the quality of service to be used in delivering the message, either `0`, `1` or `2`
    * `{retain, true`} to indicate that the message should be retained, and delivered automatically to clients subscribing to the designated topic

Note that the return of this call indicates that the message has been sent, not that it has been received by clients.

For messages sent with a quality of service greater than 0, the client will manage the acknowledgement conversation with the broker, and automatically resending unacknowleged messsages.

> # Receiving a Message #
> ## Simple ##

```
mqtt_client:get_message(Pid).
```

where:
  * `Pid` is a client pid returned by `mqtt_client:connect`

This call is synchronous and will block until a message is received.

The client will automatically handle the protocol conversations necessary for receiving messages with a quality of service level greater than 0.

> ## Advanced ##

When the client receives a message it will send it to your process where you may receive it asynchronously.

Messages are received as `mqtt` records. You can find the definition in `include/mqtt.hrl`.

> # Disconnecting #

```
mqtt_client:disconnect(Pid).
```

where:
  * `Pid` is a client pid returned by `mqtt_client:connect`.