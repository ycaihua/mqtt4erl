-module(store).

%%
%% An erlang client for MQTT (http://www.mqtt.org/)
%%

-include_lib("mqtt.hrl").

-export([start/0, put_message/2, get_all_messages/1, get_message/2, delete_message/2]).

start() ->
  store_loop(dict:new()).

put_message(Message, StorePid) ->
  StorePid ! {store, put, Message, self()},
  receive
    {store, ok} ->
      ok
  end.

get_all_messages(StorePid) ->
  StorePid ! {store, get, all, self()},
  receive
    {store, get, ok, Results} ->
      Results
  end.

get_message(MessageId, StorePid) ->
  StorePid ! {store, get, MessageId, self()},
  receive
    {store, get, ok, Result} ->
      Result;
    {store, get, not_found} ->
      exit({store, get, MessageId, not_found})
  end.

delete_message(MessageId, StorePid) ->
  StorePid ! {store, delete, MessageId, self()},
  receive
    {store, ok} ->
      ok
  end.

store_loop(State) ->
  NewState = receive
    {store, put, Message, FromPid} when Message#mqtt.id /= undefined ->
      ?LOG({message_store, put, Message#mqtt.id}),
      FromPid ! {store, ok},
      dict:store(Message#mqtt.id, Message, State);
    {store, get, all, FromPid} ->
      ?LOG({message_store, get, all}),
      FromPid ! {store, get, ok, dict:to_list(State)},
      State;
    {store, get, MessageId, FromPid} ->
      ?LOG({message_store, get, MessageId}),
      case dict:find(MessageId, State) of
        {ok, Message} ->
          ?LOG({message_store, get, MessageId, ok}),
          FromPid ! {store, get, ok, Message};
        error ->
          FromPid ! {store, get, not_found}
      end,
      State;
    {store, delete, MessageId, FromPid} ->
      ?LOG({message_store, delete, MessageId}),
      FromPid ! {store, ok},
      dict:erase(MessageId, State);
    Msg ->
      ?LOG({message_store, unexpected_message, Msg}),
      State
  end,
  store_loop(NewState).
