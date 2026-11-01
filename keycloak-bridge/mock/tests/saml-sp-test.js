#!/usr/bin/env node
'use strict';
/*
 * 模拟 IAM Identity Center 作为 SAML SP，验证 Keycloak 发出的 SAML 响应是否满足 IAM Identity Center 的要求
 * （https://docs.aws.amazon.com/singlesignon/latest/userguide/other-idps.html）：
 *   - NameID 格式为 emailAddress，值为邮箱，且与 IAM Identity Center 用户名一致
 *   - 断言有签名，签名能用 IdP 元数据里的证书验证；不加密
 *   - IdP 元数据：有 entityID、X509 证书、SingleSignOnService；不含加密密钥；小于 75000 字符
 *   - AuthnRequest 不签名（IAM Identity Center 不签）
 * 浏览器 POST 到 ACS（AWS 地址）的请求被拦截下来做检查，不会真的发到 AWS。
 *
 * 用法：node saml-sp-test.js <账号> <密码> <期望的邮箱> [标签] [--twice]（由 aws/verify-cloud.sh 调用）
 *   --twice：同一浏览器会话里再发起一次，验证单点登录会话复用（第二次不应再登录 E10）
 */
const fs = require('fs');
const path = require('path');
const zlib = require('zlib');
const crypto = require('crypto');
const { DOMParser } = require('@xmldom/xmldom');
const { SignedXml } = require('xml-crypto');
const { launch, drive, KC } = require('./lib');

const args = process.argv.slice(2).filter((x) => !x.startsWith('--'));
const TWICE = process.argv.includes('--twice');
const [USER, PASS, EMAIL, LABEL = 'saml'] = args;
if (!USER || !PASS || !EMAIL) { console.error('用法：node saml-sp-test.js <账号> <密码> <期望的邮箱> [标签]'); process.exit(2); }
const REALM = process.env.KC_REALM || 'corp';
const SP_META = process.env.SP_METADATA || path.join(__dirname, '..', 'fixtures', 'iam-identity-center-sp-metadata.xml');

const NS = {
  md: 'urn:oasis:names:tc:SAML:2.0:metadata',
  samlp: 'urn:oasis:names:tc:SAML:2.0:protocol',
  saml: 'urn:oasis:names:tc:SAML:2.0:assertion',
  ds: 'http://www.w3.org/2000/09/xmldsig#',
};
const EMAIL_FMT = 'urn:oasis:names:tc:SAML:1.1:nameid-format:emailAddress';
const one = (node, ns, tag) => node.getElementsByTagNameNS(NS[ns], tag)[0];
const results = [];
const check = (name, ok, detail = '') => results.push({ name, ok: !!ok, detail: String(detail) });

