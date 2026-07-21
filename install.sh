#!/usr/bin/env bash
set -Eeuo pipefail
[[ $EUID -eq 0 ]] || { echo "Run as root"; exit 1; }
APP=/opt/xray-mobile
mkdir -p "$APP"
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y python3 curl unzip jq nginx certbot python3-certbot-nginx dnsutils cron uuid-runtime ca-certificates
cat > "$APP/manager.py" <<'PY'
#!/usr/bin/env python3
import json, os, re, shutil, subprocess, tempfile, time, uuid
from pathlib import Path
from datetime import date, timedelta

A=Path("/opt/xray-mobile"); S=A/"state.json"
XC=Path("/usr/local/etc/xray/config.json")
NC=Path("/etc/nginx/sites-available/xray-mobile.conf")
NL=Path("/etc/nginx/sites-enabled/xray-mobile.conf")
XB=Path("/usr/local/bin/xray")
DEF={"domain":"","email":"","dns":["1.1.1.1","8.8.8.8"],"ipv6":True,"users":[],"proxies":[],
"proxy":{"enabled":False,"mode":"off","selected":[],"domains":[],"rotate":False,"balance":"random"},
"paths":{"ws":"/vless-ws","httpupgrade":"/vless-hu","xhttp":"/vless-xhttp"},
"ports":{"ws":11001,"httpupgrade":11002,"xhttp":11003}}

def sh(x,check=True,cap=False):
 p=subprocess.run(x,shell=isinstance(x,str),text=True,stdout=subprocess.PIPE if cap else None,stderr=subprocess.PIPE if cap else None)
 if check and p.returncode: raise RuntimeError((p.stderr or p.stdout or "command failed").strip())
 return (p.stdout or "").strip() if cap else p.returncode
def load():
 if not S.exists(): save(DEF.copy())
 d=json.loads(S.read_text())
 for k,v in DEF.items():
  if k not in d:d[k]=v
  elif isinstance(v,dict):
   for a,b in v.items():
    if a not in d[k]:d[k][a]=b
 return d
def save(d): S.write_text(json.dumps(d,indent=2)); os.chmod(S,0o600)
def active(u): return not u.get("expiry") or date.fromisoformat(u["expiry"])>=date.today()
def svc(n): return sh(["systemctl","is-active","--quiet",n],False)==0
def ip():
 try:return sh(["curl","-4fsS","--max-time","4","https://api.ipify.org"],cap=True)
 except:return "-"
def pause(): input("\nEnter...")
def dash(d,t="XRAY MOBILE"):
 os.system("clear")
 p=", ".join(d["proxy"]["selected"]) if d["proxy"]["enabled"] else "direct"
 print("╭──────────────────────────────────────────────────────────────╮")
 print(f"│ {t:^60} │")
 print("├──────────────────────────────┬───────────────────────────────┤")
 print(f"│ Xray: {'ON' if svc('xray') else 'OFF':<22}│ IP: {ip():<26}│")
 print(f"│ Nginx: {'ON' if svc('nginx') else 'OFF':<21}│ Domain: {d['domain'] or '-':<22}│")
 print(f"│ Proxy: {'ON' if d['proxy']['enabled'] else 'OFF':<21}│ Users: {sum(active(u) for u in d['users']):<23}│")
 print(f"│ DNS: {','.join(d['dns']):<23}│ Out: {p[:24]:<24}│")
 print("╰──────────────────────────────┴───────────────────────────────╯")
def menu(title,items):
 print("\n"+title)
 r=(len(items)+1)//2
 for i in range(r):
  a=items[i]; b=items[i+r] if i+r<len(items) else ("","")
  print(f" [{a[0]}] {a[1]:<27} [{b[0]}] {b[1]}")
 return input("\nPilih > ").strip().lower()
def install_xray(ver="latest"):
 cmd='bash -c "$(curl -LfsS https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install'
 if ver not in ("latest",""):
  v=ver if ver.startswith("v") else "v"+ver
  cmd+=' --version '+v
 sh(cmd)
 if not XB.exists(): raise RuntimeError("Xray binary tidak ditemui selepas pemasangan")
 sh(["systemctl","daemon-reload"])
 return sh([str(XB),"version"],cap=True).splitlines()[0]
def service():
 sh(["systemctl","daemon-reload"])
def out(p):
 tag="proxy-"+re.sub("[^A-Za-z0-9_-]","-",p["name"]); sv={"address":p["host"],"port":int(p["port"])}
 if p.get("username"): sv["users"]=[{"user":p["username"],"pass":p.get("password","")}]
 if p["type"] in ("socks5","socks5h"):
  return {"tag":tag,"protocol":"socks","settings":{"servers":[sv]},"streamSettings":{"sockopt":{"domainStrategy":"AsIs" if p["type"]=="socks5h" else "UseIP"}}}
 return {"tag":tag,"protocol":"http","settings":{"servers":[sv]}}
