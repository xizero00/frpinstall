#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
frp-manage 管理面板入口

用法：
  python3 manage.py serve [--conf manage.conf]
                         [--host 127.0.0.1] [--port 7501] [--state-dir DIR]
  python3 manage.py check [--conf manage.conf]
  python3 manage.py install-systemd [--conf manage.conf] [--user root]
"""

import argparse
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from manage_lib import (  # noqa: E402
    APP_NAME,
    APP_VERSION,
    ConfigError,
    build_config,
)


def _default_conf():
    return os.path.join(os.path.dirname(os.path.abspath(__file__)), "manage.conf")


def cmd_check(args):
    conf = args.conf or _default_conf()
    try:
        cfg = build_config(conf)
    except ConfigError as exc:
        print(f"[错误] {exc}", file=sys.stderr)
        return 1
    print("manage.conf        :", cfg["CONF_FILE"])
    print("监听地址           :", f"{cfg['PANEL_LISTEN_ADDR']}:{cfg['PANEL_LISTEN_PORT']}")
    print("登录方式           :", "frps webServer 用户名/密码")
    print("frps 配置文件      :", cfg.get("FRPS_CONFIG_FILE") or "（未找到）")
    print("frps API 地址      :", cfg.get("FRPS_API_URL") or "（未配置）")
    print("frps API 用户      :", cfg.get("FRPS_API_USER") or "（未配置）")
    print("systemd 服务名     :", cfg.get("FRPS_SERVICE_NAME") or "（未识别）")
    print("状态/会话数据库    :", cfg["DB_PATH"])
    print("暴力破解防护       :",
          f"连续失败 {cfg['LOGIN_MAX_FAILURES']} 次锁定 "
          f"{cfg['LOGIN_LOCKOUT_MINUTES']} 分钟")
    return 0


def cmd_serve(args):
    from manage_lib import run_forever

    conf = args.conf or _default_conf()
    try:
        overrides = {}
        if args.state_dir:
            overrides["STATE_DIR"] = args.state_dir
        cfg = build_config(conf, overrides)
    except ConfigError as exc:
        print(f"[错误] {exc}", file=sys.stderr)
        return 1
    run_forever(
        cfg,
        host=args.host,
        port=args.port,
    )
    return 0


def cmd_install_systemd(args):
    if os.geteuid() != 0:
        print("install-systemd 需要 root 权限，请使用 sudo 运行", file=sys.stderr)
        return 1
    conf = os.path.abspath(args.conf or _default_conf())
    script = os.path.abspath(__file__)
    if not os.path.exists(conf):
        print(f"配置文件不存在: {conf}", file=sys.stderr)
        return 1

    frps_service = ""
    try:
        cfg = build_config(conf)
        frps_service = cfg.get("FRPS_SERVICE_NAME", "") or ""
    except ConfigError as exc:
        print(f"[警告] 无法读取配置，跳过 frps 服务依赖关联: {exc}", file=sys.stderr)

    after = "network.target"
    wants = ""
    if frps_service:
        after += f" {frps_service}.service"
        wants = f"Wants={frps_service}.service\n"

    def sq(value):
        # systemd ExecStart 使用双引号处理带空格的路径
        return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'

    unit = "/etc/systemd/system/frp-manage.service"
    content = f"""[Unit]
Description=frp-manage - frps Web Management Panel
After={after}
{wants}

[Service]
Type=simple
User={args.user}
ExecStart={sq(sys.executable)} {sq(script)} serve --conf {sq(conf)}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
"""
    with open(unit, "w", encoding="utf-8") as fh:
        fh.write(content)
    for cmd in (["systemctl", "daemon-reload"], ["systemctl", "enable", "frp-manage"]):
        proc = subprocess.run(cmd, capture_output=True, text=True)
        if proc.returncode != 0:
            print(f"[警告] {cmd[0]} {cmd[1]} 失败: {proc.stderr.strip()}", file=sys.stderr)
    print(f"已写入 systemd 单元: {unit}")
    print("启动面板：sudo systemctl start frp-manage")
    print("查看状态：systemctl status frp-manage")
    return 0


def build_parser():
    parser = argparse.ArgumentParser(
        prog="manage.py",
        description=f"{APP_NAME} v{APP_VERSION} - frps Web 管理面板",
    )
    sub = parser.add_subparsers(dest="command", required=True)

    p_serve = sub.add_parser("serve", help="启动面板服务")
    p_serve.add_argument("--conf", help="manage.conf 路径")
    p_serve.add_argument("--host", help="监听地址（覆盖配置）")
    p_serve.add_argument("--port", type=int, help="监听端口（覆盖配置）")
    p_serve.add_argument("--state-dir", help="会话/审计数据库目录（覆盖配置）")
    p_serve.set_defaults(func=cmd_serve)

    p_check = sub.add_parser("check", help="检查配置")
    p_check.add_argument("--conf", help="manage.conf 路径")
    p_check.set_defaults(func=cmd_check)

    p_sysd = sub.add_parser("install-systemd", help="安装 systemd 服务")
    p_sysd.add_argument("--conf", help="manage.conf 路径")
    p_sysd.add_argument("--user", default="root", help="运行用户（默认 root）")
    p_sysd.set_defaults(func=cmd_install_systemd)
    return parser


def main(argv=None):
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        return args.func(args) or 0
    except KeyboardInterrupt:
        return 130


if __name__ == "__main__":
    sys.exit(main())
