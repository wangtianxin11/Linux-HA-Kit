#!/usr/bin/env bash
# install.sh — 热备安装脚本主入口
# 支持单机 / 热备 模式
# 兼容 Ubuntu 20.04 / 24.04

# 若用 sh 执行则自动切换到 bash
if [ -z "${BASH_VERSION:-}" ]; then
    exec bash "$0" "$@"
fi

set -euo pipefail

# ─── 脚本根目录（绝对路径）────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export SCRIPT_DIR

# ─── 加载公共库 ───────────────────────────────────────────────
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/menu.sh"
source "${SCRIPT_DIR}/lib/config.sh"
source "${SCRIPT_DIR}/lib/component_config.sh"

# ─── 支持的组件列表 ───────────────────────────────────────────
ALL_COMPONENTS=("mysql" "redis" "nacos" "mongodb" "nginx" "docker" "dpanel" "emqx" "uptime-kuma")
HA_ONLY_COMPONENTS=("keepalived")

# ─── 环境检查 ─────────────────────────────────────────────────
check_env() {
    if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
        log_error "需要 bash 4.0 及以上版本，当前版本: ${BASH_VERSION}"
        exit 1
    fi

    if [ ! -f /etc/os-release ]; then
        log_warn "无法检测操作系统版本，请确认当前系统为 Ubuntu 20.04 / 24.04"
    else
        local os_name os_version
        os_name=$(grep '^NAME=' /etc/os-release | cut -d= -f2 | tr -d '"')
        os_version=$(grep '^VERSION_ID=' /etc/os-release | cut -d= -f2 | tr -d '"')
        if [[ "${os_name}" != *"Ubuntu"* ]]; then
            log_warn "当前系统: ${os_name} ${os_version}，推荐使用 Ubuntu 20.04 / 24.04"
        else
            log_info "操作系统: ${os_name} ${os_version}"
        fi
    fi
}

# ─── 构建可选组件列表 ─────────────────────────────────────────
build_component_options() {
    local -n _opts=$1
    _opts=("${ALL_COMPONENTS[@]}")
    if [ "${MODE:-}" = "ha" ]; then
        _opts+=("${HA_ONLY_COMPONENTS[@]}")
    fi
}

# ─── 调用组件配置脚本 ─────────────────────────────────────────
run_component_config() {
    local comp="$1"
    local config_script="${SCRIPT_DIR}/components/${comp}/config.sh"

    if [ ! -f "${config_script}" ]; then
        log_warn "[${comp}] 无配置脚本，跳过配置"
        return 0
    fi

    chmod +x "${config_script}"
    # 用 source 执行，使配置变量留在当前 shell 环境
    source "${config_script}"
}

# ─── HA 前置检查：keepalived 必须已运行 ──────────────────────
check_keepalived_running() {
    local host="$1" user="$2" pass="$3"
    local status
    status=$(sshpass -p "${pass}" ssh \
        -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
        "${user}@${host}" \
        "systemctl is-active keepalived 2>/dev/null || echo inactive")
    if [ "${status}" != "active" ]; then
        log_error "[${host}] keepalived 未运行（状态: ${status}），请先安装 keepalived 组件"
        return 1
    fi
    log_info "[${host}] keepalived 运行正常"
}

# ─── 调用组件安装脚本 ─────────────────────────────────────────
run_component_install() {
    local comp="$1"
    local install_script="${SCRIPT_DIR}/components/${comp}/install.sh"

    if [ ! -f "${install_script}" ]; then
        log_error "找不到安装脚本: ${install_script}"
        return 1
    fi

    chmod +x "${install_script}"

    # ha 模式下安装非 keepalived 组件时，前置检查 keepalived 是否运行
    if [ "${MODE:-}" = "ha" ] && [ "${comp}" != "keepalived" ]; then
        log_info "检查 keepalived 运行状态..."
        check_keepalived_running "${MASTER_HOST}" "${MASTER_SSH_USER}" "${MASTER_SSH_PASS}" || exit 1
        check_keepalived_running "${SLAVE_HOST}"  "${SLAVE_SSH_USER}"  "${SLAVE_SSH_PASS}"  || exit 1
    fi

    export MODE HA_TOPO \
           MASTER_HOST MASTER_SSH_USER MASTER_SSH_PASS \
           SLAVE_HOST  SLAVE_SSH_USER  SLAVE_SSH_PASS \
           SCRIPT_DIR

    if bash "${install_script}"; then
        log_info "组件 [${comp}] 安装完成"
        return 0
    else
        log_error "组件 [${comp}] 安装失败，终止"
        exit 1
    fi
}

# ─── 主循环：单选 → 配置 → 安装 → 是否继续 ────────────────────
install_loop() {
    local options
    build_component_options options

    # 追加退出选项
    local menu_options=("${options[@]}" "── 退出安装 ──")

    while true; do
        echo ""
        single_select SELECTED_COMP "请选择要安装的组件" "${menu_options[@]}"

        # 选择退出
        if [ "${SELECTED_COMP}" = "── 退出安装 ──" ]; then
            log_info "已退出安装程序"
            break
        fi

        local comp="${SELECTED_COMP}"

        # Step 1: 组件配置
        log_title "配置 ${comp}"
        run_component_config "${comp}"

        # Step 2: 安装（计时）
        log_title "安装 ${comp}"
        timer_start
        if run_component_install "${comp}"; then
            timer_end "${comp}"
            echo ""
            if ! confirm_yes_no "是否继续安装其他组件？" "y"; then
                log_info "已退出安装程序"
                break
            fi
        fi
    done
}

# ─── 主流程 ───────────────────────────────────────────────────
main() {
    log_title "热备安装脚本 v1.0"
    timer_start

    # Step 0: 环境检查
    check_env

    # Step 1: 全局配置（首次录入 or 已有配置确认）
    load_or_init_config

    # Step 2: 保存全局配置
    save_config

    # Step 3: 进入安装循环
    install_loop

    timer_end "本次安装总计"
}

main "$@"
