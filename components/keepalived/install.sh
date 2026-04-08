#!/usr/bin/env bash
# components/keepalived/install.sh — Keepalived 离线安装脚本
# 仅热备（ha）模式下被调用
# 本地调用接收环境变量: MODE, MASTER_HOST, MASTER_SSH_USER, MASTER_SSH_PASS,
#                        SLAVE_HOST, SLAVE_SSH_USER, SLAVE_SSH_PASS, SCRIPT_DIR
# 远端调用接收环境变量: MODE=standalone, KA_VIP, KA_INTERFACE, KA_STATE, KA_PRIORITY, SCRIPT_DIR

# sh→bash 自动切换守卫
if [ -z "${BASH_VERSION:-}" ]; then
    exec bash "$0" "$@"
fi

set -euo pipefail

source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/component_config.sh"

KA_PKG_DIR="${SCRIPT_DIR}/packages/keepalived"

# ─── 检测远端 Ubuntu 代号 ─────────────────────────────────────
_detect_codename_remote() {
    local host="$1" user="$2" pass="$3"
    run_remote "${host}" "${user}" "${pass}" \
        "grep '^VERSION_CODENAME=' /etc/os-release | cut -d= -f2 | tr -d '\"'"
}

# ─── 应用配置模板（替换占位符）→ /etc/keepalived/keepalived.conf ──
_apply_conf() {
    local tmpl="$1"
    local dest="/etc/keepalived/keepalived.conf"

    mkdir -p /etc/keepalived
    sed \
        -e "s|__STATE__|${KA_STATE}|g" \
        -e "s|__INTERFACE__|${KA_INTERFACE}|g" \
        -e "s|__PRIORITY__|${KA_PRIORITY}|g" \
        -e "s|__VIP__|${KA_VIP}|g" \
        "${tmpl}" > "${dest}"
    log_info "keepalived.conf 已写入: ${dest}"
}

# ─── 创建 notify 占位脚本（供后续中间件覆盖）─────────────────
_create_notify_scripts() {
    mkdir -p /etc/keepalived
    for script in /etc/keepalived/notify_master.sh /etc/keepalived/notify_backup.sh; do
        if [ ! -f "${script}" ]; then
            printf '#!/bin/bash\n# 由后续中间件安装脚本填充\n' > "${script}"
            chmod +x "${script}"
            log_info "创建占位脚本: ${script}"
        else
            log_info "占位脚本已存在，跳过: ${script}"
        fi
    done
}

