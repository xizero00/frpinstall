#!/usr/bin/env bash
#
# frp-manage 端到端自测
#
# 本地拉起：
#   1. frps（真实二进制 + 测试配置）
#   2. 一个本地 HTTP 服务 + frpc 隧道（让 frps 有真实客户端/代理数据）
#   3. frp-manage 面板
#
# 然后逐项验证：页面、登录、错误密码锁定、锁定恢复、会话、CSRF、
# frps v2 API 反代、prune 清理、frpc 配置生成器、审计日志。
#
# 注意：服务控制项会把 FRPS_SERVICE_NAME 固定为不存在的隔离单元名，
# 只验证“结构化失败”，不会重启本机真实的 frps systemd 服务。
#
# 用法：
#   ./run_selftest.sh
#   FRPS_BIN=/path/to/frps FRPC_BIN=/path/to/frpc ./run_selftest.sh
#
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="${SELFTEST_DIR:-$(mktemp -d /tmp/frpman_selftest.XXXXXX)}"

FRPS_BIN="${FRPS_BIN:-/usr/local/bin/frps}"
FRPC_BIN="${FRPC_BIN:-/usr/local/bin/frpc}"
PY="${PYTHON:-python3}"

# 端口（避开常用端口，冲突可覆盖）
FRPS_BIND="${SELFTEST_FRPS_BIND:-17600}"
FRPS_DASH="${SELFTEST_FRPS_DASH:-17601}"
LOCAL_HTTP="${SELFTEST_LOCAL_HTTP:-18680}"
REMOTE_TCP="${SELFTEST_REMOTE_TCP:-18681}"
PANEL_PORT="${SELFTEST_PANEL_PORT:-17650}"

DASH_USER="selftest-admin"
DASH_PASS="selftest-pass-456"
TOKEN="selftest-token-123"
BASE="http://127.0.0.1:${PANEL_PORT}"
JAR="${WORK}/cookies.txt"

PASS=0
FAIL=0
PIDS=()

log() { printf '[selftest] %s\n' "$*"; }
fail() { FAIL=$((FAIL + 1)); log "FAIL: $*"; }
ok() { PASS=$((PASS + 1)); log "ok:   $*"; }

cleanup() {
    for pid in "${PIDS[@]:-}"; do
        kill "$pid" 2>/dev/null || true
    done
    sleep 0.3
    for pid in "${PIDS[@]:-}"; do
        kill -9 "$pid" 2>/dev/null || true
    done
    if [ "${FAIL:-0}" -eq 0 ] && [ "${KEEP_WORK:-0}" != "1" ]; then
        rm -rf "$WORK"
    else
        log "工作目录保留用于排查: $WORK"
    fi
}
trap cleanup EXIT

json_get() {
    # json_get <file> <dot.path>
    "$PY" - "$1" "$2" <<'PY'
import json, sys
def get(d, path):
    for k in path.split("."):
        if isinstance(d, list):
            try:
                d = d[int(k)]
            except (ValueError, IndexError):
                return ""
        elif isinstance(d, dict) and k in d:
            d = d[k]
        else:
            return ""
    if d is None:
        return ""
    return d
print(get(json.load(open(sys.argv[1])), sys.argv[2]))
PY
}

wait_url() {
    # wait_url <url> <timeout>
    local url="$1" timeout="${2:-10}" i
    for i in $(seq 1 $((timeout * 2))); do
        if curl -fsS --connect-timeout 1 --max-time 2 "$url" >/dev/null 2>&1; then
            return 0
        fi
        sleep 0.5
    done
    return 1
}

mkdir -p "$WORK/state"

# ---------- 1. 启动 frps ----------
cat > "$WORK/frps.toml" <<EOF
bindPort = ${FRPS_BIND}

auth.method = "token"
auth.token = "${TOKEN}"

