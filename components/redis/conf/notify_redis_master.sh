#!/bin/bash
export REDISCLI_AUTH=__REDIS_PASS__
logger "[Redis-HA] __LOCAL_IP__: Promoting Redis to MASTER"
redis-cli -p __REDIS_PORT__ SLAVEOF NO ONE
redis-cli -p __REDIS_PORT__ CONFIG SET slave-read-only no
echo "master" > /var/run/redis-role
