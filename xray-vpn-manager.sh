#!/usr/bin/env bash
# ZYANV VPN Manager - single-file Xray/Nginx manager
# Target: Ubuntu 24.04 LTS and Debian 12/13 (Debian has no "24.04" release)
set -Eeuo pipefail
IFS=$'\n\t'

APP="zyanv-vpn"
BASE="/etc/${APP}"
STATE="${BASE}/state.json"
USERS="${BASE}/users.json"
PROXIES="${BASE}/proxies.json"
DOMAINS="${BASE}/proxy-domains.txt"
XRAY_CONFIG="/usr/local/etc/xray/config.json"
XRAY_BIN="/usr/local/bin/xray"
XRAY_SERVICE="/etc/systemd/system/xray.service"
NGINX_SITE="/etc/nginx/sites-available/${APP}.conf"
NGINX_LINK="/etc/nginx/sites-enabled/${APP}.conf"
CERT_DIR="${BASE}/ssl"
LOG_DIR="/var/log/xray"
MENU_BIN="/usr/local/sbin/vpn"
ACME_HOME="/root/.acme.sh"
WEBROOT="/var/www/${APP}"

C_RESET='\033[0m'; C_BOLD='\033[1m'; C_CYAN='\033[38;5;45m'; C_BLUE='\033[38;5;39m'
C_GREEN='\033[38;5;82m'; C_RED='\033[38;5;196m'; C_YELLOW='\033[38;5;220m'; C_GRAY='\033[38;5;245m'

trap 'printf "\n%bRalat pada baris %s. Semak: journalctl -u xray -u nginx --no-pager%b\n" "$C_RED" "$LINENO" "$C_RESET"' ERR