def genx(d):
 cl=[{"id":u["uuid"],"email":u["name"]} for u in d["users"] if active(u)]
 ins=[]
 for n,net in (("ws","ws"),("httpupgrade","httpupgrade"),("xhttp","xhttp")):
  st={"path":d["paths"][n]}; 
  if n=="xhttp": st["mode"]="auto"
  ins.append({"tag":"in-"+n,"listen":"127.0.0.1","port":d["ports"][n],"protocol":"vless","settings":{"clients":cl,"decryption":"none"},"streamSettings":{"network":net,net+"Settings":st},"sniffing":{"enabled":True,"destOverride":["http","tls","quic"],"routeOnly":True}})
 outs=[{"tag":"direct","protocol":"freedom","settings":{"domainStrategy":"UseIP"}},{"tag":"block","protocol":"blackhole","settings":{}}]+[out(p) for p in d["proxies"] if p.get("enabled",True)]
 sel=[p for p in d["proxies"] if p.get("enabled",True) and p["name"] in d["proxy"]["selected"]]
 tags=["proxy-"+re.sub("[^A-Za-z0-9_-]","-",p["name"]) for p in sel]
 rt={"domainStrategy":"IPIfNonMatch","rules":[{"type":"field","ip":["geoip:private"],"outboundTag":"direct"},{"type":"field","protocol":["bittorrent"],"outboundTag":"block"}]}
 if d["proxy"]["enabled"] and tags:
  if len(tags)>1:
   strategy=d["proxy"].get("balance","random")
   rt["balancers"]=[{"tag":"proxy-pool","selector":tags,"strategy":{"type":strategy}}]; target={"balancerTag":"proxy-pool"}
  else: target={"outboundTag":tags[0]}
  if d["proxy"]["mode"]=="full": rt["rules"].append({"type":"field","network":"tcp,udp",**target})
  elif d["proxy"]["mode"]=="domain":
   dom=[x if x.startswith(("domain:","full:","regexp:","geosite:")) else "domain:"+x for x in d["proxy"]["domains"]]
   if dom: rt["rules"].append({"type":"field","domain":dom,**target})
 cfg={"log":{"loglevel":"warning"},"dns":{"servers":d["dns"],"queryStrategy":"UseIP" if d["ipv6"] else "UseIPv4"},"inbounds":ins,"outbounds":outs,"routing":rt}
 if d["proxy"].get("balance")=="leastPing" and len(tags)>1:
  cfg["observatory"]={"subjectSelector":tags,"probeURL":"https://www.gstatic.com/generate_204","probeInterval":"30s","enableConcurrency":True}
 XC.parent.mkdir(parents=True,exist_ok=True); XC.write_text(json.dumps(cfg,indent=2))
def genn(d):
 dom=d["domain"] or "_"; tls=Path(f"/etc/letsencrypt/live/{dom}/fullchain.pem").exists()
 loc=[]
 for n in ("ws","httpupgrade","xhttp"):
  up='' if n=="xhttp" else 'proxy_set_header Upgrade $http_upgrade;\n        proxy_set_header Connection "upgrade";'
  loc.append(f'''location {d["paths"][n]} {{
        proxy_pass http://127.0.0.1:{d["ports"][n]};
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        {up}
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_read_timeout 3600s;
    }}''')
 common=f"server_name {dom};\n    client_max_body_size 0;\n    "+("\n    ".join(loc))+'\n    location / { return 200 "OK\\n"; }'
 txt=f"server {{ listen 80; listen 8080; listen 8880; {common} }}\n"
 if tls:
  ver=sh(["nginx","-v"],False,True); m=re.search(r"nginx/(\d+)\.(\d+)\.(\d+)",ver)
  modern=bool(m and tuple(map(int,m.groups())) >= (1,25,1))
  h2="listen 443 ssl; listen [::]:443 ssl; http2 on;" if modern else "listen 443 ssl http2; listen [::]:443 ssl http2;"
  txt+=f"server {{ {h2} {common} ssl_certificate /etc/letsencrypt/live/{dom}/fullchain.pem; ssl_certificate_key /etc/letsencrypt/live/{dom}/privkey.pem; ssl_protocols TLSv1.2 TLSv1.3; }}\n"
 NC.write_text(txt); NL.unlink(missing_ok=True); NL.symlink_to(NC); Path("/etc/nginx/sites-enabled/default").unlink(missing_ok=True)
