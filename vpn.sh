#!/usr/bin/env bash
# ZYANV VPN Manager - single-file installer/manager
# Supports Ubuntu 24.04 and Debian 12/13
# Repository target: https://github.com/zyanv/VPN
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

APP="zyanv-vpn"
BASE="/etc/${APP}"
STATE="${BASE}/state"
XRAY_CONFIG="/usr/local/etc/xray/config.json"
NGINX_SITE="/etc/nginx/sites-available/${APP}.conf"
NGINX_LINK="/etc/nginx/sites-enabled/${APP}.conf"
BIN="/usr/local/sbin/vpn"
LOG="/var/log/${APP}.log"
ACME_HOME="/root/.acme.sh"

C_RESET='\033[0m'; C_BOLD='\033[1m'; C_DIM='\033[2m'
C_RED='\033[31m'; C_GREEN='\033[32m'; C_YELLOW='\033[33m'
C_BLUE='\033[34m'; C_CYAN='\033[36m'; C_MAGENTA='\033[35m'

trap 'printf "\n%bRalat pada baris %s. Semak %s%b\n" "$C_RED" "$LINENO" "$LOG" "$C_RESET" >&2' ERR

log(){ printf '[%s] %s\n' "$(date '+%F %T')" "$*" >> "$LOG"; }
die(){ printf '%bRalat:%b %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }
need_root(){ [[ ${EUID:-$(id -u)} -eq 0 ]] || die "Jalankan sebagai root."; }
pause(){ read -r -p "Tekan Enter untuk kembali..." _ || true; }
spinner(){
  local pid=$1 msg=${2:-"Memproses"} spin='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏' i=0
  printf '%b%s%b ' "$C_CYAN" "$msg" "$C_RESET"
  while kill -0 "$pid" 2>/dev/null; do
    printf '\b%s' "${spin:i++%${#spin}:1}"; sleep .09
  done
  wait "$pid"; local rc=$?
  if ((rc==0)); then printf '\b%b✓%b\n' "$C_GREEN" "$C_RESET"; else printf '\b%b✗%b\n' "$C_RED" "$C_RESET"; fi
  return "$rc"
}
run_spin(){ local msg=$1; shift; ("$@" >>"$LOG" 2>&1) & spinner $! "$msg"; }
header(){
  clear
  printf '%b%b╭────────────────────────────────────────────────────────────╮%b\n' "$C_BOLD" "$C_BLUE" "$C_RESET"
  printf '%b%b│                 ZYANV VPN MANAGER                         │%b\n' "$C_BOLD" "$C_BLUE" "$C_RESET"
  printf '%b%b╰────────────────────────────────────────────────────────────╯%b\n' "$C_BOLD" "$C_BLUE" "$C_RESET"
}
status_word(){ systemctl is-active --quiet "$1" 2>/dev/null && printf '%bON%b' "$C_GREEN" "$C_RESET" || printf '%bOFF%b' "$C_RED" "$C_RESET"; }
get_public_ip(){ curl -4fsS --max-time 4 https://api.ipify.org 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}' || printf '-'; }
domain(){ [[ -f "$STATE/domain" ]] && cat "$STATE/domain" || printf '-'; }
dns_now(){ awk '/^nameserver/{print $2}' /etc/resolv.conf 2>/dev/null | paste -sd, - || printf '-'; }
selected_proxy(){
  [[ -f "$STATE/proxy-selected" ]] || { printf 'direct'; return; }
  local id; id=$(cat "$STATE/proxy-selected")
  awk -F'\t' -v id="$id" '$1==id{print $2"://"$3":"$4; found=1} END{if(!found)print "direct"}' "$STATE/proxies.tsv" 2>/dev/null
}
count_users(){ awk -F'\t' 'NF>=5 && $5 >= strftime("%Y-%m-%d"){n++} END{print n+0}' "$STATE/users.tsv" 2>/dev/null || printf 0; }
active_connections(){ ss -Hnt state established 2>/dev/null | awk '$4 ~ /:1008[1-3]$/{n++} END{print n+0}'; }

dashboard(){
  local ip dom users mode
  ip=$(get_public_ip); dom=$(domain); users=$(count_users); mode=$(cat "$STATE/proxy-mode" 2>/dev/null || echo direct)
  printf '\n%b┌──────────────────────┬───────────────────────────────────┐%b\n' "$C_DIM" "$C_RESET"
  printf '│ Xray      %-11b │ Nginx      %-20b │\n' "$(status_word xray)" "$(status_word nginx)"
  printf '│ SOCKS5    %-11b │ Sambungan  %-20s │\n' "$(status_word xray)" "$(active_connections)"
  printf '│ IP VPS    %-11s │ Domain     %-20s │\n' "${ip:0:11}" "${dom:0:20}"
  printf '│ User      %-11s │ DNS        %-20s │\n' "$users" "$(dns_now | cut -c1-20)"
  printf '│ Proxy     %-11s │ Mod        %-20s │\n' "$(selected_proxy | cut -c1-11)" "$mode"
  printf '%b└──────────────────────┴───────────────────────────────────┘%b\n\n' "$C_DIM" "$C_RESET"
}

check_os(){
  . /etc/os-release
  case "${ID}:${VERSION_ID}" in
    ubuntu:24.04|debian:12|debian:13) ;;
    *) die "OS disokong: Ubuntu 24.04, Debian 12 atau Debian 13. Dikesan: ${PRETTY_NAME:-unknown}" ;;
  esac
}
init_state(){
  mkdir -p "$STATE" /usr/local/etc/xray /var/www/acme
  touch "$STATE/users.tsv" "$STATE/proxies.tsv" "$STATE/region-domains.txt"
  [[ -f "$STATE/proxy-mode" ]] || echo direct > "$STATE/proxy-mode"
  [[ -f "$STATE/socks-enabled" ]] || echo 0 > "$STATE/socks-enabled"
  [[ -f "$STATE/socks-bind" ]] || echo 127.0.0.1 > "$STATE/socks-bind"
  [[ -f "$STATE/socks-port" ]] || echo 1080 > "$STATE/socks-port"
  [[ -f "$STATE/socks-user" ]] || echo "socks_$(openssl rand -hex 3)" > "$STATE/socks-user"
  [[ -f "$STATE/socks-pass" ]] || openssl rand -base64 18 | tr -d '/+=' | head -c 20 > "$STATE/socks-pass"
  [[ -f "$STATE/xray-channel" ]] || echo stable > "$STATE/xray-channel"
}
install_packages(){
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y curl wget unzip jq nginx socat cron openssl ca-certificates dnsutils iproute2 uuid-runtime python3
}
install_xray(){
  local version=${1:-}
  local api="https://api.github.com/repos/XTLS/Xray-core/releases/latest"
  [[ -n "$version" ]] || version=$(curl -fsSL "$api" | jq -r .tag_name)
  [[ "$version" =~ ^v[0-9] ]] || die "Versi Xray tidak sah: $version"
  local arch asset tmp
  case "$(uname -m)" in
    x86_64|amd64) asset="Xray-linux-64.zip" ;;
    aarch64|arm64) asset="Xray-linux-arm64-v8a.zip" ;;
    *) die "Seni bina belum disokong: $(uname -m)" ;;
  esac
  tmp=$(mktemp -d)
  curl -fL "https://github.com/XTLS/Xray-core/releases/download/${version}/${asset}" -o "$tmp/xray.zip"
  unzip -oq "$tmp/xray.zip" -d "$tmp/xray"
  install -m 0755 "$tmp/xray/xray" /usr/local/bin/xray
  install -m 0644 "$tmp/xray/geoip.dat" /usr/local/share/xray/geoip.dat
  install -m 0644 "$tmp/xray/geosite.dat" /usr/local/share/xray/geosite.dat
  rm -rf "$tmp"
  cat >/etc/systemd/system/xray.service <<'UNIT'
