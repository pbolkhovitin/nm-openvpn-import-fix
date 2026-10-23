#!/usr/bin/env bash
# rollback.sh — удаление VPN-профиля NetworkManager и извлечённых им сертификатов.
set -euo pipefail

usage() {
  cat <<'EOF'
Использование:
  rollback.sh <id|uuid>
EOF
}

TARGET="${1:-}"
[[ -n "$TARGET" ]] || { usage; exit 1; }

command -v nmcli >/dev/null 2>&1 || { echo "nmcli не найден" >&2; exit 1; }

UUID="$(nmcli -g connection.uuid connection show "$TARGET" 2>/dev/null || true)"
[[ -n "$UUID" ]] || { echo "профиль не найден: $TARGET" >&2; exit 1; }
ID="$(nmcli -g connection.id connection show "$UUID")"

DATA="$(nmcli -g vpn.data connection show "$UUID" 2>/dev/null || true)"
PATHS="$(printf '%s\n' "$DATA" | tr ',' '\n' | sed -n -E 's/^ *(ca|cert|key) = (.+)$/\2/p')"

echo "Удаление профиля: $ID ($UUID)"
nmcli connection delete "$UUID"

if [[ -n "$PATHS" ]]; then
  while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    case "$p" in
      "$HOME"/.local/share/networkmanagement/certificates/*|/etc/NetworkManager/certs/*)
        rm -f -- "$p" && echo "  удалён: $p" ;;
      *)
        echo "  пропущен (вне известных каталогов): $p" ;;
    esac
  done <<< "$PATHS"
fi

echo "Готово."