def apply(d):
 genx(d); genn(d); sh([str(XB),"run","-test","-config",str(XC)]); sh(["nginx","-t"]); sh(["systemctl","enable","--now","xray","nginx"]); sh(["systemctl","restart","xray"]); sh(["systemctl","reload","nginx"])
def install(d): print("Installed",install_xray()); apply(d); Path("/etc/cron.d/xray-mobile").write_text("17 3 * * * root /usr/local/sbin/xray-mobile --purge-expired\n")
def showcfg(d,u,p):
 h=d["domain"] or ip(); q={"ws":f"type=ws&security=tls&path={d['paths']['ws']}&host={h}&sni={h}","httpupgrade":f"type=httpupgrade&security=tls&path={d['paths']['httpupgrade']}&host={h}&sni={h}","xhttp":f"type=xhttp&security=tls&path={d['paths']['xhttp']}&host={h}&sni={h}&mode=auto"}[p]
 print(f"vless://{u['uuid']}@{h}:443?{q}#{u['name']}-{p}")
 print(f"vless://{u['uuid']}@{h}:80?{q.replace('security=tls','security=none').replace('&sni='+h,'')}#{u['name']}-{p}-ntls")
def users(d,p):
 while 1:
  dash(d,"VLESS "+p.upper()); c=menu("User",[("1","Add"),("2","Trial"),("3","List/config"),("4","Renew"),("5","Delete"),("6","Purge expired"),("0","Back")])
  if c=="0":return
  try:
   if c in ("1","2"):
    n=input("Nama: "); days=int(input("Hari: ") or ("1" if c=="2" else "30")); u={"name":n,"uuid":str(uuid.uuid4()),"expiry":(date.today()+timedelta(days=days)).isoformat()}; d["users"].append(u);save(d);apply(d);showcfg(d,u,p)
   elif c=="3":
    for i,u in enumerate(d["users"],1): print(i,u["name"],u["expiry"])
    x=input("No config (blank back): "); 
    if x: showcfg(d,d["users"][int(x)-1],p)
   elif c=="4":
    n=input("Nama: "); days=int(input("Tambah hari: ") or "30")
    for u in d["users"]:
     if u["name"]==n:u["expiry"]=(max(date.today(),date.fromisoformat(u["expiry"]))+timedelta(days=days)).isoformat()
    save(d);apply(d)
   elif c=="5":
    n=input("Nama: "); d["users"]=[u for u in d["users"] if u["name"]!=n];save(d);apply(d)
   elif c=="6":
    d["users"]=[u for u in d["users"] if active(u)];save(d);apply(d)
  except Exception as e: print("ERROR",e)
  pause();d=load()
def vmenu(d):
 while 1:
  dash(d,"VLESS"); c=menu("Transport",[("1","WebSocket"),("2","HTTPUpgrade"),("3","XHTTP"),("0","Back")])
  if c=="0":return
  if c in ("1","2","3"): users(d,{"1":"ws","2":"httpupgrade","3":"xhttp"}[c]);d=load()
def plist(d,reveal=False):
 for i,p in enumerate(d["proxies"],1): print(i,p["name"],p["type"],f"{p['host']}:{p['port']}",p.get("username",""),p.get("password","") if reveal else "***", "ON" if p.get("enabled",True) else "OFF")
def pmenu(d):
 while 1:
  dash(d,"SOCKS5 / HTTP"); c=menu("Proxy",[("1","Enable/disable"),("2","Mode full/domain/off"),("3","Add"),("4","List"),("5","Select"),("6","Delete"),("7","Test"),("8","Domains"),("9","Load balance"),("a","Show secrets"),("0","Back")])
  if c=="0":return
  try:
   if c=="1": d["proxy"]["enabled"]=not d["proxy"]["enabled"];save(d);apply(d)
   elif c=="2":
    m=input("full/domain/off: ");d["proxy"]["mode"]=m;d["proxy"]["enabled"]=m!="off";save(d);apply(d)
   elif c=="3":
    p={"name":input("Nama: "),"type":input("socks5/socks5h/http: "),"host":input("Host: "),"port":int(input("Port: ")),"username":input("User optional: "),"password":input("Pass optional: "),"enabled":True};d["proxies"].append(p);save(d);apply(d)
   elif c=="4":plist(d)
   elif c=="5":plist(d);d["proxy"]["selected"]=[x.strip() for x in input("Nama pisah koma: ").split(",") if x.strip()];save(d);apply(d)
   elif c=="6": n=input("Nama delete: ");d["proxies"]=[p for p in d["proxies"] if p["name"]!=n];save(d);apply(d)
   elif c=="7":
    for p in d["proxies"]:
     sc={"socks5":"socks5","socks5h":"socks5h","http":"http"}[p["type"]];au=f"{p['username']}:{p['password']}@" if p.get("username") else "";url=f"{sc}://{au}{p['host']}:{p['port']}";t=time.time()
     try: print(p["name"],sh(["curl","-fsS","--max-time","12","--proxy",url,"https://api.ipify.org"],cap=True),round((time.time()-t)*1000),"ms")
     except Exception as e:print(p["name"],"FAIL")
   elif c=="8": d["proxy"]["domains"]=[x.strip() for x in input("Domains comma: ").split(",") if x.strip()];save(d);apply(d)
   elif c=="9":
    b=input("random/leastPing: ").strip()
    if b not in ("random","leastPing"): raise RuntimeError("Strategy tidak sah")
    d["proxy"]["balance"]=b;save(d);apply(d)
   elif c=="a":plist(d,True)
  except Exception as e:print("ERROR",e)
  pause();d=load()