[Unit]
Description=Xray Service
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
Type=simple
User=nobody
Group=nogroup
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=/usr/local/bin/xray run -config /usr/local/etc/xray/config.json
Restart=on-failure
RestartSec=3s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
}
install_acme(){
  [[ -x "$ACME_HOME/acme.sh" ]] || curl -fsSL https://get.acme.sh | sh -s email="${1:-admin@example.invalid}"
}
valid_domain(){
  [[ "$1" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]
}
set_domain(){
  local d=${1:-}
  [[ -n "$d" ]] || read -r -p "Domain (DNS Cloudflare mesti sudah menunjuk ke IP VPS): " d
  valid_domain "$d" || die "Format domain tidak sah."
  echo "${d,,}" > "$STATE/domain"
  render_all
  printf '%bDomain disimpan:%b %s\n' "$C_GREEN" "$C_RESET" "$d"
}
issue_ssl(){
  local d email
  d=$(domain); [[ "$d" != "-" ]] || die "Tetapkan domain dahulu."
  read -r -p "Email ACME: " email
  [[ "$email" == *"@"* ]] || die "Email tidak sah."
  install_acme "$email"
  mkdir -p "$BASE/ssl"
  render_nginx_acme
  nginx -t && systemctl reload nginx
  "$ACME_HOME/acme.sh" --set-default-ca --server letsencrypt
  "$ACME_HOME/acme.sh" --issue -d "$d" --webroot /var/www/acme --keylength ec-256
  "$ACME_HOME/acme.sh" --install-cert -d "$d" --ecc \
    --key-file "$BASE/ssl/key.pem" \
    --fullchain-file "$BASE/ssl/fullchain.pem" \
    --reloadcmd "systemctl reload nginx"
  chmod 600 "$BASE/ssl/key.pem"
  render_all
  systemctl restart nginx xray
}
render_nginx_acme(){
  local d; d=$(domain)
  cat >"$NGINX_SITE" <<EOF
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name ${d};
    location ^~ /.well-known/acme-challenge/ { root /var/www/acme; }
    location / { return 200 "ZYANV VPN ACME ready\n"; }
}
EOF
  ln -sf "$NGINX_SITE" "$NGINX_LINK"
  rm -f /etc/nginx/sites-enabled/default
}
render_nginx(){
  local d tls=0
  d=$(domain); [[ "$d" != "-" ]] || d="_"
  [[ -s "$BASE/ssl/fullchain.pem" && -s "$BASE/ssl/key.pem" ]] && tls=1
  cat >"$NGINX_SITE" <<EOF
map \$http_upgrade \$connection_upgrade {
    default upgrade;
    '' close;
}
upstream xray_ws { server 127.0.0.1:10081; keepalive 64; }
upstream xray_hu { server 127.0.0.1:10082; keepalive 64; }
upstream xray_xhttp { server 127.0.0.1:10083; keepalive 64; }

server {
    listen 80;
    listen 8080;
    listen 8880;
    listen [::]:80;
    listen [::]:8080;
    listen [::]:8880;
    server_name ${d};
    location ^~ /.well-known/acme-challenge/ { root /var/www/acme; }
    location = /health { access_log off; return 200 "ok\n"; }

    location /vless-ws {
        proxy_pass http://xray_ws;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_read_timeout 1d;
        proxy_send_timeout 1d;
        proxy_buffering off;
    }
    location /vless-httpupgrade {
        proxy_pass http://xray_hu;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_read_timeout 1d;
        proxy_send_timeout 1d;
        proxy_buffering off;
    }
    location /vless-xhttp {
        proxy_pass http://xray_xhttp;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_request_buffering off;
        proxy_buffering off;
        proxy_read_timeout 1d;
        proxy_send_timeout 1d;
        client_max_body_size 0;
    }
}
EOF
  if ((tls)); then
    cat >>"$NGINX_SITE" <<EOF

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;
    server_name ${d};
    ssl_certificate $BASE/ssl/fullchain.pem;
    ssl_certificate_key $BASE/ssl/key.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_cache shared:SSL:20m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;

    location = /health { access_log off; return 200 "ok\n"; }
    location /vless-ws {
        proxy_pass http://xray_ws;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_read_timeout 1d;
        proxy_send_timeout 1d;
        proxy_buffering off;
    }
    location /vless-httpupgrade {
        proxy_pass http://xray_hu;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_read_timeout 1d;
        proxy_send_timeout 1d;
        proxy_buffering off;
    }
    location /vless-xhttp {
        proxy_pass http://xray_xhttp;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_request_buffering off;
        proxy_buffering off;
        proxy_read_timeout 1d;
        proxy_send_timeout 1d;
        client_max_body_size 0;
    }
}
EOF
  fi
  ln -sf "$NGINX_SITE" "$NGINX_LINK"
  rm -f /etc/nginx/sites-enabled/default
}

