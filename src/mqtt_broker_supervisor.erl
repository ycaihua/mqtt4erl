-module(mqtt_broker_supervisor).
-behaviour(supervisor).		% see erl -man supervisor

-export([start/0, start_in_shell_for_testing/0, start_link/1, init/1]).

start() ->
  spawn(fun() ->
    supervisor:start_link({local,?MODULE}, ?MODULE, _Arg = [])
  end).

start_in_shell_for_testing() ->
    {ok, Pid} = supervisor:start_link({local,?MODULE}, ?MODULE, _Arg = []),
    unlink(Pid).

start_link(Args) ->
    supervisor:start_link({local,?MODULE}, ?MODULE, Args).

init([]) ->
  {ok, {
    {one_for_one, 3, 10},
    [
      {mqtt_store,
        {mqtt_store, start_link, []}, permanent, 10, worker, [mqtt_store]
      },
      {mqtt_registry,
        {mqtt_registry, start_link, []}, permanent, 10, worker, [mqtt_registry]
      },
      {mqtt_broker,
        {mqtt_broker, start_link, []}, permanent, 10, worker, [mqtt_broker, mqtt_client, mqtt_core]
      }
    ]
  }}. 
