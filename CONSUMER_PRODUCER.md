# Consumer - Producer extension
> Output monitor data over a Websocket

This extension to the `system_monitor` application makes
it possible to send the collected info via the `system_monitor_producer`
code over a websocket to a Consumer. If the Consumer is setup
to be the `system_monitor_consumer` it will send along the incoming
data to the `system_monitor_pg` Postgres handler.

So basically, it can be used in two ways, either by inserting
a "bridge" (via the websocket) to the `system_monitor` Postgres
backend, or simply used as a way to output the data over a websocket
to any other backend that is capable of consuming the incoming data.


## Setup

By default the Consumer-Producer functionality is turned off.
The configuration is available but disabled in the
`src/system_monitor.app.src` file where it also is documented.

To enable and configure the functionality we need to modify the
`system_monitor.app` file that has been generated during compilation.
This can either be done manually by hand or by making use of the
`setup_consumer_producer`script. This script takes, as argument,
the file path leading to the `system_monitor.app` file which will
be modified inline. It looks for any corresponding environment
variables and, when found, makes the changes.

The `setup_consumer_producer` script will generate a
`consumer_secret` unless such already exist. It will also
modify the dependencies. 

The setup of the environment variables and invoking the
script can be done as show below:

```shell
$ set -a
$ . ./config/consumer.env
$ . ./config/producer.env
$ set +a
$ ./script/setup_consumer_producer ./_build/default/lib/system_monitor/ebin/system_monitor.app
```
> __Note:__ if using `rebar3 shell`, which will recompile the application,
> it can be necessary to operate on the `./src/system_monitor.app.src`
> file instead to avoid overwriting the `system_monitor.app` file.

Where the content of the `.env` files can look like this:

```shell
$ cat ./config/consumer.env
CONSUMER_ENABLE=true
CONSUMER_LISTEN_IP=0.0.0.0
CONSUMER_LISTEN_PORT=8888

$ cat ./config/producer.env
PRODUCER_ENABLE=true
PRODUCER_IP=192.168.1.172
PRODUCER_PORT=8888
```

A copy of the old file will be saved as a backup.

To tailor the resulting app file for either the Consumer or the Producer,
use either of the `-c` or `-p` flags to the script.

```shell
# Only enable the Consumer (e.g running on host A)
$ ./script/setup_consumer_producer -c ./src/system_monitor.app.src

# Only enable the Producer (e.g running on host B)
$ ./script/setup_consumer_producer -p ./src/system_monitor.app.src
```
Make sure the app file contain the same `consumer_secret` (require
manual editing).

> __Note:__ the `consumer_secret` will be automatically generated
> unless it isn't already set to an Erlang binary value; hence it
> will not be overwritten once generated.

## Running

At the target node where the Producer will run, start like:

```erlang
$ rebar3 shell --apps gun
1> application:load(system_monitor).
2> system_monitor_sup:start_link().
```

If setup properly, the `system_monitor_producer` will setup a
websocket to the Consumer and start sending the collected data.

At the backend node where the Consumer and the Postgres code will
run, start like:

```erlang
$ rebar3 shell --apps epgsql,ranch,cowboy
1> application:load(system_monitor).
2> system_monitor_consumer:start_link().
```


