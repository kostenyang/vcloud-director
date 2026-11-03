#!/usr/bin/env python3
"""
vcd_alb_reimport.py — Avi (NSX ALB) controller 壞掉重裝後，修復 VCD 端的 NSX-ALB 設定

背景（2026-11-03 lab 實測：VCD 10.6.2 + Avi 22.1.5 + NSX 9.1.1）
  controller 重裝 → 新憑證 / 新 CA、Avi 上 cloud 與 SEG 的 UUID 全換。
  - VCD 不信任新憑證 → 所有 ALB 操作報 PKIX path building failed，連刪 SEG 都會失敗
  - 信任之後，VCD 舊的 NSX-T Cloud / SEG 仍指向舊 UUID（報 Cloud uuid '...' does not exist!）
  - backing 不能用 PUT 改（cannot have its backing be updated / Unable to change ...backingId）
  → 正解：信任新 CA → 刪舊 SEG → 刪舊 Cloud → 匯入新 Cloud → 匯入新 SEG；controller 記錄沿用
  直接刪 controller 看到「has associated Load Balancer Clouds」，就是少了中間這幾步。

子命令（預設全部 dry-run，加 --apply 才會動）
  status   列出 controller、底下的 Cloud / SEG、backing 在 controller 上還在不在、Edge Gateway 指派
  trust    匯入新 CA（--ca-pem，可含多張）或 controller 目前出示的憑證（--from-server），再測連線
  cleanup  備份 → 刪 backing 已不存在的 SEG → 刪 backing 已不存在的 Cloud（有 Edge 指派就中止）
  import   依備份把新的 Cloud / SEG 匯回來（VCD 名稱、reservationType、supportedFeatureSet 沿用舊的）
  all      trust → cleanup → import

範例
  export VCD_PASS='...'
  python3 vcd_alb_reimport.py --vcd vcd.example.local --controller avi-vip.example.local status
  python3 vcd_alb_reimport.py --vcd ... --controller ... trust --ca-pem new-root-ca.pem --apply
  python3 vcd_alb_reimport.py --vcd ... --controller ... cleanup --apply
  python3 vcd_alb_reimport.py --vcd ... --controller ... import --apply

只用 Python 3 標準函式庫（VCD cell 上的 python3 就能跑）。
"""
import argparse
import base64
import getpass
import glob
import hashlib
import json
import os
import re
import ssl
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime

CTX = ssl.create_default_context()
CTX.check_hostname = False
CTX.verify_mode = ssl.CERT_NONE  # 對 VCD 本身不驗憑證（跟 curl -k 一樣）

APPLY = False


def log(msg=""):
    print(f"[{datetime.now():%H:%M:%S}] {msg}", flush=True)


def die(msg):
    log(f"✖ {msg}")
    sys.exit(1)


def act(desc):
    """mutating 動作的閘門：dry-run 時只印出來。"""
    if APPLY:
        log(f"▶ {desc}")
        return True
    log(f"[DRY-RUN] 會執行：{desc}")
    return False


