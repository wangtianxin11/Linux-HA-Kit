#!/usr/bin/env bash
# components/redis/install.sh — Redis 7.0 离线安装脚本
# 支持单机 / 热备模式
# 适用系统: Ubuntu 20.04 / 22.04 / 24.04

# sh→bash 自动切换守卫
if [ -z "${BASH_VERSION:-}" ]; then
    exec bash "$0" "$@"
fi

set -euo pipefail

source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/component_config.sh"

# ─── 读取组件配置 ─────────────────────────────────────────────
load_component_config "redis" || true
REDIS_PORT="${REDIS_PORT:-6379}"
REDIS_PASS="${REDIS_PASS:-}"

if [ -z "${REDIS_PASS}" ]; then
    log_error "未找到 Redis 配置，请先完成配置步骤"
    exit 1
fi

REDIS_PKG_DIR="${SCRIPT_DIR}/packages/redis"

# ─── 检测系统版本 ─────────────────────────────────────────────
detect_ubuntu_codename() {
    local codename
    codename=$(grep '^VERSION_CODENAME=' /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"')
    if [ -z "${codename}" ]; then
        codename=$(lsb_release -cs 2>/dev/null || echo "unknown")
    fi
    echo "${codename}"
}


# ─── 安装单台机器的 Redis ────────────────────────────────────
install_redis_on_host() {
    local host="$1"
    local user="$2"
    local pass="$3"
    local is_local="${4:-false}"
    local role="${5:-standalone}"   # standalone / master / replica

    log_info "开始在 [${host}] 安装 Redis（角色: ${role}）..."

    if [ "${is_local}" = "true" ]; then
        local codename
        codename=$(detect_ubuntu_codename)
        log_info "[${host}] 系统版本: Ubuntu ${codename}"
        local pkg_dir="${REDIS_PKG_DIR}/${codename}"
        [ ! -d "${pkg_dir}" ] && pkg_dir="${REDIS_PKG_DIR}"
        if [ ! -d "${pkg_dir}" ]; then
            log_error "找不到 Redis 安装包目录: ${REDIS_PKG_DIR}/${codename} 或 ${REDIS_PKG_DIR}"
            exit 1
        fi
        _do_install_local "${pkg_dir}" "${role}"
    else
        _do_install_remote "${host}" "${user}" "${pass}" "${role}"
    fi
}

# ─── 本地安装逻辑 ─────────────────────────────────────────────
_do_install_local() {
    local pkg_dir="$1"
    local role="${2:-standalone}"
    local work_dir="/tmp/redis_install_$$"

    mkdir -p "${work_dir}"

    # 查找离线包
    local tar_bundle
    tar_bundle=$(find "${pkg_dir}" -maxdepth 1 -name "redis-offline.tar.gz" 2>/dev/null | head -1)
    if [ -z "${tar_bundle}" ]; then
        tar_bundle=$(find "${pkg_dir}" -maxdepth 1 -name "*.tar.gz" 2>/dev/null | head -1)
    fi

    if [ -n "${tar_bundle}" ]; then
        log_info "解压离线包: $(basename "${tar_bundle}")"
        tar -xzf "${tar_bundle}" -C "${work_dir}"
    else
        log_info "使用目录中的 deb 文件: ${pkg_dir}"
        cp "${pkg_dir}"/*.deb "${work_dir}/" 2>/dev/null || true
    fi

    # 安装所有 deb 包
    log_info "安装 Redis 及依赖包..."
    local deb_files=()
    while IFS= read -r -d '' f; do
        deb_files+=("$f")
    done < <(find "${work_dir}" -name "*.deb" -print0 | sort -z)

    if [ ${#deb_files[@]} -eq 0 ]; then
        log_error "未找到任何 deb 包，请检查离线包内容"
        exit 1
    fi
    log_info "共找到 ${#deb_files[@]} 个 deb 包"

    # 阻止 dpkg postinst 自动启服务（装完再手动启，避免卡住）
    echo "exit 101" > /usr/sbin/policy-rc.d
    chmod +x /usr/sbin/policy-rc.d

    if ! DEBIAN_FRONTEND=noninteractive dpkg -i "${deb_files[@]}" 2>/dev/null; then
        log_warn "dpkg 安装出错，尝试修复依赖..."
        apt-get install -f -y 2>/dev/null || true
        DEBIAN_FRONTEND=noninteractive dpkg -i "${deb_files[@]}" || {
            rm -f /usr/sbin/policy-rc.d
            log_error "Redis 安装失败，请检查离线包完整性"
            rm -rf "${work_dir}"
            exit 1
        }
    fi

    # 恢复正常服务启动策略
    rm -f /usr/sbin/policy-rc.d

    # 清理临时目录
    rm -rf "${work_dir}"

    _configure_redis

    # 热备模式：配置 Keepalived notify 脚本并初始化角色
    if [ "${role}" != "standalone" ]; then
        local local_ip peer_ip
        if [ "${role}" = "master" ]; then
            local_ip="${MASTER_HOST}"
            peer_ip="${SLAVE_HOST}"
        else
            local_ip="${SLAVE_HOST}"
            peer_ip="${MASTER_HOST}"
        fi
        _setup_keepalived_notify "${role}" "${local_ip}" "${peer_ip}"
    fi
}

# ─── 远端安装逻辑 ─────────────────────────────────────────────
_do_install_remote() {
    local host="$1" user="$2" pass="$3"
    local role="${4:-standalone}"
    local remote_tmp="/tmp/redis_install_$$"

    # 无论成败都清理远端临时目录
    trap "sshpass -p '${pass}' ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
        '${user}@${host}' 'rm -rf ${remote_tmp}' 2>/dev/null || true" RETURN

    # 获取远端系统版本
    local codename
    codename=$(run_remote "${host}" "${user}" "${pass}" \
        "grep '^VERSION_CODENAME=' /etc/os-release | cut -d= -f2 | tr -d '\"'")
    log_info "[${host}] 系统版本: Ubuntu ${codename}"

    local pkg_dir="${REDIS_PKG_DIR}/${codename}"
    [ ! -d "${pkg_dir}" ] && pkg_dir="${REDIS_PKG_DIR}"
    if [ ! -d "${pkg_dir}" ]; then
        log_error "找不到 Redis 安装包目录: ${pkg_dir}"
        exit 1
    fi

    log_info "上传安装包到 [${host}]:${remote_tmp} ..."
    run_remote "${host}" "${user}" "${pass}" \
        "mkdir -p ${remote_tmp}/packages/redis/${codename} ${remote_tmp}/lib ${remote_tmp}/components/redis/conf"

    # 上传离线包（tar 管道，绕过 scp 中文路径问题）
    log_info "上传到 [${user}@${host}]: packages/redis/${codename}/"
    tar -C "${pkg_dir}" -cf - . | \
        sshpass -p "${pass}" ssh \
            -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
            "${user}@${host}" "tar -xf - -C ${remote_tmp}/packages/redis/${codename}/"

    # 上传 conf 模板
    log_info "上传到 [${user}@${host}]: components/redis/conf/"
    tar -C "${SCRIPT_DIR}/components/redis" -cf - conf | \
        sshpass -p "${pass}" ssh \
            -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
            "${user}@${host}" "tar -xf - -C ${remote_tmp}/components/redis/"

    # 上传 lib/
    log_info "上传到 [${user}@${host}]: lib/"
    tar -C "${SCRIPT_DIR}" -cf - lib | \
        sshpass -p "${pass}" ssh \
            -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
            "${user}@${host}" "tar -xf - -C ${remote_tmp}/"

    # 上传 install.sh
    log_info "上传到 [${user}@${host}]: install.sh"
    sshpass -p "${pass}" ssh \
        -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
        "${user}@${host}" "cat > ${remote_tmp}/install.sh" \
        < "${SCRIPT_DIR}/components/redis/install.sh"

    # 远端执行：强制 MODE=standalone，通过 REDIS_ROLE 区分主从
    run_remote "${host}" "${user}" "${pass}" \
        "SCRIPT_DIR=${remote_tmp} \
         REDIS_PORT=${REDIS_PORT} \
         REDIS_PASS='${REDIS_PASS}' \
         REDIS_ROLE=${role} \
         MASTER_HOST=${MASTER_HOST:-} \
         SLAVE_HOST=${SLAVE_HOST:-} \
         MODE=standalone \
         bash ${remote_tmp}/install.sh"
}

# ─── 写入 redis.conf（从模板替换占位符）────────────────────
_configure_redis() {
    log_info "配置 Redis 服务..."

    local tmpl="${SCRIPT_DIR}/components/redis/conf/redis.conf"
    local dest="/etc/redis/redis.conf"

    if [ ! -f "${tmpl}" ]; then
        log_warn "未找到配置模板: ${tmpl}，跳过写入"
    else
        log_info "写入配置文件: ${dest}"
        mkdir -p "$(dirname "${dest}")"
        mkdir -p /var/log/redis
        sed \
            -e "s/__REDIS_PORT__/${REDIS_PORT}/g" \
            -e "s/__REDIS_PASS__/${REDIS_PASS}/g" \
            "${tmpl}" > "${dest}"
    fi

    # 启动服务
    systemctl daemon-reload
    systemctl enable redis-server 2>/dev/null || true
    timeout 30 systemctl start redis-server || {
        log_error "Redis 服务启动失败，请查看日志: journalctl -xe"
        exit 1
    }

    # 验证服务
    sleep 1
    local pong
    pong=$(redis-cli -p "${REDIS_PORT}" -a "${REDIS_PASS}" ping 2>/dev/null || echo "FAILED")
    if [ "${pong}" != "PONG" ]; then
        log_error "Redis 验证失败（redis-cli ping 返回: ${pong}），请检查日志"
        exit 1
    fi

    local ver
    ver=$(redis-cli -p "${REDIS_PORT}" -a "${REDIS_PASS}" info server 2>/dev/null | grep 'redis_version:' | cut -d: -f2 | tr -d '\r')
    log_info "Redis 版本: ${ver}  端口: ${REDIS_PORT}"
}

# ─── 配置 Keepalived notify 脚本并初始化角色 ────────────────
# 用法: _setup_keepalived_notify ROLE LOCAL_IP PEER_IP
_setup_keepalived_notify() {
    local role="$1"
    local local_ip="$2"
    local peer_ip="$3"
    local ka_dir="/etc/keepalived"
    local conf_dir="${SCRIPT_DIR}/components/redis/conf"

    log_info "配置 Keepalived notify 脚本（角色: ${role}）..."

    mkdir -p "${ka_dir}"

    # 生成 notify_redis_master.sh
    sed \
        -e "s/__REDIS_PASS__/${REDIS_PASS}/g" \
        -e "s/__REDIS_PORT__/${REDIS_PORT}/g" \
        -e "s/__LOCAL_IP__/${local_ip}/g" \
        "${conf_dir}/notify_redis_master.sh" > "${ka_dir}/notify_redis_master.sh"
    chmod +x "${ka_dir}/notify_redis_master.sh"

    # 生成 notify_redis_backup.sh
    sed \
        -e "s/__REDIS_PASS__/${REDIS_PASS}/g" \
        -e "s/__REDIS_PORT__/${REDIS_PORT}/g" \
        -e "s/__LOCAL_IP__/${local_ip}/g" \
        -e "s/__PEER_IP__/${peer_ip}/g" \
        "${conf_dir}/notify_redis_backup.sh" > "${ka_dir}/notify_redis_backup.sh"
    chmod +x "${ka_dir}/notify_redis_backup.sh"

    log_info "notify 脚本已写入 ${ka_dir}/"

    # 追加 notify_master / notify_backup 到 keepalived.conf（若不存在）
    local ka_conf="${ka_dir}/keepalived.conf"
    if [ -f "${ka_conf}" ]; then
        if ! grep -q "notify_redis_master" "${ka_conf}"; then
            log_info "追加 notify_master/notify_backup 到 ${ka_conf}"
            # 在最后一个 } 前插入两行（vrrp_instance 块结尾）
            sed -i "s|^\(}\s*\)$|    notify_master \"${ka_dir}/notify_redis_master.sh\"\n    notify_backup \"${ka_dir}/notify_redis_backup.sh\"\n}|" "${ka_conf}"
            # 若上面的 sed 没匹配到（格式差异），直接追加到文件末尾的 } 前
            if ! grep -q "notify_redis_master" "${ka_conf}"; then
                # fallback：直接在最后一行 } 前插入
                sed -i '$s/^}/    notify_master "'"${ka_dir}"'\/notify_redis_master.sh"\n    notify_backup "'"${ka_dir}"'\/notify_redis_backup.sh"\n}/' "${ka_conf}"
            fi
        else
            log_info "keepalived.conf 已包含 notify 配置，跳过追加"
        fi

        # 重载 keepalived
        systemctl reload keepalived 2>/dev/null || systemctl restart keepalived 2>/dev/null || true
    else
        log_warn "未找到 ${ka_conf}，请手动将 notify 配置添加到 keepalived.conf"
    fi

    # 立即初始化 Redis 角色
    log_info "立即初始化 Redis 角色: ${role}"
    if [ "${role}" = "master" ]; then
        bash "${ka_dir}/notify_redis_master.sh"
        log_info "Redis 已提升为主库（MASTER）"
    else
        bash "${ka_dir}/notify_redis_backup.sh"
        log_info "Redis 已设置为从库（REPLICA），对端主库: ${peer_ip}:${REDIS_PORT}"
    fi

    # 打印最终主从状态
    sleep 1
    local role_info
    role_info=$(redis-cli -p "${REDIS_PORT}" -a "${REDIS_PASS}" info replication 2>/dev/null | grep -E 'role:|master_host:|master_link_status:' || true)
    log_info "Redis 复制状态: ${role_info}"
}

# ─── 主流程 ───────────────────────────────────────────────────
main() {
    log_title "Redis 安装"

    # 支持远端调用时通过环境变量传入角色
    local role="${REDIS_ROLE:-}"

    if [ "${MODE}" = "standalone" ]; then
        if [ -n "${role}" ] && [ "${role}" != "standalone" ]; then
            # 由 _do_install_remote 调用，直接本地安装并配置指定角色
            install_redis_on_host "localhost" "" "" "true" "${role}"
        else
            install_redis_on_host "localhost" "" "" "true" "standalone"
        fi

    elif [ "${MODE}" = "ha" ]; then
        log_info "热备模式，安装主机 [${MASTER_HOST}]..."
        install_redis_on_host "${MASTER_HOST}" "${MASTER_SSH_USER}" "${MASTER_SSH_PASS}" "false" "master"

        log_info "安装备机 [${SLAVE_HOST}]..."
        install_redis_on_host "${SLAVE_HOST}" "${SLAVE_SSH_USER}" "${SLAVE_SSH_PASS}" "false" "replica"
    fi

    log_info "Redis 安装完成"
}

main "$@"
