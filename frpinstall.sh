#/usr/bin/env bash
set -e


#########################################
#============FRP download =============
# FRP version
# please refer to https://github.com/fatedier/frp/releases
# 你可以根据FRP的github的release来修改该URL，使其下载最新的FRP程序
FRPURL='https://mirror.ghproxy.com/https://github.com/fatedier/frp/releases/download/v0.63.0/frp_0.63.0_linux_amd64.tar.gz'


#########################################
#==========FRP related configurations =====
# FRP相关的配置
# please refer to https://github.com/fatedier/frp/blob/dev/README.md#example-usage
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
LOCAL_SERVICE_PORT='22'

# FRP token
# 用于公网服务器和内网服务器之间的FRP服务连接进行验证的密码
FRP_TOKEN='123456@!(xixihaha)'

# User name which can be used to identify the service
# 自动获取用户的用户名，用于区分服务是谁创建的
USER_NAME=${USER}


#########################################
#===========FRP configuration file=======
# FRP配置文件的名字

# frp client configuration filename
# FRP客户端配置文件的名字
FRPCCONF=frpc_${USER_NAME}.toml
# FRP server configuration filename
# FRP服务器端配置文件的名字
FRPSCONF=frps_${USER_NAME}.toml




#########################################
#=========service configuration =========
# 安装到系统的服务相关的配置
# FRP service type(only support systemd or initd)
SERVICETYPE=systemd
# FRP client service name
# FRP客户端服务的名字
FRPC=frpc_${USER_NAME}
# FRP server service name
# FRP服务端服务的名字
FRPS=frps_${USER_NAME}



install_frpc_config() {
    echo 'install frp client configuration file'
    echo "
serverAddr = \"${FRP_SERVER_IP}\"
serverPort = ${FRP_SERVER_PORT}

auth.method = \"token\"
auth.token = \"${FRP_TOKEN}\"

[[proxies]]
name = \"${SERVICE_NAME}\"
type = \"tcp\"
localIP = \"127.0.0.1\"
localPort = ${LOCAL_SERVICE_PORT}
remotePort = ${FRP_INET_PORT}
" | sudo tee /etc/frp/${FRPCCONF}
}

install_frps_config() {
    echo 'Installing frp server configuration file'
    echo "
bindPort = ${FRP_SERVER_PORT}

auth.method = \"token\"
auth.token = \"${FRP_TOKEN}\"

webServer.addr = \"127.0.0.1\"
webServer.port = 7500
webServer.user = \"admin\"
webServer.password = \"adminxdaas@d@xxx\"
" | sudo tee /etc/frp/${FRPSCONF}
}

install_frps_systemd_service() {
     echo "
[Unit]
Description=FRP Server Daemon
After=network.target
After=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/frps -c /etc/frp/${FRPSCONF}
Restart=on-failure
RestartSec=30

[Install]
WantedBy=multi-user.target
" | sudo tee /etc/systemd/system/${FRPS}.service
    sudo systemctl enable ${FRPS}
    sudo systemctl start ${FRPS}
    sudo systemctl status ${FRPS}
}

uninstall_frps_systemd_service() {
    sudo systemctl stop ${FRPS}
    sudo systemctl disable ${FRPS}
    sudo rm -rf /etc/systemd/system/${FRPS}.service
}

install_frpc_systemd_service() {
     echo "
[Unit]
Description=FRP Client Daemon
After=network.target
After=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/frpc -c /etc/frp/${FRPCCONF}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
" | sudo tee /etc/systemd/system/${FRPC}.service
    sudo systemctl enable ${FRPC}
    sudo systemctl start ${FRPC}
    sudo systemctl status ${FRPC}
}

uninstall_frpc_systemd_service() {
    sudo systemctl stop ${FRPC}
    sudo systemctl disable ${FRPC}
    sudo rm -rf /etc/systemd/system/${FRPC}.service
}



install_frps_initd_service() {
    sudo cp ./frps_initd.sh /etc/init.d/${FRPS}
    # rpm based, install service to be run at boot-time: 
    chkconfig ${FRPS} --add
    # apt based, install service to be run at boot-time: 
    # update-rc.d ${FRPS} defaults
    service ${FRPS} start
    service ${FRPS} status
}

uninstall_frps_initd_service() {
    chkconfig ${FRPS} --del
    service ${FRPS} stop
    sudo rm -rf /etc/init.d/${FRPS}
}

install_frpc_initd_service() {
    sudo cp ./frpc_initd.sh /etc/init.d/${FRPC}
    # rpm based, install service to be run at boot-time: 
    chkconfig ${FRPC} --add
    # apt based, install service to be run at boot-time: 
    # update-rc.d ${FRPS} defaults
    service ${FRPC} start
    service ${FRPC} status
}

