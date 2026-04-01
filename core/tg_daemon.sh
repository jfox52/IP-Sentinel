#!/bin/bash

# ==========================================================
# 脚本名称: tg_daemon.sh (Telegram 互动监听守护进程)
# 核心功能: 极低功耗长轮询监听 TG 指令，实现远程控制
# ==========================================================

INSTALL_DIR="/opt/ip_sentinel"
CONFIG_FILE="${INSTALL_DIR}/config.conf"
OFFSET_FILE="/tmp/ip_sentinel_tg_offset.txt"

# 1. 环境自检
[ ! -f "$CONFIG_FILE" ] && exit 1
source "$CONFIG_FILE"

# 如果没有配置 TG 机器人，则安静退出守护进程
[ -z "$TG_TOKEN" ] || [ -z "$CHAT_ID" ] && exit 0

# 2. 初始化消息偏移量 (Offset) 记录文件，防止重启后重复处理老消息
OFFSET=0
[ -f "$OFFSET_FILE" ] && OFFSET=$(cat "$OFFSET_FILE")

# 发送消息的快捷工具函数
send_msg() {
    curl -s -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
        -d "chat_id=$CHAT_ID" -d "text=$1" -d "parse_mode=Markdown" > /dev/null
}

# 3. 核心守护循环 (无限长轮询监听)
# timeout=30 表示如果没有新消息，连接会挂起 30 秒才断开重连，极大地降低了系统资源消耗
while true; do
    UPDATES=$(curl -s "https://api.telegram.org/bot${TG_TOKEN}/getUpdates?offset=${OFFSET}&timeout=30")
    
    # 使用 jq 检查是否有新消息返回
    COUNT=$(echo "$UPDATES" | jq -r '.result | length' 2>/dev/null)
    
    if [[ "$COUNT" =~ ^[0-9]+$ ]] && [ "$COUNT" -gt 0 ]; then
        for (( i=0; i<$COUNT; i++ )); do
            UPDATE_ID=$(echo "$UPDATES" | jq -r ".result[$i].update_id")
            MSG_CHAT_ID=$(echo "$UPDATES" | jq -r ".result[$i].message.chat.id")
            MSG_TEXT=$(echo "$UPDATES" | jq -r ".result[$i].message.text")

            # 【安全防御】严格权限验证：只响应你部署时填入的 Chat ID，无视陌生人消息
            if [ "$MSG_CHAT_ID" == "$CHAT_ID" ]; then
                case "$MSG_TEXT" in
                    "/run")
                        send_msg "🚀 **[指令下达]** 正在后台立即触发 IP 养护任务..."
                        # 使用 nohup 另起后台独立进程运行，防止阻塞当前监听器的循环
                        nohup bash "${INSTALL_DIR}/core/mod_google.sh" >/dev/null 2>&1 &
                        ;;
                    "/log")
                        LOG_DATA=$(tail -n 15 "${INSTALL_DIR}/logs/sentinel.log")
                        send_msg "📄 **[最近 15 行系统日志]**%0A\`\`\`log%0A${LOG_DATA}%0A\`\`\`"
                        ;;
                    "/report")
                        # 触发生成一次战报
                        bash "${INSTALL_DIR}/core/tg_report.sh"
                        ;;
                    "/help"|"/start")
                        HELP_MSG="🛡️ **IP-Sentinel 控制台**%0A/run - 立刻执行一次养护%0A/log - 抓取最新运行日志%0A/report - 手动生成统计简报"
                        send_msg "$HELP_MSG"
                        ;;
                esac
            fi
            
            # 记录处理完毕的 message ID，下次请求从新的 ID 开始获取
            OFFSET=$((UPDATE_ID + 1))
            echo "$OFFSET" > "$OFFSET_FILE"
        done
    fi
    # 基础安全延时，防止极端网络情况下的死循环吃光 CPU
    sleep 2
done