.PHONY: nosup3 consumer producer

# Install the CA
CA:
	git clone --depth 1 https://github.com/etnt/myca.git CA

# As the 'nosup3' profile: compile, check and run the tests
nosup3:
	rebar3 as nosup3 do compile, xref, dialyzer, eunit

# Start the Consumer node
consumer:
	rebar3 shell --apps epgsql,ranch,cowboy --eval 'application:load(system_monitor),system_monitor_consumer:start_link().'

# Start the Producer node
producer:
	rebar3 shell --apps gun --eval 'application:load(system_monitor),system_monitor_sup:start_link().'
