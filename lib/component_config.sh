#!/usr/bin/env bash
# lib/component_config.sh — 组件配置通用函数

[ -n "${_COMPONENT_CONFIG_SH_LOADED:-}" ] && return 0
_COMPONENT_CONFIG_SH_LOADED=1

# ─── 保存组件配置 ─────────────────────────────────────────────
save_component_config() {
    local comp="$1"; shift
    local conf_file="${SCRIPT_DIR}/components/${comp}/config.conf"
    {
        echo "# ${comp} 组件配置"
        echo "# 生成时间: $(date '+%Y-%m-%d %H:%M:%S')"
        echo ""
        while [ $# -ge 2 ]; do
            echo "${1}=${2}"
            shift 2
        done
    } > "${conf_file}"
    log_info "[${comp}] 配置已保存到: ${conf_file}"
}

# ─── 读取组件配置 ─────────────────────────────────────────────
load_component_config() {
    local comp="$1"
    local conf_file="${SCRIPT_DIR}/components/${comp}/config.conf"
    [ ! -f "${conf_file}" ] && return 1
    while IFS='=' read -r key value; do
        [[ "$key" =~ ^#.*$ || -z "$key" ]] && continue
        key="${key// /}"
        export "${key}=${value}"
    done < "${conf_file}"
    return 0
}

# ─── 通用输入：带默认值 ───────────────────────────────────────
input_with_default() {
    local result_var="$1" prompt="$2" default="$3" input
    echo -n "  ${prompt} [默认 ${default}]: "
    read -re input
    printf -v "${result_var}" '%s' "${input:-${default}}"
}

# ─── 通用输入：必填 ───────────────────────────────────────────
input_required() {
    local result_var="$1" prompt="$2" input
    while true; do
        echo -n "  ${prompt}: "
        read -re input
        if [ -n "${input}" ]; then
            printf -v "${result_var}" '%s' "${input}"
            return 0
        fi
        log_warn "  此项不能为空，请重新输入"
    done
}

# ─── 通用输入：密码 ───────────────────────────────────────────
input_password() {
    local result_var="$1" prompt="$2" required="${3:-true}" input_pass
    while true; do
        echo -n "  ${prompt}$([ "${required}" = "false" ] && echo '（回车跳过）'): "
        input_pass=""
        while IFS= read -rsn1 ch; do
            if [[ "$ch" == $'\x7f' || "$ch" == $'\b' ]]; then
                if [ -n "$input_pass" ]; then
                    input_pass="${input_pass%?}"
                    echo -ne '\b \b'
                fi
            elif [[ -z "$ch" ]]; then
                echo; break
            else
                input_pass+="$ch"; echo -n "*"
            fi
        done
        if [ -z "${input_pass}" ] && [ "${required}" = "false" ]; then
            printf -v "${result_var}" '%s' ""; return 0
        fi
        if [ -n "${input_pass}" ]; then
            printf -v "${result_var}" '%s' "${input_pass}"; return 0
        fi
        log_warn "  密码不能为空，请重新输入"
    done
}

# ─── 通用组件配置主函数 ───────────────────────────────────────
# 用法: component_config COMP_NAME FIELD_DEF...
#
# FIELD_DEF 格式: "VAR_NAME|标签|类型|默认值"
#   类型: default（带默认值）/ required（必填）/ password（密码必填）/ password_optional（密码可选）
#
# 示例:
#   component_config "mysql" \
#       "MYSQL_PORT|端口|default|3306" \
#       "MYSQL_ROOT_PASS|root 密码|password|"
#
# 流程:
#   1. 若已有 config.conf，展示当前值并询问是否重新配置
#   2. 逐字段交互录入
#   3. 保存到 components/<comp>/config.conf
component_config() {
    local comp="$1"; shift
    local field_defs=("$@")

    # 已有配置则展示并询问是否修改
    if load_component_config "${comp}"; then
        echo -e "\n${COLOR_CYAN}── ${comp} 已有配置 ────────────────────────${COLOR_RESET}"
        for field_def in "${field_defs[@]}"; do
            IFS='|' read -r var label type default <<< "${field_def}"
            local current_val="${!var:-（未设置）}"
            if [[ "${type}" == password* ]]; then
                [ -n "${!var:-}" ] && current_val="********" || current_val="（未设置）"
            fi
            echo "  ${label}: ${current_val}"
        done
        echo -e "${COLOR_CYAN}──────────────────────────────────────────${COLOR_RESET}"
        if ! confirm_yes_no "是否重新配置？" "n"; then
            return 0
        fi
    fi

    log_title "配置 ${comp}"

    # 逐字段录入
    local save_args=()
    for field_def in "${field_defs[@]}"; do
        IFS='|' read -r var label type default <<< "${field_def}"
        case "${type}" in
            default)           input_with_default "${var}" "${label}" "${default}" ;;
            required)          input_required     "${var}" "${label}" ;;
            password)          input_password     "${var}" "${label}" "true" ;;
            password_optional) input_password     "${var}" "${label}" "false" ;;
        esac
        save_args+=("${var}" "${!var}")
    done

    save_component_config "${comp}" "${save_args[@]}"
}
