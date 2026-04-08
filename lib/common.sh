#!/usr/bin/env bash
# lib/common.sh — 公共函数库
# 提供日志输出、本地/远端执行、文件传输、依赖检查等基础能力

# 防止重复加载
[ -n "${_COMMON_SH_LOADED:-}" ] && return 0
_COMMON_SH_LOADED=1

# ─── 颜色定义 ────────────────────────────────────────────────
readonly COLOR_GREEN="\033[0;32m"
readonly COLOR_YELLOW="\033[0;33m"
readonly COLOR_RED="\033[0;31m"
readonly COLOR_CYAN="\033[0;36m"
readonly COLOR_RESET="\033[0m"

# ─── 日志函数（全部输出到 stderr，避免污染命令替换的 stdout）──
log_info() {
    echo -e "${COLOR_GREEN}[INFO]${COLOR_RESET} $*" >&2
}

log_warn() {
    echo -e "${COLOR_YELLOW}[WARN]${COLOR_RESET} $*" >&2
}

log_error() {
    echo -e "${COLOR_RED}[ERROR]${COLOR_RESET} $*" >&2
}

log_title() {
    echo -e "\n${COLOR_CYAN}══════════════════════════════════════${COLOR_RESET}" >&2
    echo -e "${COLOR_CYAN}  $*${COLOR_RESET}" >&2
    echo -e "${COLOR_CYAN}══════════════════════════════════════${COLOR_RESET}\n" >&2
}

# ─── 本地执行 ────────────────────────────────────────────────
# 用法: run_local "命令描述" CMD [ARGS...]
run_local() {
    local desc="$1"; shift
    log_info "本地执行: ${desc}"
    if ! "$@"; then
        log_error "执行失败: ${desc}"
        return 1
    fi
}

# ─── 远端执行 ────────────────────────────────────────────────
# 用法: run_remote HOST USER PASS CMD
run_remote() {
    local host="$1" user="$2" pass="$3"; shift 3
    local cmd="$*"
    log_info "远端执行 [${user}@${host}]: ${cmd}"
    sshpass -p "${pass}" ssh \
        -o StrictHostKeyChecking=no \
        -o ConnectTimeout=10 \
        "${user}@${host}" "${cmd}"
    local ret=$?
    if [ $ret -ne 0 ]; then
        log_error "远端执行失败 [${host}]: ${cmd}"
        return $ret
    fi
}

# ─── 文件/目录上传到远端 ─────────────────────────────────────
# 用法: copy_to_remote HOST USER PASS SRC DST
copy_to_remote() {
    local host="$1" user="$2" pass="$3" src="$4" dst="$5"
    log_info "上传到 [${user}@${host}]: ${src} → ${dst}"
    sshpass -p "${pass}" scp \
        -o StrictHostKeyChecking=no \
        -o ConnectTimeout=10 \
        -r "${src}" "${user}@${host}:${dst}"
    local ret=$?
    if [ $ret -ne 0 ]; then
        log_error "上传失败 [${host}]: ${src} → ${dst}"
        return $ret
    fi
}

# ─── 依赖工具检查（支持离线 deb 自动安装）────────────────────
# 用法: check_dependency TOOL
# 检测工具是否已安装，未安装时自动在 packages/ 目录查找对应 deb 包安装
# 找不到 deb 则提示在线安装命令后退出
check_dependency() {
    local tool="$1"
    if command -v "${tool}" &>/dev/null; then
        return 0
    fi

    log_warn "未检测到 ${tool}，尝试离线安装..."

    # 在 packages/ 目录下查找匹配的 deb 包
    local pkg_dir="${SCRIPT_DIR}/packages"
    local deb_file
    deb_file=$(find "${pkg_dir}" -maxdepth 1 -name "${tool}_*.deb" 2>/dev/null | head -1)

    if [ -n "${deb_file}" ]; then
        log_info "找到离线包: $(basename "${deb_file}")，正在安装..."
        if dpkg -i "${deb_file}" 2>/dev/null; then
            log_info "${tool} 安装成功"
            return 0
        else
            log_error "${tool} 离线安装失败"
            exit 1
        fi
    fi

    # 没有找到离线包，提示在线安装后退出
    log_error "未找到 ${tool} 的离线安装包（packages/${tool}_*.deb）"
    log_warn "请手动安装: apt-get install -y ${tool}"
    exit 1
}

# ─── 按回车继续 ──────────────────────────────────────────────
press_enter_to_continue() {
    echo -e "\n按 ${COLOR_CYAN}Enter${COLOR_RESET} 继续..."
    read -r
}

# ─── 计时函数 ────────────────────────────────────────────────
# 用法:
#   timer_start          → 记录开始时间
#   timer_end "标签"     → 打印耗时，格式: X分X秒 或 X秒
_TIMER_START=0

timer_start() {
    _TIMER_START=$(date +%s)
}

timer_end() {
    local label="${1:-}"
    local end elapsed m s
    end=$(date +%s)
    elapsed=$(( end - _TIMER_START ))
    m=$(( elapsed / 60 ))
    s=$(( elapsed % 60 ))
    if [ "${m}" -gt 0 ]; then
        log_info "${label:+[${label}] }耗时: ${m} 分 ${s} 秒"
    else
        log_info "${label:+[${label}] }耗时: ${s} 秒"
    fi
}
