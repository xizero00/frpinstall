
# Frp Installation Script(FRP自动安装脚本)

Support installing frp service for systemd(tested) and initd(not tested)
支持Systemd，Initd没有经过测试

# Download the script(下载本Github仓库的脚本)
```bash
git clone https://github.com/xizero00/frpinstall.git
```

# Configuration(如何配置FRP)
Modify the frpinstall.sh script according to your server and client's ip and port 
根据你的公网服务器的IP和端口
```

#########################################
#============FRP download =============
# FRP version
# Please refer to https://github.com/fatedier/frp/releases
# 你可以根据FRP的github的release来修改该URL，使其下载最新的FRP程序
FRPURL='https://mirror.ghproxy.com/https://github.com/fatedier/frp/releases/download/v0.63.0/frp_0.63.0_linux_amd64.tar.gz'


#########################################
#==========FRP related configurations =====
# FRP相关的配置
# Please refer to https://github.com/fatedier/frp/blob/dev/README.md#example-usage
# 具体语法可以参考 https://github.com/fatedier/frp/blob/dev/README.md#example-usage

# FRP server ip address
# 公网主机ip地址
FRP_SERVER_IP='127.0.0.1'

# FRP server port 
# 公网主机的FRP反向连接端口，也就是你购买的公网服务器所开放的用于FRP服务的连接端口。
FRP_SERVER_PORT='7000'

# FRP server port for your service
# 公网主机外网端口号，供你的服务使用
# 比如你想让内网主机的ssh服务在外网访问的端口是10022，那么就可以
# 设置为如下
FRP_INET_PORT='10022'

# Your service's name
# 你想要进行反向代理的服务程序的名字
# 比如这里想对ssh进行反向代理，那么就填ssh
# 服务的名字随便起，只要你自己知道这个服务是干嘛的就行
# 命名不要在单词之间有空格
SERVICE_NAME='ssh'

# Your service's port
# 内网的主机上你的服务所占用的端口号
# 比如你想内内网主机的ssh暴露到公网上，那么就可以设置LOCAL_PORT=22
# 因为内网主机的ssh服务的端口是22
LOCAL_PORT='22'

# FRP token
# 用于公网服务器和内网服务器之间的FRP服务连接进行验证的密码
FRP_TOKEN='123456@!(xixihaha)'

# User name which can be used to identify the service
# 自动获取用户的用户名，用于区分服务是谁创建的
USER_NAME=${USER}

```

# Installation Options(安装选项)

* ins_frp : install frp binary and configuration files 安装frp的服务端和客户端的所有文件

* ins_frpc_s : install frpc binary and configuration files and its client service 安装frp的客户端的所有文件

* ins_frps_s : install frpc binary and configuration files and its server service 安装frp的服务端的所有文件

* unins_frpc_s : delete frps binary and configuration files and its client service 删除frp的客户端的所有文件

* unins_frps_s : delete frps binary and configuration files and its  server service 删除frp的服务端的所有文件

# Usage Example(使用示例)

* install frp client with its service 安装frp的客户端的所有文件

```
./frpinstall.sh ins_frpc_s
```

* install frp server with its service 安装frp的服务端的所有文件

```
./frpinstall.sh ins_frps_s
```

* uninstall frp client and its service 删除frp的客户端的所有文件

```
./frpinstall.sh unins_frpc_s
```

* uninstall frp server and its service 删除frp的服务端的所有文件


```
./frpinstall.sh unins_frps_s
```

# Configuration Files(所安装的配置文件路径)

* frp client configuration file 客户端配置文件

```
# 这里的${USER}代表你的Linux当前登录的用户名
/etc/frp/frpc_${USER}.toml
```

* frp server configuration file 服务端配置文件


```
# 这里的${USER}代表你的Linux当前登录的用户名
/etc/frp/frps_${USER}.toml
```


# Manage your FRP service(如何管理你的FRP服务)

* systemd

Restart frp client service
重启客户端服务
```
# 这里的${USER}代表你的Linux当前登录的用户名
sudo systemctl start/stop/restart/status frpc_${USER}
```

Restart frp server service
重启服务端服务
```
# 这里的${USER}代表你的Linux当前登录的用户名
sudo systemctl start/stop/restart/status frps_${USER}
```

* initd system

Restart frp client service
重启客户端服务
```
service frpc start/stop/restart/status
```

Restart frp server service
重启服务端服务
```
service frps start/stop/restart/status
```


`


