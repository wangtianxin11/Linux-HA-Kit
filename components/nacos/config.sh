#!/usr/bin/env bash
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/menu.sh"
source "${SCRIPT_DIR}/lib/component_config.sh"

component_config "nacos" \
    "NACOS_PORT|端口|default|8848" \
    "NACOS_USER|账号|default|nacos" \
    "NACOS_PASS|密码|password|"
