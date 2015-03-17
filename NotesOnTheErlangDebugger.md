I think the thing that I like the most about the erlang deugger (the `dbg` module) is that - even though it's a helpful wrapper around the underlying `trace` mechanism - its invocation is /even more terse/. COOL!

Here are some tips to get up and running with the erlang debugger:

These instructions assume you are in the erlang shell.

> # Switch it on #

```
dbg:tracer().
```

> # Tell it what to trace #

```
dbg:p(new, [all]).
```

  * `new` here means only trace newly spawned processes, alternatives include `all`, `existing`, a pid, or the registered name for a pid.
  * `all` means all of the following:
    * `s` (send) traces the messages the process sends.
    * `r` (receive) traces the messages the process receives.
    * `m` (messages) traces the messages the process receives and sends.
    * `c` (call) traces global function calls for the process according to the trace patterns set in the system (see tp/2).
    * `p` (procs) traces process related events to the process.

> # Refine the Trace Pattern #

If you are tracing function calls (the `c` tracing flag is set, as above) the trace pattern allows you to refine exactly which function calls are traced.

```
dbg:tp().
```