.PHONY: CA consumer producer

CA:
	git clone --depth 1 https://github.com/etnt/myca.git CA

consumer:
	rebar3 shell --apps epgsql,ranch,cowboy --eval 'application:load(system_monitor),system_monitor_consumer:start_link().'

producer:
	rebar3 shell --apps gun --eval 'application:load(system_monitor),system_monitor_sup:start_link().'
