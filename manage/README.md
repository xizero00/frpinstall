# frp-manage — frps 网页管理面板

frp-manage 是一个运行在 frps 服务器上的网页管理面板，用来**对接 frps 官方 dashboard API（v0.71+），实现对 frps 的完整监控与控制**。它替换掉直接暴露的 frps 自带 Dashboard，增加网页登录与暴力破解防护。

> 目录结构：本项目根目录为 `frpinstall`，本面板代码位于 `manage/`。

## 它能做什么

### 监控（全部来自 frps API）

| 页面 | 内容 |
| --- | --- |
| 总览 | frps 版本、绑定端口、总入/出流量、当前连接数、各类型代理数量、vhost/QUIC/KCP 等配置 |
| 客户端 | 在线/离线筛选、搜索、分页；点击查看详情（Hostname、IP、frp 版本、连接时间等） |
| 代理 | 按 TCP/UDP/HTTP/HTTPS/STCP 等类型筛选；搜索、分页；详情含配置与 7 天流量 |
| 用户 | 每个 `user`（frpc 代理名前缀）下挂载的客户端与代理数量 |

### 控制

- **清理离线代理**：`POST /api/v2/system/prune?type=offline_proxies`（frps API 原生运维接口）
- **frps 进程控制**：查看 PID / systemd 状态，一键启动、停止、重启 frps 服务（面板以 root 或无密码 sudo 运行 systemd 时可用）
- **frpc 配置生成器**：网页表单生成 `frpc_<user>.toml`（填好服务器、token、user 前缀和代理列表），实时预览 / 校验 / 下载，方便批量给其他人部署 frpc

> 说明：frps 服务端 API 本身是“监控 + 清理”性质，没有创建/删除隧道的接口。新增/删除隧道属于 frpc 端能力（frpc ≥ 0.68 的 admin API + store），如需在网页上增删隧道，可以再扩展 frpc admin 模块。

## 登录方式

**不额外维护账号。** 登录页输入的用户名/密码，就是 frps 配置文件里的：

```toml
[frps] 下的
webServer.user = "admin"
webServer.password = "xxxxxxxx"
```

面板收到登录请求后，会用这对账号去请求 `frps API`（`/api/v2/system/info`）做真实校验，通过才发会话 Cookie。

## 暴力破解防护

- 同一用户名 + IP 连续失败 `LOGIN_MAX_FAILURES` 次（默认 5）后锁定 `LOGIN_LOCKOUT_MINUTES` 分钟（默认 15）
- 同一 IP 无论换多少用户名，累计失败超过上限也会锁（默认上限 = 单账号上限 × 3）
- 每次失败响应有固定延时（默认 0.5 秒）
- 锁定返回 HTTP 429 + `Retry-After`，网页会提示剩余锁定时间
- 成功/失败/锁定/服务操作全部写入审计日志（SQLite），运维页可查
- 会话只存随机 token（HttpOnly / SameSite=Lax Cookie），frps 密码只留在面板进程内存里，不落盘

## 环境要求

- Python 3.11+（只用标准库，无需 pip 安装任何依赖）
- frps 0.71.0+ 且已开启 `webServer`（本仓库安装脚本默认 7500 端口）
- frps 配置文件可读（自动读取 `webServer.*`），或手动在 `manage.conf` 指定 `FRPS_API_URL/USER/PASSWORD`

## 快速开始

```bash
cd manage
cp manage.conf.example manage.conf
# 按需编辑 manage.conf（frps 配置路径、面板端口、防爆破参数等）

./frpdash-manage.sh start     # 一键后台启动
./frpdash-manage.sh status    # 查看状态
./frpdash-manage.sh restart   # 重启
./frpdash-manage.sh stop      # 停止
./frpdash-manage.sh           # 查看帮助
```

浏览器打开 `http://127.0.0.1:7501`，用 **frps webServer 的用户名/密码**登录。

也可以前台运行：

```bash
python3 manage.py serve --conf manage.conf
```

## 配置项（manage.conf）