class Vcd:
    def __init__(self, host, user, password, version=None):
        self.base = f"https://{host}"
        self.user, self.password = user, password
        self.version = version or self._detect_version()
        self.token = None

    def _detect_version(self):
        req = urllib.request.Request(self.base + "/api/versions", headers={"Accept": "application/*+json"})
        try:
            body = urllib.request.urlopen(req, context=CTX, timeout=30).read().decode()
        except Exception as e:
            die(f"連不到 {self.base}/api/versions：{e}")
        try:
            vers = [v["version"] for v in json.loads(body)["versionInfo"] if not v.get("deprecated")]
        except Exception:
            vers = re.findall(r"<Version>([\d.]+)</Version>", body)
        if not vers:
            die("偵測不到 VCD API 版本，請用 --api-version 指定（10.6=39.2、10.5=38.1）")
        return max(vers, key=lambda s: tuple(int(x) for x in s.split(".")))

    def login(self):
        auth = base64.b64encode(f"{self.user}:{self.password}".encode()).decode()
        code, hdr, _ = self.req("POST", "/cloudapi/1.0.0/sessions/provider",
                                headers={"Authorization": f"Basic {auth}"}, auth=False)
        self.token = hdr.get("X-VMWARE-VCLOUD-ACCESS-TOKEN")
        if code != 200 or not self.token:
            die(f"VCD 登入失敗（HTTP {code}），確認帳號是 provider（例 administrator@System）")

    def req(self, method, path, body=None, headers=None, auth=True, accept=None):
        url = path if path.startswith("http") else self.base + path
        h = {"Accept": accept or f"application/json;version={self.version}"}
        if auth:
            h["Authorization"] = f"Bearer {self.token}"
        if headers:
            h.update(headers)
        data = None
        if body is not None:
            data = json.dumps(body).encode()
            h["Content-Type"] = "application/json"
        r = urllib.request.Request(url, data=data, method=method, headers=h)
        try:
            resp = urllib.request.urlopen(r, context=CTX, timeout=180)
            code, rh, raw = resp.status, resp.headers, resp.read()
        except urllib.error.HTTPError as e:
            code, rh, raw = e.code, e.headers, e.read()
        try:
            parsed = json.loads(raw) if raw else None
        except ValueError:
            parsed = raw.decode(errors="replace")
        return code, rh, parsed

    @staticmethod
    def errmsg(body):
        msg = body.get("message", "") if isinstance(body, dict) else str(body)
        return re.sub(r"^\[ [0-9a-f-]+ \] ", "", msg)[:400]

    def list(self, path):
        out, page = [], 1
        sep = "&" if "?" in path else "?"
        while True:
            code, _, b = self.req("GET", f"{path}{sep}pageSize=128&page={page}")
            if code != 200:
                raise RuntimeError(f"GET {path} → HTTP {code}：{self.errmsg(b)}")
            out += b.get("values", [])
            if page >= (b.get("pageCount") or 1):
                return out
            page += 1

    def wait_task(self, hdr, what):
        loc = hdr.get("Location")
        if not loc:
            return True
        for _ in range(120):
            _, _, t = self.req("GET", loc, accept=f"application/*+json;version={self.version}")
            st = (t or {}).get("status")
            if st == "success":
                return True
            if st in ("error", "aborted", "canceled"):
                log(f"  ✖ {what} 失敗：{self.errmsg((t or {}).get('error') or {})}")
                return False
            time.sleep(5)
        log(f"  ✖ {what} 逾時（task {loc}）")
        return False

    def call(self, method, path, body, what):
        code, hdr, b = self.req(method, path, body)
        if code not in (200, 201, 202, 204):
            log(f"  ✖ {what} 失敗（HTTP {code}）：{self.errmsg(b)}")
            return False
        ok = self.wait_task(hdr, what) if code == 202 else True
        if ok:
            log(f"  ✔ {what}")
        return ok


# ---------------------------------------------------------------- 盤點

def inventory(v, ctrl_name):
    ctrls = v.list("/cloudapi/1.0.0/loadBalancer/controllers")
    ctrl = next((c for c in ctrls if c["name"] == ctrl_name), None)
    if not ctrl:
        die(f"VCD 找不到 controller「{ctrl_name}」；現有：{[c['name'] for c in ctrls] or '（無）'}")
    cid = ctrl["id"]
    clouds = [c for c in v.list("/cloudapi/1.0.0/loadBalancer/clouds")
              if c["loadBalancerCloudBacking"]["loadBalancerControllerRef"]["id"] == cid]
    cloud_ids = {c["id"] for c in clouds}
    segs = [s for s in v.list("/cloudapi/1.0.0/loadBalancer/serviceEngineGroups")
            if s["serviceEngineGroupBacking"]["loadBalancerCloudRef"]["id"] in cloud_ids]

    # 連得到 controller 嗎？importableClouds 會列出 Avi 上所有 NSX-T cloud（含已匯入的）
    code, _, b = v.req("GET", f"/cloudapi/1.0.0/nsxAlbResources/importableClouds?filter=_context=={cid}&pageSize=128")
    conn_err, avi_clouds = None, None
    if code == 200:
        avi_clouds = b.get("values", [])
    else:
        conn_err = v.errmsg(b)

    avi_cloud_ids = {c["id"] for c in avi_clouds or []}
    for c in clouds:
        c["_stale"] = None if avi_clouds is None else c["loadBalancerCloudBacking"]["backingId"] not in avi_cloud_ids
    for s in segs:
        cl = next(c for c in clouds if c["id"] == s["serviceEngineGroupBacking"]["loadBalancerCloudRef"]["id"])
        s["_cloud"] = cl["name"]
        if cl["_stale"] is None:
            s["_stale"] = None
        elif cl["_stale"]:
            s["_stale"] = True
        else:
            code, _, b = v.req("GET", "/cloudapi/1.0.0/nsxAlbResources/importableServiceEngineGroups"
                                      f"?filter=_context=={cl['id']}&pageSize=128")
            s["_stale"] = (s["serviceEngineGroupBacking"]["backingId"] not in
                           {x["id"] for x in b.get("values", [])}) if code == 200 else None
        try:
            s["_assign"] = v.list("/cloudapi/1.0.0/loadBalancer/serviceEngineGroups/assignments"
                                  f"?filter=serviceEngineGroupRef.id=={s['id']}")
        except RuntimeError as e:
            s["_assign"] = None
            log(f"  ⚠ 查不到 {s['name']} 的 Edge 指派：{e}")
    return ctrl, clouds, segs, avi_clouds, conn_err


