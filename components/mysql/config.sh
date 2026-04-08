#!/usr/bin/env bash
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/menu.sh"
source "${SCRIPT_DIR}/lib/component_config.sh"

component_config "mysql" \
    "MYSQL_PORT|端口|default|3306" \
    "MYSQL_ROOT_PASS|root 密码|password|"
