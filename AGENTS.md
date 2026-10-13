# AGENTS.md

`setup.sh` configures a remote Debian 12/13 box that its owner never logs into again. Treat every change as running unattended as root on a machine nobody can easily reach. User docs: `README.md`.

## Layout

- `setup.sh`: everything. Order: parse config → install packages → validate config and environment → SSH lockout guard → state/keys → sysctl → WireGuard → nftables → SSH → unattended upgrades → client configs.
- `vpn.conf.example`: config template. `vpn.conf` and `.clients/` (generated configs with private keys) are gitignored.
- `tests/run.sh`: Docker end-to-end tests (`Dockerfile` has `server` and `client` targets). `echo_server.py` replies `<hostname> <source IP>` over TCP and UDP; `udp_probe.py` queries it.

## Invariants

1. Never regenerate existing keys or client IPs (`/etc/wireguard/offsite-vpn/`). Removed clients are archived, not deleted.
2. Idempotent: managed files go through `write_file`, which only writes on change and sets `WROTE`. Services reload only when `WROTE` is set. Output must be deterministic. Tests assert a second run changes nothing.
3. Validate before mutating. Only package installation may happen before validation.
4. No lockouts: the firewall always allows the SSH ports; password login is disabled only if `ssh_access_ok` passes; SSH config is checked on disk before reload; nft rules are checked with `nft -c`.
5. No IPv6 leaks: IPv6 forwarding from wg0 is allowed only with an IPv6 uplink.
6. `vpn.conf` is parsed, never sourced.

## Gotchas

- Never pipe into `write_file`: it runs in a subshell and `WROTE` is lost. Use `< <(render_x)` or a heredoc.
- `set -euo pipefail`: `cmd | grep -q` can fail via SIGPIPE; `cond && action` doesn't abort when `action` fails; `[[ ]] && x` as a function's last line returns 1. Use `if`.
- nft: use `icmpv6`, not `ipv6-icmp` (needs `/etc/protocols`).
- Install `wireguard-tools`, not `wireguard` (can pull in a kernel). List dependencies like `ca-certificates` explicitly.
- If new interfaces have IPv6 disabled (`IPV6_STACK=0`), wg0's server side must be IPv4-only or wg-quick fails.
- IPv6 forwarding needs `accept_ra=2` on the uplink, or SLAAC boxes lose their default route.

## Style

Comments explain why, never what. No section banners. Markdown: one line per paragraph or bullet, no hard wraps, keep it short.

## Testing

Run `tests/run.sh` (both Debian versions, about 6 min) and `shellcheck setup.sh tests/run.sh` after every change; both must be clean. Add a test for new behaviour, and make negative tests fail for the intended reason (check the logs). Not covered: real cloud firewalls, SLAAC, real unattended-upgrade reboots.
