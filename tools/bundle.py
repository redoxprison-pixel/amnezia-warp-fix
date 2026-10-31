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
if '--check' in sys.argv:
    if updated != text:
        sys.exit('Embedded controller is stale: run python3 tools/bundle.py')
else:
    path.write_text(updated)
