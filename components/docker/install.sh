#!/usr/bin/env bash
# components/docker/install.sh — Docker CE 离线安装脚本
# 支持单机 / 热备模式（热备模式即在两台机器上各自独立安装）
# 适用系统: Ubuntu 20.04 / 22.04 / 24.04

if [ -z "${BASH_VERSION:-}" ]; then
    exec bash "$0" "$@"
fi

set -euo pipefail

source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/component_config.sh"

# ─── 读取组件配置 ─────────────────────────────────────────────
load_component_config "docker" || true
DOCKER_REMOTE_PORT="${DOCKER_REMOTE_PORT:-2375}"

DOCKER_PKG_DIR="${SCRIPT_DIR}/packages/docker"

# ─── 检测系统版本 ─────────────────────────────────────────────
detect_ubuntu_codename() {
    local codename
    codename=$(grep '^VERSION_CODENAME=' /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"')
    if [ -z "${codename}" ]; then
        codename=$(lsb_release -cs 2>/dev/null || echo "unknown")
    fi
    echo "${codename}"
}

# ─── 清理 macOS 元数据文件 ────────────────────────────────────
_clean_macos_metadata() {
    local dir="$1"
    local count
    count=$(find "${dir}" \( -name "._*" -o -name ".DS_Store" -o -path "*/__MACOSX/*" \) 2>/dev/null | wc -l | tr -d " ")
    if [ "${count}" -gt 0 ]; then
        log_warn "检测到 ${count} 个 macOS 元数据文件，自动清理"
        find "${dir}" \( -name "._*" -o -name ".DS_Store" -o -path "*/__MACOSX/*" \) -delete 2>/dev/null || true
    fi
}

# ─── 安装单台机器的 Docker ────────────────────────────────────
install_docker_on_host() {
    local host="$1"
    local user="$2"
    local pass="$3"
    local is_local="${4:-false}"

    log_info "开始在 [${host}] 安装 Docker..."

    if [ "${is_local}" = "true" ]; then
        local codename
        codename=$(detect_ubuntu_codename)
        log_info "[${host}] 系统版本: Ubuntu ${codename}"
        local pkg_dir="${DOCKER_PKG_DIR}/${codename}"
        [ ! -d "${pkg_dir}" ] && pkg_dir="${DOCKER_PKG_DIR}"
        if [ ! -d "${pkg_dir}" ]; then
            log_error "找不到 Docker 安装包目录: ${DOCKER_PKG_DIR}/${codename} 或 ${DOCKER_PKG_DIR}"
            exit 1
        fi
        _do_install_local "${pkg_dir}"
    else
        _do_install_remote "${host}" "${user}" "${pass}"
    fi
}

# ─── 本地安装逻辑 ─────────────────────────────────────────────
_do_install_local() {
    local pkg_dir="$1"
    local work_dir="/tmp/docker_install_$$"

    mkdir -p "${work_dir}"

    local tar_bundle
    tar_bundle=$(find "${pkg_dir}" -maxdepth 1 -name "docker-offline.tar.gz" 2>/dev/null | head -1)
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

    # 清理 macOS 元数据文件（._*.deb 等）
    _clean_macos_metadata "${work_dir}"

    local deb_files=()
    while IFS= read -r -d '' f; do
        deb_files+=("$f")
    done < <(find "${work_dir}" -type f -name "*.deb" ! -name "._*" ! -path "*/__MACOSX/*" -print0 | sort -z)

    if [ ${#deb_files[@]} -eq 0 ]; then
        log_error "未找到任何 deb 包，请检查离线包内容"
        rm -rf "${work_dir}"
        exit 1
    fi
    log_info "共找到 ${#deb_files[@]} 个 deb 包"

    echo "exit 101" > /usr/sbin/policy-rc.d
    chmod +x /usr/sbin/policy-rc.d

    log_info "安装 Docker 组件..."
    if ! DEBIAN_FRONTEND=noninteractive dpkg -i "${deb_files[@]}" 2>/dev/null; then
        DEBIAN_FRONTEND=noninteractive dpkg -i "${deb_files[@]}" || {
            rm -f /usr/sbin/policy-rc.d
            log_error "Docker 安装失败，请检查离线包完整性"
            rm -rf "${work_dir}"
            exit 1
        }
    fi

    rm -f /usr/sbin/policy-rc.d
    rm -rf "${work_dir}"

    _configure_docker
}

# ─── 远端安装逻辑 ─────────────────────────────────────────────
_do_install_remote() {
    local host="$1" user="$2" pass="$3"
    local remote_tmp="/tmp/docker_install_$$"

    trap "sshpass -p '${pass}' ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
        '${user}@${host}' 'rm -rf ${remote_tmp}' 2>/dev/null || true" RETURN

    local codename
    codename=$(run_remote "${host}" "${user}" "${pass}" \
        "grep '^VERSION_CODENAME=' /etc/os-release | cut -d= -f2 | tr -d '\"'")
    log_info "[${host}] 系统版本: Ubuntu ${codename}"

    local pkg_dir="${DOCKER_PKG_DIR}/${codename}"
    [ ! -d "${pkg_dir}" ] && pkg_dir="${DOCKER_PKG_DIR}"
    if [ ! -d "${pkg_dir}" ]; then
        log_error "找不到 Docker 安装包目录: ${pkg_dir}"
        exit 1
    fi

    log_info "上传安装包到 [${host}]:${remote_tmp} ..."
    run_remote "${host}" "${user}" "${pass}" \
        "mkdir -p ${remote_tmp}/packages/docker/${codename} ${remote_tmp}/lib ${remote_tmp}/components/docker"

    log_info "上传到 [${user}@${host}]: packages/docker/${codename}/"
    COPYFILE_DISABLE=1 tar -C "${pkg_dir}" \
        --exclude="._*" --exclude=".DS_Store" --exclude="__MACOSX" \
        -cf - . | \
        sshpass -p "${pass}" ssh \
            -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
            "${user}@${host}" "tar -xf - -C ${remote_tmp}/packages/docker/${codename}/"

    log_info "上传到 [${user}@${host}]: lib/"
    COPYFILE_DISABLE=1 tar -C "${SCRIPT_DIR}" --exclude="._*" --exclude=".DS_Store" -cf - lib | \
        sshpass -p "${pass}" ssh \
            -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
            "${user}@${host}" "tar -xf - -C ${remote_tmp}/"

    log_info "上传到 [${user}@${host}]: install.sh"
    sshpass -p "${pass}" ssh \
        -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
        "${user}@${host}" "cat > ${remote_tmp}/install.sh" \
        < "${SCRIPT_DIR}/components/docker/install.sh"

    run_remote "${host}" "${user}" "${pass}" \
        "SCRIPT_DIR=${remote_tmp} \
         DOCKER_REMOTE_PORT=${DOCKER_REMOTE_PORT} \
         MODE=standalone \
         bash ${remote_tmp}/install.sh"
}

# ─── 配置 Docker 并启动 ───────────────────────────────────────
_configure_docker() {
    log_info "配置 Docker 远程访问（端口: ${DOCKER_REMOTE_PORT}）..."

    # 通过 systemd override 开启远程访问，避免修改原始 service 文件
    local override_dir="/etc/systemd/system/docker.service.d"
    mkdir -p "${override_dir}"
    cat > "${override_dir}/override.conf" <<EOF
[Service]
ExecStart=
ExecStart=/usr/bin/dockerd -H fd:// --containerd=/run/containerd/containerd.sock -H tcp://0.0.0.0:${DOCKER_REMOTE_PORT}
EOF

    systemctl daemon-reload
    systemctl enable docker 2>/dev/null || true
    timeout 30 systemctl start docker || {
        log_error "Docker 服务启动失败，请查看日志: journalctl -xe"
        exit 1
    }

    # 验证
    local ver
    ver=$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo "unknown")
    log_info "Docker 版本: ${ver}  远程端口: ${DOCKER_REMOTE_PORT}"

    # 验证 docker ps
    log_info "验证 docker ps..."
    docker ps || {
        log_error "docker ps 执行失败，请检查 Docker 服务状态"
        exit 1
    }

    # 验证 docker compose
    log_info "验证 docker compose..."
    docker compose version || {
        log_error "docker compose 不可用，请检查 docker-compose-plugin 是否安装"
        exit 1
    }
}

# ─── 主流程 ───────────────────────────────────────────────────
main() {
    log_title "Docker 安装"

    if [ "${MODE}" = "standalone" ]; then
        install_docker_on_host "localhost" "" "" "true"

    elif [ "${MODE}" = "ha" ]; then
        log_info "热备模式，安装主机 [${MASTER_HOST}]..."
        install_docker_on_host "${MASTER_HOST}" "${MASTER_SSH_USER}" "${MASTER_SSH_PASS}" "false" \
            || { log_error "主机 Docker 安装失败，终止"; exit 1; }

        log_info "安装备机 [${SLAVE_HOST}]..."
        install_docker_on_host "${SLAVE_HOST}" "${SLAVE_SSH_USER}" "${SLAVE_SSH_PASS}" "false" \
            || { log_error "备机 Docker 安装失败，终止"; exit 1; }
    fi

    log_info "Docker 安装完成"
}

main "$@"
