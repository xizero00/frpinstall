# Frp Installation Script（FRP 自动安装脚本）

一个用于自动下载、配置并安装 [frp](https://github.com/fatedier/frp)（服务端 / 客户端）的脚本，支持 systemd（已测试）与 initd（未测试）。

## 特性

- 自动选择最快的 GitHub 下载代理：数据来自 [Mirror 检测站](https://demo.kentxxq.com/app/mirror)（脚本直接使用该页面背后的检测接口），在“最近一次检测成功”的代理中，选取最近 5 次成功检测平均耗时最短的代理下载。
- 自动检测官方最新版本：自动查询 `fatedier/frp` 的最新 Release 并下载最新版；也可在配置中固定版本。
- frpc / frps 配置即 TOML：`frpc.toml`、`frps.toml` 就是完整的 frp 配置（连接信息、token、`[[proxies]]`、Web 面板等），支持多个服务；安装时脚本读取它们生成 `/etc/frp` 下的正式配置。
- `frp.conf` 只负责与 frp 配置文件内容无关的安装设置（镜像、版本、服务类型、用户名等）。
- 旧代码归档：重构前的代码完整保存在 [prev_code](prev_code) 目录，便于对比回退。

## 目录结构

```text
frpinstall/
├── frpinstall.sh       # 主安装脚本（一般不需要修改）
├── frp.conf            # 安装设置：镜像、版本、服务类型、用户名等
├── frpc.toml           # frpc 完整配置（安装时生成 /etc/frp/frpc_${USER}.toml）
├── frps.toml           # frps 完整配置（安装时生成 /etc/frp/frps_${USER}.toml）
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

按机器角色编辑对应配置：

```bash
vim frp.conf    # 安装设置（镜像、版本等），一般改一次即可
vim frpc.toml   # 客户端机器：服务器地址、token、要映射的服务
vim frps.toml   # 服务端机器：bindPort、token、Web 面板等
```

安装 FRP 服务端（含 frps 服务）：

```bash
./frpinstall.sh ins_frps_s
```

安装 FRP 客户端（含 frpc 服务）：

```bash
./frpinstall.sh ins_frpc_s
```

> 脚本内部会调用 `sudo`，请使用有 sudo 权限的账号运行。

## 配置说明

### frpc.toml（FRP 客户端）

这份文件就是 frpc 的完整配置，安装时原样安装为 `/etc/frp/frpc_${USER}.toml`。需要修改：

- `serverAddr`：公网服务器 IP / 域名
- `serverPort`：公网服务器上的 FRP 服务端口
- `auth.token`：与服务端 `frps.toml` 一致
- `[[proxies]]`：内网需要映射到公网的服务，可写多个

示例（ssh + web 两个服务）：

```toml
serverAddr = "1.2.3.4"
serverPort = 7000

auth.method = "token"
auth.token = "你的token"

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

### frps.toml（FRP 服务端）

这份文件就是 frps 的完整配置，安装时原样安装为 `/etc/frp/frps_${USER}.toml`：

```toml
bindPort = 7000

auth.method = "token"
auth.token = "你的token"

webServer.addr = "127.0.0.1"
webServer.port = 7500
webServer.user = "admin"
webServer.password = "你的面板密码"
```

客户端与服务器的 `auth.token` 必须保持一致。

### frp.conf（安装设置）

| 变量 | 说明 |
| --- | --- |
| `AUTO_SELECT_MIRROR` | 是否自动选择最快的 GitHub 下载代理（true/false） |
| `MIRROR_API_URL` / `MIRROR_API_DAYS` | Mirror 检测站数据接口与统计天数 |
| `FALLBACK_MIRROR` | 备用代理域名，留空则直连 |
| `AUTO_DETECT_LATEST_VERSION` | 是否自动下载官方最新版本（true/false） |
| `FRP_VERSION` / `FRP_ARCH` | 固定版本号与平台架构 |
| `USER_NAME` | 服务与配置文件归属的用户名（默认当前用户） |
| `SERVICETYPE` | systemd（推荐）或 initd |

> frp.conf 不包含任何会写进 frpc/frps 配置的内容；IP、端口、token、服务映射等一律在 `frpc.toml` / `frps.toml` 中修改。

## 安装选项

```text
ins_frp       安装 FRP 二进制与配置文件（不装服务）
ins_frpc_s    安装 FRP 与客户端服务
ins_frps_s    安装 FRP 与服务端服务
unins_frpc_s  卸载 FRP 与客户端服务
unins_frps_s  卸载 FRP 与服务端服务
```

示例：

```bash
./frpinstall.sh ins_frpc_s     # 安装客户端
./frpinstall.sh ins_frps_s     # 安装服务端
./frpinstall.sh unins_frpc_s   # 卸载客户端
./frpinstall.sh unins_frps_s   # 卸载服务端
```

## 生成的配置文件与服务管理

安装后 FRP 配置文件位于：

```text
/etc/frp/frpc_${USER}.toml   # 由 frpc.toml 生成
/etc/frp/frps_${USER}.toml   # 由 frps.toml 生成
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
- 修改 `frpc.toml` / `frps.toml` 后，重新运行对应的安装命令即可把新配置安装到 `/etc/frp`。
- 国内网络直连 GitHub 通常较慢或失败，建议保留镜像自动选择。
- 旧版脚本与文档保存在 `prev_code/`，仅供查看，不再维护。
