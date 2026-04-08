#!/usr/bin/env bash
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/menu.sh"
source "${SCRIPT_DIR}/lib/component_config.sh"

component_config "emqx" \
    "EMQX_MQTT_PORT|MQTT 端口|default|11883" \
    "EMQX_WS_PORT|WebSocket 端口|default|8083" \
    "EMQX_WSS_PORT|WebSocket SSL 端口|default|8084" \
    "EMQX_MQTTS_PORT|MQTT SSL 端口|default|8883" \
    "EMQX_DASHBOARD_PORT|Dashboard 端口|default|18083"