def flag(stale):
    return {True: "✖ backing 已不存在", False: "✔ backing 存在", None: "? 無法確認（連不到 controller）"}[stale]


def show(ctrl, clouds, segs, avi_clouds, conn_err):
    log(f"Controller：{ctrl['name']}  url={ctrl['url']}  version={ctrl.get('version')}  "
        f"usedCloudCount={ctrl.get('usedCloudCount')}")
    if conn_err:
        log(f"  ✖ 連不到 controller：{conn_err}")
        if "PKIX" in conn_err or "certificat" in conn_err.lower():
            log("    → 憑證不被信任：先跑 trust（--ca-pem 新 CA，或 --from-server）")
    else:
        log("  ✔ 連得到 controller")
    for c in clouds:
        log(f"  NSX-T Cloud「{c['name']}」 backing={c['loadBalancerCloudBacking']['backingId']}  {flag(c['_stale'])}")
    for s in segs:
        a = s.get("_assign")
        an = "?" if a is None else (", ".join(x["gatewayRef"]["name"] for x in a) or "無")
        log(f"    SEG「{s['name']}」 cloud={s['_cloud']} backing={s['serviceEngineGroupBacking']['backingId']}  "
            f"{flag(s['_stale'])}  Edge 指派：{an}")
    if avi_clouds is not None:
        for c in avi_clouds:
            if not c.get("alreadyImported"):
                pool = (c.get("networkPoolRef") or {}).get("name") or "（找不到對應 network pool）"
                log(f"  可匯入的 Avi cloud「{c['displayName']}」{c['id']}  network pool={pool}")


# ---------------------------------------------------------------- trust

def pem_blocks(text):
    return re.findall(r"-----BEGIN CERTIFICATE-----.+?-----END CERTIFICATE-----", text, re.S)


def pem_body(pem):
    return "".join(pem.split("-----")[2].split())


def cert_info(pem):
    der = base64.b64decode(pem_body(pem))
    fp = hashlib.sha256(der).hexdigest().upper()
    fp = ":".join(fp[i:i + 2] for i in range(0, len(fp), 2))
    subj = "?"
    try:  # CPython 內部 API，解不出來就只顯示指紋
        with tempfile.NamedTemporaryFile("w", suffix=".pem", delete=False) as f:
            f.write(pem)
        d = ssl._ssl._test_decode_cert(f.name)
        os.unlink(f.name)
        cn = lambda x: ",".join(v for rdn in x for k, v in rdn if k == "commonName")
        san = ",".join(v for _, v in d.get("subjectAltName", ()))
        subj = f"CN={cn(d['subject'])} issuer={cn(d['issuer'])} SAN=[{san}] 期限={d.get('notAfter')}"
    except Exception:
        pass
    return subj, fp


