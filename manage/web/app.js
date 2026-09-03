"use strict";

const $ = (sel, root = document) => root.querySelector(sel);
const $$ = (sel, root = document) => Array.from(root.querySelectorAll(sel));
const PAGE_SIZE = 50;

let session = null;
let csrf = "";
const refreshing = {};

const state = {
  tab: "overview",
  cl: { page: 1, total: 0, q: "", status: "" },
  px: { page: 1, total: 0, q: "", status: "", type: "" },
  u: { page: 1, total: 0, q: "" },
  gen: { options: null, proxies: [], text: "", filename: "" },
};

/* ---------------- 基础工具 ---------------- */

function esc(value) {
  return String(value ?? "").replace(/[&<>"']/g, (ch) => ({
    "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;",
  }[ch]));
}

function fmtBytes(n) {
  n = Number(n || 0);
  if (n < 1024) return `${n} B`;
  const units = ["KB", "MB", "GB", "TB", "PB"];
  let i = -1;
  do { n /= 1024; i += 1; } while (n >= 1024 && i < units.length - 1);
  return `${n.toFixed(2)} ${units[i]}`;
}

function fmtTime(ts) {
  if (!ts) return "-";
  const d = new Date(Number(ts) * 1000);
  if (Number.isNaN(d.getTime())) return "-";
  const p = (x) => String(x).padStart(2, "0");
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())} ` +
         `${p(d.getHours())}:${p(d.getMinutes())}:${p(d.getSeconds())}`;
}

function stateBadge(online) {
  const on = String(online) === "true" || online === true;
  return `<span class="badge ${on ? "online" : "offline"}">${on ? "在线" : "离线"}</span>`;
}

function phaseBadge(phase) {
  const p = String(phase || "");
  if (p === "online") return `<span class="badge running">online</span>`;
  if (p === "offline" || p === "new" || p === "wait start") {
    return `<span class="badge offline">${esc(p)}</span>`;
  }
  if (p === "start error") return `<span class="badge dead">${esc(p)}</span>`;
  return `<span class="badge warn">${esc(p || "未知")}</span>`;
}

function toast(message, type = "") {
  const el = document.createElement("div");
  el.className = `toast ${type}`.trim();
  el.textContent = message;
  $("#toastRoot").appendChild(el);
  setTimeout(() => el.remove(), 4200);
}

function showAlert(sel, text, type) {
  const el = $(sel);
  if (!el) return;
  el.className = `alert ${type || ""}`.trim();
  el.textContent = text || "";
  el.classList.remove("hidden");
}

function hideAlert(sel) {
  const el = $(sel);
  if (el) el.classList.add("hidden");
}

/* ---------------- API ---------------- */

async function api(path, opts = {}) {
  const headers = { "X-Requested-With": "XMLHttpRequest" };
  if (csrf) headers["X-CSRF-Token"] = csrf;
  let body;
  if (opts.body !== undefined) {
    headers["Content-Type"] = "application/json";
    body = JSON.stringify(opts.body);
  }
  let resp;
  try {
    resp = await fetch(path, {
      method: opts.method || "GET",
      headers,
      credentials: "same-origin",
      body,
    });
  } catch (err) {
    throw new Error(`网络请求失败: ${err.message}`);
  }
  let data = null;
  try { data = await resp.json(); } catch (_) { /* ignore */ }
  if (!resp.ok) {
    const err = new Error(
      (data && (data.error || data.msg)) || `HTTP ${resp.status}`
    );
    err.status = resp.status;
    err.data = data;
    if (resp.status === 401 && path !== "/api/login") {
      handleSessionExpired();
    }
    throw err;
  }
  return data;
}

function unwrap(j) {
  if (j && typeof j === "object" && "code" in j && "data" in j) {
    if (j.code === 200) return j.data;
    throw new Error(j.msg || `frps API 错误 ${j.code}`);
  }
  return j;
}

async function frpsApi(sub, opts = {}) {
  const data = await api(`/api/frps/${sub}`, opts);
  return unwrap(data);
}

function handleSessionExpired() {
  session = null;
  csrf = "";
  stopRefresh();
  showLogin();
  toast("登录已过期，请重新登录", "error");
}

/* ---------------- 视图切换 ---------------- */

function showLogin() {
  $("#appView").classList.add("hidden");
  $("#loginView").classList.remove("hidden");
  $("#loginUser").focus();
}

function showApp() {
  $("#loginView").classList.add("hidden");
  $("#appView").classList.remove("hidden");
  $("#currentUser").textContent = session ? `账号: ${session.username}` : "";
  $("#loginError").classList.add("hidden");
  switchTab(state.tab);
}

function switchTab(name) {
  state.tab = name;
  $$(".tab-btn").forEach((b) =>
    b.classList.toggle("active", b.dataset.tab === name)
  );
  $$(".tab-page").forEach((p) => p.classList.toggle("hidden", p.id !== `tab-${name}`));
  if (name === "overview") refreshOverview();
  else if (name === "clients") refreshClients();
  else if (name === "proxies") refreshProxies();
  else if (name === "users") refreshUsers();
  else if (name === "generator") initGenerator();
  else if (name === "ops") { refreshOpsStatus(); refreshAudit(); }
}

/* ---------------- 登录 ---------------- */

async function doLogin(ev) {
  ev.preventDefault();
  const btn = $("#loginBtn");
  btn.disabled = true;
  hideAlert("#loginError");
  try {
    const data = await api("/api/login", {
      method: "POST",
      body: {
        username: $("#loginUser").value.trim(),
        password: $("#loginPass").value,
      },
    });
    csrf = data.csrf;
    session = { username: data.username };
    $("#loginPass").value = "";
    showApp();
  } catch (err) {
    let msg = err.message;
    if (err.status === 429) {
      const secs = err.data && err.data.retryAfterSeconds;
      msg = secs
        ? `尝试次数过多，请 ${Math.max(1, Math.ceil(secs / 60))} 分钟后重试`
        : "尝试次数过多，请稍后再试";
    } else if (err.status === 503) {
      msg = "认证服务暂时不可用，请稍后重试或联系管理员";
    } else if (err.data && err.data.remainingAttempts !== undefined) {
      msg = `${msg}（还可尝试 ${err.data.remainingAttempts} 次）`;
    }
    showAlert("#loginError", msg, "error");
  } finally {
    btn.disabled = false;
  }
}

async function doLogout() {
  try { await api("/api/logout", { method: "POST", body: {} }); } catch (_) { /* ignore */ }
  session = null;
  csrf = "";
  stopRefresh();
  showLogin();
}

/* ---------------- 定时刷新 ---------------- */

let refreshTimer = null;

function startRefresh() {
  stopRefresh();
  refreshTimer = setInterval(async () => {
    if (document.hidden) return;
    try {
      if (state.tab === "overview") await refreshOverview();
      else if (state.tab === "clients") await refreshClients();
      else if (state.tab === "proxies") await refreshProxies();
    } catch (_) { /* 下一次再试 */ }
  }, 12000);
}

function stopRefresh() {
  if (refreshTimer) {
    clearInterval(refreshTimer);
    refreshTimer = null;
  }
}

/* ---------------- 总览 ---------------- */

function normalizeSystemInfo(info) {
  if (!info) return null;
  if (info.config && info.status) {
    return {
      version: info.version,
      config: info.config,
      status: info.status,
    };
  }
  return {
    version: info.version,
    config: {
      bindPort: info.bindPort,
      vhostHTTPPort: info.vhostHTTPPort,
      vhostHTTPSPort: info.vhostHTTPSPort,
      tcpmuxHTTPConnectPort: info.tcpmuxHTTPConnectPort,
      kcpBindPort: info.kcpBindPort,
      quicBindPort: info.quicBindPort,
      subdomainHost: info.subdomainHost,
      maxPoolCount: info.maxPoolCount,
      maxPortsPerClient: info.maxPortsPerClient,
      heartbeatTimeout: info.heartbeatTimeout,
      allowPortsStr: info.allowPortsStr,
      tlsForce: info.tlsForce,
    },
    status: {
      totalTrafficIn: info.totalTrafficIn,
      totalTrafficOut: info.totalTrafficOut,
      curConns: info.curConns,
      clientCounts: info.clientCounts,
      proxyTypeCount: info.proxyTypeCount,
    },
  };
}

async function refreshOverview() {
  if (refreshing.overview) return;
  refreshing.overview = true;
  try {
    let info;
    try {
      info = normalizeSystemInfo(await frpsApi("v2/system/info"));
    } catch (_) {
      info = normalizeSystemInfo(await frpsApi("serverinfo"));
    }
    renderOverview(info);
  } catch (err) {
    $("#ovCards").innerHTML =
      `<div class="empty">加载失败：${esc(err.message)}</div>`;
  } finally {
    refreshing.overview = false;
  }
}

function kvItem(k, v) {
  return `<div class="kv"><dt>${esc(k)}</dt><dd>${v === "" || v === null || v === undefined ? "-" : esc(v)}</dd></div>`;
}

function kvRaw(k, html) {
  return `<div class="kv"><dt>${esc(k)}</dt><dd>${html || "-"}</dd></div>`;
}

function renderOverview(info) {
  const st = info.status || {};
  const cfg = info.config || {};
  const typeCounts = st.proxyTypeCount || {};
  const chips = Object.entries(typeCounts)
    .map(([type, count]) => `<span class="chip">${esc(type)} × ${esc(count)}</span>`)
    .join("");
  $("#ovCards").innerHTML = `
    <div class="stat"><div class="k">frps 版本</div><div class="v">${esc(info.version || "-")}</div></div>
    <div class="stat"><div class="k">绑定端口</div><div class="v">${esc(cfg.bindPort ?? "-")}</div></div>
    <div class="stat"><div class="k">客户端数</div><div class="v">${esc(st.clientCounts ?? "-")}</div></div>
    <div class="stat"><div class="k">当前连接</div><div class="v">${esc(st.curConns ?? "-")}</div></div>
    <div class="stat"><div class="k">总入流量</div><div class="v">${fmtBytes(st.totalTrafficIn)}</div></div>
    <div class="stat"><div class="k">总出流量</div><div class="v">${fmtBytes(st.totalTrafficOut)}</div></div>
    <div class="stat"><div class="k">代理类型分布</div><div class="chips">${chips || '<span class="muted">暂无</span>'}</div></div>
  `;
  $("#ovConfig").innerHTML = [
    kvItem("vhostHTTPPort", cfg.vhostHTTPPort ?? "-"),
    kvItem("vhostHTTPSPort", cfg.vhostHTTPSPort ?? "-"),
    kvItem("TCPMux HTTP Connect", cfg.tcpmuxHTTPConnectPort ?? "-"),
    kvItem("KCP 端口", cfg.kcpBindPort ?? "-"),
    kvItem("QUIC 端口", cfg.quicBindPort ?? "-"),
    kvItem("Subdomain 域名", cfg.subdomainHost || "-"),
    kvItem("每客户端最大代理数", cfg.maxPortsPerClient ?? "-"),
    kvItem("最大连接池", cfg.maxPoolCount ?? "-"),
    kvItem("心跳超时(s)", cfg.heartbeatTimeout ?? "-"),
    kvItem("允许端口范围", cfg.allowPortsStr || "-"),
    kvItem("强制 TLS", cfg.tlsForce === undefined ? "-" : (cfg.tlsForce ? "是" : "否")),
  ].join("");
}

/* ---------------- 客户端 ---------------- */

function clientFields() {
  const s = state.cl;
  const params = new URLSearchParams({ page: s.page, pageSize: PAGE_SIZE });
  if (s.status) params.set("status", s.status);
  if (s.q) params.set("q", s.q);
  return params.toString();
}

async function refreshClients() {
  if (refreshing.clients) return;
  refreshing.clients = true;
  try {
    const data = await frpsApi(`v2/clients?${clientFields()}`);
    state.cl.total = data.total || 0;
    const rows = (data.items || []).map((c) => `
      <tr class="clickable" data-key="${esc(c.key)}" title="点击查看详情">
        <td>${esc(c.user || "-")}</td>
        <td>${esc(c.hostname || "-")}</td>
        <td>${esc(c.clientIP || "-")}</td>
        <td>${esc(c.version || "-")}</td>
        <td>${stateBadge(c.online)}</td>
        <td>${fmtTime(c.lastConnectedAt)}</td>
      </tr>`).join("");
    $("#clBody").innerHTML = rows ||
      `<tr><td colspan="6" class="empty">暂无客户端</td></tr>`;
    renderPager("cl", data.total);
  } catch (err) {
    $("#clBody").innerHTML =
      `<tr><td colspan="6" class="empty">加载失败：${esc(err.message)}</td></tr>`;
  } finally {
    refreshing.clients = false;
  }
}

async function openClientDetail(key) {
  try {
    const d = await frpsApi(`v2/clients/${encodeURIComponent(key)}`);
    const c = d;
    const rows = [
      kvItem("key", c.key),
      kvItem("user", c.user || "-"),
      kvItem("clientID", c.clientID || "-"),
      kvItem("runID", c.runID || "-"),
      kvItem("版本", c.version || "-"),
      kvItem("协议", c.wireProtocol || "-"),
      kvItem("Hostname", c.hostname || "-"),
      kvItem("IP", c.clientIP || "-"),
      kvItem("状态", c.online ? "在线" : "离线"),
      kvItem("当前连接数", (c.status && c.status.curConns) ?? "-"),
      kvItem("代理数", (c.status && c.status.proxyCount) ?? "-"),
      kvItem("首次连接", fmtTime(c.firstConnectedAt)),
      kvItem("最后连接", fmtTime(c.lastConnectedAt)),
      kvItem("断开时间", c.disconnectedAt ? fmtTime(c.disconnectedAt) : "-"),
    ];
    openModal(`客户端详情：${esc(c.key)}`, `<div class="kv-list">${rows.join("")}</div>`);
  } catch (err) {
    toast(err.message, "error");
  }
}

/* ---------------- 代理 ---------------- */

function proxyFields() {
  const s = state.px;
  const params = new URLSearchParams({ page: s.page, pageSize: PAGE_SIZE });
  if (s.status) params.set("status", s.status);
  if (s.type) params.set("type", s.type);
  if (s.q) params.set("q", s.q);
  return params.toString();
}

async function refreshProxies() {
  if (refreshing.proxies) return;
  refreshing.proxies = true;
  try {
    const data = await frpsApi(`v2/proxies?${proxyFields()}`);
    state.px.total = data.total || 0;
    const rows = (data.items || []).map((p) => {
      const spec = p.spec || {};
      return `
        <tr class="clickable" data-name="${esc(p.name)}" title="点击查看详情">
          <td>${esc(p.name || "-")}</td>
          <td>${esc((spec.type || "-").toUpperCase())}</td>
          <td>${esc(p.user || "-")}</td>
          <td>${esc(p.clientID ? String(p.clientID).slice(0, 12) + "…" : "-")}</td>
          <td>${phaseBadge(p.status && p.status.phase)}</td>
          <td>${esc((p.status && p.status.curConns) ?? "-")}</td>
          <td>${fmtBytes(p.status && p.status.todayTrafficIn)}</td>
          <td>${fmtBytes(p.status && p.status.todayTrafficOut)}</td>
        </tr>`;
    }).join("");
    $("#pxBody").innerHTML = rows ||
      `<tr><td colspan="8" class="empty">暂无代理</td></tr>`;
    renderPager("px", data.total);
  } catch (err) {
    $("#pxBody").innerHTML =
      `<tr><td colspan="8" class="empty">加载失败：${esc(err.message)}</td></tr>`;
  } finally {
    refreshing.proxies = false;
  }
}

async function openProxyDetail(name) {
  try {
    const enc = encodeURIComponent(name);
    const [d2, d1] = await Promise.all([
      frpsApi(`v2/proxies/${enc}`),
      frpsApi(`proxies/${enc}`).catch(() => null),
    ]);
    let trafficHtml = "";
    try {
      const tr = await frpsApi(`v2/proxies/${enc}/traffic?days=7`);
      const points = (tr.history || []).map((h) => `
        <tr>
          <td>${esc(h.date || "-")}</td>
          <td>${fmtBytes(h.trafficIn)}</td>
          <td>${fmtBytes(h.trafficOut)}</td>
        </tr>`).join("");
      trafficHtml = `
        <h3>近 7 天流量</h3>
        <div class="table-wrap">
          <table>
            <thead><tr><th>日期</th><th>入流量</th><th>出流量</th></tr></thead>
            <tbody>${points || '<tr><td colspan="3" class="empty">暂无数据</td></tr>'}</tbody>
          </table>
        </div>`;
    } catch (_) { /* 旧版本无 traffic 接口时忽略 */ }

    const st = d2.status || {};
    const body = `
      <div class="kv-list">
        ${kvItem("名称", d2.name)}
        ${kvItem("类型", (d2.spec && d2.spec.type || "").toUpperCase())}
        ${kvItem("user", d2.user || "-")}
        ${kvItem("clientID", d2.clientID || "-")}
        ${kvItem("状态", st.phase || "-")}
        ${kvItem("当前连接", st.curConns ?? "-")}
        ${kvItem("今日入", fmtBytes(st.todayTrafficIn))}
        ${kvItem("今日出", fmtBytes(st.todayTrafficOut))}
        ${st.lastStartAt ? kvItem("启动时间", fmtTime(st.lastStartAt)) : ""}
        ${st.lastCloseAt ? kvItem("关闭时间", fmtTime(st.lastCloseAt)) : ""}
      </div>
      ${trafficHtml}
      ${d1 && d1.conf ? `<h3>运行配置</h3><pre class="codeblock">${esc(JSON.stringify(d1.conf, null, 2))}</pre>` : ""}
    `;
    openModal(`代理详情：${esc(d2.name)}`, body);
  } catch (err) {
    toast(err.message, "error");
  }
}

/* ---------------- 用户 ---------------- */

async function refreshUsers() {
  if (refreshing.users) return;
  refreshing.users = true;
  try {
    const params = new URLSearchParams({ page: state.u.page, pageSize: PAGE_SIZE });
    if (state.u.q) params.set("q", state.u.q);
    const data = await frpsApi(`v2/users?${params.toString()}`);
    state.u.total = data.total || 0;
    $("#uBody").innerHTML = (data.items || []).map((u) => `
      <tr>
        <td>${esc(u.user || "(空)")}</td>
        <td>${esc(u.clientCount ?? "-")}</td>
        <td>${esc(u.proxyCount ?? "-")}</td>
      </tr>`).join("") ||
      `<tr><td colspan="3" class="empty">暂无数据</td></tr>`;
    $("#uMeta").textContent = `共 ${state.u.total} 个用户`;
    renderPager("u", data.total);
  } catch (err) {
    $("#uBody").innerHTML =
      `<tr><td colspan="3" class="empty">加载失败：${esc(err.message)}</td></tr>`;
  } finally {
    refreshing.users = false;
  }
}

/* ---------------- 分页 ---------------- */

function renderPager(prefix, total) {
  const s = state[prefix];
  const pageCount = Math.max(1, Math.ceil(total / PAGE_SIZE));
  $(`#${prefix}Meta`) &&
    ($(`#${prefix}Meta`).textContent = `共 ${total} 条，第 ${s.page} / ${pageCount} 页`);
  $(`#${prefix}PageInfo`) &&
    ($(`#${prefix}PageInfo`).textContent = `${s.page} / ${pageCount}`);
  const prev = $(`#${prefix}Prev`);
  const next = $(`#${prefix}Next`);
  if (prev) prev.disabled = s.page <= 1;
  if (next) next.disabled = s.page >= pageCount;
}

