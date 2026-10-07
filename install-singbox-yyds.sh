#!/usr/bin/env bash
set -euo pipefail
umask 077

info() { echo -e "\033[1;34m[INFO]\033[0m $*"; }
err()  { echo -e "\033[1;31m[ERR]\033[0m $*" >&2; }
CONFIG=/etc/sing-box/config.json

detect_os() {
    . /etc/os-release 2>/dev/null || true
    case "${ID:-} ${ID_LIKE:-}" in
        *alpine*) OS=alpine ;;
        *debian*|*ubuntu*) OS=debian ;;
        *centos*|*rhel*|*fedora*|*rocky*|*almalinux*) OS=redhat ;;
        *) OS=unknown ;;
    esac
}

install_deps() {
    case "$OS" in
        alpine) apk update; apk add --no-cache bash curl ca-certificates openssl jq ;;
        debian) export DEBIAN_FRONTEND=noninteractive; apt-get update -y; apt-get install -y curl ca-certificates openssl jq ;;
        redhat) if command -v dnf >/dev/null; then dnf install -y curl ca-certificates openssl jq; else yum install -y curl ca-certificates openssl jq; fi ;;
        *) err "不支持的系统，仅支持 Alpine、Debian/Ubuntu、RHEL 系"; exit 1 ;;
    esac
}

rand_port() { shuf -i 10000-60000 -n 1 2>/dev/null || echo $((RANDOM % 50001 + 10000)); }
rand_uuid() { cat /proc/sys/kernel/random/uuid; }

get_ip() {
    local ip
    for url in https://api.ipify.org https://ipinfo.io/ip https://ifconfig.me; do
        ip=$(curl -fsS --max-time 5 "$url" 2>/dev/null | tr -d '[:space:]' || true)
        if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ || "$ip" == *:* ]]; then echo "$ip"; return 0; fi
    done
    return 1
}

