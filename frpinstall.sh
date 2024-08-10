#/usr/bin/env bash
set -e

#==========frp related configuration=====
# please refer to https://github.com/fatedier/frp/blob/dev/README.md#example-usage
# frp server ip address(公网主机ip地址)
FRP_SERVER_IP='127.0.0.1'
# frp server port (公网主机FRP反向连接端口)
FRP_SERVER_PORT='7000'

# frp server port for ssh(公网主机外网端口号，供ssh使用)
FRP_INET_PORT='6000'

# the client machine 's ssh port
LOCAL_SSH_PORT='22'

# frp token(FRP 密码，用于反向代理连接保证安全性)
FRP_TOKEN='123456'
# user name which can be used to identify the service
USER_NAME=${USER}

#########################################
#============frp download =============
# frp version
# please refer to https://github.com/fatedier/frp/releases
FRPURL='https://mirror.ghproxy.com/https://github.com/fatedier/frp/releases/download/v0.59.0/frp_0.59.0_linux_amd64.tar.gz'

#===========frp configuration file=======
# frp client configuration filename
FRPCCONF=frpc_${USER_NAME}.toml
# frp server configuration filename
FRPSCONF=frps_${USER_NAME}.toml

#=========service configuration =========
# frp service type(only support systemd or initd)
SERVICETYPE=systemd
# frp client service name
FRPC=frpc_${USER_NAME}
# frp server service name
FRPS=frps_${USER_NAME}





install_frpc_config() {
    echo 'install frp client configuration file'
    echo "
serverAddr = \"${FRP_SERVER_IP}\"
serverPort = ${FRP_SERVER_PORT}

auth.method = \"token\"
auth.token = \"${FRP_TOKEN}\"

[[proxies]]
name = \"ssh\"
type = \"tcp\"
localIP = \"127.0.0.1\"
localPort = ${LOCAL_SSH_PORT}
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
webServer.password = \"adminxdaas\"
" | sudo tee /etc/frp/${FRPSCONF}
}

install_frps_systemd_service() {
     echo "
[Unit]
Description=frps daemon
After=network.target
After=systemd-user-sessions.service
After=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/frps -c /etc/frp/${FRPSCONF}
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
Description=frpc daemon
After=network.target
After=systemd-user-sessions.service
After=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/frpc -c /etc/frp/${FRPCCONF}
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

    if [ ! -f /usr/bin/frpc ]; then
        echo "Copying ${TARDIR}/frpc to /usr/bin/frpc"
        sudo cp ${TARDIR}/frpc /usr/bin/frpc
    fi

    if [ ! -f /usr/bin/frps ]; then
        echo "Copying ${TARDIR}/frps to /usr/bin/frps"
        sudo cp ${TARDIR}/frps /usr/bin/frps
    fi

    if [ ! -d /etc/frp ]; then
        echo "Creating frp configuration directory"
        sudo mkdir /etc/frp
    fi
    install_frpc_config
    install_frps_config
}

uninstall_frp() {
    if [ -f /usr/bin/frpc ]; then
        echo 'Deleting frpc to /usr/bin/frpc'
        sudo rm -rf /usr/bin/frpc
    fi
    if [ -f /usr/bin/frps ]; then
        echo 'Deleting frps to /usr/bin/frps'
        sudo rm -rf /usr/bin/frps
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





