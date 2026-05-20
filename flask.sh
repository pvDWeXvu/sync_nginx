#!/bin/bash

# 配置区域
APP_DIR="$HOME/redirector-app"
VENV_DIR="$APP_DIR/venv"
FLASK_APP="$APP_DIR/app.py"
CADDY_CONF="/etc/caddy/Caddyfile"
SERVICE_NAME="redirector"

# 检查权限
if [ "$EUID" -ne 0 ]; then
  echo "错误: 请使用 sudo 或 root 权限运行此脚本"
  exit 1
fi

show_menu() {
    echo "------------------------------------------"
    echo "      Redirector 裸机管理脚本 (修复版)    "
    echo "------------------------------------------"
    echo "1. 环境初始化安装 (Python + Caddy)"
    echo "2. 修改转发目标 (Python TARGETS)"
    echo "3. 修改域名配置 (Caddyfile)"
    echo "4. 启动服务 (Start)"
    echo "5. 停止服务 (Stop)"
    echo "6. 重启服务 (Restart)"
    echo "7. 查看实时日志 (Logs)"
    echo "8. 卸载全部组件"
    echo "0. 退出"
    echo "------------------------------------------"
    printf "请输入选项 [0-8]: "
}

install_env() {
    echo ">>> 正在安装基础依赖..."
    apt-get update && apt-get install -y python3 python3-venv curl debian-keyring debian-archive-keyring apt-transport-https

    # 安装 Caddy (如果未安装)
    if ! command -v caddy &> /dev/null; then
        echo ">>> 正在安装 Caddy..."
        curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
        curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list
        apt-get update && apt-get install -y caddy
    fi

    mkdir -p $APP_DIR
    
    # 创建 Python 虚拟环境
    if [ ! -d $VENV_DIR ]; then
        echo ">>> 创建 Python 虚拟环境..."
        python3 -m venv $VENV_DIR
        $VENV_DIR/bin/pip install flask requests urllib3
    fi

    # 生成默认 app.py
    if [ ! -f $FLASK_APP ]; then
        cat > $FLASK_APP << 'INNER_EOF'
from flask import Flask, redirect, request
import threading, time, requests, urllib3
urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

app = Flask(__name__)
# === 你的目标站点 ===
TARGETS = ["https://google.com", "https://bing.com"]
# ===============================
cache = {"best": None, "ts": 0}
lock = threading.Lock()
TTL = 8

def ping(u):
    try:
        s = time.time()
        requests.head(u, timeout=1.2, verify=False)
        return time.time() - s
    except:
        return float("inf")

def bg():
    while True:
        valid = {k:v for k,v in {u:ping(u) for u in TARGETS}.items() if v != float("inf")}
        best = min(valid, key=valid.get) if valid else TARGETS[0]
        with lock: cache["best"] = best; cache["ts"] = time.time()
        time.sleep(TTL)

threading.Thread(target=bg, daemon=True).start()

@app.route("/<path:p>")
@app.route("/")
def r(p=""):
    with lock:
        if not cache["best"] or time.time() - cache["ts"] > TTL*2:
            best = min(TARGETS, key=ping)
        else: best = cache["best"]
    url = best.rstrip("/") + "/" + p
    if request.query_string: url += "?" + request.query_string.decode()
    return redirect(url, 302)

if __name__ == "__main__":
    app.run("127.0.0.1", 5000)
INNER_EOF
    fi

    # 写入正确的 Caddyfile (强制 /etc/caddy/ 路径)
    printf "请输入你的域名 (例如 www.abcd.com): "
    read DOMAIN
    cat > $CADDY_CONF << INNER_EOF
{
    email admin@admin.com
}

$DOMAIN {
    reverse_proxy 127.0.0.1:5000
}
INNER_EOF

    # 创建 Systemd 服务
    cat > /etc/systemd/system/$SERVICE_NAME.service << INNER_EOF
[Unit]
Description=Python Redirector Service
After=network.target

[Service]
User=root
WorkingDirectory=$APP_DIR
ExecStart=$VENV_DIR/bin/python $FLASK_APP
Restart=always

[Install]
WantedBy=multi-user.target
INNER_EOF

    systemctl daemon-reload
    systemctl enable $SERVICE_NAME
    systemctl enable caddy
    echo ">>> 环境初始化完成！请执行选项 4 启动服务。"
}

modify_targets() {
    nano $FLASK_APP
    systemctl restart $SERVICE_NAME
    echo ">>> 目标地址更新成功，Python 服务已重启。"
}

modify_caddy() {
    nano $CADDY_CONF
    systemctl reload caddy
    echo ">>> Caddy 配置已重载。"
}

start_all() {
    systemctl start $SERVICE_NAME
    systemctl restart caddy
    echo ">>> 所有服务已在后台运行。"
}

stop_all() {
    systemctl stop $SERVICE_NAME
    systemctl stop caddy
    echo ">>> 服务已停止。"
}

view_logs() {
    echo "提示: 按 Ctrl+C 退出日志查看"
    journalctl -u $SERVICE_NAME -u caddy -f
}

uninstall() {
    stop_all
    systemctl disable $SERVICE_NAME
    rm /etc/systemd/system/$SERVICE_NAME.service
    systemctl daemon-reload
    rm -rf $APP_DIR
    echo ">>> 卸载成功。注意：未移除 Caddy 软件包以防影响其他站点。"
}

# 循环显示菜单
while true; do
    show_menu
    read choice
    case $choice in
        1) install_env ;;
        2) modify_targets ;;
        3) modify_caddy ;;
        4) start_all ;;
        5) stop_all ;;
        6) systemctl restart $SERVICE_NAME && systemctl restart caddy ;;
        7) view_logs ;;
        8) uninstall ;;
        0) exit 0 ;;
        *) echo "无效输入，请重试" ;;
    esac
done