/* ---------------- 模态 ---------------- */

function openModal(title, bodyHtml) {
  const root = $("#modalRoot");
  root.classList.remove("hidden");
  root.innerHTML = `
    <div class="modal-card">
      <div class="modal-head">
        <h3>${esc(title)}</h3>
        <button class="modal-close" aria-label="关闭">&times;</button>
      </div>
      <div class="modal-body">${bodyHtml}</div>
    </div>`;
  const close = () => {
    root.classList.add("hidden");
    root.innerHTML = "";
  };
  $(".modal-close", root).onclick = close;
  root.onclick = (ev) => { if (ev.target === root) close(); };
}

/* ---------------- 配置生成器 ---------------- */

function emptyProxy() {
  return {
    name: "", type: "tcp", localIP: "127.0.0.1",
    localPort: "", remotePort: "", customDomains: "", subdomain: "",
  };
}

async function initGenerator() {
  if (state.gen.options) {
    renderProxyRows();
    return;
  }
  try {
    state.gen.options = await api("/api/frpc-template/options");
    fillGenOptions();
    if (!state.gen.proxies.length) {
      state.gen.proxies = [emptyProxy()];
      renderProxyRows();
    }
    updateGenHelp();
  } catch (err) {
    showAlert("#genValidateMsg", `读取生成器默认值失败：${err.message}`, "error");
  }
}

