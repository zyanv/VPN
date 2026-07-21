#!/usr/bin/env bash
# SOCKS5 Manager - one-file installer/menu for Ubuntu & Debian
# Use only on servers and networks you own or are authorised to administer.

set -Eeuo pipefail
IFS=$'\n\t'

APP_NAME="SOCKS5 Manager"
APP_DIR="/etc/socks5-manager"
ALLOW_FILE="$APP_DIR/allowed.list"
SETTINGS_FILE="$APP_DIR/settings.conf"
DANTE_CONF="/etc/danted.conf"
SERVICE="danted"
GROUP="socks5users"
DEFAULT_PORT="1080"

C_RESET='\033[0m'; C_RED='\033[1;31m'; C_GREEN='\033[1;32m'; C_YELLOW='\033[1;33m'; C_BLUE='\033[1;34m'; C_CYAN='\033[1;36m'; C_WHITE='\033[1;37m'

need_root() {
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    echo -e "${C_RED}Jalankan sebagai root: sudo bash $0${C_RESET}"
    exit 1
  fi
}

pause() { read -r -p "Tekan Enter untuk teruskan..." _ || true; }
clear_screen() { command -v clear >/dev/null && clear || printf '\033c'; }

header() {
  clear_screen
  local ip="-" port="-" status="OFF"
  ip=$(hostname -I 2>/dev/null | awk '{print $1}')
  [[ -f "$SETTINGS_FILE" ]] && source "$SETTINGS_FILE"
  port="${SOCKS_PORT:-$DEFAULT_PORT}"
  systemctl is-active --quiet "$SERVICE" 2>/dev/null && status="ON"
  echo -e "${C_CYAN}╔══════════════════════════════════════╗${C_RESET}"
  echo -e "${C_CYAN}║${C_WHITE}          SOCKS5 MANAGER             ${C_CYAN}║${C_RESET}"
  echo -e "${C_CYAN}╠══════════════════════════════════════╣${C_RESET}"
  printf "${C_CYAN}║${C_RESET} IP VPS : %-27s ${C_CYAN}║${C_RESET}\n" "${ip:--}"
  printf "${C_CYAN}║${C_RESET} Port   : %-27s ${C_CYAN}║${C_RESET}\n" "$port"
  if [[ "$status" == "ON" ]]; then
    printf "${C_CYAN}║${C_RESET} Status : ${C_GREEN}%-27s${C_RESET} ${C_CYAN}║${C_RESET}\n" "$status"
  else
    printf "${C_CYAN}║${C_RESET} Status : ${C_RED}%-27s${C_RESET} ${C_CYAN}║${C_RESET}\n" "$status"
  fi
  echo -e "${C_CYAN}╚══════════════════════════════════════╝${C_RESET}"
}

