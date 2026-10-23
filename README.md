# nm-openvpn-import-fix

Набор скриптов для корректного импорта OpenVPN-профиля в NetworkManager:
обход ошибки inline-`<auth-user-pass>`, настройка MTU/MSS и split-DNS,
диагностика и откат. Без секретов: ни профилей, ни ключей, ни паролей в репозитории нет.

Проверено на Fedora 44: NetworkManager 1.56.1, NetworkManager-openvpn 1.12.5,
systemd-resolved, niri/waybar (без GNOME/KDE).

---

## Какие проблемы решает

### 1. Импорт падает на inline-кредах

`nmcli connection import type openvpn file profile.ovpn` завершается ошибкой:

```
ошибка конфигурации: неподдерживаемый элемент blob/xml (строка N)
```

Причина — inline-блок в `.ovpn`:

```
<auth-user-pass>
login
password
</auth-user-pass>
```

NetworkManager-openvpn **не поддерживает inline `<auth-user-pass>`**
(inline `<ca>/<cert>/<key>` — поддерживает и сам извлекает их в PEM-файлы).
Исправление: заменить блок на bare-директиву `auth-user-pass`, логин задать
свойством профиля, пароль — интерактивно или через «Save password».

### 2. TCP-соединение устанавливается, но данные не идут

Симптом: `ping` проходит, TCP-хендшейк проходит, а HTTP-ответ не приходит
(таймаут). Причина — MTU:

- OpenVPN по умолчанию получает `tun-mtu 1500`;
- реальный path MTU внутри туннеля может быть меньше (например, **1419**);
- пакеты `1500 + ~72 байта overhead` молча отбрасываются, PMTU discovery
  на клиенте часто выключен (`net.ipv4.tcp_mtu_probing = 0`).

Исправление: `tunnel-mtu` ≤ path MTU и `mssfix` ≤ `path_mtu - 40`
(для 1419 это `mssfix 1360`).

### 3. VPN «ломает» публичные сайты и Bitrix24

OpenVPN-сервер может пушить:

```
dhcp-option DOMAIN ~.
```

`~.` — routing-домен, который отправляет **все** DNS-запросы на корпоративный
DNS. Если тот не умеет резолвить публичные имена (или отдаёт split-horizon
ответы), внешние сервисы «пропадают».

Пример split-horizon: `b24.apo-avrora.ru` публично резолвится в один адрес,
а из корпоративного DNS — во внутренний `10.0.0.x`. Нужно, чтобы в
корпоративный DNS уходили только корпоративные домены, а остальное —
в DNS основного линка.

Исправление:

```bash
ipv4.ignore-auto-dns yes                 # игнорировать push от сервера
ipv4.dns 172.15.0.1,172.17.231.7         # какие DNS использовать
ipv4.dns-search ais.local,apo-avrora.ru  # только эти домены -> корпоративный DNS
ipv4.dns-priority 200                    # split: VPN-DNS не главный для прочих имён
```

> `dns-priority`: меньшее число = выше приоритет. Отрицательное значение
> исключает DNS остальных профилей (режим full-tunnel, защита от утечек).

---

## Требования

- NetworkManager + `NetworkManager-openvpn`
  (Fedora: `sudo dnf install NetworkManager-openvpn NetworkManager-openvpn-gnome`;
  Debian/Ubuntu: `sudo apt install network-manager-openvpn network-manager-openvpn-gnome`);
- `systemd-resolved` (для split-DNS) либо другой менеджер DNS;
- polkit разрешает активному пользователю править системные профили
  (`org.freedesktop.NetworkManager.settings.modify.system = yes` — на Fedora так по умолчанию);
- сам `.ovpn`-файл и учётные данные — **у вас**, в репозиторий не кладутся.

---

## Быстрый старт

```bash
git clone <URL> nm-openvpn-import-fix
cd nm-openvpn-import-fix

# split-tunnel (рекомендуется): интернет не через VPN, только корпоративные подсети
./import-openvpn.sh ~/profile.ovpn --username <login>

# подключение (пароль спросит интерактивно)
nmcli --ask connection up <id>

# проверка
./verify-vpn.sh <id> 172.17.231.49:8080
```

`<id>` печатается в конце импорта; по умолчанию это имя файла без `.ovpn`.