function fillGenOptions() {
  const o = state.gen.options;
  $("#genUser").value = o.user || "";
  $("#genServerAddr").value = o.serverAddr || "";
  $("#genServerPort").value = o.serverPort || "";
  $("#genToken").value = o.token || "";
}

function genFilename() {
  const user = $("#genUser").value.trim();
  const base = user || "client";
  return `frpc_${base}.toml`;
}

function updateGenHelp() {
  const o = state.gen.options;
  if (!o) return;
  const fname = genFilename();
  const unit = `[Unit]
Description=FRP Client Daemon
After=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/frpc -c /etc/frp/${fname}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target`;
  $("#genHelp").textContent = [
    `# 1) 把生成的 ${fname} 上传到目标机器`,
    `scp ${fname} root@目标机器:/etc/frp/${fname}`,
    "",
    "# 2) 安装 frpc 二进制（以 Linux amd64 为例）",
    `cd /tmp`,
    `curl -fLO https://github.com/fatedier/frp/releases/download/v${o.version}/frp_${o.version}_${o.arch}.tar.gz`,
    `tar -xzf frp_${o.version}_${o.arch}.tar.gz`,
    `sudo mkdir -p /etc/frp`,
    `sudo cp frp_${o.version}_${o.arch}/frpc /usr/local/bin/frpc`,
    `sudo chmod +x /usr/local/bin/frpc`,
    "",
    "# 3) 注册为 systemd 服务并启动",
    `sudo tee /etc/systemd/system/frpc.service >/dev/null <<'EOF'\n${unit}\nEOF`,
    `sudo systemctl daemon-reload`,
    `sudo systemctl enable --now frpc`,
    "",
    "# 4) 排错",
    `systemctl status frpc`,
    `sudo journalctl -u frpc -n 50 --no-pager`,
  ].join("\n");
}