need_root(){ [[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "Jalankan sebagai root."; exit 1; }; }
command_exists(){ command -v "$1" >/dev/null 2>&1; }
pause(){ read -r -p "Tekan Enter untuk kembali..." _ || true; }
clear_screen(){ printf '\033c'; }
spinner(){
  local pid="$1" msg="${2:-Memproses}" chars='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏' i=0
  while kill -0 "$pid" 2>/dev/null; do
    printf "\r%b%s%b %s" "$C_CYAN" "${chars:i++%${#chars}:1}" "$C_RESET" "$msg"
    sleep 0.09
  done
  wait "$pid"; local rc=$?
  if (( rc == 0 )); then printf "\r%b✓%b %s\n" "$C_GREEN" "$C_RESET" "$msg"; else printf "\r%b✗%b %s\n" "$C_RED" "$C_RESET" "$msg"; fi
  return "$rc"
}
run_spin(){ ( "$@" ) >/tmp/${APP}.last.log 2>&1 & spinner $! "${*: -1}"; }

json_get(){ jq -r "$1 // empty" "$STATE" 2>/dev/null || true; }
state_set(){
  local tmp filter
  tmp=$(mktemp)
  if (( $# == 1 )); then
    filter="$1"; jq "$filter" "$STATE" >"$tmp"
  else
    filter="${!#}"
    local -a args=("${@:1:$#-1}")
    jq "${args[@]}" "$filter" "$STATE" >"$tmp"
  fi
  mv "$tmp" "$STATE"
}
valid_domain(){ [[ "$1" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]; }
valid_port(){ [[ "$1" =~ ^[0-9]+$ ]] && ((1<=10#$1 && 10#$1<=65535)); }
valid_uuid(){ [[ "$1" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$ ]]; }
public_ip(){ curl -4fsS --max-time 5 https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}'; }
service_state(){ systemctl is-active "$1" 2>/dev/null || echo inactive; }
status_badge(){ [[ "$1" == active ]] && printf "%bON%b" "$C_GREEN" "$C_RESET" || printf "%bOFF%b" "$C_RED" "$C_RESET"; }
now_epoch(){ date +%s; }
iso_date_to_epoch(){ date -d "$1 23:59:59" +%s 2>/dev/null || return 1; }

init_state(){
  mkdir -p "$BASE" "$CERT_DIR" "$LOG_DIR" "$WEBROOT/.well-known/acme-challenge" /usr/local/etc/xray
  chmod 700 "$BASE" "$CERT_DIR"
  [[ -f "$USERS" ]] || echo '[]' > "$USERS"
  [[ -f "$PROXIES" ]] || echo '[]' > "$PROXIES"
  [[ -f "$DOMAINS" ]] || cat > "$DOMAINS" <<'EOF'
geosite:google
geosite:netflix
domain:viu.com
domain:iq.com
domain:iqiyi.com
EOF
  [[ -f "$STATE" ]] || cat > "$STATE" <<'JSON'
{
  "domain":"",
  "paths":{"ws":"/vless-ws","httpupgrade":"/vless-hu","xhttp":"/vless-xhttp"},
  "localPorts":{"ws":10001,"httpupgrade":10002,"xhttp":10003},
  "publicPorts":[80,8080,8880],
  "proxy":{"enabled":false,"mode":"domain","selected":[],"type":"socks5","rotate":false},
  "dns":{"preset":"cloudflare","servers":["1.1.1.1","1.0.0.1"]},
  "ipv6":true,
  "autoreboot":{"enabled":false,"time":"04:30"},
  "xrayChannel":"stable"
}
JSON
}

install_packages(){
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y curl wget unzip jq nginx socat cron ca-certificates openssl uuid-runtime dnsutils iproute2 lsof netcat-openbsd
}

install_xray(){
  local channel tag api
  channel=$(json_get '.xrayChannel'); [[ -n "$channel" ]] || channel=stable
  api="https://api.github.com/repos/XTLS/Xray-core/releases"
  if [[ "$channel" == latest ]]; then
    tag=$(curl -fsSL "$api?per_page=20" | jq -r '.[0].tag_name')
  else
    tag=$(curl -fsSL "$api?per_page=30" | jq -r '[.[]|select(.prerelease==false and .draft==false)][0].tag_name // .[0].tag_name')
  fi
  [[ -n "$tag" && "$tag" != null ]] || { echo "Tidak dapat menentukan versi Xray."; return 1; }
  local arch asset tmp
  case "$(uname -m)" in x86_64) arch=64;; aarch64|arm64) arch=arm64-v8a;; *) echo "Seni bina tidak disokong: $(uname -m)"; return 1;; esac
  asset="Xray-linux-${arch}.zip"; tmp=$(mktemp -d)
  curl -fL "https://github.com/XTLS/Xray-core/releases/download/${tag}/${asset}" -o "$tmp/xray.zip"
  unzip -qo "$tmp/xray.zip" -d "$tmp/xray"
  install -m 755 "$tmp/xray/xray" "$XRAY_BIN"
  install -m 644 "$tmp/xray/geoip.dat" /usr/local/share/xray/geoip.dat 2>/dev/null || { mkdir -p /usr/local/share/xray; install -m 644 "$tmp/xray/geoip.dat" /usr/local/share/xray/geoip.dat; }
  install -m 644 "$tmp/xray/geosite.dat" /usr/local/share/xray/geosite.dat
  echo "$tag" > "$BASE/xray-version"
  rm -rf "$tmp"
}

write_systemd(){
  cat > "$XRAY_SERVICE" <<EOF
[Unit]
Description=Xray Service (${APP})
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
Type=simple
User=nobody
Group=nogroup
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=${XRAY_BIN} run -c ${XRAY_CONFIG}
Restart=on-failure
RestartSec=3s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable xray >/dev/null
}

build_outbounds(){
  local enabled mode rotate selected_count
  enabled=$(json_get '.proxy.enabled'); mode=$(json_get '.proxy.mode'); rotate=$(json_get '.proxy.rotate')
  selected_count=$(jq '[.[]|select(.enabled==true)]|length' "$PROXIES")
  jq -n --argjson enabled "${enabled:-false}" --arg mode "${mode:-domain}" --argjson rotate "${rotate:-false}" \
    --slurpfile proxies "$PROXIES" '
    def pobj($p):
      if $p.type=="http" then
        {tag:("proxy-"+$p.id),protocol:"http",settings:{servers:[({address:$p.host,port:$p.port}|if ($p.user//"")!="" then .+{users:[{user:$p.user,pass:($p.pass//"")}]} else . end)]}}
      else
        {tag:("proxy-"+$p.id),protocol:"socks",settings:{servers:[({address:$p.host,port:$p.port}|if ($p.user//"")!="" then .+{users:[{user:$p.user,pass:($p.pass//"")}]} else . end)]}}
      end;
    [{tag:"direct",protocol:"freedom",settings:{domainStrategy:"UseIP"}},
     {tag:"blocked",protocol:"blackhole",settings:{}}]
    + (if $enabled then [$proxies[0][]|select(.enabled==true)|pobj(.)] else [] end)
  '
}

build_config(){
  local tmp outbounds enabled mode rotate domains_json dns_json ws_port hu_port xh_port
  tmp=$(mktemp); outbounds=$(build_outbounds)
  enabled=$(json_get '.proxy.enabled'); mode=$(json_get '.proxy.mode'); rotate=$(json_get '.proxy.rotate')
  ws_port=$(json_get '.localPorts.ws'); hu_port=$(json_get '.localPorts.httpupgrade'); xh_port=$(json_get '.localPorts.xhttp')
  domains_json=$(grep -Ev '^\s*(#|$)' "$DOMAINS" | jq -R . | jq -s .)
  dns_json=$(jq '.dns.servers' "$STATE")

  jq -n \
    --slurpfile users "$USERS" --argjson outbounds "$outbounds" --argjson dns "$dns_json" --argjson proxyEnabled "${enabled:-false}" \
    --arg proxyMode "${mode:-domain}" --argjson rotate "${rotate:-false}" --argjson proxyDomains "$domains_json" \
    --arg wsPath "$(json_get '.paths.ws')" --arg huPath "$(json_get '.paths.httpupgrade')" --arg xhPath "$(json_get '.paths.xhttp')" \
    --argjson wsPort "$ws_port" --argjson huPort "$hu_port" --argjson xhPort "$xh_port" '
    def clients: [$users[0][]|select(.expiry > (now|floor))|{id:.uuid,email:(.name+"@zyanv"),level:0}];
    def pTags: [$outbounds[]|select(.tag|startswith("proxy-"))|.tag];
    def routeRules:
      ([{type:"field",ip:["geoip:private"],outboundTag:"blocked"},{type:"field",network:"udp",outboundTag:"direct"}]
      + (if $proxyEnabled and (pTags|length)>0 then
          (if $proxyMode=="full" then [{type:"field",network:"tcp",balancerTag:"proxy-balancer"}]
           else [{type:"field",network:"tcp",domain:$proxyDomains,balancerTag:"proxy-balancer"}] end)
        else [] end));
    {
      log:{loglevel:"warning",access:"/var/log/xray/access.log",error:"/var/log/xray/error.log"},
      dns:{servers:$dns,queryStrategy:"UseIP"},
      policy:{levels:{"0":{statsUserUplink:true,statsUserDownlink:true}},system:{statsInboundUplink:true,statsInboundDownlink:true,statsOutboundUplink:true,statsOutboundDownlink:true}},
      inbounds:[
        {tag:"vless-ws",listen:"127.0.0.1",port:$wsPort,protocol:"vless",settings:{clients:clients,decryption:"none"},streamSettings:{network:"ws",wsSettings:{path:$wsPath,acceptProxyProtocol:false}},sniffing:{enabled:true,destOverride:["http","tls","quic"],routeOnly:true}},
        {tag:"vless-httpupgrade",listen:"127.0.0.1",port:$huPort,protocol:"vless",settings:{clients:clients,decryption:"none"},streamSettings:{network:"httpupgrade",httpupgradeSettings:{path:$huPath}},sniffing:{enabled:true,destOverride:["http","tls","quic"],routeOnly:true}},
        {tag:"vless-xhttp",listen:"127.0.0.1",port:$xhPort,protocol:"vless",settings:{clients:clients,decryption:"none"},streamSettings:{network:"xhttp",xhttpSettings:{path:$xhPath,mode:"stream-up"}},sniffing:{enabled:true,destOverride:["http","tls","quic"],routeOnly:true}}
      ],
      outbounds:$outbounds,
      routing:{domainStrategy:"IPIfNonMatch",rules:routeRules,balancers:(if $proxyEnabled and (pTags|length)>0 then [{tag:"proxy-balancer",selector:["proxy-"],fallbackTag:"direct",strategy:{type:(if $rotate then "roundRobin" else "random" end)}}] else [] end)}
    }' > "$tmp"
  "$XRAY_BIN" run -test -c "$tmp" >/dev/null
  install -m 640 -o root -g nogroup "$tmp" "$XRAY_CONFIG"
  rm -f "$tmp"
}

nginx_locations(){
  local ws hu xh wp hp xp
  ws=$(json_get '.paths.ws'); hu=$(json_get '.paths.httpupgrade'); xh=$(json_get '.paths.xhttp')
  wp=$(json_get '.localPorts.ws'); hp=$(json_get '.localPorts.httpupgrade'); xp=$(json_get '.localPorts.xhttp')
  cat <<EOF
  location ${ws} {
    proxy_pass http://127.0.0.1:${wp}; proxy_http_version 1.1;
    proxy_set_header Upgrade \$http_upgrade; proxy_set_header Connection "upgrade";
    proxy_set_header Host \$host; proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_read_timeout 86400s; proxy_send_timeout 86400s;
  }
  location ${hu} {
    proxy_pass http://127.0.0.1:${hp}; proxy_http_version 1.1;
    proxy_set_header Upgrade \$http_upgrade; proxy_set_header Connection "upgrade";
    proxy_set_header Host \$host; proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_read_timeout 86400s; proxy_send_timeout 86400s;
  }
  location ${xh} {
    client_max_body_size 0; proxy_request_buffering off; proxy_buffering off;
    proxy_pass http://127.0.0.1:${xp}; proxy_http_version 1.1;
    proxy_set_header Host \$host; proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_read_timeout 86400s; proxy_send_timeout 86400s;
  }
EOF
}

write_nginx(){
  local domain cert key ports loc
  domain=$(json_get '.domain'); cert="$CERT_DIR/fullchain.cer"; key="$CERT_DIR/private.key"; loc=$(nginx_locations)
  [[ -n "$domain" ]] || domain="_"
  cat > "$NGINX_SITE" <<EOF
map \$http_upgrade \$connection_upgrade { default upgrade; '' close; }
server_tokens off;

server {
  listen 80 default_server reuseport;
  listen [::]:80 default_server reuseport;
  server_name ${domain};
  root ${WEBROOT};
  location ^~ /.well-known/acme-challenge/ { try_files \$uri =404; }
${loc}
  location / { return 200 'ZYANV VPN service is running\n'; add_header Content-Type text/plain; }
}
server {
  listen 8080 reuseport; listen [::]:8080 reuseport;
  server_name ${domain}; root ${WEBROOT};
${loc}
  location / { return 204; }
}
server {
  listen 8880 reuseport; listen [::]:8880 reuseport;
  server_name ${domain}; root ${WEBROOT};
${loc}
  location / { return 204; }
}
EOF
  if [[ -s "$cert" && -s "$key" ]]; then
    cat >> "$NGINX_SITE" <<EOF
server {
  listen 443 ssl http2 reuseport; listen [::]:443 ssl http2 reuseport;
  server_name ${domain}; root ${WEBROOT};
  ssl_certificate ${cert}; ssl_certificate_key ${key};
  ssl_protocols TLSv1.2 TLSv1.3; ssl_session_cache shared:SSL:20m; ssl_session_timeout 1d;
  ssl_session_tickets off; ssl_stapling on; ssl_stapling_verify on;
  add_header Strict-Transport-Security "max-age=31536000" always;
${loc}
  location / { return 200 'ZYANV TLS service is running\n'; add_header Content-Type text/plain; }
}
EOF
  fi
  ln -sfn "$NGINX_SITE" "$NGINX_LINK"
  rm -f /etc/nginx/sites-enabled/default
  nginx -t
}

reload_all(){
  remove_expired_quiet
  build_config
  write_nginx
  systemctl restart xray
  systemctl reload nginx
}

issue_ssl(){
  local domain
  domain=$(json_get '.domain'); [[ -n "$domain" ]] || { echo "Tetapkan domain dahulu."; return 1; }
  valid_domain "$domain" || { echo "Domain tidak sah."; return 1; }
  local resolved ip; resolved=$(dig +short A "$domain" | tail -1); ip=$(public_ip)
  echo "A record: ${resolved:-tiada} | VPS: ${ip:-tidak diketahui}"
  [[ "$resolved" == "$ip" ]] || echo -e "${C_YELLOW}Amaran: A record tidak sama dengan IP VPS. Cloudflare Proxy perlu DNS-only sementara untuk HTTP-01.${C_RESET}"
  systemctl reload nginx
  if [[ ! -x "$ACME_HOME/acme.sh" ]]; then curl -fsSL https://get.acme.sh | sh -s email=ssl@"$domain"; fi
  "$ACME_HOME/acme.sh" --set-default-ca --server letsencrypt
  "$ACME_HOME/acme.sh" --issue -d "$domain" -w "$WEBROOT" --keylength ec-256 --force
  "$ACME_HOME/acme.sh" --install-cert -d "$domain" --ecc \
    --fullchain-file "$CERT_DIR/fullchain.cer" --key-file "$CERT_DIR/private.key" \
    --reloadcmd "systemctl reload nginx"
  chmod 600 "$CERT_DIR/private.key"
  write_nginx && systemctl reload nginx
}

add_user(){
  local proto="$1" name days uuid expiry tmp
  read -r -p "Nama user: " name; [[ "$name" =~ ^[A-Za-z0-9._-]{2,32}$ ]] || { echo "Nama tidak sah."; return; }
  read -r -p "Tempoh hari [30]: " days; days=${days:-30}; [[ "$days" =~ ^[0-9]+$ ]] || return
  uuid=$(uuidgen); expiry=$(date -d "+$days days" +%s)
  tmp=$(mktemp); jq --arg n "$name" --arg u "$uuid" --arg p "$proto" --argjson e "$expiry" '. += [{name:$n,uuid:$u,protocol:$p,expiry:$e,created:now|floor}]' "$USERS" > "$tmp" && mv "$tmp" "$USERS"
  reload_all
  show_user_config "$name"
}
trial_user(){ local proto="$1"; local name="trial-$(date +%H%M%S)" uuid=$(uuidgen) expiry=$(date -d '+1 day' +%s) tmp=$(mktemp); jq --arg n "$name" --arg u "$uuid" --arg p "$proto" --argjson e "$expiry" '. += [{name:$n,uuid:$u,protocol:$p,expiry:$e,created:now|floor}]' "$USERS" > "$tmp" && mv "$tmp" "$USERS"; reload_all; show_user_config "$name"; }
list_users(){ jq -r 'sort_by(.expiry)[] | [.name,.protocol,.uuid,(.expiry|strftime("%Y-%m-%d")),(if .expiry>now then "AKTIF" else "EXPIRED" end)]|@tsv' "$USERS" | column -t -s $'\t' || true; }
delete_user(){ local name tmp; list_users; read -r -p "Nama user untuk delete: " name; tmp=$(mktemp); jq --arg n "$name" 'map(select(.name!=$n))' "$USERS" > "$tmp" && mv "$tmp" "$USERS"; reload_all; }
renew_user(){ local name days tmp; list_users; read -r -p "Nama user: " name; read -r -p "Tambah hari [30]: " days; days=${days:-30}; tmp=$(mktemp); jq --arg n "$name" --argjson d "$days" 'map(if .name==$n then .expiry=((if .expiry>now then .expiry else now end)+($d*86400)|floor) else . end)' "$USERS" > "$tmp" && mv "$tmp" "$USERS"; reload_all; }
remove_expired_quiet(){ local tmp=$(mktemp); jq 'map(select(.expiry>now))' "$USERS" > "$tmp" && mv "$tmp" "$USERS"; }
remove_expired(){ local before after; before=$(jq length "$USERS"); remove_expired_quiet; after=$(jq length "$USERS"); reload_all; echo "$((before-after)) user expired dibuang."; }
show_user_config(){
  local name="${1:-}" row domain uuid exp ws hu xh
  [[ -n "$name" ]] || { list_users; read -r -p "Nama user: " name; }
  row=$(jq -c --arg n "$name" '.[]|select(.name==$n)' "$USERS" | head -1); [[ -n "$row" ]] || { echo "User tidak ditemui."; return; }
  domain=$(json_get '.domain'); uuid=$(jq -r .uuid <<<"$row"); exp=$(jq -r '.expiry|strftime("%Y-%m-%d")' <<<"$row")
  ws=$(json_get '.paths.ws'); hu=$(json_get '.paths.httpupgrade'); xh=$(json_get '.paths.xhttp')
  echo -e "\n${C_BOLD}User:${C_RESET} $name | Expiry: $exp"
  echo "TLS WS:  vless://${uuid}@${domain}:443?encryption=none&security=tls&type=ws&host=${domain}&path=$(printf %s "$ws"|jq -sRr @uri)#${name}-WS-TLS"
  echo "TLS HU:  vless://${uuid}@${domain}:443?encryption=none&security=tls&type=httpupgrade&host=${domain}&path=$(printf %s "$hu"|jq -sRr @uri)#${name}-HU-TLS"
  echo "TLS XH:  vless://${uuid}@${domain}:443?encryption=none&security=tls&type=xhttp&host=${domain}&path=$(printf %s "$xh"|jq -sRr @uri)&mode=stream-up#${name}-XHTTP-TLS"
  for p in 80 8080 8880; do
    echo "NTLS WS $p: vless://${uuid}@${domain}:${p}?encryption=none&security=none&type=ws&host=${domain}&path=$(printf %s "$ws"|jq -sRr @uri)#${name}-WS-${p}"
  done
}

vless_menu(){
  local proto="$1" title
  case "$proto" in ws) title="VLESS WebSocket";; httpupgrade) title="VLESS HTTP Upgrade";; xhttp) title="VLESS XHTTP";; esac
  while true; do clear_screen; header "$title"; two_col "1) Add user" "5) Renew user" "2) Trial user" "6) Remove expired" "3) List user" "7) Check config user" "4) Delete user" "0) Back"; read -r -p "Pilih: " c
    case "$c" in 1)add_user "$proto";pause;;2)trial_user "$proto";pause;;3)list_users;pause;;4)delete_user;pause;;5)renew_user;pause;;6)remove_expired;pause;;7)show_user_config;pause;;0)return;;esac
  done
}

add_proxy(){
  local type host port user pass id tmp
  read -r -p "Jenis [socks5/http]: " type; [[ "$type" == socks5 || "$type" == http ]] || return
  read -r -p "IP/host: " host; [[ -n "$host" ]] || return
  read -r -p "Port: " port; valid_port "$port" || return
  read -r -p "Username (kosong jika tiada): " user; read -r -s -p "Password: " pass; echo
  id=$(openssl rand -hex 4); tmp=$(mktemp)
  jq --arg id "$id" --arg t "$type" --arg h "$host" --argjson p "$port" --arg u "$user" --arg pw "$pass" '. += [{id:$id,type:$t,host:$h,port:$p,user:$u,pass:$pw,enabled:false}]' "$PROXIES" > "$tmp" && mv "$tmp" "$PROXIES"
}
list_proxies(){ jq -r '.[]|[.id,.type,(.host+":"+(.port|tostring)),(.user//"-"),(if .enabled then "USED" else "OFF" end)]|@tsv' "$PROXIES" | column -t -s $'\t' || true; }
toggle_proxy_item(){ local id tmp; list_proxies; read -r -p "ID proxy: " id; tmp=$(mktemp); jq --arg id "$id" 'map(if .id==$id then .enabled=(.enabled|not) else . end)' "$PROXIES" > "$tmp" && mv "$tmp" "$PROXIES"; reload_all; }
delete_proxy(){ local id tmp; list_proxies; read -r -p "ID proxy delete: " id; tmp=$(mktemp); jq --arg id "$id" 'map(select(.id!=$id))' "$PROXIES" > "$tmp" && mv "$tmp" "$PROXIES"; reload_all; }
check_proxy(){
  local id p type host port user pass
  list_proxies; read -r -p "ID proxy check: " id; p=$(jq -c --arg id "$id" '.[]|select(.id==$id)' "$PROXIES"); [[ -n "$p" ]] || return
  type=$(jq -r .type<<<"$p"); host=$(jq -r .host<<<"$p"); port=$(jq -r .port<<<"$p"); user=$(jq -r .user<<<"$p"); pass=$(jq -r .pass<<<"$p")
  local auth=(); [[ -n "$user" ]] && auth=(-U "$user:$pass")
  if [[ "$type" == http ]]; then curl -fsS --max-time 12 -x "http://$host:$port" "${auth[@]}" https://api.ipify.org && echo; else curl -fsS --max-time 12 --socks5-hostname "$host:$port" ${user:+--proxy-user "$user:$pass"} https://api.ipify.org && echo; fi
}
edit_domains(){
  while true; do clear_screen; header "Domain Bypass Proxy"; nl -ba "$DOMAINS"; echo; echo "1) Add domain  2) Delete line  0) Back"; read -r -p "Pilih: " c
    case "$c" in 1) read -r -p "Domain/rule (contoh domain:netflix.com): " d; [[ -n "$d" ]] && echo "$d" >> "$DOMAINS"; reload_all;; 2) read -r -p "Nombor baris: " n; [[ "$n" =~ ^[0-9]+$ ]] && sed -i "${n}d" "$DOMAINS"; reload_all;;0)return;;esac
  done
}
show_proxy_config(){ echo "Status: $(json_get '.proxy.enabled') | Mode: $(json_get '.proxy.mode') | Rotate: $(json_get '.proxy.rotate')"; list_proxies; }
proxy_menu(){
  while true; do clear_screen; header "SOCKS5 / HTTP Outbound"; two_col "1) Enable/disable sistem" "6) Delete proxy" "2) Mode full/domain" "7) Check proxy" "3) Rotate on/off" "8) Domain bypass list" "4) Add proxy" "9) Show config" "5) Enable proxy item" "0) Back"; read -r -p "Pilih: " c
    case "$c" in
      1) state_set '.proxy.enabled=(.proxy.enabled|not)'; reload_all;;
      2) local m; m=$(json_get '.proxy.mode'); [[ "$m" == full ]] && state_set '.proxy.mode="domain"' || state_set '.proxy.mode="full"'; reload_all;;
      3) state_set '.proxy.rotate=(.proxy.rotate|not)'; reload_all;;
      4)add_proxy;;5)toggle_proxy_item;;6)delete_proxy;;7)check_proxy;pause;;8)edit_domains;;9)show_proxy_config;pause;;0)return;;
    esac
  done
}

