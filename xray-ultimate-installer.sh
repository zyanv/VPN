#!/usr/bin/env bash
set -Eeuo pipefail

APP=/opt/xray-admin
STATE=$APP/state.json
USERS=$APP/users.json
PROXIES=$APP/proxies.json
CONFIG=/usr/local/etc/xray/config.json
DOMAIN_FILE=$APP/domain
LOG=/var/log/xray-admin-install.log

c0='\033[0m'; c1='\033[1;36m'; c2='\033[1;32m'; c3='\033[1;33m'; c4='\033[1;31m'
msg(){ echo -e "${c1}▶${c0} $*"; }
ok(){ echo -e "${c2}✓${c0} $*"; }
warn(){ echo -e "${c3}!${c0} $*"; }
die(){ echo -e "${c4}✗ $*${c0}" >&2; exit 1; }
spin(){ local p=$1; shift; "$@" >>"$LOG" 2>&1 & local x=$! s='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏' i=0; while kill -0 "$x" 2>/dev/null; do printf "\r%s %s" "${s:i++%10:1}" "$p"; sleep .1; done; wait "$x"; local r=$?; printf '\r'; return $r; }
need_root(){ [[ $EUID -eq 0 ]] || die 'Jalankan sebagai root.'; }
need_os(){ . /etc/os-release; [[ ${ID:-} == ubuntu && ${VERSION_ID:-} == 24.04 ]] || die 'Hanya Ubuntu 24.04 disokong.'; }
randpass(){ tr -dc 'A-Za-z0-9@#%+=' </dev/urandom | head -c 18; }
public_ip(){ curl -4fsS --max-time 5 https://api.ipify.org || hostname -I | awk '{print $1}'; }

write_manager(){
cat >$APP/manager.py <<'PY'
#!/usr/bin/env python3
import argparse, datetime as dt, json, os, secrets, subprocess, sys, urllib.parse
APP='/opt/xray-admin'; STATE=f'{APP}/state.json'; USERS=f'{APP}/users.json'; PROXIES=f'{APP}/proxies.json'; CONFIG='/usr/local/etc/xray/config.json'; DOMAIN=f'{APP}/domain'

def load(p,d):
    try:
        with open(p) as f:return json.load(f)
    except:return d

def save(p,v):
    t=p+'.tmp'; open(t,'w').write(json.dumps(v,indent=2)); os.replace(t,p)

def state(): return load(STATE, {'proxy_enabled':False,'proxy_mode':'full','proxy_type':'socks','active_proxy':None,'bypass_domains':['geosite:netflix','domain:viu.com','domain:iq.com'],'dns':'cloudflare','ipv6':True,'rotate':False})
def users(): return load(USERS,[])
def proxies(): return load(PROXIES,[])
def domain():
    try:return open(DOMAIN).read().strip()
    except:return ''
def run(*a): return subprocess.run(a,text=True,capture_output=True)
def active_users():
    now=dt.date.today(); return [u for u in users() if dt.date.fromisoformat(u['expiry'])>=now]
def outbound(st):
    ps=proxies(); p=next((x for x in ps if x['id']==st.get('active_proxy')),None)
    if not st.get('proxy_enabled') or not p:return {'protocol':'freedom','tag':'direct','settings':{'domainStrategy':'UseIP'}}
    settings={'address':p['host'],'port':int(p['port'])}
    if p.get('user'):settings.update(user=p['user'],pass_=p.get('pass',''))
    if 'pass_' in settings:settings['pass']=settings.pop('pass_')
    return {'protocol':'http' if p['type']=='http' else 'socks','tag':'proxy','settings':settings}
def rebuild(restart=True):
    us=active_users(); clients=[{'id':u['uuid'],'email':u['name']} for u in us]
    st=state(); ob=outbound(st); out=[ob]
    if ob['tag']!='direct':out.append({'protocol':'freedom','tag':'direct','settings':{'domainStrategy':'UseIP'}})
    out.append({'protocol':'blackhole','tag':'block','settings':{}})
    rules=[]
    if ob['tag']=='proxy':
        if st.get('proxy_mode')=='bypass': rules.append({'type':'field','domain':st.get('bypass_domains',[]),'outboundTag':'proxy'})
        else: rules.append({'type':'field','network':'tcp,udp','outboundTag':'proxy'})
    cfg={'log':{'loglevel':'warning','access':'/var/log/xray/access.log','error':'/var/log/xray/error.log'},
      'dns':{'servers': {'google':['8.8.8.8','8.8.4.4'],'cloudflare':['1.1.1.1','1.0.0.1'],'quad9':['9.9.9.9','149.112.112.112']}.get(st.get('dns'),['1.1.1.1'])},
      'inbounds':[
       {'tag':'vless-ws','listen':'127.0.0.1','port':10001,'protocol':'vless','settings':{'clients':clients,'decryption':'none'},'streamSettings':{'method':'websocket','security':'none','wsSettings':{'path':'/vless-ws','acceptProxyProtocol':False}}},
       {'tag':'vless-up','listen':'127.0.0.1','port':10002,'protocol':'vless','settings':{'clients':clients,'decryption':'none'},'streamSettings':{'method':'httpupgrade','security':'none','httpupgradeSettings':{'path':'/vless-up','acceptProxyProtocol':False}}},
       {'tag':'vless-xhttp','listen':'127.0.0.1','port':10003,'protocol':'vless','settings':{'clients':clients,'decryption':'none'},'streamSettings':{'method':'xhttp','security':'none','xhttpSettings':{'path':'/vless-xhttp','mode':'packet-up'}}}
      ],'outbounds':out,'routing':{'domainStrategy':'IPIfNonMatch','rules':rules}}
    os.makedirs(os.path.dirname(CONFIG),exist_ok=True); save(CONFIG,cfg)
    r=run('/usr/local/bin/xray','run','-test','-config',CONFIG)
    if r.returncode: print(r.stderr); raise SystemExit('Konfigurasi Xray tidak sah')
    if restart: run('systemctl','restart','xray')
def add_user(name,days):
    a=users(); u={'name':name,'uuid':run('/usr/local/bin/xray','uuid').stdout.strip() or secrets.token_hex(16),'expiry':str(dt.date.today()+dt.timedelta(days=int(days)))}; a.append(u); save(USERS,a); rebuild(); print(json.dumps(u))
def renew(name,days):
    a=users(); found=False
    for u in a:
      if u['name']==name: u['expiry']=str(max(dt.date.today(),dt.date.fromisoformat(u['expiry']))+dt.timedelta(days=int(days))); found=True
    if not found: raise SystemExit('User tidak ditemui')
    save(USERS,a); rebuild()
def delete(name): save(USERS,[u for u in users() if u['name']!=name]); rebuild()
def purge():
    today=dt.date.today(); save(USERS,[u for u in users() if dt.date.fromisoformat(u['expiry'])>=today]); rebuild()
def links(name):
    d=domain(); u=next((x for x in users() if x['name']==name),None)
    if not u: raise SystemExit('User tidak ditemui')
    q=lambda x:urllib.parse.quote(x,safe='')
    print(f"vless://{u['uuid']}@{d}:443?encryption=none&security=tls&type=ws&host={d}&path={q('/vless-ws')}#{q(name+'-WS-TLS')}")
    print(f"vless://{u['uuid']}@{d}:443?encryption=none&security=tls&type=httpupgrade&host={d}&path={q('/vless-up')}#{q(name+'-HTTPUpgrade-TLS')}")
    print(f"vless://{u['uuid']}@{d}:443?encryption=none&security=tls&type=xhttp&host={d}&path={q('/vless-xhttp')}&mode=packet-up#{q(name+'-XHTTP-TLS')}")
    for port in (80,8080,8880): print(f"vless://{u['uuid']}@{d}:{port}?encryption=none&security=none&type=ws&host={d}&path={q('/vless-ws')}#{q(name+'-WS-'+str(port))}")
def proxy_add(kind,host,port,user='',password=''):
    a=proxies(); p={'id':secrets.token_hex(4),'type':kind,'host':host,'port':int(port),'user':user,'pass':password}; a.append(p); save(PROXIES,a); print(json.dumps(p))
def proxy_del(pid):
    save(PROXIES,[p for p in proxies() if p['id']!=pid]); st=state();
    if st.get('active_proxy')==pid: st['active_proxy']=None; st['proxy_enabled']=False; save(STATE,st)
    rebuild()
def rotate():
    ps=proxies()
    if not ps:return
    st=state(); ids=[p['id'] for p in ps]
    try:i=(ids.index(st.get('active_proxy'))+1)%len(ids)
    except:i=0
    st['active_proxy']=ids[i]; st['proxy_enabled']=True; save(STATE,st); rebuild()
def set_state(k,v):
    st=state(); st[k]=v; save(STATE,st); rebuild()
def status():
    def svc(n): return run('systemctl','is-active',n).stdout.strip()
    print(json.dumps({'xray':svc('xray'),'nginx':svc('nginx'),'panel':svc('xray-panel'),'domain':domain(),'users':len(active_users()),'state':state()},indent=2))

def main():
 p=argparse.ArgumentParser(); s=p.add_subparsers(dest='cmd',required=True)
 q=s.add_parser('add');q.add_argument('name');q.add_argument('days',type=int)
 q=s.add_parser('trial');q.add_argument('name');q.add_argument('--hours',type=int,default=1)
 q=s.add_parser('renew');q.add_argument('name');q.add_argument('days',type=int)
 q=s.add_parser('delete');q.add_argument('name');q=s.add_parser('links');q.add_argument('name')
 s.add_parser('list');s.add_parser('purge');s.add_parser('rebuild');s.add_parser('status');s.add_parser('rotate')
 q=s.add_parser('proxy-add');q.add_argument('type',choices=['socks','socks5h','http']);q.add_argument('host');q.add_argument('port',type=int);q.add_argument('--user',default='');q.add_argument('--password',default='')
 q=s.add_parser('proxy-del');q.add_argument('id');s.add_parser('proxy-list')
 q=s.add_parser('set');q.add_argument('key',choices=['proxy_enabled','proxy_mode','active_proxy','dns','ipv6','rotate']);q.add_argument('value')
 a=p.parse_args()
 if a.cmd=='add':add_user(a.name,a.days)
 elif a.cmd=='trial':add_user(a.name,max(1,a.hours/24))
 elif a.cmd=='renew':renew(a.name,a.days)
 elif a.cmd=='delete':delete(a.name)
 elif a.cmd=='links':links(a.name)
 elif a.cmd=='list':print(json.dumps(users(),indent=2))
 elif a.cmd=='purge':purge()
 elif a.cmd=='rebuild':rebuild()
 elif a.cmd=='status':status()
 elif a.cmd=='rotate':rotate()
 elif a.cmd=='proxy-add':proxy_add(a.type,a.host,a.port,a.user,a.password)
 elif a.cmd=='proxy-del':proxy_del(a.id)
 elif a.cmd=='proxy-list':print(json.dumps(proxies(),indent=2))
 elif a.cmd=='set':
    v=a.value
    if v.lower() in ('true','false'):v=v.lower()=='true'
    set_state(a.key,v)
if __name__=='__main__':main()
PY
chmod 700 $APP/manager.py
}

write_panel(){
cat >$APP/app.py <<'PY'
from flask import Flask,request,redirect,session,render_template_string,flash
from werkzeug.security import check_password_hash
import json,os,subprocess
app=Flask(__name__); app.secret_key=os.environ.get('PANEL_SECRET','change-me')
APP='/opt/xray-admin'
def ld(n,d):
 try:return json.load(open(f'{APP}/{n}.json'))
 except:return d
def cmd(*a): return subprocess.run([f'{APP}/manager.py',*map(str,a)],text=True,capture_output=True)
def auth(): return session.get('ok')
TPL='''<!doctype html><meta name=viewport content="width=device-width,initial-scale=1"><title>Xray Admin</title><style>
body{margin:0;background:#07111f;color:#e5eefb;font:15px system-ui}.wrap{max-width:1100px;margin:auto;padding:18px}.top{display:flex;justify-content:space-between;align-items:center}.grid{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:14px}.card{background:#101d30;border:1px solid #24354f;border-radius:18px;padding:16px;box-shadow:0 12px 35px #0005}h1,h2{margin:.2em 0}.muted{color:#91a4bf}input,select,button{width:100%;box-sizing:border-box;padding:11px;margin:5px 0;border-radius:11px;border:1px solid #334760;background:#091526;color:white}button,.btn{background:#17a2b8;border:0;font-weight:700;cursor:pointer}.danger{background:#b83246}.row{display:grid;grid-template-columns:1fr 1fr;gap:8px}table{width:100%;border-collapse:collapse}td,th{padding:8px;border-bottom:1px solid #263750;text-align:left}.pill{display:inline-block;padding:4px 8px;border-radius:20px;background:#18344a}@media(max-width:700px){.grid,.row{grid-template-columns:1fr}.wrap{padding:10px}}</style><div class=wrap>{% if login %}<div class=card style="max-width:390px;margin:10vh auto"><h1>Xray Admin</h1><form method=post><input name=user placeholder=Admin required><input type=password name=password placeholder=Password required><button>Login</button></form></div>{% else %}<div class=top><div><h1>Xray Admin</h1><div class=muted>{{domain}}</div></div><a href=/logout style=color:white>Logout</a></div>{% with m=get_flashed_messages() %}{% for x in m %}<p class=pill>{{x}}</p>{% endfor %}{% endwith %}<div class=grid>
<div class=card><h2>Dashboard</h2><p>Xray: <b>{{status.xray}}</b> · Nginx: <b>{{status.nginx}}</b> · Panel: <b>{{status.panel}}</b></p><p>User aktif: <b>{{users|length}}</b></p><form method=post action=/service class=row><button name=service value=xray>Restart Xray</button><button name=service value=nginx>Restart Nginx</button></form></div>
<div class=card><h2>Tambah user</h2><form method=post action=/user/add><input name=name placeholder="Nama user" required><input name=days type=number value=30 min=1 required><button>Tambah</button></form></div>
<div class=card><h2>User VLESS</h2><table><tr><th>Nama</th><th>Tamat</th><th>Tindakan</th></tr>{% for u in users %}<tr><td>{{u.name}}</td><td>{{u.expiry}}</td><td><a href="/user/config/{{u.name}}" style=color:#54d7e8>Config</a> · <a href="/user/delete/{{u.name}}" style=color:#ff8090>Delete</a></td></tr>{% endfor %}</table></div>
<div class=card><h2>Proxy outbound</h2><form method=post action=/proxy/add><div class=row><select name=type><option>socks</option><option>socks5h</option><option>http</option></select><input name=host placeholder=Host required></div><div class=row><input name=port type=number placeholder=Port required><input name=user placeholder=Username></div><input name=password placeholder=Password><button>Tambah proxy</button></form><table>{% for p in proxies %}<tr><td>{{p.type}}://{{p.host}}:{{p.port}}</td><td><a href="/proxy/use/{{p.id}}" style=color:#54d7e8>Use</a> · <a href="/proxy/delete/{{p.id}}" style=color:#ff8090>Delete</a></td></tr>{% endfor %}</table><form method=post action=/proxy/mode><select name=mode><option value=full>Full traffic</option><option value=bypass>Domain terpilih sahaja</option></select><button>Tetapkan mode</button></form><a href=/proxy/off style=color:#ffcf66>Matikan proxy</a></div>
<div class=card><h2>Sistem</h2><form method=post action=/dns><select name=dns><option>cloudflare</option><option>google</option><option>quad9</option></select><button>Tukar DNS Xray</button></form><form method=post action=/ssl><button>Issue/Renew SSL ACME</button></form><form method=post action=/core><button>Kemas kini Xray Core stabil</button></form></div>
<div class=card><h2>Nota</h2><p class=muted>Panel hanya didengar pada 127.0.0.1 dan diterbitkan melalui HTTPS di <b>/xray-admin/</b>. Gunakan kata laluan kuat dan jangan kongsi URL konfigurasi.</p></div>
</div>{% endif %}</div>'''
def st():
 r=cmd('status');
 try:return json.loads(r.stdout)
 except:return {'xray':'?','nginx':'?','panel':'?'}
@app.route('/login',methods=['GET','POST'])
def login():
 if request.method=='POST':
  a=ld('admin',{}); ok=request.form['user']==a.get('user') and check_password_hash(a.get('password_hash',''),request.form['password'])
  if ok:session['ok']=True;return redirect('/')
 return render_template_string(TPL,login=True)
@app.before_request
def guard():
 if request.endpoint not in ('login','static') and not auth():return redirect('/login')
@app.route('/')
def home(): return render_template_string(TPL,login=False,domain=open(f'{APP}/domain').read().strip(),status=st(),users=ld('users',[]),proxies=ld('proxies',[]))
@app.route('/logout')
def logout():session.clear();return redirect('/login')
@app.post('/user/add')
def ua():cmd('add',request.form['name'],request.form['days']);return redirect('/')
@app.route('/user/delete/<name>')
def ud(name):cmd('delete',name);return redirect('/')
@app.route('/user/config/<name>')
def uc(name):return '<pre style="white-space:pre-wrap">'+cmd('links',name).stdout+'</pre>'
@app.post('/proxy/add')
def pa():cmd('proxy-add',request.form['type'],request.form['host'],request.form['port'],'--user',request.form.get('user',''),'--password',request.form.get('password',''));return redirect('/')
@app.route('/proxy/use/<pid>')
def pu(pid):cmd('set','active_proxy',pid);cmd('set','proxy_enabled','true');return redirect('/')
@app.route('/proxy/delete/<pid>')
def pd(pid):cmd('proxy-del',pid);return redirect('/')
@app.route('/proxy/off')
def po():cmd('set','proxy_enabled','false');return redirect('/')
@app.post('/proxy/mode')
def pm():cmd('set','proxy_mode',request.form['mode']);return redirect('/')
@app.post('/dns')
def dns():cmd('set','dns',request.form['dns']);return redirect('/')
@app.post('/service')
def service():subprocess.run(['systemctl','restart',request.form['service']]);return redirect('/')
@app.post('/ssl')
def ssl():subprocess.run(['/usr/local/sbin/xray-acme']);return redirect('/')
@app.post('/core')
def core():subprocess.run(['bash','-c','curl -Ls https://github.com/XTLS/Xray-install/raw/main/install-release.sh | bash -s -- install']);subprocess.run(['systemctl','restart','xray']);return redirect('/')
PY
}

write_nginx(){
local d=$1
cat >/etc/nginx/conf.d/xray-admin.conf <<NG
map \$http_upgrade \$connection_upgrade { default upgrade; '' close; }
server {
 listen 80 default_server; listen 8080; listen 8880;
 server_name $d;
 location ^~ /.well-known/acme-challenge/ { root /var/www/acme; }
 location /vless-ws { proxy_pass http://127.0.0.1:10001; proxy_http_version 1.1; proxy_set_header Upgrade \$http_upgrade; proxy_set_header Connection \$connection_upgrade; proxy_set_header Host \$host; proxy_read_timeout 86400; }
 location /vless-up { proxy_pass http://127.0.0.1:10002; proxy_http_version 1.1; proxy_set_header Upgrade \$http_upgrade; proxy_set_header Connection upgrade; proxy_set_header Host \$host; proxy_read_timeout 86400; }
 location /vless-xhttp { proxy_pass http://127.0.0.1:10003; proxy_http_version 1.1; proxy_set_header Host \$host; proxy_request_buffering off; proxy_buffering off; proxy_read_timeout 86400; }
 location / { return 200 'OK'; add_header Content-Type text/plain; }
}
server {
 listen 443 ssl http2; server_name $d;
 ssl_certificate /etc/letsencrypt/live/$d/fullchain.pem; ssl_certificate_key /etc/letsencrypt/live/$d/privkey.pem;
 ssl_protocols TLSv1.2 TLSv1.3; ssl_session_cache shared:SSL:10m;
 location /vless-ws { proxy_pass http://127.0.0.1:10001; proxy_http_version 1.1; proxy_set_header Upgrade \$http_upgrade; proxy_set_header Connection \$connection_upgrade; proxy_set_header Host \$host; proxy_read_timeout 86400; }
 location /vless-up { proxy_pass http://127.0.0.1:10002; proxy_http_version 1.1; proxy_set_header Upgrade \$http_upgrade; proxy_set_header Connection upgrade; proxy_set_header Host \$host; proxy_read_timeout 86400; }
 location /vless-xhttp { proxy_pass http://127.0.0.1:10003; proxy_http_version 1.1; proxy_set_header Host \$host; proxy_request_buffering off; proxy_buffering off; proxy_read_timeout 86400; }
 location /xray-admin/ { proxy_pass http://127.0.0.1:8787/; proxy_set_header Host \$host; proxy_set_header X-Forwarded-Proto https; proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for; }
 location / { return 200 'Secure endpoint'; add_header Content-Type text/plain; }
}
NG
rm -f /etc/nginx/sites-enabled/default
}

install_all(){
need_root; need_os; touch "$LOG"
read -rp 'Domain (rekod A mesti menuju ke VPS): ' domain
[[ $domain =~ ^[A-Za-z0-9.-]+$ ]] || die 'Domain tidak sah.'
read -rp 'Email ACME: ' email
read -rp 'Admin panel username [admin]: ' admin; admin=${admin:-admin}
read -rsp 'Admin panel password (kosong=jana automatik): ' pass; echo; pass=${pass:-$(randpass)}
mkdir -p "$APP" /var/www/acme /var/log/xray; echo "$domain" > "$DOMAIN_FILE"
spin 'Memasang pakej' apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y curl jq nginx certbot python3-venv python3-pip openssl ca-certificates uuid-runtime cron >>"$LOG" 2>&1
spin 'Memasang Xray Core stabil rasmi' bash -c 'curl -Ls https://github.com/XTLS/Xray-install/raw/main/install-release.sh | bash -s -- install'
write_manager; write_panel
cat >$STATE <<JSON
{"proxy_enabled":false,"proxy_mode":"full","proxy_type":"socks","active_proxy":null,"bypass_domains":["geosite:netflix","domain:viu.com","domain:iq.com","domain:youtube.com","domain:googlevideo.com"],"dns":"cloudflare","ipv6":true,"rotate":false}
JSON
echo '[]' >$USERS; echo '[]' >$PROXIES
python3 -m venv $APP/venv
$APP/venv/bin/pip install --quiet flask gunicorn werkzeug
$APP/venv/bin/python - <<PY
import json
from werkzeug.security import generate_password_hash
json.dump({'user':'$admin','password_hash':generate_password_hash('$pass')},open('$APP/admin.json','w'))
PY
cat >/etc/systemd/system/xray-panel.service <<UNIT
[Unit]
After=network.target xray.service
[Service]
User=root
WorkingDirectory=$APP
Environment=PANEL_SECRET=$(openssl rand -hex 32)
ExecStart=$APP/venv/bin/gunicorn -b 127.0.0.1:8787 app:app
Restart=always
[Install]
WantedBy=multi-user.target
UNIT
$APP/manager.py rebuild
cat >/usr/local/sbin/xray-acme <<ACME
#!/usr/bin/env bash
set -e
systemctl stop nginx || true
certbot certonly --standalone -d '$domain' -m '$email' --agree-tos --non-interactive --preferred-challenges http
systemctl start nginx
ACME
chmod 700 /usr/local/sbin/xray-acme
systemctl stop nginx || true
certbot certonly --standalone -d "$domain" -m "$email" --agree-tos --non-interactive --preferred-challenges http || die 'ACME gagal. Pastikan DNS domain menuju ke VPS dan port 80 terbuka.'
write_nginx "$domain"
nginx -t || die 'Konfigurasi Nginx gagal.'
systemctl daemon-reload; systemctl enable --now xray xray-panel nginx
cat >/etc/cron.d/xray-admin <<'CRON'
15 2 * * * root /opt/xray-admin/manager.py purge >/dev/null 2>&1
35 3 * * * root certbot renew --quiet --deploy-hook 'systemctl reload nginx'
*/10 * * * * root test "$(jq -r .rotate /opt/xray-admin/state.json 2>/dev/null)" = true && /opt/xray-admin/manager.py rotate >/dev/null 2>&1
CRON
cat >/usr/local/sbin/xray-menu <<'MENU'
#!/usr/bin/env bash
A=/opt/xray-admin/manager.py
while true; do clear; echo '╔══════════════ XRAY ADMIN ══════════════╗'; $A status | jq -r '"║ Xray: \(.xray)  Nginx: \(.nginx)  Panel: \(.panel)\n║ Domain: \(.domain)\n║ User aktif: \(.users)  DNS: \(.state.dns)\n║ Proxy: \(.state.proxy_enabled) / \(.state.proxy_mode)"'; echo '╠═════════════════════════════════════════╣'; echo '║ 1 Install/Update Core │ 2 VLESS Users  ║'; echo '║ 3 SOCKS/HTTP Proxy   │ 4 System       ║'; echo '║ 0 Back/Exit                           ║'; echo '╚═════════════════════════════════════════╝'; read -rp 'Pilih: ' x
case $x in
1) curl -Ls https://github.com/XTLS/Xray-install/raw/main/install-release.sh | bash -s -- install; systemctl restart xray; read -rp Enter;;
2) echo '1 Add  2 Trial  3 Renew  4 Delete  5 List  6 Config  7 Purge expired'; read -rp '> ' y; case $y in 1) read -rp Nama: n;read -rp Hari: d;$A add "$n" "$d";;2) read -rp Nama: n;$A add "$n" 1;;3) read -rp Nama: n;read -rp Hari: d;$A renew "$n" "$d";;4) read -rp Nama: n;$A delete "$n";;5)$A list;;6)read -rp Nama: n;$A links "$n";;7)$A purge;;esac;read -rp Enter;;
3) echo '1 Add 2 List 3 Use 4 Delete 5 Enable 6 Disable 7 Full 8 Domain-only 9 Rotate ON 10 Rotate OFF';read -rp '> ' y;case $y in 1)read -rp 'Type socks/socks5h/http: ' t;read -rp Host: h;read -rp Port: p;read -rp User: u;read -rsp Pass: w;echo;$A proxy-add "$t" "$h" "$p" --user "$u" --password "$w";;2)$A proxy-list;;3)read -rp ID: i;$A set active_proxy "$i";$A set proxy_enabled true;;4)read -rp ID: i;$A proxy-del "$i";;5)$A set proxy_enabled true;;6)$A set proxy_enabled false;;7)$A set proxy_mode full;;8)$A set proxy_mode bypass;;9)$A set rotate true;;10)$A set rotate false;;esac;read -rp Enter;;
4) echo '1 Restart all 2 DNS Cloudflare 3 DNS Google 4 DNS Quad9 5 Renew SSL 6 IPv6 enable 7 IPv6 disable';read -rp '> ' y;case $y in 1)systemctl restart xray nginx xray-panel;;2)$A set dns cloudflare;;3)$A set dns google;;4)$A set dns quad9;;5)/usr/local/sbin/xray-acme;;6)sysctl -w net.ipv6.conf.all.disable_ipv6=0;;7)sysctl -w net.ipv6.conf.all.disable_ipv6=1;;esac;read -rp Enter;;
0)exit;;esac; done
MENU
chmod 700 /usr/local/sbin/xray-menu
ok 'Pemasangan selesai.'
echo "Panel: https://$domain/xray-admin/"
echo "Admin: $admin"
echo "Password: $pass"
echo 'CLI: xray-menu'
}

uninstall_all(){
need_root
systemctl disable --now xray-panel nginx xray 2>/dev/null || true
rm -rf "$APP" /etc/systemd/system/xray-panel.service /etc/nginx/conf.d/xray-admin.conf /usr/local/sbin/xray-menu /usr/local/sbin/xray-acme /etc/cron.d/xray-admin
curl -Ls https://github.com/XTLS/Xray-install/raw/main/install-release.sh | bash -s -- remove --purge || true
apt-get remove -y nginx certbot || true
systemctl daemon-reload
ok 'Xray Admin dibuang. Sijil Let’s Encrypt dikekalkan di /etc/letsencrypt.'
}

case ${1:-install} in install) install_all;; uninstall) uninstall_all;; *) echo "Usage: $0 [install|uninstall]"; exit 2;; esac