render_xray(){
python3 - "$STATE" "$XRAY_CONFIG" <<'PY'
import csv, datetime, json, os, sys
state, output = sys.argv[1], sys.argv[2]
today = datetime.date.today().isoformat()

def read(name, default=""):
    try:
        return open(os.path.join(state,name), encoding="utf-8").read().strip()
    except FileNotFoundError:
        return default

clients={"ws":[],"httpupgrade":[],"xhttp":[]}
try:
    with open(os.path.join(state,"users.tsv"), encoding="utf-8") as f:
        for row in csv.reader(f, delimiter="\t"):
            if len(row)>=5 and row[0] in clients and row[4]>=today:
                clients[row[0]].append({"id":row[2],"email":f"{row[1]}@{row[0]}","level":0})
except FileNotFoundError: pass

inbounds=[
 {"tag":"vless-ws","listen":"127.0.0.1","port":10081,"protocol":"vless",
  "settings":{"clients":clients["ws"],"decryption":"none"},
  "streamSettings":{"network":"ws","security":"none","wsSettings":{"path":"/vless-ws","acceptProxyProtocol":False}},
  "sniffing":{"enabled":True,"destOverride":["http","tls","quic"],"routeOnly":True}},
 {"tag":"vless-httpupgrade","listen":"127.0.0.1","port":10082,"protocol":"vless",
  "settings":{"clients":clients["httpupgrade"],"decryption":"none"},
  "streamSettings":{"network":"httpupgrade","security":"none","httpupgradeSettings":{"path":"/vless-httpupgrade","acceptProxyProtocol":False}},
  "sniffing":{"enabled":True,"destOverride":["http","tls","quic"],"routeOnly":True}},
 {"tag":"vless-xhttp","listen":"127.0.0.1","port":10083,"protocol":"vless",
  "settings":{"clients":clients["xhttp"],"decryption":"none"},
  "streamSettings":{"network":"xhttp","security":"none","xhttpSettings":{"path":"/vless-xhttp","mode":"auto"}},
  "sniffing":{"enabled":True,"destOverride":["http","tls","quic"],"routeOnly":True}},
]
if read("socks-enabled","0")=="1":
    inbounds.append({
      "tag":"socks-server","listen":read("socks-bind","127.0.0.1"),"port":int(read("socks-port","1080")),
      "protocol":"socks","settings":{"auth":"password","accounts":[{"user":read("socks-user"),"pass":read("socks-pass")}],"udp":True},
      "sniffing":{"enabled":True,"destOverride":["http","tls","quic"],"routeOnly":True}
    })

outbounds=[
 {"tag":"direct","protocol":"freedom","settings":{"domainStrategy":"UseIP"}},
 {"tag":"block","protocol":"blackhole","settings":{}}
]
proxy_tags=[]
try:
    with open(os.path.join(state,"proxies.tsv"), encoding="utf-8") as f:
        for row in csv.reader(f, delimiter="\t"):
            if len(row)<7 or row[6]!="1": continue
            pid,ptype,host,port,user,pw,enabled=row[:7]
            tag=f"proxy-{pid}"
            if ptype in ("socks5","socks5h"):
                settings={"address":host,"port":int(port)}
            elif ptype in ("http","https"):
                settings={"address":host,"port":int(port)}
            else: continue
            if user:
                settings.update({"user":user,"pass":pw})
            ob={"tag":tag,"protocol":"socks" if ptype.startswith("socks") else "http","settings":settings}
            if ptype=="https":
                ob["streamSettings"]={"security":"tls","tlsSettings":{"serverName":host}}
            outbounds.append(ob); proxy_tags.append(tag)
except FileNotFoundError: pass

mode=read("proxy-mode","direct")
selected=read("proxy-selected","")
selected_tag=f"proxy-{selected}" if f"proxy-{selected}" in proxy_tags else (proxy_tags[0] if proxy_tags else "direct")
rules=[
 {"type":"field","ip":["geoip:private"],"outboundTag":"block"},
 {"type":"field","protocol":["bittorrent"],"outboundTag":"block"}
]
balancers=[]
if mode=="full" and proxy_tags:
    if read("proxy-rotate","0")=="1" and len(proxy_tags)>1:
        balancers=[{"tag":"proxy-pool","selector":proxy_tags,"strategy":{"type":"random"}}]
        rules.append({"type":"field","network":"tcp,udp","balancerTag":"proxy-pool"})
    else:
        rules.append({"type":"field","network":"tcp,udp","outboundTag":selected_tag})
elif mode=="region" and proxy_tags:
    domains=[]
    for line in read("region-domains","").splitlines():
        line=line.strip()
        if line and not line.startswith("#"):
            domains.append(line if ":" in line else "domain:"+line)
    if domains:
        rules.append({"type":"field","domain":domains,"outboundTag":selected_tag})

config={
 "log":{"loglevel":"warning","access":"/var/log/xray-access.log","error":"/var/log/xray-error.log"},
 "api":{"tag":"api","services":["HandlerService","LoggerService","StatsService"]},
 "stats":{},
 "policy":{"levels":{"0":{"statsUserUplink":True,"statsUserDownlink":True}},"system":{"statsInboundUplink":True,"statsInboundDownlink":True}},
 "dns":{"servers":["https+local://1.1.1.1/dns-query","https+local://8.8.8.8/dns-query","localhost"],"queryStrategy":"UseIP"},
 "inbounds":inbounds,
 "outbounds":outbounds,
 "routing":{"domainStrategy":"IPIfNonMatch","rules":rules,"balancers":balancers}
}
os.makedirs(os.path.dirname(output), exist_ok=True)
with open(output,"w",encoding="utf-8") as f: json.dump(config,f,indent=2)
PY
  chown nobody:nogroup "$XRAY_CONFIG"
  chmod 640 "$XRAY_CONFIG"
}
render_all(){
  init_state
  render_xray
  render_nginx
  /usr/local/bin/xray run -test -config "$XRAY_CONFIG" >/dev/null
  nginx -t >/dev/null
}

