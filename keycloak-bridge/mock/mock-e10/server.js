#!/usr/bin/env node
/*
 * 模拟泛微 E10「统一认证中心」的 OIDC 认证服务，仅用于测试 Keycloak 桥接方案。
 *
 * 行为依据 E10 集成中心文档（OIDC 认证协议 / 业务系统通过 OIDC 集成 E10 / 账号映射 /
 * 共享范围 / Scope 配置 / 高级设置 / 基本信息）：
 *   - 接口路径：/papi/sso/oidc/authorize、/accessToken、/profile、/jwks，退出 /sp/integration/oidc/logout
 *   - 换 token、刷新 token 必须带 client_secret（参数方式传递）；文档未提 PKCE，默认忽略 code_challenge
 *   - 授权码 ST- 开头，默认 60 秒、一次有效；access_token 7200 秒；id_token 28800 秒；refresh_token 5 天
 *   - token 响应带 msg/code/status 等非标准字段；示例中没有 token_type；刷新响应不返回新的 refresh_token
 *   - id_token：RS256，header 只有 alg/kid；payload 为 jti(TGT-…)/iss({base}/oidc/)/aud/exp/iat/sub + scope 对应 claims
 *   - sub / id = 账号映射规则对应的人员属性（默认手机号）
 *   - 用户信息接口返回 {"msg","code","attributes":{…},"id","status"}
 *   - JWKS 只有 kty/e/kid/alg/n，没有 use 字段
 *   - 不在共享范围、账号未维护映射属性时，E10 停在自己的提示页，不回调业务系统
 *   - 回调地址必须位于"业务系统 URL 地址"范围内
 *
 * 文档没写清楚的行为做成开关（环境变量，或 POST /__mock/config 动态修改）：
 *   E10_ECHO_NONCE     false|true     id_token 是否原样带回 nonce（默认 false）
 *   E10_TOKEN_TYPE     false|true     token 响应是否带 token_type（默认 false）
 *   E10_UNKNOWN_SCOPE  ignore|error   请求未配置的 scope 时忽略还是报错（默认 ignore）
 *   E10_PARAMS         any|query      token 接口只读 URL 参数，还是也读 POST 表单（默认 any）
 *   E10_PKCE           ignore|enforce 是否支持 PKCE（默认 ignore，与文档一致）
 *   E10_ERROR_HTTP     200|400        接口出错时的 HTTP 状态码（默认 200，错误放在 body 的 status 里）
 *   E10_JWKS_USE       false|true     JWKS 是否带 use=sig（默认 false，与文档示例一致）
 * 以下两个开关只用来验证测试脚本能不能发现问题，不代表 E10 的真实行为：
 *   E10_JWKS_KEY       right|wrong    JWKS 用同一个 kid 发布另一把公钥（模拟换钥后 JWKS 没更新）
 *   E10_ISS_IN_TOKEN   same|mismatch  id_token 的 iss 末尾多一个 /，与服务发现不一致
 */
'use strict';
const http = require('http');
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');

const DIR = __dirname;
const DATA = path.join(DIR, 'data');
const PORT = parseInt(process.env.PORT || '20600', 10);   // 云上由栈参数 E10Port 通过环境变量 PORT 传入；20600 只是没设置时的默认值
const cfg = JSON.parse(fs.readFileSync(process.env.E10_CONFIG || path.join(DIR, 'config.json'), 'utf8'));
const BASE = (process.env.E10_PUBLIC_BASE || cfg.public_base).replace(/\/$/, '');
// 客户确认：真实 E10 的 issuer 就是访问地址本身（协议 + 域名:端口），服务发现在 /papi/sso/oidc/.well-known/openid-configuration
const ISSUER = BASE;
const L = cfg.lifetimes;
const SECURE = BASE.startsWith('https://') ? '; Secure' : '';
// 部署到公网时设置 MOCK_ADMIN_TOKEN，/__mock/* 管理接口需带请求头 X-Mock-Token；
// MOCK_ADMIN_LOCAL_ONLY=true 时只接受本机请求（公网是 http，令牌不能在公网上传）
const ADMIN_TOKEN = process.env.MOCK_ADMIN_TOKEN || '';
const ADMIN_LOCAL_ONLY = process.env.MOCK_ADMIN_LOCAL_ONLY === 'true';
function mockAuthorized(req) {
  if (ADMIN_LOCAL_ONLY && !['127.0.0.1', '::1', '::ffff:127.0.0.1'].includes(req.socket.remoteAddress)) return false;
  if (!ADMIN_TOKEN) return true;
  const got = Buffer.from(String(req.headers['x-mock-token'] || ''));
  const want = Buffer.from(ADMIN_TOKEN);
  return got.length === want.length && crypto.timingSafeEqual(got, want);
}

