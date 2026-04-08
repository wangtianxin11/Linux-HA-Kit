#!/usr/bin/env bash
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/menu.sh"
source "${SCRIPT_DIR}/lib/component_config.sh"

component_config "redis" \
    "REDIS_PORT|端口|default|6379" \
    "REDIS_PASS|密码|password|"
