#!/usr/bin/env python3
"""Validate a Continuum VPN bundle or a plain WireGuard config.

Writes a private profile directory. Does not start processes or call NetworkManager.
A downloaded shell script is rejected and never executed.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

IFACE_RE = re.compile(r"^[A-Za-z0-9_=+.\-]{1,15}$")
ALLOWED_INTERFACE = {
    "PrivateKey",
    "Address",
    "DNS",
    "ListenPort",
    "MTU",
    "FwMark",
    "Table",
}
ALLOWED_PEER = {
    "PublicKey",
    "PresharedKey",
    "AllowedIPs",
    "Endpoint",
    "PersistentKeepalive",
}
HOOKS = {"preup", "postup", "predown", "postdown"}
TRANSPORT_BINS = {
    "shadowsocks": {"sslocal", "shadowsocks-rust.sslocal"},
    "wg_obfuscator": {"wg-obfuscator"},
}
TRANSPORT_SUFFIX = {
    "shadowsocks": "-ss.json",
    "wg_obfuscator": "-wgo.conf",
}


class Reject(Exception):
    pass


def fail(message: str) -> None:
    raise Reject(message)


def detail_text(value) -> str:
    text = " ".join(str(value or "").split())
    return text[:180].rstrip()


def country_code(value) -> str:
    if value is None or str(value).strip() == "":
        return ""
    code = str(value).strip().upper()
    if not re.fullmatch(r"[A-Z]{2}", code):
        fail("countryCode must be an ISO 3166-1 alpha-2 code")
    return code


def parse_wg(text: str) -> dict:
    section = None
    interface: dict[str, str] = {}
    peers: list[dict[str, str]] = []
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or line.startswith(";"):
            continue
        if line.startswith("[") and line.endswith("]"):
            name = line[1:-1].strip().lower()
            if name == "interface":
                if interface:
                    fail("config has more than one [Interface]")
                section = "interface"
            elif name == "peer":
                peers.append({})
                section = "peer"
            else:
                fail(f"unknown section [{line[1:-1].strip()}]")
            continue
        if "=" not in line or section is None:
            fail(f"invalid line: {line}")
        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip()
        if key.lower() in HOOKS:
            fail("config contains shell hooks")
        if section == "interface":
            if key not in ALLOWED_INTERFACE:
                fail(f"unknown interface key {key}")
            if key in interface:
                fail(f"duplicate interface key {key}")
            interface[key] = value
        else:
            if key not in ALLOWED_PEER:
                fail(f"unknown peer key {key}")
            peer = peers[-1]
            if key in peer:
                fail(f"duplicate peer key {key}")
            peer[key] = value
    if "PrivateKey" not in interface:
        fail("interface is missing PrivateKey")
    if not peers or any("PublicKey" not in peer for peer in peers):
        fail("a peer PublicKey is required")
    check_private_key(interface["PrivateKey"])
    for peer in peers:
        check_public_key(peer["PublicKey"])
        if "PresharedKey" in peer:
            check_public_key(peer["PresharedKey"])
    return {"interface": interface, "peers": peers}


def check_private_key(key: str) -> None:
    try:
        subprocess.run(
            ["wg", "pubkey"],
            input=(key.strip() + "\n").encode(),
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            check=True,
        )
    except FileNotFoundError:
        fail("wireguard-tools (wg) is required to validate keys")
    except subprocess.CalledProcessError as exc:
        detail = exc.stderr.decode(errors="replace").strip()
        fail(detail or "private key was rejected by wg pubkey")


def check_public_key(key: str) -> None:
    try:
        raw = base64.b64decode(key.strip(), validate=True)
    except Exception:
        fail("peer key is not valid base64")
    if len(raw) != 32:
        fail("peer key is not a WireGuard key")


def looks_like_shell(text: str, filename: str) -> bool:
    stripped = text.lstrip()
    if stripped.startswith("#!"):
        return True
    if filename.endswith(".sh"):
        return True
    return False


def load_input(path: str | None) -> str:
    if path:
        with open(path, "r", encoding="utf-8") as handle:
            text = handle.read()
    else:
        text = sys.stdin.read()
    if not text.strip():
        fail("empty config")
    return text


def bundle_from_json(text: str) -> dict:
    try:
        data = json.loads(text)
    except json.JSONDecodeError as exc:
        fail(f"bundle is not valid JSON: {exc.msg}")
    if not isinstance(data, dict):
        fail("bundle must be a JSON object")
    obfuscation = str(data.get("obfuscation") or "none").strip().lower().replace("-", "_")
    if obfuscation in {"udp2raw", "lwo"}:
        fail(f"{obfuscation} is not started by this plugin")
    if obfuscation not in {"none", "shadowsocks", "wg_obfuscator"}:
        fail(f"unsupported obfuscation {obfuscation}")
    iface = str(data.get("iface") or "").strip()
    if not IFACE_RE.fullmatch(iface):
        fail("iface must be 1-15 characters from [A-Za-z0-9_=+.-]")
    label = str(data.get("label") or iface).replace("\n", " ").strip() or iface
    country = country_code(data.get("countryCode"))
    detail = detail_text(data.get("detail"))
    source = str(data.get("source") or "admin").strip()
    if source not in {"admin", "egress"}:
        fail("source must be admin or egress")
    wg_text = str(data.get("wireGuardConfig") or "")
    if not wg_text.strip():
        fail("bundle is missing wireGuardConfig")
    transport_text = str(data.get("transportConfig") or "")
    transport_name = str(data.get("transportFilename") or "")
    transport_bin = str(data.get("transportBinary") or "").strip()
    if looks_like_shell(transport_text, transport_name) or transport_bin == "udp2raw":
        fail("refusing to store a shell script")
    if obfuscation == "none":
        if transport_text.strip() or transport_bin:
            fail("plain profile includes a transport")
        transport_text = ""
        transport_bin = ""
        transport_name = ""
    else:
        if not transport_text.strip():
            fail("obfuscated profile is missing transportConfig")
        if "/" in transport_bin or transport_bin not in TRANSPORT_BINS[obfuscation]:
            fail(f"transport binary {transport_bin or '(missing)'} is not allowed")
        expected = iface + TRANSPORT_SUFFIX[obfuscation]
        transport_name = expected
    parse_wg(wg_text)
    return {
        "label": label,
        "countryCode": country,
        "detail": detail,
        "source": source,
        "obfuscation": obfuscation,
        "iface": iface,
        "wireGuardConfig": wg_text if wg_text.endswith("\n") else wg_text + "\n",
        "transportBinary": transport_bin,
        "transportFilename": transport_name,
        "transportConfig": (transport_text if transport_text.endswith("\n") else transport_text + "\n")
        if transport_text
        else "",
    }


def iface_from_endpoint(parsed: dict) -> tuple[str, str]:
    endpoint = ""
    for peer in parsed["peers"]:
        if peer.get("Endpoint"):
            endpoint = str(peer["Endpoint"])
    host = endpoint.rsplit(":", 1)[0].strip().strip("[]")
    label = host or "WireGuard"
    cleaned = re.sub(r"[^A-Za-z0-9_=+.\-]", "", host)
    if IFACE_RE.fullmatch(cleaned) and cleaned[:1].isalnum():
        return cleaned, label
    digest = hashlib.sha256((host or endpoint or "wireguard").encode()).hexdigest()[:12]
    return f"wg-{digest}", label


def bundle_from_conf(text: str, filename: str) -> dict:
    if looks_like_shell(text, filename):
        fail("refusing to import a shell script")
    parsed = parse_wg(text)
    stem = os.path.splitext(os.path.basename(filename))[0]
    label = stem
    if stem in {"", "pasted"} or not IFACE_RE.fullmatch(stem):
        stem, label = iface_from_endpoint(parsed)
    if not IFACE_RE.fullmatch(stem):
        fail("config filename must be an interface name of 1-15 characters from [A-Za-z0-9_=+.-]")
    body = text if text.endswith("\n") else text + "\n"
    return {
        "label": label,
        "countryCode": "",
        "detail": "",
        "source": "admin",
        "obfuscation": "none",
        "iface": stem,
        "wireGuardConfig": body,
        "transportBinary": "",
        "transportFilename": "",
        "transportConfig": "",
    }


def write_profile(profile: dict, dest_root: str) -> str:
    iface = profile["iface"]
    final = os.path.join(dest_root, iface)
    parent = os.path.dirname(final)
    os.makedirs(parent, mode=0o700, exist_ok=True)
    os.chmod(parent, 0o700)
    tmp = tempfile.mkdtemp(prefix=f".{iface}.", dir=parent)
    os.chmod(tmp, 0o700)
    try:
        wg_path = os.path.join(tmp, "wg.conf")
        with open(wg_path, "w", encoding="utf-8") as handle:
            handle.write(profile["wireGuardConfig"])
        os.chmod(wg_path, 0o600)
        if profile["transportConfig"]:
            transport_path = os.path.join(tmp, profile["transportFilename"])
            with open(transport_path, "w", encoding="utf-8") as handle:
                handle.write(profile["transportConfig"])
            os.chmod(transport_path, 0o600)
        meta = {
            "label": profile["label"],
            "countryCode": profile.get("countryCode") or "",
            "detail": profile.get("detail") or "",
            "source": profile["source"],
            "obfuscation": profile["obfuscation"],
            "iface": iface,
            "transportBinary": profile["transportBinary"],
            "transportFilename": profile["transportFilename"],
            "nmUuid": "",
        }
        meta_path = os.path.join(tmp, "meta.json")
        with open(meta_path, "w", encoding="utf-8") as handle:
            json.dump(meta, handle, indent=2)
            handle.write("\n")
        os.chmod(meta_path, 0o600)
        if os.path.isdir(final):
            shutil.rmtree(final)
        os.rename(tmp, final)
    except Exception:
        shutil.rmtree(tmp, ignore_errors=True)
        raise
    return final


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", help="bundle JSON or WireGuard conf; default stdin")
    parser.add_argument("--filename", default="", help="original filename for a stdin conf")
    parser.add_argument("--dest", required=True, help="profiles directory")
    args = parser.parse_args()
    try:
        text = load_input(args.input)
        filename = args.filename or (os.path.basename(args.input) if args.input else "")
        if text.lstrip().startswith("{"):
            profile = bundle_from_json(text)
        else:
            profile = bundle_from_conf(text, filename)
        write_profile(profile, args.dest)
    except Reject as exc:
        print(str(exc), file=sys.stderr)
        return 1
    print(profile["iface"])
    return 0


if __name__ == "__main__":
    sys.exit(main())
