-module(id).

-export([get_incr/1, start/0, start_link/0]).

get_incr(IdPid) ->
  IdPid ! {id, get_incr, self()},
  receive
    {id, Id} ->
      Id
  end.

start_link() ->
  Pid = start(),
  link(Pid),
  Pid.

start() ->
  spawn(fun() ->
    loop(1)
  end).

loop(Sequence) ->
  receive
    {id, get_incr, From} ->
      From ! {id, Sequence}
  end,
  loop(Sequence + 1).