const toggles = {
  ECHO_NONCE: process.env.E10_ECHO_NONCE || 'false',
  TOKEN_TYPE: process.env.E10_TOKEN_TYPE || 'false',
  UNKNOWN_SCOPE: process.env.E10_UNKNOWN_SCOPE || 'ignore',
  PARAMS: process.env.E10_PARAMS || 'any',
  PKCE: process.env.E10_PKCE || 'ignore',
  ERROR_HTTP: process.env.E10_ERROR_HTTP || '200',
  JWKS_USE: process.env.E10_JWKS_USE || 'false',
  JWKS_KEY: process.env.E10_JWKS_KEY || 'right',
  ISS_IN_TOKEN: process.env.E10_ISS_IN_TOKEN || 'same',
};

// ---------- 签名密钥（持久化，kid 由公钥指纹生成，换钥后 kid 也会变） ----------
fs.mkdirSync(DATA, { recursive: true });
const keyFile = path.join(DATA, 'idp-key.pem');
if (!fs.existsSync(keyFile)) {
  const { privateKey } = crypto.generateKeyPairSync('rsa', { modulusLength: 2048 });
  fs.writeFileSync(keyFile, privateKey.export({ type: 'pkcs8', format: 'pem' }), { mode: 0o600 });
}
const privateKey = crypto.createPrivateKey(fs.readFileSync(keyFile));
const publicJwk = crypto.createPublicKey(privateKey).export({ format: 'jwk' });
const KID = crypto.createHash('sha256').update(publicJwk.n).digest('base64url').slice(0, 32);
const wrongJwk = crypto.generateKeyPairSync('rsa', { modulusLength: 2048 }).publicKey.export({ format: 'jwk' });

// 管理员通过 /__mock/apps 修改过的业务系统 URL（持久化，重启后仍生效）
const overrideFile = path.join(DATA, 'apps-override.json');
if (fs.existsSync(overrideFile)) {
  const ov = JSON.parse(fs.readFileSync(overrideFile, 'utf8'));
  for (const app of cfg.apps) if (ov[app.client_id]) Object.assign(app, ov[app.client_id]);
}

// 管理员通过 /__mock/users 新增的人员（持久化，重启后仍生效）。相当于在 E10 组织架构里加人员，并加入认证应用的共享范围
const usersFile = path.join(DATA, 'users-extra.json');
function applyExtraUser(u) {
  const i = cfg.users.findIndex((x) => x.loginid === u.loginid);
  if (i >= 0) cfg.users[i] = { ...cfg.users[i], ...u }; else cfg.users.push(u);
  for (const app of cfg.apps) if (!app.share_scope.includes(u.loginid)) app.share_scope.push(u.loginid);
}
if (fs.existsSync(usersFile)) for (const u of JSON.parse(fs.readFileSync(usersFile, 'utf8'))) applyExtraUser(u);

const b64u = (b) => Buffer.from(b).toString('base64url');
const rnd = (n) => crypto.randomBytes(n).toString('base64url').replace(/_/g, '-');
let seq = 1;

function signJwt(payload) {
  const h = b64u(JSON.stringify({ alg: 'RS256', kid: KID }));
  const p = b64u(JSON.stringify(payload));
  const s = crypto.sign('RSA-SHA256', Buffer.from(`${h}.${p}`), privateKey).toString('base64url');
  return `${h}.${p}.${s}`;
}

// ---------- 内存状态 ----------
const sessions = new Map(); // ETEAMSID -> loginid
const codes = new Map();    // code -> {...}
const ats = new Map();      // access_token -> {...}
const rts = new Map();      // refresh_token -> {...}
const now = () => Math.floor(Date.now() / 1000);

const findUser = (loginid) => cfg.users.find((u) => u.loginid === loginid);
const findApp = (cid) => cfg.apps.find((a) => a.client_id === cid);