| 配置 | 默认 | 说明 |
| --- | --- | --- |
| `PANEL_LISTEN_ADDR` | `127.0.0.1` | 面板监听地址，公网访问请在前面挂 Nginx |
| `PANEL_LISTEN_PORT` | `7501` | 面板端口 |
| `FRPS_CONFIG_FILE` | 自动 | frps 安装后的 TOML 配置（`/etc/frp/frps_*.toml`），用于推导 webServer API 地址与账号 |
| `FRPS_API_URL / _USER / _PASSWORD` | 空 | 无法读取 frps 配置时手动指定 |
| `FRPS_SERVICE_NAME` | 自动 | frps 的 systemd 服务名（如 `frps_root`） |
| `LOGIN_MAX_FAILURES` | `5` | 连续失败锁定阈值 |
| `LOGIN_LOCKOUT_MINUTES` | `15` | 锁定分钟数 |
| `LOGIN_FAILURE_WINDOW_MINUTES` | `15` | 失败计数窗口 |
| `LOGIN_DELAY_SECONDS` | `0.5` | 失败响应延时 |
| `SESSION_TTL_HOURS` | `12` | 会话有效期 |
| `STATE_DIR` | `/var/lib/frp-manage` | 会话/审计 SQLite 目录（无写权限自动回退 `manage/.state`） |
| `ENABLE_SERVICE_CONTROL` | `true` | 是否开放 frps 服务启停/重启 |
| `FRP_TEMPLATE_FILE` | 自动 | frpc 生成器的默认值来源（`../frp_template.toml`） |
| `FRP_GEN_VERSION/ARCH` | `0.71.0` / `linux_amd64` | 生成器部署说明中提示的 frp 版本 |

## 对接的 frps API 清单

面板内部通过 Basic Auth（frps webServer 账号）访问，网页侧经 `/api/frps/*` 反代（登录会话 + CSRF 保护）：

- `GET /api/v2/system/info` — 服务器信息
- `POST /api/v2/system/prune?type=offline_proxies` — 清理离线代理
- `GET /api/v2/users` — 用户统计（分页）
- `GET /api/v2/clients`、`/api/v2/clients/{key}` — 客户端列表/详情
- `GET /api/v2/proxies`、`/api/v2/proxies/{name}`、`/api/v2/proxies/{name}/traffic` — 代理列表/详情/流量
- `GET /api/serverinfo`、`/api/clients` 等 v1 端点（管理面板按需调用）

## Nginx HTTPS 反代（推荐）

面板只监听 127.0.0.1，公网统一走 Nginx HTTPS。仓库提供示例：

```bash
cp nginx-frpdash.ilovepose.cn.conf.sample /usr/local/openresty/nginx/conf/conf.d/frpdash.ilovepose.cn.conf
# 改好证书路径后：
nginx -t && nginx -s reload
```

## 安装为 systemd 服务（可选）

```bash
sudo python3 manage/manage.py install-systemd --conf /path/to/manage/manage.conf
sudo systemctl enable --now frp-manage
```

## 生成器使用

“配置生成”页可以给每台需要部署 frpc 的机器生成独立配置：

1. 填写一个唯一的 `user`（例如 `home-pc`、`office-01`），frps 面板上会按这个名字区分客户端和代理
2. 填 `serverAddr`（frps 公网域名/IP）、token（自动从服务器配置带出）
3. 逐行添加要映射的服务（名称、类型、本地 IP/端口、远端端口等）
4. 预览 TOML → 校验 → 下载 `frpc_<user>.toml`
5. 部署提示里给出目标机器安装 frpc 二进制与 systemd 服务的命令

frps 面板里该机器下的代理会显示为 `<user>.<代理名>`。

## 测试

```bash
cd manage/tests
./run_selftest.sh          # 本地拉起 frps + frpc + 面板做端到端自测
```

覆盖：正常登录、错误密码 N 次后锁定、锁定后恢复、会话鉴权、CSRF、frps v2 API 反代、prune 清理、审计日志。

> 自测里的服务控制项使用不存在的隔离 systemd 单元名，只验证接口返回结构化错误，
> 不会误操作测试机上真实运行的 frps 服务。

## 安全注意

- 不要把面板直接暴露在公网 7501 端口；请使用 Nginx HTTPS + 面板自带的登录与防爆破
- 面板只在请求来自本机回环（即同机 Nginx 反代）时信任 `X-Forwarded-For` /
  `X-Real-IP`，避免公网直连时伪造来源 IP 绕过按 IP 的防爆破限制
- `manage/manage.conf` 不要提交到 Git（`.gitignore` 已忽略）
- 面板以 root 运行才有 frps 服务启停能力；若不需要该能力，用普通用户运行并把 `ENABLE_SERVICE_CONTROL=false`
