'use strict';
// 浏览器自动化公共函数：打开起始地址，遇到模拟 E10 登录页就自动登录，直到到达目标地址。
// 由 aws/verify-cloud.sh 调用，E10_BASE / KC_BASE 由它从云上栈的输出设置。
const { chromium } = require('playwright');
const fs = require('fs');
const path = require('path');

const E10 = process.env.E10_BASE;
const KC = process.env.KC_BASE;
if (!E10 || !KC) {
  console.error('缺少环境变量 E10_BASE / KC_BASE（请通过 aws/verify-cloud.sh 运行）');
  process.exit(2);
}
const OUT = path.join(__dirname, 'out');
fs.mkdirSync(OUT, { recursive: true });

async function launch() {
  return chromium.launch({ args: ['--disable-gpu'] });
}

/**
 * @returns {Promise<{ok:boolean, url:string, kind:string, detail?:string, trail:string[]}>}
 *   kind: reached | e10_tip | unexpected_page | timeout
 */
async function drive(page, startUrl, { user, pass, until, timeoutMs = 30000, label = 'run' }) {
  const trail = [];
  page.on('framenavigated', (f) => { if (f === page.mainFrame()) trail.push(f.url().slice(0, 160)); });
  let loggedIn = false;
  await page.goto(startUrl, { waitUntil: 'commit' }).catch(() => {});
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    await page.waitForLoadState('domcontentloaded').catch(() => {});
    const url = page.url();
    if (until(url)) return { ok: true, url, kind: 'reached', trail, e10Login: loggedIn };
    try {
      if (url.startsWith(E10 + '/login') && (await page.$('#loginid'))) {
        if (loggedIn) return fail('unexpected_page', 'E10 登录后又回到登录页（账号或密码错误？）');
        loggedIn = true;
        // 本机无字体，headless 下 fill/innerText 不可靠，直接操作 DOM
        await Promise.all([
          page.waitForNavigation({ waitUntil: 'commit' }).catch(() => {}),
          page.evaluate(([u, p]) => {
            document.querySelector('#loginid').value = u;
            document.querySelector('#password').value = p;
            HTMLFormElement.prototype.submit.call(document.querySelector('#loginid').form);
          }, [user, pass]),
        ]);
        continue;
      }
      const tip = await page.$('#e10-tip');
      if (tip) return fail('e10_tip', (await tip.textContent()).trim());
      if (url.startsWith(KC)) {
        // Keycloak 停在了某个需要用户操作的页面（补填资料、报错页等）
        const hasForm = await page.$('form#kc-form-login, form#kc-update-profile-form, form#kc-idp-review-profile-form, #kc-error-message, .alert-error, .pf-v5-c-alert');
        if (hasForm) {
          const text = (await page.textContent('body')).replace(/\s+/g, ' ').slice(0, 400);
          return fail('unexpected_page', text);
        }
      }
    } catch (e) { /* 页面正在跳转，重试 */ }
    await page.waitForTimeout(300);
  }
  return fail('timeout', '超时未到达目标地址');

  async function fail(kind, detail) {
    const shot = path.join(OUT, `${label}-${kind}.png`);
    await page.screenshot({ path: shot }).catch(() => {});
    return { ok: false, url: page.url(), kind, detail, trail, screenshot: shot };
  }
}

module.exports = { launch, drive, E10, KC, OUT };
