#!/usr/bin/env bash
# Continuum VPN bar backend. NetworkManager owns the tunnel. Transport proxies
# are allowlisted binaries started as the current user. Downloaded shell is never run.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${CONTINUUM_VPN_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/continuum-vpn}"
RUNTIME="${CONTINUUM_VPN_RUNTIME_DIR:-${XDG_RUNTIME_DIR:-/tmp}/continuum-vpn-$UID}"
PROFILES="$CONFIG/profiles"
VALIDATE=(python3 "$ROOT/validate_bundle.py")

die() {
  printf '%s\n' "$*" >&2
  exit 1
}

ensure_dirs() {
  mkdir -p "$PROFILES" "$RUNTIME"
  chmod 700 "$CONFIG" "$PROFILES" "$RUNTIME" 2>/dev/null || true
}

meta_get() {
  python3 - "$1" "$2" <<'PY'
import json, sys
path, key = sys.argv[1], sys.argv[2]
with open(path, encoding="utf-8") as handle:
    data = json.load(handle)
value = data.get(key, "")
if value is None:
    value = ""
print(value)
PY
}

meta_set() {
  python3 - "$1" "$2" "$3" <<'PY'
import json, sys
path, key, value = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path, encoding="utf-8") as handle:
    data = json.load(handle)
data[key] = value
with open(path, "w", encoding="utf-8") as handle:
    json.dump(data, handle, indent=2)
    handle.write("\n")
PY
}

nm_uuid_active() {
  local uuid="$1"
  [[ -n "$uuid" ]] || return 1
  nmcli -g GENERAL.STATE connection show "$uuid" 2>/dev/null | grep -q '^activated'
}

active_wg_uuids() {
  local line uuid typ
  nmcli -t -f UUID,TYPE connection show --active 2>/dev/null | while IFS=: read -r uuid typ; do
    [[ "$typ" == "wireguard" ]] || continue
    printf '%s\n' "$uuid"
  done
}

delete_iface_connections() {
  local iface="$1" uuid typ ifn name
  while IFS=: read -r uuid typ; do
    [[ "$typ" == "wireguard" && -n "$uuid" ]] || continue
    ifn="$(nmcli -g connection.interface-name connection show "$uuid" 2>/dev/null || true)"
    name="$(nmcli -g connection.id connection show "$uuid" 2>/dev/null || true)"
    if [[ "$ifn" == "$iface" || "$name" == "$iface" ]]; then
      nmcli connection delete "$uuid" >/dev/null 2>&1 || true
    fi
  done < <(nmcli -t -f UUID,TYPE connection show 2>/dev/null || true)
}

import_staged() {
  local staged_iface="$1"
  local dir="$PROFILES/$staged_iface"
  local meta="$dir/meta.json"
  local label iface uuid old stage
  [[ -f "$meta" ]] || die "profile was not written"
  iface="$(meta_get "$meta" iface)"
  label="$(meta_get "$meta" label)"
  [[ "$iface" == "$staged_iface" ]] || die "profile iface mismatch"
  old="$(meta_get "$meta" nmUuid)"
  if [[ -n "$old" ]]; then
    nmcli connection delete "$old" >/dev/null 2>&1 || true
  fi
  delete_iface_connections "$iface"
  stage="$(mktemp -d "$RUNTIME/import.XXXXXX")"
  chmod 700 "$stage"
  cp "$dir/wg.conf" "$stage/$iface.conf"
  chmod 600 "$stage/$iface.conf"
  nmcli connection import type wireguard file "$stage/$iface.conf" >/dev/null
  rm -rf "$stage"
  uuid="$(nmcli -g connection.uuid connection show "$iface")"
  [[ -n "$uuid" ]] || die "NetworkManager did not return a connection uuid"
  nmcli connection modify "$uuid" connection.id "$label" connection.interface-name "$iface" connection.autoconnect no
  meta_set "$meta" nmUuid "$uuid"
  printf '%s\n' "$label"
}

cmd_import_file() {
  local path="$1"
  [[ -f "$path" ]] || die "file not found"
  ensure_dirs
  local iface
  iface="$("${VALIDATE[@]}" --input "$path" --dest "$PROFILES")"
  import_staged "$iface"
}

