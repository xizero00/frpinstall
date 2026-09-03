#!/usr/bin/env bash
#
# frpdash 一键管理脚本
#
# 用法：
#   ./frpdash-manage.sh start    启动面板（后台运行）
#   ./frpdash-manage.sh stop     停止面板
#   ./frpdash-manage.sh restart  重启面板
#   ./frpdash-manage.sh status   查看运行状态
#   ./frpdash-manage.sh          查看帮助
#
# 环境变量（可选）：
#   MANAGE_CONF       manage.conf 路径
#   MANAGE_HOST       监听地址（默认 127.0.0.1）
#   MANAGE_PORT       监听端口（默认 7501）
#   MANAGE_STATE_DIR  会话/审计数据库目录
#
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON:-python3}"
CONF_FILE="${MANAGE_CONF:-${SCRIPT_DIR}/manage.conf}"
HOST="${MANAGE_HOST:-127.0.0.1}"
PORT="${MANAGE_PORT:-7501}"

RUN_DIR="${SCRIPT_DIR}/.run"
PID_FILE="${RUN_DIR}/panel.pid"
LOG_FILE="${RUN_DIR}/panel.log"

log() {
    printf '[frp-manage] %s\n' "$*"
}

die() {
    echo "Error: $*" >&2
    exit 1
}

require_python() {
    command -v "$PYTHON_BIN" >/dev/null 2>&1 || die "未找到 $PYTHON_BIN，请先安装 Python 3.11+"
}

require_conf() {
    if [ ! -f "$CONF_FILE" ]; then
        if [ -f "${SCRIPT_DIR}/manage.conf.example" ]; then
            cp "${SCRIPT_DIR}/manage.conf.example" "$CONF_FILE"
            log "已从 manage.conf.example 生成 $CONF_FILE"
        else
            die "缺少配置文件 $CONF_FILE（可复制 manage.conf.example）"
        fi
    fi
}

read_pid() {
    if [ -f "$PID_FILE" ]; then
        cat "$PID_FILE"
    fi
}

is_running() {
    local pid
    pid="$(read_pid)"
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

health_check() {
    local url="http://127.0.0.1:${PORT}/healthz"
    if command -v curl >/dev/null 2>&1; then
        curl -fsS --connect-timeout 2 --max-time 3 "$url" >/dev/null 2>&1
    else
        "$PYTHON_BIN" -c "
import sys, urllib.request
try:
    urllib.request.urlopen('$url', timeout=3)
    sys.exit(0)
except Exception:
    sys.exit(1)
"
    fi
}

wait_healthy() {
    local i
    for i in $(seq 1 20); do
        if health_check; then
            return 0
        fi
        sleep 0.5
    done
    return 1
}

do_start() {
    require_python
    require_conf
    mkdir -p "$RUN_DIR"

    if is_running; then
        log "面板已在运行 (PID $(read_pid))，地址 http://${HOST}:${PORT}"
        log "如要重启请执行 ./frpdash-manage.sh restart"
        return 0
    fi

    # 清理可能残留的旧 PID 文件
    rm -f "$PID_FILE"

    log "正在启动 frp-manage (${HOST}:${PORT})…"
    local cmd_args=(serve --conf "$CONF_FILE" --host "$HOST" --port "$PORT")
    if [ -n "${MANAGE_STATE_DIR:-}" ]; then
        cmd_args+=(--state-dir "$MANAGE_STATE_DIR")
    fi

    nohup "$PYTHON_BIN" "${SCRIPT_DIR}/manage.py" "${cmd_args[@]}" \
        >>"$LOG_FILE" 2>&1 &
    local pid=$!
    echo "$pid" > "$PID_FILE"

    if wait_healthy; then
        log "启动成功 (PID $pid)"
        log "访问地址: http://${HOST}:${PORT}  使用 frps webServer 的用户名/密码登录"
        log "日志文件: $LOG_FILE"
    else
        log "启动失败，请查看日志："
        tail -n 30 "$LOG_FILE" >&2
        kill "$pid" 2>/dev/null
        rm -f "$PID_FILE"
        return 1
    fi
}

do_stop() {
    local pid
    pid="$(read_pid)"
    if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
        log "面板没有在运行"
        rm -f "$PID_FILE"
        return 0
    fi
    log "正在停止面板 (PID $pid)…"
    kill "$pid" 2>/dev/null || true
    local i
    for i in $(seq 1 10); do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.3
    done
    if kill -0 "$pid" 2>/dev/null; then
        log "进程未在 3 秒内退出，发送 KILL"
        kill -9 "$pid" 2>/dev/null || true
    fi
    rm -f "$PID_FILE"
    log "已停止"
}

do_status() {
    local pid
    pid="$(read_pid)"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        log "运行中：PID $pid，地址 http://${HOST}:${PORT}"
        if health_check; then
            log "健康检查：通过"
        else
            log "健康检查：未通过（进程在但 HTTP 未响应，请查看 $LOG_FILE）"
        fi
    else
        log "未运行"
    fi
}

usage() {
    cat <<EOF
用法: $0 <命令>

命令:
  start     启动面板（后台运行）
  stop      停止面板
  restart   重启面板
  status    查看运行状态

环境变量:
  MANAGE_CONF       manage.conf 路径（默认 \$SCRIPT_DIR/manage.conf）
  MANAGE_HOST       监听地址（默认 127.0.0.1）
  MANAGE_PORT       监听端口（默认 7501）
  MANAGE_STATE_DIR  会话/审计数据库目录
EOF
}

case "${1:-}" in
    start)
        do_start
        ;;
    stop)
        do_stop
        ;;
    restart)
        do_stop
        do_start
        ;;
    status)
        do_status
        ;;
    help|-h|--help)
        usage
        ;;
    *)
        usage >&2
        exit 1
        ;;
esac
