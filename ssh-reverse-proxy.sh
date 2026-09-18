#!/usr/bin/env bash
# Run by a user on demand. The server proxy port is the account UID plus 10000.
set -euo pipefail
umask 077

BASHRC="$HOME/.bashrc"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/ssh-reverse-proxy"
LOCK="$STATE_DIR/lock"
SETUP_PENDING="$STATE_DIR/first-setup-pending"
SETUP_DONE="$STATE_DIR/first-setup-done"
BEGIN_MARK='# >>> ssh-reverse-proxy managed >>>'
END_MARK='# <<< ssh-reverse-proxy managed <<<'

valid_port() { [[ "$1" =~ ^[0-9]{1,5}$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 )); }
valid_target() { [[ "$1" =~ ^[a-zA-Z0-9_][a-zA-Z0-9_.@:-]*$ ]]; }

# Read simple literal assignments only. This command writes this exact format.
read_value() {
    local key=$1 raw
    raw=$(sed -nE "s/^[[:space:]]*(export[[:space:]]+)?${key}[[:space:]]*=[[:space:]]*\"?([^\"[:space:]#]*)\"?[[:space:]]*(#.*)?$/\2/p" "$BASHRC" | tail -n 1)
    printf '%s' "$raw"
}

manual_port_present() {
    awk -v begin="$BEGIN_MARK" -v end="$END_MARK" '
        $0 == begin { managed=1; next }
        $0 == end { managed=0; next }
        !managed && /^[[:space:]]*(export[[:space:]]+)?SRP_SERVER_PORT[[:space:]]*=/ { found=1 }
        END { exit !found }
    ' "$BASHRC"
}

outside_proxy_assignments() {
    awk -v begin="$BEGIN_MARK" -v end="$END_MARK" '
        $0 == begin { managed=1; next }
        $0 == end { managed=0; next }
        !managed && /^[[:space:]]*(export[[:space:]]+)?(http_proxy|https_proxy|HTTP_PROXY|HTTPS_PROXY|ALL_PROXY)[[:space:]]*=/ { found=1 }
        END { exit !found }
    ' "$BASHRC"
}

write_config() {
    local port=$1 local_port=$2 target=$3 enabled=$4 tmp
    tmp=$(mktemp "$BASHRC.tmp.XXXXXX")
    awk -v begin="$BEGIN_MARK" -v end="$END_MARK" '
        $0 == begin { managed=1; next }
        $0 == end { managed=0; next }
        !managed && /^[[:space:]]*$/ { pending=pending $0 ORS; next }
        !managed { printf "%s", pending; pending=""; print }
    ' "$BASHRC" > "$tmp"
    {
        printf '\n%s\n' "$BEGIN_MARK"
        printf 'export SRP_SERVER_PORT="%s"\n' "$port"
        printf 'export SRP_LOCAL_PORT="%s"\n' "$local_port"
        printf 'export SRP_SSH_TARGET="%s"\n' "$target"
        printf 'export SRP_ENABLED="%s"\n' "$enabled"
        printf 'if [ "$SRP_ENABLED" = 1 ]; then\n'
        printf '    export http_proxy="http://127.0.0.1:${SRP_SERVER_PORT}"\n'
        printf '    export https_proxy="$http_proxy"\n'
        printf '    export HTTP_PROXY="$http_proxy"\n'
        printf '    export HTTPS_PROXY="$http_proxy"\n'
        printf '    export ALL_PROXY="$http_proxy"\n'
        printf '    export no_proxy="localhost,127.0.0.1,::1"\n'
        printf '    export NO_PROXY="$no_proxy"\n'
        printf 'else\n'
        printf '    unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY no_proxy NO_PROXY\n'
        printf 'fi\n'
        printf '%s\n' "$END_MARK"
    } >> "$tmp"
    chmod --reference="$BASHRC" "$tmp"
    if cmp -s -- "$tmp" "$BASHRC"; then
        rm -- "$tmp"
    else
        mv -- "$tmp" "$BASHRC"
    fi
}

save_field() {
    local field=$1 value=$2 port local_port target enabled
    exec 8> "$LOCK"
    flock -x 8
    port=$(read_value SRP_SERVER_PORT)
    local_port=$(read_value SRP_LOCAL_PORT)
    target=$(read_value SRP_SSH_TARGET)
    enabled=$(read_value SRP_ENABLED)
    [[ -n "$enabled" ]] || enabled=1
    case "$field" in
        local_port) local_port=$value ;;
        target) target=$value ;;
        enabled) enabled=$value ;;
    esac
    write_config "$port" "$local_port" "$target" "$enabled"
    flock -u 8
    exec 8>&-
}