def cmd_trust(v, args, ctrl):
    host = urllib.parse.urlparse(ctrl["url"]).hostname
    port = urllib.parse.urlparse(ctrl["url"]).port or 443
    if args.ca_pem:
        with open(args.ca_pem, encoding="utf-8-sig") as f:
            certs = pem_blocks(f.read())
        if not certs:
            die(f"{args.ca_pem} 裡沒有 PEM 憑證")
    elif args.from_server:
        certs = [ssl.get_server_certificate((host, port))]
        log(f"從 {host}:{port} 取得目前出示的憑證（等同 UI 的 Trust 視窗，請核對指紋）")
    else:
        certs = []
        log("沒給 --ca-pem / --from-server，略過匯入，只測連線")

    trusted = {pem_body(t["certificate"]) for t in v.list("/cloudapi/1.0.0/ssl/trustedCertificates")}
    pending = False
    for pem in certs:
        subj, fp = cert_info(pem)
        log(f"憑證 {subj}")
        log(f"  SHA256 {fp}")
        if pem_body(pem) in trusted:
            log("  已在 VCD Trusted Certificates，略過")
            continue
        alias = re.sub(r"[^A-Za-z0-9._-]", "-", f"avi-{host}-{fp.replace(':', '')[:12]}")
        pending = not APPLY
        if act(f"匯入 Trusted Certificate alias={alias}"):
            v.call("POST", "/cloudapi/1.0.0/ssl/trustedCertificates",
                   {"alias": alias, "certificate": pem.strip() + "\n"}, f"信任 {alias}")

    if args.avi_pass:
        body = {k: ctrl.get(k) for k in ("id", "name", "description", "url", "username")}
        body["password"] = args.avi_pass
        if act(f"更新 controller「{ctrl['name']}」的 admin 密碼（PUT）"):
            v.call("PUT", f"/cloudapi/1.0.0/loadBalancer/controllers/{ctrl['id']}", body, "更新 controller")

    code, _, b = v.req("GET", f"/cloudapi/1.0.0/nsxAlbResources/importableClouds?filter=_context=={ctrl['id']}")
    if code == 200:
        log("✔ 連線測試：VCD 連得到 controller")
        return True
    msg = v.errmsg(b)
    if pending:
        log("[DRY-RUN] 憑證還沒真的匯入，目前仍連不到；加 --apply 後會再測一次")
        return False
    log(f"✖ 連線測試失敗：{msg}")
    if "NotBefore" in msg or "validity" in msg:
        log("  → 憑證有效期問題：檢查 VCD cell 時鐘（NTP），或憑證是不是剛簽、還沒生效")
    elif "PKIX" in msg:
        log("  → 仍不被信任：有中繼 CA 要一起匯入；剛匯入的話，VCD 可能還在用舊的 TLS 連線，稍等再試")
    elif "connect" in msg.lower():
        log("  → 檢查 controller URL 的主機名有沒有在新憑證的 SAN 裡、帳密對不對（重裝後密碼變了就加 --avi-pass）")
    return False


# ---------------------------------------------------------------- cleanup

def cmd_cleanup(v, args, ctrl, clouds, segs, avi_clouds, conn_err):
    if conn_err:
        if not APPLY:
            log("[DRY-RUN] 目前連不到 controller，trust 真的套用之後才能預覽 cleanup")
            return
        die("VCD 連不到 controller，刪除一定會失敗（VCD 刪 SEG 前會呼叫 Avi）→ 先跑 trust")
    del_segs = [s for s in segs if s["_stale"]]
    del_clouds = [c for c in clouds if c["_stale"]]
    keep = [s for s in segs if s["_cloud"] in {c["name"] for c in del_clouds} and not s["_stale"]]
    if keep:
        die(f"要刪的 Cloud 底下還有 backing 存在的 SEG：{[s['name'] for s in keep]}，請人工確認")
    if not del_segs and not del_clouds:
        log("沒有 backing 已不存在的 Cloud / SEG，不需要 cleanup")
        return
    busy = [(s["name"], [x["gatewayRef"]["name"] for x in s["_assign"]]) for s in del_segs if s.get("_assign")]
    unknown = [s["name"] for s in del_segs if s.get("_assign") is None]
    if busy or unknown:
        for n, gws in busy:
            log(f"  SEG「{n}」還指派給 Edge Gateway：{gws}")
        for n in unknown:
            log(f"  SEG「{n}」查不到 Edge 指派狀態")
        die("先在這些 Edge Gateway 刪 Virtual Service / Pool、移除 SEG 指派再重跑（此路徑未在 lab 驗證）")

    backup = {"time": datetime.now().isoformat(timespec="seconds"), "vcd": v.base, "apiVersion": v.version,
              "controller": ctrl, "clouds": del_clouds,
              "serviceEngineGroups": [dict({k: x for k, x in s.items() if not k.startswith("_")}, _cloud=s["_cloud"])
                                      for s in del_segs]}
    path = os.path.join(args.workdir, f"vcd-alb-backup-{datetime.now():%Y%m%d-%H%M%S}.json")
    if APPLY:
        with open(path, "w", encoding="utf-8") as f:
            json.dump(backup, f, ensure_ascii=False, indent=2)
        log(f"備份寫入 {path}（import 會用到）")
    else:
        log(f"[DRY-RUN] 會備份到 {path}")

    for s in del_segs:
        if act(f"刪 SEG「{s['name']}」（backing {s['serviceEngineGroupBacking']['backingId']} 已不存在）"):
            if not v.call("DELETE", f"/cloudapi/1.0.0/loadBalancer/serviceEngineGroups/{s['id']}", None,
                          f"刪 SEG {s['name']}"):
                die("SEG 刪除失敗，停止")
    for c in del_clouds:
        if act(f"刪 NSX-T Cloud「{c['name']}」（backing {c['loadBalancerCloudBacking']['backingId']} 已不存在）"):
            if not v.call("DELETE", f"/cloudapi/1.0.0/loadBalancer/clouds/{c['id']}", None, f"刪 Cloud {c['name']}"):
                die("Cloud 刪除失敗，停止")