function renderProxyRows() {
  const wrap = $("#genProxyRows");
  wrap.innerHTML = state.gen.proxies.map((p, i) => `
    <div class="proxy-row" data-index="${i}">
      <input class="f-name" placeholder="名称，如 ssh" value="${esc(p.name)}">
      <select class="f-type">
        ${["tcp", "udp", "http", "https", "tcpmux", "stcp", "xtcp", "sudp"]
          .map((t) => `<option value="${t}" ${t === p.type ? "selected" : ""}>${t.toUpperCase()}</option>`)
          .join("")}
      </select>
      <input class="f-localIP" placeholder="localIP" value="${esc(p.localIP)}">
      <input class="f-localPort" type="number" placeholder="localPort" value="${esc(p.localPort)}">
      <input class="f-remotePort" type="number" placeholder="remotePort" value="${esc(p.remotePort)}">
      <input class="f-domains" placeholder="customDomains(逗号分隔)" value="${esc(p.customDomains)}">
      <input class="f-subdomain" placeholder="subdomain" value="${esc(p.subdomain)}">
      <button class="btn danger ghost small del" title="删除">删除</button>
    </div>`).join("") ||
    `<p class="muted empty">还没有代理，点击右上角“添加代理”</p>`;

  $$(".proxy-row", wrap).forEach((row) => {
    const idx = Number(row.dataset.index);
    const set = (key, value) => {
      const p = { ...state.gen.proxies[idx] };
      p[key] = value;
      state.gen.proxies[idx] = p;
    };
    $(".f-name", row).oninput = (e) => set("name", e.target.value);
    $(".f-type", row).onchange = (e) => { set("type", e.target.value); renderProxyRows(); };
    $(".f-localIP", row).oninput = (e) => set("localIP", e.target.value);
    $(".f-localPort", row).oninput = (e) => set("localPort", e.target.value);
    $(".f-remotePort", row).oninput = (e) => set("remotePort", e.target.value);
    $(".f-domains", row).oninput = (e) => set("customDomains", e.target.value);
    $(".f-subdomain", row).oninput = (e) => set("subdomain", e.target.value);
    $(".del", row).onclick = () => {
      state.gen.proxies.splice(idx, 1);
      renderProxyRows();
    };
  });
  updateGenHelp();
}