install_all(){
  need_root; check_os; touch "$LOG"; init_state
  run_spin "Memasang pakej" install_packages
  run_spin "Memasang Xray stabil disyorkan v26.6.22" install_xray v26.6.22
  cp -f "$0" "$BIN"; chmod 755 "$BIN"
  render_all
  systemctl enable --now nginx xray cron
  cat >/etc/cron.d/zyanv-vpn-expiry <<EOF
17 2 * * * root $BIN purge-expired --quiet
EOF
  printf '\n%bPemasangan selesai.%b Jalankan: %bvpn%b\n' "$C_GREEN" "$C_RESET" "$C_BOLD" "$C_RESET"
}
uninstall_all(){
  read -r -p "Taip DELETE untuk buang Xray, Nginx config dan semua data user: " ans
  [[ "$ans" == DELETE ]] || { echo "Dibatalkan."; return; }
  systemctl disable --now xray 2>/dev/null || true
  rm -f /etc/systemd/system/xray.service "$BIN" "$NGINX_SITE" "$NGINX_LINK" /etc/cron.d/zyanv-vpn-expiry
  rm -rf "$BASE" /usr/local/etc/xray /usr/local/share/xray /usr/local/bin/xray
  systemctl daemon-reload
  systemctl restart nginx 2>/dev/null || true
  echo "Uninstall selesai."
}

