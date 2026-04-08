#!/usr/bin/env bash
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/menu.sh"
source "${SCRIPT_DIR}/lib/component_config.sh"

component_config "nginx" \
    "NGINX_HTTP_PORT|HTTP 端口|default|80" \
    "NGINX_HTTPS_PORT|HTTPS 端口|default|443"