def sysmenu(d):
 while 1:
  dash(d,"SYSTEM");c=menu("System",[("1","Set domain"),("2","Issue SSL"),("3","Autoreboot"),("4","Restart all"),("5","IPv6 on/off"),("6","DNS"),("7","Update Xray"),("8","Test config"),("0","Back")])
  if c=="0":return
  try:
   if c=="1": d["domain"]=input("Domain: ").strip();save(d);apply(d)
   elif c=="2":
    d["domain"]=input(f"Domain [{d['domain']}]: ") or d["domain"];d["email"]=input("Email: ") or d.get("email","");save(d);genn(d);sh(["nginx","-t"]);sh(["systemctl","reload","nginx"]);sh(["certbot","certonly","--nginx","-d",d["domain"],"--non-interactive","--agree-tos","-m",d["email"]]);genn(d);sh(["systemctl","reload","nginx"])
   elif c=="3":
    x=input("HH:MM atau off: ");p=Path("/etc/cron.d/xray-mobile-reboot")
    if x=="off":p.unlink(missing_ok=True)
    else:
     h,m=x.split(":");p.write_text(f"{int(m)} {int(h)} * * * root /sbin/reboot\n")
   elif c=="4":sh(["systemctl","restart","xray","nginx"])
   elif c=="5":
    d["ipv6"]=not d["ipv6"];save(d);v="0" if d["ipv6"] else "1";Path("/etc/sysctl.d/99-xray-ipv6.conf").write_text(f"net.ipv6.conf.all.disable_ipv6={v}\nnet.ipv6.conf.default.disable_ipv6={v}\n");sh(["sysctl","--system"]);apply(d)
   elif c=="6":
    print("1 CF 2 Google 3 Quad9 4 Custom");z=input("> ");d["dns"]={"1":["1.1.1.1","1.0.0.1"],"2":["8.8.8.8","8.8.4.4"],"3":["9.9.9.9","149.112.112.112"]}.get(z,[x.strip() for x in input("comma: ").split(",")]);save(d);apply(d)
   elif c=="7":print("Installed",install_xray(input("latest atau version: ") or "latest"));sh(["systemctl","restart","xray"])
   elif c=="8":sh([str(XB),"run","-test","-config",str(XC)]);sh(["nginx","-t"]);print("VALID")
  except Exception as e:print("ERROR",e)
  pause();d=load()
def main():
 d=load()
 if "--purge-expired" in os.sys.argv:
  d["users"]=[u for u in d["users"] if active(u)];save(d)
  if XB.exists():apply(d)
  return
 while 1:
  dash(d);c=menu("Main",[("1","Install/update"),("2","Uninstall"),("3","VLESS"),("4","SOCKS5/HTTP"),("5","System"),("0","Back/Exit")])
  try:
   if c=="1":install(d)
   elif c=="2":
    if input("Taip UNINSTALL: ")=="UNINSTALL": sh(["systemctl","disable","--now","xray"],False);NL.unlink(missing_ok=True);NC.unlink(missing_ok=True)
   elif c=="3":vmenu(d)
   elif c=="4":pmenu(d)
   elif c=="5":sysmenu(d)
   elif c=="0":return
  except Exception as e:print("ERROR",e)
  pause();d=load()
main()
PY
chmod 700 "$APP/manager.py"
cat > /usr/local/sbin/xray-mobile <<EOF
#!/usr/bin/env bash
exec python3 "$APP/manager.py" "\$@"
EOF
chmod 755 /usr/local/sbin/xray-mobile
exec /usr/local/sbin/xray-mobile
