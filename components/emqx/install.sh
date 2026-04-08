#!/usr/bin/env bash
# components/emqx/install.sh — EMQX Enterprise 离线安装脚本（docker compose 方式）
# 依赖 Docker 已安装，通过 docker load 导入镜像后 docker compose up 启动
# 适用系统: Ubuntu 20.04 / 22.04 / 24.04

if [ -z "${BASH_VERSION:-}" ]; then
    exec bash "$0" "$@"
fi

set -euo pipefail

source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/component_config.sh"

# ─── 读取组件配置 ─────────────────────────────────────────────
load_component_config "emqx" || true
EMQX_MQTT_PORT="${EMQX_MQTT_PORT:-11883}"
EMQX_WS_PORT="${EMQX_WS_PORT:-8083}"
EMQX_WSS_PORT="${EMQX_WSS_PORT:-8084}"
EMQX_MQTTS_PORT="${EMQX_MQTTS_PORT:-8883}"
EMQX_DASHBOARD_PORT="${EMQX_DASHBOARD_PORT:-18083}"

EMQX_PKG_DIR="${SCRIPT_DIR}/packages/emqx"
EMQX_COMPOSE_TEMPLATE="${SCRIPT_DIR}/components/emqx/conf/docker-compose.yml"
EMQX_WORK_DIR="/home/emqx"

# ─── 安装单台机器的 EMQX ─────────────────────────────────────
install_emqx_on_host() {
    local host="$1"
    local user="$2"
    local pass="$3"
    local is_local="${4:-false}"

    log_info "开始在 [${host}] 安装 EMQX Enterprise..."

    if [ "${is_local}" = "true" ]; then
        if [ ! -d "${EMQX_PKG_DIR}" ]; then
            log_error "找不到 EMQX 镜像目录: ${EMQX_PKG_DIR}"
            exit 1
        fi
        _do_install_local
    else
        _do_install_remote "${host}" "${user}" "${pass}"
    fi
}

# ─── 本地安装逻辑 ─────────────────────────────────────────────
_do_install_local() {
    # 检查 Docker 是否可用
    if ! command -v docker &>/dev/null; then
        log_error "Docker 未安装，请先安装 Docker"
        exit 1
    fi

    # 查找镜像文件
    local image_file
    image_file=$(find "${EMQX_PKG_DIR}" -maxdepth 1 -name "*.tar" 2>/dev/null | head -1)
    if [ -z "${image_file}" ]; then
        log_error "未找到镜像文件（*.tar），请检查 ${EMQX_PKG_DIR}"
        exit 1
    fi

    # 导入镜像
    log_info "导入镜像: $(basename "${image_file}")"
    local load_output
    load_output=$(docker load -i "${image_file}" 2>&1) || {
        log_error "镜像导入失败"
        exit 1
    }
    log_info "${load_output}"

    # 确保镜像有正确的 tag
    if ! docker images --format '{{.Repository}}:{{.Tag}}' | grep -q '^emqx/emqx-enterprise:6.2.0$'; then
        local loaded_id
        loaded_id=$(echo "${load_output}" | grep -oP '(sha256:)?[0-9a-f]{64}' | head -1)
        if [ -z "${loaded_id}" ]; then
            log_error "无法从 docker load 输出中解析镜像 ID"
            exit 1
        fi
        log_info "镜像无 tag，自动标记: ${loaded_id} -> emqx/emqx-enterprise:6.2.0"
        docker tag "${loaded_id}" emqx/emqx-enterprise:6.2.0
    fi

    # 准备工作目录和 compose 文件（EMQX 容器内以 uid 1000 运行）
    mkdir -p "${EMQX_WORK_DIR}/data" "${EMQX_WORK_DIR}/log"
    chown -R 1000:1000 "${EMQX_WORK_DIR}/data" "${EMQX_WORK_DIR}/log"

    log_info "生成 docker-compose.yml..."
    sed -e "s/__EMQX_MQTT_PORT__/${EMQX_MQTT_PORT}/g" \
        -e "s/__EMQX_WS_PORT__/${EMQX_WS_PORT}/g" \
        -e "s/__EMQX_WSS_PORT__/${EMQX_WSS_PORT}/g" \
        -e "s/__EMQX_MQTTS_PORT__/${EMQX_MQTTS_PORT}/g" \
        -e "s/__EMQX_DASHBOARD_PORT__/${EMQX_DASHBOARD_PORT}/g" \
        "${EMQX_COMPOSE_TEMPLATE}" > "${EMQX_WORK_DIR}/docker-compose.yml"

    # 停止并移除已有容器
    if docker ps -a --format '{{.Names}}' | grep -q '^emqx-enterprise$'; then
        log_info "检测到已有 emqx-enterprise 容器，先停止并移除..."
        docker compose -f "${EMQX_WORK_DIR}/docker-compose.yml" down 2>/dev/null || docker rm -f emqx-enterprise
    fi

    # 启动容器
    log_info "启动 EMQX Enterprise（docker compose up）..."
    docker compose -f "${EMQX_WORK_DIR}/docker-compose.yml" up -d || {
        log_error "EMQX 容器启动失败"
        exit 1
    }

    # 验证
    sleep 3
    log_info "验证 EMQX 运行状态..."
    docker compose -f "${EMQX_WORK_DIR}/docker-compose.yml" ps

    if docker ps --format '{{.Names}}' | grep -q '^emqx-enterprise$'; then
        local host_ip
        host_ip=$(hostname -I | awk '{print $1}')
        log_info "EMQX Enterprise 已启动"
        log_info "  Dashboard:  http://${host_ip}:${EMQX_DASHBOARD_PORT}"
        log_info "  MQTT:       tcp://${host_ip}:${EMQX_MQTT_PORT}"
        log_info "  WebSocket:  ws://${host_ip}:${EMQX_WS_PORT}/mqtt"
    else
        log_error "EMQX 容器未正常运行，请检查: docker compose -f ${EMQX_WORK_DIR}/docker-compose.yml logs"
        exit 1
    fi
}