proto_name(){
  case "$1" in ws) echo "VLESS WebSocket";; httpupgrade) echo "VLESS HTTPUpgrade";; xhttp) echo "VLESS XHTTP";; *) return 1;; esac
}
add_user(){
  local proto=$1 name days uuid exp
  read -r -p "Nama user (huruf/nombor/_/-): " name
  [[ "$name" =~ ^[A-Za-z0-9_-]{2,32}$ ]] || die "Nama tidak sah."
  awk -F'\t' -v p="$proto" -v n="$name" '$1==p&&$2==n{found=1} END{exit found?0:1}' "$STATE/users.tsv" && die "User sudah wujud."
  read -r -p "Tempoh hari [30]: " days; days=${days:-30}
  [[ "$days" =~ ^[0-9]+$ ]] && ((days>=1 && days<=3650)) || die "Tempoh tidak sah."
  uuid=$(uuidgen); exp=$(date -d "+${days} days" +%F)
  printf '%s\t%s\t%s\t%s\t%s\n' "$proto" "$name" "$uuid" "$(date +%F)" "$exp" >>"$STATE/users.tsv"
  render_all; systemctl restart xray
  show_user_config "$proto" "$name"
}
trial_user(){
  local proto=$1 mins name uuid exp epoch
  read -r -p "Nama trial [trial$(date +%H%M)]: " name; name=${name:-trial$(date +%H%M)}
  read -r -p "Tempoh minit [60]: " mins; mins=${mins:-60}
  [[ "$mins" =~ ^[0-9]+$ ]] || die "Minit tidak sah."
  uuid=$(uuidgen); exp=$(date -d "+1 day" +%F); epoch=$(date -d "+${mins} minutes" +%s)
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$proto" "$name" "$uuid" "$(date +%F)" "$exp" "$epoch" >>"$STATE/users.tsv"
  ( sleep "$((mins*60))"; "$BIN" delete-user "$proto" "$name" --quiet ) >/dev/null 2>&1 &
  render_all; systemctl restart xray
  show_user_config "$proto" "$name"
}
list_users(){
  local proto=$1
  printf '%-18s %-38s %-12s\n' "NAMA" "UUID" "TAMAT"
  awk -F'\t' -v p="$proto" '$1==p{printf "%-18s %-38s %-12s\n",$2,$3,$5}' "$STATE/users.tsv"
}
delete_user(){
  local proto=$1 name=${2:-}
  [[ -n "$name" ]] || read -r -p "Nama user: " name
  awk -F'\t' -v p="$proto" -v n="$name" 'BEGIN{OFS="\t"} !($1==p&&$2==n)' "$STATE/users.tsv" >"$STATE/users.tmp"
  mv "$STATE/users.tmp" "$STATE/users.tsv"
  render_all; systemctl restart xray
}
renew_user(){
  local proto=$1 name days
  read -r -p "Nama user: " name
  read -r -p "Tambah hari [30]: " days; days=${days:-30}
  [[ "$days" =~ ^[0-9]+$ ]] || die "Hari tidak sah."
  awk -F'\t' -v p="$proto" -v n="$name" -v days="$days" '
    BEGIN{OFS="\t"; cmd="date +%F"; cmd|getline today; close(cmd)}
    $1==p&&$2==n {
      base=($5>today?$5:today)
      cmd="date -d \""base" +"days" days\" +%F"; cmd|getline $5; close(cmd)
    } {print}
  ' "$STATE/users.tsv" >"$STATE/users.tmp"
  mv "$STATE/users.tmp" "$STATE/users.tsv"
  render_all; systemctl restart xray
}
purge_expired(){
  local today now
  today=$(date +%F); now=$(date +%s)
  awk -F'\t' -v t="$today" -v now="$now" 'BEGIN{OFS="\t"} $5>=t && (NF<6 || $6=="" || $6>now)' "$STATE/users.tsv" >"$STATE/users.tmp"
  mv "$STATE/users.tmp" "$STATE/users.tsv"
  render_all
  systemctl restart xray
}
show_user_config(){
  local proto=$1 name=${2:-} d uuid path type sec port
  [[ -n "$name" ]] || read -r -p "Nama user: " name
  d=$(domain); [[ "$d" != "-" ]] || d=$(get_public_ip)
  uuid=$(awk -F'\t' -v p="$proto" -v n="$name" '$1==p&&$2==n{print $3;exit}' "$STATE/users.tsv")
  [[ -n "$uuid" ]] || die "User tidak ditemui."
  case "$proto" in
    ws) type=ws; path="/vless-ws" ;;
    httpupgrade) type=httpupgrade; path="/vless-httpupgrade" ;;
    xhttp) type=xhttp; path="/vless-xhttp" ;;
  esac
  if [[ -s "$BASE/ssl/fullchain.pem" ]]; then sec=tls; port=443; else sec=none; port=80; fi
  local uri="vless://${uuid}@${d}:${port}?encryption=none&security=${sec}&type=${type}&host=${d}&path=$(python3 -c 'import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1],safe=""))' "$path")#${name}-${proto}"
  printf '\n%b%s%b\n%s\n\n' "$C_GREEN" "$(proto_name "$proto")" "$C_RESET" "$uri"
}
protocol_menu(){
  local proto=$1 choice
  while true; do
    header; dashboard
    printf '%b%s%b\n\n' "$C_BOLD" "$(proto_name "$proto")" "$C_RESET"
    printf '  1) Add user            2) Trial user\n'
    printf '  3) Renew user          4) Delete user\n'
    printf '  5) List user           6) Show config user\n'
    printf '  7) Remove expired      0) Back\n\n'
    read -r -p "Pilihan: " choice
    case "$choice" in
      1) add_user "$proto"; pause;; 2) trial_user "$proto"; pause;;
      3) renew_user "$proto"; pause;; 4) delete_user "$proto"; pause;;
      5) list_users "$proto"; pause;; 6) show_user_config "$proto"; pause;;
      7) purge_expired; echo "User expired dibuang."; pause;; 0) return;;
    esac
  done
}
vless_menu(){
  local c
  while true; do
    header; dashboard
    printf '  1) VLESS WebSocket\n  2) VLESS HTTPUpgrade\n  3) VLESS XHTTP\n  0) Back\n\n'
    read -r -p "Pilihan: " c
    case "$c" in 1) protocol_menu ws;; 2) protocol_menu httpupgrade;; 3) protocol_menu xhttp;; 0) return;; esac
  done
}

