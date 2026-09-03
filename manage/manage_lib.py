#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
frp-manage 管理面板核心库

功能：
  1. 用户名 + 密码登录：直接用 frps webServer.user / webServer.password 校验
  2. 暴力破解防护：按 用户名+IP 与 IP 维度统计失败次数，超限锁定一段时间
  3. 登录会话：随机 token 存 SQLite，Cookie 只存 token（HttpOnly / SameSite）
  4. 对接 frps dashboard API（v0.71+ 的 v1/v2 接口全部透传）
  5. frps 服务进程/ systemd 状态探测与启停（需要 root 或无密码 sudo）

仅使用 Python 3 标准库，无第三方依赖。
"""

import base64
import hashlib
import hmac
import ipaddress
import json
import logging
import mimetypes
import os
import re
import secrets
import sqlite3
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

try:
    import tomllib
except ImportError:  # Python < 3.11
    tomllib = None

APP_NAME = "frp-manage"
APP_VERSION = "1.0.0"
COOKIE_NAME = "frpman_session"

DEFAULT_CONFIG = {
    "PANEL_LISTEN_ADDR": "127.0.0.1",
    "PANEL_LISTEN_PORT": 7501,
    "FRPS_CONFIG_FILE": "",
    "FRPS_API_URL": "",
    "FRPS_API_USER": "",
    "FRPS_API_PASSWORD": "",
    "FRPS_SERVICE_NAME": "",
    "STATE_DIR": "/var/lib/frp-manage",
    "LOGIN_MAX_FAILURES": 5,
    "LOGIN_LOCKOUT_MINUTES": 15,
    "LOGIN_FAILURE_WINDOW_MINUTES": 15,
    "LOGIN_DELAY_SECONDS": 0.5,
    "SESSION_TTL_HOURS": 12,
    "ENABLE_SERVICE_CONTROL": "true",
    "REQUEST_TIMEOUT_SECONDS": 30,
    "FRP_TEMPLATE_FILE": "",
    "FRP_GEN_VERSION": "0.71.0",
    "FRP_GEN_ARCH": "linux_amd64",
}

INT_KEYS = {
    "PANEL_LISTEN_PORT",
    "LOGIN_MAX_FAILURES",
    "SESSION_TTL_HOURS",
    "REQUEST_TIMEOUT_SECONDS",
}

FLOAT_KEYS = {
    "LOGIN_LOCKOUT_MINUTES",
    "LOGIN_FAILURE_WINDOW_MINUTES",
    "LOGIN_DELAY_SECONDS",
}

BOOL_KEYS = {"ENABLE_SERVICE_CONTROL"}

MAX_BODY_SIZE = 4 * 1024 * 1024  # 4MB
PBKDF2_ITERATIONS = 600_000


class ConfigError(Exception):
    """配置错误。"""


def _clean_value(raw: str) -> str:
    """去掉注释与引号，返回纯值。"""
    raw = raw.strip()
    if not raw:
        return ""
    if raw[0] in ("'", '"'):
        quote = raw[0]
        if raw[-1] == quote and len(raw) > 1:
            return raw[1:-1].strip()
        return raw[1:].strip()
    # 未加引号时，# 视为注释起点
    if "#" in raw:
        raw = raw.split("#", 1)[0].strip()
    return raw


def parse_conf_file(path: str) -> dict:
    """解析 manage.conf（兼容 frp.conf 的 KEY=VALUE 风格）。"""
    values = {}
    accounts = {}
    if not os.path.exists(path):
        raise ConfigError(f"配置文件不存在: {path}")
    with open(path, "r", encoding="utf-8") as fh:
        for lineno, line in enumerate(fh, 1):
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            m = re.match(r"^([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$", line)
            if not m:
                raise ConfigError(f"{path}:{lineno} 行格式错误（应为 KEY=VALUE）")
            key, value = m.group(1), _clean_value(m.group(2))
            if key.startswith("ACCOUNT_"):
                username = key[len("ACCOUNT_") :]
                if not username or not value:
                    continue
                accounts[username] = value
            else:
                values[key] = value
    return values, accounts


def _as_int(key: str, raw_value, default):
    try:
        return int(float(raw_value) if "." in str(raw_value) else raw_value)
    except (TypeError, ValueError):
        return default


def _as_float(raw_value, default):
    try:
        return float(raw_value)
    except (TypeError, ValueError):
        return default


def _as_bool(raw_value, default):
    if isinstance(raw_value, bool):
        return raw_value
    return str(raw_value).strip().lower() in ("1", "true", "yes", "on")


def _frps_config_candidates():
    cfg_dir = Path("/etc/frp")
    if cfg_dir.is_dir():
        for p in sorted(cfg_dir.glob("frps_*.toml")):
            yield str(p)


def discover_frps_config_file(preferred: str = "") -> str:
    """返回 frps 配置文件路径。"""
    if preferred:
        if not os.path.exists(preferred):
            raise ConfigError(f"FRPS_CONFIG_FILE 指向的文件不存在: {preferred}")
        return preferred
    for cand in _frps_config_candidates():
        return cand
    # 兼容自定义安装目录：看看 manage.conf 所在目录附近
    return ""


def parse_frps_toml_scalars(path: str):
    """从 frps TOML 中提取 webServer.* 等标量配置。"""
    if not path or not os.path.exists(path):
        return {}
    out = {}

    def flatten(node, prefix, sink):
        for key, value in node.items():
            full = f"{prefix}.{key}" if prefix else key
            if isinstance(value, dict):
                flatten(value, full, sink)
            elif isinstance(value, (str, int, float, bool)) or value is None:
                sink[full] = value

    # 优先用标准 TOML 解析：同时兼容
    #   webServer.addr = "..."（平铺点号键）与
    #   [webServer] / [webServer.tls]（小节）两种写法。
    if tomllib is not None:
        try:
            with open(path, "rb") as fh:
                data = tomllib.load(fh)
            flatten(data.get("webServer") or {}, "webServer", out)
            if out:
                return out
        except (ValueError, OSError, TypeError):
            pass

    # 退回行级解析（文件含 ${...} 占位符等无法用 tomllib 解析时）
    section = ""
    try:
        fh = open(path, "r", encoding="utf-8")
    except OSError:
        return out
    with fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            if line.startswith("[") and line.endswith("]"):
                section = line[1:-1].strip()
                continue
            m = re.match(r"^([A-Za-z0-9_.]+)\s*=\s*(.*)$", line)
            if not m:
                continue
            key, value = m.group(1), _clean_value(m.group(2))
            if section in ("", "frps"):
                if key.startswith("webServer."):
                    out[key] = value
            elif section == "webServer" or section.startswith("webServer."):
                sub = section[len("webServer.") :] if section != "webServer" else ""
                full = "webServer" + ("." + sub if sub else "") + "." + key
                out[full] = value
    return out


def _api_base_from_frps_conf(conf_file: str) -> tuple:
    """从 frps 配置文件推导 (api_url, user, password)。"""
    scalars = parse_frps_toml_scalars(conf_file)
    if not scalars.get("webServer.port"):
        raise ConfigError(
            f"frps 配置文件 {conf_file} 中没有 webServer.port，"
            "frps 未开启 dashboard API"
        )
    if not scalars.get("webServer.user") or not scalars.get("webServer.password"):
        raise ConfigError(
            f"frps 配置文件 {conf_file} 中没有 webServer.user/password"
        )
    addr = scalars.get("webServer.addr", "127.0.0.1") or "127.0.0.1"
    if addr in ("0.0.0.0", "::", "[::]"):
        addr = "127.0.0.1"
    scheme = "https" if scalars.get("webServer.tls.certFile") else "http"
    api_url = f"{scheme}://{addr}:{scalars['webServer.port']}"
    return api_url, scalars["webServer.user"], scalars["webServer.password"]


def discover_frps_service_name(conf_file: str, preferred: str = "") -> str:
    """猜测 frps 的 systemd 服务名。"""
    if preferred:
        return preferred
    if conf_file:
        stem = Path(conf_file).stem
        if Path(f"/etc/systemd/system/{stem}.service").exists():
            return stem
    matches = []
    sysd = Path("/etc/systemd/system")
    if sysd.is_dir():
        for p in sorted(sysd.glob("frps_*.service")):
            matches.append(p.stem)
    if len(matches) == 1:
        return matches[0]
    if conf_file:
        stem = Path(conf_file).stem
        if stem in matches:
            return stem
    return matches[0] if matches else ""


def build_config(conf_path: str, overrides: dict | None = None) -> dict:
    """读取 manage.conf 并推导最终运行配置。"""
    raw_values, accounts = parse_conf_file(conf_path)
    cfg = dict(DEFAULT_CONFIG)
    cfg.update(raw_values)
    if overrides:
        cfg.update({k: str(v) for k, v in overrides.items()})

    for key in INT_KEYS:
        cfg[key] = _as_int(key, cfg[key], DEFAULT_CONFIG[key])
    for key in FLOAT_KEYS:
        cfg[key] = _as_float(cfg[key], DEFAULT_CONFIG[key])
    for key in BOOL_KEYS:
        cfg[key] = _as_bool(cfg[key], DEFAULT_CONFIG[key])

    cfg["ACCOUNTS"] = accounts  # 保留兼容：未来如需面板自有账号仍可扩展
    if not cfg.get("FRPS_API_URL") and not cfg.get("FRPS_API_USER"):
        pass  # 登录时直接用用户输入的 frps webServer 账号校验

    cfg["FRPS_CONFIG_FILE"] = discover_frps_config_file(cfg.get("FRPS_CONFIG_FILE"))
    api_url, api_user, api_pass = "", "", ""
    try:
        api_url, api_user, api_pass = _api_base_from_frps_conf(
            cfg.get("FRPS_CONFIG_FILE", "")
        )
    except ConfigError as exc:
        # 允许用户在 manage.conf 中直接覆盖 FRPS_API_URL / USER / PASSWORD
        if not cfg.get("FRPS_API_URL"):
            raise ConfigError(str(exc) + "\n也可以在 manage.conf 中用 FRPS_API_URL / "
                              "FRPS_API_USER / FRPS_API_PASSWORD 手动指定")
    if cfg.get("FRPS_API_URL"):
        cfg["FRPS_API_URL"] = cfg["FRPS_API_URL"].rstrip("/")
    else:
        cfg["FRPS_API_URL"] = api_url
    if cfg.get("FRPS_API_USER"):
        cfg["FRPS_API_USER"] = cfg["FRPS_API_USER"]
    else:
        cfg["FRPS_API_USER"] = api_user
    if cfg.get("FRPS_API_PASSWORD"):
        cfg["FRPS_API_PASSWORD"] = cfg["FRPS_API_PASSWORD"]
    else:
        cfg["FRPS_API_PASSWORD"] = api_pass

    cfg["FRPS_SERVICE_NAME"] = discover_frps_service_name(
        cfg.get("FRPS_CONFIG_FILE", ""), cfg.get("FRPS_SERVICE_NAME", "")
    )

    # 状态目录：默认 /var/lib/frp-manage，无权限时回退到仓库 .state
    state_dir = cfg.get("STATE_DIR", "")
    try:
        Path(state_dir).mkdir(parents=True, exist_ok=True)
        probe = os.path.join(state_dir, ".probe")
        with open(probe, "w", encoding="utf-8") as fh:
            fh.write("ok")
        os.unlink(probe)
    except OSError:
        fallback = os.path.join(os.path.dirname(os.path.abspath(conf_path)), ".state")
        Path(fallback).mkdir(parents=True, exist_ok=True)
        state_dir = fallback
    try:
        os.chmod(state_dir, 0o700)
    except OSError:
        pass
    cfg["STATE_DIR"] = state_dir
    cfg["DB_PATH"] = os.path.join(state_dir, "manage.db")
    cfg["CONF_DIR"] = os.path.dirname(os.path.abspath(conf_path))
    cfg["CONF_FILE"] = os.path.abspath(conf_path)
    return cfg


def _toml_quote(value) -> str:
    """把字符串转成合法的 TOML 基础字符串。"""
    text = str(value)
    out = []
    for ch in text:
        if ch == "\\":
            out.append("\\\\")
        elif ch == '"':
            out.append('\\"')
        elif ch == "\n":
            out.append("\\n")
        elif ch == "\r":
            out.append("\\r")
        elif ch == "\t":
            out.append("\\t")
        elif ord(ch) < 0x20:
            out.append("\\u%04x" % ord(ch))
        else:
            out.append(ch)
    return '"' + "".join(out) + '"'


def hash_password(password: str, iterations: int = PBKDF2_ITERATIONS) -> str:
    """返回 pbkdf2_sha256$迭代次数$盐$摘要。"""
    salt = secrets.token_bytes(16)
    dk = hashlib.pbkdf2_hmac(
        "sha256", password.encode("utf-8"), salt, iterations
    )
    return "$".join(
        [
            "pbkdf2_sha256",
            str(iterations),
            base64.b64encode(salt).decode("ascii"),
            base64.b64encode(dk).decode("ascii"),
        ]
    )


def verify_password(password: str, stored: str) -> bool:
    """常量时间比较，支持 pbkdf2_sha256。"""
    try:
        algo, iters, salt_b64, hash_b64 = stored.split("$", 3)
        if algo != "pbkdf2_sha256":
            return False
        salt = base64.b64decode(salt_b64)
        expected = base64.b64decode(hash_b64)
        actual = hashlib.pbkdf2_hmac(
            "sha256", password.encode("utf-8"), salt, int(iters)
        )
        return hmac.compare_digest(actual, expected)
    except (ValueError, TypeError):
        return False


def _sha256_hex(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


class Store:
    """SQLite 存储：登录尝试、会话、审计日志。"""

    SCHEMA = """
    CREATE TABLE IF NOT EXISTS login_attempts (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        username TEXT NOT NULL,
        ip TEXT NOT NULL,
        success INTEGER NOT NULL DEFAULT 0,
        ts REAL NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_login_lookup
        ON login_attempts (ip, username, ts);

    CREATE TABLE IF NOT EXISTS sessions (
        token_hash TEXT PRIMARY KEY,
        username TEXT NOT NULL,
        csrf TEXT NOT NULL,
        created REAL NOT NULL,
        expires REAL NOT NULL
    );

    CREATE TABLE IF NOT EXISTS audit_log (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        ts REAL NOT NULL,
        username TEXT,
        ip TEXT,
        event TEXT NOT NULL,
        detail TEXT
    );
    CREATE INDEX IF NOT EXISTS idx_audit_ts ON audit_log (ts);
    """

    def __init__(self, db_path: str):
        self.db_path = db_path
        self._lock = threading.RLock()
        self._conn = sqlite3.connect(db_path, check_same_thread=False)
        self._conn.row_factory = sqlite3.Row
        with self._conn:
            self._conn.execute("PRAGMA journal_mode=WAL")
            self._conn.execute("PRAGMA busy_timeout=10000")
            self._conn.executescript(self.SCHEMA)
        try:
            os.chmod(db_path, 0o600)
        except OSError:
            pass

    def close(self):
        with self._lock:
            try:
                self._conn.close()
            except sqlite3.Error:
                pass

    # ---------- 登录尝试 ----------
    def record_login_attempt(self, username, ip, success):
        with self._lock:
            with self._conn:
                self._conn.execute(
                    "INSERT INTO login_attempts (username, ip, success, ts) "
                    "VALUES (?, ?, ?, ?)",
                    (username, ip, 1 if success else 0, time.time()),
                )

    def failures_for(self, username, ip, since):
        with self._lock:
            rows = self._conn.execute(
                "SELECT ts FROM login_attempts "
                "WHERE success=0 AND username=? AND ip=? AND ts>=? "
                "ORDER BY ts",
                (username, ip, since),
            ).fetchall()
        return [r["ts"] for r in rows]

    def failures_for_ip(self, ip, since):
        with self._lock:
            rows = self._conn.execute(
                "SELECT ts FROM login_attempts "
                "WHERE success=0 AND ip=? AND ts>=? ORDER BY ts",
                (ip, since),
            ).fetchall()
        return [r["ts"] for r in rows]

    def clear_failures(self, username, ip):
        with self._lock:
            with self._conn:
                self._conn.execute(
                    "DELETE FROM login_attempts WHERE success=0 "
                    "AND username=? AND ip=?",
                    (username, ip),
                )

    def clear_failures_for_ip(self, ip):
        with self._lock:
            with self._conn:
                self._conn.execute(
                    "DELETE FROM login_attempts WHERE success=0 AND ip=?",
                    (ip,),
                )

    def prune_login_attempts(self, before):
        with self._lock:
            with self._conn:
                self._conn.execute(
                    "DELETE FROM login_attempts WHERE ts < ?", (before,)
                )

    # ---------- 会话 ----------
    def create_session(self, username, ttl_hours):
        token = secrets.token_urlsafe(32)
        csrf = secrets.token_urlsafe(32)
        now = time.time()
        with self._lock:
            with self._conn:
                self._conn.execute(
                    "INSERT INTO sessions (token_hash, username, csrf, created, expires) "
                    "VALUES (?, ?, ?, ?, ?)",
                    (
                        _sha256_hex(token),
                        username,
                        csrf,
                        now,
                        now + ttl_hours * 3600,
                    ),
                )
        return token, csrf

    def get_session(self, token):
        if not token:
            return None
        with self._lock:
            row = self._conn.execute(
                "SELECT * FROM sessions WHERE token_hash=?", (_sha256_hex(token),)
            ).fetchone()
        if row is None:
            return None
        if row["expires"] < time.time():
            self.delete_session(token)
            return None
        return dict(row)

    def delete_session(self, token):
        if not token:
            return
        with self._lock:
            with self._conn:
                self._conn.execute(
                    "DELETE FROM sessions WHERE token_hash=?", (_sha256_hex(token),)
                )

    def delete_expired_sessions(self):
        with self._lock:
            with self._conn:
                self._conn.execute(
                    "DELETE FROM sessions WHERE expires < ?", (time.time(),)
                )

    def count_sessions(self):
        with self._lock:
            row = self._conn.execute(
                "SELECT COUNT(*) AS c FROM sessions WHERE expires > ?",
                (time.time(),),
            ).fetchone()
        return row["c"] if row else 0

    # ---------- 审计 ----------
    def audit(self, username, ip, event, detail=""):
        try:
            with self._lock:
                with self._conn:
                    self._conn.execute(
                        "INSERT INTO audit_log (ts, username, ip, event, detail) "
                        "VALUES (?, ?, ?, ?, ?)",
                        (time.time(), username, ip, event, detail),
                    )
        except sqlite3.Error:
            pass

    def recent_audit(self, limit=50):
        with self._lock:
            rows = self._conn.execute(
                "SELECT * FROM audit_log ORDER BY id DESC LIMIT ?", (int(limit),)
            ).fetchall()
        return [dict(r) for r in rows]


class LoginRateLimiter:
    """基于 Store 的暴力破解防护（带并发占位，防止并行请求绕过阈值）。"""

    def __init__(self, cfg: dict, store: Store):
        self.cfg = cfg
        self.store = store
        self._pending = {}
        self._pending_ip = {}
        self._gate_lock = threading.Lock()

    def _window_seconds(self):
        return self.cfg["LOGIN_FAILURE_WINDOW_MINUTES"] * 60

    def _lockout_seconds(self):
        return self.cfg["LOGIN_LOCKOUT_MINUTES"] * 60

    def reserve(self, username, ip):
        """尝试占一个登录名额。

        占位会把“正在校验的请求”也计入失败额度，避免攻击者并发发起大量
        请求时，在失败落库之前全部通过 check 的竞态。返回 (allowed,
        locked_seconds)；allowed=True 时调用方必须在请求结束后调用 release()。
        """
        now = time.time()
        since = now - self._window_seconds()
        max_fail = max(1, self.cfg["LOGIN_MAX_FAILURES"])

        # 锁顺序统一为 store._lock -> _gate_lock，避免与
        # record_login_attempt（store 锁）后 release（gate 锁）形成死锁。
        with self.store._lock:
            with self._gate_lock:
                user_key = (username, ip)
                user_fails = self.store.failures_for(username, ip, since)
                user_pending = self._pending.get(user_key, 0)
                if len(user_fails) + user_pending >= max_fail:
                    until = (user_fails or [now])[-1] + self._lockout_seconds()
                    if now < until:
                        return False, until - now
                    # 锁定已到期：清掉旧失败计数，让下一次登录重新开始计算
                    self.store.clear_failures(username, ip)
                    user_fails = []

                ip_fails = self.store.failures_for_ip(ip, since)
                ip_pending = self._pending_ip.get(ip, 0)
                ip_limit = max_fail * 3
                if len(ip_fails) + ip_pending >= ip_limit:
                    until = (ip_fails or [now])[-1] + self._lockout_seconds()
                    if now < until:
                        return False, until - now
                    self.store.clear_failures_for_ip(ip)
                    ip_fails = []

                self._pending[user_key] = user_pending + 1
                self._pending_ip[ip] = ip_pending + 1
        return True, 0

    def release(self, username, ip):
        """释放 reserve() 占用的名额。"""
        with self._gate_lock:
            user_key = (username, ip)
            left = self._pending.get(user_key, 0) - 1
            if left > 0:
                self._pending[user_key] = left
            else:
                self._pending.pop(user_key, None)

            left_ip = self._pending_ip.get(ip, 0) - 1
            if left_ip > 0:
                self._pending_ip[ip] = left_ip
            else:
                self._pending_ip.pop(ip, None)

    def remaining_attempts(self, username, ip):
        since = time.time() - self._window_seconds()
        fails = self.store.failures_for(username, ip, since)
        pending = self._pending.get((username, ip), 0)
        return max(0, self.cfg["LOGIN_MAX_FAILURES"] - len(fails) - pending)

    def locked_seconds(self, username, ip):
        """返回当前剩余锁定秒数（未锁定返回 0）。"""
        now = time.time()
        since = now - self._window_seconds()
        max_fail = max(1, self.cfg["LOGIN_MAX_FAILURES"])
        with self.store._lock:
            with self._gate_lock:
                user_fails = self.store.failures_for(username, ip, since)
                if len(user_fails) >= max_fail:
                    until = user_fails[-1] + self._lockout_seconds()
                    if now < until:
                        return until - now
                ip_fails = self.store.failures_for_ip(ip, since)
                ip_limit = max_fail * 3
                if len(ip_fails) >= ip_limit:
                    until = ip_fails[-1] + self._lockout_seconds()
                    if now < until:
                        return until - now
        return 0


def _subprocess_run(cmd, timeout=25):
    try:
        proc = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=timeout,
            stdin=subprocess.DEVNULL,
        )
        return proc.returncode, proc.stdout.strip(), proc.stderr.strip()
    except subprocess.TimeoutExpired:
        return 124, "", "timeout"
    except FileNotFoundError:
        return 127, "", f"命令不存在: {cmd[0]}"
    except Exception as exc:  # noqa: BLE001
        return 1, "", str(exc)


class FrpsApi:
    """frps dashboard API 客户端（Basic Auth）。"""

    def __init__(self, cfg: dict):
        self.base_url = cfg["FRPS_API_URL"]
        self.user = cfg["FRPS_API_USER"]
        self.password = cfg["FRPS_API_PASSWORD"]
        self.timeout = cfg["REQUEST_TIMEOUT_SECONDS"]
        self._lock = threading.Lock()

    def _auth_header(self, user=None, password=None):
        user = self.user if user is None else user
        password = self.password if password is None else password
        return "Basic " + base64.b64encode(
            f"{user}:{password}".encode("utf-8")
        ).decode("ascii")

    def ensure_credentials(self, user, password):
        """把成功登录所用的 frps webServer 账号记入运行时（仅内存）。"""
        with self._lock:
            self.user = user
            self.password = password

    def verify_credentials(self, user, password):
        """用指定账号请求 frps API，验证是否有效。返回 (ok, version)。"""
        req = urllib.request.Request(
            self.base_url + "/api/v2/system/info", method="GET"
        )
        req.add_header("Authorization", self._auth_header(user, password))
        req.add_header("Accept", "application/json")
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as resp:
                raw = resp.read()
        except urllib.error.HTTPError as exc:
            if exc.code == 401:
                return False, ""
            raise ConnectionError(
                f"frps API 返回 HTTP {exc.code}: {exc.reason}"
            ) from exc
        except urllib.error.URLError as exc:
            raise ConnectionError(f"无法连接 frps API: {exc.reason}") from exc
        except OSError as exc:
            raise ConnectionError(f"无法连接 frps API: {exc}") from exc
        try:
            payload = json.loads(raw or b"{}")
            if isinstance(payload, dict) and "data" in payload:
                payload = payload.get("data") or {}
            return True, str(payload.get("version", ""))
        except (ValueError, TypeError):
            return True, ""

    def request(self, method, sub_path, query="", body=None):
        """对 frps API 发起请求，返回 (status, headers, raw_body)。"""
        with self._lock:
            auth = self._auth_header()
        url = self.base_url + "/" + sub_path.lstrip("/")
        if query:
            url += "?" + query
        data = body if body is not None else None
        req = urllib.request.Request(url, data=data, method=method.upper())
        req.add_header("Authorization", auth)
        req.add_header("Accept", "application/json")
        if data is not None:
            req.add_header("Content-Type", "application/json")
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as resp:
                raw = resp.read()
                return resp.status, dict(resp.headers), raw
        except urllib.error.HTTPError as exc:
            return exc.code, dict(exc.headers), exc.read()
        except urllib.error.URLError as exc:
            raise ConnectionError(f"无法连接 frps API ({url}): {exc.reason}") from exc
        except OSError as exc:
            raise ConnectionError(f"无法连接 frps API ({url}): {exc}") from exc


# ---------- frpc 配置生成器 ----------


def _find_template_file(cfg: dict) -> str:
    """优先使用仓库里的 frp_template.toml，其次 frps 安装配置。"""
    preferred = cfg.get("FRP_TEMPLATE_FILE", "")
    if preferred:
        if os.path.exists(preferred):
            return preferred
        return ""
    cand = os.path.join(cfg.get("CONF_DIR", ""), "..", "frp_template.toml")
    if os.path.exists(cand):
        return os.path.realpath(cand)
    for p in _frps_config_candidates():
        return p
    return ""


def _read_toml_section(path: str, section: str):
    """粗略读取 TOML 中某一节的 key=value（不处理内嵌表/数组）。"""
    out = {}
    if not path or not os.path.exists(path):
        return out

    def flatten(node, prefix, sink):
        for key, value in node.items():
            full = f"{prefix}.{key}" if prefix else key
            if isinstance(value, dict):
                flatten(value, full, sink)
            elif isinstance(value, (str, int, float, bool)) or value is None:
                sink[full] = value

    try:
        if tomllib is not None:
            with open(path, "rb") as fh:
                data = tomllib.load(fh)
            node = data
            if section:
                for part in section.split("."):
                    if not isinstance(node, dict):
                        return {}
                    node = node.get(part, {})
            if isinstance(node, dict):
                flatten(node, "" if section else "", out)
        else:
            return out
    except (ValueError, OSError, TypeError):
        # frp 模板里含 ${serverPort} 等占位符，tomllib 解析不了时退回正则
        active = False
        with open(path, "r", encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if line.startswith("["):
                    active = line == f"[{section}]"
                    continue
                if not active or not line or line.startswith("#"):
                    continue
                m = re.match(r"^([A-Za-z_][A-Za-z0-9_.]*)\s*=\s*(.*)$", line)
                if m:
                    out[m.group(1)] = _clean_value(m.group(2))
    return out


def frpc_generator_options(cfg: dict) -> dict:
    """返回生成器默认值（服务端地址/端口/token 等）。"""
    tpl_file = _find_template_file(cfg)
    token, server_port, server_addr, user = "", "", "", ""
    if tpl_file:
        common = _read_toml_section(tpl_file, "common")
        frpc_sec = _read_toml_section(tpl_file, "frpc")
        token = str(common.get("token", "") or "")
        server_port = str(common.get("serverPort", "") or "")
        if not server_port:
            server_port = str(frpc_sec.get("serverPort", "") or "")
        server_addr = str(frpc_sec.get("serverAddr", "") or "")
        user = str(frpc_sec.get("user", "") or "")
    if not server_addr and cfg.get("FRPS_API_URL"):
        # 无法知道公网地址，留给用户填写
        pass
    if not token or not server_port:
        frps_sec = _read_toml_section(
            cfg.get("FRPS_CONFIG_FILE", ""), "frps"
        )
        if not frps_sec:
            frps_sec = _read_toml_section(cfg.get("FRPS_CONFIG_FILE", ""), "")
        token = str(
            frps_sec.get("auth.token")
            or frps_sec.get("token")
            or token
            or ""
        )
        server_port = str(frps_sec.get("bindPort") or server_port or "")
    return {
        "templateFile": tpl_file,
        "serverAddr": server_addr,
        "serverPort": server_port,
        "token": token,
        "user": user,
        "version": cfg.get("FRP_GEN_VERSION", "0.71.0"),
        "arch": cfg.get("FRP_GEN_ARCH", "linux_amd64"),
    }


def _render_proxy(proxy: dict) -> list:
    lines = []
    lines.append("[[proxies]]")
    name = str(proxy.get("name", "")).strip()
    ptype = str(proxy.get("type", "tcp")).strip().lower()
    if name:
        lines.append(f'name = {_toml_quote(name)}')
    lines.append(f'type = {_toml_quote(ptype)}')
    local_ip = str(proxy.get("localIP", "")).strip()
    if local_ip:
        lines.append(f'localIP = {_toml_quote(local_ip)}')
    local_port = proxy.get("localPort", "")
    if local_port not in ("", None):
        lines.append(f"localPort = {int(local_port)}")
    remote_port = proxy.get("remotePort", "")
    if remote_port not in ("", None) and ptype in ("tcp", "udp"):
        lines.append(f"remotePort = {int(remote_port)}")
    custom_domains = proxy.get("customDomains", "") or proxy.get("customDomains", [])
    if isinstance(custom_domains, str):
        custom_domains = [
            d.strip() for d in custom_domains.replace("\n", ",").split(",") if d.strip()
        ]
    if custom_domains:
        arr = ", ".join(_toml_quote(d) for d in custom_domains)
        lines.append(f"customDomains = [{arr}]")
    subdomain = str(proxy.get("subdomain", "") or "").strip()
    if subdomain:
        lines.append(f"subdomain = {_toml_quote(subdomain)}")
    return lines


def render_frpc_toml(params: dict) -> str:
    """根据表单参数生成 frpc_<user>.toml 内容。"""
    lines = [
        "# ====================================================",
        "# frpc 客户端配置（由 frp-manage 生成器生成）",
        "# 使用方法：保存为 frpc.toml 后执行",
        "#   frpc -c frpc.toml",
        "# ====================================================",
    ]
    user = str(params.get("user", "") or "").strip()
    server_addr = str(params.get("serverAddr", "") or "").strip()
    server_port = params.get("serverPort", "") or ""
    token = str(params.get("token", "") or "")
    if user:
        lines += ["", f'# user：代理名前缀，用于在 frps 面板中区分不同部署']
        lines.append(f'user = {_toml_quote(user)}')
    lines += [
        "",
        "# frps 服务器地址与端口",
        f"serverAddr = {_toml_quote(server_addr)}",
    ]
    try:
        lines.append(f"serverPort = {int(server_port)}")
    except (TypeError, ValueError):
        lines.append(f"serverPort = {_toml_quote(server_port)}")
    lines += [
        "",
        "# 连接 frps 的认证信息",
        'auth.method = "token"',
        f"auth.token = {_toml_quote(token)}",
    ]
    proxies = params.get("proxies", []) or []
    if not proxies:
        lines += [
            "",
            "# 还没有代理，请把要映射的服务按 [[proxies]] 的格式补上。",
        ]
    for proxy in proxies:
        lines.append("")
        lines.extend(_render_proxy(proxy))
    return "\n".join(lines) + "\n"


def validate_frpc_toml(text: str) -> dict:
    """校验生成的 TOML 是否可被 frpc 解析（基础必填项）。"""
    if tomllib is None:
        return {"ok": True, "errors": ["当前 Python 版本过低，无法服务端校验，请人工检查"]}
    text = text or ""
    if "${" in text:
        return {
            "ok": False,
            "errors": ["配置中仍包含未替换的 ${...} 占位符，请先替换后再使用"],
        }
    try:
        data = tomllib.loads(text)
    except tomllib.TOMLDecodeError as exc:
        return {"ok": False, "errors": [f"TOML 语法错误: {exc}"]}

    errors = []
    if not str(data.get("serverAddr", "")).strip():
        errors.append("缺少 serverAddr（frps 服务器地址）")
    try:
        int(data.get("serverPort", 0))
    except (TypeError, ValueError):
        errors.append("serverPort 必须是数字")
    token = data.get("auth", {})
    if isinstance(token, dict) and not str(token.get("token", "")).strip():
        errors.append("缺少 auth.token（连接密钥）")
    proxies = data.get("proxies", [])
    if proxies:
        for idx, p in enumerate(proxies, 1):
            if not str(p.get("name", "")).strip():
                errors.append(f"第 {idx} 个代理缺少 name")
            if not str(p.get("localIP", "")).strip():
                errors.append(f"代理 {p.get('name','?')} 缺少 localIP")
            try:
                int(p.get("localPort", 0))
            except (TypeError, ValueError):
                errors.append(f"代理 {p.get('name','?')} 的 localPort 必须是数字")
            ptype = str(p.get("type", "")).lower()
            if ptype in ("tcp", "udp"):
                try:
                    int(p.get("remotePort", 0))
                except (TypeError, ValueError):
                    errors.append(
                        f"代理 {p.get('name','?')} 的 remotePort 必须是数字"
                    )
            elif ptype in ("http", "https", "tcpmux"):
                if not p.get("customDomains") and not str(p.get("subdomain", "")).strip():
                    errors.append(
                        f"{ptype} 代理 {p.get('name','?')} 需要 customDomains 或 subdomain"
                    )
    return {"ok": not errors, "errors": errors}


def _format_time(ts):
    if not ts:
        return "-"
    try:
        return time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(float(ts)))
    except (ValueError, TypeError):
        return "-"


def _json_dumps(obj):
    return json.dumps(obj, ensure_ascii=False).encode("utf-8")


class PanelApp:
    """组装配置、存储、限流与 frps 客户端，供 HTTP Handler 使用。"""

    def __init__(self, cfg: dict):
        self.cfg = cfg
        self.store = Store(cfg["DB_PATH"])
        self.limiter = LoginRateLimiter(cfg, self.store)
        self.frps = FrpsApi(cfg)
        self.web_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), "web")
        self.start_time = time.time()

    # ---------- 面板会话 ----------
    def create_session(self, username):
        token, csrf = self.store.create_session(
            username, self.cfg["SESSION_TTL_HOURS"]
        )
        return token, csrf

    def check_login(self, username, password, ip):
        """
        执行登录校验：直接使用 frps webServer 用户名/密码验证。
        返回 (ok, payload, http_code)。
        """
        username = (username or "").strip()
        if not username or password is None:
            # 空账号也走限流与失败计数，避免被用来探测/刷请求
            allowed, locked_secs = self.limiter.reserve(username, ip)
            if not allowed:
                self.store.audit(
                    username, ip, "login_locked", "empty credentials denied"
                )
                return False, {
                    "error": f"失败次数过多，请在 {max(1, round(locked_secs / 60, 1))} 分钟后重试",
                    "locked": True,
                    "retryAfterSeconds": int(locked_secs) + 1,
                }, 429
            self.store.record_login_attempt(username, ip, False)
            self.limiter.release(username, ip)
            self.store.audit(username, ip, "login_failed", "empty credentials")
            time.sleep(min(max(float(self.cfg["LOGIN_DELAY_SECONDS"]), 0), 2.0))
            return False, {"error": "用户名或密码错误"}, 401

        allowed, locked_secs = self.limiter.reserve(username, ip)
        if not allowed:
            self.store.audit(
                username, ip, "login_locked",
                f"denied, locked {max(1, round(locked_secs / 60, 1))} min",
            )
            return False, {
                "error": f"失败次数过多，请在 {max(1, round(locked_secs / 60, 1))} 分钟后重试",
                "locked": True,
                "retryAfterSeconds": int(locked_secs) + 1,
            }, 429

        try:
            valid, _version = self.frps.verify_credentials(
                username, password or ""
            )
        except ConnectionError as exc:
            # frps 不可达时不算密码错误，避免用户被无谓锁定
            self.limiter.release(username, ip)
            self.store.audit(username, ip, "login_failed", f"frps unreachable: {exc}")
            return False, {
                "error": f"无法连接 frps dashboard API：{exc}",
                "frpsDown": True,
            }, 503

        if valid:
            self.store.clear_failures(username, ip)
            self.limiter.release(username, ip)
            self.store.audit(username, ip, "login_success")
            # 会话内后续代理 frps API 使用该账号（frps 只有一个 webServer 账号）
            self.frps.ensure_credentials(username, password or "")
            return True, {
                "username": username,
            }, 200

        # 校验失败：记录 + 延时，削弱爆破
        self.store.record_login_attempt(username, ip, False)
        self.limiter.release(username, ip)
        self.store.audit(username, ip, "login_failed")
        delay = min(max(float(self.cfg["LOGIN_DELAY_SECONDS"]), 0), 2.0)
        if delay > 0:
            time.sleep(delay)
        remaining = self.limiter.remaining_attempts(username, ip)
        locked_secs = self.limiter.locked_seconds(username, ip)
        if remaining <= 0 and locked_secs > 0:
            return False, {
                "error": "失败次数过多，登录已临时锁定",
                "locked": True,
                "retryAfterSeconds": int(locked_secs) + 1,
            }, 429
        return False, {
            "error": "用户名或密码错误",
            "remainingAttempts": remaining,
        }, 401

    # ---------- 服务探测与控制 ----------
    def service_info(self):
        """返回 frps 进程 / systemd 状态信息。"""
        service_name = self.cfg.get("FRPS_SERVICE_NAME", "")
        service = {
            "name": service_name,
            "systemdAvailable": False,
            "active": "",
            "enabled": "",
            "message": "",
        }
        systemd = _subprocess_run(
            ["systemctl", "is-system-running", "--no-pager"]
        )
        if systemd[0] in (0, 1):
            service["systemdAvailable"] = True
        if service_name:
            rc_active, out_active, _ = _subprocess_run(
                ["systemctl", "is-active", "--", service_name]
            )
            service["active"] = out_active.strip() if rc_active in (0, 1) else ""
            rc_en, out_en, _ = _subprocess_run(
                ["systemctl", "is-enabled", "--", service_name]
            )
            service["enabled"] = out_en.strip() if rc_en in (0, 1) else ""

        pids = []
        rc, out, _ = _subprocess_run(["pgrep", "-x", "frps"])
        if rc == 0:
            pids = [p.strip() for p in out.splitlines() if p.strip()]

        frps_api_ok = False
        version = ""
        try:
            status, _, raw = self.frps.request(
                "GET", "api/v2/system/info", "pageSize=1"
            )
            if status == 200:
                frps_api_ok = True
                try:
                    payload = json.loads(raw)
                    if isinstance(payload, dict) and "data" in payload:
                        payload = payload.get("data") or {}
                    version = payload.get("version", "")
                except (ValueError, TypeError):
                    version = ""
        except ConnectionError:
            pass

        return {
            "frpsConfigFile": self.cfg.get("FRPS_CONFIG_FILE", ""),
            "frpsApiUrl": self.cfg["FRPS_API_URL"],
            "frpsApiReachable": frps_api_ok,
            "frpsVersion": version,
            "frpsPids": pids,
            "service": service,
            "serviceControlEnabled": self.cfg["ENABLE_SERVICE_CONTROL"],
            "panelStartTime": self.start_time,
        }

    def service_action(self, action):
        """systemd 服务控制。返回 (ok, payload)。"""
        if not self.cfg["ENABLE_SERVICE_CONTROL"]:
            return False, {
                "error": "manage.conf 中 ENABLE_SERVICE_CONTROL=false，已关闭服务控制",
            }
        service_name = self.cfg.get("FRPS_SERVICE_NAME", "")
        if not service_name:
            return False, {
                "error": "未能识别 frps systemd 服务名，可在 manage.conf 中设置 FRPS_SERVICE_NAME",
            }
        if action not in ("start", "stop", "restart"):
            return False, {"error": f"不支持的操作: {action}"}

        if os.geteuid() == 0:
            cmd = ["systemctl", action, "--", service_name]
        else:
            cmd = ["sudo", "-n", "systemctl", action, "--", service_name]
        rc, out, err = _subprocess_run(cmd, timeout=60)
        ok = rc == 0
        detail = (out + "\n" + err).strip()
        if not ok:
            if "sudo: a password is required" in err or "no tty present" in err:
                detail += "\n请以 root 运行面板，或为该用户配置免密 sudo systemctl。"
            elif "System has not been booted with systemd" in err:
                detail += "\n当前环境没有运行 systemd，无法通过 systemctl 控制服务。"
        return ok, {
            "service": service_name,
            "action": action,
            "ok": ok,
            "detail": detail,
        }


def client_ip(handler) -> str:
    """从反代头或 socket 取客户端 IP。

    只有本机回环来源（默认部署：面板 127.0.0.1 + 本机 Nginx）才信任
    X-Forwarded-For / X-Real-IP，避免面板被直接暴露到公网时，
    远端客户端通过伪造反代头绕过按 IP 的暴力破解限制。
    """
    peer = handler.client_address[0]
    try:
        peer_loopback = ipaddress.ip_address(peer).is_loopback
    except ValueError:
        peer_loopback = False
    xff = handler.headers.get("X-Forwarded-For")
    if peer_loopback and xff:
        first = xff.split(",")[0].strip()
        if first:
            return first
    xrip = handler.headers.get("X-Real-IP")
    if peer_loopback and xrip:
        return xrip.strip()
    return peer


def is_https_request(handler) -> bool:
    peer = handler.client_address[0]
    try:
        peer_loopback = ipaddress.ip_address(peer).is_loopback
    except ValueError:
        peer_loopback = False
    if peer_loopback:
        proto = handler.headers.get("X-Forwarded-Proto", "").lower()
        if proto in ("https", "wss"):
            return True
    return False


def _send(handler, code: int, body: bytes, content_type="application/json", extra=None):
    handler.send_response(code)
    handler.send_header("Content-Type", content_type)
    handler.send_header("Content-Length", str(len(body)))
    handler.send_header("Cache-Control", "no-store")
    handler.send_header("X-Content-Type-Options", "nosniff")
    handler.send_header("X-Frame-Options", "DENY")
    for key, value in (extra or {}).items():
        handler.send_header(key, value)
    handler.end_headers()
    if handler.command != "HEAD":
        handler.wfile.write(body)


class PanelHandler(BaseHTTPRequestHandler):
    server_version = f"{APP_NAME}/{APP_VERSION}"
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):  # 静默默认访问日志
        return

    # ---------- 工具 ----------
    @property
    def app(self) -> PanelApp:
        return self.server.app  # type: ignore[attr-defined]

    def _read_body(self):
        length = self.headers.get("Content-Length")
        if not length:
            return b""
        try:
            length = int(length)
        except ValueError:
            return b""
        if length > MAX_BODY_SIZE:
            return b""
        return self.rfile.read(length)

    def _json(self, code, obj, extra=None):
        _send(self, code, _json_dumps(obj), extra=extra)

    def _static(self, rel_path):
        base = os.path.realpath(self.app.web_dir)
        target = os.path.realpath(os.path.join(base, rel_path))
        if not target.startswith(base + os.sep):
            self._json(403, {"error": "forbidden"})
            return
        if not os.path.isfile(target):
            self._json(404, {"error": "not found"})
            return
        try:
            with open(target, "rb") as fh:
                body = fh.read()
        except OSError:
            self._json(500, {"error": "read failed"})
            return
        ctype = mimetypes.guess_type(target)[0] or "application/octet-stream"
        cache = "no-cache" if rel_path in ("index.html", "app.js", "style.css") else "max-age=3600"
        handler_extra = {"Cache-Control": cache}
        _send(self, 200, body, content_type=ctype, extra=handler_extra)

    def _session_from_cookie(self):
        raw = self.headers.get("Cookie", "")
        for part in raw.split(";"):
            part = part.strip()
            if part.startswith(COOKIE_NAME + "="):
                return part[len(COOKIE_NAME) + 1 :].strip()
        return None

    def _require_session(self):
        token = self._session_from_cookie()
        session = self.app.store.get_session(token) if token else None
        if session is None:
            self._json(401, {"error": "未登录或会话已过期"})
            return None
        return session

    def _require_csrf(self, session):
        token = self.headers.get("X-CSRF-Token", "")
        if not token or not hmac.compare_digest(
            str(token), str(session.get("csrf", ""))
        ):
            self._json(403, {"error": "CSRF 校验失败，请刷新页面重试"})
            return False
        return True

    # ---------- 路由 ----------
    def _handle(self):
        parsed = urllib.parse.urlsplit(self.path)
        path = parsed.path
        query = parsed.query
        method = self.command

        if method == "GET":
            if path == "/healthz":
                self._json(200, {"status": "ok"})
                return
            if path in ("/", "/index.html"):
                self._static("index.html")
                return
            if path.startswith("/static/"):
                self._static(path[len("/static/") :])
                return
            if path == "/api/me":
                token = self._session_from_cookie()
                session = self.app.store.get_session(token) if token else None
                if not session:
                    self._json(401, {"authenticated": False, "error": "未登录"})
                    return
                self._json(
                    200,
                    {
                        "authenticated": True,
                        "username": session["username"],
                        "csrf": session["csrf"],
                        "expiresAt": session["expires"],
                    },
                )
                return
            if path == "/api/audit":
                session = self._require_session()
                if session is None:
                    return
                try:
                    limit = min(max(int(query and query.split("limit=")[-1].split("&")[0]), 1), 500)
                except (ValueError, IndexError):
                    limit = 50
                rows = self.app.store.recent_audit(limit)
                for row in rows:
                    row["timeText"] = _format_time(row.get("ts"))
                self._json(200, {"items": rows})
                return
            if path == "/api/service/status":
                session = self._require_session()
                if session is None:
                    return
                info = self.app.service_info()
                info["ip"] = client_ip(self)
                self._json(200, info)
                return
            if path == "/api/frpc-template/options":
                session = self._require_session()
                if session is None:
                    return
                self._json(200, frpc_generator_options(self.app.cfg))
                return
            if path.startswith("/api/frps/"):
                session = self._require_session()
                if session is None:
                    return
                self._proxy_frps(method, path, query, b"")
                return

        elif method == "POST":
            if path == "/api/login":
                raw = self._read_body()
                try:
                    payload = json.loads(raw or b"{}")
                except ValueError:
                    payload = {}
                username = payload.get("username", "")
                password = payload.get("password", "")
                ip = client_ip(self)
                ok, body, code = self.app.check_login(username, password, ip)
                extra = {}
                if code == 200:
                    token, csrf = self.app.store.create_session(
                        username, self.app.cfg["SESSION_TTL_HOURS"]
                    )
                    body["csrf"] = csrf
                    body["expiresAt"] = (
                        time.time() + self.app.cfg["SESSION_TTL_HOURS"] * 3600
                    )
                    secure = "; Secure" if is_https_request(self) else ""
                    extra = {
                        "Set-Cookie": (
                            f"{COOKIE_NAME}={token}; Path=/; HttpOnly; "
                            f"SameSite=Lax; Max-Age="
                            f"{int(self.app.cfg['SESSION_TTL_HOURS'] * 3600)}{secure}"
                        )
                    }
                if code == 429:
                    extra["Retry-After"] = str(body.get("retryAfterSeconds", 60))
                self._json(code, body, extra=extra)
                return
            if path == "/api/logout":
                token = self._session_from_cookie()
                if token:
                    self.app.store.delete_session(token)
                extra = {
                    "Set-Cookie": (
                        f"{COOKIE_NAME}=; Path=/; HttpOnly; SameSite=Lax; Max-Age=0"
                    )
                }
                self._json(200, {"ok": True}, extra=extra)
                return
            if path == "/api/frpc-template/render":
                session = self._require_session()
                if session is None:
                    return
                if not self._require_csrf(session):
                    return
                raw = self._read_body()
                try:
                    payload = json.loads(raw or b"{}")
                except ValueError:
                    payload = {}
                text = render_frpc_toml(payload)
                result = validate_frpc_toml(text)
                self.app.store.audit(
                    session["username"],
                    client_ip(self),
                    "frpc_render",
                    f"proxies={len(payload.get('proxies') or [])}",
                )
                self._json(200, {"text": text, **result})
                return
            if path == "/api/frpc-template/validate":
                session = self._require_session()
                if session is None:
                    return
                if not self._require_csrf(session):
                    return
                raw = self._read_body()
                try:
                    payload = json.loads(raw or b"{}")
                except ValueError:
                    payload = {}
                self._json(200, validate_frpc_toml(str(payload.get("text", ""))))
                return
            if path.startswith("/api/service/"):
                session = self._require_session()
                if session is None:
                    return
                if not self._require_csrf(session):
                    return
                action = path[len("/api/service/") :]
                ok, body = self.app.service_action(action)
                ip = client_ip(self)
                self.app.store.audit(
                    session["username"],
                    ip,
                    f"service_{action}",
                    body.get("detail", "")[:500],
                )
                self._json(200 if ok else 403, body)
                return
            if path.startswith("/api/frps/"):
                session = self._require_session()
                if session is None:
                    return
                if not self._require_csrf(session):
                    return
                body = self._read_body()
                self._proxy_frps(method, path, query, body)
                return

        elif method in ("DELETE", "PUT", "PATCH"):
            if path.startswith("/api/frps/"):
                session = self._require_session()
                if session is None:
                    return
                if not self._require_csrf(session):
                    return
                body = self._read_body()
                self._proxy_frps(method, path, query, body)
                return

        self._json(404, {"error": f"接口不存在: {method} {path}"})

    # ---------- frps API 反代 ----------
    def _proxy_frps(self, method, path, query, body):
        sub_path = path[len("/api/frps/") :]
        if not sub_path:
            self._json(400, {"error": "缺少 frps API 路径"})
            return
        # 面板路由形如 /api/frps/v2/system/info，
        # 自动补上 frps API 要求的 /api 前缀，前端调用更简洁
        if not sub_path.startswith("api/"):
            sub_path = "api/" + sub_path
        if not re.fullmatch(r"[A-Za-z0-9._~%/:-]+", sub_path):
            self._json(400, {"error": "非法的 frps API 路径"})
            return
        segments = sub_path.split("/")
        if ".." in segments:
            self._json(400, {"error": "非法的 frps API 路径"})
            return
        try:
            status, headers, raw = self.app.frps.request(
                method, sub_path, query, body if body else None
            )
        except ConnectionError as exc:
            self._json(502, {"error": str(exc)})
            return
        if raw:
            ctype = headers.get("Content-Type", "application/json").split(";")[0]
        else:
            ctype = "application/json"
        if status >= 400 and raw:
            # 尝试把 frps 的错误包装成统一格式，但保留原状态码
            try:
                parsed = json.loads(raw)
                if isinstance(parsed, dict) and "msg" in parsed:
                    parsed["upstream"] = True
                    raw = _json_dumps(parsed)
            except ValueError:
                pass
        _send(self, status, raw or b"{}", content_type=ctype)

    # ---------- 入口 ----------
    def do_GET(self):
        self._handle()

    def do_POST(self):
        self._handle()

    def do_DELETE(self):
        self._handle()

    def do_PUT(self):
        self._handle()

    def do_PATCH(self):
        self._handle()

    def do_HEAD(self):
        self._handle()


class PanelServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, addr, app):
        super().__init__(addr, PanelHandler)
        self.app = app


def make_server(cfg: dict, host=None, port=None):
    if host is not None:
        cfg["PANEL_LISTEN_ADDR"] = host
    if port is not None:
        cfg["PANEL_LISTEN_PORT"] = int(port)
    app = PanelApp(cfg)
    server = PanelServer(
        (cfg["PANEL_LISTEN_ADDR"], cfg["PANEL_LISTEN_PORT"]), app
    )
    return server, app


def setup_logging(level=logging.INFO):
    logging.basicConfig(
        level=level,
        format="%(asctime)s [%(levelname)s] %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S",
    )


def run_forever(cfg: dict, host=None, port=None):
    setup_logging()
    server, app = make_server(cfg, host=host, port=port)
    log = logging.getLogger(APP_NAME)
    log.info(
        "面板已启动: http://%s:%d  (frps API: %s, 登录账号: frps webServer)",
        cfg["PANEL_LISTEN_ADDR"],
        cfg["PANEL_LISTEN_PORT"],
        cfg["FRPS_API_URL"],
    )
    log.info(
        "frps 配置文件: %s | systemd 服务: %s",
        cfg.get("FRPS_CONFIG_FILE") or "（未找到，请配置 FRPS_API_URL）",
        cfg.get("FRPS_SERVICE_NAME") or "（未识别）",
    )
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        log.info("收到退出信号，正在关闭…")
    finally:
        server.server_close()
        app.store.close()


if __name__ == "__main__":
    sys.exit("这是管理面板库，请通过 manage.py 调用。")
