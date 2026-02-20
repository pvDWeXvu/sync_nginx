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

# --- 1. 安装功能 (高仿 Cloudflare 优化版) ---
install_nginx() {
    echo -e "${YELLOW}正在开始安装 Nginx 并配置高仿 Cloudflare 1003 页面...${NC}"
    
    apt-get update -y
    apt-get install nginx-full -y
    
    # 获取当前 UTC 时间和模拟一个 Ray ID
    local now_time=$(date -u '+%Y-%m-%d %H:%M:%S')
    local fake_ray=$(cat /proc/sys/kernel/random/uuid | tr -d '-' | cut -c1-16)

    # 写入主配置文件
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

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;

    # 模拟 CF 响应头
    add_header Server "cloudflare" always;
    add_header Content-Type "text/html; charset=UTF-8" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header Cache-Control "private, max-age=0, no-store, no-cache, must-revalidate, post-check=0, pre-check=0" always;

    server {
        listen 80;
        server_name _;

        location / {
            # 动态生成伪造的 Ray ID
            set \$fake_ray_id "${fake_ray}";
            add_header CF-Ray "\$fake_ray_id-SJC" always;

            return 403 '<!DOCTYPE html>
<html class="no-js" lang="en-US"> <head>
<title>Direct IP access not allowed | Cloudflare</title>
<meta charset="UTF-8" />
<meta http-equiv="Content-Type" content="text/html; charset=UTF-8" />
<meta http-equiv="X-UA-Compatible" content="IE=Edge,chrome=1" />
<meta name="robots" content="noindex, nofollow" />
<meta name="viewport" content="width=device-width,initial-scale=1" />
<style type="text/css">
  body{margin:0;padding:0}
  .cf-error-details .cf-error-type:before{content:"\\00a0" content-visibility:hidden;display:block;height:0}
  #cf-wrapper #cf-error-details .cf-error-type-container{margin-bottom:4px}
  #cf-wrapper #cf-error-details .cf-status-label{color:#bd242a}
  #cf-wrapper #cf-error-details .cf-status-name{font-weight:500}
  #cf-wrapper #cf-error-details .cf-status-desc{color:#404040}
  #cf-wrapper #cf-error-details .cf-error-header-desc{font-size:18px;font-weight:400;color:#404040;line-height:1.3;margin:0}
  #cf-wrapper #cf-error-details .cf-error-footer{padding:1.33333rem 0;border-top:1px solid #ebebeb;text-align:left;font-size:13px}
  #cf-wrapper #cf-error-details .cf-footer-item{display:inline-block;white-space:nowrap}
  #cf-wrapper #cf-error-details .cf-footer-separator{margin:0 .5rem;color:#ebebeb}
  #cf-wrapper #cf-error-details .cf-footer-separator:before{content:"\\2022"}
  body{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Oxygen,Ubuntu,Cantarell,"Fira Sans","Droid Sans","Helvetica Neue",sans-serif;font-size:15px;line-height:1.5;color:#404040}
  .cf-wrapper{width:90%;margin-left:auto;margin-right:auto;max-width:960px}
  .cf-section{padding:2.5rem 0}
  h1{font-size:2.4rem;line-height:1.1;font-weight:400;margin:0 0 .5rem}
  p{margin-top:0;margin-bottom:1.5rem}
  .cf-gray{color:#999}
</style>
</head>
<body>
  <div id="cf-wrapper">
    <div id="cf-error-details" class="cf-error-details-wrapper">
      <div class="cf-wrapper cf-error-overview">
        <div class="cf-section">
          <h1 class="cf-error-title">Error 1003</h1>
          <p class="cf-error-header-desc">Direct IP access not allowed</p>
        </div>
      </div>
      <div class="cf-wrapper cf-error-footer cf-footer">
        <div class="cf-section">
          <div class="cf-footer-item">Ray ID: <strong>\$fake_ray_id</strong></div>
          <div class="cf-footer-separator"></div>
          <div class="cf-footer-item"><span>$now_time UTC</span></div>
          <div class="cf-footer-separator"></div>
          <div class="cf-footer-item"><span>Cloudflare</span></div>
        </div>
      </div>
    </div>
  </div>
</body>
</html>';
        }
    }

    include /etc/nginx/conf.d/*.conf;
}

include $STREAM_CONF;
EOF

    sync_configs
    systemctl enable nginx
    systemctl restart nginx
    echo -e "${GREEN}安装与高仿配置初始化成功！${NC}"
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