const MAPPING_LABEL = { mobile: '手机号码', loginid: '登录名', job_num: '工号', email: '电子邮箱', id_card: '身份证号码', id: '人员ID' };
const userAttr = (u, key) => (key === 'loginid' ? u.loginid : u[key]);

function claimsFor(app, user, scopes) {
  const out = {};
  for (const s of scopes) {
    const def = app.scopes[s];
    if (!def) continue;
    for (const [claim, attr] of Object.entries(def.claims)) out[claim] = userAttr(user, attr) ?? '';
  }
  return out;
}

// ---------- HTTP 工具 ----------
function log(...a) { console.log(new Date().toISOString(), ...a); }

function send(res, status, body, headers = {}) {
  res.writeHead(status, { 'Cache-Control': 'no-store', ...headers });
  res.end(body);
}
const json = (res, obj, status = 200) => send(res, status, JSON.stringify(obj), { 'Content-Type': 'application/json;charset=UTF-8' });
const redirect = (res, loc, headers = {}) => send(res, 302, '', { Location: loc, ...headers });

function e10Error(res, msg, code = '400') {
  log('  -> 接口错误:', msg);
  json(res, { msg, code, status: 400 }, toggles.ERROR_HTTP === '400' ? 400 : 200);
}

function page(res, title, inner, status = 200) {
  send(res, status, `<!doctype html><html><head><meta charset="utf-8"><title>${title}</title>
<style>body{font-family:sans-serif;background:#f4f6fa;margin:0}.box{width:360px;margin:80px auto;background:#fff;padding:32px;border-radius:6px;box-shadow:0 2px 8px #0001}
h2{margin-top:0;color:#2d6bdf}input{width:100%;padding:8px;margin:6px 0 14px;box-sizing:border-box}button{width:100%;padding:10px;background:#2d6bdf;color:#fff;border:0;border-radius:4px}
.err{color:#c00}</style></head><body><div class="box">${inner}</div></body></html>`, { 'Content-Type': 'text/html;charset=UTF-8' });
}
function tipPage(res, msg) {
  log('  -> E10 提示页:', msg);
  page(res, '提示', `<h2>泛微 E10（模拟）</h2><p class="err" id="e10-tip">${msg}</p>`);
}

function cookies(req) {
  return Object.fromEntries((req.headers.cookie || '').split(';').map((c) => c.trim().split('=')).filter((p) => p[0]));
}

function readBody(req) {
  return new Promise((resolve) => {
    let d = '';
    req.on('data', (c) => (d += c));
    req.on('end', () => resolve(d));
  });
}

// ---------- 业务逻辑 ----------
function authorize(req, res, q) {
  const app = findApp(q.client_id);
  if (!app || !app.enabled) return tipPage(res, '应用标识(client_id)无效或应用未启用');
  if (q.response_type !== 'code') return tipPage(res, 'response_type 必须为 code');
  if (!q.redirect_uri || !app.business_urls.some((u) => q.redirect_uri.startsWith(u)))
    return tipPage(res, '回调地址不在认证应用注册的业务系统URL地址范围内');
  const scopes = (q.scope || '').split(/\s+/).filter(Boolean);
  if (!scopes.includes('openid')) return tipPage(res, 'scope 参数必须包含 openid');
  const unknown = scopes.filter((s) => s !== 'openid' && !app.scopes[s]);
  if (unknown.length) {
    log('  未配置的 scope:', unknown.join(','), '处理方式:', toggles.UNKNOWN_SCOPE);
    if (toggles.UNKNOWN_SCOPE === 'error') return tipPage(res, `scope 参数无效：${unknown.join(',')}`);
  }

  const sid = cookies(req).ETEAMSID;
  const loginid = sid && sessions.get(sid);
  if (!loginid) {
    const back = req.url;
    return redirect(res, '/login?service=' + encodeURIComponent(back));
  }
  const user = findUser(loginid);
  if (!app.share_scope.includes(user.loginid))
    return tipPage(res, '登录用户不在认证应用注册的适用对象范围内，请联系管理员检查配置');
  const mapped = userAttr(user, app.account_mapping);
  if (!mapped) {
    const label = MAPPING_LABEL[app.account_mapping];
    return tipPage(res, `当前账号未维护${label}，请设置${label}后重新登录`);
  }

  const code = `ST-${seq++}-${rnd(20)}`;
  codes.set(code, {
    client_id: app.client_id, redirect_uri: q.redirect_uri, loginid, scopes: scopes.filter((s) => s === 'openid' || app.scopes[s]),
    nonce: q.nonce, code_challenge: q.code_challenge, code_challenge_method: q.code_challenge_method,
    exp: now() + L.code_seconds, uses: 0,
  });
  log(`  签发授权码 ${code.slice(0, 12)}… 给 ${loginid}；收到 nonce=${q.nonce ? '有' : '无'} code_challenge=${q.code_challenge ? '有' : '无'}`);
  const sep = q.redirect_uri.includes('?') ? '&' : '?';
  const extra = q.state !== undefined ? `&state=${encodeURIComponent(q.state)}` : '';
  redirect(res, `${q.redirect_uri}${sep}code=${encodeURIComponent(code)}${extra}`);
}

