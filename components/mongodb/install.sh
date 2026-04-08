#!/usr/bin/env bash
# components/mongodb/install.sh — MongoDB 离线安装脚本
# 支持单机 / 热备（副本集 + Keepalived VIP）模式
# 热备架构：两节点副本集，Keepalived notify 脚本触发 rs.reconfig(force) 强制切主
# 适用系统: Ubuntu 20.04 / 22.04 / 24.04

if [ -z "${BASH_VERSION:-}" ]; then
    exec bash "$0" "$@"
fi

set -euo pipefail

source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/component_config.sh"

# ─── 读取组件配置 ─────────────────────────────────────────────
load_component_config "mongodb" || true
MONGO_PORT="${MONGO_PORT:-27017}"
MONGO_REPLSET="${MONGO_REPLSET:-rs0}"
MONGO_USER="${MONGO_USER:-admin}"
MONGO_PASS="${MONGO_PASS:-}"

if [ -z "${MONGO_PASS}" ]; then
    log_error "未找到 MongoDB 配置，请先完成配置步骤"
    exit 1
fi

MONGO_PKG_DIR="${SCRIPT_DIR}/packages/mongodb"

# ─── 检测系统版本 ─────────────────────────────────────────────
detect_ubuntu_codename() {
    local codename
    codename=$(grep '^VERSION_CODENAME=' /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"')
    if [ -z "${codename}" ]; then
        codename=$(lsb_release -cs 2>/dev/null || echo "unknown")
    fi
    echo "${codename}"
}

# ─── 安装单台机器的 MongoDB ──────────────────────────────────
install_mongo_on_host() {
    local host="$1"
    local user="$2"
    local pass="$3"
    local is_local="${4:-false}"
    local role="${5:-standalone}"   # standalone / master / slave

    log_info "开始在 [${host}] 安装 MongoDB（角色: ${role}）..."

    if [ "${is_local}" = "true" ]; then
        local codename
        codename=$(detect_ubuntu_codename)
        log_info "[${host}] 系统版本: Ubuntu ${codename}"
        local pkg_dir="${MONGO_PKG_DIR}/${codename}"
        [ ! -d "${pkg_dir}" ] && pkg_dir="${MONGO_PKG_DIR}"
        if [ ! -d "${pkg_dir}" ]; then
            log_error "找不到 MongoDB 安装包目录: ${MONGO_PKG_DIR}/${codename} 或 ${MONGO_PKG_DIR}"
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
    local work_dir="/tmp/mongo_install_$$"

    mkdir -p "${work_dir}"

    local tar_bundle
    tar_bundle=$(find "${pkg_dir}" -maxdepth 1 -name "mongodb-offline.tar.gz" 2>/dev/null | head -1)
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

    local deb_files=()
    while IFS= read -r -d '' f; do
        deb_files+=("$f")
    done < <(find "${work_dir}" -name "*.deb" -print0 | sort -z)

    if [ ${#deb_files[@]} -eq 0 ]; then
        log_error "未找到任何 deb 包，请检查离线包内容"
        rm -rf "${work_dir}"
        exit 1
    fi
    log_info "共找到 ${#deb_files[@]} 个 deb 包"

    echo "exit 101" > /usr/sbin/policy-rc.d
    chmod +x /usr/sbin/policy-rc.d

    log_info "安装 MongoDB 组件..."
    if ! DEBIAN_FRONTEND=noninteractive dpkg -i "${deb_files[@]}" 2>/dev/null; then
        DEBIAN_FRONTEND=noninteractive dpkg -i "${deb_files[@]}" || {
            rm -f /usr/sbin/policy-rc.d
            log_error "MongoDB 安装失败，请检查离线包完整性"
            rm -rf "${work_dir}"
            exit 1
        }
    fi

    rm -f /usr/sbin/policy-rc.d
    rm -rf "${work_dir}"

    _configure_mongo "${role}"

    # 热备模式：配置 Keepalived notify 脚本
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
    local remote_tmp="/tmp/mongo_install_$$"

    trap "sshpass -p '${pass}' ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
        '${user}@${host}' 'rm -rf ${remote_tmp}' 2>/dev/null || true" RETURN

    local codename
    codename=$(run_remote "${host}" "${user}" "${pass}" \
        "grep '^VERSION_CODENAME=' /etc/os-release | cut -d= -f2 | tr -d '\"'")
    log_info "[${host}] 系统版本: Ubuntu ${codename}"

    local pkg_dir="${MONGO_PKG_DIR}/${codename}"
    [ ! -d "${pkg_dir}" ] && pkg_dir="${MONGO_PKG_DIR}"
    if [ ! -d "${pkg_dir}" ]; then
        log_error "找不到 MongoDB 安装包目录: ${pkg_dir}"
        exit 1
    fi

    log_info "上传安装包到 [${host}]:${remote_tmp} ..."
    run_remote "${host}" "${user}" "${pass}" \
        "mkdir -p ${remote_tmp}/packages/mongodb/${codename} ${remote_tmp}/lib ${remote_tmp}/components/mongodb/conf"

    log_info "上传到 [${user}@${host}]: packages/mongodb/${codename}/"
    tar -C "${pkg_dir}" -cf - . | \
        sshpass -p "${pass}" ssh \
            -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
            "${user}@${host}" "tar -xf - -C ${remote_tmp}/packages/mongodb/${codename}/"

    log_info "上传到 [${user}@${host}]: components/mongodb/conf/"
    tar -C "${SCRIPT_DIR}/components/mongodb" -cf - conf | \
        sshpass -p "${pass}" ssh \
            -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
            "${user}@${host}" "tar -xf - -C ${remote_tmp}/components/mongodb/"

    log_info "上传到 [${user}@${host}]: lib/"
    tar -C "${SCRIPT_DIR}" -cf - lib | \
        sshpass -p "${pass}" ssh \
            -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
            "${user}@${host}" "tar -xf - -C ${remote_tmp}/"

    log_info "上传到 [${user}@${host}]: install.sh"
    sshpass -p "${pass}" ssh \
        -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
        "${user}@${host}" "cat > ${remote_tmp}/install.sh" \
        < "${SCRIPT_DIR}/components/mongodb/install.sh"

    run_remote "${host}" "${user}" "${pass}" \
        "SCRIPT_DIR=${remote_tmp} \
         MONGO_PORT=${MONGO_PORT} \
         MONGO_REPLSET=${MONGO_REPLSET} \
         MONGO_USER='${MONGO_USER}' \
         MONGO_PASS='${MONGO_PASS}' \
         MONGO_ROLE=${role} \
         MASTER_HOST=${MASTER_HOST:-} \
         SLAVE_HOST=${SLAVE_HOST:-} \
         MONGO_KEYFILE_CONTENT='${MONGO_KEYFILE_CONTENT:-}' \
         MODE=standalone \
         bash ${remote_tmp}/install.sh"
}

# ─── 写入 mongod.conf ─────────────────────────────────────────
_apply_conf() {
    local role="${1:-standalone}"
    local dest="/etc/mongod.conf"
    local tmpl_dir="${SCRIPT_DIR}/components/mongodb/conf"

    local tmpl
    if [ "${role}" = "standalone" ]; then
        tmpl="${tmpl_dir}/standalone.conf"
    else
        tmpl="${tmpl_dir}/replicaset.conf"
    fi

    if [ ! -f "${tmpl}" ]; then
        log_warn "未找到配置模板: ${tmpl}，跳过写入"
        return 0
    fi

    log_info "写入配置文件: ${dest}（模板: $(basename "${tmpl}")）"
    sed \
        -e "s/__MONGO_PORT__/${MONGO_PORT}/g" \
        -e "s/__MONGO_REPLSET__/${MONGO_REPLSET}/g" \
        "${tmpl}" > "${dest}"
}

# ─── 生成副本集 keyfile ───────────────────────────────────────
_setup_keyfile() {
    local keyfile="/etc/mongodb/keyfile"
    mkdir -p /etc/mongodb

    if [ -n "${MONGO_KEYFILE_CONTENT:-}" ]; then
        printf '%s' "${MONGO_KEYFILE_CONTENT}" > "${keyfile}"
    else
        openssl rand -base64 756 > "${keyfile}"
    fi

    chmod 400 "${keyfile}"
    chown mongodb:mongodb "${keyfile}" 2>/dev/null || true
    log_info "keyfile 已写入: ${keyfile}"
}

# ─── 配置并启动 MongoDB ───────────────────────────────────────
_configure_mongo() {
    local role="${1:-standalone}"

    log_info "配置 MongoDB 服务..."

    mkdir -p /var/lib/mongodb /var/log/mongodb
    chown -R mongodb:mongodb /var/lib/mongodb /var/log/mongodb 2>/dev/null || true

    # 热备模式需要 keyfile
    if [ "${role}" != "standalone" ]; then
        _setup_keyfile
    fi

    _apply_conf "${role}"

    systemctl daemon-reload
    systemctl enable mongod 2>/dev/null || true
    timeout 60 systemctl start mongod || {
        log_error "MongoDB 服务启动失败，请查看日志: journalctl -xe"
        exit 1
    }

    # 等待 mongod 就绪（最多 30 秒）
    local i=0
    while ! mongosh --port "${MONGO_PORT}" --eval "db.runCommand({ping:1})" --quiet &>/dev/null; do
        i=$(( i + 1 ))
        [ "${i}" -ge 15 ] && { log_error "MongoDB 启动超时"; exit 1; }
        sleep 2
    done

    # 单机模式直接创建管理员
    if [ "${role}" = "standalone" ]; then
        _create_admin_noauth
    fi

    local ver
    ver=$(mongosh --port "${MONGO_PORT}" --eval "db.version()" --quiet 2>/dev/null || echo "unknown")
    log_info "MongoDB 版本: ${ver}  端口: ${MONGO_PORT}"
}

# ─── 创建管理员（无认证状态下）──────────────────────────────
_create_admin_noauth() {
    log_info "创建管理员账号: ${MONGO_USER}..."
    mongosh --port "${MONGO_PORT}" --eval "
        try {
            db.getSiblingDB('admin').createUser({
                user: '${MONGO_USER}',
                pwd: '${MONGO_PASS}',
                roles: [{ role: 'root', db: 'admin' }]
            });
            print('管理员创建成功');
        } catch(e) {
            if (e.message && e.message.indexOf('already exists') !== -1) {
                print('管理员已存在，跳过');
            } else {
                throw e;
            }
        }
    " --quiet 2>/dev/null || log_warn "创建管理员账号失败，请手动创建"
}

# ─── 配置 Keepalived notify 脚本 ─────────────────────────────
_setup_keepalived_notify() {
    local role="$1"
    local local_ip="$2"
    local peer_ip="$3"
    local ka_dir="/etc/keepalived"
    local conf_dir="${SCRIPT_DIR}/components/mongodb/conf"

    log_info "配置 Keepalived notify 脚本（角色: ${role}）..."
    mkdir -p "${ka_dir}"

    sed \
        -e "s/__MONGO_PORT__/${MONGO_PORT}/g" \
        -e "s/__MONGO_USER__/${MONGO_USER}/g" \
        -e "s/__MONGO_PASS__/${MONGO_PASS}/g" \
        -e "s/__MONGO_REPLSET__/${MONGO_REPLSET}/g" \
        -e "s/__LOCAL_IP__/${local_ip}/g" \
        "${conf_dir}/notify_mongo_master.sh" > "${ka_dir}/notify_mongo_master.sh"
    chmod +x "${ka_dir}/notify_mongo_master.sh"

    sed \
        -e "s/__MONGO_PORT__/${MONGO_PORT}/g" \
        -e "s/__MONGO_USER__/${MONGO_USER}/g" \
        -e "s/__MONGO_PASS__/${MONGO_PASS}/g" \
        -e "s/__MONGO_REPLSET__/${MONGO_REPLSET}/g" \
        -e "s/__LOCAL_IP__/${local_ip}/g" \
        -e "s/__PEER_IP__/${peer_ip}/g" \
        "${conf_dir}/notify_mongo_backup.sh" > "${ka_dir}/notify_mongo_backup.sh"
    chmod +x "${ka_dir}/notify_mongo_backup.sh"

    log_info "notify 脚本已写入 ${ka_dir}/"

    # 追加到 keepalived.conf（若不存在则跳过，等 keepalived 安装后再追加）
    local ka_conf="${ka_dir}/keepalived.conf"
    if [ -f "${ka_conf}" ]; then
        if ! grep -q "notify_mongo_master" "${ka_conf}"; then
            log_info "追加 MongoDB notify 到 ${ka_conf}"
            sed -i "s|notify_master \"/etc/keepalived/notify_master.sh\"|notify_master \"/etc/keepalived/notify_master.sh\"\n    notify_master \"/etc/keepalived/notify_mongo_master.sh\"|" "${ka_conf}" 2>/dev/null || true
            sed -i "s|notify_backup \"/etc/keepalived/notify_backup.sh\"|notify_backup \"/etc/keepalived/notify_backup.sh\"\n    notify_backup \"/etc/keepalived/notify_mongo_backup.sh\"|" "${ka_conf}" 2>/dev/null || true
            systemctl reload keepalived 2>/dev/null || systemctl restart keepalived 2>/dev/null || true
        else
            log_info "keepalived.conf 已包含 MongoDB notify，跳过"
        fi
    else
        log_warn "未找到 ${ka_conf}，请确保 Keepalived 已安装，MongoDB notify 脚本已写入 ${ka_dir}/"
    fi

    # 立即初始化角色
    log_info "立即初始化 MongoDB 角色: ${role}"
    if [ "${role}" = "master" ]; then
        bash "${ka_dir}/notify_mongo_master.sh"
        log_info "MongoDB 已提升为 PRIMARY"
    else
        bash "${ka_dir}/notify_mongo_backup.sh"
        log_info "MongoDB 已设置为 SECONDARY，对端: ${peer_ip}:${MONGO_PORT}"
    fi

    sleep 2
    local rs_state
    rs_state=$(mongosh --port "${MONGO_PORT}" \
        -u "${MONGO_USER}" -p "${MONGO_PASS}" \
        --authenticationDatabase admin \
        --eval "rs.status().myState" --quiet 2>/dev/null || echo "unknown")
    # myState: 1=PRIMARY 2=SECONDARY
    log_info "MongoDB 副本集状态: myState=${rs_state}（1=PRIMARY 2=SECONDARY）"
}

# ─── 主流程 ───────────────────────────────────────────────────
main() {
    log_title "MongoDB 安装"

    local role="${MONGO_ROLE:-}"

    if [ "${MODE}" = "standalone" ]; then
        if [ -n "${role}" ] && [ "${role}" != "standalone" ]; then
            install_mongo_on_host "localhost" "" "" "true" "${role}"
        else
            install_mongo_on_host "localhost" "" "" "true" "standalone"
        fi

    elif [ "${MODE}" = "ha" ]; then
        # 热备模式：先生成 keyfile，两台机器共用同一份
        log_info "热备模式，生成副本集 keyfile..."
        export MONGO_KEYFILE_CONTENT
        MONGO_KEYFILE_CONTENT=$(openssl rand -base64 756 | tr -d '\n')

        log_info "安装主机 [${MASTER_HOST}]..."
        install_mongo_on_host "${MASTER_HOST}" "${MASTER_SSH_USER}" "${MASTER_SSH_PASS}" "false" "master" \
            || { log_error "主机 MongoDB 安装失败，终止"; exit 1; }

        log_info "安装备机 [${SLAVE_HOST}]..."
        install_mongo_on_host "${SLAVE_HOST}" "${SLAVE_SSH_USER}" "${SLAVE_SSH_PASS}" "false" "slave" \
            || { log_error "备机 MongoDB 安装失败，终止"; exit 1; }

        # 在主机初始化副本集（两节点都加入）
        log_info "在主机 [${MASTER_HOST}] 初始化副本集..."
        run_remote "${MASTER_HOST}" "${MASTER_SSH_USER}" "${MASTER_SSH_PASS}" \
            "mongosh --port ${MONGO_PORT} --eval \"
                rs.initiate({
                    _id: '${MONGO_REPLSET}',
                    members: [
                        { _id: 0, host: '${MASTER_HOST}:${MONGO_PORT}', priority: 2 },
                        { _id: 1, host: '${SLAVE_HOST}:${MONGO_PORT}',  priority: 1 }
                    ]
                });
            \" --quiet" || { log_error "副本集初始化失败"; exit 1; }

        # 轮询等待主机成为 PRIMARY（最多 60 秒）
        log_info "等待 [${MASTER_HOST}] 成为 PRIMARY..."
        local primary_ready=false
        for _i in $(seq 1 30); do
            local _state
            _state=$(run_remote "${MASTER_HOST}" "${MASTER_SSH_USER}" "${MASTER_SSH_PASS}" \
                "mongosh --port ${MONGO_PORT} --eval 'rs.status().myState' --quiet 2>/dev/null" || echo 0)
            if [ "${_state}" = "1" ]; then
                primary_ready=true
                log_info "[${MASTER_HOST}] 已成为 PRIMARY"
                break
            fi
            sleep 2
        done
        if [ "${primary_ready}" = "false" ]; then
            log_error "等待 PRIMARY 超时，请检查副本集状态"
            exit 1
        fi

        # 在主机创建管理员（副本集初始化后才能创建）
        log_info "在主机 [${MASTER_HOST}] 创建管理员账号..."
        run_remote "${MASTER_HOST}" "${MASTER_SSH_USER}" "${MASTER_SSH_PASS}" \
            "mongosh --port ${MONGO_PORT} --eval \"
                try {
                    db.getSiblingDB('admin').createUser({
                        user: '${MONGO_USER}',
                        pwd: '${MONGO_PASS}',
                        roles: [{ role: 'root', db: 'admin' }]
                    });
                    print('管理员创建成功');
                } catch(e) {
                    if (e.message && e.message.indexOf('already exists') !== -1) {
                        print('管理员已存在，跳过');
                    } else {
                        throw e;
                    }
                }
            \" --quiet" || { log_error "管理员账号创建失败"; exit 1; }

        # 验证副本集状态
        log_info "验证副本集状态..."
        run_remote "${MASTER_HOST}" "${MASTER_SSH_USER}" "${MASTER_SSH_PASS}" \
            "mongosh --port ${MONGO_PORT} \
             -u '${MONGO_USER}' -p '${MONGO_PASS}' \
             --authenticationDatabase admin \
             --eval \"rs.status().members.forEach(m => print(m.name, m.stateStr))\" \
             --quiet" || log_warn "副本集状态验证失败，请手动检查"
    fi

    log_info "MongoDB 安装完成"
}

main "$@"
