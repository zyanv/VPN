#!/usr/bin/env bash
# Xray Unified Manager for Debian/Ubuntu/Kali
# Generated 2026-07-21
set -Eeuo pipefail
IFS=$'\n\t'

APP_DIR=/opt/xray-manager
BIN=/usr/local/bin/xray-manager
PY="$APP_DIR/manager.py"
VENV="$APP_DIR/venv"
SERVICE=xray-manager
XRAY_SERVICE=xray
NGINX_SERVICE=nginx

need_root(){ [[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "Run as root: sudo bash $0"; exit 1; }; }
have(){ command -v "$1" >/dev/null 2>&1; }
spin(){
  local pid=$1 msg=${2:-Working} chars='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏' i=0
  while kill -0 "$pid" 2>/dev/null; do
    printf "\r\033[36m%s\033[0m %s" "${chars:i++%10:1}" "$msg"
    sleep .1
  done
  wait "$pid"; local rc=$?
  if ((rc==0)); then printf "\r\033[32m✔\033[0m %s\n" "$msg"; else printf "\r\033[31m✘\033[0m %s\n" "$msg"; fi
  return "$rc"
}
install_all(){
  need_root
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y >/tmp/xm-apt.log 2>&1 &
  spin $! "Updating packages"
  apt-get install -y curl unzip jq nginx python3 python3-venv python3-pip openssl uuid-runtime \
    iproute2 dnsutils cron ca-certificates socat sqlite3 nftables >/tmp/xm-apt.log 2>&1 &
  spin $! "Installing dependencies"

  mkdir -p "$APP_DIR"/{data,backup,certs,logs}
  chmod 700 "$APP_DIR/data"

  echo "Installing latest official Xray release..."
  bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

  cat >"$PY" <<'PYEOF'
#!/usr/bin/env python3
import argparse, base64, copy, datetime as dt, fcntl, getpass, hashlib, hmac, ipaddress
import json, os, pathlib, secrets, shutil, socket, subprocess, sys, tempfile, time, urllib.parse, uuid

ROOT=pathlib.Path("/opt/xray-manager")
DATA=ROOT/"data"
STATE=DATA/"state.json"
LOCK=DATA/"lock"
XRAY_CFG=pathlib.Path("/usr/local/etc/xray/config.json")
NGINX_CFG=pathlib.Path("/etc/nginx/conf.d/xray-manager.conf")
CERT_DIR=ROOT/"certs"
LOG=ROOT/"logs/manager.log"
DEFAULT={
 "domain":"","public_ip":"","dns":["1.1.1.1","1.0.0.1"],"ipv6":True,"tun":False,
 "users":[],"proxies":[],"proxy_mode":"off","active_proxy":None,"bypass_domains":[],
 "ports":{"ws":10001,"upgrade":10002,"xhttp":10003,"socks":10808,"http":10809,"api":10085},
 "paths":{"ws":"/vless-ws","upgrade":"/vless-upgrade","xhttp":"/vless-xhttp"},
 "admin":{"username":"admin","password_hash":"","secret":""},
 "created_at":"","updated_at":""
}

def now(): return dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat()
def log(msg):
    ROOT.joinpath("logs").mkdir(parents=True,exist_ok=True)
    with open(LOG,"a") as f: f.write(f"{now()} {msg}\n")
def locked():
    LOCK.parent.mkdir(parents=True,exist_ok=True)
    f=open(LOCK,"a+"); fcntl.flock(f,fcntl.LOCK_EX); return f
def load():
    if not STATE.exists():
        s=copy.deepcopy(DEFAULT); s["created_at"]=s["updated_at"]=now(); save(s)
    with open(STATE) as f: s=json.load(f)
    d=copy.deepcopy(DEFAULT); d.update(s)
    for k in ("ports","paths","admin"): d[k].update(s.get(k,{}) or {})
    return d
def save(s):
    s["updated_at"]=now(); STATE.parent.mkdir(parents=True,exist_ok=True)
    fd,tmp=tempfile.mkstemp(dir=STATE.parent,prefix=".state.",text=True)
    with os.fdopen(fd,"w") as f: json.dump(s,f,indent=2); f.flush(); os.fsync(f.fileno())
    os.chmod(tmp,0o600); os.replace(tmp,STATE)
def run(cmd,check=True,capture=True):
    p=subprocess.run(cmd,text=True,capture_output=capture)
    if check and p.returncode: raise RuntimeError((p.stderr or p.stdout or str(cmd)).strip())
    return p
def svc(name,action): return run(["systemctl",action,name],check=False).returncode==0
def svc_state(name): return run(["systemctl","is-active",name],check=False).stdout.strip() or "unknown"
def public_ip():
    for url in ("https://api.ipify.org","https://ifconfig.me/ip"):
        try:
            p=run(["curl","-4fsS","--max-time","4",url],check=False)
            ip=p.stdout.strip(); ipaddress.ip_address(ip); return ip
        except: pass
    try: return socket.gethostbyname(socket.gethostname())
    except: return ""
def hash_pw(pw,salt=None):
    salt=salt or secrets.token_bytes(16)
    dk=hashlib.pbkdf2_hmac("sha256",pw.encode(),salt,250000)
    return base64.urlsafe_b64encode(salt+dk).decode()
def verify_pw(pw,encoded):
    try:
        raw=base64.urlsafe_b64decode(encoded.encode()); return hmac.compare_digest(raw[16:],hashlib.pbkdf2_hmac("sha256",pw.encode(),raw[:16],250000))
    except: return False
def active_users(s):
    today=dt.date.today()
    out=[]
    for u in s["users"]:
        try: exp=dt.date.fromisoformat(u["expires"])
        except: continue
        if u.get("enabled",True) and exp>=today: out.append(u)
    return out
def proxy_outbound(p):
    if p["type"] in ("socks5","socks5h"):
        settings={"servers":[{"address":p["host"],"port":int(p["port"])}]}
        if p.get("user"): settings["servers"][0]["users"]=[{"user":p["user"],"pass":p.get("pass","")}]
        return {"tag":"upstream-proxy","protocol":"socks","settings":settings}
    settings={"servers":[{"address":p["host"],"port":int(p["port"])}]}
    if p.get("user"): settings["servers"][0]["users"]=[{"user":p["user"],"pass":p.get("pass","")}]
    return {"tag":"upstream-proxy","protocol":"http","settings":settings}
def gen_xray(s):
    clients=[{"id":u["uuid"],"email":u["name"],"level":0} for u in active_users(s)]
    p=s["ports"]; paths=s["paths"]
    inbounds=[
      {"tag":"vless-ws","listen":"127.0.0.1","port":p["ws"],"protocol":"vless",
       "settings":{"clients":clients,"decryption":"none"},
       "streamSettings":{"network":"ws","security":"none","wsSettings":{"path":paths["ws"],"acceptProxyProtocol":False}}},
      {"tag":"vless-upgrade","listen":"127.0.0.1","port":p["upgrade"],"protocol":"vless",
       "settings":{"clients":clients,"decryption":"none"},
       "streamSettings":{"network":"httpupgrade","security":"none","httpupgradeSettings":{"path":paths["upgrade"]}}},
      {"tag":"vless-xhttp","listen":"127.0.0.1","port":p["xhttp"],"protocol":"vless",
       "settings":{"clients":clients,"decryption":"none"},
       "streamSettings":{"network":"xhttp","security":"none","xhttpSettings":{"path":paths["xhttp"],"mode":"auto"}}},
      {"tag":"local-socks","listen":"127.0.0.1","port":p["socks"],"protocol":"socks",
       "settings":{"auth":"noauth","udp":True}},
      {"tag":"local-http","listen":"127.0.0.1","port":p["http"],"protocol":"http","settings":{}}
    ]
    if s.get("tun"):
      inbounds.append({"tag":"tun-in","protocol":"tun",
        "settings":{"name":"xray0","MTU":1500,"address":["172.19.0.1/30"],"autoRoute":False}})
    outbounds=[{"tag":"direct","protocol":"freedom","settings":{"domainStrategy":"UseIP"}},{"tag":"block","protocol":"blackhole","settings":{}}]
    ap=next((x for x in s["proxies"] if x["id"]==s.get("active_proxy") and x.get("enabled",True)),None)
    if ap and s["proxy_mode"]!="off": outbounds.insert(0,proxy_outbound(ap))
    rules=[
      {"type":"field","ip":["geoip:private"],"outboundTag":"direct"},
      {"type":"field","protocol":["bittorrent"],"outboundTag":"block"}
    ]
    if ap and s["proxy_mode"]=="full":
      rules.append({"type":"field","network":"tcp,udp","outboundTag":"upstream-proxy"})
    elif ap and s["proxy_mode"]=="bypass" and s["bypass_domains"]:
      rules.append({"type":"field","domain":s["bypass_domains"],"outboundTag":"upstream-proxy"})
    cfg={
      "log":{"loglevel":"warning","access":str(ROOT/"logs/access.log"),"error":str(ROOT/"logs/error.log")},
      "dns":{"servers":s["dns"],"queryStrategy":"UseIP"},
      "api":{"tag":"api","services":["HandlerService","LoggerService","StatsService"]},
      "stats":{},"policy":{"system":{"statsInboundUplink":True,"statsInboundDownlink":True}},
      "inbounds":inbounds,"outbounds":outbounds,
      "routing":{"domainStrategy":"IPIfNonMatch","rules":rules}
    }
    return cfg
def nginx_text(s):
    d=s["domain"] or "_"; p=s["ports"]; pa=s["paths"]
    cert=CERT_DIR/"fullchain.pem"; key=CERT_DIR/"privkey.pem"
    tls = cert.exists() and key.exists()
    locations=f'''
    location {pa["ws"]} {{
      proxy_pass http://127.0.0.1:{p["ws"]};
      proxy_http_version 1.1;
      proxy_set_header Upgrade $http_upgrade;
      proxy_set_header Connection "upgrade";
      proxy_set_header Host $host;
      proxy_set_header X-Real-IP $remote_addr;
    }}
    location {pa["upgrade"]} {{
      proxy_pass http://127.0.0.1:{p["upgrade"]};
      proxy_http_version 1.1;
      proxy_set_header Upgrade $http_upgrade;
      proxy_set_header Connection "upgrade";
      proxy_set_header Host $host;
      proxy_set_header X-Real-IP $remote_addr;
      proxy_buffering off;
    }}
    location {pa["xhttp"]} {{
      proxy_pass http://127.0.0.1:{p["xhttp"]};
      proxy_http_version 1.1;
      proxy_set_header Host $host;
      proxy_set_header X-Real-IP $remote_addr;
      proxy_buffering off;
      proxy_request_buffering off;
      client_max_body_size 0;
      proxy_read_timeout 3600s;
      proxy_send_timeout 3600s;
    }}
    location /panel/ {{
      proxy_pass http://127.0.0.1:8765/;
      proxy_set_header Host $host;
      proxy_set_header X-Real-IP $remote_addr;
      proxy_set_header X-Forwarded-Proto $scheme;
    }}
    location = /health {{ default_type text/plain; return 200 "ok\n"; }}
    location / {{ default_type text/html; return 200 "<h1>Welcome</h1>"; }}
'''
    blocks=[]
    for port in (80,8080,8880):
      blocks.append(f'''server {{
    listen {port};
    listen [::]:{port};
    server_name {d};
{locations}
}}''')
    if tls:
      blocks.append(f'''server {{
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name {d};
    ssl_certificate {cert};
    ssl_certificate_key {key};
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;
{locations}
}}''')
    return "\n\n".join(blocks)+"\n"
def atomic_write(path,text,mode=0o600):
    path.parent.mkdir(parents=True,exist_ok=True)
    fd,tmp=tempfile.mkstemp(dir=path.parent,prefix="."+path.name+".",text=True)
    with os.fdopen(fd,"w") as f: f.write(text); f.flush(); os.fsync(f.fileno())
    os.chmod(tmp,mode); os.replace(tmp,path)
def apply(s,restart=True):
    cfg=gen_xray(s); oldx=XRAY_CFG.read_text() if XRAY_CFG.exists() else None
    oldn=NGINX_CFG.read_text() if NGINX_CFG.exists() else None
    atomic_write(XRAY_CFG,json.dumps(cfg,indent=2))
    atomic_write(NGINX_CFG,nginx_text(s),0o644)
    tx=run(["/usr/local/bin/xray","run","-test","-config",str(XRAY_CFG)],check=False)
    tn=run(["nginx","-t"],check=False)
    if tx.returncode or tn.returncode:
      if oldx is None: XRAY_CFG.unlink(missing_ok=True)
      else: atomic_write(XRAY_CFG,oldx)
      if oldn is None: NGINX_CFG.unlink(missing_ok=True)
      else: atomic_write(NGINX_CFG,oldn,0o644)
      raise RuntimeError("Validation failed:\n"+(tx.stderr or tx.stdout)+"\n"+(tn.stderr or tn.stdout))
    save(s)
    if restart: svc("xray","restart"); svc("nginx","reload")
def ensure_admin(s):
    if not s["admin"].get("secret"): s["admin"]["secret"]=secrets.token_urlsafe(48)
    if not s["admin"].get("password_hash"):
      pw=os.environ.get("XRAY_ADMIN_PASSWORD") or secrets.token_urlsafe(12)
      s["admin"]["password_hash"]=hash_pw(pw); save(s)
      print(f"Initial panel login: admin / {pw}")
def uri_for(s,u,kind,tls=True,port=None):
    host=s["domain"] or s["public_ip"]; sec="tls" if tls else "none"; port=port or (443 if tls else 80)
    net={"ws":"ws","upgrade":"httpupgrade","xhttp":"xhttp"}[kind]
    path=s["paths"][kind]
    q={"encryption":"none","security":sec,"type":net,"path":path}
    if tls: q["sni"]=s["domain"]; q["fp"]="chrome"
    return f'vless://{u["uuid"]}@{host}:{port}?{urllib.parse.urlencode(q)}#{urllib.parse.quote(u["name"]+"-"+kind)}'
def add_user(s,name,days,trial=False):
    if any(x["name"]==name for x in s["users"]): raise ValueError("User already exists")
    exp=dt.date.today()+dt.timedelta(days=int(days))
    s["users"].append({"name":name,"uuid":str(uuid.uuid4()),"expires":exp.isoformat(),"enabled":True,"trial":trial,"created_at":now()})
    apply(s); return s["users"][-1]
def remove_expired(s):
    today=dt.date.today(); before=len(s["users"])
    s["users"]=[u for u in s["users"] if dt.date.fromisoformat(u["expires"])>=today]
    apply(s); return before-len(s["users"])
def add_proxy(s,ptype,host,port,user="",password=""):
    socket.getaddrinfo(host,int(port))
    x={"id":secrets.token_hex(4),"type":ptype,"host":host,"port":int(port),"user":user,"pass":password,"enabled":True,"created_at":now()}
    s["proxies"].append(x); save(s); return x
def check_proxy(p):
    scheme="socks5h" if p["type"] in ("socks5","socks5h") else "http"
    auth=""
    if p.get("user"): auth=urllib.parse.quote(p["user"])+":"+urllib.parse.quote(p.get("pass",""))+"@"
    url=f"{scheme}://{auth}{p['host']}:{p['port']}"
    r=run(["curl","-fsS","--connect-timeout","7","--max-time","12","--proxy",url,"https://www.gstatic.com/generate_204","-o","/dev/null","-w","%{http_code} %{time_total}"],check=False)
    return {"ok":r.returncode==0 and r.stdout.startswith("204"),"result":(r.stdout or r.stderr).strip()}
def dashboard(s):
    print("="*68)
    print(f" Xray Manager | IP: {s.get('public_ip') or '-'} | Domain: {s.get('domain') or '-'}")
    print("-"*68)
    print(f" Xray: {svc_state('xray'):<12} Nginx: {svc_state('nginx'):<12} Panel: {svc_state('xray-manager')}")
    print(f" Users: {len(active_users(s))}/{len(s['users'])}   Proxy: {s['proxy_mode']} / {s.get('active_proxy') or '-'}")
    print(f" DNS: {', '.join(s['dns'])}   IPv6: {'ON' if s['ipv6'] else 'OFF'}   TUN: {'ON' if s['tun'] else 'OFF'}")
    print("="*68)
def menu_users(s):
    while True:
      os.system("clear"); dashboard(s)
      print("1 Add user      2 Trial user     3 Renew user")
      print("4 Delete user   5 List/config    6 Remove expired   0 Back")
      c=input("> ").strip()
      try:
       if c in ("1","2"):
        u=add_user(s,input("Name: ").strip(),input("Days: ").strip(),c=="2"); print(json.dumps(u,indent=2)); input("Enter...")
       elif c=="3":
        n=input("Name: "); days=int(input("Add days: "))
        u=next(x for x in s["users"] if x["name"]==n); base=max(dt.date.today(),dt.date.fromisoformat(u["expires"])); u["expires"]=(base+dt.timedelta(days=days)).isoformat(); apply(s)
       elif c=="4":
        n=input("Name: "); s["users"]=[x for x in s["users"] if x["name"]!=n]; apply(s)
       elif c=="5":
        for u in s["users"]:
          print(f'\n{u["name"]} exp={u["expires"]} enabled={u["enabled"]}')
          for k in ("ws","upgrade","xhttp"): print(uri_for(s,u,k))
        input("\nEnter...")
       elif c=="6": print("Removed:",remove_expired(s)); time.sleep(2)
       elif c=="0": return
      except Exception as e: print("ERROR:",e); input("Enter...")
def menu_proxy(s):
    while True:
      os.system("clear"); dashboard(s)
      print("1 Add proxy      2 List/check       3 Select active")
      print("4 Mode off/full/domain-list       5 Add bypass domain")
      print("6 Delete bypass  7 Rotate best      8 Delete proxy      0 Back")
      c=input("> ").strip()
      try:
       if c=="1":
        p=add_proxy(s,input("Type socks5/socks5h/http: "),input("Host/IP: "),int(input("Port: ")),input("User(optional): "),getpass.getpass("Password(optional): "))
        print(p); input("Enter...")
       elif c=="2":
        for p in s["proxies"]: print(p["id"],p["type"],p["host"],p["port"],"ACTIVE" if p["id"]==s.get("active_proxy") else "",check_proxy(p))
        input("Enter...")
       elif c=="3":
        s["active_proxy"]=input("Proxy ID: ").strip(); apply(s)
       elif c=="4":
        m=input("Mode off/full/bypass: ").strip(); assert m in ("off","full","bypass"); s["proxy_mode"]=m; apply(s)
       elif c=="5":
        d=input("Domain or geosite rule (e.g. domain:netflix.com): ").strip(); s["bypass_domains"].append(d); apply(s)
       elif c=="6":
        d=input("Exact rule to delete: "); s["bypass_domains"]=[x for x in s["bypass_domains"] if x!=d]; apply(s)
       elif c=="7":
        results=[(float(check_proxy(p)["result"].split()[-1]),p) for p in s["proxies"] if check_proxy(p)["ok"]]
        if not results: raise RuntimeError("No working proxy")
        s["active_proxy"]=min(results,key=lambda x:x[0])[1]["id"]; apply(s); print("Selected",s["active_proxy"]); time.sleep(2)
       elif c=="8":
        pid=input("Proxy ID: "); s["proxies"]=[x for x in s["proxies"] if x["id"]!=pid]; 
        if s.get("active_proxy")==pid: s["active_proxy"]=None; s["proxy_mode"]="off"
        apply(s)
       elif c=="0": return
      except Exception as e: print("ERROR:",e); input("Enter...")
def issue_ssl(s):
    if not s["domain"]: raise RuntimeError("Set domain first")
    d=s["domain"]; CERT_DIR.mkdir(parents=True,exist_ok=True)
    run(["systemctl","stop","nginx"],check=False)
    try:
      cmd=[str(pathlib.Path.home()/".acme.sh/acme.sh"),"--issue","--standalone","-d",d,"--keylength","ec-256","--server","letsencrypt"]
      run(cmd)
      run([cmd[0],"--install-cert","-d",d,"--ecc","--fullchain-file",str(CERT_DIR/"fullchain.pem"),
           "--key-file",str(CERT_DIR/"privkey.pem"),"--reloadcmd","systemctl reload nginx"])
    finally: run(["systemctl","start","nginx"],check=False)
    apply(s)
def menu_system(s):
    while True:
      os.system("clear"); dashboard(s)
      print("1 Set domain/IP    2 Issue SSL ACME    3 Restart all")
      print("4 IPv6 on/off      5 Set DNS           6 TUN on/off")
      print("7 Update Xray latest  8 Autoreboot       9 Change admin password  0 Back")
      c=input("> ").strip()
      try:
       if c=="1": s["domain"]=input("Domain (DNS A/AAAA must point here): ").strip().lower(); s["public_ip"]=public_ip(); apply(s)
       elif c=="2": issue_ssl(s)
       elif c=="3": svc("xray","restart"); svc("nginx","restart"); svc("xray-manager","restart")
       elif c=="4":
        s["ipv6"]=not s["ipv6"]; atomic_write(pathlib.Path("/etc/sysctl.d/99-xray-ipv6.conf"),f"net.ipv6.conf.all.disable_ipv6 = {0 if s['ipv6'] else 1}\nnet.ipv6.conf.default.disable_ipv6 = {0 if s['ipv6'] else 1}\n",0o644); run(["sysctl","--system"],check=False); apply(s)
       elif c=="5":
        choice=input("1 Cloudflare  2 Google  3 Custom: ")
        s["dns"]={"1":["1.1.1.1","1.0.0.1"],"2":["8.8.8.8","8.8.4.4"]}.get(choice,[x.strip() for x in input("Comma separated DNS: ").split(",")]); apply(s)
       elif c=="6": s["tun"]=not s["tun"]; apply(s)
       elif c=="7": run(["bash","-c","bash -c \"$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)\" @ install"]); svc("xray","restart")
       elif c=="8":
        h=input("Hour 0-23 (blank disables): ").strip()
        cron=pathlib.Path("/etc/cron.d/xray-autoreboot")
        if h: atomic_write(cron,f"0 {int(h)} * * * root /sbin/reboot\n",0o644)
        else: cron.unlink(missing_ok=True)
       elif c=="9":
        pw=getpass.getpass("New password: "); assert len(pw)>=10; s["admin"]["password_hash"]=hash_pw(pw); save(s); print("Changed"); time.sleep(1)
       elif c=="0": return
      except Exception as e: print("ERROR:",e); input("Enter...")
def cli():
    s=load(); ensure_admin(s)
    while True:
      os.system("clear"); dashboard(s)
      print("┌──────────────────────────────┬──────────────────────────────┐")
      print("│ 1 Install / repair           │ 2 VLESS users                │")
      print("│ 3 SOCKS5 / HTTP proxy        │ 4 System                     │")
      print("│ 5 Uninstall                  │ 0 Back / Exit                │")
      print("└──────────────────────────────┴──────────────────────────────┘")
      c=input("> ").strip()
      if c=="1": s["public_ip"]=public_ip(); apply(s); print("Installed/repaired"); time.sleep(2)
      elif c=="2": menu_users(s)
      elif c=="3": menu_proxy(s)
      elif c=="4": menu_system(s)
      elif c=="5":
        if input("Type UNINSTALL: ")=="UNINSTALL": run(["systemctl","disable","--now","xray-manager"],check=False); shutil.rmtree(ROOT,ignore_errors=True); print("Manager removed. Xray/Nginx retained."); return
      elif c=="0": return
def command():
    ap=argparse.ArgumentParser(); sub=ap.add_subparsers(dest="cmd")
    sub.add_parser("apply"); sub.add_parser("dashboard"); sub.add_parser("remove-expired")
    a=sub.add_parser("add-user"); a.add_argument("name"); a.add_argument("--days",type=int,default=30)
    a=sub.add_parser("delete-user"); a.add_argument("name")
    a=sub.add_parser("renew-user"); a.add_argument("name"); a.add_argument("--days",type=int,default=30)
    args=ap.parse_args()
    if not args.cmd: cli(); return
    s=load()
    if args.cmd=="apply": apply(s)
    elif args.cmd=="dashboard": dashboard(s)
    elif args.cmd=="remove-expired": print(remove_expired(s))
    elif args.cmd=="add-user": print(json.dumps(add_user(s,args.name,args.days),indent=2))
    elif args.cmd=="delete-user": s["users"]=[u for u in s["users"] if u["name"]!=args.name]; apply(s)
    elif args.cmd=="renew-user":
      u=next(u for u in s["users"] if u["name"]==args.name); base=max(dt.date.today(),dt.date.fromisoformat(u["expires"])); u["expires"]=(base+dt.timedelta(days=args.days)).isoformat(); apply(s)
if __name__=="__main__": command()
PYEOF

  cat >"$APP_DIR/web.py" <<'PYEOF'
#!/usr/bin/env python3
import datetime as dt, functools, html, json, os, secrets, subprocess
from flask import Flask, request, redirect, session, url_for, flash
import manager as m
app=Flask(__name__)
s=m.load(); m.ensure_admin(s); app.secret_key=s["admin"]["secret"]
CSS='''<style>
body{font-family:system-ui;background:#0b1020;color:#e8ecff;margin:0}.wrap{max-width:1100px;margin:auto;padding:18px}
nav{display:flex;gap:10px;flex-wrap:wrap;margin-bottom:18px}a,button{color:white;background:#3346d3;border:0;padding:10px 14px;border-radius:10px;text-decoration:none}
.grid{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:14px}.card{background:#151d35;padding:16px;border-radius:16px;overflow:auto}
input,select{width:100%;box-sizing:border-box;padding:10px;margin:5px 0 12px;border-radius:8px;border:1px solid #445;background:#0d1428;color:white}
table{width:100%;border-collapse:collapse}td,th{padding:8px;border-bottom:1px solid #2a3557;text-align:left}.ok{color:#69e29b}.bad{color:#ff7b88}
@media(max-width:700px){.grid{grid-template-columns:1fr}.wrap{padding:10px}}
</style>'''
def page(title,body):
 return f'<!doctype html><meta name=viewport content="width=device-width,initial-scale=1"><title>{html.escape(title)}</title>{CSS}<div class=wrap><h1>{html.escape(title)}</h1><nav><a href="/panel/">Dashboard</a><a href="/panel/users">Users</a><a href="/panel/proxies">Proxies</a><a href="/panel/system">System</a><a href="/panel/logout">Logout</a></nav>{body}</div>'
def auth(f):
 @functools.wraps(f)
 def w(*a,**k):
  if not session.get("ok"): return redirect("/panel/login")
  return f(*a,**k)
 return w
@app.route("/login",methods=["GET","POST"])
def login():
 s=m.load()
 if request.method=="POST" and request.form.get("username")==s["admin"]["username"] and m.verify_pw(request.form.get("password",""),s["admin"]["password_hash"]):
  session["ok"]=True; return redirect("/panel/")
 return page("Admin Login",'<form method=post><input name=username placeholder=Username><input type=password name=password placeholder=Password><button>Login</button></form>')
@app.route("/logout")
def logout(): session.clear(); return redirect("/panel/login")
@app.route("/")
@auth
def index():
 s=m.load(); ap=next((p for p in s["proxies"] if p["id"]==s.get("active_proxy")),None)
 cards=[("Xray",m.svc_state("xray")),("Nginx",m.svc_state("nginx")),("SOCKS/HTTP","on" if s["proxy_mode"]!="off" else "off"),("IP",s["public_ip"]),("Domain",s["domain"]),("Active users",str(len(m.active_users(s)))),("DNS",", ".join(s["dns"])),("Proxy",(f'{ap["type"]} {ap["host"]}:{ap["port"]}' if ap else "none"))]
 return page("Xray Dashboard",'<div class=grid>'+''.join(f'<div class=card><b>{html.escape(a)}</b><h2>{html.escape(b or "-")}</h2></div>' for a,b in cards)+'</div>')
@app.route("/users",methods=["GET","POST"])
@auth
def users():
 s=m.load()
 try:
  if request.method=="POST":
   act=request.form["act"]; name=request.form.get("name","").strip()
   if act=="add": m.add_user(s,name,int(request.form.get("days",30)))
   elif act=="delete": s["users"]=[u for u in s["users"] if u["name"]!=name]; m.apply(s)
   elif act=="renew":
    u=next(u for u in s["users"] if u["name"]==name); u["expires"]=(max(dt.date.today(),dt.date.fromisoformat(u["expires"]))+dt.timedelta(days=int(request.form.get("days",30)))).isoformat(); m.apply(s)
   elif act=="expired": m.remove_expired(s)
   return redirect("/panel/users")
 except Exception as e: flash(str(e))
 rows=""
 for u in s["users"]:
  cfg="<br>".join(html.escape(m.uri_for(s,u,k)) for k in ("ws","upgrade","xhttp"))
  rows+=f'<tr><td>{html.escape(u["name"])}</td><td>{u["expires"]}</td><td><details><summary>Config</summary><small>{cfg}</small></details></td><td><form method=post><input type=hidden name=name value="{html.escape(u["name"])}"><button name=act value=delete>Delete</button><button name=act value=renew>Renew</button><input name=days value=30></form></td></tr>'
 body='<div class=card><form method=post><input name=name placeholder=Name required><input name=days type=number value=30><button name=act value=add>Add user</button><button name=act value=expired>Remove expired</button></form></div><div class=card><table><tr><th>Name</th><th>Expiry</th><th>Config</th><th>Action</th></tr>'+rows+'</table></div>'
 return page("VLESS Users",body)
@app.route("/proxies",methods=["GET","POST"])
@auth
def proxies():
 s=m.load()
 try:
  if request.method=="POST":
   a=request.form["act"]
   if a=="add": m.add_proxy(s,request.form["type"],request.form["host"],int(request.form["port"]),request.form.get("user",""),request.form.get("password",""))
   elif a=="select": s["active_proxy"]=request.form["id"]; m.apply(s)
   elif a=="delete": s["proxies"]=[p for p in s["proxies"] if p["id"]!=request.form["id"]]; m.apply(s)
   elif a=="mode": s["proxy_mode"]=request.form["mode"]; m.apply(s)
   elif a=="domain": s["bypass_domains"].append(request.form["domain"]); m.apply(s)
   return redirect("/panel/proxies")
 except Exception as e: flash(str(e))
 rows=''.join(f'<tr><td>{p["id"]}</td><td>{p["type"]}</td><td>{html.escape(p["host"])}:{p["port"]}</td><td>{"active" if p["id"]==s.get("active_proxy") else ""}</td><td><form method=post><input type=hidden name=id value={p["id"]}><button name=act value=select>Select</button><button name=act value=delete>Delete</button></form></td></tr>' for p in s["proxies"])
 body=f'''<div class=grid><div class=card><h3>Add proxy</h3><form method=post><select name=type><option>socks5h</option><option>socks5</option><option>http</option></select><input name=host placeholder=Host required><input name=port type=number placeholder=Port required><input name=user placeholder=User><input name=password type=password placeholder=Password><button name=act value=add>Add</button></form></div>
 <div class=card><h3>Routing</h3><form method=post><select name=mode><option>off</option><option>full</option><option>bypass</option></select><button name=act value=mode>Set mode</button></form><form method=post><input name=domain placeholder="domain:netflix.com"><button name=act value=domain>Add domain rule</button></form><pre>{html.escape(json.dumps(s["bypass_domains"],indent=2))}</pre></div></div>
 <div class=card><table><tr><th>ID</th><th>Type</th><th>Endpoint</th><th>Status</th><th>Action</th></tr>{rows}</table></div>'''
 return page("Proxy Manager",body)
@app.route("/system",methods=["GET","POST"])
@auth
def system():
 s=m.load()
 try:
  if request.method=="POST":
   a=request.form["act"]
   if a=="domain": s["domain"]=request.form["domain"].strip().lower(); s["public_ip"]=m.public_ip(); m.apply(s)
   elif a=="dns": s["dns"]=[x.strip() for x in request.form["dns"].split(",")]; m.apply(s)
   elif a=="ipv6": s["ipv6"]=not s["ipv6"]; m.save(s)
   elif a=="restart":
    for x in ("xray","nginx","xray-manager"): m.svc(x,"restart")
   elif a=="ssl": m.issue_ssl(s)
   return redirect("/panel/system")
 except Exception as e: flash(str(e))
 body=f'''<div class=grid><div class=card><form method=post><label>Domain</label><input name=domain value="{html.escape(s["domain"])}"><button name=act value=domain>Save domain</button><button name=act value=ssl>Issue SSL ACME</button></form></div>
 <div class=card><form method=post><label>DNS comma separated</label><input name=dns value="{html.escape(",".join(s["dns"]))}"><button name=act value=dns>Save DNS</button></form></div>
 <div class=card><form method=post><button name=act value=ipv6>Toggle IPv6 ({s["ipv6"]})</button></form></div>
 <div class=card><form method=post><button name=act value=restart>Restart services</button></form></div></div>'''
 return page("System",body)
if __name__=="__main__": app.run("127.0.0.1",8765)
PYEOF

  python3 -m venv "$VENV"
  "$VENV/bin/pip" -q install --upgrade pip
  "$VENV/bin/pip" -q install flask gunicorn

  cat >"$BIN" <<EOF
#!/usr/bin/env bash
exec "$VENV/bin/python" "$PY" "\$@"
EOF
  chmod +x "$BIN" "$PY" "$APP_DIR/web.py"

  cat >/etc/systemd/system/xray-manager.service <<EOF
[Unit]
Description=Xray Manager Web Panel
After=network-online.target xray.service nginx.service
Wants=network-online.target
[Service]
Type=simple
WorkingDirectory=$APP_DIR
ExecStart=$VENV/bin/gunicorn --workers 2 --bind 127.0.0.1:8765 web:app
Restart=on-failure
RestartSec=3
User=root
UMask=0077
[Install]
WantedBy=multi-user.target
EOF

  # Install acme.sh from its official installer.
  if [[ ! -x /root/.acme.sh/acme.sh ]]; then
    curl -fsSL https://get.acme.sh | sh -s email="${ACME_EMAIL:-admin@invalid.local}"
  fi

  "$BIN" apply
  systemctl daemon-reload
  systemctl enable --now xray nginx xray-manager
  cat >/etc/cron.d/xray-expired-users <<EOF
17 3 * * * root $BIN remove-expired >/dev/null 2>&1
EOF
  chmod 644 /etc/cron.d/xray-expired-users

  echo
  echo "Installed."
  echo "CLI: xray-manager"
  echo "Panel after domain/TLS: https://YOUR-DOMAIN/panel/"
  echo "Current state file: $APP_DIR/data/state.json"
}
case "${1:-install}" in
 install) install_all ;;
 menu) need_root; exec "$BIN" ;;
 uninstall)
   need_root
   systemctl disable --now xray-manager 2>/dev/null || true
   rm -f /etc/systemd/system/xray-manager.service /etc/nginx/conf.d/xray-manager.conf "$BIN" /etc/cron.d/xray-expired-users
   rm -rf "$APP_DIR"
   systemctl daemon-reload
   systemctl reload nginx 2>/dev/null || true
   echo "Manager removed; Xray core and Nginx packages retained."
   ;;
 *) echo "Usage: $0 {install|menu|uninstall}"; exit 2 ;;
esac