cmd_import_text() {
  local filename="${1:-pasted.conf}"
  ensure_dirs
  local tmp iface
  tmp="$(mktemp "$RUNTIME/paste.XXXXXX")"
  chmod 600 "$tmp"
  cat >"$tmp"
  iface="$("${VALIDATE[@]}" --input "$tmp" --filename "$filename" --dest "$PROFILES")" || {
    rm -f "$tmp"
    exit 1
  }
  rm -f "$tmp"
  import_staged "$iface"
}

cmd_import_pick() {
  local path=""
  if command -v zenity >/dev/null 2>&1; then
    path="$(zenity --file-selection --title='Import Continuum VPN bundle' 2>/dev/null || true)"
  elif command -v kdialog >/dev/null 2>&1; then
    path="$(kdialog --getopenfilename . 2>/dev/null || true)"
  elif command -v yad >/dev/null 2>&1; then
    path="$(yad --file --title='Import Continuum VPN bundle' 2>/dev/null || true)"
  else
    die "No file picker found — install zenity, kdialog, or yad"
  fi
  [[ -n "$path" ]] || exit 0
  cmd_import_file "$path"
}

cmd_import_paste() {
  command -v wl-paste >/dev/null 2>&1 || die "wl-clipboard is not installed"
  wl-paste --no-newline | cmd_import_text "pasted.conf"
}

listen_port() {
  local dir="$1"
  python3 - "$dir" <<'PY'
import json, os, re, sys
directory = sys.argv[1]
wg = open(os.path.join(directory, "wg.conf"), encoding="utf-8").read()
match = re.search(r"(?im)^\s*Endpoint\s*=\s*(127\.0\.0\.1|localhost):(\d+)\s*$", wg)
if match:
    print(match.group(2))
    raise SystemExit(0)
meta = json.load(open(os.path.join(directory, "meta.json"), encoding="utf-8"))
name = meta.get("transportFilename") or ""
path = os.path.join(directory, name) if name else ""
if path and os.path.isfile(path):
    text = open(path, encoding="utf-8").read()
    try:
        data = json.loads(text)
    except json.JSONDecodeError:
        data = {}
    port = data.get("local_port") or data.get("listen_port")
    if port:
        print(int(port))
        raise SystemExit(0)
print("")
PY
}

stop_proxy() {
  local iface="$1"
  local pidfile="$RUNTIME/$iface.pid"
  [[ -f "$pidfile" ]] || return 0
  local pid
  pid="$(cat "$pidfile" 2>/dev/null || true)"
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    local i
    for i in 1 2 3 4 5 6 7 8 9 10; do
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.1
    done
    kill -9 "$pid" 2>/dev/null || true
  fi
  rm -f "$pidfile"
}

start_proxy() {
  local iface="$1" binary="$2" transport="$3" port="$4"
  local log="$RUNTIME/$iface.log"
  local pidfile="$RUNTIME/$iface.pid"
  command -v "$binary" >/dev/null 2>&1 || die "$binary is not on PATH"
  case "$binary" in
    sslocal|shadowsocks-rust.sslocal)
      setsid "$binary" -c "$transport" >>"$log" 2>&1 </dev/null &
      ;;
    wg-obfuscator)
      setsid "$binary" --config "$transport" >>"$log" 2>&1 </dev/null &
      ;;
    *)
      die "refusing to run $binary"
      ;;
  esac
  echo $! >"$pidfile"
  local i
  for i in $(seq 1 50); do
    if ss -ltnH "sport = :$port" 2>/dev/null | grep -q .; then
      return 0
    fi
    if ! kill -0 "$(cat "$pidfile")" 2>/dev/null; then
      die "$binary exited before it listened on port $port"
    fi
    sleep 0.1
  done
  stop_proxy "$iface"
  die "$binary did not listen on port $port"
}

