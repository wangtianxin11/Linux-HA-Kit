#!/usr/bin/env bash
# lib/menu.sh — 交互菜单库（方向键导航版）
# 依赖: lib/common.sh 中的颜色变量

[ -n "${_MENU_SH_LOADED:-}" ] && return 0
_MENU_SH_LOADED=1

# ─── 单选菜单（↑↓ 移动，回车确认）────────────────────────────
# 用法: single_select RESULT_VAR TITLE OPTION1 OPTION2 ...
single_select() {
    local result_var="$1"; shift
    local title="$1";      shift
    local options=("$@")
    local count=${#options[@]}
    local current=0
    local key key2
    local first_draw=true

    tput civis 2>/dev/null  # 隐藏光标

    while true; do
        # 非首次绘制时，将光标上移回起点（空行1 + 标题1 + 选项N = N+2 行）
        if ! $first_draw; then
            for ((i = 0; i < count + 2; i++)); do tput cuu1; done
        fi
        first_draw=false

        echo ""
        echo -e "${COLOR_CYAN}>>> ${title}${COLOR_RESET}  （↑↓ 移动，回车确认）"
        for i in "${!options[@]}"; do
            if [ "$i" -eq "$current" ]; then
                echo -e "  ${COLOR_GREEN}▶ ${options[$i]}${COLOR_RESET}"
            else
                echo "    ${options[$i]}"
            fi
        done

        # 读取按键
        IFS= read -rsn1 key
        if [[ "$key" == $'\x1b' ]]; then
            IFS= read -rsn2 -t 0.05 key2 || true
            case "$key2" in
                '[A') [ "$current" -gt 0 ] && current=$(( current - 1 )) || true ;;
                '[B') [ "$current" -lt $(( count - 1 )) ] && current=$(( current + 1 )) || true ;;
            esac
        elif [[ "$key" == '' ]]; then   # 回车
            break
        fi
    done

    tput cnorm 2>/dev/null  # 恢复光标
    printf -v "$result_var" '%s' "${options[$current]}"
    log_info "已选择: ${options[$current]}"
}

# ─── 多选菜单（↑↓ 移动，空格切换，回车确认）─────────────────
# 用法: multi_select RESULT_VAR TITLE OPTION1 OPTION2 ...
# 返回: 逗号分隔的选中项写入 RESULT_VAR
multi_select() {
    local result_var="$1"; shift
    local title="$1";      shift
    local options=("$@")
    local count=${#options[@]}
    local current=0
    local key key2
    local first_draw=true
    local warn_msg=""

    # 初始化选中状态数组
    local selected=()
    for ((i = 0; i < count; i++)); do selected[$i]=false; done

    tput civis 2>/dev/null

    # 固定行数: 空行1 + 标题1 + 提示1 + 选项N + 警告1 = N+4
    local total_lines=$(( count + 4 ))

    while true; do
        if ! $first_draw; then
            for ((i = 0; i < total_lines; i++)); do tput cuu1; done
        fi
        first_draw=false

        echo ""
        echo -e "${COLOR_CYAN}>>> ${title}${COLOR_RESET}  （↑↓ 移动，空格选择，回车确认）"
        echo -e "  ${COLOR_YELLOW}提示: 可多选${COLOR_RESET}"
        for i in "${!options[@]}"; do
            local check
            if ${selected[$i]}; then
                check="${COLOR_GREEN}[✓]${COLOR_RESET}"
            else
                check="[ ]"
            fi
            if [ "$i" -eq "$current" ]; then
                echo -e "  ${COLOR_GREEN}▶${COLOR_RESET} ${check} ${options[$i]}"
            else
                echo -e "      ${check} ${options[$i]}"
            fi
        done
        # 警告行（固定占一行，保持行数稳定）
        if [ -n "$warn_msg" ]; then
            echo -e "  ${COLOR_RED}${warn_msg}${COLOR_RESET}"
        else
            echo ""
        fi

        # 读取按键
        IFS= read -rsn1 key
        warn_msg=""  # 每次按键后清除警告
        if [[ "$key" == $'\x1b' ]]; then
            IFS= read -rsn2 -t 0.05 key2 || true
            case "$key2" in
                '[A') [ "$current" -gt 0 ] && current=$(( current - 1 )) || true ;;
                '[B') [ "$current" -lt $(( count - 1 )) ] && current=$(( current + 1 )) || true ;;
            esac
        elif [[ "$key" == ' ' ]]; then  # 空格切换选中
            if ${selected[$current]}; then
                selected[$current]=false
            else
                selected[$current]=true
            fi
        elif [[ "$key" == '' ]]; then   # 回车确认
            # 检查至少选一项
            local any=false
            for ((i = 0; i < count; i++)); do
                ${selected[$i]} && any=true && break
            done
            if ! $any; then
                warn_msg="至少选择一项！"
                continue
            fi
            break
        fi
    done

    tput cnorm 2>/dev/null

    # 收集选中项
    local result_arr=()
    for ((i = 0; i < count; i++)); do
        ${selected[$i]} && result_arr+=("${options[$i]}")
    done

    local result
    result=$(IFS=','; echo "${result_arr[*]}")
    printf -v "$result_var" '%s' "$result"

    echo -e "\n${COLOR_GREEN}已选择:${COLOR_RESET}"
    for item in "${result_arr[@]}"; do
        echo "  ✓ ${item}"
    done
}

# ─── 是/否确认 ───────────────────────────────────────────────
# 用法: confirm_yes_no "提示" DEFAULT(y|n)
# 返回: 0=是, 1=否
confirm_yes_no() {
    local prompt="$1"
    local default="${2:-y}"
    local hint
    [ "${default,,}" = "y" ] && hint="[Y/n]" || hint="[y/N]"

    echo -n "${prompt} ${hint}: "
    read -r answer
    answer="${answer:-$default}"
    case "${answer,,}" in
        y|yes) return 0 ;;
        *)     return 1 ;;
    esac
}
