# Frp Installation Script（FRP 自动安装脚本）

一个用于自动下载、配置并安装 [frp](https://github.com/fatedier/frp)（服务端 / 客户端）的脚本，支持 systemd（已测试）与 initd（未测试）。

## 特性

- 自动选择最快的 GitHub 下载代理：数据来自 [Mirror 检测站](https://demo.kentxxq.com/app/mirror)（脚本直接使用该页面背后的检测接口），在“最近一次检测成功”的代理中，选取最近 5 次成功检测平均耗时最短的代理下载。
- 自动检测官方最新版本：自动查询 `fatedier/frp` 的最新 Release 并下载最新版；也可在配置中固定版本。
- 单个配置模板：[frp_template.toml](frp_template.toml) 用 `[common]`、`[frps]`、`[frpc]` 三段保存全部 frp 配置；两端重叠的端口、token 只需在 `[common]` 改一次。
- 安装时脚本读取模板，用 `[common]` 的值替换 `[frpc]` / `[frps]` 中的占位符，再分别生成 `/etc/frp` 下的正式配置。
- [frp.conf](frp.conf) 只保存与 frp 配置内容无关的安装设置。
- 旧代码归档：重构前的代码完整保存在 [prev_code](prev_code) 目录，便于对比回退。

## 目录结构

```text
frpinstall/
├── frpinstall.sh       # 主安装脚本（一般不需要修改）
├── frp.conf            # 安装设置：镜像、版本、服务类型、用户名等
├── frp_template.toml   # frp 配置模板：[common] + [frps] + [frpc]
├── scripts/
│   ├── frpc_initd.sh   # initd 客户端服务模板
│   ├── frps_initd.sh   # initd 服务端服务模板
│   ├── reinstall_frpc.sh
│   └── reinstall_frps.sh
├── prev_code/          # 重构前的旧代码快照
└── README.md
```

## 快速开始

```bash
git clone https://github.com/xizero00/frpinstall.git
cd frpinstall
```

编辑配置：

```bash
vim frp.conf           # 安装设置（镜像、版本等）
vim frp_template.toml  # [common] 公共参数 + [frps] / [frpc] 配置
```

安装 FRP 服务端（含 frps 服务）：

```bash
./frpinstall.sh install-frps
```

安装 FRP 客户端（含 frpc 服务）：

```bash
./frpinstall.sh install-frpc
```

> 脚本内部会调用 `sudo`，请使用有 sudo 权限的账号运行。

## 配置说明

### frp_template.toml

模板分三段，所有 frp 配置内容都放在这里：

```toml
# ============ [common] 公共参数 ============
[common]
serverPort = 7000          # frpc 连接 / frps 监听的端口
token = "你的token"        # 两端连接校验密码

# ============ [frps] FRP 服务端 ============
[frps]
bindPort = ${serverPort}
auth.method = "token"
auth.token = "${token}"

webServer.addr = "127.0.0.1"
webServer.port = 7500
webServer.user = "admin"
webServer.password = "你的面板密码"

# ============ [frpc] FRP 客户端 ============
[frpc]
serverAddr = "1.2.3.4"     # 公网服务器 IP / 域名
serverPort = ${serverPort}
auth.method = "token"
auth.token = "${token}"

[[proxies]]
name = "ssh"
type = "tcp"
localIP = "127.0.0.1"
localPort = 22
remotePort = 10022

[[proxies]]
name = "web"
type = "tcp"
localIP = "127.0.0.1"
localPort = 8080
remotePort = 80
```

- `[common]`：frpc / frps 重叠的公共参数，只需修改一次。
- `[frps]`：服务端专属配置（`webServer` 等）。
- `[frpc]`：客户端专属配置（`serverAddr`、`[[proxies]]` 等）。
- 段内出现的 `${serverPort}`、`${token}` 是占位符，安装时自动替换为 `[common]` 中的值，无需手改。

### frp.conf

只存放安装层面的设置，不包含任何 frp 配置内容：

| 变量 | 说明 |
| --- | --- |
| `AUTO_SELECT_MIRROR` | 是否自动选择最快的 GitHub 下载代理（true/false） |
| `MIRROR_API_URL` / `MIRROR_API_DAYS` | Mirror 检测站数据接口与统计天数 |
| `FALLBACK_MIRROR` | 备用代理域名，留空则直连 |
| `AUTO_DETECT_LATEST_VERSION` | 是否自动下载官方最新版本（true/false） |
| `FRP_VERSION` / `FRP_ARCH` | 固定版本号与平台架构 |
| `USER_NAME` | 服务与配置文件归属的用户名（默认当前用户） |
| `SERVICETYPE` | systemd（推荐）或 initd |

## 安装选项

```text
install-frp               安装 FRP 二进制与配置文件（不装服务）
uninstall-frp             卸载 FRP 二进制与配置文件
install-frpc              安装 FRP 二进制、配置文件与 frpc（客户端）服务
uninstall-frpc            卸载 FRP 二进制、配置文件与 frpc 服务
install-frps              安装 FRP 二进制、配置文件与 frps（服务端）服务
uninstall-frps            卸载 FRP 二进制、配置文件与 frps 服务

仅安装/卸载服务（需先执行 install-frp）：
install-frpc-service      安装 frpc（客户端）服务
uninstall-frpc-service    卸载 frpc（客户端）服务
install-frps-service      安装 frps（服务端）服务
uninstall-frps-service    卸载 frps（服务端）服务
```

示例：

```bash
./frpinstall.sh install-frpc        # 安装客户端（二进制 + 配置 + 服务）
./frpinstall.sh install-frps        # 安装服务端（二进制 + 配置 + 服务）
./frpinstall.sh uninstall-frpc      # 卸载客户端
./frpinstall.sh uninstall-frps      # 卸载服务端
```

> 旧的 `ins_frp` / `ins_frpc_s` / `ins_frps_s` / `unins_*` 写法仍兼容可用。

## 生成的配置文件与服务管理

安装后 FRP 配置文件位于：

```text
/etc/frp/frpc_${USER}.toml   # 来自 frp_template.toml 的 [frpc] 段
/etc/frp/frps_${USER}.toml   # 来自 frp_template.toml 的 [frps] 段
```

服务管理（systemd）：

```bash
sudo systemctl start|stop|restart|status frpc_${USER}
sudo systemctl start|stop|restart|status frps_${USER}
```

服务管理（initd，未测试）：

```bash
service frpc start|stop|restart|status
service frps start|stop|restart|status
```

## 注意事项

- 安装脚本会在当前目录下载 `frp_<版本>_<架构>.tar.gz` 并解压（这些文件已被 `.gitignore` 忽略）。
- 修改 `frp_template.toml` 后，重新运行对应的安装命令即可更新 `/etc/frp` 下的配置。
- 国内网络直连 GitHub 通常较慢或失败，建议保留镜像自动选择。
- 旧版脚本与文档保存在 `prev_code/`，仅供查看，不再维护。
