"""Generate a static UX catalog, excluding Bash heredoc data from shell symbols."""
import ast
import json
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
TEXT = (ROOT / 'govpn.sh').read_text()
GROUPS = {
    '_3xui_load_config': ('3X-UI: клиенты и API', '1 / Клиенты 3X-UI'),
    '_awg_conf': ('Amnezia и WARP', '1 / Клиенты; 2 / WARP'),
    '_awg_read_phase': ('Подключение WARP', '2'),
    '_service_restart_menu': ('Перезапуск сервисов', '4 / 6'),
    'warp_test': ('Диагностика WARP', '2 / проверка подключения'),
    'awg_clients_menu': ('Маршруты клиентов', '1 / r'),
    'save_iptables': ('Сеть и каскады', '5 / 2'),
    'tools_menu': ('Диагностика', '3'),
    '_run_ipregion': ('Legacy диагностика', 'скрыт из обычного меню'),
    '_hy2_list_users': ('Hysteria legacy', 'скрыт; кандидат на отдельный модуль'),
    '_install_docker': ('Установка компонентов', '5 / 4'),
    '_3xui_backup_geofiles': ('3X-UI: дополнительные настройки', '5 / 6-8'),
    '_install_3xui': ('Установка компонентов', '5 / 4'),
    '_domain_detect_short': ('Веб-сервер, домены и SSL', '5 / 3'),
    'system_menu': ('Обслуживание', '4'),
    'do_backup': ('Резервные копии', '4 / 1'),
    '_update_cached_ver': ('Обновление и установка', '4 / 2; install.sh'),
    '_awg_emergency_restore': ('Клиенты, профили и маршруты', '1'),
    '_ssh_access_plan': ('Резервный SSH', '4 / 3'),
    '_clients_hub': ('Навигация клиентов', '1'),
    '_menu_begin': ('Общая навигация', 'основные экраны'),
    '_network_tools_menu': ('Навигация дополнительных функций', '5'),
    'awg_peers_menu': ('Клиенты, профили и маршруты', '1'),
    '_mtg_list_instances': ('Telegram-прокси', '5 / 1'),
    'show_menu': ('Навигация и запуск', 'главное меню'),
}
entries = []
category, destination = 'Служебные функции', 'внутренние helpers'
pending = []
generated = False
for number, line in enumerate(TEXT.splitlines(), 1):
    if line.startswith('# BEGIN GENERATED '):
        generated = True
    if generated:
        adapter = re.match(r'^(_awg_safe|_awg_clients_data|_connection_report)\(\)', line)
        if adapter:
            entries.append({'file': 'govpn.sh', 'line': number, 'function': adapter[1],
                            'category': 'Адаптеры backend', 'destination': '3 / Диагностика' if adapter[1] == '_connection_report' else '2 / WARP; 1 / Клиенты', 'kind': 'shell'})
        if line.startswith('# END GENERATED '):
            generated = False
        continue
    if pending:
        if line.lstrip('\t') == pending[0]:
            pending.pop(0)
        continue
    match = re.match(r'^([A-Za-z_]\w*)\(\)\s*[{(]', line)
    if match:
        name = match[1]
        if name in GROUPS:
            category, destination = GROUPS[name]
        item_category, item_destination = category, destination
        if name.startswith(('_mtg_', '_telemt_')) or name == 'mtproto_menu':
            item_category, item_destination = 'Telegram-прокси', '5 / 1'
        elif name.startswith(('_stub_', '_ssl_')):
            item_category, item_destination = 'Веб-сервер, домены и SSL', '5 / 3'
        elif name.startswith('_hy2_') or name == 'hysteria2_menu':
            item_category, item_destination = 'Hysteria legacy', 'скрыт; кандидат на отдельный модуль'
        entries.append({'file': 'govpn.sh', 'line': number, 'function': name,
                        'category': item_category, 'destination': item_destination, 'kind': 'shell'})
    pending.extend(m[2] for m in re.finditer(r'(?<!<)<<-?\s*([\'\"]?)([A-Za-z_]\w*)\1', line))


def python_functions(nodes, file, scope=''):
    for node in nodes:
        if isinstance(node, ast.ClassDef):
            python_functions(node.body, file, scope + node.name + '.')
        elif isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            entries.append({'file': file, 'line': node.lineno, 'function': scope + node.name,
                            'category': 'Диагностика' if 'diagnostics' in file else ('Backend WARP' if 'warp' in file else 'Backend клиентов/профилей'),
                            'destination': '3 / Диагностика' if 'diagnostics' in file else '2 / WARP; 1 / Клиенты', 'kind': 'python'})
            python_functions(node.body, file, scope + node.name + '.')
        else:
            python_functions(list(ast.iter_child_nodes(node)), file, scope)


for file in ('lib/awg_warp.py', 'lib/awg_clients.py', 'lib/diagnostics.py'):
    python_functions(ast.parse((ROOT / file).read_text()).body, file)
data = {'version': re.search(r'^VERSION="([^"]+)"', TEXT, re.M)[1],
        'scope': 'Product shell functions and Python backends; tests and generators are not product features.',
        'method': 'Static definitions, heredoc-aware shell scan and Python AST. Category is an ownership/UX map, not a dynamic test guarantee.',
        'functions': entries}
rendered = json.dumps(data, ensure_ascii=False, indent=2) + '\n'
path = ROOT / 'docs/function-catalog.json'
if '--check' in sys.argv:
    if not path.exists() or path.read_text() != rendered:
        sys.exit('Function catalog is stale: run python3 tools/catalog_functions.py')
else:
    path.write_text(rendered)
print(f'Catalog: {len(entries)} functions')
