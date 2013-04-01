all:
	./rebar compile


logs:
	mkdir -p logs

test: logs
	ct_run -dir test -logdir logs

clean:
	./rebar clean

.PHONY: test

