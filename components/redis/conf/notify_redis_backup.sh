#!/bin/bash
export REDISCLI_AUTH=__REDIS_PASS__
PEER_IP="__PEER_IP__"
logger "[Redis-HA] __LOCAL_IP__: Demoting Redis to REPLICA of $PEER_IP"
redis-cli -p __REDIS_PORT__ SLAVEOF "$PEER_IP" __REDIS_PORT__
redis-cli -p __REDIS_PORT__ CONFIG SET slave-read-only yes
echo "replica" > /var/run/redis-role
