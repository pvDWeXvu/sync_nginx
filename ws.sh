#!/bin/bash

# --- 路径与配置定义 ---
NGINX_DIR="/etc/nginx"
STREAM_CONF="$NGINX_DIR/stream.conf"
NGINX_MAIN="$NGINX_DIR/nginx.conf"
DOMAIN_LIST="domains.txt"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# 权限检查
[[ $EUID -ne 0 ]] && echo -e "${RED}错误：请以 root 权限运行此脚本${NC}" && exit 1

# --- 工具函数 ---
log() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }

# --- 1. 环境安装与初始化 ---
install_nginx() {
    log "正在安装 Nginx 完整版..."
    apt-get update -y && apt-get install nginx-full libnginx-mod-stream -y
    
    # 模块健壮性检查：自动寻找并加载 stream 模块
    mkdir -p /etc/nginx/modules-enabled/
    if [[ -f "/usr/share/nginx/modules-available/ngx_stream_module.conf" ]]; then
        ln -sf /usr/share/nginx/modules-available/ngx_stream_module.conf /etc/nginx/modules-enabled/
    fi

    # 备份原始主配置
    [[ -f "$NGINX_MAIN" ]] && cp "$NGINX_MAIN" "${NGINX_MAIN}.bak"

    log "写入高性能主配置文件 (含 Cloudflare 1003 伪装)..."
    cat <<EOF > "$NGINX_MAIN"
user www-data;
worker_processes auto;
pid /run/nginx.pid;
include /etc/nginx/modules-enabled/*.conf;

events {
    worker_connections 4096; # 提升并发处理能力
    multi_accept on;
}

http {
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    types_hash_max_size 2048;
    server_tokens off;

    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    access_log /var/log/nginx/access.log;
    error_log /var/log/nginx/error.log;

    # 默认 80 端口逻辑：模拟 Cloudflare 1003
    server {
        listen 80 default_server;
        server_name _;

        location / {
            default_type text/html;
            add_header CF-Ray "\$request_id-SJC"; 
            add_header Server "cloudflare";
            return 403 '<html><head><title>Direct IP access not allowed | Cloudflare</title><style>body { font-family: -apple-system, system-ui; background: #fff; padding: 80px; }.container { max-width: 800px; margin: 0 auto; } h1 { font-size: 48px; font-weight: 400; margin: 0 0 10px; } .gray { color: #666; } hr { border:0; border-top:1px solid #eee; margin:20px 0; }</style></head><body><div class="container"><h1>Error 1003</h1><p class="gray">Ray ID: \$request_id &bull; IP: \$remote_addr</p><p>Direct IP access not allowed</p><hr><p class="gray">Cloudflare</p></div></body></html>';
        }
    }
}
# 包含 Stream 转发配置
include $STREAM_CONF;
EOF

    [[ ! -f "$DOMAIN_LIST" ]] && touch "$DOMAIN_LIST"
    sync_configs
    systemctl enable nginx
    systemctl restart nginx
    log "安装与初始化成功！"
}

# --- 2. 配置同步逻辑 (核心优化版) ---
sync_configs() {
    if [[ ! -f "$DOMAIN_LIST" ]]; then
        error "$DOMAIN_LIST 不存在，已自动创建。"
        touch "$DOMAIN_LIST"
    fi

    log "正在从 $DOMAIN_LIST 生成转发规则..."
    
    # 使用进程替换和临时文件，保证配置生成的原子性
    TMP_MAP=$(mktemp)
    TMP_UPSTREAM=$(mktemp)

    local count=0
    while read -r front back || [[ -n "$front" ]]; do
        # 过滤注释行和空行
        [[ -z "$front" || "$front" =~ ^# ]] && continue
        
        if [[ -z "$back" ]]; then
            warn "跳过无效配置行: $front"
            continue
        fi

        local tag=$(echo "$front" | tr '.' '_')
        echo "        $front server_${tag}_443;" >> "$TMP_MAP"
        echo "upstream server_${tag}_443 { server $back:443; }" >> "$TMP_UPSTREAM"
        ((count++))
    done < "$DOMAIN_LIST"

    # 生成 Stream 配置文件
    cat <<EOF > "${STREAM_CONF}.new"
stream {
    resolver 8.8.8.8 1.1.1.1 valid=30s;
    resolver_timeout 5s;

    map \$ssl_preread_server_name \$backend_node_443 {
        default 127.0.0.1:80; # SNI 匹配失败时，转发到本地 HTTP 80 返回 1003 错误
$(cat "$TMP_MAP")
    }

$(cat "$TMP_UPSTREAM")

    server {
        listen 443;
        proxy_pass \$backend_node_443;
        ssl_preread on;
        
        # 优化连接参数
        proxy_connect_timeout 5s;
        proxy_timeout 1h; # 保持长连接
        proxy_buffer_size 16k;
    }
}
EOF

    rm -f "$TMP_MAP" "$TMP_UPSTREAM"

    # 预检新配置
    mv "$STREAM_CONF" "${STREAM_CONF}.bak" 2>/dev/null
    mv "${STREAM_CONF}.new" "$STREAM_CONF"

    if nginx -t > /dev/null 2>&1; then
        systemctl reload nginx
        log "成功同步 $count 条规则，配置已生效！"
    else
        error "Nginx 配置检测失败！正在回滚..."
        mv "${STREAM_CONF}.bak" "$STREAM_CONF"
        nginx -t
    fi
}

# --- 3. 卸载逻辑 ---
uninstall_nginx() {
    warn "该操作将彻底移除 Nginx 及其所有配置数据！"
    read -p "请输入大写的 YES 确认: " confirm
    if [[ "$confirm" == "YES" ]]; then
        systemctl stop nginx
        apt-get purge nginx nginx-full libnginx-mod-stream -y
        apt-get autoremove -y
        rm -rf /etc/nginx
        log "卸载已完成。"
    else
        log "已取消卸载。"
    fi
}

# --- 主菜单 ---
while true; do
    echo -e "\n${YELLOW}=== Nginx SNI 转发管理系统 ===${NC}"
    echo "1) 同步配置 (domains.txt -> Nginx)"
    echo "2) 编辑域名列表 (格式: 域名 目标IP)"
    echo "3) 初次安装/重置环境"
    echo "4) 检查 Nginx 状态"
    echo "5) 彻底卸载"
    echo "6) 退出"
    read -p "请输入选项 [1-6]: " opt
    case $opt in
        1) sync_configs ;;
        2) ${EDITOR:-vi} "$DOMAIN_LIST" ;;
        3) install_nginx ;;
        4) systemctl status nginx --no-pager ;;
        5) uninstall_nginx ;;
        6) exit 0 ;;
        *) error "输入错误，请重新选择" ;;
    esac
done
