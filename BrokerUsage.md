See [Building](http://code.google.com/p/mqtt4erl/wiki/Building) to learn how to get the broker compiled.

> # From the erlang shell #

The broker is wrapped as an OTP application so it can be simply started with

```
application:start(mqtt_broker).
```

and stopped with:

```
application:stop(mqtt_broker).
```


Remember to get the `beam` files onto your path, for example by invoking the shell as
```
erl -pa ./ebin
```

> # From the command line #

Specify the broker's bootfile when you invoke erlang on the command line, eg:

```
erl -noshell -boot mqtt_broker_0.3.0
```

This will look for `mqtt_broker_0.3.0.boot` in the current directory - see [Building](http://code.google.com/p/mqtt4erl/wiki/Building) for clues on getting the boot files built.

The Makefile's `run` target can be used as a shortcut for this method.