# ─── 远端安装逻辑 ─────────────────────────────────────────────
_do_install_remote() {
    local host="$1" user="$2" pass="$3"
    local remote_tmp="/tmp/emqx_install_$$"

    trap "sshpass -p '${pass}' ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
        '${user}@${host}' 'rm -rf ${remote_tmp}' 2>/dev/null || true" RETURN

    log_info "上传安装包到 [${host}]:${remote_tmp} ..."
    run_remote "${host}" "${user}" "${pass}" \
        "mkdir -p ${remote_tmp}/packages/emqx ${remote_tmp}/lib ${remote_tmp}/components/emqx/conf"

    log_info "上传到 [${user}@${host}]: packages/emqx/ (镜像较大，请稍候...)"
    tar -C "${EMQX_PKG_DIR}" -cf - . | \
        sshpass -p "${pass}" ssh \
            -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
            "${user}@${host}" "tar -xf - -C ${remote_tmp}/packages/emqx/"

    log_info "上传到 [${user}@${host}]: lib/"
    tar -C "${SCRIPT_DIR}" -cf - lib | \
        sshpass -p "${pass}" ssh \
            -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
            "${user}@${host}" "tar -xf - -C ${remote_tmp}/"

    log_info "上传到 [${user}@${host}]: docker-compose.yml 模板"
    sshpass -p "${pass}" ssh \
        -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
        "${user}@${host}" "cat > ${remote_tmp}/components/emqx/conf/docker-compose.yml" \
        < "${EMQX_COMPOSE_TEMPLATE}"

    log_info "上传到 [${user}@${host}]: install.sh"
    sshpass -p "${pass}" ssh \
        -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
        "${user}@${host}" "cat > ${remote_tmp}/install.sh" \
        < "${SCRIPT_DIR}/components/emqx/install.sh"

    run_remote "${host}" "${user}" "${pass}" \
        "SCRIPT_DIR=${remote_tmp} \
         EMQX_MQTT_PORT=${EMQX_MQTT_PORT} \
         EMQX_WS_PORT=${EMQX_WS_PORT} \
         EMQX_WSS_PORT=${EMQX_WSS_PORT} \
         EMQX_MQTTS_PORT=${EMQX_MQTTS_PORT} \
         EMQX_DASHBOARD_PORT=${EMQX_DASHBOARD_PORT} \
         MODE=standalone \
         bash ${remote_tmp}/install.sh"
}

# ─── 主流程 ───────────────────────────────────────────────────
main() {
    log_title "EMQX Enterprise 安装"

    if [ "${MODE}" = "standalone" ]; then
        install_emqx_on_host "localhost" "" "" "true"

    elif [ "${MODE}" = "ha" ]; then
        log_info "热备模式，安装主机 [${MASTER_HOST}]..."
        install_emqx_on_host "${MASTER_HOST}" "${MASTER_SSH_USER}" "${MASTER_SSH_PASS}" "false" \
            || { log_error "主机 EMQX 安装失败，终止"; exit 1; }

        log_info "安装备机 [${SLAVE_HOST}]..."
        install_emqx_on_host "${SLAVE_HOST}" "${SLAVE_SSH_USER}" "${SLAVE_SSH_PASS}" "false" \
            || { log_error "备机 EMQX 安装失败，终止"; exit 1; }
    fi

    log_info "EMQX Enterprise 安装完成"
}

main "$@"