webServer.addr = "127.0.0.1"
webServer.port = ${FRPS_DASH}
webServer.user = "${DASH_USER}"
webServer.password = "${DASH_PASS}"
EOF

"$FRPS_BIN" -c "$WORK/frps.toml" >"$WORK/frps.log" 2>&1 &
PIDS+=("$!")
if ! wait_url "http://127.0.0.1:${FRPS_DASH}/healthz" 10; then
    log "frps 启动失败，日志："
    tail -n 20 "$WORK/frps.log"
    exit 1
fi
log "frps 已启动 (bind ${FRPS_BIND} / dashboard ${FRPS_DASH})"

# ---------- 2. 本地 HTTP 服务 + frpc 隧道 ----------
"$PY" -m http.server "$LOCAL_HTTP" --bind 127.0.0.1 \
    --directory "$WORK" >"$WORK/http.log" 2>&1 &
PIDS+=("$!")

cat > "$WORK/frpc.toml" <<EOF
serverAddr = "127.0.0.1"
serverPort = ${FRPS_BIND}
user = "selftest"

auth.method = "token"
auth.token = "${TOKEN}"

[[proxies]]
name = "web"
type = "tcp"
localIP = "127.0.0.1"
localPort = ${LOCAL_HTTP}
remotePort = ${REMOTE_TCP}
EOF

"$FRPC_BIN" -c "$WORK/frpc.toml" >"$WORK/frpc.log" 2>&1 &
PIDS+=("$!")

# 等 frps 上出现 selftest 客户端和代理
proxy_seen=""
for _ in $(seq 1 30); do
    body="$(curl -fsS -u "${DASH_USER}:${DASH_PASS}" \
        "http://127.0.0.1:${FRPS_DASH}/api/v2/proxies?pageSize=50" 2>/dev/null || true)"
    printf '%s' "$body" > "$WORK/proxies_raw.json"
    PROXY_NAME="$("$PY" - "$WORK/proxies_raw.json" <<'PY'
import json, sys
try:
    data = json.load(open(sys.argv[1]))
except Exception:
    data = {}
items = (data.get("data") or data).get("items") or []
name = next(
    (x["name"] for x in items if x.get("name") == "web" or x.get("name", "").endswith(".web")),
    "",
)
print(name)
PY
)"
    if [ -n "$PROXY_NAME" ]; then
        proxy_seen=1
        break
    fi
    sleep 0.5
done
if [ -z "$proxy_seen" ]; then
    log "frpc 代理未出现在 frps 上，日志："
    tail -n 20 "$WORK/frpc.log"
    exit 1
fi
log "frpc 隧道已注册"
log "frps 上的代理名: ${PROXY_NAME}"

# ---------- 3. 启动面板 ----------
cat > "$WORK/manage.conf" <<EOF
PANEL_LISTEN_ADDR=127.0.0.1
PANEL_LISTEN_PORT=${PANEL_PORT}
FRPS_CONFIG_FILE=${WORK}/frps.toml
FRPS_SERVICE_NAME=__frpman_selftest__
STATE_DIR=${WORK}/state
LOGIN_MAX_FAILURES=3
LOGIN_LOCKOUT_MINUTES=0.1
LOGIN_FAILURE_WINDOW_MINUTES=0.5
LOGIN_DELAY_SECONDS=0.2
SESSION_TTL_HOURS=1
ENABLE_SERVICE_CONTROL=true
EOF

(cd "$ROOT" && nohup "$PY" -B manage.py serve --conf "$WORK/manage.conf" \
    >"$WORK/panel.log" 2>&1 & echo $! > "$WORK/panel.pid")
PIDS+=("$(cat "$WORK/panel.pid")")
if ! wait_url "${BASE}/healthz" 15; then
    log "面板启动失败，日志："
    tail -n 30 "$WORK/panel.log"
    exit 1
fi
log "面板已启动 (${BASE})"

