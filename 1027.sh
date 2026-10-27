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

# --- 1. 安装与初始化功能 ---
install_nginx() {
    echo -e "${YELLOW}正在开始安装 Nginx 及高并发系统级优化...${NC}"
    
    apt-get update -y
    apt-get install nginx-full -y
    
    # 1. 自动修改系统安全限制 /etc/security/limits.conf
    if ! grep -q "nofile 65535" /etc/security/limits.conf; then
        echo -e "${YELLOW}正在优化系统文件句柄限制 (limits.conf)...${NC}"
        cat <<EOF >> /etc/security/limits.conf
- soft nofile 65535
- hard nofile 65535
root soft nofile 65535
root hard nofile 65535
EOF
    fi

    # 2. 备份原始配置
    [[ -f "$NGINX_MAIN" ]] && cp "$NGINX_MAIN" "${NGINX_MAIN}.bak"

    # 3. 写入主配置文件 (含 worker_rlimit_nofile 65535 和高性能事件模型)
    cat <<EOF > "$NGINX_MAIN"
user www-data;
worker_processes auto;
worker_rlimit_nofile 65535;
pid /run/nginx.pid;
error_log /var/log/nginx/error.log;
include /etc/nginx/modules-enabled/*.conf;

events {
    worker_connections 10240;
    use epoll;
    multi_accept on;
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

    # 4. 配置 systemd 服务端句柄限制
    mkdir -p /etc/systemd/system/nginx.service.d
    cat <<EOF > /etc/systemd/system/nginx.service.d/override.conf
[Service]
LimitNOFILE=65535
EOF

    systemctl daemon-reload

    # 5. 初始化 stream 配置
    sync_configs
    
    systemctl enable nginx
    systemctl restart nginx
    echo -e "${GREEN}安装与高并发系统级优化全部完成！${NC}"
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
        rm -rf /etc/nginx /etc/systemd/system/nginx.service.d
        systemctl daemon-reload
        echo -e "${GREEN}Nginx 及所有配置文件已彻底移除。${NC}"
    else
        echo -e "${YELLOW}已取消卸载。${NC}"
    fi
}

# --- 3. 重启 Nginx 功能 ---
restart_nginx() {
    echo -e "${YELLOW}正在检查 Nginx 配置语法...${NC}"
    if nginx -t; then
        systemctl restart nginx
        echo -e "${GREEN}Nginx 重启成功！${NC}"
    else
        echo -e "${RED}Nginx 语法检查失败，取消重启，请检查配置文件。${NC}"
    fi
}

# --- 4. 同步配置 (核心同步逻辑，仅 443 端口，支持自定义后端端口及 DDNS) ---
sync_configs() {
    [[ ! -f "$DOMAIN_LIST" ]] && touch "$DOMAIN_LIST"
    
    local map_entries_443=""

    while read -r front back || [[ -n "$front" ]]; do
        [[ -z "$front" || "$front" =~ ^# ]] && continue
        
        # 如果 back 后面没有指定端口（即不包含冒号），则自动补全为 :443
        if [[ -n "$back" && "$back" != *:* ]]; then
            back="${back}:443"
        fi

        # 如果整行只有一个参数（只写了前台域名，没写后台），则默认转发到自己并保持 443
        if [[ -z "$back" ]]; then
            back="${front}:443"
        fi

        # 生成 443 端口的映射规则
        map_entries_443="${map_entries_443}        $front $back;\n"
    done < "$DOMAIN_LIST"

    cat <<EOF > "$STREAM_CONF"
stream {
    # 扩大哈希表，防止域名较多时溢出
    map_hash_max_size 65536;
    map_hash_bucket_size 128;

    # 启用 DNS 解析服务，valid=30s 表示 DNS 缓存 30 秒
    resolver 8.8.8.8 1.1.1.1 223.5.5.5 valid=30s;
    resolver_timeout 5s;

    # --- 443 端口分流 ---
    map \$ssl_preread_server_name \$backend_target_443 {
        default 198.51.100.1:443;
$(echo -e "$map_entries_443")    }
    server {
        listen 443;
        proxy_pass \$backend_target_443;
        ssl_preread on;
    }
}
EOF

    if nginx -t > /dev/null 2>&1; then
        systemctl reload nginx
        echo -e "${GREEN}配置已同步并生效 (仅 443 端口，支持自定义后端端口及 DDNS)！${NC}"
    else
        echo -e "${RED}同步后发现 Nginx 配置语法错误，请检查 domains.txt${NC}"
        nginx -t
    fi
}

# --- 主菜单 ---
while true; do
    echo -e "\n${YELLOW}=== Nginx 443 端口转发管理系统 (含高并发与 DDNS 支持) ===${NC}"
    echo "1. 同步配置 (从 domains.txt 更新规则)"
    echo "2. 编辑域名列表 (domains.txt)"
    echo "3. 重启 Nginx 服务 (含语法检查)"
    echo "4. 初次安装 (安装 Nginx + 系统级高并发优化 + 1003 报错)"
    echo "5. 彻底卸载 Nginx"
    echo "6. 退出"
    read -p "请选择操作 [1-6]: " opt
    case $opt in
        1) sync_configs ;;
        2) vi "$DOMAIN_LIST" ;;
        3) restart_nginx ;;
        4) install_nginx ;;
        5) uninstall_nginx ;;
        6) exit 0 ;;
        *) echo -e "${RED}无效选项${NC}" ;;
    esac
done
