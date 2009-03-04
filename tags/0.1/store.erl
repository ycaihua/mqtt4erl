-module(store).

%%
%% An erlang client for MQTT (http://www.mqtt.org/)
%%

-include_lib("mqtt.hrl").

-export([start/0]).

start() ->
  store_loop(dict:new()).

store_loop(State) ->
  NewState = receive
    {store, put, Message} when Message#mqtt.id /= undefined ->
      ?LOG({message_store, put, Message#mqtt.id}),
      dict:store(Message#mqtt.id, Message, State);
    {store, get, all, FromPid} ->
      FromPid ! {message_store, get, ok, dict:to_list(State)},
      State;
    {store, get, MessageId, FromPid} ->
      case dict:find(MessageId, State) of
        {ok, Message} ->
          ?LOG({message_store, get, MessageId, ok}),
          FromPid ! {store, get, ok, Message};
        error ->
          FromPid ! {store, get, not_found}
      end,
      State;
    {store, delete, MessageId} ->
      ?LOG({message_store, delete, MessageId}),
      dict:erase(MessageId, State);
    Msg ->
      ?LOG({message_store, unexpected_message, Msg}),
      State
  end,
  store_loop(NewState).