# ---------------------------------------------------------------- import

def parse_map(s):
    out = {}
    for pair in filter(None, (s or "").split(",")):
        k, _, val = pair.partition("=")
        out[k.strip()] = val.strip()
    return out


def cmd_import(v, args, ctrl, avi_clouds, conn_err):
    if conn_err:
        die("VCD 連不到 controller → 先跑 trust")
    bpath = args.backup or max(glob.glob(os.path.join(args.workdir, "vcd-alb-backup-*.json")), default=None)
    if not bpath:
        die("找不到備份檔（cleanup 會產生 vcd-alb-backup-*.json），或用 --backup 指定")
    with open(bpath, encoding="utf-8") as f:
        bk = json.load(f)
    log(f"使用備份 {bpath}")
    old_clouds, old_segs = bk["clouds"], bk["serviceEngineGroups"]
    cand = [c for c in avi_clouds if not c.get("alreadyImported")]
    cmap = parse_map(args.cloud_map)      # Avi cloud 名稱 → VCD 名稱
    smap = parse_map(args.seg_map)        # Avi SEG 名稱 → VCD 名稱

    plan = []  # (avi cloud, 舊 VCD cloud 記錄或 None, VCD 名稱)
    for c in cand:
        if c["displayName"] in cmap:
            name = cmap[c["displayName"]]
            old = next((o for o in old_clouds if o["name"] == name), None)
        elif len(old_clouds) == 1 and len(cand) == 1:
            old = old_clouds[0]
            name = old["name"]
        else:
            old = next((o for o in old_clouds if o["name"] == c["displayName"]), None)
            name = old["name"] if old else None
        if name:
            plan.append((c, old, name))
        else:
            log(f"  Avi cloud「{c['displayName']}」對不到舊記錄，略過（要匯入請用 --cloud-map \"{c['displayName']}=<VCD 名稱>\"）")
    if not plan:
        log("沒有需要匯入的 cloud（都已匯入，或對不到舊記錄）")
        return

    for c, old, name in plan:
        pool = c.get("networkPoolRef")
        if not pool:
            log(f"  ✖ Avi cloud「{c['displayName']}」的 transport zone 在 VCD 沒有對應的 network pool，略過")
            continue
        body = {"name": name, "description": (old or {}).get("description"),
                "loadBalancerCloudBacking": {"backingId": c["id"], "backingType": "NSXALB_NSXT",
                                             "loadBalancerControllerRef": {"id": ctrl["id"]}},
                "networkPoolRef": {"id": pool["id"]}}
        my_segs = [s for s in old_segs if old and s["_cloud"] == old["name"]]
        if not act(f"匯入 NSX-T Cloud「{name}」← Avi {c['displayName']} ({c['id']}) network pool={pool['name']}"):
            for s in my_segs:
                log(f"[DRY-RUN]   之後匯入 SEG「{s['name']}」（Avi 上同名的 SEG）"
                    f" reservationType={s.get('reservationType')} featureSet={s.get('supportedFeatureSet')}")
            continue
        if not v.call("POST", "/cloudapi/1.0.0/loadBalancer/clouds", body, f"匯入 Cloud {name}"):
            continue
        new = next((x for x in v.list("/cloudapi/1.0.0/loadBalancer/clouds")
                    if x["loadBalancerCloudBacking"]["backingId"] == c["id"]), None)
        if not new:
            log(f"  ✖ 匯入後找不到 Cloud「{name}」")
            continue
        avi_segs = v.list(f"/cloudapi/1.0.0/nsxAlbResources/importableServiceEngineGroups?filter=_context=={new['id']}")
        rev = {vcd: avi for avi, vcd in smap.items()}
        done = set()
        for s in my_segs:
            want = rev.get(s["name"], s["name"])
            a = next((x for x in avi_segs if x["displayName"] == want and not x.get("alreadyImported")), None)
            if not a:
                log(f"  ⚠ Avi 上找不到名為「{want}」的 SEG（舊 SEG「{s['name']}」），略過；可用 --seg-map \"<Avi 名稱>={s['name']}\"")
                continue
            body = {"name": s["name"], "description": s.get("description"),
                    "serviceEngineGroupBacking": {"backingId": a["id"], "loadBalancerCloudRef": {"id": new["id"]}},
                    "reservationType": s.get("reservationType") or "DEDICATED"}
            if s.get("supportedFeatureSet"):
                body["supportedFeatureSet"] = s["supportedFeatureSet"]
            if act(f"匯入 SEG「{s['name']}」← Avi {a['displayName']} ({a['id']})"):
                v.call("POST", "/cloudapi/1.0.0/loadBalancer/serviceEngineGroups", body, f"匯入 SEG {s['name']}")
                done.add(a["id"])
        for a in avi_segs:
            if a["id"] not in done and not a.get("alreadyImported"):
                log(f"  （Avi 上還有 SEG「{a['displayName']}」沒匯入，需要的話到 UI 匯入或加 --seg-map）")
    log("提醒：SEG 匯回來後，要到各 Edge Gateway 重新指派 SEG、開 LB（原本若有在用）")


