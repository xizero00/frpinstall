# Frp Installation Script（FRP 自动安装脚本）

一个用于自动下载、配置并安装 [frp](https://github.com/fatedier/frp)（服务端 / 客户端）的脚本，支持 systemd（已测试）与 initd（未测试）。

## 特性

- 自动选择最快的 GitHub 下载代理：数据来自 [Mirror 检测站](https://demo.kentxxq.com/app/mirror)（脚本直接使用该页面背后的检测接口），在“最近一次检测成功”的代理中，选取最近 5 次成功检测平均耗时最短的代理下载。
- 自动检测官方最新版本：自动查询 `fatedier/frp` 的最新 Release 并下载最新版；也可在配置中固定版本。
- 配置独立：所有需要修改的参数都集中在 [frp.conf](frp.conf)，主脚本无需改动。
- 旧代码归档：重构前的代码完整保存在 [prev_code](prev_code) 目录，便于对比回退。

## 目录结构

```text
frpinstall/
├── frpinstall.sh       # 主安装脚本（一般不需要修改）
├── frp.conf            # 配置文件：镜像、版本、IP、端口、密码等
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

编辑配置文件：

```bash
vim frp.conf
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

## 配置说明（frp.conf）

### GitHub 下载代理

默认 `AUTO_SELECT_MIRROR=true`，安装时会自动向 Mirror 检测站的接口查询代理检测结果，并选择最快的一个，例如拼接成：

```text
https://gh-proxy.com/https://github.com/fatedier/frp/releases/download/...
```

如果自动选择失败，或想手动固定代理，可修改：

```bash
AUTO_SELECT_MIRROR=false
FALLBACK_MIRROR='ghfast.top'   # 留空则直连 github.com
```

### FRP 版本

默认 `AUTO_DETECT_LATEST_VERSION=true`，每次安装都会先查询官方最新 Release 版本再下载；如果希望固定版本：

```bash
AUTO_DETECT_LATEST_VERSION=false
FRP_VERSION='0.71.0'
```

平台架构通过 `FRP_ARCH` 指定，默认 `linux_amd64`。

### 连接参数

| 变量 | 说明 |
| --- | --- |
| `FRP_SERVER_IP` | 公网服务器 IP |
| `FRP_SERVER_PORT` | 公网服务器上的 FRP 服务端口 |
| `FRP_INET_PORT` | 对外提供服务的外网端口 |
| `SERVICE_NAME` | 服务名称（不要带空格），如 `ssh` |
| `LOCAL_SERVICE_PORT` | 内网实际服务端口 |
| `FRP_TOKEN` | FRP 服务端/客户端校验密码 |
| `USER_NAME` | 用于区分服务归属，默认取当前用户 |
| `FRP_WEB_SERVER_*` | frps 自带 Web 面板设置 |

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

## 生成的配置文件与日志路径

安装后 FRP 配置文件位于：

```text
/etc/frp/frpc_${USER}.toml   # 客户端配置
/etc/frp/frps_${USER}.toml   # 服务端配置
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
- 国内网络直连 GitHub 通常较慢或失败，建议保留镜像自动选择。
- 旧版脚本与文档保存在 `prev_code/`，仅供查看，不再维护。