cmd_up() {
  local iface="$1"
  local dir="$PROFILES/$iface"
  local meta="$dir/meta.json"
  [[ -f "$meta" ]] || die "unknown profile $iface"
  ensure_dirs
  local uuid obfuscation binary transport_name port
  uuid="$(meta_get "$meta" nmUuid)"
  [[ -n "$uuid" ]] || die "profile $iface has no NetworkManager connection"
  obfuscation="$(meta_get "$meta" obfuscation)"
  if [[ "$obfuscation" == "udp2raw" || "$obfuscation" == "lwo" ]]; then
    die "$obfuscation is not started by this plugin"
  fi
  if [[ "$obfuscation" != "none" ]]; then
    binary="$(meta_get "$meta" transportBinary)"
    transport_name="$(meta_get "$meta" transportFilename)"
    port="$(listen_port "$dir")"
    [[ -n "$port" ]] || die "could not find the local transport port"
    [[ -f "$dir/$transport_name" ]] || die "missing transport file"
    stop_proxy "$iface"
    start_proxy "$iface" "$binary" "$dir/$transport_name" "$port"
  fi
  if ! nmcli connection up "$uuid" >/dev/null; then
    stop_proxy "$iface"
    die "NetworkManager did not activate $iface"
  fi
  local other other_dir other_iface
  while IFS= read -r other; do
    [[ -n "$other" && "$other" != "$uuid" ]] || continue
    nmcli connection down "$other" >/dev/null 2>&1 || true
  done < <(active_wg_uuids)
  for other_dir in "$PROFILES"/*; do
    [[ -f "$other_dir/meta.json" ]] || continue
    other_iface="$(basename "$other_dir")"
    [[ "$other_iface" == "$iface" ]] && continue
    stop_proxy "$other_iface"
  done
  printf '%s\n' "$(meta_get "$meta" label)"
}

cmd_down() {
  local iface="$1"
  local dir="$PROFILES/$iface"
  local meta="$dir/meta.json"
  [[ -f "$meta" ]] || die "unknown profile $iface"
  local uuid
  uuid="$(meta_get "$meta" nmUuid)"
  if [[ -n "$uuid" ]]; then
    nmcli connection down "$uuid" >/dev/null 2>&1 || true
  fi
  stop_proxy "$iface"
  printf '%s\n' "$(meta_get "$meta" label)"
}

cmd_list() {
  ensure_dirs
  python3 - "$PROFILES" <<'PY'
import json, os, subprocess, sys
root = sys.argv[1]
rows = []
if os.path.isdir(root):
    names = sorted(os.listdir(root))
else:
    names = []
for name in names:
    meta_path = os.path.join(root, name, "meta.json")
    if not os.path.isfile(meta_path):
        continue
    with open(meta_path, encoding="utf-8") as handle:
        meta = json.load(handle)
    uuid = str(meta.get("nmUuid") or "")
    active = False
    if uuid:
        state = subprocess.run(
            ["nmcli", "-g", "GENERAL.STATE", "connection", "show", uuid],
            capture_output=True, text=True,
        )
        active = state.returncode == 0 and state.stdout.startswith("activated")
    code = str(meta.get("countryCode") or "").strip().upper()
    if len(code) != 2 or not code.isalpha():
        code = ""
    flag = ""
    if code:
        flag = chr(0x1F1E6 + ord(code[0]) - ord("A")) + chr(0x1F1E6 + ord(code[1]) - ord("A"))
    rows.append({
        "iface": meta.get("iface") or name,
        "label": meta.get("label") or name,
        "countryCode": code,
        "countryFlag": flag,
        "detail": str(meta.get("detail") or "").strip(),
        "obfuscation": meta.get("obfuscation") or "none",
        "active": active,
        "uuid": uuid,
    })
print(json.dumps(rows))
PY
}

usage() {
  die "usage: backend.sh list|up IFACE|down IFACE|import-file PATH|import-text [NAME]|import-pick|import-paste"
}

main() {
  local cmd="${1:-}"
  case "$cmd" in
    list) cmd_list ;;
    up) [[ $# -eq 2 ]] || usage; cmd_up "$2" ;;
    down) [[ $# -eq 2 ]] || usage; cmd_down "$2" ;;
    import-file) [[ $# -eq 2 ]] || usage; cmd_import_file "$2" ;;
    import-text) cmd_import_text "${2:-pasted.conf}" ;;
    import-pick) cmd_import_pick ;;
    import-paste) cmd_import_paste ;;
    *) usage ;;
  esac
}

main "$@"