valid_port() { [[ "$1" =~ ^[0-9]+$ ]] && (( 1 <= 10#$1 && 10#$1 <= 65535 )); }
valid_user() { [[ "$1" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; }
valid_source() {
  local x="$1"
  [[ "$x" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?$ ]] || return 1
  local ip=${x%%/*} prefix=""
  [[ "$x" == */* ]] && prefix=${x##*/}
  IFS=. read -r a b c d <<< "$ip"
  for n in "$a" "$b" "$c" "$d"; do (( 0 <= 10#$n && 10#$n <= 255 )) || return 1; done
  [[ -z "$prefix" ]] || (( 0 <= 10#$prefix && 10#$prefix <= 32 ))
}
normalize_source() { [[ "$1" == */* ]] && printf '%s\n' "$1" || printf '%s/32\n' "$1"; }

install_packages() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y dante-server curl ca-certificates iproute2 passwd procps
  getent group "$GROUP" >/dev/null || groupadd --system "$GROUP"
  install -d -m 700 "$APP_DIR"
  touch "$ALLOW_FILE"
  chmod 600 "$ALLOW_FILE"
}

detect_interface() {
  ip -4 route list default 2>/dev/null | awk '{print $5; exit}'
}

load_settings() {
  SOCKS_PORT="$DEFAULT_PORT"
  EXTERNAL_IF="$(detect_interface)"
  [[ -f "$SETTINGS_FILE" ]] && source "$SETTINGS_FILE"
  EXTERNAL_IF="${EXTERNAL_IF:-$(detect_interface)}"
}

save_settings() {
  cat > "$SETTINGS_FILE" <<CFG
SOCKS_PORT="$SOCKS_PORT"
EXTERNAL_IF="$EXTERNAL_IF"
CFG
  chmod 600 "$SETTINGS_FILE"
}

render_config() {
  load_settings
  [[ -n "$EXTERNAL_IF" ]] || { echo -e "${C_RED}Interface internet tidak dijumpai.${C_RESET}"; return 1; }
  local tmp
  tmp=$(mktemp)
  cat > "$tmp" <<CFG
logoutput: syslog
internal: 0.0.0.0 port = $SOCKS_PORT
external: $EXTERNAL_IF

socksmethod: username
clientmethod: none

user.privileged: root
user.unprivileged: nobody

# Default: block clients not present in allowed.list
client block {
  from: 0.0.0.0/0 to: 0.0.0.0/0
  log: connect error
}
CFG

  local src
  while IFS= read -r src; do
    [[ -z "$src" || "$src" == \#* ]] && continue
    cat >> "$tmp" <<CFG

client pass {
  from: $src to: 0.0.0.0/0
  log: connect error
}

socks pass {
  from: $src to: 0.0.0.0/0
  command: connect bind udpassociate
  proxyprotocol: socks_v5
  socksmethod: username
  group: $GROUP
  log: connect error
}
CFG
  done < "$ALLOW_FILE"

  cat >> "$tmp" <<'CFG'

socks block {
  from: 0.0.0.0/0 to: 0.0.0.0/0
  log: connect error
}
CFG
  install -m 600 "$tmp" "$DANTE_CONF"
  rm -f "$tmp"

  if ! danted -V >/dev/null 2>&1; then true; fi
  systemctl enable "$SERVICE" >/dev/null 2>&1 || true
  if ! systemctl restart "$SERVICE"; then
    echo -e "${C_RED}Dante gagal dimulakan. Semak konfigurasi/log.${C_RESET}"
    journalctl -u "$SERVICE" -n 30 --no-pager || true
    return 1
  fi
}

initial_setup() {
  need_root
  echo -e "${C_CYAN}Memasang Dante SOCKS5...${C_RESET}"
  install_packages
  load_settings
  echo
  read -r -p "Port SOCKS5 [$DEFAULT_PORT]: " p
  p="${p:-$DEFAULT_PORT}"
  valid_port "$p" || { echo -e "${C_RED}Port tidak sah.${C_RESET}"; exit 1; }
  SOCKS_PORT="$p"
  EXTERNAL_IF="${EXTERNAL_IF:-$(detect_interface)}"
  save_settings

  local source_ip
  read -r -p "IP/CIDR server pertama yang dibenarkan (contoh 203.0.113.10): " source_ip
  if [[ -n "$source_ip" ]]; then
    valid_source "$source_ip" || { echo -e "${C_RED}IP/CIDR tidak sah.${C_RESET}"; exit 1; }
    normalize_source "$source_ip" > "$ALLOW_FILE"
  fi
  render_config
  install_menu_command
  echo -e "${C_GREEN}Pemasangan siap. Jalankan: socks5-menu${C_RESET}"
}

install_menu_command() {
  local target="/usr/local/sbin/socks5-menu"
  local source_path
  source_path=$(readlink -f "$0")
  if [[ "$source_path" != "$target" ]]; then
    install -m 700 "$source_path" "$target"
  else
    chmod 700 "$target"
  fi
}

list_users() {
  header
  echo -e "${C_YELLOW}SENARAI PENGGUNA${C_RESET}"
  local found=0
  while IFS=: read -r user _ uid gid _ _ shell; do
    id -nG "$user" 2>/dev/null | tr ' ' '\n' | grep -qx "$GROUP" || continue
    found=1
    local state="aktif"
    passwd -S "$user" 2>/dev/null | grep -q ' L ' && state="dikunci"
    printf " • %-20s [%s]\n" "$user" "$state"
  done < /etc/passwd
  (( found )) || echo "Tiada pengguna."
  echo
  pause
}

add_user_menu() {
  header
  read -r -p "Username baru: " user
  valid_user "$user" || { echo -e "${C_RED}Username tidak sah.${C_RESET}"; pause; return; }
  id "$user" >/dev/null 2>&1 && { echo -e "${C_RED}Pengguna sudah wujud.${C_RESET}"; pause; return; }
  useradd -M -s /usr/sbin/nologin -g "$GROUP" "$user"
  echo -e "${C_YELLOW}Masukkan password SOCKS5 untuk $user:${C_RESET}"
  if ! passwd "$user"; then userdel "$user" >/dev/null 2>&1 || true; pause; return; fi
  echo -e "${C_GREEN}Pengguna berjaya ditambah.${C_RESET}"
  pause
}

delete_user_menu() {
  header
  read -r -p "Username untuk dipadam: " user
  id "$user" >/dev/null 2>&1 || { echo -e "${C_RED}Pengguna tidak dijumpai.${C_RESET}"; pause; return; }
  id -nG "$user" | tr ' ' '\n' | grep -qx "$GROUP" || { echo -e "${C_RED}Bukan pengguna SOCKS5.${C_RESET}"; pause; return; }
  read -r -p "Taip YES untuk sahkan: " confirm
  [[ "$confirm" == "YES" ]] && userdel "$user" && echo -e "${C_GREEN}Pengguna dipadam.${C_RESET}" || echo "Dibatalkan."
  pause
}

edit_user_menu() {
  header
  read -r -p "Username asal: " old
  id "$old" >/dev/null 2>&1 || { echo -e "${C_RED}Pengguna tidak dijumpai.${C_RESET}"; pause; return; }
  echo "1) Tukar password"
  echo "2) Tukar username"
  echo "3) Kunci pengguna"
  echo "4) Buka kunci pengguna"
  read -r -p "Pilihan: " ch
  case "$ch" in
    1) passwd "$old" ;;
    2)
      read -r -p "Username baru: " new
      valid_user "$new" || { echo -e "${C_RED}Username tidak sah.${C_RESET}"; pause; return; }
      usermod -l "$new" "$old"
      echo -e "${C_GREEN}Username ditukar.${C_RESET}"
      ;;
    3) passwd -l "$old" >/dev/null; echo -e "${C_GREEN}Pengguna dikunci.${C_RESET}" ;;
    4) passwd -u "$old" >/dev/null; echo -e "${C_GREEN}Pengguna dibuka semula.${C_RESET}" ;;
    *) echo "Pilihan tidak sah." ;;
  esac
  pause
}

list_allowed() {
  header
  echo -e "${C_YELLOW}SERVER/IP YANG DIBENARKAN${C_RESET}"
  if [[ ! -s "$ALLOW_FILE" ]]; then echo "Tiada IP dibenarkan."; else nl -w2 -s'. ' "$ALLOW_FILE"; fi
  echo
  pause
}

add_allowed() {
  header
  read -r -p "IP atau CIDR untuk dibenarkan: " src
  valid_source "$src" || { echo -e "${C_RED}IP/CIDR tidak sah.${C_RESET}"; pause; return; }
  src=$(normalize_source "$src")
  grep -Fxq "$src" "$ALLOW_FILE" && { echo -e "${C_YELLOW}IP sudah ada.${C_RESET}"; pause; return; }
  echo "$src" >> "$ALLOW_FILE"
  sort -u -o "$ALLOW_FILE" "$ALLOW_FILE"
  render_config && echo -e "${C_GREEN}IP dibenarkan dan servis dimuat semula.${C_RESET}"
  pause
}

delete_allowed() {
  header
  nl -w2 -s'. ' "$ALLOW_FILE" || true
  read -r -p "Nombor baris untuk dipadam: " n
  [[ "$n" =~ ^[0-9]+$ ]] || { echo -e "${C_RED}Nombor tidak sah.${C_RESET}"; pause; return; }
  sed -i "${n}d" "$ALLOW_FILE"
  render_config && echo -e "${C_GREEN}Senarai dikemas kini.${C_RESET}"
  pause
}

edit_allowed() {
  header
  nl -w2 -s'. ' "$ALLOW_FILE" || true
  read -r -p "Nombor baris untuk diedit: " n
  [[ "$n" =~ ^[0-9]+$ ]] || { echo -e "${C_RED}Nombor tidak sah.${C_RESET}"; pause; return; }
  read -r -p "IP/CIDR baru: " src
  valid_source "$src" || { echo -e "${C_RED}IP/CIDR tidak sah.${C_RESET}"; pause; return; }
  src=$(normalize_source "$src")
  sed -i "${n}c\\$src" "$ALLOW_FILE"
  sort -u -o "$ALLOW_FILE" "$ALLOW_FILE"
  render_config && echo -e "${C_GREEN}IP dikemas kini.${C_RESET}"
  pause
}

change_port() {
  header
  load_settings
  read -r -p "Port baru: " p
  valid_port "$p" || { echo -e "${C_RED}Port tidak sah.${C_RESET}"; pause; return; }
  SOCKS_PORT="$p"
  save_settings
  render_config && echo -e "${C_GREEN}Port ditukar kepada $p.${C_RESET}"
  echo -e "${C_YELLOW}Pastikan port ini dibuka pada firewall/security group VPS.${C_RESET}"
  pause
}

show_status() {
  header
  systemctl status "$SERVICE" --no-pager -l || true
  echo
  ss -lntup | grep -E "(:$(source "$SETTINGS_FILE" 2>/dev/null; echo "${SOCKS_PORT:-$DEFAULT_PORT}")\\b)" || true
  echo
  pause
}

show_logs() {
  header
  journalctl -u "$SERVICE" -n 80 --no-pager || true
  echo
  pause
}

connection_info() {
  header
  load_settings
  local ip
  ip=$(hostname -I 2>/dev/null | awk '{print $1}')
  echo -e "${C_YELLOW}FORMAT SAMBUNGAN${C_RESET}"
  echo "SOCKS5 : $ip:$SOCKS_PORT"
  echo "Auth   : username + password"
  echo "DNS    : gunakan socks5h pada aplikasi klien jika mahu DNS melalui proxy"
  echo "UDP    : disokong jika aplikasi klien menggunakan SOCKS5 UDP ASSOCIATE"
  echo
  echo "Contoh curl:"
  echo "curl --proxy socks5h://USERNAME:PASSWORD@$ip:$SOCKS_PORT https://api.ipify.org"
  echo
  pause
}

uninstall_menu() {
  header
  read -r -p "Taip REMOVE untuk buang Dante dan konfigurasi: " c
  [[ "$c" == "REMOVE" ]] || { echo "Dibatalkan."; pause; return; }
  systemctl disable --now "$SERVICE" >/dev/null 2>&1 || true
  while IFS=: read -r user _; do
    id -nG "$user" 2>/dev/null | tr ' ' '\n' | grep -qx "$GROUP" && userdel "$user" >/dev/null 2>&1 || true
  done < /etc/passwd
  apt-get purge -y dante-server || true
  rm -rf "$APP_DIR" "$DANTE_CONF" /usr/local/sbin/socks5-menu
  echo -e "${C_GREEN}SOCKS5 Manager dibuang.${C_RESET}"
  exit 0
}

main_menu() {
  need_root
  [[ -f "$SETTINGS_FILE" ]] || initial_setup
  while true; do
    header
    echo -e "${C_WHITE} 1${C_RESET}) Tambah pengguna"
    echo -e "${C_WHITE} 2${C_RESET}) Edit pengguna"
    echo -e "${C_WHITE} 3${C_RESET}) Padam pengguna"
    echo -e "${C_WHITE} 4${C_RESET}) Senarai pengguna"
    echo -e "${C_WHITE} 5${C_RESET}) Tambah server/IP dibenarkan"
    echo -e "${C_WHITE} 6${C_RESET}) Edit server/IP dibenarkan"
    echo -e "${C_WHITE} 7${C_RESET}) Padam server/IP dibenarkan"
    echo -e "${C_WHITE} 8${C_RESET}) Senarai server/IP dibenarkan"
    echo -e "${C_WHITE} 9${C_RESET}) Tukar port SOCKS5"
    echo -e "${C_WHITE}10${C_RESET}) Status servis"
    echo -e "${C_WHITE}11${C_RESET}) Log servis"
    echo -e "${C_WHITE}12${C_RESET}) Info sambungan"
    echo -e "${C_WHITE}13${C_RESET}) Restart servis"
    echo -e "${C_WHITE}14${C_RESET}) Uninstall"
    echo -e "${C_WHITE} 0${C_RESET}) Keluar"
    echo
    read -r -p "Pilih menu: " choice
    case "$choice" in
      1) add_user_menu ;; 2) edit_user_menu ;; 3) delete_user_menu ;; 4) list_users ;;
      5) add_allowed ;; 6) edit_allowed ;; 7) delete_allowed ;; 8) list_allowed ;;
      9) change_port ;; 10) show_status ;; 11) show_logs ;; 12) connection_info ;;
      13) render_config && echo -e "${C_GREEN}Servis direstart.${C_RESET}"; pause ;;
      14) uninstall_menu ;; 0) exit 0 ;; *) echo "Pilihan tidak sah."; sleep 1 ;;
    esac
  done
}

case "${1:-}" in
  --install|install) initial_setup; main_menu ;;
  --menu|menu|"") main_menu ;;
  *) echo "Guna: sudo bash $0 --install"; exit 1 ;;
esac
