#!/usr/bin/env bash
# components/nginx/install.sh — Nginx 安装脚本
# 接收环境变量: MODE, HA_TOPO, MASTER_HOST, SLAVE_HOST, SSH_USER, SSH_PASS, SCRIPT_DIR

source "${SCRIPT_DIR}/lib/common.sh"

log_info "[Nginx] 安装脚本待实现"
log_info "  MODE        = ${MODE}"
log_info "  HA_TOPO     = ${HA_TOPO:-N/A}"
log_info "  MASTER_HOST = ${MASTER_HOST}"
log_info "  SLAVE_HOST  = ${SLAVE_HOST:-N/A}"