initialize() {
    local port previous_port local_port target enabled account_uid created=0 allocated=0
    account_uid=$(/usr/bin/id -u)
    if [[ ! "$account_uid" =~ ^[0-9]+$ ]] || (( account_uid > 55535 )); then
        printf 'UID %s 无法使用 UID + 10000 映射到有效端口。\n' "$account_uid" >&2
        exit 1
    fi
    port=$((account_uid + 10000))
    mkdir -p -- "$STATE_DIR"
    touch -- "$LOCK"
    exec 9> "$LOCK"
    flock -x 9
    [[ -f "$BASHRC" ]] || created=1
    if [[ "$created" == 1 ]]; then : > "$BASHRC"; fi
    if outside_proxy_assignments; then
        printf '%s 中已有其他代理导出语句，请先迁移或移除，避免与新配置冲突。\n' "$BASHRC" >&2
        exit 1
    fi
    if manual_port_present; then
        printf '%s 中已有手动设置的 SRP_SERVER_PORT，请先移除以使用 UID 端口。\n' "$BASHRC" >&2
        exit 1
    fi
    previous_port=$(read_value SRP_SERVER_PORT)
    if [[ -n "$previous_port" && "$previous_port" != "$port" ]]; then
        printf '%s 中已有端口 %s，与 UID %s 对应的端口 %s 不同；请先迁移旧配置。\n' "$BASHRC" "$previous_port" "$account_uid" "$port" >&2
        exit 1
    fi
    [[ -n "$previous_port" ]] || allocated=1
    local_port=$(read_value SRP_LOCAL_PORT)
    target=$(read_value SRP_SSH_TARGET)
    enabled=$(read_value SRP_ENABLED)
    [[ -n "$enabled" ]] || enabled=1
    if [[ -n "$local_port" ]] && ! valid_port "$local_port"; then
        printf '%s 中的 SRP_LOCAL_PORT 不是有效端口。\n' "$BASHRC" >&2
        exit 1
    fi
    if [[ -n "$target" ]] && ! valid_target "$target"; then
        printf '%s 中的 SRP_SSH_TARGET 不是有效 SSH 别名。\n' "$BASHRC" >&2
        exit 1
    fi
    if [[ "$enabled" != 0 && "$enabled" != 1 ]]; then
        printf '%s 中的 SRP_ENABLED 必须是 0 或 1。\n' "$BASHRC" >&2
        exit 1
    fi
    write_config "$port" "$local_port" "$target" "$enabled"
    if [[ ! -e "$SETUP_PENDING" && ! -e "$SETUP_DONE" ]] &&
       { [[ "$created" == 1 || "$allocated" == 1 || -z "$local_port" || -z "$target" ]]; }; then
        printf 'created=%s\nallocated=%s\n' "$created" "$allocated" > "$SETUP_PENDING"
    fi
    flock -u 9
    exec 9>&-
}

ask_local_port() {
    local answer
    while true; do
        printf '请查看你本地电脑的代理软件，输入其本地代理端口：'
        if ! IFS= read -r answer; then return 1; fi
        if valid_port "$answer"; then
            LOCAL_PORT="$((10#$answer))"
            return 0
        fi
        printf '请输入 1–65535 之间的纯数字端口。\n'
    done
}

ask_target() {
    local answer
    while true; do
        printf '请输入你本地 ~/.ssh/config 的 Host 别名：'
        if ! IFS= read -r answer; then return 1; fi
        if valid_target "$answer"; then
            TARGET="$answer"
            return 0
        fi
        printf 'SSH 别名不能为空，且不能包含空格或命令参数。\n'
    done
}

box_row() {
    local inner=$1 row=$2 width
    width=$(printf '%s\n' "$row" | wc -L)
    printf '│ %s%*s │\n' "$row" "$((inner - width))" ''
}