proxy_add(){
  local type host port user pass id
  read -r -p "Jenis [socks5/socks5h/http/https]: " type
  [[ "$type" =~ ^(socks5|socks5h|http|https)$ ]] || die "Jenis tidak sah."
  read -r -p "IP/host: " host; [[ -n "$host" ]] || die "Host kosong."
  read -r -p "Port: " port; [[ "$port" =~ ^[0-9]+$ ]] && ((port<=65535)) || die "Port tidak sah."
  read -r -p "Username (kosong jika tiada): " user
  if [[ -n "$user" ]]; then read -r -s -p "Password: " pass; echo; else pass=""; fi
  id=$(date +%s%N | tail -c 7)
  printf '%s\t%s\t%s\t%s\t%s\t%s\t1\n' "$id" "$type" "$host" "$port" "$user" "$pass" >>"$STATE/proxies.tsv"
  echo "$id" >"$STATE/proxy-selected"
  render_all; systemctl restart xray
}
proxy_list(){
  printf '%-8s %-8s %-24s %-6s %-14s %-5s\n' ID TYPE HOST PORT USER ON
  awk -F'\t' '{printf "%-8s %-8s %-24s %-6s %-14s %-5s\n",$1,$2,$3,$4,$5,$7}' "$STATE/proxies.tsv"
}
proxy_delete(){
  local id; proxy_list; read -r -p "ID proxy untuk delete: " id
  awk -F'\t' -v id="$id" 'BEGIN{OFS="\t"} $1!=id' "$STATE/proxies.tsv" >"$STATE/proxies.tmp"
  mv "$STATE/proxies.tmp" "$STATE/proxies.tsv"
  [[ "$(cat "$STATE/proxy-selected" 2>/dev/null || true)" == "$id" ]] && rm -f "$STATE/proxy-selected"
  render_all; systemctl restart xray
}
proxy_select(){
  local id; proxy_list; read -r -p "ID proxy: " id
  awk -F'\t' -v id="$id" '$1==id{ok=1} END{exit ok?0:1}' "$STATE/proxies.tsv" || die "ID tidak ditemui."
  echo "$id" >"$STATE/proxy-selected"; render_all; systemctl restart xray
}
proxy_test(){
  local id type host port user pass auth url start end ms
  proxy_list; read -r -p "ID proxy (kosong = semua): " id
  while IFS=$'\t' read -r pid type host port user pass enabled; do
    [[ -z "$id" || "$pid" == "$id" ]] || continue
    auth=""; [[ -n "$user" ]] && auth="${user}:${pass}"
    case "$type" in
      socks5) url="socks5://${auth:+$auth@}${host}:${port}";;
      socks5h) url="socks5h://${auth:+$auth@}${host}:${port}";;
      http) url="http://${auth:+$auth@}${host}:${port}";;
      https) url="https://${auth:+$auth@}${host}:${port}";;
    esac
    start=$(date +%s%3N)
    if curl -fsS --max-time 8 --proxy "$url" https://www.gstatic.com/generate_204 -o /dev/null; then
      end=$(date +%s%3N); ms=$((end-start)); printf '%bOK%b  %-8s %sms\n' "$C_GREEN" "$C_RESET" "$pid" "$ms"
    else printf '%bFAIL%b %-8s\n' "$C_RED" "$C_RESET" "$pid"; fi
  done <"$STATE/proxies.tsv"
}
proxy_mode(){
  local m
  printf '1) Direct  2) Full traffic proxy  3) Region/domain list\n'
  read -r -p "Pilihan: " m
  case "$m" in 1) echo direct >"$STATE/proxy-mode";; 2) echo full >"$STATE/proxy-mode";; 3) echo region >"$STATE/proxy-mode";; *) return;; esac
  render_all; systemctl restart xray
}
proxy_domains(){
  local c d
  while true; do
    printf '\nDomain region:\n'; nl -ba "$STATE/region-domains.txt" 2>/dev/null || true
    printf '\n1) Add  2) Delete  0) Back\n'; read -r -p "Pilihan: " c
    case "$c" in
      1) read -r -p "Domain/geosite (contoh netflix.com atau geosite:netflix): " d; echo "$d" >>"$STATE/region-domains.txt";;
      2) read -r -p "Nombor baris: " d; sed -i "${d}d" "$STATE/region-domains.txt";;
      0) break;;
    esac
  done
  render_all; systemctl restart xray
}
proxy_rotate(){
  local v; v=$(cat "$STATE/proxy-rotate" 2>/dev/null || echo 0)
  [[ "$v" == 1 ]] && echo 0 >"$STATE/proxy-rotate" || echo 1 >"$STATE/proxy-rotate"
  render_all; systemctl restart xray
}
socks_server(){
  local c
  while true; do
    header
    printf 'SOCKS5 server: %s\nBind: %s  Port: %s\nUser: %s\nPassword: %s\n\n' \
      "$([[ $(cat "$STATE/socks-enabled") == 1 ]] && echo ON || echo OFF)" \
      "$(cat "$STATE/socks-bind")" "$(cat "$STATE/socks-port")" \
      "$(cat "$STATE/socks-user")" "$(cat "$STATE/socks-pass")"
    printf '1) Enable public (0.0.0.0)\n2) Enable local only\n3) Disable\n4) Tukar credential/port\n0) Back\n'
    read -r -p "Pilihan: " c
    case "$c" in
      1) echo 1 >"$STATE/socks-enabled"; echo 0.0.0.0 >"$STATE/socks-bind"; render_all; systemctl restart xray;;
      2) echo 1 >"$STATE/socks-enabled"; echo 127.0.0.1 >"$STATE/socks-bind"; render_all; systemctl restart xray;;
      3) echo 0 >"$STATE/socks-enabled"; render_all; systemctl restart xray;;
      4)
        read -r -p "Port [1080]: " p; echo "${p:-1080}" >"$STATE/socks-port"
        read -r -p "User: " u; echo "$u" >"$STATE/socks-user"
        read -r -s -p "Password: " pw; echo; echo "$pw" >"$STATE/socks-pass"
        render_all; systemctl restart xray;;
      0) return;;
    esac
  done
}
proxy_show(){
  local id; id=$(cat "$STATE/proxy-selected" 2>/dev/null || true)
  echo "Mode: $(cat "$STATE/proxy-mode") | Rotate: $(cat "$STATE/proxy-rotate" 2>/dev/null || echo 0)"
  awk -F'\t' -v id="$id" '$1==id{printf "Type: %s\nHost: %s\nPort: %s\nUser: %s\nPass: %s\nEnabled: %s\n",$2,$3,$4,$5,$6,$7}' "$STATE/proxies.tsv"
}
proxy_menu(){
  local c
  while true; do
    header; dashboard
    printf '  1) Add proxy            2) List proxy\n'
    printf '  3) Test latency         4) Select proxy\n'
    printf '  5) Delete proxy         6) Mode direct/full/region\n'
    printf '  7) Region domain list   8) Toggle rotate\n'
    printf '  9) Show config proxy   10) SOCKS5 server\n'
    printf '  0) Back\n\n'
    read -r -p "Pilihan: " c
    case "$c" in
      1) proxy_add; pause;; 2) proxy_list; pause;; 3) proxy_test; pause;;
      4) proxy_select; pause;; 5) proxy_delete; pause;; 6) proxy_mode; pause;;
      7) proxy_domains;; 8) proxy_rotate; pause;; 9) proxy_show; pause;;
      10) socks_server;; 0) return;;
    esac
  done
}

