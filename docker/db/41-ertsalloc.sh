#!/usr/bin/env sh

#!/bin/bash
set -euxo

# Example: ./41-ertsalloc.sh localhost
HOST=""
if [ $# -eq 1 ] && [ -n "$1" ]; then
    HOST="-h $1"
fi

psql ${HOST} -v ON_ERROR_STOP=1 --username "system_monitor" --dbname "system_monitor" <<-EOSQL

-----------------------------------------------------------------------------------
-- ertsalloc table
--
--   (e)binary  : Allocator used for Erlang binary data.
--   driver     : Allocator used for driver data.
--   eheap      : Used for Erlang heap data, such as Erlang process heaps.
--   ets        : Allocator used for ETS data.
--   fix        : A fast allocator used for some frequently used fixed size data types.
--   ll         : Allocator used for memory blocks that are expected to be long-lived,
--                for example, Erlang code.
--   sl         : Allocator used for memory blocks that are expected to be short-lived.
--   std        : Allocator used for most memory blocks not allocated through any of
--                the other allocators
--   temp       : Allocator used for temporary allocations.
--
-- NOTE: 'binary' is a reserved Postgres word, hence we use 'ebinary' as column name.
--
-----------------------------------------------------------------------------------

create table if not exists ertsalloc (
    node text not null,
    ts timestamp without time zone not null,
    ebinary bigint not null,
    driver bigint not null,
    eheap bigint not null,
    ets bigint not null,
    fix bigint not null,
    ll bigint not null,
    sl bigint not null,
    std bigint not null,
    temp bigint not null
) partition by range(ts);

alter table ertsalloc owner to system_monitor;
grant insert on table ertsalloc to system_monitor;
grant select on table ertsalloc to grafana;

EOSQL