set_domain(){ local d; read -r -p "Domain: " d; valid_domain "$d" || { echo "Domain tidak sah."; return; }; state_set --arg d "$d" '.domain=$d'; write_nginx; systemctl reload nginx; }
set_dns(){
  echo "1) Cloudflare  2) Google  3) Quad9  4) Custom"; read -r -p "Pilih: " c
  case "$c" in
    1) state_set '.dns={preset:"cloudflare",servers:["1.1.1.1","1.0.0.1"]}';;
    2) state_set '.dns={preset:"google",servers:["8.8.8.8","8.8.4.4"]}';;
    3) state_set '.dns={preset:"quad9",servers:["9.9.9.9","149.112.112.112"]}';;
    4) local a b; read -r -p "DNS 1: " a; read -r -p "DNS 2: " b; state_set --arg a "$a" --arg b "$b" '.dns={preset:"custom",servers:[$a,$b]}';;
  esac
  reload_all
}
toggle_ipv6(){
  local current; current=$(json_get '.ipv6')
  if [[ "$current" == true ]]; then
    cat > /etc/sysctl.d/99-${APP}-ipv6.conf <<EOF
net.ipv6.conf.all.disable_ipv6=1
net.ipv6.conf.default.disable_ipv6=1
EOF
    state_set '.ipv6=false'
  else
    cat > /etc/sysctl.d/99-${APP}-ipv6.conf <<EOF
net.ipv6.conf.all.disable_ipv6=0
net.ipv6.conf.default.disable_ipv6=0
EOF
    state_set '.ipv6=true'
  fi
  sysctl --system >/dev/null
}
set_autoreboot(){
  local enabled time h m
  enabled=$(json_get '.autoreboot.enabled')
  if [[ "$enabled" == true ]]; then rm -f /etc/cron.d/${APP}-reboot; state_set '.autoreboot.enabled=false'; else
    read -r -p "Masa HH:MM [04:30]: " time; time=${time:-04:30}; [[ "$time" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || return
    h=${time%:*}; m=${time#*:}; echo "$m $h * * * root /sbin/reboot" > /etc/cron.d/${APP}-reboot
    state_set --arg t "$time" '.autoreboot={enabled:true,time:$t}'
  fi
}
choose_xray_channel(){ echo "1) Stable release  2) Latest termasuk pre-release"; read -r -p "Pilih: " c; [[ "$c" == 2 ]] && state_set '.xrayChannel="latest"' || state_set '.xrayChannel="stable"'; install_xray; reload_all; }
system_menu(){
  while true; do clear_screen; header "System"; two_col "1) Set domain" "6) Restart all service" "2) Issue/Renew SSL ACME" "7) Enable/disable IPv6" "3) Set DNS" "8) Pilih/update Xray Core" "4) Set autoreboot" "9) Show logs" "5) Test config" "0) Back"; read -r -p "Pilih: " c
    case "$c" in 1)set_domain;pause;;2)issue_ssl;pause;;3)set_dns;;4)set_autoreboot;;5)"$XRAY_BIN" run -test -c "$XRAY_CONFIG" && nginx -t;pause;;6)reload_all;;7)toggle_ipv6;;8)choose_xray_channel;pause;;9)journalctl -u xray -u nginx -n 80 --no-pager;pause;;0)return;;esac
  done
}

