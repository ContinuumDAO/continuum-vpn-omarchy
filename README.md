# Continuum VPN for Omarchy

Bar card for [Omarchy](https://github.com/basecamp/omarchy). Import a profile bundle from the Continuum node VPN panel, then turn your own node or an egress exit on or off from the top bar. Turning one profile on turns the other WireGuard tunnels off.

The plugin does not call your node. It stores what you import.

## Install

```bash
omarchy plugin add https://github.com/ContinuumDAO/continuum-vpn-omarchy.git
omarchy plugin enable continuum.vpn
```

`plugin add` asks before it clones. Updates are `omarchy plugin update`.

## Use

1. In the node app VPN panel, choose Linux, then Omarchy, and download the bundle.
2. Click the card on the bar.
3. Import the `continuum-vpn-*.json` file, or paste it. A plain WireGuard `.conf` whose name is a valid interface name also imports.
4. Use the switch on a row. One profile is up at a time.

Shadowsocks and wg-obfuscator must already be on `PATH` (`sslocal`, `shadowsocks-rust.sslocal`, or `wg-obfuscator`). The plugin starts the matching program as your user, waits until it listens, then asks NetworkManager to bring the tunnel up. No sudo and no `wg-quick`.

udp2raw and LWO are refused. udp2raw is a root shell script; this plugin never executes a downloaded script. WireGuard `PreUp` / `PostUp` / `PreDown` / `PostDown` lines are refused for the same reason. NetworkManager does not run those hooks.

## Bundle

`bundle.schema.json` is the file the node app writes. `iface` is the kernel interface name, at most 15 characters. Own-node profiles use `cont-full` and `cont-split`. Each egress exit has its own name so a second download does not replace the first.

Profiles are stored under `~/.config/continuum-vpn/profiles/<iface>/` (mode 0700). The WireGuard private key is imported into NetworkManager. Transport files stay in that directory.

## Requirements

- NetworkManager, which Omarchy already runs. A logged-in session may control it without a password.
- `wireguard-tools`, for `wg pubkey` during import.
- `python3`, to read the bundle.
- `sslocal` or `wg-obfuscator` only when the profile uses that transport.

## Tests

```bash
bash tests/run.sh
```

The tests use a stand-in `nmcli` and do not change the machine's NetworkManager connections.