# ---------- 4. 静态页面 ----------
code="$(curl -s -o "$WORK/index.html" -w '%{http_code}' "${BASE}/")"
if [ "$code" = "200" ] && grep -q "frps 管理面板" "$WORK/index.html"; then
    ok "首页可访问且包含标题"
else
    fail "首页异常 (HTTP ${code})"
fi

code="$(curl -s -o "$WORK/app.js" -w '%{http_code}' "${BASE}/static/app.js")"
if [ "$code" = "200" ] && grep -q "frpsApi" "$WORK/app.js"; then
    ok "前端脚本可访问"
else
    fail "前端脚本异常 (HTTP ${code})"
fi

# ---------- 5. 未登录禁止访问 API ----------
code="$(curl -s -o "$WORK/noauth.json" -w '%{http_code}' \
    "${BASE}/api/frps/v2/system/info")"
if [ "$code" = "401" ]; then
    ok "未登录访问 frps API 返回 401"
else
    fail "未登录访问未拦截 (HTTP ${code})"
fi

# ---------- 6. 错误密码触发锁定 ----------
c1="$(curl -s -o "$WORK/f1.json" -w '%{http_code}' -X POST \
    -H 'Content-Type: application/json' \
    -d "{\"username\":\"${DASH_USER}\",\"password\":\"wrong-1\"}" \
    "${BASE}/api/login")"
c2="$(curl -s -o "$WORK/f2.json" -w '%{http_code}' -X POST \
    -H 'Content-Type: application/json' \
    -d "{\"username\":\"${DASH_USER}\",\"password\":\"wrong-2\"}" \
    "${BASE}/api/login")"
c3="$(curl -s -o "$WORK/f3.json" -w '%{http_code}' -X POST \
    -H 'Content-Type: application/json' \
    -d "{\"username\":\"${DASH_USER}\",\"password\":\"wrong-3\"}" \
    "${BASE}/api/login")"
if [ "$c1" = "401" ] && [ "$c2" = "401" ] && [ "$c3" = "429" ]; then
    ok "错误密码 3 次后触发锁定 (401/401/429)"
else
    fail "锁定流程异常 (HTTP ${c1}/${c2}/${c3})"
fi

# 锁定期内即使密码正确也应拒绝
c4="$(curl -s -o "$WORK/f4.json" -w '%{http_code}' -X POST \
    -H 'Content-Type: application/json' \
    -d "{\"username\":\"${DASH_USER}\",\"password\":\"${DASH_PASS}\"}" \
    "${BASE}/api/login")"
if [ "$c4" = "429" ]; then
    ok "锁定期内正确密码也被拒绝"
else
    fail "锁定期内未被拒绝 (HTTP ${c4})"
fi

# ---------- 6.5. 并发爆破也应被限制（换一个账号避免影响上面用例） ----------
race_pids=""
for i in 1 2 3 4 5 6 7 8; do
    curl -s -o "$WORK/race_${i}.json" -w '%{http_code}\n' -X POST \
        -H 'Content-Type: application/json' \
        -d "{\"username\":\"brute-race\",\"password\":\"wrong-${i}\"}" \
        "${BASE}/api/login" >"$WORK/race_${i}.code" &
    race_pids="$race_pids $!"
done
for race_pid in $race_pids; do
    wait "$race_pid"
done
race_allowed="$(cat "$WORK"/race_*.code | grep -c '^401$' || true)"
race_blocked="$(cat "$WORK"/race_*.code | grep -c '^429$' || true)"
race_recorded="$("$PY" - "$WORK/state/manage.db" <<'PY'
import sqlite3, sys
con = sqlite3.connect(sys.argv[1])
row = con.execute(
    "SELECT COUNT(*) FROM login_attempts WHERE username='brute-race' AND success=0"
).fetchone()
print(row[0])
PY
)"
if [ "$race_recorded" = "3" ] && [ "$race_blocked" -ge 5 ]; then
    ok "并发爆破数据库仅记录 3 次失败，HTTP 429 拒绝 ${race_blocked} 个请求（未出现全部放行）"