# ---------------------------------------------------------------- main

def main():
    global APPLY
    p = argparse.ArgumentParser(description="Avi controller 重裝後修復 VCD NSX-ALB 設定",
                                formatter_class=argparse.RawDescriptionHelpFormatter, epilog=__doc__)
    p.add_argument("command", choices=["status", "trust", "cleanup", "import", "all"])
    p.add_argument("--vcd", default=os.environ.get("VCD_HOST"), help="VCD FQDN（或環境變數 VCD_HOST）")
    p.add_argument("--controller", default=os.environ.get("CONTROLLER"), help="VCD 裡的 controller 名稱")
    p.add_argument("--user", default=os.environ.get("VCD_USER", "administrator@System"))
    p.add_argument("--api-version", default=os.environ.get("API_VERSION"), help="預設自動偵測")
    p.add_argument("--ca-pem", help="trust：新 Root / 中繼 CA 的 PEM 檔（可多張）")
    p.add_argument("--from-server", action="store_true", help="trust：信任 controller 目前出示的憑證")
    p.add_argument("--avi-pass", default=os.environ.get("AVI_PASS"),
                   help="trust：重裝後 Avi admin 密碼變了才需要（或環境變數 AVI_PASS）")
    p.add_argument("--backup", help="import：備份檔（預設取 workdir 最新的 vcd-alb-backup-*.json）")
    p.add_argument("--cloud-map", default=os.environ.get("CLOUD_MAP"), help='"Avi cloud 名稱=VCD 名稱,..."')
    p.add_argument("--seg-map", default=os.environ.get("SEG_MAP"), help='"Avi SEG 名稱=VCD 名稱,..."')
    p.add_argument("--workdir", default=".", help="備份檔目錄（預設目前目錄）")
    p.add_argument("--apply", action="store_true", help="真的執行（否則 dry-run）")
    a = p.parse_args()
    if not a.vcd or not a.controller:
        p.error("--vcd 和 --controller 必填")
    APPLY = a.apply
    pw = os.environ.get("VCD_PASS") or getpass.getpass(f"VCD {a.user} 密碼：")

    v = Vcd(a.vcd, a.user, pw, a.api_version)
    v.login()
    log(f"VCD {a.vcd}  API {v.version}  模式={'APPLY' if APPLY else 'DRY-RUN'}")

    inv = inventory(v, a.controller)
    show(*inv)
    ctrl = inv[0]
    if a.command == "status":
        return
    if a.command in ("trust", "all"):
        ok = cmd_trust(v, a, ctrl)
        if a.command == "trust":
            return
        if not ok and APPLY:
            die("trust 後仍連不到 controller，停止")
        inv = inventory(v, a.controller)
    if a.command in ("cleanup", "all"):
        cmd_cleanup(v, a, *inv)
        if a.command == "cleanup":
            return
        inv = inventory(v, a.controller)
    if a.command in ("import", "all"):
        if not APPLY and a.command == "all":
            log("[DRY-RUN] import 要等 cleanup 真的執行、產生備份後才能預覽；先用 --apply 跑 cleanup 再看 import")
            return
        cmd_import(v, a, inv[0], inv[3], inv[4])


if __name__ == "__main__":
    main()
