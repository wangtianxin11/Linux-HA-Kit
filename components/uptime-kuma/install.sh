#!/usr/bin/env bash
# components/uptime-kuma/install.sh — Uptime Kuma 离线安装脚本（docker compose 方式）
# 依赖 Docker 已安装，通过 docker load 导入镜像后 docker compose up 启动
# 适用系统: Ubuntu 20.04 / 22.04 / 24.04

if [ -z "${BASH_VERSION:-}" ]; then
    exec bash "$0" "$@"
fi

set -euo pipefail

source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/component_config.sh"

# ─── 读取组件配置 ─────────────────────────────────────────────
load_component_config "uptime-kuma" || true
KUMA_PORT="${KUMA_PORT:-3001}"

KUMA_PKG_DIR="${SCRIPT_DIR}/packages/uptime-kuma"
KUMA_COMPOSE_TEMPLATE="${SCRIPT_DIR}/components/uptime-kuma/conf/docker-compose.yml"
KUMA_WORK_DIR="/home/uptime-kuma"

# ─── 安装单台机器 ─────────────────────────────────────────────
install_kuma_on_host() {
    local host="$1"
    local user="$2"
    local pass="$3"
    local is_local="${4:-false}"

    log_info "开始在 [${host}] 安装 Uptime Kuma..."

    if [ "${is_local}" = "true" ]; then
        if [ ! -d "${KUMA_PKG_DIR}" ]; then
            log_error "找不到 Uptime Kuma 镜像目录: ${KUMA_PKG_DIR}"
            exit 1
        fi
        _do_install_local
    else
        _do_install_remote "${host}" "${user}" "${pass}"
    fi
}

# ─── 本地安装逻辑 ─────────────────────────────────────────────
_do_install_local() {
    if ! command -v docker &>/dev/null; then
        log_error "Docker 未安装，请先安装 Docker"
        exit 1
    fi

    # 查找镜像文件
    local image_file
    image_file=$(find "${KUMA_PKG_DIR}" -maxdepth 1 -name "*.tar" 2>/dev/null | head -1)
    if [ -z "${image_file}" ]; then
        log_error "未找到镜像文件（*.tar），请检查 ${KUMA_PKG_DIR}"
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
    if ! docker images --format '{{.Repository}}:{{.Tag}}' | grep -q '^louislam/uptime-kuma:2$'; then
        local loaded_id
        loaded_id=$(echo "${load_output}" | grep -oP '(sha256:)?[0-9a-f]{64}' | head -1)
        if [ -z "${loaded_id}" ]; then
            log_error "无法从 docker load 输出中解析镜像 ID"
            exit 1
        fi
        log_info "镜像无 tag，自动标记: ${loaded_id} -> louislam/uptime-kuma:2"
        docker tag "${loaded_id}" louislam/uptime-kuma:2
    fi

    # 准备工作目录和 compose 文件
    mkdir -p "${KUMA_WORK_DIR}/data"

    log_info "生成 docker-compose.yml（端口: ${KUMA_PORT}）..."
    sed "s/__KUMA_PORT__/${KUMA_PORT}/g" \
        "${KUMA_COMPOSE_TEMPLATE}" > "${KUMA_WORK_DIR}/docker-compose.yml"

    # 停止并移除已有容器
    if docker ps -a --format '{{.Names}}' | grep -q '^uptime-kuma$'; then
        log_info "检测到已有 uptime-kuma 容器，先停止并移除..."
        docker compose -f "${KUMA_WORK_DIR}/docker-compose.yml" down 2>/dev/null || docker rm -f uptime-kuma
    fi

    # 启动容器
    log_info "启动 Uptime Kuma（docker compose up）..."
    docker compose -f "${KUMA_WORK_DIR}/docker-compose.yml" up -d || {
        log_error "Uptime Kuma 容器启动失败"
        exit 1
    }

    # 验证
    sleep 2
    log_info "验证 Uptime Kuma 运行状态..."
    docker compose -f "${KUMA_WORK_DIR}/docker-compose.yml" ps

    if docker ps --format '{{.Names}}' | grep -q '^uptime-kuma$'; then
        log_info "Uptime Kuma 已启动，访问地址: http://$(hostname -I | awk '{print $1}'):${KUMA_PORT}"
    else
        log_error "Uptime Kuma 容器未正常运行，请检查: docker compose -f ${KUMA_WORK_DIR}/docker-compose.yml logs"
        exit 1
    fi
}

# ─── 远端安装逻辑 ─────────────────────────────────────────────
_do_install_remote() {
    local host="$1" user="$2" pass="$3"
    local remote_tmp="/tmp/kuma_install_$$"

    trap "sshpass -p '${pass}' ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
        '${user}@${host}' 'rm -rf ${remote_tmp}' 2>/dev/null || true" RETURN

    log_info "上传安装包到 [${host}]:${remote_tmp} ..."
    run_remote "${host}" "${user}" "${pass}" \
        "mkdir -p ${remote_tmp}/packages/uptime-kuma ${remote_tmp}/lib ${remote_tmp}/components/uptime-kuma/conf"

    log_info "上传到 [${user}@${host}]: packages/uptime-kuma/ (镜像较大，请稍候...)"
    COPYFILE_DISABLE=1 tar -C "${KUMA_PKG_DIR}" --exclude="._*" --exclude=".DS_Store" -cf - . | \
        sshpass -p "${pass}" ssh \
            -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
            "${user}@${host}" "tar -xf - -C ${remote_tmp}/packages/uptime-kuma/"

    log_info "上传到 [${user}@${host}]: lib/"
    COPYFILE_DISABLE=1 tar -C "${SCRIPT_DIR}" --exclude="._*" --exclude=".DS_Store" -cf - lib | \
        sshpass -p "${pass}" ssh \
            -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
            "${user}@${host}" "tar -xf - -C ${remote_tmp}/"

    log_info "上传到 [${user}@${host}]: docker-compose.yml 模板"
    sshpass -p "${pass}" ssh \
        -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
        "${user}@${host}" "cat > ${remote_tmp}/components/uptime-kuma/conf/docker-compose.yml" \
        < "${KUMA_COMPOSE_TEMPLATE}"

    log_info "上传到 [${user}@${host}]: install.sh"
    sshpass -p "${pass}" ssh \
        -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
        "${user}@${host}" "cat > ${remote_tmp}/install.sh" \
        < "${SCRIPT_DIR}/components/uptime-kuma/install.sh"

    run_remote "${host}" "${user}" "${pass}" \
        "SCRIPT_DIR=${remote_tmp} \
         KUMA_PORT=${KUMA_PORT} \
         MODE=standalone \
         bash ${remote_tmp}/install.sh"
}

# ─── 主流程 ───────────────────────────────────────────────────
main() {
    log_title "Uptime Kuma 安装"

    if [ "${MODE}" = "standalone" ]; then
        install_kuma_on_host "localhost" "" "" "true"

    elif [ "${MODE}" = "ha" ]; then
        log_info "热备模式，安装主机 [${MASTER_HOST}]..."
        install_kuma_on_host "${MASTER_HOST}" "${MASTER_SSH_USER}" "${MASTER_SSH_PASS}" "false" \
            || { log_error "主机 Uptime Kuma 安装失败，终止"; exit 1; }

        log_info "安装备机 [${SLAVE_HOST}]..."
        install_kuma_on_host "${SLAVE_HOST}" "${SLAVE_SSH_USER}" "${SLAVE_SSH_PASS}" "false" \
            || { log_error "备机 Uptime Kuma 安装失败，终止"; exit 1; }
    fi

    log_info "Uptime Kuma 安装完成"
}

main "$@"
