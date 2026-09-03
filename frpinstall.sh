#!/usr/bin/env bash
set -e

#########################################
#  frpinstall - FRP 服务端 / 客户端安装脚本
#
#  特性：
#   1. 自动从 Mirror 检测站 (https://demo.kentxxq.com/app/mirror)
#      所使用的数据接口获取 GitHub 代理列表，自动选择“最近检测通过、
#      平均速度最快”的代理下载 FRP。
#   2. 自动查询 fatedier/frp 官方最新 Release 并下载最新版本。
#   3. frp_template.toml 一个文件包含 [common] / [frpc] / [frps] 三段；
#      重叠的端口与 token 在 [common] 段配置，安装时自动替换并提取。
#
#  用法：./frpinstall.sh <ins_frp|ins_frpc_s|ins_frps_s|...>
#########################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${FRPINSTALL_CONFIG_FILE:-${SCRIPT_DIR}/frp.conf}"

# ---------- 加载用户配置 ----------
if [ ! -f "$CONFIG_FILE" ]; then
    echo "Error: 配置文件不存在: ${CONFIG_FILE}" >&2
    echo "      请将 frp.conf 放到脚本同目录后重新运行。" >&2
    exit 1
fi
# shellcheck source=/dev/null
source "$CONFIG_FILE"

# ---------- 配置默认值（未在 frp.conf 中定义时使用） ----------
: "${AUTO_SELECT_MIRROR:=true}"
: "${MIRROR_API_URL:=https://uni.kentxxq.com/uni.webapi/githubMirror/GetMirrorStatus}"
: "${MIRROR_API_DAYS:=3}"
: "${FALLBACK_MIRROR:=}"
: "${AUTO_DETECT_LATEST_VERSION:=true}"
: "${FRP_VERSION:=0.71.0}"
: "${FRP_ARCH:=linux_amd64}"
: "${USER_NAME:=${USER}}"
: "${SERVICETYPE:=systemd}"
: "${FRP_CONFIG_FILE:=${SCRIPT_DIR}/frp_template.toml}"

# ---------- FRP 文件名 / 服务名（依赖上面配置） ----------
FRPCCONF="frpc_${USER_NAME}.toml"
FRPSCONF="frps_${USER_NAME}.toml"
FRPC="frpc_${USER_NAME}"
FRPS="frps_${USER_NAME}"


#########################################
# ========== 基础工具函数 ==========
#########################################

log() {
    printf '[frpinstall] %s\n' "$*" >&2
}

die() {
    echo "Error: $*" >&2
    exit 1
}

# http_get <url> [超时秒数] ：把响应内容输出到 stdout
http_get() {
    local url="$1"
    local timeout="${2:-40}"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --connect-timeout 10 --max-time "${timeout}" "$url"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO- --timeout="${timeout}" "$url"
    else
        die "未找到 curl 或 wget，无法进行网络请求"
    fi
}

# http_download <url> <保存文件名> ：下载文件
http_download() {
    local url="$1"
    local file="$2"
    if command -v curl >/dev/null 2>&1; then
        curl -fLk --connect-timeout 10 --retry 2 --retry-delay 2 -o "$file" "$url"
    elif command -v wget >/dev/null 2>&1; then
        wget --no-check-certificate --timeout=60 -O "$file" "$url"
    else
        die "未找到 curl 或 wget，无法下载文件"
    fi
}


#########################################
# ========== GitHub 代理自动选择 ==========
#########################################

