-module(store).

%%
%% An erlang client for MQTT (http://www.mqtt.org/)
%%

-include_lib("mqtt.hrl").

-export([start/2, start_link/2, put_message/2, get_all_messages/1, get_message/2, delete_message/2, pass_messages/2]).

-record(store, {
  handle,
  messages
}).

start(ClientId, StoreId) ->
  Handle = {ClientId, StoreId},
  case global:whereis_name(Handle) of
    undefined ->
      Pid = spawn(fun() ->
        InitialState = case file:consult(filename(Handle)) of
          {ok, [State]} ->
            ?LOG({store, Handle, init_from, disk}),
            State;
          _ ->
            ?LOG({store, Handle, init_from, scratch}),
            #store{handle = Handle, messages = dict:new()}
        end,
        store_loop(InitialState)
      end),
      case global:register_name(Handle, Pid) of
        yes ->
          Pid;
        _ ->
          exit({global, register, failed, Handle})
      end;
    ExistingPid ->
      ExistingPid
  end.

start_link(ClientId, StoreId) ->
  Pid = start(ClientId, StoreId),
  link(Pid),
  Pid.

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

pass_messages(ToPid, StorePid) ->
  StorePid ! {store, pass_messages, ToPid, self()},
  receive
    {store, ok} ->
      ok
  end.

store_loop(State) ->
  NewState = receive
    {store, put, Message, FromPid} when Message#mqtt.id /= undefined ->
      ?LOG({put, Message#mqtt.id}),
      FromPid ! {store, ok},
      State#store{messages = dict:store(Message#mqtt.id, Message, State#store.messages)};
    {store, get, all, FromPid} ->
      ?LOG({get, all}),
      FromPid ! {store, get, ok, dict:to_list(State#store.messages)},
      State;
    {store, get, MessageId, FromPid} ->
      ?LOG({message_store, get, MessageId}),
      case dict:find(MessageId, State#store.messages) of
        {ok, Message} ->
          ?LOG({get, MessageId, ok}),
          FromPid ! {store, get, ok, Message};
        error ->
          FromPid ! {store, get, not_found}
      end,
      State;
    {store, delete, MessageId, FromPid} ->
      ?LOG({delete, MessageId}),
      FromPid ! {store, ok},
      State#store{messages = dict:erase(MessageId, State#store.messages)};
    {store, pass_messages, ToPid, FromPid} ->
      ?LOG({passing_messages, to, ToPid}),
      lists:foreach(fun({_, M}) ->
        ToPid ! M
      end, dict:to_list(State#store.messages)),
      FromPid ! {store, ok},
      State#store{messages = dict:new()};
    {'EXIT', FromPid, Reason} ->
      ?LOG({trap_exit, got, Reason, from, FromPid}),
      unconsult(filename(State#store.handle), State),
      exit(Reason);
    Message ->
      ?LOG({unexpected_message, Message}),
      State
  end,
  store_loop(NewState).

filename({ClientId, StoreId}) ->
  lists:flatten(io_lib:format("~s_~s", [ClientId, atom_to_list(StoreId)])).

unconsult(FName, Term) ->
    {ok, Fd} = file:open(FName, [write]),
    io:write(Fd, Term),
    io:put_chars(Fd, ".\n"),
    file:close(Fd),
    ok.