function issueTokens(app, user, scopes, nonce, withRefresh) {
  const t = now();
  const payload = { jti: `TGT-${seq++}-${rnd(40)}`, iss: toggles.ISS_IN_TOKEN === 'mismatch' ? ISSUER + '/' : ISSUER,
    aud: app.client_id, exp: t + L.id_token_seconds, iat: t,
    sub: String(userAttr(user, app.account_mapping)) };
  if (nonce && toggles.ECHO_NONCE === 'true') payload.nonce = nonce;
  Object.assign(payload, claimsFor(app, user, scopes));
  const at = `AT-1-${rnd(24)}`;
  ats.set(at, { client_id: app.client_id, loginid: user.loginid, scopes, exp: t + L.access_token_seconds });
  const body = { msg: 'SUCCESS', access_token: at };
  if (withRefresh) {
    const rt = `RT-1-${rnd(24)}`;
    rts.set(rt, { client_id: app.client_id, loginid: user.loginid, scopes, exp: t + L.refresh_token_seconds });
    body.refresh_token = rt;
  }
  Object.assign(body, { code: '0', id_token: signJwt(payload), expires_in: L.id_token_seconds, status: 200 });
  if (toggles.TOKEN_TYPE === 'true') body.token_type = 'Bearer';
  return body;
}

async function accessToken(req, res, q) {
  let p = { ...q };
  if (req.method === 'POST') {
    const raw = await readBody(req);
    const ct = req.headers['content-type'] || '';
    if (toggles.PARAMS === 'any' && ct.includes('application/x-www-form-urlencoded'))
      p = { ...Object.fromEntries(new URLSearchParams(raw)), ...q };
  }
  const shown = Object.fromEntries(Object.entries(p).map(([k, v]) => [k, /secret|verifier|token|code$/.test(k) ? (v ? '***' : v) : v]));
  log('  token 请求参数:', JSON.stringify(shown), req.headers.authorization ? '(带 Authorization 头，E10 文档未提及，忽略)' : '');

  const app = findApp(p.client_id);
  if (!app) return e10Error(res, '应用标识(client_id)无效');
  if (!p.client_secret) return e10Error(res, '应用密钥(client_secret)不能为空');
  if (p.client_secret !== app.client_secret) return e10Error(res, '应用密钥(client_secret)错误');

  if (p.grant_type === 'authorization_code') {
    const c = codes.get(p.code);
    if (!c || c.client_id !== app.client_id) return e10Error(res, '授权码(code)无效');
    if (c.exp < now()) return e10Error(res, '授权码(code)已过期');
    if (++c.uses > L.code_max_uses) return e10Error(res, '授权码(code)已使用');
    if (p.redirect_uri !== c.redirect_uri) return e10Error(res, '回调地址(redirect_uri)与授权时不一致');
    if (toggles.PKCE === 'enforce' && c.code_challenge) {
      const calc = crypto.createHash('sha256').update(p.code_verifier || '').digest('base64url');
      if (calc !== c.code_challenge) return e10Error(res, 'code_verifier 校验失败');
    }
    const body = issueTokens(app, findUser(c.loginid), c.scopes, c.nonce, true);
    log(`  -> 签发 token 给 ${c.loginid}`);
    return json(res, body);
  }
  if (p.grant_type === 'refresh_token') {
    const r = rts.get(p.refresh_token);
    if (!r || r.client_id !== app.client_id) return e10Error(res, '刷新令牌(refresh_token)无效');
    if (r.exp < now()) return e10Error(res, '刷新令牌(refresh_token)已过期');
    const body = issueTokens(app, findUser(r.loginid), r.scopes, null, false);
    log(`  -> 刷新 token 给 ${r.loginid}`);
    return json(res, body);
  }
  return e10Error(res, `不支持的授权类型(grant_type)：${p.grant_type}`);
}

