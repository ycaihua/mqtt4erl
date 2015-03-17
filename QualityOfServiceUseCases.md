Some use cases to understand how quality of service levels should affect behaviour of MQTT clients and brokers.

# Client #
## QOS 0 - zero or more deliveries ##
### Normal Flow ###
  * client sends a QoS 0 message

## QOS 1 - one or more deliveries ##
### Normal Flow ###
  * client sends a QoS 1 message (PUBLISH, SUBSCRIBE, UNSUBSCRIBE) and stores in Persistent Outbox
  * client receives {PUB,SUB,UNSUB}ACK and removes message from Outbox

### Death before Acknowledgement ###
  * client sends a QoS 1 message (PUBLISH, SUBSCRIBE, UNSUBSCRIBE) and stores in Persistent Outbox
  * client dies before {PUB,SUB,UNSUB}ACK received
  * client restarts with same client id and recovers Persistent Outbox
  * client resends messages in Outbox
  * client receives {PUB,SUB,UNSUB}ACK and removes message from Outbox

### Transfer Interrupted ###
  * client sends a QoS 1 message (PUBLISH, SUBSCRIBE, UNSUBSCRIBE) and stores in Persistent Outbox
  * broker dies before message is transferred
  * client reconnects with same client id
  * client resends messages in Outbox
  * client receives {PUB,SUB,UNSUB}ACK and removes message from Outbox

## QOS 2 - exactly one delivery ##
### Normal Flow ###
  * client sends a QoS 2 PUBLISH message and stores in Persistent Outbox
  * broker replies with PUBREC
  * client sends PUBREL
  * broker responds with PUBCOMP
  * client receives PUBCOMP and deletes message from Persistent Outbox

# Broker #
## QOS 0 - zero or more deliveries ##
### Normal Flow ###
  * client A connects and subscribes to topic T
  * client B connects and publishes to topic T with QoS 0
  * broker delivers to all connected subscribers, namely client A

### Client Subscribes, then Disconnects ###
  * client A connects and subscribes to topic T
  * client A disconnects
  * client B connects and publishes to topic T with QoS 0
  * broker gets list of interested connected subscribers for topic T, namely client A
  * noop: there are no connected subscribers to topic T

## QOS 1 - one or more deliveries ##
### Normal Flow ###
  * client A connects and subscribes to topic T, requesting QoS 1
  * client B connects and publishes to topic T with QoS 1, placing message in Persistent Outbox
  * broker acknowledges receipt with a PUBACK to client B
  * client B removes message from Persistent Outbox
  * broker delivers message to client A, placing message in Persistent Outbox
  * client A acknowledges by sending a PUBACK to the broker
  * broker removes message from its Persistent Outbox

### Published QoS > Requested QoS ###
  * client A connects and subscribes to topic T, requesting QoS 0
  * client B connects and publishes to topic T with QoS 1, placing message in Persistent Outbox
  * broker acknowledges receipt with a PUBACK to client B
  * client B removes message from Persistent Outbox
  * broker delivers message as QoS 0 to client A (see QoS 0 use cases above)

### Client Subscribes, then Disconnects, then Reconnects ###
  * client A connects and subscribes to topic T, requesting QoS 1
  * client A disconnects
  * client B connects and publishes to topic T with QoS 1, placing message in Persistent Outbox
  * broker acknowledges message with a PUBACK sent to client B
  * client B removes message from Persistent Outbox
  * client A is not connected: broker marks message as 'pending' for client A
  * client A connects
  * broker delivers 'pending' message to client A and places it in Persistent Outbox
  * client A acknowledges message with a PUBACK
  * broker removes message from Persistent Outbox

## QOS 2 - exactly one delivery ##
### Normal Flow ###
  * client A connects and subscribes to topic T requesting a QoS of 2
  * broker receives message from client B with QoS 2 destined for topic T, places it in Persistent inbox
  * broker replies to client B with PUBREC
  * client B replies with PUBREL
  * broker receives PUBREL and removes the message from the Inbox
  * broker acknowledges client B with a PUBCOMP
  * broker retrieves list of subscribers to topic T, namely client A
  * broker delivers message to client A and adds to Outbox
  * client A replies with a PUBREC
  * broker replies with a PUBREL
  * client A replies with a PUBCOMP
  * broker receives PUBCOMP and removes messae from Outbox

### Subscriber Connects, Disconnects and Reconnects ###
  * client A connects and subscribes to topic T requesting a QoS of 2
  * broker receives message from client B with QoS 2 destined for topic T
  * broker replies to client B with PUBREC
  * client B replies with PUBREL
  * broker receives PUBREL and may release the message
  * broker acknowledges client B with a PUBCOMP
  * client A disconnects
  * broker retrieves list of subscribers to topic T, namely client A
  * broker marks message as 'pending' for client A
  * client A reconnects
  * broker delivers 'pending' message to client A
  * client A replies with a PUBREC
  * broker replies with a PUBREL
  * client A replies with a PUBCOMP
  * broker receives PUBCOMP and removes messae from Outbox