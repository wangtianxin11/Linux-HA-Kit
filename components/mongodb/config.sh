#!/usr/bin/env bash
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/menu.sh"
source "${SCRIPT_DIR}/lib/component_config.sh"

component_config "mongodb" \
    "MONGO_PORT|端口|default|27017" \
    "MONGO_REPLSET|副本集名称|default|rs0" \
    "MONGO_USER|管理员账号|default|admin" \
    "MONGO_PASS|管理员密码|password|"