async function profile(req, res, q) {
  let p = { ...q };
  if (req.method === 'POST') p = { ...Object.fromEntries(new URLSearchParams(await readBody(req))), ...q };
  const a = ats.get(p.access_token);
  if (!a || a.exp < now()) return e10Error(res, '授权令牌(access_token)无效或已过期');
  const app = findApp(a.client_id);
  const user = findUser(a.loginid);
  json(res, { msg: 'SUCCESS', code: '0', attributes: claimsFor(app, user, a.scopes), id: String(userAttr(user, app.account_mapping)), status: 200 });
}

function discovery(res) {
  const allScopes = new Set(['openid']);
  cfg.apps.forEach((a) => Object.keys(a.scopes).forEach((s) => allScopes.add(s)));
  json(res, {
    issuer: ISSUER,
    authorization_endpoint: `${BASE}/papi/sso/oidc/authorize`,
    token_endpoint: `${BASE}/papi/sso/oidc/accessToken`,
    userinfo_endpoint: `${BASE}/papi/sso/oidc/profile`,
    jwks_uri: `${BASE}/papi/sso/oidc/jwks`,
    end_session_endpoint: `${BASE}/sp/integration/oidc/logout`,
    response_types_supported: ['code'],
    grant_types_supported: ['authorization_code', 'refresh_token'],
    subject_types_supported: ['public'],
    id_token_signing_alg_values_supported: ['RS256'],
    token_endpoint_auth_methods_supported: ['client_secret_post'],
    scopes_supported: [...allScopes],
  });
}