Полный туннель:

```bash
./import-openvpn.sh ~/profile.ovpn --username <login> -n office --full-tunnel --autoconnect
```

---

## Опции `import-openvpn.sh`

| Опция | По умолчанию | Что делает |
|---|---|---|
| `-n, --name` | имя файла | id профиля в NM |
| `-u, --username` | — | `vpn.data username=<login>` |
| `--full-tunnel` | split | `ipv4.never-default no` + `ipv4.routes 0.0.0.0/0` |
| `--autoconnect` | выкл. | `connection.autoconnect yes` |
| `--mtu` | `1400` | `vpn.data tunnel-mtu` |
| `--mss` | `1360` | `vpn.data mssfix` (≤ `path_mtu - 40`) |
| `--dns` | `172.15.0.1,172.17.231.7` | `ipv4.dns` |
| `--dns-search` | `ais.local,apo-avrora.ru` | routing-домены |
| `--dns-priority` | `200` split / `-50` full | `ipv4.dns-priority` |
| `--routes` | корпоративные подсети | `ipv4.routes` (только split) |
| `--metric` | `200` | `ipv4.route-metric` |

Переменные окружения: `VPN_MTU`, `VPN_MSS`, `VPN_DNS`, `VPN_DNS_SEARCH`,
`VPN_ROUTES`, `VPN_METRIC`.

Маршруты по умолчанию (split):

```
10.0.0.0/16, 10.20.0.0/16, 10.22.0.0/16, 172.17.0.0/16,
192.168.18.0/24, 192.168.20.0/24
```

---

## Что делает импорт по шагам

1. Проверяет `nmcli` и наличие VPN-плагина.
2. Копирует `.ovpn` во временный каталог (`umask 077`, удаляется по выходу).
3. Вырезает inline `<auth-user-pass>` и вставляет bare `auth-user-pass`.
4. Импортирует профиль:
   `nmcli connection import type openvpn file <tmp>`.
   - keyfile → `/etc/NetworkManager/system-connections/<имя>.nmconnection` (root:root 600);
   - сертификаты → `~/.local/share/networkmanagement/certificates/nm-openvpn/<имя>-{ca,cert,key}.pem` (600).
5. Находит UUID нового профиля (сравнение списков до/после, независимо от локали).
6. Применяет MTU/MSS, split-DNS, маршруты, metric, autoconnect.
7. Печатает итоговый профиль и подсказки.

Ручной эквивалент (если хочется без скрипта):

```bash
# 1. убрать inline-блок <auth-user-pass> из копии .ovpn, оставить "auth-user-pass"
# 2. импорт
nmcli connection import type openvpn file profile-fixed.ovpn
# 3. настройка (для словаря vpn.data обязателен префикс "+",
#    иначе каждое присваивание заменит весь словарь)
nmcli connection modify profile-fixed \
  connection.autoconnect no \
  +vpn.data 'username=<login>' \
  +vpn.data 'tunnel-mtu=1400' \
  +vpn.data 'mssfix=1360' \
  ipv4.never-default yes \
  ipv4.dns '172.15.0.1,172.17.231.7' \
  ipv4.dns-search 'ais.local,apo-avrora.ru' \
  ipv4.ignore-auto-dns yes \
  ipv4.dns-priority 200 \
  ipv4.route-metric 200 \
  ipv4.routes '10.0.0.0/16,10.20.0.0/16,10.22.0.0/16,172.17.0.0/16,192.168.18.0/24,192.168.20.0/24'
```

---

## Использование из GUI

Единственный полноценный редактор в минимальных окружениях (niri, sway, i3) —
`nm-connection-editor` (GTK, работает через XWayland):

```bash
nm-connection-editor
```

- `+` → **VPN** → **OpenVPN** → **Import a saved VPN configuration…** — импорт `.ovpn`
  (тот же inline-`auth-user-pass` вызовет ту же ошибку, поэтому сначала подготовьте файл);
- вкладка **VPN**:
  - *Gateway*, *Authentication type* (`Password with certificates` = `password-tls`),
  - *User name* → `vpn.data username`,
  - *Password* + галочка сохранения → `password-flags` (`0` хранить, `1` спрашивать),
  - *CA certificate / User certificate / Private key* + *Ask for password* → `cert-pass-flags`,
  - кнопка **Advanced…**: cipher, HMAC, `Use custom MTU`, `Use custom MSS` (`tunnel-mtu`, `mssfix`);