install_singbox() {
    if command -v sing-box >/dev/null 2>&1; then
        info "发现 sing-box: $(sing-box version | head -n1)"
        read -r -p "重新安装? (y/N): " answer
        [[ "$answer" =~ ^[Yy]$ ]] || return 0
    fi
    if [ "$OS" = alpine ]; then
        apk add --no-cache --repository=https://dl-cdn.alpinelinux.org/alpine/edge/community sing-box
    else
        bash <(curl -fsSL https://sing-box.app/install.sh)
    fi
    command -v sing-box >/dev/null 2>&1 || { err "sing-box 安装失败"; exit 1; }
}

generate_reality_keys() {
    local keys
    keys=$(sing-box generate reality-keypair)
    REALITY_PRIVATE=$(printf '%s\n' "$keys" | awk '/PrivateKey/ {print $NF; exit}')
    REALITY_PUBLIC=$(printf '%s\n' "$keys" | awk '/PublicKey/ {print $NF; exit}')
    REALITY_SHORT_ID=$(sing-box generate rand 8 --hex | tr -d '\r\n')
    [ -n "$REALITY_PRIVATE" ] && [ -n "$REALITY_PUBLIC" ] && [ -n "$REALITY_SHORT_ID" ] || { err "Reality 密钥生成失败"; return 1; }
}

make_inbound() {
    jq -n --arg tag "$1" --argjson port "$2" --arg uuid "$3" --arg sni "$4" \
        --arg private_key "$5" --arg short_id "$6" \
        '{type:"vless",tag:$tag,listen:"::",listen_port:$port,users:[{uuid:$uuid,flow:"xtls-rprx-vision"}],tls:{enabled:true,server_name:$sni,reality:{enabled:true,handshake:{server:$sni,server_port:443},private_key:$private_key,short_id:[$short_id]}}}'
}

prompt_socks() {
    local tag="$1" answer server server_port username password
    SOCKS_ENABLED=false
    SOCKS_JSON=null
    if [ "${2:-}" != force ]; then
        read -r -p '是否为此连接添加 SOCKS 出站? (y/N): ' answer
        [[ "$answer" =~ ^[Yy]$ ]] || return 0
    fi
    read -r -p 'SOCKS 服务器 server: ' server
    [ -n "$server" ] || { err "SOCKS 服务器不能为空"; return 1; }
    read -r -p 'SOCKS 端口 server_port: ' server_port
    [[ "$server_port" =~ ^[0-9]+$ ]] && [ "$server_port" -ge 1 ] && [ "$server_port" -le 65535 ] || { err "SOCKS 端口必须为 1-65535"; return 1; }
    read -r -p 'SOCKS 用户名 username: ' username
    [ -n "$username" ] || { err "SOCKS 用户名不能为空"; return 1; }
    read -r -p 'SOCKS 密码明文 (只输入密码本身，不要输入 password: 等字段): ' password
    [ -n "$password" ] || { err "SOCKS 密码不能为空"; return 1; }
    SOCKS_TAG="socks-${tag#vless-}"
    SOCKS_JSON=$(jq -n --arg tag "$SOCKS_TAG" --arg server "$server" --arg username "$username" --arg password "$password" --argjson port "$server_port" '{type:"socks",tag:$tag,server:$server,server_port:$port,username:$username,password:$password}')
    SOCKS_ENABLED=true
}

write_service() {
    local binary
    binary=$(command -v sing-box)
    if [ "$OS" = alpine ]; then
        cat > /etc/init.d/sing-box <<OPENRC
#!/sbin/openrc-run
name="sing-box"
command="$binary"
command_args="run -c /etc/sing-box/config.json"
command_background="yes"
pidfile="/run/sing-box.pid"
supervisor=supervise-daemon
supervise_daemon_args="--respawn-max 0 --respawn-delay 5"
depend() { need net; }
OPENRC
        chmod +x /etc/init.d/sing-box
        rc-update add sing-box default
        rc-service sing-box restart
    else
        cat > /etc/systemd/system/sing-box.service <<SYSTEMD
[Unit]
Description=Sing-box VLESS Reality Server
After=network.target
[Service]
ExecStart=$binary run -c /etc/sing-box/config.json
Restart=on-failure
RestartSec=10s
LimitNOFILE=1048576
[Install]
WantedBy=multi-user.target
SYSTEMD
        systemctl daemon-reload
        systemctl enable sing-box
        systemctl restart sing-box
    fi
}

write_manager() {
    cat > /usr/local/bin/sb <<'SB_SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
umask 077
CONFIG=/etc/sing-box/config.json
NAMES=/etc/sing-box/node-names
PUBKEYS=/etc/sing-box/reality-public
CACHE=/etc/sing-box/.config_cache
info() { echo -e "\033[1;34m[INFO]\033[0m $*"; }
err() { echo -e "\033[1;31m[ERR]\033[0m $*" >&2; }
. /etc/os-release
if [[ "${ID:-}" == alpine ]]; then
    start_service() { rc-service sing-box start; }
    stop_service() { rc-service sing-box stop; }
    restart_service() { rc-service sing-box restart; }
    show_status() { rc-service sing-box status; }
else
    start_service() { systemctl start sing-box; }
    stop_service() { systemctl stop sing-box; }
    restart_service() { systemctl restart sing-box; }
    show_status() { systemctl status sing-box --no-pager; }
fi
generate_reality_keys() {
    local keys
    keys=$(sing-box generate reality-keypair)
    REALITY_PRIVATE=$(printf '%s\n' "$keys" | awk '/PrivateKey/ {print $NF; exit}')
    REALITY_PUBLIC=$(printf '%s\n' "$keys" | awk '/PublicKey/ {print $NF; exit}')
    REALITY_SHORT_ID=$(sing-box generate rand 8 --hex | tr -d '\r\n')
    [ -n "$REALITY_PRIVATE" ] && [ -n "$REALITY_PUBLIC" ] && [ -n "$REALITY_SHORT_ID" ] || { err "Reality 密钥生成失败"; return 1; }
}
make_inbound() {
    jq -n --arg tag "$1" --argjson port "$2" --arg uuid "$3" --arg sni "$4" \
        --arg private_key "$5" --arg short_id "$6" \
        '{type:"vless",tag:$tag,listen:"::",listen_port:$port,users:[{uuid:$uuid,flow:"xtls-rprx-vision"}],tls:{enabled:true,server_name:$sni,reality:{enabled:true,handshake:{server:$sni,server_port:443},private_key:$private_key,short_id:[$short_id]}}}'
}
prompt_socks() {
    local tag="$1" answer server server_port username password
    SOCKS_ENABLED=false
    SOCKS_JSON=null
    if [ "${2:-}" != force ]; then
        read -r -p '是否为此连接添加 SOCKS 出站? (y/N): ' answer
        [[ "$answer" =~ ^[Yy]$ ]] || return 0
    fi
    read -r -p 'SOCKS 服务器 server: ' server
    [ -n "$server" ] || { err "SOCKS 服务器不能为空"; return 1; }
    read -r -p 'SOCKS 端口 server_port: ' server_port
    [[ "$server_port" =~ ^[0-9]+$ ]] && [ "$server_port" -ge 1 ] && [ "$server_port" -le 65535 ] || { err "SOCKS 端口必须为 1-65535"; return 1; }
    read -r -p 'SOCKS 用户名 username: ' username
    [ -n "$username" ] || { err "SOCKS 用户名不能为空"; return 1; }
    read -r -p 'SOCKS 密码明文 (只输入密码本身，不要输入 password: 等字段): ' password
    [ -n "$password" ] || { err "SOCKS 密码不能为空"; return 1; }
    SOCKS_TAG="socks-${tag#vless-}"
    SOCKS_JSON=$(jq -n --arg tag "$SOCKS_TAG" --arg server "$server" --arg username "$username" --arg password "$password" --argjson port "$server_port" '{type:"socks",tag:$tag,server:$server,server_port:$port,username:$username,password:$password}')
    SOCKS_ENABLED=true
}
backup_config() { cp -a "$CONFIG" "${CONFIG}.bak"; }
validate_and_restart() {
    if sing-box check -c "$CONFIG"; then restart_service; info "配置已校验并重启服务";
    else err "配置校验失败，恢复备份"; cp -a "${CONFIG}.bak" "$CONFIG"; return 1; fi
}
get_tags() { jq -r '.inbounds[] | select(.type=="vless" and .tls.reality.enabled==true) | .tag' "$CONFIG"; }
show_nodes() {
    local i=0 tag name port
    while IFS= read -r tag; do
        [ -n "$tag" ] || continue
        i=$((i+1)); name=$(cat "$NAMES/$tag" 2>/dev/null || echo "$tag")
        port=$(jq -r --arg t "$tag" '.inbounds[]|select(.tag==$t)|.listen_port' "$CONFIG")
        printf '%2d) %-24s port=%s  [%s]\n' "$i" "$name" "$port" "$tag"
    done < <(get_tags)
    [ "$i" -gt 0 ] || echo '暂无连接'
}
select_tag() {
    local tags=() i
    mapfile -t tags < <(get_tags)
    [ "${#tags[@]}" -gt 0 ] || { err "暂无 VLESS Reality 连接"; return 1; }
    show_nodes
    read -r -p '输入要管理的序号: ' i
    [[ "$i" =~ ^[0-9]+$ ]] && [ "$i" -ge 1 ] && [ "$i" -le "${#tags[@]}" ] || { err "序号无效"; return 1; }
    SELECTED_TAG="${tags[$((i-1))]}"
}
host_value() {
    local host=''
    [ ! -f "$CACHE" ] || { . "$CACHE"; host="${CUSTOM_IP:-}"; }
    [ -n "$host" ] || host=$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || echo YOUR_SERVER_IP)
    if [[ "$host" == *:* && "$host" != \[*\] ]]; then host="[$host]"; fi
    printf '%s' "$host"
}
show_uri() {
    local tag="$1" host name port uuid sni sid pub
    name=$(cat "$NAMES/$tag" 2>/dev/null || echo "$tag")
    port=$(jq -r --arg t "$tag" '.inbounds[]|select(.tag==$t)|.listen_port' "$CONFIG")
    uuid=$(jq -r --arg t "$tag" '.inbounds[]|select(.tag==$t)|.users[0].uuid' "$CONFIG")
    sni=$(jq -r --arg t "$tag" '.inbounds[]|select(.tag==$t)|.tls.server_name' "$CONFIG")
    sid=$(jq -r --arg t "$tag" '.inbounds[]|select(.tag==$t)|.tls.reality.short_id[0]' "$CONFIG")
    pub=$(cat "$PUBKEYS/$tag")
    host=$(host_value)
    echo "${name}: vless://${uuid}@${host}:${port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${sni}&fp=chrome&pbk=${pub}&sid=${sid}#${name}"
}
add_node() {
    local name tag port sni uuid inbound used
    read -r -p '连接名称: ' name
    [ -n "$name" ] || { err "名称不能为空"; return 1; }
    tag="vless-$(openssl rand -hex 4)"
    read -r -p '监听端口 (留空随机 10000-60000): ' port
    port="${port:-$(shuf -i 10000-60000 -n 1)}"
    [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || { err "端口无效"; return 1; }
    used=$(jq --argjson p "$port" '[.inbounds[]|select(.listen_port==$p)]|length' "$CONFIG")
    [ "$used" = 0 ] || { err "端口已被配置占用"; return 1; }
    read -r -p 'Reality SNI (默认 addons.mozilla.org): ' sni
    sni="${sni:-addons.mozilla.org}"
    uuid=$(cat /proc/sys/kernel/random/uuid)
    generate_reality_keys
    inbound=$(make_inbound "$tag" "$port" "$uuid" "$sni" "$REALITY_PRIVATE" "$REALITY_SHORT_ID")
    prompt_socks "$tag" || return 1
    backup_config
    if [ "$SOCKS_ENABLED" = true ]; then
        jq --argjson inbound "$inbound" --argjson proxy "$SOCKS_JSON" --arg t "$tag" \
            '.inbounds += [$inbound] | .outbounds += [$proxy] | .route.rules += [{inbound:[$t],outbound:$proxy.tag}]' \
            "$CONFIG" > "${CONFIG}.tmp"
    else
        jq --argjson inbound "$inbound" '.inbounds += [$inbound]' "$CONFIG" > "${CONFIG}.tmp"
    fi
    mv "${CONFIG}.tmp" "$CONFIG"
    printf '%s' "$name" > "$NAMES/$tag"
    printf '%s' "$REALITY_PUBLIC" > "$PUBKEYS/$tag"
    if validate_and_restart; then show_uri "$tag"; else rm -f "$NAMES/$tag" "$PUBKEYS/$tag"; fi
}
delete_node() {
    select_tag || return 1
    local tag="$SELECTED_TAG" name
    name=$(cat "$NAMES/$tag" 2>/dev/null || echo "$tag")
    read -r -p "确认删除连接 '$name'? (y/N): " answer
    [[ "$answer" =~ ^[Yy]$ ]] || return 0
    backup_config
    local socks_tag="socks-${tag#vless-}"
    jq --arg t "$tag" --arg s "$socks_tag" \
        '.inbounds |= map(select(.tag!=$t)) | .outbounds |= map(select(.tag!=$s)) | .route.rules |= map(select((.inbound // []) | index($t) | not))' \
        "$CONFIG" > "${CONFIG}.tmp"
    mv "${CONFIG}.tmp" "$CONFIG"
    if validate_and_restart; then rm -f "$NAMES/$tag" "$PUBKEYS/$tag"; fi
}
manage_socks() {
    local tag="$1" socks_tag="socks-${1#vless-}" exists action
    exists=$(jq --arg s "$socks_tag" '[.outbounds[]|select(.tag==$s)]|length' "$CONFIG")
    if [ "$exists" -gt 0 ]; then
        read -r -p '此连接已有 SOCKS 出站: (1) 修改参数 (2) 移除 (0) 返回: ' action
        case "$action" in
            1)
                prompt_socks "$tag" force || return 1
                [ "$SOCKS_ENABLED" = true ] || return 0
                jq --arg s "$socks_tag" --argjson proxy "$SOCKS_JSON" \
                    '(.outbounds[]|select(.tag==$s))=$proxy' "$CONFIG" > "${CONFIG}.tmp"
                mv "${CONFIG}.tmp" "$CONFIG"
                ;;
            2)
                jq --arg t "$tag" --arg s "$socks_tag" \
                    '.outbounds |= map(select(.tag!=$s)) | .route.rules |= map(select((.inbound // []) | index($t) | not))' \
                    "$CONFIG" > "${CONFIG}.tmp"
                mv "${CONFIG}.tmp" "$CONFIG"
                ;;
            0) return 0 ;;
            *) err "无效选项"; return 1 ;;
        esac
    else
        prompt_socks "$tag" || return 1
        [ "$SOCKS_ENABLED" = true ] || return 0
        jq --argjson proxy "$SOCKS_JSON" --arg t "$tag" \
            '.outbounds += [$proxy] | .route.rules += [{inbound:[$t],outbound:$proxy.tag}]' \
            "$CONFIG" > "${CONFIG}.tmp"
        mv "${CONFIG}.tmp" "$CONFIG"
    fi
    validate_and_restart
}
modify_node() {
    select_tag || return 1
    local tag="$SELECTED_TAG" name port sni uuid choice inbound used old_tag
    echo "修改连接: $(cat "$NAMES/$tag" 2>/dev/null || echo "$tag")"
    echo '1) 名称  2) 端口  3) SNI  4) UUID  5) 重新生成 Reality 密钥  6) 管理 SOCKS 出站  0) 返回'
    read -r -p '选择要修改的项目: ' choice
    backup_config
    case "$choice" in
        1) read -r -p '新名称: ' name; [ -n "$name" ] || { err "名称不能为空"; return 1; }; printf '%s' "$name" > "$NAMES/$tag" ;;
        2) read -r -p '新端口: ' port; [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || { err "端口无效"; return 1; }; used=$(jq --arg t "$tag" --argjson p "$port" '[.inbounds[]|select(.tag!=$t and .listen_port==$p)]|length' "$CONFIG"); [ "$used" = 0 ] || { err "端口已被占用"; return 1; }; jq --arg t "$tag" --argjson p "$port" '(.inbounds[]|select(.tag==$t).listen_port)=$p' "$CONFIG" > "${CONFIG}.tmp"; mv "${CONFIG}.tmp" "$CONFIG" ;;
        3) read -r -p '新 SNI: ' sni; [ -n "$sni" ] || { err "SNI 不能为空"; return 1; }; jq --arg t "$tag" --arg s "$sni" '(.inbounds[]|select(.tag==$t)|.tls.server_name)=$s | (.inbounds[]|select(.tag==$t)|.tls.reality.handshake.server)=$s' "$CONFIG" > "${CONFIG}.tmp"; mv "${CONFIG}.tmp" "$CONFIG" ;;
        4) read -r -p '新 UUID (留空自动生成): ' uuid; uuid="${uuid:-$(cat /proc/sys/kernel/random/uuid)}"; jq --arg t "$tag" --arg u "$uuid" '(.inbounds[]|select(.tag==$t)|.users[0].uuid)=$u' "$CONFIG" > "${CONFIG}.tmp"; mv "${CONFIG}.tmp" "$CONFIG" ;;
        5) generate_reality_keys; jq --arg t "$tag" --arg k "$REALITY_PRIVATE" --arg sid "$REALITY_SHORT_ID" '(.inbounds[]|select(.tag==$t)|.tls.reality.private_key)=$k | (.inbounds[]|select(.tag==$t)|.tls.reality.short_id)=[$sid]' "$CONFIG" > "${CONFIG}.tmp"; mv "${CONFIG}.tmp" "$CONFIG"; printf '%s' "$REALITY_PUBLIC" > "$PUBKEYS/$tag" ;;
        6) manage_socks "$tag"; return $? ;;
        0) return 0 ;;
        *) err "无效选项"; return 1 ;;
    esac
    if validate_and_restart; then show_uri "$tag"; fi
}
uninstall() {
    read -r -p '确认卸载 sing-box 及全部连接配置? (y/N): ' answer
    [[ "$answer" =~ ^[Yy]$ ]] || return 0
    stop_service 2>/dev/null || true
    if [[ "${ID:-}" == alpine ]]; then rc-update del sing-box default 2>/dev/null || true; rm -f /etc/init.d/sing-box; apk del sing-box 2>/dev/null || true
    else systemctl disable sing-box 2>/dev/null || true; rm -f /etc/systemd/system/sing-box.service; systemctl daemon-reload; if [[ "${ID:-}" == debian || "${ID:-}" == ubuntu ]]; then apt-get purge -y sing-box 2>/dev/null || true; elif command -v dnf >/dev/null; then dnf remove -y sing-box 2>/dev/null || true; else yum remove -y sing-box 2>/dev/null || true; fi; fi
    rm -rf /etc/sing-box /usr/local/bin/sb /usr/bin/sb
    exit 0
}
while true; do
    echo
    echo '=== Sing-box VLESS Reality 多连接管理 ==='
    echo '1) 查看所有节点链接'
    echo '2) 添加连接'
    echo '3) 删除连接'
    echo '4) 修改连接'
    echo '5) 查看配置文件路径'
    echo '6) 编辑配置文件'
    echo '7) 启动服务'
    echo '8) 停止服务'
    echo '9) 重启服务'
    echo '10) 查看状态'
    echo '11) 更新 sing-box'
    echo '12) 卸载'
    echo '0) 退出'
    read -r -p '选择: ' option
    case "$option" in
        1) while IFS= read -r tag; do [ -n "$tag" ] && show_uri "$tag"; done < <(get_tags) ;;
        2) add_node ;;
        3) delete_node ;;
        4) modify_node ;;
        5) echo "$CONFIG" ;;
        6) ${EDITOR:-nano} "$CONFIG"; sing-box check -c "$CONFIG" && restart_service ;;
        7) start_service ;;
        8) stop_service ;;
        9) restart_service ;;
        10) show_status ;;
        11) if [[ "${ID:-}" == alpine ]]; then apk update && apk upgrade sing-box; else bash <(curl -fsSL https://sing-box.app/install.sh); fi; restart_service ;;
        12) uninstall ;;
        0) exit 0 ;;
        *) echo '无效选项' ;;
    esac
