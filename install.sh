#!/bin/bash
# Review installer. Main is intentionally unchanged until the Draft PR is merged.
set -euo pipefail
umask 077
(( BASH_VERSINFO[0] >= 4 )) || { echo 'Требуется Linux с Bash 4+.' >&2; exit 1; }
[ "$EUID" -eq 0 ] || { echo 'Запустите через sudo bash.' >&2; exit 1; }
for tool in curl python3 flock; do command -v "$tool" >/dev/null || { echo "Требуется ${tool}." >&2; exit 1; }; done
install_path=${GOVPN_INSTALL_PATH:-/usr/local/bin/govpn}
conf_dir=${GOVPN_CONF_DIR:-/etc/govpn}
case "$install_path" in /*) ;; *) exit 1 ;; esac
[ ! -L "$install_path" ] && [ ! -L "$conf_dir" ] || { echo 'Символические ссылки не поддерживаются.' >&2; exit 1; }
mkdir -p "$conf_dir" "${conf_dir}/backups" "$(dirname "$install_path")"
exec 9>"${conf_dir}/update.lock"
flock -n 9 || { echo 'Другая установка или обновление уже выполняется.' >&2; exit 1; }
work=$(mktemp -d)
stage=''
trap 'rm -rf -- "$work"; [ -z "$stage" ] || rm -f -- "$stage"' EXIT
curl -fsSL --proto '=https' --proto-redir '=https' --connect-timeout 10 --max-time 60 --max-filesize 4194304 \
  'https://raw.githubusercontent.com/redoxprison-pixel/amnezia-warp-fix/refs/heads/fix/awg-warp-safe-persistence/govpn.sh' \
  -o "$work/govpn.sh"
bash -n "$work/govpn.sh"
python3 - "$work/govpn.sh" <<'INSTALL_VALIDATE'
import ast
from pathlib import Path
import re
import sys
text = Path(sys.argv[1]).read_text()
if not text.startswith('#!/bin/bash\n') or len(re.findall(r'^VERSION="\d+\.\d+(?:\.\d+)?"$', text, re.M)) != 1:
    sys.exit('Неверный формат скрипта.')
for marker, name, delimiter in (('SAFE WARP', '_awg_safe', 'GOVPN_SAFE_PY'),
                                 ('AWG CLIENTS', '_awg_clients_data', 'GOVPN_CLIENTS_PY')):
    begin, end = '# BEGIN GENERATED ' + marker + '\n', '# END GENERATED ' + marker + '\n'
    if text.count(begin) != 1 or text.count(end) != 1:
        sys.exit('Встроенный backend отсутствует.')
    block = text.split(begin, 1)[1].split(end, 1)[0]
    prefix = name + '() {\n    python3 - "$AWG_CONTAINER" "$@" <<\'' + delimiter + '\'\n'
    suffix = '\n' + delimiter + '\n}\n'
    if not block.startswith(prefix) or not block.endswith(suffix):
        sys.exit('Неверный формат backend.')
    ast.parse(block[len(prefix):-len(suffix)])
INSTALL_VALIDATE
if [ -e "$install_path" ]; then
    backup=$(mktemp -d "${conf_dir}/backups/govpn-install.XXXXXX")
    cp -p -- "$install_path" "$backup/govpn.sh"
    chmod 600 "$backup/govpn.sh"
    echo "Предыдущий скрипт: ${backup}/govpn.sh"
fi
stage=$(mktemp "${install_path}.update.XXXXXX")
cp -- "$work/govpn.sh" "$stage"
chmod 755 "$stage"
mv -f -- "$stage" "$install_path"
stage=''
echo "Установлено в ${install_path}. Источник: review-ветка, не main."
if [ "${1:-}" != --no-run ]; then
    # Release the update lock before the interactive manager can update itself.
    flock -u 9
    bash "$install_path"
fi
