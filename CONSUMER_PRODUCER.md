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

To make sure no one else can eavesdrop on what is sent to the Backend
we run the Websocket over TLS using certificates both for the
Backend- and the Frontend node.

## Compiling

Just run: `make`

The `system_monitor` application makes use of its own variant of
of the OTP supervisor; it is called `supervisor3`. If you don't
want to use it and instead use the standard OTP `supervisor`;
compile as: `make nosup3`.


## Setup the Consumer

The Consumer is the "backend" that receives the data, produced
at the target node, over the Websocket. It is on the backend Host
that we run Postgres in one Docker container and Grafana in another
Docker container. These Docker containers can be setup by running:

```shell
$ make dev-start

# To check that they have been created:
$ sudo docker ps -a
CONTAINER ID   IMAGE                  COMMAND                  CREATED          STATUS                      PORTS     NAMES                                                                                
d5432f939bb9   docker-grafana         "/run.sh"                17 minutes ago   Created                               docker-grafana-1                                                                     
9b31895dea71   docker-db              "docker-entrypoint.s…"   17 minutes ago   Created                               docker-db-1

# To start them:
sudo docker start docker-db-1
sudo docker start docker-grafana-1
```

### Setup the Certificates

>[!NOTE]
> This it not necessary if running over TCP only!

To create the necessary server- and client certificates we will make use
of the [myca](https://github.com/etnt/myca) package. 

```shell
# Clone a shallow copy of the 'myca' package and enter the subdir.
$ make CA
$ cd CA
# Create CA- and Server certificate; prompted for some info.
$ make all
# Create Client certificate; prompted for some info.
$ make client
```

Prepare a tar file of certificates to put at the Client:

```shell
$ tar cvzf ~/sysmon_client_bill.tgz client_keys/bill@acme.com_Tue-21-Nov-2023-01\:14\:32-PM-CET.pem certs/cacert.pem 
client_keys/bill@acme.com_Tue-21-Nov-2023-01:14:32-PM-CET.pem
certs/cacert.pem
```

### Prepare the .app file

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

>[!NOTE]
> If using `rebar3 shell`, which will automatically  recompile the application,
> it can be necessary to operate on the `./src/system_monitor.app.src`
> file instead to having your `system_monitor.app` file being overwritten.


The setup of the environment variables and invoking the
script can be done as show below:

```shell
$ set -a
$ . ./config/consumer.env
$ set +a
$ ./script/setup_consumer_producer -c ./_build/default/lib/system_monitor/ebin/system_monitor.app

# Or do like this, see the Note above!
$ ./script/setup_consumer_producer -c ./src/system_monitor.app.src
```

To tailor the resulting app file for either the Consumer or the Producer,
use either of the `-c` or `-p` flags to the script.

A copy of the old file will be saved as a backup.

The content of the `.env` files can look like this:

```shell
$ cat ./config/consumer.env
CONSUMER_ENABLE=true
CONSUMER_LISTEN_IP=0.0.0.0
CONSUMER_LISTEN_PORT=8888
CONSUMER_USE_TLS=true
CONSUMER_CACERTFILE="/home/system_monitor/CA/certs/cacert.pem"
CONSUMER_CERTFILE="/home/system_monitor/CA/certs/server.crt"
CONSUMER_KEYFILE="/home/system_monitor/CA/certs/server.key"
CONSUMER_CRLDIR="/home/system_monitor/CA/crl"
```


## Setup the Producer (the client at the target node)

Start by installing the client certificates we put in the tar file.

```shell
$ mkdir certs
$ tar xvzf ~/sysmon_client_bill.tgz 
client_keys/bill@acme.com_Tue-21-Nov-2023-01:14:32-PM-CET.pem
certs/cacert.pem
```

Then modify the `producer.env` file to fit:

```shell
$ cat ./config/producer.env
PRODUCER_ENABLE=true
PRODUCER_IP=192.168.1.172
PRODUCER_PORT=8888
PRODUCER_USE_TLS=true
PRODUCER_CACERTFILE="/home/system_monitor/certs/certs/cacert.pem"
PRODUCER_CERTFILE="/home/system_monitor/certs/client_keys/bill@acme.com_Mon-Nov-20-09:46:10-UTC-2023.pem"
```

Then give the .app file some massage: 

```shell
$ set -a
$ . ./config/producer.env
$ set +a
$ ./script/setup_consumer_producer -p ./_build/default/lib/system_monitor/ebin/system_monitor.app

# Or do like this, see the Note above!
$ ./script/setup_consumer_producer -p ./src/system_monitor.app.src
```


## Running

Start the Consumer node as:

```shell
$ make consumer
```

At the target node where the Producer will run, start like:

```shell
$ make producer
```

If setup properly, the Producer will setup a websocket to the
Consumer and start sending the collected data.

If your system is started in any other way you may have to integrate
the start of the Producer into it. It could look something like this:

```erlang
start_system_monitor() ->
    ok = application:set_env(system_monitor, producer_enable, true),
    ok = application:set_env(system_monitor, callback_mod, system_monitor_producer),
    ok = application:set_env(system_monitor, restart_intensity, {5,60}),
    %% You can of course also set the Host/IP, CaCertFile/CertFile and TLS info here,
    %% using application:set_env/3, if that is more convenient for you.
    ChildSpec = my_system_monitor_sup:system_monitor_child(),
    supervisor:start_child(my_system_monitor_sup, ChildSpec).
```

Note that we start a new child under our supervisor. Our supervisor code
could look like this:

```erlang
...

init([]) ->
    SupFlags = #{ strategy => one_for_one
                , intensity => 0
                , period => 1
                },
    ChildSpecs = [some_other_child_spec()],
    {ok, {SupFlags, ChildSpecs}}.

...
system_monitor_child() ->
    #{id => system_monitor_sup,
      start => {system_monitor_sup, start_link, []},
      restart => temporary,
      shutdown => infinity,
      type => supervisor,
      modules => [system_monitor_sup]}.
```

