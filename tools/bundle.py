"""Refresh/check the self-contained Python controller embedded in govpn.sh."""
from pathlib import Path
import sys

root = Path(__file__).resolve().parents[1]
path = root / 'govpn.sh'
begin = '# BEGIN GENERATED SAFE WARP\n'
end = '# END GENERATED SAFE WARP\n'
source = (root / 'lib/awg_warp.py').read_text()
block = begin + '_awg_safe() {\n    python3 - "$AWG_CONTAINER" "$@" <<\'GOVPN_SAFE_PY\'\n' + source + '\nGOVPN_SAFE_PY\n}\n' + end
text = path.read_text()
if begin in text:
    before, rest = text.split(begin, 1)
    _, after = rest.split(end, 1)
    updated = before + block + after
else:
    updated = text.replace('_awg_conf() {', block + '\n_awg_conf() {', 1)
client_begin = '# BEGIN GENERATED AWG CLIENTS\n'
client_end = '# END GENERATED AWG CLIENTS\n'
client_source = (root / 'lib/awg_clients.py').read_text()
client_block = (client_begin + '_awg_clients_data() {\n    python3 - "$AWG_CONTAINER" "$@" <<\'GOVPN_CLIENTS_PY\'\n'
                + client_source + '\nGOVPN_CLIENTS_PY\n}\n' + client_end)
if client_begin in updated:
    before, rest = updated.split(client_begin, 1)
    _, after = rest.split(client_end, 1)
    updated = before + client_block + after
else:
    updated = updated.replace('_awg_conf() {', client_block + '\n_awg_conf() {', 1)
diag_begin = '# BEGIN GENERATED DIAGNOSTICS\n'
diag_end = '# END GENERATED DIAGNOSTICS\n'
diag_source = (root / 'lib/diagnostics.py').read_text()
diag_block = (diag_begin + '_connection_report() {\n    python3 - "$MODE" "$AWG_CONTAINER" <<\'GOVPN_DIAGNOSTICS_PY\'\n'
              + diag_source + '\nGOVPN_DIAGNOSTICS_PY\n}\n' + diag_end)
if diag_begin in updated:
    before, rest = updated.split(diag_begin, 1)
    _, after = rest.split(diag_end, 1)
    updated = before + diag_block + after
else:
    updated = updated.replace('tools_menu() {', diag_block + '\ntools_menu() {', 1)
access_begin = '# BEGIN GENERATED ACCESS TOOLS\n'
access_end = '# END GENERATED ACCESS TOOLS\n'
access_source = (root / 'lib/access_tools.py').read_text()
access_block = (access_begin + '_access_tools() {\n    python3 - "$@" <<\'GOVPN_ACCESS_PY\'\n'
                + access_source + '\nGOVPN_ACCESS_PY\n}\n' + access_end)
if access_begin in updated:
    before, rest = updated.split(access_begin, 1)
    _, after = rest.split(access_end, 1)
    updated = before + access_block + after
else:
    updated = updated.replace('_country_direct_menu() {', access_block + '\n_country_direct_menu() {', 1)
if '--check' in sys.argv:
    if updated != text:
        sys.exit('Embedded controller is stale: run python3 tools/bundle.py')
else:
    path.write_text(updated)