(async () => {
  // ---------- SP 信息 ----------
  const sp = new DOMParser().parseFromString(fs.readFileSync(SP_META, 'utf8'), 'text/xml');
  const SP_ENTITY = sp.documentElement.getAttribute('entityID');
  const ACS = one(sp, 'md', 'AssertionConsumerService').getAttribute('Location');

  // ---------- IdP 元数据（模拟上传到 IAM Identity Center 前的检查） ----------
  const descUrl = `${KC}/realms/${REALM}/protocol/saml/descriptor`;
  const desc = await (await fetch(descUrl)).text();
  const md = new DOMParser().parseFromString(desc, 'text/xml');
  const IDP_ENTITY = md.documentElement.getAttribute('entityID');
  const keyDescs = [...md.getElementsByTagNameNS(NS.md, 'KeyDescriptor')];
  const certs = keyDescs.filter((k) => k.getAttribute('use') !== 'encryption')
    .map((k) => one(k, 'ds', 'X509Certificate').textContent.replace(/\s+/g, ''));
  const sso = [...md.getElementsByTagNameNS(NS.md, 'SingleSignOnService')];
  check('IdP 元数据：小于 75000 字符', desc.length < 75000, `${desc.length} 字符`);
  check('IdP 元数据：有 entityID', !!IDP_ENTITY, IDP_ENTITY);
  check('IdP 元数据：有 X509 签名证书', certs.length > 0, `${certs.length} 个`);
  check('IdP 元数据：有 SingleSignOnService', sso.length > 0, sso.map((s) => s.getAttribute('Binding').split(':').pop()).join(','));
  check('IdP 元数据：不含加密密钥', !keyDescs.some((k) => k.getAttribute('use') === 'encryption'),
    keyDescs.map((k) => k.getAttribute('use') || '(未标注)').join(','));
  const pems = certs.map((c) => `-----BEGIN CERTIFICATE-----\n${c.match(/.{1,64}/g).join('\n')}\n-----END CERTIFICATE-----\n`);

  // ---------- 浏览器 ----------
  const browser = await launch();
  const ctx = await browser.newContext({ locale: 'zh-CN' });
  let captured = null;
  await ctx.route(new URL(ACS).origin + '/**', async (route) => {
    const req = route.request();
    if (req.method() === 'POST' && req.url() === ACS) captured = Object.fromEntries(new URLSearchParams(req.postData() || ''));
    await route.fulfill({ status: 200, contentType: 'text/html', body: '<html><body>（模拟 IAM Identity Center ACS）</body></html>' });
  });

  async function round(label) {
    captured = null;
    const reqId = '_' + crypto.randomUUID();
    const relay = 'https://d-9067000000.awsapps.com/start#/' + crypto.randomBytes(6).toString('hex');
    const authn = `<samlp:AuthnRequest xmlns:samlp="${NS.samlp}" xmlns:saml="${NS.saml}" ID="${reqId}" Version="2.0" ` +
      `IssueInstant="${new Date().toISOString()}" Destination="${KC}/realms/${REALM}/protocol/saml" ` +
      `AssertionConsumerServiceURL="${ACS}" ProtocolBinding="urn:oasis:names:tc:SAML:2.0:bindings:HTTP-POST">` +
      `<saml:Issuer>${SP_ENTITY}</saml:Issuer><samlp:NameIDPolicy Format="${EMAIL_FMT}" AllowCreate="true"/></samlp:AuthnRequest>`;
    const q = new URLSearchParams({ SAMLRequest: zlib.deflateRawSync(authn).toString('base64'), RelayState: relay });
    const page = await ctx.newPage();
    const r = await drive(page, `${KC}/realms/${REALM}/protocol/saml?${q}`, { user: USER, pass: PASS, label, until: (u) => u === ACS });
    await page.close();
    return { r, reqId, relay };
  }

  const { r, reqId, relay } = await round(LABEL);
  check('浏览器经 E10 登录后到达 IAM Identity Center ACS', r.ok && captured, r.ok ? '' : `${r.kind}: ${r.detail}`);
  if (r.ok && captured) inspect(captured, reqId, relay);

  if (TWICE && r.ok) {
    const r2 = await round(LABEL + '-2');
    check('同一浏览器第二次登录复用会话（不再输入 E10 密码）', r2.r.ok && !r2.r.e10Login, r2.r.ok ? `E10 登录次数=${r2.r.e10Login ? 1 : 0}` : r2.r.detail);
  }
  await browser.close();

  // ---------- 输出 ----------
  console.log(`\n== Web 端（SAML → 模拟 IAM Identity Center）用户 ${USER} ==`);
  for (const x of results) console.log(`  [${x.ok ? '通过' : '不通过'}] ${x.name}${x.detail ? '：' + x.detail : ''}`);
  const failed = results.filter((x) => !x.ok).length;
  console.log(failed ? `\n${failed} 项不通过` : '\n全部通过');
  process.exit(failed ? 1 : 0);

  function inspect(post, expectId, expectRelay) {
    const xml = Buffer.from(post.SAMLResponse, 'base64').toString('utf8');
    fs.writeFileSync(path.join(__dirname, 'out', `${LABEL}-response.xml`), xml);
    const doc = new DOMParser().parseFromString(xml, 'text/xml');
    const resp = doc.documentElement;
    const status = one(resp, 'samlp', 'StatusCode')?.getAttribute('Value') || '';
    check('响应状态 Success', status.endsWith(':Success'), status);
    check('RelayState 原样带回', post.RelayState === expectRelay, post.RelayState);
    check('Response Destination = ACS', resp.getAttribute('Destination') === ACS, resp.getAttribute('Destination'));
    check('Response InResponseTo = 请求 ID', resp.getAttribute('InResponseTo') === expectId, resp.getAttribute('InResponseTo'));
    check('断言未加密（IAM Identity Center 不支持加密）', !one(resp, 'saml', 'EncryptedAssertion'));
    const as = one(resp, 'saml', 'Assertion');
    if (!as) return check('包含 Assertion', false);
    check('Assertion Issuer = IdP entityID', one(as, 'saml', 'Issuer')?.textContent === IDP_ENTITY, one(as, 'saml', 'Issuer')?.textContent);
    const nid = one(as, 'saml', 'NameID');
    check('NameID Format = emailAddress', nid?.getAttribute('Format') === EMAIL_FMT, nid?.getAttribute('Format'));
    check('NameID 值 = 用户邮箱（需与 IAM Identity Center 用户名一致）', nid?.textContent === EMAIL, nid?.textContent);
    check('NameID 是 RFC 2822 邮箱格式', /^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(nid?.textContent || ''));
    check('Audience = SP entityID', one(as, 'saml', 'Audience')?.textContent === SP_ENTITY, one(as, 'saml', 'Audience')?.textContent);
    const scd = one(as, 'saml', 'SubjectConfirmationData');
    check('SubjectConfirmation Recipient = ACS', scd?.getAttribute('Recipient') === ACS, scd?.getAttribute('Recipient'));
    const cond = one(as, 'saml', 'Conditions');
    const nb = Date.parse(cond?.getAttribute('NotBefore')), na = Date.parse(cond?.getAttribute('NotOnOrAfter'));
    check('有效期包含当前时间', nb <= Date.now() + 5000 && Date.now() < na, `${cond?.getAttribute('NotBefore')} ~ ${cond?.getAttribute('NotOnOrAfter')}`);

    // 签名验证：找到直接属于 Assertion / Response 的 Signature
    const sigOf = (el) => [...el.childNodes].find((n) => n.localName === 'Signature' && n.namespaceURI === NS.ds);
    const verify = (sigNode, expectedId) => {
      for (const pem of pems) {
        try {
          const s = new SignedXml({ publicCert: pem });
          s.loadSignature(sigNode);
          if (!s.checkSignature(xml)) continue;
          const uri = sigNode.getElementsByTagNameNS(NS.ds, 'Reference')[0].getAttribute('URI');
          return uri === '#' + expectedId ? 'ok' : `签名引用 ${uri}，不是 #${expectedId}`;
        } catch (e) { /* 换下一张证书 */ }
      }
      return '验签失败';
    };
    const aSig = sigOf(as);
    check('断言已签名，且能用 IdP 元数据证书验签', aSig && verify(aSig, as.getAttribute('ID')) === 'ok', aSig ? verify(aSig, as.getAttribute('ID')) : '无签名');
    const rSig = sigOf(resp);
    if (rSig) check('响应签名能用 IdP 元数据证书验签', verify(rSig, resp.getAttribute('ID')) === 'ok', verify(rSig, resp.getAttribute('ID')));
  }
})();