uninstall_frpc_initd_service() {
    chkconfig ${FRPC} --del
    service ${FRPC} stop
    sudo rm -rf /etc/init.d/${FRPC}
}

TARFILENAME=$(basename -- "$FRPURL")
TARDIR="${TARFILENAME%.tar.gz}"
download_frp_64() {
    if [ ! -f $TARFILENAME ]; then
        echo "Downloading ${FRPURL}"
        #proxychains wget ${FRPURL}
        
        wget --no-check-certificate  ${FRPURL}
        echo "Extracting ${TARFILENAME}"
        tar -xzvf $TARFILENAME
    else
        echo "Already exists ${TARFILENAME}"
        if [ ! -d $TARDIR ]; then
            echo "Extracting ${TARFILENAME} to ${TARDIR}"
            tar -xzvf $TARFILENAME
        else
            echo "Already exists ${TARDIR}"
        fi
    fi
}

install_frp() {
    download_frp_64

    if [ ! -f /usr/local/bin/frpc ]; then
        echo "Copying ${TARDIR}/frpc to /usr/local/bin/frpc"
        sudo cp ${TARDIR}/frpc /usr/local/bin/frpc
    fi

    if [ ! -f /usr/local/bin/frps ]; then
        echo "Copying ${TARDIR}/frps to /usr/local/bin/frps"
        sudo cp ${TARDIR}/frps /usr/local/bin/frps
    fi

    if [ ! -d /etc/frp ]; then
        echo "Creating frp configuration directory"
        sudo mkdir /etc/frp
    fi
    install_frpc_config
    install_frps_config
}

uninstall_frp() {
    if [ -f /usr/local/bin/frpc ]; then
        echo 'Deleting frpc to /usr/local/bin/frpc'
        sudo rm -rf /usr/local/bin/frpc
    fi
    if [ -f /usr/local/bin/frps ]; then
        echo 'Deleting frps to /usr/local/bin/frps'
        sudo rm -rf /usr/local/bin/frps
    fi
    if [ ! -d /etc/frp ]; then
        echo 'Deleting frp configuration directory'
        sudo rm -rf /etc/frp
    fi

}

install_frpc_service() {
    if [ "$SERVICETYPE" = "systemd" ]; then
        echo 'Installing frp client service for systemd'
        install_frpc_systemd_service
    else
        echo 'Installing frp client service for initd'
        install_frpc_initd_service
    fi
}

uninstall_frpc_service() {
    if [ "$SERVICETYPE" = "systemd" ]; then
        echo 'Uninstalling frp client service for systemd'
        uninstall_frpc_systemd_service
    else
        echo 'Uninstalling frp client service for initd'
        uninstall_frpc_initd_service
    fi
}

install_frps_service() {
    if [ "$SERVICETYPE" = "systemd" ]; then
        echo 'Installing frp server service for systemd'
        install_frps_systemd_service
    else
        echo 'Installing frp server service for initd'
        install_frps_initd_service
    fi
}

uninstall_frps_service() {
    if [ "$SERVICETYPE" = "systemd" ]; then
        echo 'Uninstalling frp server service for systemd'
        uninstall_frps_systemd_service
    else
        echo 'Uninstalling frp server service for initd'
        uninstall_frps_initd_service
    fi
}


############## main ############################


case "$1" in
    ins_frpc_s)
        install_frp
        install_frpc_service
            ;;
    unins_frpc_s)
        uninstall_frp
        uninstall_frpc_service
        ;;
    ins_frps_s)
        install_frp
        install_frps_service
            ;;   
    unins_frps_s)
        uninstall_frp
        uninstall_frps_service
            ;; 
    ins_frp)
        install_frp
            ;;
    unins_frp)
        uninstall_frp
            ;;
    ins_c_serv)
        install_frpc_service
            ;;
    ins_s_serv)
        install_frps_service
            ;;
    unins_c_serv)
        uninstall_frpc_service
            ;;
    unins_s_serv)
        uninstall_frps_service
            ;;
    *)
    echo "Usage: $0 {ins_frp|ins_frpc_s|ins_frps_s|unins_frpc_s|unins_frps_s}"
    echo "      support installing frp service for systemd(tested) and initd(not tested)"
    echo "      ins_frp : install frp binary and configuration files"
    echo "      ins_frpc_s : install frp binary and configuration files and client service"
    echo "      ins_frps_s : install frp binary and configuration files and server service"
    echo "      unins_frpc_s : delete frp binary and configuration files and client service"
    echo "      unins_frps_s : delete frp binary and configuration files and server service"
esac