- вкладка **IPv4**:
  - *Additional DNS servers* → `ipv4.dns`,
  - *DNS search domains* → `ipv4.dns-search` (routing-домены),
  - *Routes* → *Use this connection only for resources on its network* = `ipv4.never-default yes`;
  - `ipv4.dns-priority` в GUI не выставляется — только через `nmcli`;
- вкладка **General**:
  - *Connect automatically* → `connection.autoconnect`,
  - *All users may connect to this network* → `connection.permissions` (если снять — профиль только для вас, секреты уйдут в keyring).

Подключение/отключение без GUI:

```bash
nmtui                                     # TUI
nmcli connection up <id>                  # спросит пароль
nmcli connection down <id>
```

Апплета в трее нет: при желании `sudo dnf install network-manager-applet`
и включить модуль `tray` в waybar.

---

## Проверка

```bash
./verify-vpn.sh <id> 172.17.231.49:8080
```

Проверяет: активность профиля, tun-интерфейс и его MTU, маршруты, DNS-серверы
и routing-домены (предупреждает про `~.`), path MTU (`ping -M do` для 1379 и 1400),
HTTP-код.

Ручные проверки:

```bash
ip -brief addr show tun0
ip route show dev tun0
resolvectl status tun0
resolvectl domain
ping -M do -c1 -s 1400 <host>     # должно падать при path MTU 1419
curl -m 10 -v http://<host>:8080/
```

---

## Откат

```bash
./rollback.sh <id>
```

Удаляет профиль NM и извлечённые сертификаты из
`~/.local/share/networkmanagement/certificates/nm-openvpn/`.
Файлы вне этих каталогов не трогает.

---

## Troubleshooting

| Симптом | Причина | Решение |
|---|---|---|
| `неподдерживаемый элемент blob/xml` | inline `<auth-user-pass>` | скрипт вырезает блок; вручную — заменить на `auth-user-pass` |
| Импорт прошёл, но логин не подхватился | креды из inline/файла не импортируются | `vpn.data username=<login>` |
| Пароль спрашивается каждый раз | `password-flags=1` | `vpn.data 'password-flags=0'` или галочка в GUI |
| TCP есть, HTTP висит | MTU/MSS | `tunnel-mtu 1400`, `mssfix 1360` (≤ `path_mtu - 40`) |
| Отвалились публичные сайты/Bitrix24 | routing-домен `~.` | `ipv4.ignore-auto-dns yes`, `ipv4.dns-search` только корпоративные домены |
| Корпоративные имена не резолвятся | DNS не переключился | `ipv4.dns`, `ipv4.dns-search`, `ipv4.dns-priority` |
| Два туннеля одновременно | параллельно openvpn3 и NM | использовать один стек; `openvpn3 sessions-list` / `nmcli connection show --active` |
| `Cannot open TUN/TAP dev` | нет прав/модуля | проверить `lsmod | grep tun`, права `nm-openvpn` |
| После настройки пропали `remote`/`ca`/`cert`/`key` | `vpn.data` задан без `+` — словарь перезаписан | настраивать через `+vpn.data key=value` или переимпортировать |

---

## Безопасность

- В репозиторий **не попадают** `.ovpn`, PEM-ключи, пароли (см. `.gitignore`).
- Inline-креды из исходного `.ovpn` скрипт **удаляет** и не сохраняет.
- Временная копия профиля живёт в `mktemp -d` с `umask 077` и удаляется по выходу,
  но содержит inline-ключ, если он был в исходнике.
- Пароль лучше хранить в менеджере секретов (Vault/Bitwarden) и вводить через
  `nmcli --ask`, а не в командной строке.
- Для системного профиля сохранённый пароль лежит в keyfile (root:root 600);
  для пользовательского (`connection.permissions user:<login>`) — в keyring.

---

## Состав репозитория

```
import-openvpn.sh        # подготовка .ovpn + импорт + настройка
verify-vpn.sh            # диагностика активного профиля
rollback.sh              # удаление профиля и сертификатов
examples/profile.template.ovpn  # шаблон без секретов
```

## Лицензия

MIT (см. LICENSE).
