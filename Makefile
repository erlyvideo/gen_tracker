all:
	./rebar compile


logs:
	mkdir -p logs

test: logs all
	ct_run -pa ebin -dir test -logdir logs

clean:
	./rebar clean

.PHONY: test

