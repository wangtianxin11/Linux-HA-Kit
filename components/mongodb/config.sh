#!/usr/bin/env bash
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/menu.sh"
source "${SCRIPT_DIR}/lib/component_config.sh"

component_config "mongodb" \
    "MONGO_PORT|端口|default|27017" \
    "MONGO_USER|账号|default|admin" \
    "MONGO_PASS|密码|password|"