done
SB_SCRIPT
    chmod 700 /usr/local/bin/sb
    ln -sf /usr/local/bin/sb /usr/bin/sb
}

main() {
    detect_os
    info "系统: $OS"
    [ "$(id -u)" = 0 ] || { err "请以 root 运行"; exit 1; }
    install_deps
    install_singbox
    mkdir -p /etc/sing-box/node-names /etc/sing-box/reality-public
    chmod 700 /etc/sing-box /etc/sing-box/node-names /etc/sing-box/reality-public

    read -r -p '默认连接名称: ' name
    name="${name:-Reality-1}"
    read -r -p '连接 IP 或 DDNS 域名 (留空自动检测): ' host
    host=$(printf '%s' "$host" | tr -d '[:space:]')
    read -r -p 'Reality SNI (默认 addons.mozilla.org): ' sni
    sni="${sni:-addons.mozilla.org}"
    read -r -p 'VLESS Reality 端口 (留空随机 10000-60000): ' port
    port="${port:-$(rand_port)}"
    [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || { err "端口必须为 1-65535"; exit 1; }

    generate_reality_keys
    local_tag=vless-main
    uuid=$(rand_uuid)
    inbound=$(make_inbound "$local_tag" "$port" "$uuid" "$sni" "$REALITY_PRIVATE" "$REALITY_SHORT_ID")
    prompt_socks "$local_tag"
    jq -n --argjson inbound "$inbound" --argjson proxy "$SOCKS_JSON" --arg tag "$local_tag" \
        '{log:{level:"info",timestamp:true},ntp:{enabled:true,server:"time.apple.com",server_port:123,interval:"30m"},inbounds:[$inbound],outbounds:([{type:"direct",tag:"direct-out"}] + (if $proxy==null then [] else [$proxy] end)),route:{rules:(if $proxy==null then [] else [{inbound:[$tag],outbound:$proxy.tag}] end)}}' > "$CONFIG"
    chmod 600 "$CONFIG"
    printf '%s' "$name" > "/etc/sing-box/node-names/$local_tag"
    printf '%s' "$REALITY_PUBLIC" > "/etc/sing-box/reality-public/$local_tag"
    printf 'CUSTOM_IP=%q\n' "$host" > /etc/sing-box/.config_cache
    chmod 600 /etc/sing-box/.config_cache /etc/sing-box/reality-public/"$local_tag"
    sing-box check -c "$CONFIG"
    write_service
    write_manager

    [[ -n "$host" ]] || host=$(get_ip || echo YOUR_SERVER_IP)
    uri_host="$host"
    if [[ "$uri_host" == *:* && "$uri_host" != \[*\] ]]; then uri_host="[$uri_host]"; fi
    info "VLESS Reality 部署完成"
    echo "${name}: vless://${uuid}@${uri_host}:${port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${sni}&fp=chrome&pbk=${REALITY_PUBLIC}&sid=${REALITY_SHORT_ID}#${name}"
    echo '管理命令: sb'
}

main "$@"