set_dns(){
  local c servers
  printf '1) Cloudflare  2) Google  3) Quad9  4) Custom\n'
  read -r -p "Pilihan: " c
  case "$c" in
    1) servers=$'1.1.1.1\n1.0.0.1';; 2) servers=$'8.8.8.8\n8.8.4.4';;
    3) servers=$'9.9.9.9\n149.112.112.112';;
    4) read -r -p "DNS dipisah ruang: " raw; servers=$(tr ' ' '\n' <<<"$raw");;
    *) return;;
  esac
  mkdir -p /etc/systemd/resolved.conf.d
  printf '[Resolve]\nDNS=%s\nFallbackDNS=1.1.1.1 8.8.8.8\n' "$(paste -sd' ' <<<"$servers")" >/etc/systemd/resolved.conf.d/zyanv.conf
  systemctl restart systemd-resolved 2>/dev/null || {
    cp -a /etc/resolv.conf /etc/resolv.conf.zyanv.bak 2>/dev/null || true
    : >/etc/resolv.conf; while read -r s; do echo "nameserver $s" >>/etc/resolv.conf; done <<<"$servers"
  }
}
toggle_ipv6(){
  local state
  state=$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || echo 0)
  if [[ "$state" == 0 ]]; then
    cat >/etc/sysctl.d/99-zyanv-ipv6.conf <<EOF