function collectGenParams() {
  const serverAddr = $("#genServerAddr").value.trim();
  const serverPort = Number($("#genServerPort").value);
  const token = $("#genToken").value;
  const user = $("#genUser").value.trim();
  const proxies = state.gen.proxies
    .filter((p) => p.name && p.localPort)
    .map((p) => ({
      name: p.name.trim(),
      type: p.type,
      localIP: p.localIP.trim() || "127.0.0.1",
      localPort: p.localPort,
      remotePort: p.type === "tcp" || p.type === "udp" ? p.remotePort : "",
      customDomains:
        p.type === "http" || p.type === "https" || p.type === "tcpmux"
          ? p.customDomains : "",
      subdomain:
        p.type === "http" || p.type === "https" || p.type === "tcpmux"
          ? p.subdomain : "",
    }));
  return {
    serverAddr,
    serverPort,
    token,
    user,
    proxies,
    serverPortMissing: !Number.isFinite(serverPort) || serverPort <= 0,
  };
}

function showGenResult(result) {
  const el = $("#genValidateMsg");
  if (result.ok) {
    el.className = "alert ok";
    el.textContent = "校验通过，配置可用。";
  } else {
    el.className = "alert error";
    el.textContent = "校验未通过：\n" + (result.errors || []).join("；");
  }
  el.classList.remove("hidden");
}

