#!/bin/bash

# --- 路径定义 ---
STREAM_CONF="/etc/nginx/stream.conf"
NGINX_MAIN="/etc/nginx/nginx.conf"
DOMAIN_LIST="domains.txt"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# 权限检查
[[ $EUID -ne 0 ]] && echo -e "${RED}错误：请以 root 权限运行此脚本${NC}" && exit 1

# --- 1. 安装功能 ---
install_nginx() {
    echo -e "${YELLOW}正在开始安装 Nginx 及初始化配置...${NC}"
    apt-get update -y
    apt-get install nginx-full -y
    
    [[ -f "$NGINX_MAIN" ]] && cp $NGINX_MAIN "${NGINX_MAIN}.bak"

    cat <<EOF > "$NGINX_MAIN"
user www-data;
worker_processes auto;
pid /run/nginx.pid;
include /etc/nginx/modules-enabled/*.conf;

events {
    worker_connections 1024;
}

http {
    sendfile on;
    tcp_nopush on;
    server_tokens off;
    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    server {
        listen 80;
        server_name _;
        location / {
            default_type text/html;
            return 403 '<html><body style="font-family:sans-serif;padding:50px"><h1>Error 1003</h1><p>Direct IP access not allowed</p><hr><p>Cloudflare</p></body></html>';
        }
    }
}

include $STREAM_CONF;
EOF

    [[ ! -f "$DOMAIN_LIST" ]] && touch "$DOMAIN_LIST"
    sync_configs
    systemctl enable nginx
    systemctl restart nginx
    echo -e "${GREEN}安装与初始化成功！${NC}"
}

# --- 2. 卸载功能 ---
uninstall_nginx() {
    echo -e "${RED}警告：此操作将彻底删除 Nginx 及其所有配置！${NC}"
    read -p "请输入大写的 YES 确认卸载: " confirm
    if [[ "$confirm" == "YES" ]]; then
        systemctl stop nginx
        apt-get purge nginx nginx-full nginx-common -y
        apt-get autoremove -y
        rm -rf /etc/nginx
        echo -e "${GREEN}Nginx 已彻底移除。${NC}"
    fi
}

# --- 3. 同步配置 ---
sync_configs() {
    [[ ! -f "$DOMAIN_LIST" ]] && touch "$DOMAIN_LIST"
    
    local map_entries=""
    local upstream_blocks=""

    while read -r front back port || [[ -n "$front" ]]; do
        [[ -z "$front" || "$front" =~ ^# ]] && continue
        [[ -z "$port" ]] && port="2053"
        
        local tag=$(echo "${front}_${port}" | tr '.' '_')
        map_entries="${map_entries}        $front up_${tag};\n"
        upstream_blocks="${upstream_blocks}upstream up_${tag} { server $back:$port; }\n"
    done < "$DOMAIN_LIST"

    cat <<EOF > "$STREAM_CONF"
stream {
    resolver 8.8.8.8 1.1.1.1 valid=30s;
    resolver_timeout 5s;

    map \$ssl_preread_server_name \$backend_name {
$(echo -e "$map_entries")
        default fake_web;
    }

    upstream fake_web { server 127.0.0.1:80; }

$(echo -e "$upstream_blocks")

    server {
        listen 443;
        proxy_pass \$backend_name;
        ssl_preread on;
        proxy_connect_timeout 5s;
        proxy_timeout 1h;
    }
}
EOF

    if nginx -t > /dev/null 2>&1; then
        systemctl reload nginx
        echo -e "${GREEN}配置同步成功！(端口分流已生效)${NC}"
    else
        echo -e "${RED}配置错误，检查 domains.txt${NC}"
        nginx -t
    fi
}

# --- 主菜单 ---
while true; do
    echo -e "\n${YELLOW}=== Nginx 443 SNI 分流系统 ===${NC}"
    echo "1. 同步配置 (domains.txt -> Nginx)"
    echo "2. 编辑域名列表 (domains.txt)"
    echo "3. 初次安装"
    echo "4. 彻底卸载"
    echo "5. 退出"
    read -p "选择 [1-5]: " opt
    case $opt in
        1) sync_configs ;;
        2) vi "$DOMAIN_LIST" ;;
        3) install_nginx ;;
        4) uninstall_nginx ;;
        5) exit 0 ;;
        *) echo -e "${RED}无效选项${NC}" ;;
    esac
done