else
    fail "并发爆破未被正确限制 (recorded=${race_recorded}, 401=${race_allowed}, 429=${race_blocked})"
fi

# ---------- 7. 等待锁定过期后正常登录 ----------
sleep 8
code="$(curl -s -c "$JAR" -o "$WORK/login.json" -w '%{http_code}' -X POST \
    -H 'Content-Type: application/json' \
    -d "{\"username\":\"${DASH_USER}\",\"password\":\"${DASH_PASS}\"}" \
    "${BASE}/api/login")"
user="$(json_get "$WORK/login.json" username)"
if [ "$code" = "200" ] && [ "$user" = "$DASH_USER" ]; then
    ok "锁定过期后登录成功 (HTTP 200, user=${user})"
else
    fail "登录失败 (HTTP ${code})"
fi

code="$(curl -s -b "$JAR" -o "$WORK/me.json" -w '%{http_code}' "${BASE}/api/me")"
csrf="$(json_get "$WORK/me.json" csrf)"
if [ "$code" = "200" ] && [ -n "$csrf" ]; then
    ok "会话有效并取得 CSRF token"
else
    fail "会话接口异常 (HTTP ${code})"
fi

# ---------- 8. frps API 反代 ----------
code="$(curl -s -b "$JAR" -o "$WORK/sys.json" -w '%{http_code}' \
    "${BASE}/api/frps/v2/system/info")"
version="$(json_get "$WORK/sys.json" data.version)"
bind_port="$(json_get "$WORK/sys.json" data.config.bindPort)"
if [ "$code" = "200" ] && [ "$version" = "0.71.0" ] && [ "$bind_port" = "$FRPS_BIND" ]; then
    ok "frps system/info 反代正常 (v${version}, bind ${bind_port})"
else
    fail "system/info 异常 (HTTP ${code}, v=${version}, bind=${bind_port})"
fi

code="$(curl -s -b "$JAR" -o "$WORK/clients.json" -w '%{http_code}' \
    "${BASE}/api/frps/v2/clients?pageSize=50")"
total="$(json_get "$WORK/clients.json" data.total)"
if [ "$code" = "200" ] && [ "${total:-0}" -ge 1 ]; then
    ok "客户端列表反代正常 (total=${total})"
else
    fail "客户端列表异常 (HTTP ${code}, total=${total})"
fi

# 客户端详情字段（前端点击行后依赖 status.curConns / status.proxyCount）
client_key="$(json_get "$WORK/clients.json" data.items.0.key)"
code="$(curl -s -b "$JAR" -o "$WORK/cdetail.json" -w '%{http_code}' \
    "${BASE}/api/frps/v2/clients/${client_key}")"
c_cur="$(json_get "$WORK/cdetail.json" data.status.curConns)"
c_proxies="$(json_get "$WORK/cdetail.json" data.status.proxyCount)"
c_online="$(json_get "$WORK/cdetail.json" data.online)"
if [ "$code" = "200" ] && [ "$c_cur" != "" ] && [ "$c_proxies" != "" ]; then
    ok "客户端详情反代正常 (key=${client_key}, curConns=${c_cur}, proxyCount=${c_proxies})"
else
    fail "客户端详情异常 (HTTP ${code}, online=${c_online}, cur=${c_cur}, px=${c_proxies})"
fi

code="$(curl -s -b "$JAR" -o "$WORK/proxies.json" -w '%{http_code}' \
    "${BASE}/api/frps/v2/proxies?pageSize=50")"
ptotal="$(json_get "$WORK/proxies.json" data.total)"
if [ "$code" = "200" ] && [ "${ptotal:-0}" -ge 1 ]; then
    ok "代理列表反代正常 (total=${ptotal})"
else
    fail "代理列表异常 (HTTP ${code}, total=${ptotal})"
fi

