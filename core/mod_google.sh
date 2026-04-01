#!/bin/bash

# ==========================================================
# 脚本名称: mod_google.sh (Google 业务逻辑模块)
# 核心功能: 执行坐标微抖动、模拟真实阅读时长、会话行为拉伸
# ==========================================================

MODULE_NAME="Google"
CONFIG_FILE="/opt/ip_sentinel/config.conf"

# 1. 加载冷数据配置
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
else
    echo "配置文件丢失！退出执行。"
    exit 1
fi

# 容错机制：如果父进程没有传递 log 函数，则本地定义一个作为 fallback
if ! type log >/dev/null 2>&1; then
    log() {
        mkdir -p "${INSTALL_DIR}/logs"
        printf "[$(date '+%Y-%m-%d %H:%M:%S')] [%-5s] [%-7s] [%s] %s\n" "$2" "$1" "$REGION_CODE" "$3" >> "${INSTALL_DIR}/logs/sentinel.log"
    }
fi

log "$MODULE_NAME" "START" "========== 唤醒网络模拟器 [区域: $REGION_NAME] =========="

# 2. 动态加载热数据 (设备指纹池 和 专属搜索词库)
UA_FILE="${INSTALL_DIR}/data/user_agents.txt"
KW_FILE="${INSTALL_DIR}/data/keywords/kw_${REGION_CODE}.txt"

if [ ! -f "$UA_FILE" ] || [ ! -f "$KW_FILE" ]; then
    log "$MODULE_NAME" "ERROR" "热数据缺失，请检查 data 目录。放弃本次执行。"
    exit 1
fi

# 将文本按行读取到数组中 (并自动过滤空行)
mapfile -t UA_POOL < <(grep -v '^$' "$UA_FILE")
mapfile -t KEYWORDS < <(grep -v '^$' "$KW_FILE")

# --- [工具函数] ---
get_random_coord() {
    local base=$1
    local range=$2 
    local offset=$(awk "BEGIN {print ( ( ($RANDOM % ($range * 2)) - $range ) / 10000 )}")
    awk "BEGIN {print ($base + $offset)}"
}

# --- [环境初始化] ---
# 获取当前出口 IP 仅用于日志记录
CURRENT_V4=$(curl -4 -m 10 -s https://api.ip.sb/ip || echo "获取IP失败")

# 会话锁定：单次执行内使用固定的浏览器指纹
SESSION_UA=${UA_POOL[$RANDOM % ${#UA_POOL[@]}]}
# 位置锁定：在基准点(比如东京新宿)附近 3 公里内随机生成本次上网的“固定咖啡馆”坐标
SESSION_BASE_LAT=$(get_random_coord $BASE_LAT 270)
SESSION_BASE_LON=$(get_random_coord $BASE_LON 270)

# 【核心升级】随机决定本次上网深度 (6 - 10 个复合动作，配合高频长效拉伸)
TOTAL_ACTIONS=$((6 + RANDOM % 5))

log "$MODULE_NAME" "INFO " "当前出网 IP: $CURRENT_V4"
log "$MODULE_NAME" "INFO " "设备指纹锁定: ${SESSION_UA:0:45}..."
log "$MODULE_NAME" "INFO " "虚拟驻留坐标: $SESSION_BASE_LAT, $SESSION_BASE_LON"

# --- [行为循环模拟] ---
for ((i=1; i<=TOTAL_ACTIONS; i++)); do
    # 模拟真实移动设备拿在手里时的 GPS 信号微抖动 (范围约 10 米)
    ACTION_LAT=$(get_random_coord $SESSION_BASE_LAT 1)
    ACTION_LON=$(get_random_coord $SESSION_BASE_LON 1)
    
    # 随机抽取一个符合当地特征的热点搜索词
    RAND_KEY=${KEYWORDS[$RANDOM % ${#KEYWORDS[@]}]}
    ENCODED_KEY=$(echo "$RAND_KEY" | jq -sRr @uri)
    
    # 随机选择一种上网行为
    ACTION_TYPE=$((1 + RANDOM % 4))
    
    case $ACTION_TYPE in
        1) # 搜索行为
            CODE=$(curl -4 -m 15 -s -L -o /dev/null -w "%{http_code}" -A "$SESSION_UA" \
                 "https://www.google.com/search?q=${ENCODED_KEY}&${LANG_PARAMS}")
            ;;
        2) # 浏览本土新闻
            CODE=$(curl -4 -m 15 -s -L -o /dev/null -w "%{http_code}" -A "$SESSION_UA" \
                 "https://news.google.com/home?${LANG_PARAMS}")
            ;;
        3) # 地图坐标查询
            CODE=$(curl -4 -m 15 -s -o /dev/null -w "%{http_code}" -A "$SESSION_UA" \
                 "https://www.google.com/maps/search/${ENCODED_KEY}/@${ACTION_LAT},${ACTION_LON},17z?${LANG_PARAMS}")
            ;;
        4) # 触发移动端系统底层位置检测像素
            CODE=$(curl -4 -m 10 -s -o /dev/null -w "%{http_code}" -A "$SESSION_UA" \
                 "https://connectivitycheck.gstatic.com/generate_204")
            ;;
    esac
    
    log "$MODULE_NAME" "EXEC " "动作[$i/$TOTAL_ACTIONS]完成 | HTTP状态: $CODE | 抖动坐标: $ACTION_LAT, $ACTION_LON"
    
    # 【核心升级】行为拉伸：每次动作后强制休眠 90 - 150 秒
    # 结合动作总数，总耗时将稳定在 10 分钟 到 25 分钟之间
    if [ $i -lt $TOTAL_ACTIONS ]; then
        SLEEP_TIME=$((90 + RANDOM % 61))
        log "$MODULE_NAME" "WAIT " "阅读当前页面内容，模拟停留 $SLEEP_TIME 秒..."
        sleep $SLEEP_TIME
    fi
done

# --- [结果纠偏自检] ---
# 去掉所有语言参数，进行一次最干净的直连测试
FINAL_URL=$(curl -4 -m 15 -s -L -o /dev/null -w "%{url_effective}" https://www.google.com)

if [[ "$FINAL_URL" == *"$VALID_URL_SUFFIX"* ]]; then
    STATUS="✅ 目标区域达成 ($VALID_URL_SUFFIX)"
elif [[ "$FINAL_URL" == *"google.com.hk"* ]]; then
    STATUS="❌ 判定为送中区 (CN/HK)"
else
    STATUS="⚠️ 其他分站跳板 ($FINAL_URL)"
fi

log "$MODULE_NAME" "SCORE" "自检结论: $STATUS"
log "$MODULE_NAME" "END  " "========== 会话结束，释放进程 =========="