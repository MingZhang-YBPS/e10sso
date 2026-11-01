#!/usr/bin/env python3
"""
由 config.json 生成云上用的模拟 E10 配置（在模拟 E10 实例上执行）：
  - 所有人员密码换成随机生成的密码（公网环境不能用仓库里的示例密码）
  - 两个认证应用的 client_secret 换成随机值
  - 新增一个测试人员，邮箱等于 Quick 里已有用户的邮箱，用于 Quick Desktop 实测
  - Keycloak 回调地址（业务系统 URL）部署 Keycloak 后由管理接口 /__mock/apps 写入
用法：make-cloud-config.py --src config.json --out config.cloud.json --password ... \
        --broker-secret ... --direct-secret ... --test-email you@example.com [--test-loginid quicktest]
"""
import argparse, json

ap = argparse.ArgumentParser()
ap.add_argument("--src", required=True)
ap.add_argument("--out", required=True)
ap.add_argument("--password", required=True)
ap.add_argument("--broker-secret", required=True)
ap.add_argument("--direct-secret", required=True)
ap.add_argument("--test-email", required=True)
ap.add_argument("--test-loginid", default="quicktest")
ap.add_argument("--test-name", default="Quick 测试用户")
a = ap.parse_args()

cfg = json.load(open(a.src, encoding="utf-8"))
cfg["_comment"] = "云上模拟 E10 配置（自动生成，含随机密码，勿提交到代码库）"
for u in cfg["users"]:
    u["password"] = a.password
cfg["users"].append({"loginid": a.test_loginid, "password": a.password, "name": a.test_name,
                     "email": a.test_email, "mobile": "13800000009", "job_num": "E0009", "id": "1156444318578573399"})
broker, direct = cfg["apps"][0], cfg["apps"][1]
broker["client_secret"] = a.broker_secret
broker["business_urls"] = []          # 部署 Keycloak 后写入
direct["client_secret"] = a.direct_secret
for app in (broker, direct):
    if a.test_loginid not in app["share_scope"]:
        app["share_scope"].append(a.test_loginid)
json.dump(cfg, open(a.out, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
print(f"已生成 {a.out}：{len(cfg['users'])} 个人员，测试人员 {a.test_loginid} <{a.test_email}>")
