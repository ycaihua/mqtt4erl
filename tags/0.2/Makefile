ERL=erl -pa ./ebin 
ERLC=erlc
CP=cp
RM=rm
APP_NAME=mqtt_broker
VSN=0.2.0

all: 
	$(ERL) -make
	$(CP) src/*.app ebin/

boot: all
	$(ERL) -eval 'systools:make_script("$(APP_NAME)_$(VSN)", [local, {outdir, "."}, {path,["ebin"]}, no_module_tests]), init:stop().' -noshell

clean:
	$(RM) -fv *.boot
	$(RM) -fv *.script
	$(RM) -fv *.tar.gz
	$(RM) -fv ebin/*.beam
	$(RM) -fv erl_crash.dump
	$(RM) -fv ebin/*.app

dist:
	$(ERL) -eval 'systools:make_script("$(APP_NAME)_$(VSN)", [{path,["ebin"]}]), init:stop().' -noshell
	$(ERL) -eval 'systools:make_tar("$(APP_NAME)_$(VSN)", [{path, ["./ebin/"]}, {erts, code:root_dir()}]), init:stop().' -noshell

run:
	ERL_MAX_PORTS=65535 $(ERL) -smp auto -noshell \
	-boot $(APP_NAME)_$(VSN)
