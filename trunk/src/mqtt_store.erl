-module(mqtt_store).
-behaviour(gen_server).

%%
%% An erlang client for MQTT (http://www.mqtt.org/)
%%

-include_lib("mqtt.hrl").

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-export([start/0, start_link/0, put_message/2, get_all_messages/1, get_message/2, delete_message/2, delete_messages/1, pass_messages/2]).

-record(mqtt_store, {
  table
}).

-define(TABLE, messages.dets).

start_link() -> gen_server:start_link({global, ?MODULE}, ?MODULE, [], []).

start() -> gen_server:start({global, ?MODULE}, ?MODULE, [], []).

init([]) ->
  ?LOG({dets, opening, ?TABLE}),
  {ok, Table} = dets:open_file(?TABLE, [{type, bag}]),
  process_flag(trap_exit, true),
  {ok, #mqtt_store{table = Table}}.

put_message(Handle, Message) ->
  gen_server:call({global, ?MODULE}, {put, Handle, Message}, 1000).

get_all_messages(Handle) ->
  gen_server:call({global, ?MODULE}, {get, Handle, all}, 1000).

get_message(Handle, MessageId) ->
  gen_server:call({global, ?MODULE}, {get, Handle, MessageId}, 1000).

delete_message(Handle, MessageId) ->
  gen_server:call({global, ?MODULE}, {delete, Handle, MessageId}, 1000).

delete_messages({_ClientId, all} = Handle) ->
  gen_server:call({global, ?MODULE}, {delete, Handle}, 1000).

pass_messages(Handle, ToPid) ->
  gen_server:call({global, ?MODULE}, {pass, Handle, ToPid}, 1000).

handle_call({put, Handle, Message}, _FromPid, State) when Message#mqtt.id /= undefined ->
  Response = dets:insert(State#mqtt_store.table, {Handle, Message#mqtt.id, Message}),
  ?LOG({put, Handle, mqtt_core:pretty(Message), Response}),
  {reply, Response, State};
handle_call({get, Handle, all}, _FromPid, State) ->
  Messages = lists:map(fun({_, _, Message}) ->
    Message
  end, dets:lookup(State#mqtt_store.table, Handle)), 
  ?LOG({get, Handle, all, returning, length(Messages)}),
  {reply, Messages, State};
handle_call({get, Handle, MessageId}, _FromPid, State) ->
  [[Message]] = dets:match(State#mqtt_store.table, {Handle, MessageId, '$1'}),
  ?LOG({get, Handle, MessageId, returning, mqtt_core:pretty(Message)}),
  {reply, Message, State};
handle_call({delete, {ClientId, all}}, _FromPid, State) ->
  Response = dets:match_delete(State#mqtt_store.table, {{ClientId, '_'}, '_', '_'}), 
  ?LOG({delete, {ClientId, all}, returning, Response}),
  {reply, Response, State};
handle_call({delete, Handle, MessageId}, _FromPid, State) ->
  Response = dets:match_delete(State#mqtt_store.table, {Handle, MessageId, '_'}), 
  ?LOG({delete, Handle, MessageId, returning, Response}),
  {reply, Response, State};
handle_call({pass, Handle, ToPid}, _FromPid, State) ->
  lists:foreach(fun({_, _, Message} = Object) ->
    ToPid ! Message,
    dets:delete_object(State#mqtt_store.table, Object)
  end, dets:lookup(State#mqtt_store.table, Handle)),
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
  dets:close(State#mqtt_store.table),
  ok.

code_change(_OldVersion, State, _Extra) -> {ok, State}.
