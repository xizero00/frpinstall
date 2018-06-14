# frpinstall
frp install script

support installing frp service for systemd(tested) and initd(not tested)

# Download script

`git clone https://github.com/djangogo/frpinstall.git
`

# Configure the script
modify the script according to your ip and port 
```
#==========frp related configuration=====
# please refer to https://github.com/fatedier/frp
# frp server ip address(公网主机ip地址)
FRP_SERVER_IP='127.0.0.1'
# frp server port (公网主机FRP反向连接端口)
FRP_SERVER_PORT='7000'

# frp server port for ssh(公网主机外网端口号，供ssh使用)
FRP_INET_PORT='6000'

# frp token(FRP 密码，用于反向代理连接保证安全性)
FRP_TOKEN='x2dsada'


#########################################
#============frp download =============
# frp version
# please refer to https://github.com/fatedier/frp/releases
#TARFILE='frp_0.20.0_linux_386.tar.gz'
TARFILE='frp_0.20.0_linux_amd64.tar.gz'

#===========frp configuration file=======
# frp client configuration filename
FRPCCONF=frpc.ini
# frp server configuration filename
FRPSCONF=frps.ini

#=========service configuration =========
# frp service type(only support systemd or initd)
SERVICETYPE=systemd
# frp client service name
FRPC=frpc
# frp server service name
FRPS=frps
```

# Options:
* ins_frp : install frp binary and configuration files

* ins_frpc_s : install frp binary and configuration files and client service

* ins_frps_s : install frp binary and configuration files and server service

* unins_frpc_s : delete frp binary and configuration files and client service

* unins_frps_s : delete frp binary and configuration files and server service

# Install frp
* install frp client

`
./frpinstall.sh ins_frpc_s
`

* install frp server

`
./frpinstall.sh ins_frps_s
`

# Uninstall frp

* uninstall frp client

`
./frpinstall.sh unins_frpc_s
`

* uninstall frp server


`
./frpinstall.sh unins_frps_s
`

# Manage your frp service
* systemd system

 frp client
 
`
sudo systemctl start/stop/restart/status frpc
`

 frp server
 
`
sudo systemctl start/stop/restart/status frps
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