net.ipv6.conf.all.disable_ipv6=1
net.ipv6.conf.default.disable_ipv6=1
EOF
  else
    cat >/etc/sysctl.d/99-zyanv-ipv6.conf <<EOF
net.ipv6.conf.all.disable_ipv6=0
net.ipv6.conf.default.disable_ipv6=0
EOF
  fi
  sysctl --system >/dev/null
}
set_autoreboot(){
  local c
  printf '1) Harian 04:00  2) Mingguan Ahad 04:00  3) Disable\n'
  read -r -p "Pilihan: " c
  case "$c" in
    1) echo '0 4 * * * root /sbin/reboot' >/etc/cron.d/zyanv-autoreboot;;
    2) echo '0 4 * * 0 root /sbin/reboot' >/etc/cron.d/zyanv-autoreboot;;
    3) rm -f /etc/cron.d/zyanv-autoreboot;;
  esac
}
change_xray(){
  local c ver
  printf '1) Latest stable release  2) Versi tertentu\n'
  read -r -p "Pilihan: " c
  case "$c" in 1) install_xray;; 2) read -r -p "Versi contoh v25.6.8: " ver; install_xray "$ver";; *) return;; esac
  /usr/local/bin/xray run -test -config "$XRAY_CONFIG"
  systemctl restart xray
}
system_menu(){
  local c
  while true; do
    header; dashboard
    printf '  1) Set domain            2) Issue/Renew SSL ACME\n'
    printf '  3) Auto reboot           4) Restart all service\n'
    printf '  5) Enable/Disable IPv6   6) Set DNS\n'
    printf '  7) Tukar Xray core       8) Validate config\n'
    printf '  0) Back\n\n'
    read -r -p "Pilihan: " c
    case "$c" in
      1) set_domain; pause;; 2) issue_ssl; pause;; 3) set_autoreboot; pause;;
      4) render_all; systemctl restart xray nginx; pause;;
      5) toggle_ipv6; pause;; 6) set_dns; pause;; 7) change_xray; pause;;
      8) xray run -test -config "$XRAY_CONFIG"; nginx -t; pause;; 0) return;;
    esac
  done
}
install_menu(){
  local c
  printf '1) Install/repair  2) Uninstall  0) Back\n'; read -r -p "Pilihan: " c
  case "$c" in 1) install_all;; 2) uninstall_all;; esac
}
main_menu(){
  need_root; init_state
  while true; do
    header; dashboard
    printf '  1) Install / Uninstall        2) Menu VLESS\n'
    printf '  3) SOCKS5 / HTTP Proxy        4) Menu System\n'
    printf '  0) Exit / Back\n\n'
    read -r -p "Pilihan: " c
    case "$c" in 1) install_menu; pause;; 2) vless_menu;; 3) proxy_menu;; 4) system_menu;; 0) exit 0;; esac
  done
}

case "${1:-menu}" in
  install) install_all;;
  uninstall) uninstall_all;;
  purge-expired) init_state; purge_expired;;
  delete-user) init_state; delete_user "${2:?proto}" "${3:?name}";;
  menu|"") main_menu;;
  *) echo "Usage: $0 [install|uninstall|purge-expired|menu]"; exit 1;;
esac