install_all(){
  need_root
  source /etc/os-release
  if [[ "${ID:-}" != ubuntu && "${ID:-}" != debian ]]; then echo "Hanya Ubuntu/Debian disokong."; return 1; fi
  if [[ "${ID:-}" == ubuntu && "${VERSION_ID:-}" != 24.04 ]]; then echo "Amaran: diuji untuk Ubuntu 24.04."; fi
  init_state
  install_packages
  install_xray
  write_systemd
  cp -f "$0" "$MENU_BIN"; chmod 755 "$MENU_BIN"
  build_config
  write_nginx
  systemctl enable --now nginx xray
  echo "Pemasangan selesai. Jalankan: vpn"
}
uninstall_all(){
  read -r -p "Taip REMOVE untuk uninstall: " x; [[ "$x" == REMOVE ]] || return
  systemctl disable --now xray 2>/dev/null || true
  rm -f "$XRAY_SERVICE" "$XRAY_BIN" "$XRAY_CONFIG" "$NGINX_LINK" "$NGINX_SITE" "$MENU_BIN" /etc/cron.d/${APP}-reboot
  systemctl daemon-reload; systemctl reload nginx 2>/dev/null || true
  read -r -p "Padam data user/config juga? [y/N]: " y; [[ "$y" =~ ^[Yy]$ ]] && rm -rf "$BASE" "$WEBROOT"
  echo "Uninstall selesai."
}