code="$(curl -s -b "$JAR" -o "$WORK/pxdetail.json" -w '%{http_code}' \
    "${BASE}/api/frps/v2/proxies/${PROXY_NAME}")"
pname="$(json_get "$WORK/pxdetail.json" data.name)"
if [ "$code" = "200" ] && [ "$pname" = "$PROXY_NAME" ]; then
    ok "代理详情反代正常 (name=${pname})"
else
    fail "代理详情异常 (HTTP ${code}, name=${pname})"
fi

code="$(curl -s -b "$JAR" -o "$WORK/traffic.json" -w '%{http_code}' \
    "${BASE}/api/frps/v2/proxies/${PROXY_NAME}/traffic?days=7")"
if [ "$code" = "200" ]; then
    ok "代理流量接口反代正常"
else
    fail "代理流量接口异常 (HTTP ${code})"
fi

# 代理详情中的字段应能被前端使用（spec.type / status.phase / status.todayTraffic*）
code="$(curl -s -b "$JAR" -o "$WORK/pxdetail2.json" -w '%{http_code}' \
    "${BASE}/api/frps/v2/proxies/${PROXY_NAME}")"
spec_type="$(json_get "$WORK/pxdetail2.json" data.spec.type)"
px_phase="$(json_get "$WORK/pxdetail2.json" data.status.phase)"
if [ "$code" = "200" ] && [ -n "$spec_type" ] && [ -n "$px_phase" ]; then
    ok "代理详情包含 spec.type=${spec_type} / status.phase=${px_phase}"
else
    fail "代理详情字段异常 (type=${spec_type}, phase=${px_phase})"
fi

# ---------- 8.1. 用户统计 v2 API（前端“用户”页依赖） ----------
code="$(curl -s -b "$JAR" -o "$WORK/users.json" -w '%{http_code}' \
    "${BASE}/api/frps/v2/users?pageSize=50")"
utotal="$(json_get "$WORK/users.json" data.total)"
u_first_user="$(json_get "$WORK/users.json" data.items.0.user)"
if [ "$code" = "200" ] && [ "${utotal:-0}" -ge 1 ] && [ -n "$u_first_user" ]; then
    ok "用户统计反代正常 (total=${utotal}, user=${u_first_user})"
else
    fail "用户统计异常 (HTTP ${code}, total=${utotal}, first=${u_first_user})"
fi

code="$(curl -s -b "$JAR" -o "$WORK/users_q.json" -w '%{http_code}' \
    "${BASE}/api/frps/v2/users?q=__no_such_user__&pageSize=50")"
uq_total="$(json_get "$WORK/users_q.json" data.total)"
if [ "$code" = "200" ] && [ "${uq_total:-1}" = "0" ]; then
    ok "用户按 q=__no_such_user__ 搜索过滤生效 (total=0)"
else
    fail "用户搜索过滤异常 (HTTP ${code}, total=${uq_total})"
fi

# ---------- 8.2. 总览依赖的 v2 status 字段 ----------
code="$(curl -s -b "$JAR" -o "$WORK/ovinfo.json" -w '%{http_code}' \
    "${BASE}/api/frps/v2/system/info")"
cur_conns="$(json_get "$WORK/ovinfo.json" data.status.curConns)"
client_counts="$(json_get "$WORK/ovinfo.json" data.status.clientCounts)"
if [ "$code" = "200" ] && [ "$cur_conns" != "" ] && [ "$client_counts" != "" ]; then
    ok "system/info 包含 status.curConns=${cur_conns} / clientCounts=${client_counts}"
else
    fail "system/info status 字段异常 (curConns=${cur_conns}, clientCounts=${client_counts})"
fi

# ---------- 8.3. v2 列表筛选/搜索参数（前端客户端/代理页依赖） ----------
code="$(curl -s -b "$JAR" -o "$WORK/px_filter_off.json" -w '%{http_code}' \
    "${BASE}/api/frps/v2/proxies?status=offline&pageSize=50")"
