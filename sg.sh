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
    
    local now_time=$(date -u '+%Y-%m-%d %H:%M:%S')

    # 写入主配置文件 (HTTP 部分用于显示 1003 错误或兜底)
    cat <<EOF > "$NGINX_MAIN"
user www-data;
worker_processes auto;
pid /run/nginx.pid;
error_log /var/log/nginx/error.log;
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

    # 模拟 Cloudflare 1003 报错 (当直接 IP 访问或未匹配域名时)
    server {
        listen 80;
        server_name _;
        location / {
            default_type text/html;
            add_header CF-Ray "\$request_id-SJC"; 
            add_header Server "cloudflare";
            return 403 '<html><body style="font-family:sans-serif;padding:50px"><h1>Error 1003</h1><p>Direct IP access not allowed</p><hr><p>Cloudflare</p></body></html>';
        }
    }
}

include $STREAM_CONF;
EOF

    # 初始化空的 domains.txt
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
    else
        echo -e "${YELLOW}已取消卸载。${NC}"
    fi
}

# --- 3. 同步配置 (核心 SNI 分流逻辑) ---
sync_configs() {
    [[ ! -f "$DOMAIN_LIST" ]] && touch "$DOMAIN_LIST"
    
    local map_entries=""
    local upstream_blocks=""

    # 处理 domains.txt
    # 期望格式: 域名 后端IP 端口(如 2053 或 2083)
    while read -r front back port || [[ -n "$front" ]]; do
        [[ -z "$front" || "$front" =~ ^# ]] && continue
        
        # 默认端口处理
        [[ -z "$port" ]] && port="2053"
        
        # 生成唯一标识符 (将域名点号换成下划线)
        local tag=$(echo "${front}_${port}" | tr '.' '_')
        
        # 添加映射条目
        map_entries="${map_entries}        $front up_${tag};\n"
        
        # 添加后端定义
        upstream_blocks="${upstream_blocks}upstream up_${tag} { server $back:$port; }\n"
    done < "$DOMAIN_LIST"

    # 写入 Stream 配置文件
    cat <<EOF > "$STREAM_CONF"
stream {
    resolver 8.8.8.8 1.1.1.1 valid=30s;
    resolver_timeout 5s;

    # 根据 SNI 域名识别并选择后端变量
    map \$ssl_preread_server_name \$backend_name {
$(echo -e "$map_entries")
        default fake_web;
    }

    # 兜底后端
    upstream fake_web { server 127.0.0.1:80; }

    # 动态生成的后端资源池
$(echo -e "$upstream_blocks")

    # 本地只监听 443
    server {
        listen 443;
        proxy_pass \$backend_name;
        ssl_preread on; # 关键：预读 TLS 握手包获取域名
        
        proxy_connect_timeout 5s;
        proxy_timeout 1h;
        proxy_buffer_size 16k;
    }
}
EOF

    if nginx -t > /dev/null 2>&1; then
        systemctl reload nginx
        echo -e "${GREEN}配置已同步并生效！${NC}"
    else
        echo -e "${RED}同步失败：Nginx 配置语法错误，请检查 domains.txt${NC}"
        nginx -t
    fi
}

# --- 主菜单 ---
while true; do
    echo -e "\n${YELLOW}=== Nginx 443 SNI 分流管理系统 ===${NC}"
    echo -e "${YELLOW}逻辑：本地 443 -> 根据域名转发至后端 2053/2083${NC}"
    echo "1. 同步配置 (从 domains.txt 更新规则)"
    echo "2. 编辑域名列表 (domains.txt)"
    echo "3. 初次安装 (安装 Nginx + 基础环境)"
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
done#!/bin/bash

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
    
    local now_time=$(date -u '+%Y-%m-%d %H:%M:%S')

    # 写入主配置文件 (HTTP 部分用于显示 1003 错误或兜底)
    cat <<EOF > "$NGINX_MAIN"
user www-data;
worker_processes auto;
pid /run/nginx.pid;
error_log /var/log/nginx/error.log;
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

    # 模拟 Cloudflare 1003 报错 (当直接 IP 访问或未匹配域名时)
    server {
        listen 80;
        server_name _;
        location / {
            default_type text/html;
            add_header CF-Ray "\$request_id-SJC"; 
            add_header Server "cloudflare";
            return 403 '<html><body style="font-family:sans-serif;padding:50px"><h1>Error 1003</h1><p>Direct IP access not allowed</p><hr><p>Cloudflare</p></body></html>';
        }
    }
}

include $STREAM_CONF;
EOF

    # 初始化空的 domains.txt
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
    else
        echo -e "${YELLOW}已取消卸载。${NC}"
    fi
}

# --- 3. 同步配置 (核心 SNI 分流逻辑) ---
sync_configs() {
    [[ ! -f "$DOMAIN_LIST" ]] && touch "$DOMAIN_LIST"
    
    local map_entries=""
    local upstream_blocks=""

    # 处理 domains.txt
    # 期望格式: 域名 后端IP 端口(如 2053 或 2083)
    while read -r front back port || [[ -n "$front" ]]; do
        [[ -z "$front" || "$front" =~ ^# ]] && continue
        
        # 默认端口处理
        [[ -z "$port" ]] && port="2053"
        
        # 生成唯一标识符 (将域名点号换成下划线)
        local tag=$(echo "${front}_${port}" | tr '.' '_')
        
        # 添加映射条目
        map_entries="${map_entries}        $front up_${tag};\n"
        
        # 添加后端定义
        upstream_blocks="${upstream_blocks}upstream up_${tag} { server $back:$port; }\n"
    done < "$DOMAIN_LIST"

    # 写入 Stream 配置文件
    cat <<EOF > "$STREAM_CONF"
stream {
    resolver 8.8.8.8 1.1.1.1 valid=30s;
    resolver_timeout 5s;

    # 根据 SNI 域名识别并选择后端变量
    map \$ssl_preread_server_name \$backend_name {
$(echo -e "$map_entries")
        default fake_web;
    }

    # 兜底后端
    upstream fake_web { server 127.0.0.1:80; }

    # 动态生成的后端资源池
$(echo -e "$upstream_blocks")

    # 本地只监听 443
    server {
        listen 443;
        proxy_pass \$backend_name;
        ssl_preread on; # 关键：预读 TLS 握手包获取域名
        
        proxy_connect_timeout 5s;
        proxy_timeout 1h;
        proxy_buffer_size 16k;
    }
}
EOF

    if nginx -t > /dev/null 2>&1; then
        systemctl reload nginx
        echo -e "${GREEN}配置已同步并生效！${NC}"
    else
        echo -e "${RED}同步失败：Nginx 配置语法错误，请检查 domains.txt${NC}"
        nginx -t
    fi
}

# --- 主菜单 ---
while true; do
    echo -e "\n${YELLOW}=== Nginx 443 SNI 分流管理系统 ===${NC}"
    echo -e "${YELLOW}逻辑：本地 443 -> 根据域名转发至后端 2053/2083${NC}"
    echo "1. 同步配置 (从 domains.txt 更新规则)"
    echo "2. 编辑域名列表 (domains.txt)"
    echo "3. 初次安装 (安装 Nginx + 基础环境)"
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
