#!/bin/bash

# ==========================================================
# 脚本名称: agent_daemon.sh (受控节点 Webhook 守护进程)
# 核心功能: 向 Master 汇报公网 IP 注册、监听本地 HTTP 唤醒指令
# ==========================================================

INSTALL_DIR="/opt/ip_sentinel"
CONFIG_FILE="${INSTALL_DIR}/config.conf"

[ ! -f "$CONFIG_FILE" ] && exit 1
source "$CONFIG_FILE"

# 如果没有配置 TG，说明未开启联控模式，直接退出
[ -z "$TG_TOKEN" ] || [ -z "$CHAT_ID" ] && exit 0

# 默认 Webhook 监听端口，可在安装时动态写入配置
AGENT_PORT=${AGENT_PORT:-9527}
# 截取主机名作为节点唯一标识 (可限制长度防超长)
NODE_NAME=$(hostname | cut -c 1-15)

# 1. 获取本机原生公网 IPv4
AGENT_IP=$(curl -4 -s -m 5 api.ip.sb/ip)

if [ -n "$AGENT_IP" ]; then
    # 2. 向 Master 发送注册暗号 (借助 TG API)
    # 格式严格匹配 Master 端的正则: #REGISTER#|<NodeName>|<IP>|<Port>
    REG_MSG="#REGISTER#|${NODE_NAME}|${AGENT_IP}|${AGENT_PORT}"
    
    curl -s -m 5 -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
        -d "chat_id=${CHAT_ID}" \
        -d "text=${REG_MSG}" > /dev/null
    
    echo "✅ [Agent] 已向司令部发送注册/续期请求: $NODE_NAME ($AGENT_IP:$AGENT_PORT)"
fi

# 3. 启动轻量级 Python3 Webhook 监听服务
# (相比纯 Bash 的 nc 命令，Python3 的 HTTP 库在各发行版间兼容性最完美，且支持并发)
cat > "${INSTALL_DIR}/core/webhook.py" << 'EOF'
import http.server
import socketserver
import subprocess
import sys

PORT = int(sys.argv[1])

class AgentHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        # 统一返回成功，防止 Master 请求超时阻塞
        self.send_response(200)
        self.send_header("Content-type", "text/plain")
        self.end_headers()
        self.wfile.write(b"Agent Received Action\n")
        
        # 路由分发
        if self.path == '/trigger_run':
            # 另起后台进程执行深度伪装，不阻塞 Webhook 响应
            subprocess.Popen(['bash', '/opt/ip_sentinel/core/mod_google.sh'])
        elif self.path == '/trigger_report':
            # 另起后台进程执行战报生成
            subprocess.Popen(['bash', '/opt/ip_sentinel/core/tg_report.sh'])
        elif self.path == '/trigger_log':
            # 【新增升级】抓取最后15行日志并通过 TG 原路返回 (直接通过 bash -c 运行复合命令)
            bash_cmd = """
            source /opt/ip_sentinel/config.conf
            LOG_DATA=$(tail -n 15 /opt/ip_sentinel/logs/sentinel.log)
            NODE=$(hostname | cut -c 1-15)
            curl -s -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
                -d "chat_id=${CHAT_ID}" \
                -d "text=📄 **[${NODE}] 实时运行日志:**%0A\`\`\`log%0A${LOG_DATA}%0A\`\`\`" \
                -d "parse_mode=Markdown"
            """
            subprocess.Popen(['bash', '-c', bash_cmd])

    def log_message(self, format, *args):
        # 关闭默认的控制台日志输出，保持后台清爽
        pass

try:
    with socketserver.TCPServer(("", PORT), AgentHandler) as httpd:
        httpd.serve_forever()
except Exception as e:
    sys.exit(1)
EOF

# 保持前台运行 (被 Cron 的 nohup 放入后台守护)
python3 "${INSTALL_DIR}/core/webhook.py" "$AGENT_PORT"