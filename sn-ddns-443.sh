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
    
    # 备份原始配置
    [[ -f "$NGINX_MAIN" ]] && cp $NGINX_MAIN "${NGINX_MAIN}.bak"

    # 写入主配置文件 (仅返回纯文本 Error 1003)
    cat <<EOF > "$NGINX_MAIN"
user www-data;
worker_processes auto;
pid /run/nginx.pid;
error_log /var/log/nginx/error.log;
include /etc/nginx/modules-enabled/*.conf;

events {
    worker_connections 768;
}

http {
    sendfile on;
    tcp_nopush on;
    types_hash_max_size 2048;
    server_tokens off;

    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    ssl_protocols TLSv1 TLSv1.1 TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;
    access_log /var/log/nginx/access.log;

    # 直接通过 IP 访问时仅返回 Error 1003 纯文本
    server {
        listen 80;
        server_name _;

        location / {
            default_type text/plain;
            return 403 'error code: 1003';
        }
    }

    include /etc/nginx/conf.d/*.conf;
}

include $STREAM_CONF;
EOF

    # 初始化空的 stream.conf
    sync_configs
    
    systemctl enable nginx
    systemctl restart nginx
    echo -e "${GREEN}安装与初始化成功！${NC}"
}

# --- 2. 卸载功能 (带安全确认) ---
uninstall_nginx() {
    echo -e "${RED}警告：此操作将彻底删除 Nginx 及其所有转发配置！${NC}"
    read -p "请输入大写的 YES 确认卸载: " confirm
    if [[ "$confirm" == "YES" ]]; then
        echo -e "${YELLOW}正在卸载...${NC}"
        systemctl stop nginx
        apt-get purge nginx nginx-full nginx-common -y
        apt-get autoremove -y
        rm -rf /etc/nginx
        echo -e "${GREEN}Nginx 及所有配置文件已彻底移除。${NC}"
    else
        echo -e "${YELLOW}已取消卸载。${NC}"
    fi
}

# --- 3. 同步配置 (核心同步逻辑，支持 DDNS 动态解析) ---
sync_configs() {
    [[ ! -f "$DOMAIN_LIST" ]] && touch "$DOMAIN_LIST"
    
    local map_entries_443=""

    while read -r front back || [[ -n "$front" ]]; do
        [[ -z "$front" || "$front" =~ ^# ]] && continue
        
        # 将前端匹配域名映射到真实的后端 DDNS 域名及端口
        map_entries_443="${map_entries_443}        $front $back:443;\n"
    done < "$DOMAIN_LIST"

    cat <<EOF > "$STREAM_CONF"
stream {
    # 启用 DNS 解析服务，valid=10s 表示 DNS 缓存最多 10 秒即失效重新查询
    resolver 8.8.8.8 1.1.1.1 223.5.5.5 valid=10s;
    resolver_timeout 5s;

    map \$ssl_preread_server_name \$backend_target {
        default fake_web:443;
$(echo -e "$map_entries_443")    }

    server {
        listen 443;
        # 将 backend 传入变量，使得 Nginx 连接时动态通过 resolver 解析域名
        proxy_pass \$backend_target;
        ssl_preread on;
    }
}
EOF

    if nginx -t > /dev/null 2>&1; then
        systemctl reload nginx
        echo -e "${GREEN}配置已同步并生效 (已开启 DDNS 动态 IP 解析支持)！${NC}"
    else
        echo -e "${RED}同步后发现 Nginx 配置语法错误，请检查 domains.txt${NC}"
        nginx -t
    fi
}

# --- 主菜单 ---
while true; do
    echo -e "\n${YELLOW}=== Nginx 转发管理系统 (仅443，含 DDNS 支持) ===${NC}"
    echo "1. 同步配置 (从 domains.txt 更新规则)"
    echo "2. 编辑域名列表 (domains.txt)"
    echo "3. 初次安装 (安装 Nginx + 1003 报错)"
    echo "4. 彻底卸载 Nginx"
    echo "5. 退出"
    read -p "请选择操作 [1-5]: " opt
    case $opt in
        1) sync_configs ;;
        2) vi "$DOMAIN_LIST" ;;
        3) install_nginx ;;
        4) uninstall_nginx ;;
        5) exit 0 ;;
        *) echo -e "${RED}无效选项${NC}" ;;
    esac
done
