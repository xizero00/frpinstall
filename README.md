# frpinstall
Frp installation Script

Support installing frp service for systemd(tested) and initd(not tested)

# Download the script

`git clone https://github.com/xizero00/frpinstall.git
`

# Configuration
modify the script according to your ip and port 
```
# please refer to https://github.com/fatedier/frp/blob/dev/README.md#example-usage
# frp server ip address(公网主机ip地址)
FRP_SERVER_IP='127.0.0.1'
# frp server port (公网主机FRP反向连接端口)
FRP_SERVER_PORT='7000'

# frp server port for ssh(公网主机将内部服务暴露给外网的端口号)
FRP_INET_PORT='6000'

# the client machine 's ssh port(实际提供服务的内部机器的端口号)
LOCAL_SSH_PORT='22'

# frp token(FRP 密码，用于反向代理连接保证安全性)
FRP_TOKEN='123456'
# user name which can be used to identify the service
USER_NAME=${USER}# 这里我们使用用户名作为服务的区分

#########################################
#============frp download =============
# frp version
# please refer to https://github.com/fatedier/frp/releases
FRPURL='https://mirror.ghproxy.com/https://github.com/fatedier/frp/releases/download/v0.59.0/frp_0.59.0_linux_amd64.tar.gz'

```

# Options:
* ins_frp : install frp binary and configuration files

* ins_frpc_s : install frpc binary and configuration files and its client service

* ins_frps_s : install frpc binary and configuration files and its server service

* unins_frpc_s : delete frps binary and configuration files and its client service

* unins_frps_s : delete frps binary and configuration files and its  server service

# Install frp
* install frp client with its service

`
./frpinstall.sh ins_frpc_s
`

* install frp server with its service

`
./frpinstall.sh ins_frps_s
`

# Uninstall frp

* uninstall frp client and its service

`
./frpinstall.sh unins_frpc_s
`

* uninstall frp server and its service


`
./frpinstall.sh unins_frps_s
`

# Configuration Files

* frp client configuration file

```
/etc/frp/frpc_${USER}.toml
```

* frp server configuration file


```
/etc/frp/frps_${USER}.toml
```


# Manage your frp service
* systemd system

 frp client
 
`
sudo systemctl start/stop/restart/status frpc_${USER}
`

 frp server
 
`
sudo systemctl start/stop/restart/status frps_${USER}
`

* initd system

 frp client
 
`
service frpc start/stop/restart/status
`



 frp server
 
`
service frps start/stop/restart/status
`


`