async function genRender() {
  hideAlert("#genValidateMsg");
  const params = collectGenParams();
  if (params.serverPortMissing) {
    showGenResult({ ok: false, errors: ["serverPort 必须是有效端口"] });
    return;
  }
  try {
    const data = await api("/api/frpc-template/render", {
      method: "POST",
      body: { ...params },
    });
    $("#genPreview").value = data.text;
    showGenResult({ ok: data.ok, errors: data.errors || [] });
  } catch (err) {
    toast(err.message, "error");
  }
}

async function genValidate() {
  hideAlert("#genValidateMsg");
  if (!$("#genPreview").value.trim()) {
    showGenResult({ ok: false, errors: ["请先点击“生成预览”"] });
    return;
  }
  try {
    const data = await api("/api/frpc-template/validate", {
      method: "POST",
      body: { text: $("#genPreview").value },
    });
    showGenResult(data);
  } catch (err) {
    toast(err.message, "error");
  }
}

function genDownload() {
  const text = $("#genPreview").value;
  if (!text.trim()) {
    toast("请先生成预览", "error");
    return;
  }
  const blob = new Blob(["\ufeff" + text], { type: "text/plain;charset=utf-8" });
  const a = document.createElement("a");
  a.href = URL.createObjectURL(blob);
  a.download = genFilename();
  document.body.appendChild(a);
  a.click();
  a.remove();
  setTimeout(() => URL.revokeObjectURL(a.href), 3000);
}

