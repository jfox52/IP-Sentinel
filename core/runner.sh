#!/bin/bash

# ==========================================================
# 脚本名称: runner.sh (IP-Sentinel 主控调度引擎)
# 核心功能: 防并发随机延迟启动、加载本地固化配置、调度业务模块
# ==========================================================

INSTALL_DIR="/opt/ip_sentinel"
CONFIG_FILE="${INSTALL_DIR}/config.conf"

# 1. 检查并加载本地冷数据配置
if [ ! -f "$CONFIG_FILE" ]; then
    echo "配置文件丢失，请重新运行 install.sh"
    exit 1
fi
source "$CONFIG_FILE"

# 2. 全局日志写入函数 (导出给子进程共享使用)
log() {
    local module=$1
    local level=$2
    local msg=$3
    # 保证日志目录存在
    mkdir -p "${INSTALL_DIR}/logs"
    printf "[$(date '+%Y-%m-%d %H:%M:%S')] [%-5s] [%-7s] [%s] %s\n" "$level" "$module" "$REGION_CODE" "$msg" >> "$LOG_FILE"
}
export -f log
export CONFIG_FILE INSTALL_DIR

# 3. 防僵尸网络特征 (Cron Jitter) - 核心隐蔽逻辑
# 【核心升级】配合每 30 分钟的调度周期，将随机休眠控制在 0 到 180 秒 (3分钟) 内，彻底打散全球并发请求
JITTER_TIME=$((RANDOM % 180))
log "SYSTEM" "INFO" "主控引擎被 Cron 唤醒，进入防并发随机休眠状态: ${JITTER_TIME} 秒..."
sleep $JITTER_TIME

# 4. 唤醒并调度业务模块
log "SYSTEM" "INFO" "休眠结束，开始执行养护任务..."

# 调度 Google 模块
if [ -x "${INSTALL_DIR}/core/mod_google.sh" ]; then
    log "SYSTEM" "INFO" "加载子模块: Google 业务模拟"
    # 核心降耗逻辑：使用 nice -n 19 赋予进程最低 CPU 优先级，绝不抢占 VPS 正常业务的资源
    nice -n 19 bash "${INSTALL_DIR}/core/mod_google.sh"
else
    log "SYSTEM" "ERROR" "未找到可执行的 Google 模块"
fi

log "SYSTEM" "INFO" "本轮所有模块调度完毕，哨兵继续隐蔽待命。"