#/usr/bin/env bash
set -e

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





install_frpc_config() {
    echo 'install frp client configuration file'
    echo "
[common]
server_addr = ${FRP_SERVER_IP}
server_port = ${FRP_SERVER_PORT}
token = ${FRP_TOKEN})

[ssh]
type = tcp
local_ip = 127.0.0.1
local_port = 22
remote_port = ${FRP_INET_PORT}
" | sudo tee /etc/frp/${FRPCCONF}
}

install_frps_config() {
    echo 'install frp server configuration file'
    echo "
[common]
bind_port = ${FRP_SERVER_PORT}
token = ${FRP_TOKEN})
" | sudo tee /etc/frp/${FRPSCONF}
}

install_frps_systemd_service() {
     echo "
[Unit]
Description=frps daemon

[Service]
Type=simple
ExecStart=/usr/bin/frps -c /etc/frp/${FRPSCONF}

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

[Service]
Type=simple
ExecStart=/usr/bin/frpc -c /etc/frp/${FRPCCONF}

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

TARFILENAME="${TARFILE%.*}"
TARFILENAME="${TARFILENAME%.*}"
download_frp_64() {
    if [ ! -f $TARFILE ]; then
        echo "download ${TARFILE}"
        proxychains wget https://github.com/fatedier/frp/releases/download/v0.20.0/${TARFILE}
        echo "extract ${TARFILE}"
        tar -xzvf $TARFILE
    else
        echo "already exists ${TARFILE}"
        if [ ! -d $TARFILENAME ]; then
            echo "extract ${TARFILE} to ${TARFILENAME}"
            tar -xzvf $TARFILE
        else
            echo "already exists ${TARFILENAME}"
        fi
    fi
}

install_frp() {
    download_frp_64

    if [ ! -f /usr/bin/frpc ]; then
        echo "copy ${TARFILENAME}/frpc to /usr/bin/frpc"
        sudo cp ${TARFILENAME}/frpc /usr/bin/frpc
    fi

    if [ ! -f /usr/bin/frps ]; then
        echo "copy ${TARFILENAME}/frps to /usr/bin/frps"
        sudo cp ${TARFILENAME}/frps /usr/bin/frps
    fi

    if [ ! -d /etc/frp ]; then
        echo "create frp configuration directory"
        sudo mkdir /etc/frp
    fi

}

uninstall_frp() {
    if [ -f /usr/bin/frpc ]; then
        echo 'delete frpc to /usr/bin/frpc'
        sudo rm -rf /usr/bin/frpc
    fi
    if [ -f /usr/bin/frps ]; then
        echo 'delete frps to /usr/bin/frps'
        sudo rm -rf /usr/bin/frps
    fi
    if [ ! -d /etc/frp ]; then
        echo 'delete frp configuration directory'
        sudo rm -rf /etc/frp
    fi

}

install_frpc_service() {
    if [ "$SERVICETYPE" = "systemd" ]; then
        echo 'install frp client service for systemd'
        install_frpc_systemd_service
    else
        echo 'install frp client service for initd'
        install_frpc_initd_service
    fi
}

uninstall_frpc_service() {
    if [ "$SERVICETYPE" = "systemd" ]; then
        echo 'uninstall frp client service for systemd'
        uninstall_frpc_systemd_service
    else
        echo 'uninstall frp client service for initd'
        uninstall_frpc_initd_service
    fi
}

install_frps_service() {
    if [ "$SERVICETYPE" = "systemd" ]; then
        echo 'install frp server service for systemd'
        install_frps_systemd_service
    else
        echo 'install frp server service for initd'
        install_frps_initd_service
    fi
}

uninstall_frps_service() {
    if [ "$SERVICETYPE" = "systemd" ]; then
        echo 'uninstall frp server service for systemd'
        uninstall_frps_systemd_service
    else
        echo 'uninstall frp server service for initd'
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
    echo "Usage: $0 {ins_frp|ins_c_serv|ins_s_serv|unins_c_serv|unins_s_serv}"
    echo "      support installing frp service for systemd(tested) and initd(not tested)"
    echo "      ins_frp : install frp binary and configuration files"
    echo "      ins_c_serv : install frp binary and configuration files and client service"
    echo "      ins_s_serv : install frp binary and configuration files and server service"
    echo "      unins_c_serv : delete frp binary and configuration files and client service"
    echo "      unins_s_serv : delete frp binary and configuration files and server service"
esac