off_total="$(json_get "$WORK/px_filter_off.json" data.total)"
if [ "$code" = "200" ] && [ "${off_total:-1}" = "0" ]; then
    ok "代理按 status=offline 过滤生效 (total=0)"
else
    fail "代理 status 过滤异常 (HTTP ${code}, total=${off_total})"
fi

code="$(curl -s -b "$JAR" -o "$WORK/px_filter_type.json" -w '%{http_code}' \
    "${BASE}/api/frps/v2/proxies?type=udp&pageSize=50")"
type_total="$(json_get "$WORK/px_filter_type.json" data.total)"
if [ "$code" = "200" ] && [ "${type_total:-1}" = "0" ]; then
    ok "代理按 type=udp 过滤生效 (total=0)"
else
    fail "代理 type 过滤异常 (HTTP ${code}, total=${type_total})"
fi

code="$(curl -s -b "$JAR" -o "$WORK/px_filter_q.json" -w '%{http_code}' \
    "${BASE}/api/frps/v2/proxies?q=__no_such_proxy__&pageSize=50")"
q_total="$(json_get "$WORK/px_filter_q.json" data.total)"
if [ "$code" = "200" ] && [ "${q_total:-1}" = "0" ]; then
    ok "代理按 q=__no_such_proxy__ 搜索生效 (total=0)"
else
    fail "代理搜索过滤异常 (HTTP ${code}, total=${q_total})"
fi

code="$(curl -s -b "$JAR" -o "$WORK/cl_filter_q.json" -w '%{http_code}' \
    "${BASE}/api/frps/v2/clients?q=__no_such_client__&pageSize=50")"
cq_total="$(json_get "$WORK/cl_filter_q.json" data.total)"
if [ "$code" = "200" ] && [ "${cq_total:-1}" = "0" ]; then
    ok "客户端按 q 搜索过滤生效 (total=0)"
else
    fail "客户端搜索过滤异常 (HTTP ${code}, total=${cq_total})"
fi

# ---------- 9. CSRF 保护 ----------
code="$(curl -s -b "$JAR" -o "$WORK/nocsrf.json" -w '%{http_code}' -X POST \
    "${BASE}/api/frps/v2/system/prune?type=offline_proxies")"
if [ "$code" = "403" ]; then
    ok "缺少 CSRF 的写操作被拒绝 (403)"
else
    fail "CSRF 校验未生效 (HTTP ${code})"
fi

code="$(curl -s -b "$JAR" -o "$WORK/prune.json" -w '%{http_code}' -X POST \
    -H "X-CSRF-Token: ${csrf}" \
    "${BASE}/api/frps/v2/system/prune?type=offline_proxies")"
ptype="$(json_get "$WORK/prune.json" data.type)"
pcleared="$(json_get "$WORK/prune.json" data.cleared)"
ptotal="$(json_get "$WORK/prune.json" data.total)"
if [ "$code" = "200" ] && [ "$ptype" = "offline_proxies" ] \
    && [ "$pcleared" != "" ] && [ "$ptotal" != "" ]; then
    ok "prune 清理离线代理成功 (type=${ptype}, cleared=${pcleared}, total=${ptotal})"
else
    fail "prune 异常 (HTTP ${code}, type=${ptype}, cleared=${pcleared}, total=${ptotal})"
fi

# ---------- 10. frpc 配置生成器 ----------
code="$(curl -s -b "$JAR" -o "$WORK/genopts.json" -w '%{http_code}' \
    "${BASE}/api/frpc-template/options")"
if [ "$code" = "200" ] && grep -q "$TOKEN" "$WORK/genopts.json"; then
    ok "生成器默认值接口正常（带出 token）"
else
    fail "生成器默认值异常 (HTTP ${code})"
fi

