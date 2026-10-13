# offsite-vpn

One idempotent script that turns a Debian 12/13 box into a set-and-forget WireGuard VPN: clients, port forwarding, default-deny firewall, key-only SSH, and unattended upgrades with automatic reboots.

## Usage

On the server, as root or a sudo user who can already SSH in with a key:

```sh
git clone <this repo> offsite-vpn && cd offsite-vpn
cp vpn.conf.example vpn.conf && $EDITOR vpn.conf
sudo ./setup.sh
```

Copy `.clients/` off the box (`scp -r user@server:offsite-vpn/.clients .`) and import `<name>.conf` into WireGuard, or scan `<name>.png` on a phone. These files contain private keys.

Also allow `udp/<listen_port>` and forwarded ports in your cloud provider's firewall.

## Config (`vpn.conf`)

| Directive | Default | |
|---|---|---|
| `listen_port <port>` | `51820` | WireGuard UDP port |
| `endpoint <host>[:port]` | detected public IPv4 | Address clients connect to; add `:port` if NAT maps a different public port to `listen_port` |
| `subnet <a.b.c.0/24>` | `10.66.66.0/24` | IPv4 tunnel subnet |
| `subnet6 <prefix::/64>` | `fd66:66:66::/64` | IPv6 tunnel subnet |
| `dns <ip>...` | Cloudflare (`1.1.1.1`, `1.0.0.1`, `2606:4700:4700::1111`, `2606:4700:4700::1001`) | DNS for clients |
| `client_to_client yes\|no` | `no` | Let clients reach each other |
| `reboot_time <HH:MM>` | `04:00` | When to reboot after upgrades |
| `ssh_key <pubkey>` | | Authorize an SSH key (repeatable) |
| `client <name>` | | A client; all its traffic goes through the VPN (repeatable) |
| `forward <tcp\|udp> <port> <client> <client_port>` | | Port forward, keeps the caller's source IP (repeatable) |

Don't change the subnets once clients exist.

## Re-running

Edit `vpn.conf` and re-run `sudo ./setup.sh`; only differences are applied.

- Existing clients keep their keys and IPs (state lives in `/etc/wireguard/offsite-vpn/`).
- Removing a `client` line revokes it; keys are archived in `/etc/wireguard/offsite-vpn/revoked/`. Move the directory back to `clients/<name>` there to restore it.
- Changing `endpoint`, `listen_port` or `dns` changes the client configs; re-import them.

## IPv6

Clients get private IPv6 addresses NAT'd to the server's IPv6 address, so a single address from the provider is enough. Without IPv6 on the server, clients' IPv6 traffic is dropped rather than leaked. The server must have IPv4.

## Safety

- The script refuses to disable password login unless sshd would accept a valid key for some account (it checks `AuthorizedKeysFile`, Match/Allow/Deny rules and file permissions). New SSH settings are verified before sshd is reloaded.
- Config errors and tunnel subnets overlapping existing routes are rejected before anything changes.
- The script owns the whole nftables ruleset (original saved as `/etc/nftables.conf.orig`), so don't run Docker or other firewall managers on the box.

## Tests

`tests/run.sh [12 13]` runs end-to-end tests in Docker (Linux host with the wireguard module). `KEEP=1` keeps the containers.