# 通过 Mirror 检测站的数据接口，在所有“最近一次检测成功”的 GitHub 代理中，
# 选择最近 5 次成功检测平均耗时最小的代理，输出其域名。
select_fastest_github_mirror() {
    local api_url="$MIRROR_API_URL"
    local json=""
    local host=""

    case "$api_url" in
        *\?*) api_url="${api_url}&days=${MIRROR_API_DAYS}" ;;
        *)    api_url="${api_url}?days=${MIRROR_API_DAYS}" ;;
    esac

    log "正在从 Mirror 检测站获取 GitHub 代理状态: ${api_url}"
    if ! json=$(http_get "$api_url" 30 2>/dev/null); then
        log "获取代理列表失败，将改用备用代理"
        return 1
    fi

    host=$(printf '%s\n' "$json" | awk '
{
    buf = buf $0
}
END {
    pos = 1
    while (1) {
        hs = index(substr(buf, pos), "\"hostName\":\"")
        if (!hs) break
        hpos = pos + hs + 11
        he = index(substr(buf, hpos), "\"")
        if (!he) break
        host = substr(buf, hpos, he - 1)
        rest = substr(buf, hpos)
        cs = index(rest, "\"checkHistory\":[")
        if (!cs) break
        cpos = hpos + cs + 16
        ce = index(substr(buf, cpos), "]")
        if (!ce) break
        recs = substr(buf, cpos, ce - 1)
        pos = cpos + ce - 1

        gsub(/},{/, "}\n{", recs)
        cnt = split(recs, records, "\n")
        for (i = 1; i <= cnt; i++) {
            r = records[i]
            ok = index(r, "\"isSuccess\":true") > 0
            sp = index(r, "\"hostSpeed\":")
            speed = -1
            if (sp) {
                s = substr(r, sp + 12)
                gsub(/[^0-9.]/, "", s)
                if (s != "") speed = s + 0
            }
            if (ok && speed >= 0) {
                speeds[host, ++speed_cnt[host]] = speed
            }
            last_ok[host] = ok
        }
    }

    best_host = ""
    best_avg = 1e18
    for (h in speed_cnt) {
        if (!last_ok[h]) continue
        total = speed_cnt[h]
        sample = total < 5 ? total : 5
        sum = 0
        for (i = total - sample + 1; i <= total; i++) sum += speeds[h, i]
        avg = sum / sample
        if (avg < best_avg) {
            best_avg = avg
            best_host = h
        }
    }
    print best_host
}')

    if [ -z "$host" ]; then
        log "代理列表中暂时没有“最近检测成功”的代理，将改用备用代理"
        return 1
    fi
    printf '%s\n' "$host"
}


#########################################
# ========== FRP 最新版本自动检测 ==========
#########################################

# 从 GitHub API 返回内容中解析 tag_name，如 v0.71.0 -> 0.71.0
parse_version_from_api_json() {
    grep -oE '"tag_name"[[:space:]]*:[[:space:]]*"v[0-9][0-9.]*"' |
        head -n 1 |
        sed -n 's/.*"v\([0-9][0-9.]*\)".*/\1/p'
}

# 从 GitHub Release 页面 / 重定向内容中解析 v0.71.0
parse_version_from_release_page() {
    grep -oE 'releases/tag/v[0-9][0-9.]*' |
        head -n 1 |
        sed -n 's/.*v\([0-9][0-9.]*\)$/\1/p'
}

# 尝试从单个地址获取最新版本号（失败时输出为空）
try_fetch_latest_version() {
    local url="$1"
    local body=""
    body=$(http_get "$url" 20 2>/dev/null || true)
    if [ -z "$body" ]; then
        return 1
    fi
    printf '%s\n' "$body" | parse_version_from_api_json
}

try_fetch_latest_version_from_page() {
    local url="$1"
    local body=""
    body=$(http_get "$url" 30 2>/dev/null || true)
    if [ -z "$body" ]; then
        return 1
    fi
    printf '%s\n' "$body" | parse_version_from_release_page
}

# 依次尝试：GitHub API -> 镜像代理的 GitHub API -> 镜像代理的 Release 页面
resolve_latest_frp_version() {
    local mirror="$1"
    local version=""

    version=$(try_fetch_latest_version \
        "https://api.github.com/repos/fatedier/frp/releases/latest" || true)
    if [ -n "$version" ]; then
        printf '%s\n' "$version"
        return 0
    fi

    if [ -n "$mirror" ]; then
        version=$(try_fetch_latest_version \
            "https://${mirror}/https://api.github.com/repos/fatedier/frp/releases/latest" || true)
        if [ -n "$version" ]; then
            printf '%s\n' "$version"
            return 0
        fi

        version=$(try_fetch_latest_version_from_page \
            "https://${mirror}/https://github.com/fatedier/frp/releases/latest" || true)
        if [ -n "$version" ]; then
            printf '%s\n' "$version"
            return 0
        fi
    fi

    version=$(try_fetch_latest_version_from_page \
        "https://github.com/fatedier/frp/releases/latest" || true)
    if [ -n "$version" ]; then
        printf '%s\n' "$version"
        return 0
    fi
    return 1
}


#########################################
# ========== 组装下载地址 ==========
#########################################