const server = http.createServer(async (req, res) => {
  const u = new URL(req.url, BASE);
  const q = Object.fromEntries(u.searchParams);
  log(req.method, u.pathname);
  try {
    switch (u.pathname) {
      case '/papi/sso/oidc/authorize': return authorize(req, res, q);
      case '/papi/sso/oidc/accessToken': return await accessToken(req, res, q);
      case '/papi/sso/oidc/profile': return await profile(req, res, q);
      case '/papi/sso/oidc/jwks': {
        const src = toggles.JWKS_KEY === 'wrong' ? wrongJwk : publicJwk;
        const k = { kty: 'RSA', e: src.e, kid: KID, alg: 'RS256', n: src.n };
        if (toggles.JWKS_USE === 'true') k.use = 'sig';
        return json(res, { keys: [k] });
      }
      case '/papi/sso/oidc/.well-known/openid-configuration': return discovery(res);
      case '/sp/integration/oidc/logout': {
        const sid = cookies(req).ETEAMSID;
        if (sid) sessions.delete(sid);
        log('  E10 会话已注销');
        return redirect(res, q.service || '/login', { 'Set-Cookie': `ETEAMSID=; Path=/; Max-Age=0${SECURE}` });
      }
      case '/login': {
        if (req.method === 'GET')
          return page(res, '登录', `<h2>泛微 E10（模拟）</h2><form method="post">
<input type="hidden" name="service" value="${(q.service || '').replace(/"/g, '&quot;')}">
<label>账号<input name="loginid" id="loginid"></label><label>密码<input type="password" name="password" id="password"></label>
<button type="submit" id="btn-login">登录</button></form>`);
        const rawBody = await readBody(req);
        const f = Object.fromEntries(new URLSearchParams(rawBody));
        const user = findUser(f.loginid);
        if (!user || user.password !== f.password) {
          log(`  登录失败：账号=${f.loginid} body长度=${rawBody.length}`);
          return page(res, '登录', `<h2>泛微 E10（模拟）</h2><p class="err" id="e10-tip">账号或密码错误</p><a href="/login?service=${encodeURIComponent(f.service || '')}">重新登录</a>`);
        }
        const sid = rnd(24);
        sessions.set(sid, user.loginid);
        log(`  用户 ${user.loginid} 登录 E10`);
        const svc = f.service && f.service.startsWith('/') && !f.service.startsWith('//') ? f.service : '/';
        return redirect(res, svc, { 'Set-Cookie': `ETEAMSID=${sid}; Path=/; HttpOnly; SameSite=Lax${SECURE}` });
      }
      case '/':
        return page(res, 'E10', `<h2>泛微 E10（模拟）</h2><p>${sessions.get(cookies(req).ETEAMSID) ? '已登录' : '未登录'}</p>`);
      case '/__mock/config': {
        if (!mockAuthorized(req)) return json(res, { msg: 'forbidden' }, 403);
        if (req.method === 'POST') {
          const upd = JSON.parse((await readBody(req)) || '{}');
          for (const [k, v] of Object.entries(upd)) if (k in toggles) toggles[k] = String(v);
          sessions.clear();
          log('  模拟开关已更新:', JSON.stringify(toggles));
        }
        return json(res, toggles);
      }
      case '/__mock/users': {
        // 新增或更新人员：{loginid, email, name, password?}，不给密码则沿用第一个人员的密码；自动加入所有认证应用的共享范围
        if (!mockAuthorized(req)) return json(res, { msg: 'forbidden' }, 403);
        if (req.method === 'POST') {
          const upd = JSON.parse((await readBody(req)) || '{}');
          if (!/^[A-Za-z0-9._@-]{2,64}$/.test(upd.loginid || '')) return json(res, { msg: 'loginid 只能是字母、数字和 ._@-' }, 400);
          if (upd.email && !/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(upd.email)) return json(res, { msg: 'email 格式不对' }, 400);
          const old = findUser(upd.loginid);
          const u = {
            loginid: upd.loginid,
            password: upd.password || (old && old.password) || cfg.users[0].password,
            name: upd.name || (old && old.name) || upd.loginid,
            email: upd.email ?? (old && old.email) ?? '',
            mobile: (old && old.mobile) || '13900000000',
            job_num: (old && old.job_num) || 'X' + String(cfg.users.length + 1).padStart(4, '0'),
            id: (old && old.id) || String(1156444318578580000 + cfg.users.length),
          };
          applyExtraUser(u);
          const extra = fs.existsSync(usersFile) ? JSON.parse(fs.readFileSync(usersFile, 'utf8')).filter((x) => x.loginid !== u.loginid) : [];
          extra.push(u);
          fs.writeFileSync(usersFile, JSON.stringify(extra, null, 1), { mode: 0o600 });
          log(`  ${old ? '更新' : '新增'}人员 ${u.loginid} <${u.email}>`);
        }
        return json(res, cfg.users.map((x) => ({ loginid: x.loginid, name: x.name, email: x.email,
          share: cfg.apps.filter((a) => a.share_scope.includes(x.loginid)).map((a) => a.client_id) })));
      }
      case '/__mock/apps': {
        // 相当于 E10 管理员在「认证应用管理」里维护业务系统 URL 地址
        if (!mockAuthorized(req)) return json(res, { msg: 'forbidden' }, 403);
        if (req.method === 'POST') {
          const upd = JSON.parse((await readBody(req)) || '{}');
          const app = findApp(upd.client_id);
          if (!app) return json(res, { msg: '应用不存在' }, 404);
          if (!Array.isArray(upd.business_urls) || !upd.business_urls.every((x) => /^https?:\/\/[^\s]+$/.test(x)))
            return json(res, { msg: 'business_urls 必须是 URL 数组' }, 400);
          app.business_urls = upd.business_urls;
          const ov = fs.existsSync(overrideFile) ? JSON.parse(fs.readFileSync(overrideFile, 'utf8')) : {};
          ov[app.client_id] = { business_urls: app.business_urls };
          fs.writeFileSync(overrideFile, JSON.stringify(ov, null, 1));
          log(`  应用 ${app.client_id} 的业务系统 URL 已更新:`, app.business_urls.join(','));
        }
        return json(res, cfg.apps.map((x) => ({ name: x.name, client_id: x.client_id, business_urls: x.business_urls })));
      }
      default:
        return send(res, 404, 'Not Found');
    }
  } catch (e) {
    log('  内部错误', e);
    return send(res, 500, 'Internal Error');
  }
});

server.listen(PORT, () => log(`模拟 E10 已启动：${BASE}（监听 ${PORT}），issuer=${ISSUER}，kid=${KID}，开关=${JSON.stringify(toggles)}`));
