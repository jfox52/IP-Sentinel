#!/bin/bash

# ==========================================================
# 脚本名称: tg_master.sh (Master 端调度枢纽)
# 核心功能: 监听 TG、操作 SQLite、向 Agent 发送多维 Webhook 指令
# ==========================================================

CONF="/opt/ip_sentinel_master/master.conf"
[ ! -f "$CONF" ] && exit 1
source "$CONF"

OFFSET_FILE="/tmp/tg_master_offset"
[[ -f $OFFSET_FILE ]] || echo "0" > $OFFSET_FILE

# --- 工具函数 ---
send_ui() {
    curl -s -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
        -H "Content-Type: application/json" \
        -d "{\"chat_id\":\"$1\",\"text\":\"$2\",\"parse_mode\":\"Markdown\",\"reply_markup\":{\"inline_keyboard\":$3}}" > /dev/null
}

send_msg() {
    curl -s -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
        -d "chat_id=$1" -d "text=$2" -d "parse_mode=Markdown" > /dev/null
}

# 数据库执行函数
db_exec() {
    sqlite3 "$DB_FILE" "$1"
}

# --- 核心轮询循环 ---
while true; do
    OFFSET=$(cat $OFFSET_FILE)
    UPDATES=$(curl -s "https://api.telegram.org/bot${TG_TOKEN}/getUpdates?offset=${OFFSET}&timeout=30")
    
    COUNT=$(echo "$UPDATES" | jq -r '.result | length' 2>/dev/null)
    
    if [[ "$COUNT" =~ ^[0-9]+$ ]] && [ "$COUNT" -gt 0 ]; then
        echo "$UPDATES" | jq -c '.result[]' | while read -r UPDATE; do
            UPDATE_ID=$(echo "$UPDATE" | jq -r '.update_id')
            echo $((UPDATE_ID + 1)) > $OFFSET_FILE
            
            CHAT_ID=$(echo "$UPDATE" | jq -r '.message.chat.id // .callback_query.message.chat.id')
            TEXT=$(echo "$UPDATE" | jq -r '.message.text // .callback_query.data')

            # ==========================================
            # 1. 节点注册通道 (处理 Agent 发来的注册暗号)
            # 格式: #REGISTER#|<NodeName>|<IP>|<Port>
            # ==========================================
            if [[ "$TEXT" == *"#REGISTER#"* ]]; then
                IFS='|' read -r MAGIC NODE_NAME AGENT_IP AGENT_PORT <<< "$TEXT"
                # UPSERT 逻辑: 如果节点存在则更新 IP/Port 和在线时间，不存在则插入
                db_exec "INSERT INTO nodes (chat_id, node_name, agent_ip, agent_port, last_seen) VALUES ('$CHAT_ID', '$NODE_NAME', '$AGENT_IP', '$AGENT_PORT', CURRENT_TIMESTAMP) ON CONFLICT(chat_id, node_name) DO UPDATE SET agent_ip='$AGENT_IP', agent_port='$AGENT_PORT', last_seen=CURRENT_TIMESTAMP;"
                send_msg "$CHAT_ID" "✅ 节点注册成功/续期: \`$NODE_NAME\` ($AGENT_IP:$AGENT_PORT)"
                continue
            fi

            # ==========================================
            # 2. 交互菜单与下发通道 (主控逻辑)
            # ==========================================
            case "$TEXT" in
                "/start"|"/menu")
                    BTNS="[[{\"text\":\"🖥️ 我的节点列表\",\"callback_data\":\"list_nodes\"}], [{\"text\":\"🚀 全节点一键维护\",\"callback_data\":\"all_run\"}]]"
                    send_ui "$CHAT_ID" "🛡️ **IP-Sentinel 司令部**\n欢迎回来，长官。请下达指令：" "$BTNS"
                    ;;

                "list_nodes")
                    # 从 SQLite 查询属于该 CHAT_ID 的节点
                    NODE_LIST=$(db_exec "SELECT node_name FROM nodes WHERE chat_id='$CHAT_ID';")
                    if [ -z "$NODE_LIST" ]; then
                        send_msg "$CHAT_ID" "⚠️ 您名下暂无在线节点，请先在边缘机执行部署。"
                    else
                        BTNS="["
                        for N in $NODE_LIST; do
                            BTNS="$BTNS[{\"text\":\"🖥️ $N\",\"callback_data\":\"manage:$N\"}],"
                        done
                        BTNS="${BTNS%,}]"
                        send_ui "$CHAT_ID" "🔍 您名下的活跃节点：" "$BTNS"
                    fi
                    ;;

                manage:*)
                    TARGET_NODE=${TEXT#*:}
                    # 【升级点】补齐包含 run、log、report 的复合面板菜单
                    BTNS="[[{\"text\":\"▶️ 执行深度伪装\",\"callback_data\":\"run:$TARGET_NODE\"}, {\"text\":\"📜 查看实时日志\",\"callback_data\":\"log:$TARGET_NODE\"}], [{\"text\":\"📊 索要统计战报\",\"callback_data\":\"report:$TARGET_NODE\"}, {\"text\":\"⬅️ 返回主列表\",\"callback_data\":\"list_nodes\"}]]"
                    send_ui "$CHAT_ID" "⚙️ **目标锁定**: \`$TARGET_NODE\`\n请选择战术动作：" "$BTNS"
                    ;;

                run:*|report:*|log:*)
                    # 【升级点】合并 Webhook 触发逻辑，智能识别动作类型
                    ACTION_TYPE=$(echo "$TEXT" | cut -d':' -f1)
                    TARGET_NODE=$(echo "$TEXT" | cut -d':' -f2)
                    
                    # 从 DB 提取 IP 和 Port
                    AGENT_INFO=$(db_exec "SELECT agent_ip, agent_port FROM nodes WHERE chat_id='$CHAT_ID' AND node_name='$TARGET_NODE' LIMIT 1;")
                    AGENT_IP=$(echo "$AGENT_INFO" | cut -d'|' -f1)
                    AGENT_PORT=$(echo "$AGENT_INFO" | cut -d'|' -f2)

                    if [ -n "$AGENT_IP" ] && [ -n "$AGENT_PORT" ]; then
                        send_msg "$CHAT_ID" "⏳ 正在向 \`$TARGET_NODE\` ($AGENT_IP) 下发 [$ACTION_TYPE] 指令，请稍候..."
                        
                        # 向 Agent 的开放端口发送动态 Webhook 唤醒指令 (如 trigger_run, trigger_log)
                        RESPONSE=$(curl -s -m 5 "http://${AGENT_IP}:${AGENT_PORT}/trigger_${ACTION_TYPE}" || echo "FAILED")
                        
                        if [ "$RESPONSE" == "FAILED" ]; then
                            send_msg "$CHAT_ID" "❌ 指令下发超时或失败！请检查节点公网 IP 或防火墙端口 ($AGENT_PORT) 是否放行。"
                        else
                            # 只有 run 指令需要主控单独回复确认，log 和 report 会由 Agent 直接将内容发到你的 TG
                            if [ "$ACTION_TYPE" == "run" ]; then
                                send_msg "$CHAT_ID" "✅ 节点 \`$TARGET_NODE\` 回应: 指令已接收，伪装程序启动。"
                            fi
                        fi
                    else
                        send_msg "$CHAT_ID" "❌ 数据库中未找到该节点的通讯地址。"
                    fi
                    ;;
            esac
        done
    fi
    sleep 1
done