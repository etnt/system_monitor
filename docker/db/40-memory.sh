#!/usr/bin/env sh

#!/bin/bash
set -euxo

# Example: ./40-memory.sh localhost
HOST=""
if [ -n "$1" ]; then
    HOST="-h $1"
fi

psql ${HOST} -v ON_ERROR_STOP=1 --username "system_monitor" --dbname "system_monitor" <<-EOSQL

-----------------------------------------------------------------------------------
-- memory table
-----------------------------------------------------------------------------------

create table if not exists memory (
    node text not null,
    ts timestamp without time zone not null,
    total bigint not null,
    free bigint not null,
    allocated bigint not null
) partition by range(ts);

alter table memory owner to system_monitor;
grant insert on table memory to system_monitor;
grant select on table memory to grafana;

EOSQL
