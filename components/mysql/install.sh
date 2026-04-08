#!/usr/bin/env bash
# components/mysql/install.sh — MySQL 8.0 离线安装脚本
# 支持单机 / 热备模式
# 适用系统: Ubuntu 20.04 / 22.04 / 24.04

source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/component_config.sh"

# ─── 读取组件配置 ─────────────────────────────────────────────
load_component_config "mysql"
MYSQL_PORT="${MYSQL_PORT:-3306}"
MYSQL_ROOT_PASS="${MYSQL_ROOT_PASS:-}"

if [ -z "${MYSQL_ROOT_PASS}" ]; then
    log_error "未找到 MySQL 配置，请先完成配置步骤"
    exit 1
fi

MYSQL_PKG_DIR="${SCRIPT_DIR}/packages/mysql"

# ─── 检测系统版本，确定包目录 ────────────────────────────────
detect_ubuntu_codename() {
    local codename
    codename=$(grep '^VERSION_CODENAME=' /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"')
    if [ -z "${codename}" ]; then
        codename=$(lsb_release -cs 2>/dev/null || echo "unknown")
    fi
    echo "${codename}"
}

# ─── 安装单台机器的 MySQL ────────────────────────────────────
install_mysql_on_host() {
    local host="$1"
    local user="$2"
    local pass="$3"
    local is_local="${4:-false}"
    local mode="${5:-standalone}"
    local server_id="${6:-1}"
    local ai_offset="${7:-1}"

    log_info "开始在 [${host}] 安装 MySQL..."

    local codename
    if [ "${is_local}" = "true" ]; then
        codename=$(detect_ubuntu_codename)
    else
        codename=$(run_remote "${host}" "${user}" "${pass}" \
            "grep '^VERSION_CODENAME=' /etc/os-release | cut -d= -f2 | tr -d '\"'")
    fi
    log_info "[${host}] 系统版本: Ubuntu ${codename}"

    # 查找本地包目录：优先精确版本目录，其次通用目录
    local pkg_dir="${MYSQL_PKG_DIR}/${codename}"
    if [ ! -d "${pkg_dir}" ]; then
        pkg_dir="${MYSQL_PKG_DIR}"
    fi

    if [ ! -d "${pkg_dir}" ]; then
        log_error "找不到 MySQL 安装包目录: ${pkg_dir}"
        log_warn "请将 MySQL deb 包放到以下目录之一:"
        log_warn "  ${MYSQL_PKG_DIR}/${codename}/"
        log_warn "  ${MYSQL_PKG_DIR}/"
        exit 1
    fi

    # 查找 tar bundle 或直接的 deb 文件
    local tar_bundle
    tar_bundle=$(find "${pkg_dir}" -maxdepth 1 -name "mysql-server_*.tar" 2>/dev/null | head -1)

    if [ "${is_local}" = "true" ]; then
        _do_install_local "${pkg_dir}" "${tar_bundle}" "${mode}" "${server_id}" "${ai_offset}"
    else
        _do_install_remote "${host}" "${user}" "${pass}" "${pkg_dir}" "${tar_bundle}" \
            "${mode}" "${server_id}" "${ai_offset}" "${codename}"
    fi
}

# ─── 本地安装逻辑 ─────────────────────────────────────────────
_do_install_local() {
    local pkg_dir="$1"
    local tar_bundle="$2"
    local mode="${3:-standalone}"
    local server_id="${4:-1}"
    local ai_offset="${5:-1}"
    local work_dir="/tmp/mysql_install_$$"

    mkdir -p "${work_dir}"

    # 解压 tar bundle 或直接使用 deb 文件
    if [ -n "${tar_bundle}" ]; then
        log_info "解压安装包: $(basename "${tar_bundle}")"
        tar -xf "${tar_bundle}" -C "${work_dir}"
    else
        log_info "使用目录中的 deb 文件: ${pkg_dir}"
        cp "${pkg_dir}"/*.deb "${work_dir}/" 2>/dev/null || true
    fi

    # 安装依赖包（libaio / libmecab2）
    log_info "安装依赖包..."
    for dep_deb in "${pkg_dir}"/libaio*.deb "${pkg_dir}"/libmecab*.deb; do
        [ -f "${dep_deb}" ] && dpkg -i "${dep_deb}" 2>/dev/null || true
    done
    # 系统若已有则跳过
    dpkg -l libaio1t64 &>/dev/null || dpkg -l libaio1 &>/dev/null || \
        log_warn "未找到 libaio 离线包，若安装失败请手动安装 libaio1t64"

    # 按依赖顺序安装 MySQL 组件
    log_info "按顺序安装 MySQL 组件..."
    local install_order=(
        "mysql-common_"
        "mysql-community-client-plugins_"
        "mysql-community-client-core_"
        "libmysqlclient21_"
        "mysql-community-server-core_"
        "mysql-community-client_"
        "mysql-client_"
        "mysql-community-server_"
        "mysql-server_"
    )

    for prefix in "${install_order[@]}"; do
        local deb_file
        deb_file=$(find "${work_dir}" -maxdepth 1 -name "${prefix}*.deb" 2>/dev/null | head -1)
        if [ -n "${deb_file}" ]; then
            log_info "安装: $(basename "${deb_file}")"
            DEBIAN_FRONTEND=noninteractive dpkg -i "${deb_file}"
        else
            log_warn "未找到组件包: ${prefix}*.deb，跳过"
        fi
    done

    # 清理临时目录
    rm -rf "${work_dir}"

    _configure_mysql "${mode}" "${server_id}" "${ai_offset}"
}

# ─── 远端安装逻辑 ─────────────────────────────────────────────
_do_install_remote() {
    local host="$1" user="$2" pass="$3" pkg_dir="$4" tar_bundle="$5"
    local mode="${6:-standalone}"
    local server_id="${7:-1}"
    local ai_offset="${8:-1}"
    local codename="$9"       # 由 install_mysql_on_host 传入，远端已探测好的版本代号
    local remote_tmp="/tmp/mysql_install_$$"

    log_info "上传安装包到 [${host}]:${remote_tmp} ..."
    # 在远端重建目录结构，包目录统一命名为 codename（如 noble），
    # 这样远端 detect_ubuntu_codename 返回 noble 后能精确命中
    run_remote "${host}" "${user}" "${pass}" \
        "mkdir -p ${remote_tmp}/packages/mysql/${codename} ${remote_tmp}/components/mysql"

    # 把 pkg_dir 的内容（*.deb 及子目录）上传到 packages/mysql/<codename>/
    # scp -r src/ dst：当 dst 已存在时，把 src 内容放入 dst；不加 / 则把 src 目录本身放入 dst
    # 此处目标已建好，传 ${pkg_dir}/ 的内容
    sshpass -p "${pass}" scp \
        -o StrictHostKeyChecking=no \
        -o ConnectTimeout=10 \
        -r "${pkg_dir}/." \
        "${user}@${host}:${remote_tmp}/packages/mysql/${codename}/"

    # 上传 my.cnf 配置模板目录
    copy_to_remote "${host}" "${user}" "${pass}" \
        "${SCRIPT_DIR}/components/mysql/conf" "${remote_tmp}/components/mysql"

    # 将本地 install.sh 和 lib 传过去，在远端执行
    copy_to_remote "${host}" "${user}" "${pass}" "${SCRIPT_DIR}/lib" "${remote_tmp}/lib"
    copy_to_remote "${host}" "${user}" "${pass}" \
        "${SCRIPT_DIR}/components/mysql/install.sh" "${remote_tmp}/install.sh"

    # 远端执行安装：强制 MODE=standalone，避免远端再次递归 SSH 到其他主机
    # HA_NODE=1 告知远端使用双主配置模板
    local ha_node=0
    [ "${mode}" = "ha" ] && ha_node=1
    run_remote "${host}" "${user}" "${pass}" \
        "SCRIPT_DIR=${remote_tmp} \
         MYSQL_PORT=${MYSQL_PORT} \
         MYSQL_ROOT_PASS='${MYSQL_ROOT_PASS}' \
         MODE=standalone \
         HA_NODE=${ha_node} \
         SERVER_ID_OVERRIDE=${server_id} \
         AI_OFFSET_OVERRIDE=${ai_offset} \
         bash ${remote_tmp}/install.sh"

    # 清理远端临时文件
    run_remote "${host}" "${user}" "${pass}" "rm -rf ${remote_tmp}"
}

# ─── 写入 my.cnf（从模板替换占位符）────────────────────────
# 用法: _apply_cnf MODE SERVER_ID AUTO_INCREMENT_OFFSET
_apply_cnf() {
    local mode="${1:-standalone}"
    local server_id="${2:-1}"
    local ai_offset="${3:-1}"
    local dest="/etc/mysql/mysql.conf.d/mysqld.cnf"
    local tmpl_dir="${SCRIPT_DIR}/components/mysql/conf"

    local tmpl
    # HA_NODE=1 由远端调用时注入，表示当前节点是热备节点（使用双主模板）
    if [ "${mode}" = "ha" ] || [ "${HA_NODE:-0}" = "1" ]; then
        tmpl="${tmpl_dir}/dual-master.cnf"
    else
        tmpl="${tmpl_dir}/standalone.cnf"
    fi

    if [ ! -f "${tmpl}" ]; then
        log_warn "未找到配置模板: ${tmpl}，跳过写入"
        return 0
    fi

    log_info "写入配置文件: ${dest}（模板: $(basename "${tmpl}")）"
    mkdir -p "$(dirname "${dest}")"
    sed \
        -e "s/__MYSQL_PORT__/${MYSQL_PORT}/g" \
        -e "s/__SERVER_ID__/${server_id}/g" \
        -e "s/__AUTO_INCREMENT_OFFSET__/${ai_offset}/g" \
        "${tmpl}" > "${dest}"
}

# ─── 配置 MySQL ───────────────────────────────────────────────
# 用法: _configure_mysql MODE SERVER_ID AUTO_INCREMENT_OFFSET
_configure_mysql() {
    local mode="${1:-standalone}"
    local server_id="${2:-1}"
    local ai_offset="${3:-1}"

    log_info "配置 MySQL 服务..."

    # 写入 my.cnf
    _apply_cnf "${mode}" "${server_id}" "${ai_offset}"

    # 启动服务
    systemctl enable mysql 2>/dev/null || true
    systemctl start mysql 2>/dev/null || {
        log_error "MySQL 服务启动失败，请查看日志: journalctl -xe"
        exit 1
    }

    # 获取临时 root 密码
    local tmp_pass=""
    for lf in "/var/log/mysqld.log" "/var/log/mysql/error.log"; do
        if [ -f "${lf}" ]; then
            tmp_pass=$(grep 'temporary password' "${lf}" 2>/dev/null | tail -1 | awk '{print $NF}')
            [ -n "${tmp_pass}" ] && break
        fi
    done

    # 修改 root 密码 & 开启远程访问
    log_info "初始化 root 账号..."
    if [ -n "${tmp_pass}" ]; then
        mysql --connect-expired-password -u root -p"${tmp_pass}" <<EOF 2>/dev/null
ALTER USER 'root'@'localhost' IDENTIFIED BY '${MYSQL_ROOT_PASS}';
CREATE USER IF NOT EXISTS 'root'@'%' IDENTIFIED BY '${MYSQL_ROOT_PASS}';
GRANT ALL PRIVILEGES ON *.* TO 'root'@'%' WITH GRANT OPTION;
FLUSH PRIVILEGES;
EOF
    else
        mysql -u root <<EOF 2>/dev/null
ALTER USER 'root'@'localhost' IDENTIFIED BY '${MYSQL_ROOT_PASS}';
CREATE USER IF NOT EXISTS 'root'@'%' IDENTIFIED BY '${MYSQL_ROOT_PASS}';
GRANT ALL PRIVILEGES ON *.* TO 'root'@'%' WITH GRANT OPTION;
FLUSH PRIVILEGES;
EOF
    fi

    systemctl restart mysql

    log_info "验证 MySQL 服务状态..."
    systemctl is-active mysql && log_info "MySQL 服务运行正常" || \
        log_error "MySQL 服务异常，请检查日志"

    local ver
    ver=$(mysql -u root -p"${MYSQL_ROOT_PASS}" -e "SELECT VERSION();" 2>/dev/null | tail -1)
    log_info "MySQL 版本: ${ver}  端口: ${MYSQL_PORT}"
}

# ─── 热备：创建复制账号（在主库执行）────────────────────────
_create_replicator() {
    log_info "创建复制账号 replicator..."
    mysql -u root -p"${MYSQL_ROOT_PASS}" <<EOF 2>/dev/null
CREATE USER IF NOT EXISTS 'replicator'@'%' IDENTIFIED BY '${MYSQL_ROOT_PASS}';
GRANT REPLICATION SLAVE ON *.* TO 'replicator'@'%';
FLUSH PRIVILEGES;
EOF
}

# ─── 热备：配置某节点指向对端为主库 ─────────────────────────
# 用法: _setup_slave_to PEER_HOST
_setup_slave_to() {
    local peer_host="$1"
    log_info "配置复制：指向对端主库 [${peer_host}:${MYSQL_PORT}]..."

    # 获取对端 binlog 位置（指定端口）
    local master_status binlog_file binlog_pos
    master_status=$(mysql -h "${peer_host}" -P "${MYSQL_PORT}" -u replicator -p"${MYSQL_ROOT_PASS}" \
        -e "SHOW MASTER STATUS\G" 2>/dev/null)
    binlog_file=$(echo "${master_status}" | grep 'File:'     | awk '{print $2}')
    binlog_pos=$(echo  "${master_status}" | grep 'Position:' | awk '{print $2}')

    mysql -u root -P "${MYSQL_PORT}" -p"${MYSQL_ROOT_PASS}" <<EOF 2>/dev/null
STOP SLAVE;
CHANGE MASTER TO
    MASTER_HOST='${peer_host}',
    MASTER_PORT=${MYSQL_PORT},
    MASTER_USER='replicator',
    MASTER_PASSWORD='${MYSQL_ROOT_PASS}',
    MASTER_LOG_FILE='${binlog_file}',
    MASTER_LOG_POS=${binlog_pos};
START SLAVE;
EOF

    local status
    status=$(mysql -u root -p"${MYSQL_ROOT_PASS}" \
        -e "SHOW SLAVE STATUS\G" 2>/dev/null | grep 'Running:')
    log_info "复制状态: ${status}"
}

# ─── 主流程 ───────────────────────────────────────────────────
main() {
    log_title "MySQL 安装"

    if [ "${MODE}" = "standalone" ]; then
        # 支持远端调用时通过环境变量覆盖 server_id 和 ai_offset
        local sid="${SERVER_ID_OVERRIDE:-1}"
        local aio="${AI_OFFSET_OVERRIDE:-1}"
        install_mysql_on_host "localhost" "" "" "true" "standalone" "${sid}" "${aio}"

    elif [ "${MODE}" = "ha" ]; then
        # 热备双主：主机 server-id=1 offset=1，备机 server-id=2 offset=2
        log_info "热备模式，安装主机 [${MASTER_HOST}]..."
        install_mysql_on_host "${MASTER_HOST}" "${MASTER_SSH_USER}" "${MASTER_SSH_PASS}" "false" "ha" "1" "1" \
            || { log_error "主机 MySQL 安装失败，终止"; exit 1; }

        log_info "安装备机 [${SLAVE_HOST}]..."
        install_mysql_on_host "${SLAVE_HOST}" "${SLAVE_SSH_USER}" "${SLAVE_SSH_PASS}" "false" "ha" "2" "2" \
            || { log_error "备机 MySQL 安装失败，终止"; exit 1; }

        # 双主互为主从：各自在对端创建复制账号，再互相指向
        log_info "配置双主复制..."
        run_remote "${MASTER_HOST}" "${MASTER_SSH_USER}" "${MASTER_SSH_PASS}" \
            "mysql -u root -p'${MYSQL_ROOT_PASS}' -e \
            \"CREATE USER IF NOT EXISTS 'replicator'@'%' IDENTIFIED BY '${MYSQL_ROOT_PASS}'; \
              GRANT REPLICATION SLAVE ON *.* TO 'replicator'@'%'; \
              FLUSH PRIVILEGES;\""

        run_remote "${SLAVE_HOST}" "${SLAVE_SSH_USER}" "${SLAVE_SSH_PASS}" \
            "mysql -u root -p'${MYSQL_ROOT_PASS}' -e \
            \"CREATE USER IF NOT EXISTS 'replicator'@'%' IDENTIFIED BY '${MYSQL_ROOT_PASS}'; \
              GRANT REPLICATION SLAVE ON *.* TO 'replicator'@'%'; \
              FLUSH PRIVILEGES;\""

        # 主机指向备机，备机指向主机
        log_info "主机指向备机，备机指向主机..."
        _run_slave_setup_remote \
            "${MASTER_HOST}" "${MASTER_SSH_USER}" "${MASTER_SSH_PASS}" \
            "${SLAVE_HOST}"  "${SLAVE_SSH_USER}"  "${SLAVE_SSH_PASS}"
        _run_slave_setup_remote \
            "${SLAVE_HOST}"  "${SLAVE_SSH_USER}"  "${SLAVE_SSH_PASS}" \
            "${MASTER_HOST}" "${MASTER_SSH_USER}" "${MASTER_SSH_PASS}"
    fi

    log_info "MySQL 安装完成"
}

# ─── 在远端执行指向 peer 的复制配置 ──────────────────────────
_run_slave_setup_remote() {
    local host="$1" user="$2" pass="$3"
    local peer="$4" peer_user="$5" peer_pass="$6"
    log_info "[${host}] 开始复制 → [${peer}]"

    # 获取 peer 的 binlog 位置（使用 peer 自己的凭据连接，指定端口）
    local master_status binlog_file binlog_pos
    master_status=$(run_remote "${peer}" "${peer_user}" "${peer_pass}" \
        "mysql -u root -P ${MYSQL_PORT} -p'${MYSQL_ROOT_PASS}' -e 'SHOW MASTER STATUS\G' 2>/dev/null")
    binlog_file=$(echo "${master_status}" | grep 'File:'     | awk '{print $2}')
    binlog_pos=$(echo  "${master_status}" | grep 'Position:' | awk '{print $2}')

    run_remote "${host}" "${user}" "${pass}" \
        "mysql -u root -P ${MYSQL_PORT} -p'${MYSQL_ROOT_PASS}' <<'SQL'
STOP SLAVE;
CHANGE MASTER TO
    MASTER_HOST='${peer}',
    MASTER_PORT=${MYSQL_PORT},
    MASTER_USER='replicator',
    MASTER_PASSWORD='${MYSQL_ROOT_PASS}',
    MASTER_LOG_FILE='${binlog_file}',
    MASTER_LOG_POS=${binlog_pos};
START SLAVE;
SQL"

    log_info "[${host}] 复制启动完成"
}

main "$@"
