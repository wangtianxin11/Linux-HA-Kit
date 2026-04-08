#!/usr/bin/env bash
# lib/config.sh — 配置管理库

[ -n "${_CONFIG_SH_LOADED:-}" ] && return 0
_CONFIG_SH_LOADED=1

CONF_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/conf/global.conf"

# ─── 读取配置 ────────────────────────────────────────────────
load_config() {
    [ ! -f "${CONF_FILE}" ] && return 1
    while IFS='=' read -r key value; do
        [[ "$key" =~ ^#.*$ || -z "$key" ]] && continue
        key="${key// /}"
        export "${key}=${value}"
    done < "${CONF_FILE}"
    # 确保所有变量有默认值，防止 set -u 报错
    MODE="${MODE:-}"
    HA_TOPO="${HA_TOPO:-}"
    MASTER_HOST="${MASTER_HOST:-}"
    MASTER_SSH_USER="${MASTER_SSH_USER:-}"
    MASTER_SSH_PASS="${MASTER_SSH_PASS:-}"
    SLAVE_HOST="${SLAVE_HOST:-}"
    SLAVE_SSH_USER="${SLAVE_SSH_USER:-}"
    SLAVE_SSH_PASS="${SLAVE_SSH_PASS:-}"
    INSTALL_COMPONENTS="${INSTALL_COMPONENTS:-}"
    return 0
}

# ─── 保存配置 ────────────────────────────────────────────────
save_config() {
    mkdir -p "$(dirname "${CONF_FILE}")"
    cat > "${CONF_FILE}" <<EOF
# 热备安装脚本 全局配置
# 生成时间: $(date '+%Y-%m-%d %H:%M:%S')
# 警告: 含明文密码，请勿提交到版本控制

MODE=${MODE}
HA_TOPO=${HA_TOPO}
MASTER_HOST=${MASTER_HOST}
MASTER_SSH_USER=${MASTER_SSH_USER}
MASTER_SSH_PASS=${MASTER_SSH_PASS}
SLAVE_HOST=${SLAVE_HOST}
SLAVE_SSH_USER=${SLAVE_SSH_USER}
SLAVE_SSH_PASS=${SLAVE_SSH_PASS}
INSTALL_COMPONENTS=${INSTALL_COMPONENTS:-}
EOF
    chmod 600 "${CONF_FILE}"
    log_info "配置已保存到: ${CONF_FILE}"
}

# ─── 展示当前配置 ────────────────────────────────────────────
show_config() {
    local pass_mask tmp_pass
    echo -e "\n${COLOR_CYAN}── 当前全局配置 ──────────────────────────${COLOR_RESET}"
    echo "  部署模式      : ${MODE:-（未设置）}"
    tmp_pass="${MASTER_SSH_PASS:-}"
    pass_mask=$(printf '%0.s*' $(seq 1 ${#tmp_pass}))
    echo "  主机 IP       : ${MASTER_HOST:-（未设置）}"
    echo "  主机 SSH 账号 : ${MASTER_SSH_USER:-（未设置）}"
    echo "  主机 SSH 密码 : ${pass_mask:-(未设置)}"
    if [ "${MODE:-}" = "ha" ]; then
        tmp_pass="${SLAVE_SSH_PASS:-}"
        pass_mask=$(printf '%0.s*' $(seq 1 ${#tmp_pass}))
        echo "  备机 IP       : ${SLAVE_HOST:-（未设置）}"
        echo "  备机 SSH 账号 : ${SLAVE_SSH_USER:-（未设置）}"
        echo "  备机 SSH 密码 : ${pass_mask:-(未设置)}"
    fi
    echo "  安装组件      : ${INSTALL_COMPONENTS:-（未设置）}"
    echo -e "${COLOR_CYAN}──────────────────────────────────────────${COLOR_RESET}\n"
}

# ─── 私有：录入并校验 IP ─────────────────────────────────────
_input_host() {
    local prompt="$1"
    local result_var="$2"
    local input
    while true; do
        echo -n "${prompt}: "
        read -re input
        if [[ "${input}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
            printf -v "${result_var}" '%s' "${input}"
            return 0
        fi
        log_warn "IP 格式不正确，请重新输入（示例: 192.168.1.10）"
    done
}

# ─── 私有：录入某台机器的 SSH 信息 ──────────────────────────
# 用法: _input_ssh_info "主机" HOST_VAR USER_VAR PASS_VAR
_input_ssh_info() {
    local label="$1"
    local host_var="$2"
    local user_var="$3"
    local pass_var="$4"

    echo -e "\n${COLOR_CYAN}  [ ${label} ]${COLOR_RESET}"
    _input_host "  IP 地址" "${host_var}"

    echo -n "  SSH 账号 [默认 root]: "
    read -re input_user
    printf -v "${user_var}" '%s' "${input_user:-root}"

    local input_pass
    while true; do
        echo -n "  SSH 密码: "
        input_pass=""
        while IFS= read -rsn1 ch; do
            if [[ "$ch" == $'\x7f' || "$ch" == $'\b' ]]; then
                # 退格键：删除最后一个字符
                if [ -n "$input_pass" ]; then
                    input_pass="${input_pass%?}"
                    echo -ne '\b \b'
                fi
            elif [[ -z "$ch" ]]; then
                # 回车：结束输入
                echo
                break
            else
                input_pass+="$ch"
                echo -n "*"
            fi
        done
        if [ -n "${input_pass}" ]; then
            printf -v "${pass_var}" '%s' "${input_pass}"
            break
        fi
        log_warn "  密码不能为空，请重新输入"
    done
}

# ─── 交互式录入配置 ──────────────────────────────────────────
init_config() {
    log_title "配置服务器 SSH 信息"

    # 先选部署模式
    single_select _MODE_SELECT "请选择部署模式" \
        "standalone（单机）" \
        "ha（热备）"

    case "${_MODE_SELECT}" in
        "standalone（单机）")
            MODE="standalone"
            HA_TOPO=""
            _input_ssh_info "目标主机" MASTER_HOST MASTER_SSH_USER MASTER_SSH_PASS
            SLAVE_HOST=""
            SLAVE_SSH_USER=""
            SLAVE_SSH_PASS=""
            ;;
        "ha（热备）")
            MODE="ha"
            HA_TOPO=""
            _input_ssh_info "主机" MASTER_HOST MASTER_SSH_USER MASTER_SSH_PASS
            _input_ssh_info "备机" SLAVE_HOST  SLAVE_SSH_USER  SLAVE_SSH_PASS
            ;;
    esac

    export MODE HA_TOPO \
           MASTER_HOST MASTER_SSH_USER MASTER_SSH_PASS \
           SLAVE_HOST  SLAVE_SSH_USER  SLAVE_SSH_PASS
}

# ─── SSH 连通性校验 ──────────────────────────────────────────
# 用法: validate_ssh HOST USER PASS
validate_ssh() {
    local host="$1" user="$2" pass="$3"
    log_info "测试 SSH 连通性 [${user}@${host}]..."
    if sshpass -p "${pass}" ssh \
        -o StrictHostKeyChecking=no \
        -o ConnectTimeout=5 \
        -o BatchMode=no \
        "${user}@${host}" "exit" 2>/dev/null; then
        log_info "SSH 连通正常 [${host}]"
        return 0
    else
        log_error "SSH 连接失败 [${host}]，请检查 IP、账号、密码"
        return 1
    fi
}

# ─── 主入口 ──────────────────────────────────────────────────
load_or_init_config() {
    if load_config; then
        show_config
        if confirm_yes_no "是否修改当前配置？" "n"; then
            init_config
            save_config
        fi
    else
        log_warn "未找到配置文件，开始初始化..."
        init_config
        save_config
    fi

    # 热备模式验证两台机器 SSH
    if [ "${MODE}" = "ha" ]; then
        check_dependency sshpass
        validate_ssh "${MASTER_HOST}" "${MASTER_SSH_USER}" "${MASTER_SSH_PASS}" || exit 1
        validate_ssh "${SLAVE_HOST}"  "${SLAVE_SSH_USER}"  "${SLAVE_SSH_PASS}"  || exit 1
    fi
}