# ─── 本机安装逻辑（远端 SSH 调用时走此分支）─────────────────
_do_install_local() {
    local pkg_tar="${1}"   # tar.gz 完整路径
    local work_dir="/tmp/ka_work_$$"

    log_info "解压离线包: $(basename "${pkg_tar}")"
    mkdir -p "${work_dir}"
    tar -xzf "${pkg_tar}" -C "${work_dir}"

    log_info "安装 deb 包..."
    # 递归查找解压目录中所有 deb（tar.gz 内层可能有子目录）
    local deb_files=()
    while IFS= read -r -d '' f; do
        deb_files+=("$f")
    done < <(find "${work_dir}" -name "*.deb" -print0 | sort -z)

    if [ ${#deb_files[@]} -eq 0 ]; then
        log_error "离线包中未找到任何 .deb 文件，请检查 tar.gz 内容"
        rm -rf "${work_dir}"
        exit 1
    fi
    log_info "共找到 ${#deb_files[@]} 个 deb 包"

    # 阻止 dpkg postinst 自动启服务
    echo "exit 101" > /usr/sbin/policy-rc.d
    chmod +x /usr/sbin/policy-rc.d

    # 先尝试全部安装，失败则 apt-get -f 修复依赖后重试
    if ! dpkg -i "${deb_files[@]}" 2>/dev/null; then
        log_warn "dpkg 报依赖问题，尝试 apt-get install -f 修复..."
        apt-get install -f -y 2>/dev/null || true
        dpkg -i "${deb_files[@]}" || {
            rm -f /usr/sbin/policy-rc.d
            log_error "keepalived 安装失败，请检查离线包完整性"
            rm -rf "${work_dir}"
            exit 1
        }
    fi

    # 恢复正常服务启动策略
    rm -f /usr/sbin/policy-rc.d
    rm -rf "${work_dir}"

    # 创建 notify 占位脚本
    _create_notify_scripts

    # 写入配置
    _apply_conf "${SCRIPT_DIR}/keepalived.conf.tmpl"

    # 启动服务
    systemctl daemon-reload
    systemctl enable keepalived 2>/dev/null || true
    timeout 30 systemctl restart keepalived || {
        log_error "keepalived 服务启动失败，请查看日志: journalctl -xe"
        exit 1
    }

    systemctl is-active keepalived >/dev/null && \
        log_info "keepalived 服务运行正常（${KA_STATE}，priority=${KA_PRIORITY}）" || \
        log_error "keepalived 服务状态异常"

    # 主节点额外确认 VIP 已绑定
    if [ "${KA_STATE}" = "MASTER" ]; then
        local vip_addr="${KA_VIP%%/*}"   # 去掉掩码部分
        if ip addr show "${KA_INTERFACE}" 2>/dev/null | grep -q "${vip_addr}"; then
            log_info "VIP ${vip_addr} 已绑定到 ${KA_INTERFACE}"
        else
            log_warn "VIP ${vip_addr} 暂未出现在 ${KA_INTERFACE}，请稍后手动确认: ip addr show ${KA_INTERFACE}"
        fi
    fi
}

# ─── 远端安装（上传包+脚本，SSH 执行）──────────────────────
_do_install_remote() {
    local host="$1" user="$2" pass="$3"
    local ka_state="$4" ka_priority="$5"
    local codename="$6"
    local remote_tmp="/tmp/ka_install_$$"

    # 无论成败都清理远端临时目录（RETURN trap 在函数退出时触发，含 set -e 中断）
    trap "sshpass -p '${pass}' ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
        '${user}@${host}' 'rm -rf ${remote_tmp}' 2>/dev/null || true" RETURN

    # 定位离线包
    local pkg_tar="${KA_PKG_DIR}/${codename}/keepalived-offline.tar.gz"
    if [ ! -f "${pkg_tar}" ]; then
        log_error "找不到 keepalived 离线包: ${pkg_tar}"
        log_warn "请将离线包放置到: packages/keepalived/${codename}/keepalived-offline.tar.gz"
        exit 1
    fi

    log_info "上传离线包和脚本到 [${host}]:${remote_tmp} ..."
    run_remote "${host}" "${user}" "${pass}" "mkdir -p ${remote_tmp}/lib"

    # 上传离线包（ssh cat 管道，绕过 scp 本地路径编码问题）
    log_info "上传到 [${user}@${host}]: keepalived-offline.tar.gz"
    sshpass -p "${pass}" ssh \
        -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
        "${user}@${host}" "cat > ${remote_tmp}/keepalived-offline.tar.gz" \
        < "${pkg_tar}"

    # 上传 lib/（tar 打包 | ssh 解包，绕过 scp 本地路径编码问题）
    log_info "上传到 [${user}@${host}]: lib/"
    tar -C "${SCRIPT_DIR}" -cf - lib | \
        sshpass -p "${pass}" ssh \
            -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
            "${user}@${host}" "tar -xf - -C ${remote_tmp}"

    # 上传 install.sh 本身
    log_info "上传到 [${user}@${host}]: install.sh"
    sshpass -p "${pass}" ssh \
        -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
        "${user}@${host}" "cat > ${remote_tmp}/install.sh" \
        < "${SCRIPT_DIR}/components/keepalived/install.sh"

    # 上传配置模板
    log_info "上传到 [${user}@${host}]: keepalived.conf.tmpl"
    sshpass -p "${pass}" ssh \
        -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
        "${user}@${host}" "cat > ${remote_tmp}/keepalived.conf.tmpl" \
        < "${SCRIPT_DIR}/components/keepalived/conf/keepalived.conf"

    # 远端执行（MODE=standalone 避免递归 SSH）
    run_remote "${host}" "${user}" "${pass}" \
        "SCRIPT_DIR=${remote_tmp} \
         KA_VIP='${KA_VIP}' \
         KA_INTERFACE='${KA_INTERFACE}' \
         KA_STATE=${ka_state} \
         KA_PRIORITY=${ka_priority} \
         MODE=standalone \
         bash ${remote_tmp}/install.sh"
}

# ─── 安装单台主机入口 ────────────────────────────────────────
install_keepalived_on_host() {
    local host="$1" user="$2" pass="$3"
    local ka_state="$4" ka_priority="$5"

    log_info "开始在 [${host}] 安装 Keepalived（${ka_state}，priority=${ka_priority}）..."

    local codename
    codename=$(_detect_codename_remote "${host}" "${user}" "${pass}")
    log_info "[${host}] 系统版本: Ubuntu ${codename}"

    _do_install_remote "${host}" "${user}" "${pass}" \
        "${ka_state}" "${ka_priority}" "${codename}"

    log_info "[${host}] Keepalived 安装完成"
}

# ─── 主流程 ───────────────────────────────────────────────────
main() {
    log_title "Keepalived 安装"

    # 远端执行分支（MODE=standalone 由本地调用时注入）
    if [ "${MODE:-}" = "standalone" ] && [ -n "${KA_STATE:-}" ]; then
        local pkg_tar="${SCRIPT_DIR}/keepalived-offline.tar.gz"
        if [ ! -f "${pkg_tar}" ]; then
            log_error "远端未找到离线包: ${pkg_tar}"
            exit 1
        fi
        _do_install_local "${pkg_tar}"
        return 0
    fi

    # 本地 ha 模式主流程
    if [ "${MODE:-}" != "ha" ]; then
        log_warn "Keepalived 仅在热备（ha）模式下安装，当前 MODE=${MODE:-}，跳过"
        return 0
    fi

    load_component_config "keepalived"
    KA_VIP="${KA_VIP:-}"
    KA_INTERFACE="${KA_INTERFACE:-eth0}"

    if [ -z "${KA_VIP}" ]; then
        log_error "未找到 keepalived 配置（KA_VIP 为空），请先完成配置步骤"
        exit 1
    fi

    # 主机：MASTER priority=100
    install_keepalived_on_host \
        "${MASTER_HOST}" "${MASTER_SSH_USER}" "${MASTER_SSH_PASS}" \
        "MASTER" "100"

    # 备机：BACKUP priority=90
    install_keepalived_on_host \
        "${SLAVE_HOST}" "${SLAVE_SSH_USER}" "${SLAVE_SSH_PASS}" \
        "BACKUP" "90"

    log_info "Keepalived 安装完成，VIP: ${KA_VIP}，网卡: ${KA_INTERFACE}"
}

main "$@"
