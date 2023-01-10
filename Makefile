all:
	./rebar3 compile


test: 
	./rebar3 ct

clean:
	./rebar clean

.PHONY: test

