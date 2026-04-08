#!/usr/bin/env bash
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/menu.sh"
source "${SCRIPT_DIR}/lib/component_config.sh"

# ─── 展示已有配置，询问是否重新配置 ─────────────────────────
if load_component_config "keepalived"; then
    echo -e "\n${COLOR_CYAN}── keepalived 已有配置 ────────────────────────${COLOR_RESET}"
    echo "  VIP 地址: ${KA_VIP:-（未设置）}"
    echo "  网卡名称: ${KA_INTERFACE:-（未设置）}"
    echo -e "${COLOR_CYAN}──────────────────────────────────────────${COLOR_RESET}"
    if ! confirm_yes_no "是否重新配置？" "n"; then
        return 0
    fi
fi

log_title "配置 keepalived"

# ─── 输入 VIP ────────────────────────────────────────────────
input_required "KA_VIP" "VIP 地址（示例: 192.168.10.100/24，含掩码）"

# ─── 从主机拉取网卡列表，供用户选择 ─────────────────────────
log_info "正在从主机 [${MASTER_HOST}] 获取网卡列表..."
iface_raw=$(run_remote "${MASTER_HOST}" "${MASTER_SSH_USER}" "${MASTER_SSH_PASS}" \
    "ip -o link show | awk -F': ' '{print \$2}' | grep -v '^lo'" 2>/dev/null) || true

if [ -z "${iface_raw}" ]; then
    log_warn "无法获取远端网卡列表，请手动输入"
    input_with_default "KA_INTERFACE" "网卡名称（示例: eth0、ens3、eno3np2）" "eth0"
else
    iface_arr=()
    while IFS= read -r line; do
        line="${line//[[:space:]]/}"   # 去除多余空白
        [ -n "${line}" ] && iface_arr+=("${line}")
    done <<< "${iface_raw}"

    single_select "KA_INTERFACE" \
        "选择 Keepalived 绑定网卡（来自主机 ${MASTER_HOST}）" \
        "${iface_arr[@]}"
fi

save_component_config "keepalived" \
    "KA_VIP"       "${KA_VIP}" \
    "KA_INTERFACE" "${KA_INTERFACE}"
