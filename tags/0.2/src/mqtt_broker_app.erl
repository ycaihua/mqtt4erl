-module(mqtt_broker_app). 
-behaviour(application). 
-export([start/2, stop/1]).

start(_Type, StartArgs) -> 
  mqtt_broker_supervisor:start_link(StartArgs).

stop(_State) -> 
  ok.
