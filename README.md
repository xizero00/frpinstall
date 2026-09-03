# Frp Installation Script（FRP 自动安装脚本）

一个用于自动下载、配置并安装 [frp](https://github.com/fatedier/frp)（服务端 / 客户端）的脚本，支持 systemd（已测试）与 initd（未测试）。

## 特性

- 自动选择最快的 GitHub 下载代理：数据来自 [Mirror 检测站](https://demo.kentxxq.com/app/mirror)（脚本直接使用该页面背后的检测接口），在“最近一次检测成功”的代理中，选取最近 5 次成功检测平均耗时最短的代理下载。
- 自动检测官方最新版本：自动查询 `fatedier/frp` 的最新 Release 并下载最新版；也可在配置中固定版本。
- 配置即模板：`frpc_template.toml`、`frps_template.toml` 分别保存 frpc / frps 的完整配置；两边重叠的部分（服务端口、token）用 `${...}` 占位符表示，统一在 `frp.conf` 中配置。
- 安装时脚本读取模板、替换公共占位符，再生成 `/etc/frp` 下的正式配置。
- 旧代码归档：重构前的代码完整保存在 [prev_code](prev_code) 目录，便于对比回退。

## 目录结构

```text
frpinstall/
├── frpinstall.sh          # 主安装脚本（一般不需要修改）
├── frp.conf               # 安装设置 + frpc/frps 公共参数
├── frpc_template.toml     # frpc 配置模板（含 ${...} 公共占位符）
├── frps_template.toml     # frps 配置模板（含 ${...} 公共占位符）
├── scripts/
│   ├── frpc_initd.sh      # initd 客户端服务模板
│   ├── frps_initd.sh      # initd 服务端服务模板
│   ├── reinstall_frpc.sh
│   └── reinstall_frps.sh
├── prev_code/             # 重构前的旧代码快照
└── README.md
```

## 快速开始

```bash
git clone https://github.com/xizero00/frpinstall.git
cd frpinstall
```

按机器角色编辑对应配置：

```bash
vim frp.conf             # 安装设置 + 公共参数（端口、token）
vim frpc_template.toml   # 客户端机器：serverAddr、要映射的服务等
vim frps_template.toml   # 服务端机器：webServer 面板等
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

### frp.conf

`frp.conf` 有两类内容：

1. 安装设置（与 frp 配置内容无关）：镜像、版本、用户名、服务类型等。
2. 公共参数（frpc / frps 重叠部分），会自动替换两个模板中的占位符：

| 变量 | 说明 | 替换位置 |
| --- | --- | --- |
| `FRP_SERVER_PORT` | FRP 服务端口 | frpc 的 `serverPort`、frps 的 `bindPort` |
| `FRP_TOKEN` | 连接校验密码 | frpc 与 frps 的 `auth.token` |

修改 `FRP_SERVER_PORT` / `FRP_TOKEN` 后，重新运行对应的安装命令即可让两端配置保持一致，不需要在两个模板里分别改。

### frpc_template.toml

frpc 的配置模板，安装时替换 `${FRP_SERVER_PORT}`、`${FRP_TOKEN}` 后生成 `/etc/frp/frpc_${USER}.toml`。需要按机器修改的部分：

- `serverAddr`：公网服务器 IP / 域名
- `[[proxies]]`：内网需要映射到公网的服务，可写多个

示例（ssh + web 两个服务）：

```toml
serverAddr = "1.2.3.4"
serverPort = ${FRP_SERVER_PORT}

auth.method = "token"
auth.token = "${FRP_TOKEN}"

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

### frps_template.toml

frps 的配置模板，安装时替换 `${FRP_SERVER_PORT}`、`${FRP_TOKEN}` 后生成 `/etc/frp/frps_${USER}.toml`：

```toml
bindPort = ${FRP_SERVER_PORT}

auth.method = "token"
auth.token = "${FRP_TOKEN}"

webServer.addr = "127.0.0.1"
webServer.port = 7500
webServer.user = "admin"
webServer.password = "你的面板密码"
```

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
/etc/frp/frpc_${USER}.toml   # 由 frpc_template.toml + frp.conf 生成
/etc/frp/frps_${USER}.toml   # 由 frps_template.toml + frp.conf 生成
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
- 修改模板或 `frp.conf` 的公共参数后，重新运行对应的安装命令即可更新 `/etc/frp` 下的配置。
- 国内网络直连 GitHub 通常较慢或失败，建议保留镜像自动选择。
- 旧版脚本与文档保存在 `prev_code/`，仅供查看，不再维护。
