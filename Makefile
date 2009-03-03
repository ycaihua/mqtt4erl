ERL=erl -pa ./ebin 
ERLC=erlc
CP=cp
RM=rm
APP_NAME=
VSN=0.2.0

all: 
	$(ERL) -make
	$(CP) src/*.app ebin/

boot: all
	$(ERL) -eval 'systools:make_script("bbc2daap_$(VSN)", [local, {outdir, "."}, {path,["ebin", "$(YAWS_HOME)/ebin"]}, no_module_tests]), init:stop().' -noshell

clean:
	$(RM) -fv Emakefile
	$(RM) -fv *.boot
	$(RM) -fv *.script
	$(RM) -fv *.tar.gz
	$(RM) -fv ebin/*.beam
	$(RM) -fv erl_crash.dump
	$(RM) -fv ebin/*.app

dist:
	$(ERL) -eval 'systools:make_script("bbc2daap_$(VSN)", [{path,["ebin", "$(YAWS_HOME)/ebin"]}]), init:stop().' -noshell
	$(ERL) -eval 'systools:make_tar("bbc2daap_$(VSN)", [{path, ["./ebin/","$(YAWS_HOME)/ebin/"]}, {erts, code:root_dir()}]), init:stop().' -noshell

run:
	$(ERL) -smp auto \
	-boot bbc2daap_$(VSN)