async function genCopy() {
  const text = $("#genPreview").value;
  if (!text.trim()) {
    toast("请先生成预览", "error");
    return;
  }
  try {
    await navigator.clipboard.writeText(text);
    toast("已复制到剪贴板", "ok");
  } catch (_) {
    $("#genPreview").select();
    document.execCommand("copy");
    toast("已复制", "ok");
  }
}

/* ---------------- 运维 ---------------- */

async function refreshOpsStatus() {
  try {
    const s = await api("/api/service/status");
    const svc = s.service || {};
    const reach = s.frpsApiReachable
      ? '<span class="badge running">可达</span>'
      : '<span class="badge dead">不可达</span>';
    const pids = (s.frpsPids || []).length
      ? s.frpsPids.join(", ")
      : '<span class="badge offline">未发现 frps 进程</span>';
    $("#opsStatus").innerHTML = [
      kvRaw("frps API", `${esc(s.frpsApiUrl || "-")} ${reach}`),
      kvItem("frps 版本", s.frpsVersion || "-"),
      kvItem("配置文件", s.frpsConfigFile || "-"),
      kvRaw("frps 进程 PID", pids),
      kvItem("systemd 单元", svc.name || "-"),
      kvItem("systemd active", svc.active || "-"),
      kvItem("systemd enabled", svc.enabled || "-"),
      kvItem("服务控制", s.serviceControlEnabled ? "已开启" : "已关闭"),
    ].join("");
    const ctlBtns = ["opsStart", "opsStop", "opsRestart"];
    const disabled = !s.serviceControlEnabled || !svc.name;
    ctlBtns.forEach((id) => { $(`#${id}`).disabled = disabled; });
    if (disabled && s.serviceControlEnabled && !svc.name) {
      showAlert("#opsResult",
        "未识别 frps systemd 服务名：请在 manage.conf 设置 FRPS_SERVICE_NAME", "warn");
    }
  } catch (err) {
    showAlert("#opsResult", `读取状态失败：${err.message}`, "error");
  }
}

async function opsAction(action) {
  hideAlert("#opsResult");
  const names = { start: "启动", stop: "停止", restart: "重启" };
  if (!window.confirm(`确认要${names[action]} frps 服务吗？`)) return;
  try {
    const data = await api(`/api/service/${action}`, { method: "POST", body: {} });
    showAlert("#opsResult", data.ok
      ? `服务${names[action]}成功`
      : `服务${names[action]}失败：${data.detail || data.error || ""}`, data.ok ? "ok" : "error");
    await refreshOpsStatus();
  } catch (err) {
    const reason = err.data && (err.data.detail || err.data.error)
      ? (err.data.detail || err.data.error)
      : err.message;
    showAlert("#opsResult", `操作失败：${reason}`, "error");
  }
}

async function opsPrune() {
  hideAlert("#opsResult");
  if (!window.confirm("确认清理 frps 上所有离线的代理记录吗？")) return;
  try {
    const data = await frpsApi("v2/system/prune?type=offline_proxies", { method: "POST", body: {} });
    showAlert("#opsResult",
      `清理完成：清除 ${data.cleared ?? "-"} 条 / 共 ${data.total ?? "-"} 条`,
      "ok");
  } catch (err) {
    showAlert("#opsResult", `清理失败：${err.message}`, "error");
  }
}

async function refreshAudit() {
  try {
    const data = await api("/api/audit?limit=100");
    const eventNames = {
      login_success: "登录成功",
      login_failed: "登录失败",
      login_locked: "锁定拒绝",
      logout: "退出登录",
      frpc_render: "生成 frpc 配置",
      service_start: "启动服务",
      service_stop: "停止服务",
      service_restart: "重启服务",
    };
    $("#auditBody").innerHTML = (data.items || []).map((r) => `
      <tr>
        <td>${esc(r.timeText || fmtTime(r.ts))}</td>
        <td>${esc(r.username || "-")}</td>
        <td>${esc(r.ip || "-")}</td>
        <td>${esc(eventNames[r.event] || r.event)}</td>
        <td title="${esc(r.detail || "")}">${esc((r.detail || "").slice(0, 60))}</td>
      </tr>`).join("") ||
      `<tr><td colspan="5" class="empty">暂无审计日志</td></tr>`;
  } catch (err) {
    $("#auditBody").innerHTML =
      `<tr><td colspan="5" class="empty">加载失败：${esc(err.message)}</td></tr>`;
  }
}