resolve_download_url() {
    local mirror="$1"
    local release_url=""
    release_url="https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/frp_${FRP_VERSION}_${FRP_ARCH}.tar.gz"

    if [ -n "$mirror" ]; then
        FRPURL="https://${mirror}/${release_url}"
    else
        FRPURL="$release_url"
    fi
    FRP_FILENAME="$(basename "$FRPURL")"
    FRP_DIRNAME="${FRP_FILENAME%.tar.gz}"
}

# 决定使用哪个镜像、下载哪个版本，并生成最终的下载地址
prepare_frp_download() {
    local mirror=""
    local latest=""

    if [ "$AUTO_SELECT_MIRROR" = "true" ]; then
        if ! mirror=$(select_fastest_github_mirror); then
            mirror="$FALLBACK_MIRROR"
        fi
    else
        mirror="$FALLBACK_MIRROR"
    fi

    if [ -n "$mirror" ]; then
        log "本次下载将使用 GitHub 代理: ${mirror}"
    else
        log "未配置 GitHub 代理，将直连 github.com 下载"
    fi

    if [ "$AUTO_DETECT_LATEST_VERSION" = "true" ]; then
        latest=$(resolve_latest_frp_version "$mirror" || true)
        if [ -n "$latest" ]; then
            if [ "$latest" != "$FRP_VERSION" ]; then
                log "检测到官方最新版本 v${latest}（配置中的版本为 v${FRP_VERSION}），自动切换到最新版"
            fi
            FRP_VERSION="$latest"
        else
            log "自动检测最新版本失败，使用配置中的版本 v${FRP_VERSION}"
        fi
    fi

    resolve_download_url "$mirror"
    log "下载地址: ${FRPURL}"
}


#########################################
# ========== FRP 下载与安装 ==========
#########################################

download_frp() {
    local tarfile="$FRP_FILENAME"
    local dirname="$FRP_DIRNAME"

    if [ ! -f "$tarfile" ]; then
        log "正在下载 ${FRPURL}"
        if ! http_download "$FRPURL" "$tarfile"; then
            rm -f "$tarfile"
            die "下载 ${FRPURL} 失败"
        fi

        # 简单校验：gzip 文件头应该是 1f 8b
        local magic
        magic=$(od -An -tx1 -N2 "$tarfile" 2>/dev/null | tr -d ' \n' || true)
        if [ "$magic" != "1f8b" ]; then
            rm -f "$tarfile"
            die "下载内容不是有效的 gzip 压缩包（${magic:-无法读取}），请重试或更换代理"
        fi
    else
        log "已存在 ${tarfile}，跳过下载"
    fi

    if [ ! -d "$dirname" ]; then
        log "正在解压 ${tarfile}"
        tar -xzf "$tarfile"
    else
        log "已存在目录 ${dirname}，跳过解压"
    fi
}

install_frp() {
    download_frp

    if [ ! -f /usr/local/bin/frpc ]; then
        log "正在复制 ${FRP_DIRNAME}/frpc 到 /usr/local/bin/frpc"
        sudo cp "${FRP_DIRNAME}/frpc" /usr/local/bin/frpc
    fi

    if [ ! -f /usr/local/bin/frps ]; then
        log "正在复制 ${FRP_DIRNAME}/frps 到 /usr/local/bin/frps"
        sudo cp "${FRP_DIRNAME}/frps" /usr/local/bin/frps
    fi

    if [ ! -d /etc/frp ]; then
        log "正在创建 FRP 配置目录 /etc/frp"
        sudo mkdir -p /etc/frp
    fi
    install_frpc_config
    install_frps_config
}

uninstall_frp() {
    if [ -f /usr/local/bin/frpc ]; then
        log "正在删除 /usr/local/bin/frpc"
        sudo rm -f /usr/local/bin/frpc
    fi
    if [ -f /usr/local/bin/frps ]; then
        log "正在删除 /usr/local/bin/frps"
        sudo rm -f /usr/local/bin/frps
    fi
    if [ -d /etc/frp ]; then
        log "正在删除 FRP 配置目录 /etc/frp"
        sudo rm -rf /etc/frp
    fi
}


#########################################
# ========== 配置文件安装 ==========
#########################################

