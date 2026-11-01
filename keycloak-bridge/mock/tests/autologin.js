#!/usr/bin/env node
'use strict';
// 用法：node autologin.js <起始地址> <目标地址前缀> [账号] [密码] [标签]
// 打开起始地址，在模拟 E10 登录页自动登录，到达目标地址前缀即成功。结果以 JSON 输出。
const { launch, drive } = require('./lib');

(async () => {
  const [start, target, user = 'zhangsan', pass = 'Passw0rd!', label = 'autologin'] = process.argv.slice(2);
  const browser = await launch();
  const page = await (await browser.newContext({ locale: 'zh-CN' })).newPage();
  const r = await drive(page, start, { user, pass, label, until: (u) => u.startsWith(target) });
  console.log(JSON.stringify(r));
  await browser.close();
  process.exit(r.ok ? 0 : 1);
})();
