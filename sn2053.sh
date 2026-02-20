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
    local now_time=$(date -u '+%Y-%m-%d %H:%M:%S')

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

    server {
        listen 80;
        server_name _;
        location / {
            default_type text/html;
            add_header CF-Ray "\$request_id-SJC"; 
            add_header Server "cloudflare";
            return 403 '<html><head><title>Direct IP access not allowed | Cloudflare</title></head><body><div style="text-align:center;padding:100px;"><h1>Error 1003</h1><p>Direct IP access not allowed</p><hr><p>Cloudflare</p></div></body></html>';
        }
    }
    include /etc/nginx/conf.d/*.conf;
}
include $STREAM_CONF;
EOF

    # 初始化空的 stream.conf
    touch "$DOMAIN_LIST"
    sync_configs
    
    systemctl enable nginx
    systemctl restart nginx
    echo -e "${GREEN}安装与初始化成功！本机仅监听 80(报错) 和 443(转发)${NC}"
}

# --- 2. 卸载功能 ---
uninstall_nginx() {
    echo -e "${RED}警告：此操作将彻底删除 Nginx！${NC}"
    read -p "请输入大写的 YES 确认卸载: " confirm
    if [[ "$confirm" == "YES" ]]; then
        systemctl stop nginx
        apt-get purge nginx nginx-full nginx-common -y
        apt-get autoremove -y
        rm -rf /etc/nginx
        echo -e "${GREEN}卸载完成。${NC}"
    fi
}

# --- 3. 同步配置 (核心修改处) ---
sync_configs() {
    [[ ! -f "$DOMAIN_LIST" ]] && touch "$DOMAIN_LIST"
    
    local map_entries=""
    local upstream_blocks=""

    while read -r front back || [[ -n "$front" ]]; do
        [[ -z "$front" || "$front" =~ ^# ]] && continue
        
        # 将域名中的点替换为下划线作为 upstream 名称
        local tag=$(echo "$front" | tr '.' '_')
        
        # 映射逻辑：访问域名 -> 对应的 upstream 模块
        map_entries="${map_entries}        $front upstream_${tag};\n"
        
        # 定义后端：指向后端的 2053 端口
        upstream_blocks="${upstream_blocks}upstream upstream_${tag} { server $back:2053; }\n"
    done < "$DOMAIN_LIST"

    cat <<EOF > "$STREAM_CONF"
stream {
    resolver 8.8.8.8 1.1.1.1 valid=30s;
    resolver_timeout 5s;

    # 根据 SNI (域名) 选择后端
    map \$ssl_preread_server_name \$backend_name {
        default      fake_backend; 
$(echo -e "$map_entries")    }

    # 默认兜底后端（可选，防止 SNI 不匹配时报错）
    upstream fake_backend { server 127.0.0.1:80; }

    # --- UPSTREAMS 定义 ---
$(echo -e "$upstream_blocks")

    # 本机只监听 443 端口
    server {
        listen 443;
        proxy_pass \$backend_name;
        ssl_preread on; # 必须开启，用于读取域名信息
        
        # 优化转发性能
        proxy_connect_timeout 5s;
        proxy_timeout 1h;
        proxy_buffer_size 16k;
    }
}
EOF

    if nginx -t > /dev/null 2>&1; then
        systemctl reload nginx
        echo -e "${GREEN}同步成功！443 端口已指向后端 2053 端口。${NC}"
    else
        echo -e "${RED}配置语法错误，请检查 domains.txt${NC}"
        nginx -t
    fi
}

# --- 主菜单 ---
while true; do
    echo -e "\n${YELLOW}=== Nginx 443 -> 2053 转发管理 ===${NC}"
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
