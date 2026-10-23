#!/usr/bin/env bash
# verify-vpn.sh — проверка активного VPN-профиля NetworkManager:
# устройство, MTU, маршруты, DNS-домены, path MTU и HTTP-доступность.
set -euo pipefail

usage() {
  cat <<'EOF'
Использование:
  verify-vpn.sh <id|uuid> [host[:port]]

Пример:
  ./verify-vpn.sh office 172.17.231.49:8080
EOF
}

TARGET="${1:-}"
HOST="${2:-}"
[[ -n "$TARGET" ]] || { usage; exit 1; }

command -v nmcli >/dev/null 2>&1 || { echo "nmcli не найден" >&2; exit 1; }

UUID="$(nmcli -g connection.uuid connection show "$TARGET" 2>/dev/null || true)"
[[ -n "$UUID" ]] || { echo "профиль не найден: $TARGET" >&2; exit 1; }
ID="$(nmcli -g connection.id connection show "$UUID")"

echo "== Профиль =="
printf '  %s (%s)\n' "$ID" "$UUID"

ACTIVE=0
if nmcli -t -f NAME connection show --active | grep -Fxq "$ID"; then
  ACTIVE=1
  echo "  состояние: АКТИВЕН"
else
  echo "  состояние: не активен (поднимите: nmcli --ask connection up \"$ID\")"
  echo "  ВНИМАНИЕ: проверки MTU/HTTP ниже пойдут по текущему маршруту, а не через VPN"
fi

ADDR="$(nmcli -g IP4.ADDRESS connection show "$UUID" 2>/dev/null | head -n1 | cut -d/ -f1 || true)"
DEV=""
if [[ -n "$ADDR" ]]; then
  DEV="$(ip -o -4 addr show | awk -v a="$ADDR" '$4 ~ ("^" a "/") {print $2; exit}')"
fi

if [[ -n "$DEV" ]]; then
  echo
  echo "== Интерфейс =="
  ip -brief link show "$DEV"
  echo "  MTU: $(cat "/sys/class/net/$DEV/mtu" 2>/dev/null || echo '?')"
  echo
  echo "== Маршруты через $DEV =="
  ip route show dev "$DEV" || true
  echo
  echo "== DNS =="
  resolvectl status "$DEV" 2>/dev/null | sed -n '/DNS Servers\|Current DNS\|DNS Domain\|Default Route/p' || true
  if resolvectl domain 2>/dev/null | grep -q '~\.'; then
    echo "  ВНИМАНИЕ: найден routing-домен '~.' — он перехватывает ВСЕ DNS-запросы"
    echo "            и ломает публичные имена. Уберите его:"
    echo "            nmcli connection modify \"$ID\" ipv4.dns-search 'ais.local,apo-avrora.ru'"
  fi
else
  echo
  echo "  (IP на tun-интерфейсе не найден — профиль, вероятно, не подключён)"
fi

if [[ -n "$HOST" ]]; then
  HOST_ONLY="${HOST%%:*}"
  PORT=""
  [[ "$HOST" == *:* ]] && PORT="${HOST##*:}"

  echo
  echo "== Path MTU до $HOST_ONLY =="
  for size in 1379 1400; do
    if ping -M do -c 1 -W 2 -s "$size" "$HOST_ONLY" >/dev/null 2>&1; then
      echo "  DF $size байт: OK"
    else
      echo "  DF $size байт: НЕ ПРОХОДИТ (фрагментация/потери)"
    fi
  done

  if [[ -n "$PORT" ]]; then
    URL="http://$HOST/"
  else
    URL="http://$HOST/"
  fi
  echo
  echo "== HTTP =="
  code="$(curl -m 8 -sS -o /dev/null -w '%{http_code}' "$URL" 2>/dev/null || true)"
  if [[ -n "$code" && "$code" != "000" ]]; then
    echo "  $URL -> HTTP $code"
  else
    echo "  $URL -> нет ответа (таймаут/отказ)"
  fi
fi
