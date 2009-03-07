-module(mqtt_store).
-behaviour(gen_server).

%%
%% An erlang client for MQTT (http://www.mqtt.org/)
%%

-include_lib("mqtt.hrl").

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-export([start_link/0, put_message/2, get_all_messages/1, get_message/2, delete_message/2, pass_messages/2]).

-record(store, {
  table
}).

-define(TABLE, messages.dets).

start_link() -> gen_server:start_link({global, ?MODULE}, ?MODULE, [], []).

init([]) ->
  ?LOG({dets, opening, ?TABLE}),
  {ok, Table} = dets:open_file(?TABLE, [{type, bag}]),
  process_flag(trap_exit, true),
  {ok, #store{table = Table}}.

put_message(Handle, Message) ->
  gen_server:call({global, ?MODULE}, {put, Handle, Message}, 1).

get_all_messages(Handle) ->
  gen_server:call({global, ?MODULE}, {get, Handle, all}, 1).

get_message(Handle, MessageId) ->
  gen_server:call({global, ?MODULE}, {get, Handle, MessageId}, 1).

delete_message(Handle, MessageId) ->
  gen_server:call({global, ?MODULE}, {delete, Handle, MessageId}, 1).

pass_messages(Handle, ToPid) ->
  gen_server:call({global, ?MODULE}, {pass, Handle, ToPid}, 1).

handle_call({put, Handle, Message}, _FromPid, State) when Message#mqtt.id /= undefined ->
  {reply, dets:insert(State#store.table, {Handle, Message#mqtt.id, Message}), State};
handle_call({get, Handle, all}, _FromPid, State) ->
  {reply, lists:map(fun({_, _, Message}) ->
    Message
  end, dets:lookup(State#store.table, Handle)), State};
handle_call({get, Handle, MessageId}, _FromPid, State) ->
  [[Message]] = dets:match(State#store.table, {Handle, MessageId, '$1'}),
  {reply, Message, State};
handle_call({delete, Handle, MessageId}, _FromPid, State) ->
  [[Message]] = dets:match(State#store.table, {Handle, MessageId, '$1'}),
  {reply, dets:delete_object(State#store.table, {Handle, MessageId, Message}), State};
handle_call({pass, Handle, ToPid}, _FromPid, State) ->
  lists:foreach(fun({_, _, Message} = Object) ->
    ToPid ! Message,
    dets:delete_object(State#store.table, Object)
  end, dets:lookup(State#store.table, Handle)),
  {reply, ok, State};
handle_call(Message, _FromPid, State) ->
  ?LOG({unexpected_message, Message}),
  {reply, ok, State}.

handle_cast(Message, State) ->
  ?LOG({unexpected_message, Message}),
  {noreply, State}.

handle_info(_, State) ->
  {noreply, State}.

terminate(_Reason, State) ->
  ?LOG({dets, closing, ?TABLE}),
  dets:close(State#store.table),
  ok.

code_change(_OldVersion, State, _Extra) -> {ok, State}.
