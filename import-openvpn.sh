#!/usr/bin/env bash
# import-openvpn.sh — импорт .ovpn в NetworkManager с исправлением типовых проблем:
#   1) inline-блок <auth-user-pass> ломает импорт;
#   2) tunnel-mtu 1500 при path MTU меньше 1500 -> крупные пакеты теряются;
#   3) DNS-домен "~." перехватывает все запросы и ломает публичные имена.
set -euo pipefail

die()  { printf 'ОШИБКА: %s\n' "$*" >&2; exit 1; }
note() { printf '  %s\n' "$*"; }

usage() {
  cat <<'EOF'
Использование:
  import-openvpn.sh <profile.ovpn> [опции]

Опции:
  -n, --name NAME         имя профиля в NetworkManager (по умолчанию — имя файла)
  -u, --username USER     логин VPN (сохраняется в vpn.data username=)
      --full-tunnel       весь трафик через VPN (0.0.0.0/0); по умолчанию split-tunnel
      --autoconnect       включить автоподключение (по умолчанию выключено)
      --mtu N             tunnel-mtu, по умолчанию 1400
      --mss N             mssfix, по умолчанию 1360 (должен быть <= path_mtu - 40)
      --dns LIST          DNS-серверы через запятую (по умолчанию 172.15.0.1,172.17.231.7)
      --dns-search LIST   routing-домены через запятую (по умолчанию ais.local,apo-avrora.ru)
      --dns-priority N    приоритет DNS (по умолчанию 200 для split, -50 для full)
      --routes LIST       маршруты через запятую (по умолчанию корпоративные подсети)
      --metric N          ipv4.route-metric (по умолчанию 200)
  -h, --help              показать справку

Переменные окружения (перекрываются флагами):
  VPN_MTU, VPN_MSS, VPN_DNS, VPN_DNS_SEARCH, VPN_ROUTES, VPN_METRIC

Примеры:
  ./import-openvpn.sh ~/profile.ovpn --username ivanov
  ./import-openvpn.sh ~/profile.ovpn -n office --full-tunnel --autoconnect
  ./import-openvpn.sh ~/profile.ovpn --mtu 1380 --mss 1340
EOF
}

INPUT=""
NAME=""
USERNAME=""
FULL_TUNNEL=0
AUTOCONNECT="no"
MTU="${VPN_MTU:-1400}"
MSS="${VPN_MSS:-1360}"
DNS_LIST="${VPN_DNS:-172.15.0.1,172.17.231.7}"
DNS_SEARCH="${VPN_DNS_SEARCH:-ais.local,apo-avrora.ru}"
ROUTES="${VPN_ROUTES:-10.0.0.0/16,10.20.0.0/16,10.22.0.0/16,172.17.0.0/16,192.168.18.0/24,192.168.20.0/24}"
METRIC="${VPN_METRIC:-200}"
DNS_PRIORITY=""