show_config_box() {
    local server_port=$1 local_port=$2 target=$3 enabled=$4 inner=52 rule row width status
    status=启用
    [[ "$enabled" == 1 ]] || status=关闭
    local rows=(
        '当前代理配置'
        "代理状态：$status"
        "服务器代理端口：$server_port"
        "本地代理端口：${local_port:-待填写}"
        "本地 SSH 别名：${target:-待填写}"
    )
    for row in "${rows[@]}"; do
        width=$(printf '%s\n' "$row" | wc -L)
        (( width > inner )) && inner=$width
    done
    printf -v rule '%*s' "$((inner + 2))" ''
    rule=${rule// /─}
    printf '\n┌%s┐\n' "$rule"
    box_row "$inner" "${rows[0]}"
    printf '├%s┤\n' "$rule"
    box_row "$inner" "${rows[1]}"
    box_row "$inner" "${rows[2]}"
    box_row "$inner" "${rows[3]}"
    box_row "$inner" "${rows[4]}"
    printf '└%s┘\n' "$rule"
}

show_instructions() {
    local port=$1 local_port=$2 target=$3
    printf '\n请先在本地电脑开启 VPN，然后在本地终端运行以下指令并保持连接：\n'
    printf '  ssh -N -R %s:127.0.0.1:%s %s\n' "$port" "$local_port" "$target"
    printf '\n隧道建立后，在服务器终端检查外网连接：（若本次为初始化或修改配置，请新建终端以保证代理配置生效）\n'
    printf '  curl -x http://127.0.0.1:%s -I https://api.openai.com/v1/models\n' "$port"
    printf '  若最终收到来自 API 的 HTTP 响应头（例如 HTTP/1.1 200 Connection established），说明请求已到达 API。\n'
}

show_first_completion() {
    local port=$1 created=0 allocated=0
    exec 8> "$LOCK"
    flock -x 8
    if [[ ! -f "$SETUP_PENDING" ]]; then
        flock -u 8
        exec 8>&-
        return 0
    fi
    if grep -qx 'created=1' "$SETUP_PENDING"; then created=1; fi
    if grep -qx 'allocated=1' "$SETUP_PENDING"; then allocated=1; fi
    mv -- "$SETUP_PENDING" "$SETUP_DONE"
    flock -u 8
    exec 8>&-

    printf '\n✓ 代理配置已完成\n\n'
    if [[ "$created" == 1 ]]; then
        printf '已创建 .bashrc：%s\n' "$BASHRC"
    else
        printf '已更新 .bashrc：%s\n' "$BASHRC"
    fi
    if [[ "$allocated" == 1 ]]; then
        printf '服务器代理端口已分配为 %s （由系统管理，不建议手动修改）\n' "$port"
    else
        printf '服务器代理端口沿用现有设置：%s。\n' "$port"
    fi
    printf '忘记命令或要修改本地端口、SSH 别名时，可再运行 ssh-reverse-proxy。\n'
}

show_help() {
    local choice port
    initialize
    port=$(read_value SRP_SERVER_PORT)
    LOCAL_PORT=$(read_value SRP_LOCAL_PORT)
    TARGET=$(read_value SRP_SSH_TARGET)
    ENABLED=$(read_value SRP_ENABLED)
    if [[ -z "$LOCAL_PORT" || -z "$TARGET" ]]; then
        show_config_box "$port" "$LOCAL_PORT" "$TARGET" "$ENABLED"
    fi
    if [[ -z "$LOCAL_PORT" ]]; then
        ask_local_port || { printf '\n未保存；下次运行可继续填写。\n'; return 0; }
        save_field local_port "$LOCAL_PORT"
    fi
    if [[ -z "$TARGET" ]]; then
        ask_target || { printf '\n未填写 SSH 别名；下次运行可继续填写。\n'; return 0; }
        save_field target "$TARGET"
    fi
    show_first_completion "$port"
    while true; do
        show_config_box "$port" "$LOCAL_PORT" "$TARGET" "$ENABLED"
        if [[ "$ENABLED" == 0 ]]; then
            printf '\n代理已关闭；要让新终端使用代理，请运行 ssh-reverse-proxy on 或在下方输入 n。\n'
        fi
        show_instructions "$port" "$LOCAL_PORT" "$TARGET"
        printf '\n%s' '───────────────────────────────────────────────────────'
        printf '\n输入 p 修改本地代理端口，s 修改 SSH 别名，o 关闭代理，n 启用代理，直接回车退出：'
        if ! IFS= read -r choice; then return 0; fi
        case "$choice" in
            '') return 0 ;;
            p)
                ask_local_port || return 0
                save_field local_port "$LOCAL_PORT"
                ;;
            s)
                ask_target || return 0
                save_field target "$TARGET"
                ;;
            o|n)
                if [[ "$choice" == o ]]; then ENABLED=0; else ENABLED=1; fi
                save_field enabled "$ENABLED"
                printf '\n代理已%s；请新开远程终端使环境变量更新。\n' "$([[ "$ENABLED" == 1 ]] && echo 启用 || echo 关闭)"
                ;;
            *) printf '请选择 p、s、o、n，或直接回车退出。\n' ;;
        esac
    done
}

case "${1:-help}" in
    init)
        initialize
        ;;
    help|ssh-reverse-proxy) show_help ;;
    on)
        initialize
        save_field enabled 1
        printf '代理已启用；请新开远程终端使环境变量更新。\n'
        show_help
        ;;
    off)
        if [[ ! -f "$BASHRC" ]] || [[ -z "$(read_value SRP_SERVER_PORT)" ]]; then
            printf '尚未初始化代理，无需关闭。\n'
        else
            initialize
            save_field enabled 0
            printf '代理已关闭；请新开远程终端使环境变量更新。端口和 SSH 别名已保留。\n'
        fi
        ;;
    *) printf '用法：%s [init|help|on|off]\n' "$0" >&2; exit 2 ;;
esac
