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
4. Each saved VPN is a row: country flag, country, obfuscation, ad blocking, rate limit, and endpoint. Green ON and red OFF are separate. The badge at the top right switches the selected VPN. One profile is up at a time. Import does not connect. The dustbin asks before it deletes a row.

For a Shadowsocks profile, install `shadowsocks-rust` from the official Extra repository. That package provides `sslocal`. The plugin starts it as your user, waits until it listens, then asks NetworkManager to bring the tunnel up. No sudo and no `wg-quick`.

`wg-obfuscator` is not in the official Arch repositories, so it is not a requirement of this plugin.

udp2raw and LWO are refused. udp2raw is a root shell script; this plugin never executes a downloaded script. WireGuard `PreUp` / `PostUp` / `PreDown` / `PostDown` lines are refused for the same reason. NetworkManager does not run those hooks.

## Bundle

`bundle.schema.json` is the file the node app writes. `iface` is the kernel interface name, at most 15 characters. Own-node profiles use `cont-full` and `cont-split`. Each egress exit has its own name so a second download does not replace the first.

Profiles are stored under `~/.config/continuum-vpn/profiles/<iface>/` (mode 0700). The WireGuard private key is imported into NetworkManager. Transport files stay in that directory.

## Requirements

These are official Arch packages. Omarchy already includes the first three.

```bash
sudo pacman -S --needed networkmanager wireguard-tools python iproute2 zenity wl-clipboard
sudo pacman -S --needed shadowsocks-rust
```

| Package | Repository | What it provides |
| --- | --- | --- |
| `networkmanager` | extra | `nmcli`. A logged-in session may control it without a password. |
| `wireguard-tools` | extra | `wg`, used to check keys before import. |
| `python` | extra | `python3`, used to read the bundle. |
| `iproute2` | core | `ss`, used to see that a local proxy is listening. It is part of `base`. |
| `zenity` | extra | File picker for import. |
| `wl-clipboard` | extra | `wl-paste`, for import from the clipboard. |
| `shadowsocks-rust` | extra | `sslocal`. Install this only for a Shadowsocks profile. |

`wg-obfuscator` has no official Arch package. This plugin does not ask you to install it.

## Tests

```bash
bash tests/run.sh
```

The tests use a stand-in `nmcli` and do not change the machine's NetworkManager connections.