/* ---------------- 事件绑定与启动 ---------------- */

function bindEvents() {
  $("#loginForm").addEventListener("submit", doLogin);
  $("#logoutBtn").addEventListener("click", doLogout);

  $$(".tab-btn").forEach((b) =>
    b.addEventListener("click", () => switchTab(b.dataset.tab))
  );

  $("#ovRefresh").addEventListener("click", refreshOverview);

  $("#clSearch").addEventListener("click", () => {
    state.cl.q = $("#clQ").value.trim();
    state.cl.page = 1;
    refreshClients();
  });
  $("#clQ").addEventListener("keydown", (e) => {
    if (e.key === "Enter") {
      state.cl.q = e.target.value.trim();
      state.cl.page = 1;
      refreshClients();
    }
  });
  $("#clStatus").addEventListener("change", () => {
    state.cl.status = $("#clStatus").value;
    state.cl.page = 1;
    refreshClients();
  });
  $("#clBody").addEventListener("click", (e) => {
    const tr = e.target.closest("tr[data-key]");
    if (tr) openClientDetail(tr.dataset.key);
  });
  $("#clPrev").addEventListener("click", () => {
    if (state.cl.page > 1) { state.cl.page -= 1; refreshClients(); }
  });
  $("#clNext").addEventListener("click", () => {
    state.cl.page += 1;
    refreshClients();
  });

  $("#pxSearch").addEventListener("click", () => {
    state.px.q = $("#pxQ").value.trim();
    state.px.page = 1;
    refreshProxies();
  });
  $("#pxQ").addEventListener("keydown", (e) => {
    if (e.key === "Enter") {
      state.px.q = e.target.value.trim();
      state.px.page = 1;
      refreshProxies();
    }
  });
  $("#pxType").addEventListener("change", () => {
    state.px.type = $("#pxType").value;
    state.px.page = 1;
    refreshProxies();
  });
  $("#pxStatus").addEventListener("change", () => {
    state.px.status = $("#pxStatus").value;
    state.px.page = 1;
    refreshProxies();
  });
  $("#pxBody").addEventListener("click", (e) => {
    const tr = e.target.closest("tr[data-name]");
    if (tr) openProxyDetail(tr.dataset.name);
  });
  $("#pxPrev").addEventListener("click", () => {
    if (state.px.page > 1) { state.px.page -= 1; refreshProxies(); }
  });
  $("#pxNext").addEventListener("click", () => {
    state.px.page += 1;
    refreshProxies();
  });

  $("#uSearch").addEventListener("click", () => {
    state.u.q = $("#uQ").value.trim();
    state.u.page = 1;
    refreshUsers();
  });
  $("#uQ").addEventListener("keydown", (e) => {
    if (e.key === "Enter") {
      state.u.q = e.target.value.trim();
      state.u.page = 1;
      refreshUsers();
    }
  });
  $("#uPrev").addEventListener("click", () => {
    if (state.u.page > 1) { state.u.page -= 1; refreshUsers(); }
  });
  $("#uNext").addEventListener("click", () => {
    state.u.page += 1;
    refreshUsers();
  });

  $("#genAddProxy").addEventListener("click", () => {
    state.gen.proxies.push(emptyProxy());
    renderProxyRows();
  });
  $("#genRender").addEventListener("click", genRender);
  $("#genValidate").addEventListener("click", genValidate);
  $("#genCopy").addEventListener("click", genCopy);
  $("#genDownload").addEventListener("click", genDownload);
  $("#genUser").addEventListener("input", updateGenHelp);

  $("#opsRefresh").addEventListener("click", refreshOpsStatus);
  $("#opsPrune").addEventListener("click", opsPrune);
  $("#opsStart").addEventListener("click", () => opsAction("start"));
  $("#opsStop").addEventListener("click", () => opsAction("stop"));
  $("#opsRestart").addEventListener("click", () => opsAction("restart"));
  $("#auditRefresh").addEventListener("click", refreshAudit);
}

async function boot() {
  bindEvents();
  try {
    const me = await api("/api/me");
    session = { username: me.username };
    csrf = me.csrf;
    showApp();
    startRefresh();
  } catch (_) {
    showLogin();
  }
}

boot();