header(){
  local title="${1:-ZYANV VPN MANAGER}" xray nginx proxy ip domain count dns pxy ver
  xray=$(service_state xray); nginx=$(service_state nginx); proxy=$(json_get '.proxy.enabled'); ip=$(public_ip); domain=$(json_get '.domain'); count=$(jq '[.[]|select(.expiry>now)]|length' "$USERS" 2>/dev/null||echo 0); dns=$(json_get '.dns.preset'); ver=$(cat "$BASE/xray-version" 2>/dev/null||echo -)
  [[ "$proxy" == true ]] && pxy=$(status_badge active) || pxy=$(status_badge inactive)
  printf "%b╭──────────────────────────────────────────────────────────────╮%b\n" "$C_BLUE" "$C_RESET"
  printf "%b│%b %-60s %b│%b\n" "$C_BLUE" "$C_BOLD" "$title" "$C_BLUE" "$C_RESET"
  printf "%b├──────────────────────────────────────────────────────────────┤%b\n" "$C_BLUE" "$C_RESET"
  printf "%b│%b Xray %-9b Nginx %-9b Proxy %-9b Users %-5s %b│%b\n" "$C_BLUE" "$C_RESET" "$(status_badge "$xray")" "$(status_badge "$nginx")" "$pxy" "$count" "$C_BLUE" "$C_RESET"
  printf "%b│%b IP: %-19s Domain: %-25s %b│%b\n" "$C_BLUE" "$C_RESET" "${ip:--}" "${domain:--}" "$C_BLUE" "$C_RESET"
  printf "%b│%b DNS: %-16s Xray: %-26s %b│%b\n" "$C_BLUE" "$C_RESET" "${dns:--}" "${ver:--}" "$C_BLUE" "$C_RESET"
  printf "%b╰──────────────────────────────────────────────────────────────╯%b\n\n" "$C_BLUE" "$C_RESET"
}
two_col(){ while (($#)); do printf "  %-30s %-30s\n" "${1:-}" "${2:-}"; shift 2 || true; done; }
main_menu(){
  init_state
  while true; do clear_screen; header; two_col "1) Install script" "4) SOCKS5 / HTTP" "2) Uninstall script" "5) System" "3) VLESS menu" "0) Back / Exit"; read -r -p "Pilih: " c
    case "$c" in 1)install_all;pause;;2)uninstall_all;pause;;3)vless_root_menu;;4)proxy_menu;;5)system_menu;;0)exit 0;;esac
  done
}
vless_root_menu(){ while true; do clear_screen; header "VLESS"; two_col "1) WebSocket" "3) XHTTP" "2) HTTP Upgrade" "0) Back"; read -r -p "Pilih: " c; case "$c" in 1)vless_menu ws;;2)vless_menu httpupgrade;;3)vless_menu xhttp;;0)return;;esac; done; }

need_root
case "${1:-menu}" in install) init_state; install_all;; uninstall) init_state; uninstall_all;; menu|"") main_menu;; *) echo "Usage: $0 [install|uninstall|menu]"; exit 1;; esac