while (( $# )); do
  case "$1" in
    -h|--help)        usage; exit 0 ;;
    -n|--name)        [[ $# -ge 2 ]] || die "нужно значение для $1"; NAME="$2"; shift 2 ;;
    -u|--username)    [[ $# -ge 2 ]] || die "нужно значение для $1"; USERNAME="$2"; shift 2 ;;
    --full-tunnel)    FULL_TUNNEL=1; shift ;;
    --autoconnect)    AUTOCONNECT="yes"; shift ;;
    --mtu)            [[ $# -ge 2 ]] || die "нужно значение для $1"; MTU="$2"; shift 2 ;;
    --mss)            [[ $# -ge 2 ]] || die "нужно значение для $1"; MSS="$2"; shift 2 ;;
    --dns)            [[ $# -ge 2 ]] || die "нужно значение для $1"; DNS_LIST="$2"; shift 2 ;;
    --dns-search)     [[ $# -ge 2 ]] || die "нужно значение для $1"; DNS_SEARCH="$2"; shift 2 ;;
    --dns-priority)   [[ $# -ge 2 ]] || die "нужно значение для $1"; DNS_PRIORITY="$2"; shift 2 ;;
    --routes)         [[ $# -ge 2 ]] || die "нужно значение для $1"; ROUTES="$2"; shift 2 ;;
    --metric)         [[ $# -ge 2 ]] || die "нужно значение для $1"; METRIC="$2"; shift 2 ;;
    -*)               die "неизвестная опция: $1 (см. --help)" ;;
    *)                [[ -z "$INPUT" ]] || die "лишний аргумент: $1"; INPUT="$1"; shift ;;
  esac
done

[[ -n "$INPUT" ]] || { usage; exit 1; }
[[ -r "$INPUT" ]] || die "файл не читается: $INPUT"

command -v nmcli >/dev/null 2>&1 || die "nmcli не найден (установите NetworkManager)"

if command -v rpm >/dev/null 2>&1; then
  rpm -q NetworkManager-openvpn >/dev/null 2>&1 \
    || die "не установлен NetworkManager-openvpn (sudo dnf install NetworkManager-openvpn)"
elif command -v dpkg >/dev/null 2>&1; then
  dpkg -s network-manager-openvpn >/dev/null 2>&1 \
    || die "не установлен network-manager-openvpn"
fi

if [[ -z "$DNS_PRIORITY" ]]; then
  if (( FULL_TUNNEL )); then DNS_PRIORITY="-50"; else DNS_PRIORITY="200"; fi
fi

umask 077
WORK="$(mktemp -d "${TMPDIR:-/tmp}/nm-openvpn-import.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# Имя временного файла определяет имена извлекаемых сертификатов
# (~/.local/share/networkmanagement/certificates/nm-openvpn/<имя>-{ca,cert,key}.pem),
# поэтому делаем его уникальным, чтобы импорт двух профилей не перезаписал ключи.
BASE="${NAME:-$(basename "$INPUT" .ovpn)}"
SAFE="$(printf '%s' "$BASE" | LC_ALL=C tr -c 'A-Za-z0-9._-' '_')"
RAND="$(od -An -N2 -tx1 /dev/urandom | tr -d ' \n')"
SRC="$WORK/${SAFE}-${RAND}.ovpn"
HAD_INLINE=0
if grep -qE '^[[:space:]]*<auth-user-pass>' "$INPUT"; then
  HAD_INLINE=1
fi

# Вырезаем inline-блок <auth-user-pass>...</auth-user-pass> и оставляем
# bare-директиву: NetworkManager сам запросит логин/пароль.
awk '
  /^[[:space:]]*<auth-user-pass>[[:space:]]*$/ { inblk=1; print "auth-user-pass"; next }
  /^[[:space:]]*<\/auth-user-pass>[[:space:]]*$/ { inblk=0; next }
  inblk { next }
  { print }
' "$INPUT" > "$SRC"

printf 'Подготовка профиля:\n'
if (( HAD_INLINE )); then
  note "inline <auth-user-pass> удалён (креды из файла НЕ импортируются)"
else
  note "inline <auth-user-pass> не найден"
fi

BEFORE="$(nmcli -t -f UUID connection show 2>/dev/null | sort || true)"
OUT="$(nmcli connection import type openvpn file "$SRC" 2>&1)" \
  || die "импорт не удался: $OUT"
AFTER="$(nmcli -t -f UUID connection show 2>/dev/null | sort || true)"
UUID="$(comm -13 <(printf '%s\n' "$BEFORE") <(printf '%s\n' "$AFTER") | sed '/^$/d' | head -n1)"
[[ -n "$UUID" ]] || die "не удалось определить UUID импортированного профиля"

ID="$(nmcli -g connection.id connection show "$UUID")"
if [[ -n "$NAME" && "$NAME" != "$ID" ]]; then
  nmcli connection modify "$UUID" connection.id "$NAME"
  ID="$NAME"
fi

# ВАЖНО: для словаря vpn.data используем префикс "+", иначе каждое присваивание
# заменяет весь словарь и импортированные ключи (remote, ca, cert, key, cipher...)
# будут потеряны.
MODIFY=(
  connection.autoconnect "$AUTOCONNECT"
  +vpn.data "tunnel-mtu=$MTU"
  +vpn.data "mssfix=$MSS"
  ipv4.dns "$DNS_LIST"
  ipv4.dns-search "$DNS_SEARCH"
  ipv4.ignore-auto-dns yes
  ipv4.dns-priority "$DNS_PRIORITY"
  ipv4.route-metric "$METRIC"
)
if (( FULL_TUNNEL )); then
  MODIFY+=( ipv4.never-default no ipv4.routes "0.0.0.0/0" )
else
  MODIFY+=( ipv4.never-default yes ipv4.routes "$ROUTES" )
fi
[[ -n "$USERNAME" ]] && MODIFY+=( +vpn.data "username=$USERNAME" )

nmcli connection modify "$UUID" "${MODIFY[@]}"

printf '\nГотово.\n'
printf '  профиль: %s\n  uuid:    %s\n  режим:   %s\n' \
  "$ID" "$UUID" "$( (( FULL_TUNNEL )) && echo 'full-tunnel' || echo 'split-tunnel' )"

nmcli -f \
connection.id,connection.autoconnect,ipv4.never-default,ipv4.dns,ipv4.dns-search,ipv4.dns-priority,ipv4.routes,vpn.data \
  connection show "$UUID"

cat <<EOF

Дальше:
  1) Подключиться (пароль спросит интерактивно):
       nmcli --ask connection up "$ID"
  2) Чтобы пароль сохранился, до подключения выполните:
       nmcli connection modify "$ID" vpn.data 'password-flags=0'
     Для системного профиля секрет хранится в keyfile (root:root 600).
  3) Проверка маршрутов/MTU/DNS:
       ./verify-vpn.sh "$ID" 172.17.231.49:8080
EOF

if [[ -z "$USERNAME" ]]; then
  printf '\nВНИМАНИЕ: логин не задан. Если сервер требует пароль, укажите его:\n'
  printf '  nmcli connection modify "%s" vpn.data "username=<login>"\n' "$ID"
fi