code="$(curl -s -b "$JAR" -o "$WORK/render.json" -w '%{http_code}' -X POST \
    -H 'Content-Type: application/json' \
    -H "X-CSRF-Token: ${csrf}" \
    -d "{\"serverAddr\":\"frps.example.com\",\"serverPort\":${FRPS_BIND},\"token\":\"${TOKEN}\",\"user\":\"alice\",\"proxies\":[{\"name\":\"ssh\",\"type\":\"tcp\",\"localIP\":\"127.0.0.1\",\"localPort\":22,\"remotePort\":${REMOTE_TCP},\"customDomains\":\"\",\"subdomain\":\"\"}]}" \
    "${BASE}/api/frpc-template/render")"
rendered="$(json_get "$WORK/render.json" text)"
r_ok="$(json_get "$WORK/render.json" ok)"
if [ "$code" = "200" ] && [ "$r_ok" = "True" ] \
    && printf '%s' "$rendered" | grep -q "frps.example.com" \
    && printf '%s' "$rendered" | grep -q '\[\[proxies\]\]'; then
    ok "frpc 配置渲染并校验通过"
else
    fail "生成器渲染异常 (HTTP ${code}, ok=${r_ok})"
fi

code="$(curl -s -b "$JAR" -o "$WORK/valid.json" -w '%{http_code}' -X POST \
    -H 'Content-Type: application/json' \
    -H "X-CSRF-Token: ${csrf}" \
    -d '{"text":"serverAddr = \"a\"\nserverPort = 7000\nauth.method = \"token\"\nauth.token = \"x\"\n"}' \
    "${BASE}/api/frpc-template/validate")"
v_ok="$(json_get "$WORK/valid.json" ok)"
if [ "$code" = "200" ] && [ "$v_ok" = "True" ]; then
    ok "frpc 配置文本校验接口正常"
else
    fail "校验接口异常 (HTTP ${code}, ok=${v_ok})"
fi

# ---------- 11. 运维状态与审计 ----------
code="$(curl -s -b "$JAR" -o "$WORK/svc.json" -w '%{http_code}' \
    "${BASE}/api/service/status")"
reachable="$(json_get "$WORK/svc.json" frpsApiReachable)"
if [ "$code" = "200" ] && [ "$reachable" = "True" ]; then
    ok "运维状态显示 frps API 可达"
else
    fail "运维状态异常 (HTTP ${code}, reachable=${reachable})"
fi

code="$(curl -s -b "$JAR" -o "$WORK/audit.json" -w '%{http_code}' \
    "${BASE}/api/audit?limit=100")"
fail_count="$(grep -o 'login_failed' "$WORK/audit.json" | wc -l)"
if [ "$code" = "200" ] && [ "$fail_count" -ge 3 ]; then
    ok "审计日志记录了 ${fail_count} 条失败登录"
else
    fail "审计日志异常 (HTTP ${code}, failed=${fail_count})"
fi

# ---------- 12. 服务控制接口 ----------
# FRPS_SERVICE_NAME 固定为不存在的隔离单元名，确保自测只验证
# “结构化失败”，绝不会误操作测试机上真实存在的 frps systemd 服务。
code="$(curl -s -b "$JAR" -o "$WORK/svcact.json" -w '%{http_code}' -X POST \
    -H "X-CSRF-Token: ${csrf}" -H 'Content-Type: application/json' -d '{}' \
    "${BASE}/api/service/restart")"
svc_detail="$(json_get "$WORK/svcact.json" detail)"
if [ "$code" = "403" ] && [ -n "$svc_detail" ]; then
    ok "服务控制对不存在的服务返回结构化错误 (HTTP 403)"
else
    fail "服务控制接口异常 (HTTP ${code}, detail=${svc_detail})"
fi

# ---------- 汇总 ----------
log "==========================================="
log "通过 ${PASS} 项 / 失败 ${FAIL} 项"
if [ "$FAIL" -gt 0 ]; then
    log "测试失败，工作目录: $WORK"
    exit 1
fi
log "全部通过"