# 从 frp_template.toml 的 [common] 段读取键值（自动去掉引号）
parse_common_value() {
    local src="$1"
    local key="$2"
    awk -v key="$key" '
        $0 == "[common]" { active = 1; next }
        active && /^\[[A-Za-z_]/ { exit }
        active && match($0, "^[ \t]*" key "[ \t]*=") {
            v = substr($0, RSTART + RLENGTH)
            sub(/^[ \t]+/, "", v)
            sub(/[ \t]+$/, "", v)
            if (substr(v, 1, 1) == "\"") v = substr(v, 2)
            if (substr(v, length(v), 1) == "\"") v = substr(v, 1, length(v) - 1)
            print v
            exit
        }
    ' "$src"
}

# 用 [common] 段的值替换模板中的 ${serverPort}、${token}
expand_frp_template() {
    local src="$1"
    local port token
    port=$(parse_common_value "$src" "serverPort")
    token=$(parse_common_value "$src" "token")
    if [ -z "$port" ] || [ -z "$token" ]; then
        die "模板中 [common] 段缺少 serverPort 或 token：${src}"
    fi
    # 转义 sed 替换中的特殊字符，保证 token 里的 / & \ 等不被误处理
    port=$(printf '%s' "$port" | sed 's#[\/&]#\\&#g')
    token=$(printf '%s' "$token" | sed 's#[\/&]#\\&#g')
    sed -e "s/\\\${serverPort}/$port/g" \
        -e "s/\\\${token}/$token/g" "$src"
}

# 从 frp_template.toml 中提取指定 TOML 段（[frpc] / [frps]）
extract_frp_section() {
    local section="$1"
    local src="$2"
    awk -v sec="[$section]" '
        $0 == sec { active = 1; next }
        active && /^\[[A-Za-z_]/ { exit }
        active && /\[frps\]/ { exit }
        active { print }
    ' "$src"
}

# 读取 frp_template.toml 的 [frpc] 段，替换占位符后
# 安装为 /etc/frp/frpc_${USER_NAME}.toml
install_frpc_config() {
    local content=""
    log "正在安装 FRP 客户端配置文件 /etc/frp/${FRPCCONF}"
    if [ ! -f "$FRP_CONFIG_FILE" ]; then
        die "未找到配置模板 ${FRP_CONFIG_FILE}，请先编辑同目录的 frp_template.toml"
    fi
    content=$(expand_frp_template "$FRP_CONFIG_FILE" |
        extract_frp_section "frpc" /dev/stdin)
    if [ -z "$content" ]; then
        die "模板中找不到 [frpc] 段，请检查 ${FRP_CONFIG_FILE}"
    fi
    printf '%s\n' "$content" | sudo tee "/etc/frp/${FRPCCONF}" >/dev/null
}

# 读取 frp_template.toml 的 [frps] 段，替换占位符后
# 安装为 /etc/frp/frps_${USER_NAME}.toml
install_frps_config() {
    local content=""
    log "正在安装 FRP 服务端配置文件 /etc/frp/${FRPSCONF}"
    if [ ! -f "$FRP_CONFIG_FILE" ]; then
        die "未找到配置模板 ${FRP_CONFIG_FILE}，请先编辑同目录的 frp_template.toml"
    fi
    content=$(expand_frp_template "$FRP_CONFIG_FILE" |
        extract_frp_section "frps" /dev/stdin)
    if [ -z "$content" ]; then
        die "模板中找不到 [frps] 段，请检查 ${FRP_CONFIG_FILE}"
    fi
    printf '%s\n' "$content" | sudo tee "/etc/frp/${FRPSCONF}" >/dev/null
}


#########################################
# ========== systemd 服务安装/卸载 ==========
#########################################

install_frps_systemd_service() {
    log "正在安装 FRP 服务端 systemd 服务 ${FRPS}"
    sudo tee "/etc/systemd/system/${FRPS}.service" >/dev/null <<EOF
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
EOF
    sudo systemctl enable "${FRPS}"
    sudo systemctl start "${FRPS}"
    sudo systemctl status "${FRPS}"
}

uninstall_frps_systemd_service() {
    sudo systemctl stop "${FRPS}"
    sudo systemctl disable "${FRPS}"
    sudo rm -f "/etc/systemd/system/${FRPS}.service"
}

install_frpc_systemd_service() {
    log "正在安装 FRP 客户端 systemd 服务 ${FRPC}"
    sudo tee "/etc/systemd/system/${FRPC}.service" >/dev/null <<EOF
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
EOF
    sudo systemctl enable "${FRPC}"
    sudo systemctl start "${FRPC}"
    sudo systemctl status "${FRPC}"
}

uninstall_frpc_systemd_service() {
    sudo systemctl stop "${FRPC}"
    sudo systemctl disable "${FRPC}"
    sudo rm -f "/etc/systemd/system/${FRPC}.service"
}


#########################################
# ========== initd 服务安装/卸载 ==========
#########################################

install_frps_initd_service() {
    log "正在安装 FRP 服务端 initd 服务 ${FRPS}"
    sudo cp "${SCRIPT_DIR}/scripts/frps_initd.sh" "/etc/init.d/${FRPS}"
    # rpm based, install service to be run at boot-time:
    chkconfig "${FRPS}" --add
    # apt based, install service to be run at boot-time:
    # update-rc.d ${FRPS} defaults
    service "${FRPS}" start
    service "${FRPS}" status
}

uninstall_frps_initd_service() {
    chkconfig "${FRPS}" --del
    service "${FRPS}" stop
    sudo rm -f "/etc/init.d/${FRPS}"
}

install_frpc_initd_service() {
    log "正在安装 FRP 客户端 initd 服务 ${FRPC}"
    sudo cp "${SCRIPT_DIR}/scripts/frpc_initd.sh" "/etc/init.d/${FRPC}"
    # rpm based, install service to be run at boot-time:
    chkconfig "${FRPC}" --add
    # apt based, install service to be run at boot-time:
    # update-rc.d ${FRPC} defaults
    service "${FRPC}" start
    service "${FRPC}" status
}

uninstall_frpc_initd_service() {
    chkconfig "${FRPC}" --del
    service "${FRPC}" stop
    sudo rm -f "/etc/init.d/${FRPC}"
}


#########################################
# ========== 服务安装/卸载分发 ==========
#########################################

install_frpc_service() {
    if [ "$SERVICETYPE" = "systemd" ]; then
        log "正在安装 FRP 客户端 systemd 服务"
        install_frpc_systemd_service
    else
        log "正在安装 FRP 客户端 initd 服务"
        install_frpc_initd_service
    fi
}

uninstall_frpc_service() {
    if [ "$SERVICETYPE" = "systemd" ]; then
        log "正在卸载 FRP 客户端 systemd 服务"
        uninstall_frpc_systemd_service
    else
        log "正在卸载 FRP 客户端 initd 服务"
        uninstall_frpc_initd_service
    fi
}

install_frps_service() {
    if [ "$SERVICETYPE" = "systemd" ]; then
        log "正在安装 FRP 服务端 systemd 服务"
        install_frps_systemd_service
    else
        log "正在安装 FRP 服务端 initd 服务"
        install_frps_initd_service
    fi
}

uninstall_frps_service() {
    if [ "$SERVICETYPE" = "systemd" ]; then
        log "正在卸载 FRP 服务端 systemd 服务"
        uninstall_frps_systemd_service
    else
        log "正在卸载 FRP 服务端 initd 服务"
        uninstall_frps_initd_service
    fi
}


#########################################
# ========== 主入口 ==========
#########################################

usage() {
    cat <<'EOF'
Usage: ./frpinstall.sh {ins_frp|ins_frpc_s|ins_frps_s|unins_frpc_s|unins_frps_s}

支持安装 systemd（已测试）与 initd（未测试）服务。

  ins_frp       安装 FRP 二进制文件与配置文件（不安装服务）
  ins_frpc_s    安装 FRP 二进制、配置文件与客户端服务
  ins_frps_s    安装 FRP 二进制、配置文件与服务端服务
  unins_frpc_s  删除 FRP 二进制、配置文件与客户端服务
  unins_frps_s  删除 FRP 二进制、配置文件与服务端服务

所有可配置项都在同目录的 frp.conf 中，请先按需修改。
EOF
}

main() {
    case "$1" in
        ins_frpc_s)
            prepare_frp_download
            install_frp
            install_frpc_service
            ;;
        unins_frpc_s)
            uninstall_frp
            uninstall_frpc_service
            ;;
        ins_frps_s)
            prepare_frp_download
            install_frp
            install_frps_service
            ;;
        unins_frps_s)
            uninstall_frp
            uninstall_frps_service
            ;;
        ins_frp)
            prepare_frp_download
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
            usage
            exit 1
            ;;
    esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
