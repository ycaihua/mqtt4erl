The handy `Makefile` contains some targets to get you up and running:

> # `all` #

Compiles the `.erl`s to `.beam`s

> # `clean` #

Delete all compiled files

> # `boot` #

Compiles the broker's `.beam`s into a `.boot` that can be specified when you invoke erlang, to run the broker

> ## A Note on Version Compatability! ##

If you are not building with erlang R12B-5 you may need to tweak the version numbers for the dependencies listed in the `mqtt_broker_<version>.rel` file in the project root.

> # `run` #

Runs the broker by starting an erlang vm and specifying its `.boot` file

> # `dist` #

Prepeare an tar/gz'd release suitable for distributing the broker according to the [erlang way](http://erlang.org/doc/design_principles/release_structure.html)