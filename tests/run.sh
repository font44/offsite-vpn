#!/usr/bin/env bash
# End-to-end tests for setup.sh. Docker containers stand in for the VPN server
# (systemd Debian), two VPN clients and an "internet" host, on a private dual-stack Docker network.
#
# Usage: tests/run.sh [debian_version ...]   (default: 12 13)
# Env:   KEEP=1  leave the containers running afterwards for debugging.
#
# Needs a Linux host with Docker and the wireguard kernel module. Containers run
# --privileged, but firewall/sysctl/routing changes stay inside their own
# network namespaces.
# shellcheck disable=SC2016  # single-quoted commands are expanded inside the containers
set -euo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
P=offsite-vpn-test
NETWORK=$P-net
LAN4=172.29.250        # container addresses: server .2, laptop .3, homeserver .4, outside .5
LAN6=fd00:29:250:      # same host numbers, e.g. fd00:29:250::2
SERVER4=$LAN4.2 SERVER6=${LAN6}:2 OUTSIDE4=$LAN4.5 OUTSIDE6=${LAN6}:5
# "Internet" addresses hosted by the outside container. Only reachable via
# explicit routes, so the tests show which path traffic took.
INET4=203.0.113.10 INET6=2001:db8::10
LOG_DIR=$(mktemp -d)
if (($#)); then VERSIONS=("$@"); else VERSIONS=(12 13); fi

PASS=0 FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }
expect()      { local d=$1; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi; }
expect_fail() { local d=$1; shift; if "$@" >/dev/null 2>&1; then bad "$d"; else ok "$d"; fi; }
expect_eq() {
  if [[ $2 == "$3" ]]; then ok "$1"
  elif [[ $2 == *$'\n'* ]]; then bad "$1:"; diff <(echo "$2") <(echo "$3") | sed 's/^/      /'
  else bad "$1 (expected '$2', got '$3')"; fi
}

on() { local c=$1; shift; docker exec "$P-$c" "$@"; }
on_i() { local c=$1; shift; docker exec -i "$P-$c" "$@"; }

cleanup() {
  docker ps -aq --filter "name=^$P-" | xargs -r docker rm -f >/dev/null
  docker network rm "$NETWORK" >/dev/null 2>&1 || true
}
on_exit() {
  if [[ ${KEEP:-0} == 1 ]]; then echo "KEEP=1: containers left running (docker ps --filter name=$P-)"; else cleanup; fi
  echo "Logs: $LOG_DIR"
}
trap on_exit EXIT

wait_for_systemd() {
  local i state
  for ((i = 0; i < 60; i++)); do
    state=$(on server systemctl is-system-running 2>/dev/null || true)
    [[ $state == running || $state == degraded ]] && return 0
    sleep 1
  done
  echo "systemd did not finish booting (state: $state)" >&2
  return 1
}

run_setup() {
  local log="$LOG_DIR/$1.log"; shift
  on server bash -c "cd /opt/offsite-vpn && ./setup.sh $*" >"$log" 2>&1
}

# Contents, modes and owners of everything setup.sh manages, including key state.
snapshot() {
  on server sh -c 'find /etc/wireguard /opt/offsite-vpn/.clients /etc/nftables.conf /etc/sysctl.d \
      /etc/ssh/sshd_config.d /etc/apt/apt.conf.d /etc/needrestart/conf.d /root/.ssh \
      \( -type d -exec stat -c "%a %U %n" {} + \) -o \( -type f -exec stat -c "%a %U %Y %n" {} + \) | sort
    find /etc/wireguard /opt/offsite-vpn/.clients /etc/nftables.conf /etc/sysctl.d \
      /etc/ssh/sshd_config.d /etc/apt/apt.conf.d /etc/needrestart/conf.d /root/.ssh \
      -type f -exec md5sum {} + | sort -k2'
}

ssh_opts=(-o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5)
ssh_login() { on outside ssh "${ssh_opts[@]}" "root@$1" true; }
password_login_refused() {
  on outside sh -c "ssh ${ssh_opts[*]} -o PubkeyAuthentication=no root@$1 true 2>&1 | grep -q 'Permission denied (publickey)'"
}
udp_seen_by_outside() { on outside python3 /udp_probe.py "$1" "$2" "$3" 2>/dev/null || echo "<no response>"; }

peers_in_sync() {
  on server sh -c '[ "$(wg show wg0 peers | sort)" = "$(sed -n "s/^PublicKey = //p" /etc/wireguard/wg0.conf | sort)" ]'
}

# Prints "<echo server hostname> <source address it saw>".
seen_by() { local c=$1 url=$2; shift 2; on "$c" curl -gfsS -m 5 "$@" "$url" 2>/dev/null || echo "<no response>"; }

client_ip4() { on server sed -n 's|^Address = \([0-9.]*\)/32.*|\1|p' "/opt/offsite-vpn/.clients/$1.conf"; }

# The DNS line is dropped because the containers have no resolvconf.
tunnel_up() {
  on server cat "/opt/offsite-vpn/.clients/$1.conf" | sed '/^DNS/d' |
    on_i "$1" sh -c 'umask 077; mkdir -p /etc/wireguard; cat >/etc/wireguard/wg0.conf'
  on "$1" wg-quick up wg0 >"$LOG_DIR/wg-up-$1.log" 2>&1
}

start_echo() { docker cp "$REPO/tests/echo_server.py" "$P-$1:/echo_server.py" && docker exec -d "$P-$1" python3 /echo_server.py "$2"; }

routes_to_inet() {
  on "$1" ip -4 route replace "$INET4/32" via "$OUTSIDE4"
  on "$1" ip -6 route replace "$INET6/128" via "$OUTSIDE6"
}

retry_eq() {
  local d=$1 want=$2 got i; shift 2
  for ((i = 0; i < 40; i++)); do
    got=$("$@")
    [[ $got == "$want" ]] && break
    sleep 1
  done
  expect_eq "$d" "$want" "$got"
}

run_tests() {
  local v=$1 before after
  printf '\n\033[1m=== Debian %s ===\033[0m\n' "$v"
  docker build -q --build-arg DEBIAN="$v" --target server -t "$P-server:$v" "$REPO/tests" >/dev/null
  docker build -q --build-arg DEBIAN="$v" --target client -t "$P-client:$v" "$REPO/tests" >/dev/null

  cleanup
  docker network create --ipv6 --subnet "$LAN4.0/24" --subnet "${LAN6}:/64" "$NETWORK" >/dev/null
  docker run -d --name "$P-server" --hostname "$P-server" --network "$NETWORK" \
    --ip "$SERVER4" --ip6 "$SERVER6" \
    --sysctl net.ipv6.conf.all.disable_ipv6=0 --sysctl net.ipv6.conf.default.disable_ipv6=0 \
    --privileged --cgroupns=host -v /sys/fs/cgroup:/sys/fs/cgroup:rw "$P-server:$v" >/dev/null
  local i=3 c
  for c in laptop homeserver outside; do
    docker run -d --name "$P-$c" --hostname "$c" --network "$NETWORK" \
      --ip "$LAN4.$i" --ip6 "${LAN6}:$i" \
      --privileged --sysctl net.ipv6.conf.all.disable_ipv6=0 "$P-client:$v" >/dev/null
    i=$((i + 1))
  done
  wait_for_systemd

  on outside sh -c 'mkdir -p -m 700 /root/.ssh && ssh-keygen -q -t ed25519 -N "" -f /root/.ssh/id_ed25519'
  on outside cat /root/.ssh/id_ed25519.pub |
    on_i server sh -c 'cat >/root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys'
  docker cp "$REPO/tests/udp_probe.py" "$P-outside:/udp_probe.py"

  on server mkdir -p /opt/offsite-vpn
  docker cp "$REPO/setup.sh" "$P-server:/opt/offsite-vpn/setup.sh"
  on_i server tee /opt/offsite-vpn/vpn.conf >/dev/null <<EOF
endpoint $SERVER4
client laptop
client homeserver
client phone
forward tcp 8080 homeserver 8000
forward tcp 8081 laptop 8000
forward udp 8080 homeserver 8000
EOF

  echo "First run"
  if run_setup run1; then ok "setup.sh succeeds on a fresh box"; else
    bad "setup.sh succeeds on a fresh box"; tail -20 "$LOG_DIR/run1.log"; return; fi
  expect "client configs + QR codes generated" on server sh -c \
    'cd /opt/offsite-vpn/.clients && test -s laptop.conf -a -s homeserver.conf -a -s phone.conf -a -s phone.png'
  expect "client configs are mode 600" on server sh -c \
    'test "$(stat -c %a /opt/offsite-vpn/.clients/laptop.conf)" = 600'
  expect "wg0 up with 3 peers" on server sh -c 'test "$(wg show wg0 peers | wc -l)" = 3'
  expect "live peers match config" peers_in_sync
  expect "IPv4 forwarding enabled" on server sh -c 'test "$(sysctl -n net.ipv4.ip_forward)" = 1'
  expect "IPv6 forwarding enabled" on server sh -c 'test "$(sysctl -n net.ipv6.conf.all.forwarding)" = 1'
  expect "SSH password auth disabled" on server sh -c 'sshd -T | grep -x "passwordauthentication no"'
  expect "SSH key login works (IPv4)" ssh_login "$SERVER4"
  expect "SSH key login works (IPv6)" ssh_login "$SERVER6"
  expect "SSH password login not offered" password_login_refused "$SERVER4"
  expect "SSH root login key-only" on server sh -c 'sshd -T | grep -xE "permitrootlogin (prohibit-password|without-password)"'
  expect "unattended-upgrades auto-reboot on" on server sh -c \
    'apt-config dump | grep -x "Unattended-Upgrade::Automatic-Reboot \"true\";"'
  expect "unattended-upgrades enabled" on server sh -c \
    'apt-config dump | grep -x "APT::Periodic::Unattended-Upgrade \"1\";"'
  expect "services enabled at boot" on server systemctl is-enabled wg-quick@wg0 nftables apt-daily-upgrade.timer

  echo "Idempotency"
  before=$(snapshot)
  expect "second run succeeds" run_setup run2
  after=$(snapshot)
  expect_eq "second run changes no files" "$before" "$after"
  expect_eq "second run reloads nothing" "1" "$(grep -c '==>' "$LOG_DIR/run2.log")"

  echo "Traffic"
  on outside ip -4 addr add "$INET4/32" dev lo
  on outside ip -6 addr add "$INET6/128" dev lo
  routes_to_inet server
  # The laptop's own default routes also lead to the internet host, so traffic
  # that leaked around the tunnel would arrive with the laptop's address.
  on laptop ip -4 route replace default via "$OUTSIDE4"
  on laptop ip -6 route replace default via "$OUTSIDE6"
  for c in laptop homeserver outside; do start_echo "$c" 8000; done
  expect "laptop tunnel up" tunnel_up laptop
  expect "homeserver tunnel up" tunnel_up homeserver
  sleep 1
  expect_eq "client: IPv4 internet exits via server" "outside $SERVER4" "$(seen_by laptop "http://$INET4:8000")"
  expect_eq "client: IPv6 internet exits via server" "outside $SERVER6" "$(seen_by laptop "http://[$INET6]:8000")"
  expect_eq "IPv4 forward to homeserver (source preserved)" "homeserver $INET4" \
    "$(seen_by outside "http://$SERVER4:8080" --interface "$INET4")"
  expect_eq "IPv6 forward to homeserver (source preserved)" "homeserver $INET6" \
    "$(seen_by outside "http://[$SERVER6]:8080" --interface "$INET6")"
  expect_eq "IPv4 forward to laptop" "laptop $INET4" "$(seen_by outside "http://$SERVER4:8081" --interface "$INET4")"
  expect_eq "IPv4 UDP forward to homeserver (source preserved)" "homeserver $INET4" "$(udp_seen_by_outside "$SERVER4" 8080 "$INET4")"
  expect_eq "IPv6 UDP forward to homeserver (source preserved)" "homeserver $INET6" "$(udp_seen_by_outside "$SERVER6" 8080 "$INET6")"
  start_echo server 9999
  sleep 1
  expect "server port 9999 listens locally" on server curl -fsS -m 3 http://127.0.0.1:9999
  expect_fail "firewall blocks unforwarded port over IPv4" on outside curl -fsS -m 3 "http://$SERVER4:9999"
  expect_fail "firewall blocks unforwarded port over IPv6" on outside curl -gfsS -m 3 "http://[$SERVER6]:9999"
  expect_fail "client-to-client blocked by default" \
    on laptop curl -fsS -m 3 "http://$(client_ip4 homeserver):8000"

  echo "Client changes"
  before=$(on server md5sum /opt/offsite-vpn/.clients/laptop.conf /opt/offsite-vpn/.clients/homeserver.conf)
  on server sed -i 's/^client phone$/client tablet/' /opt/offsite-vpn/vpn.conf
  expect "run with phone removed, tablet added" run_setup run3
  expect "phone config removed" on server test ! -e /opt/offsite-vpn/.clients/phone.conf
  expect "phone keys archived" on server sh -c 'ls -d /etc/wireguard/offsite-vpn/revoked/phone.*'
  expect "tablet config created" on server test -s /opt/offsite-vpn/.clients/tablet.conf
  expect "live peers updated (phone out, tablet in)" peers_in_sync
  expect_eq "existing client configs untouched" "$before" \
    "$(on server md5sum /opt/offsite-vpn/.clients/laptop.conf /opt/offsite-vpn/.clients/homeserver.conf)"
  expect_eq "existing tunnels keep working" "homeserver $INET4" \
    "$(seen_by outside "http://$SERVER4:8080" --interface "$INET4")"

  echo "Validation"
  before=$(snapshot)
  on server sh -c 'cp /opt/offsite-vpn/vpn.conf /tmp/bad1.conf && echo "forward tcp 22 laptop 22" >>/tmp/bad1.conf'
  on server sh -c 'cp /opt/offsite-vpn/vpn.conf /tmp/bad2.conf && echo "forward tcp 9000 nobody 80" >>/tmp/bad2.conf'
  on server sh -c 'cp /opt/offsite-vpn/vpn.conf /tmp/bad3.conf && echo "clinet typo" >>/tmp/bad3.conf'
  on server sh -c 'cp /opt/offsite-vpn/vpn.conf /tmp/bad4.conf && echo "subnet6 fd66::/48" >>/tmp/bad4.conf'
  on server sh -c 'cp /opt/offsite-vpn/vpn.conf /tmp/bad5.conf && echo "ssh_key ssh-ed25519 not-a-key me" >>/tmp/bad5.conf'
  on server sh -c "cp /opt/offsite-vpn/vpn.conf /tmp/bad6.conf && echo 'subnet $LAN4.0/24' >>/tmp/bad6.conf"
  on server sh -c 'cp /opt/offsite-vpn/vpn.conf /tmp/bad7.conf && echo "subnet 999.1.1.0/24" >>/tmp/bad7.conf'
  on server sh -c 'cp /opt/offsite-vpn/vpn.conf /tmp/bad8.conf && echo "subnet 10.0.1.0/24" >>/tmp/bad8.conf'
  expect_fail "rejects forward on SSH port" run_setup bad1 /tmp/bad1.conf
  expect_fail "rejects forward to unknown client" run_setup bad2 /tmp/bad2.conf
  expect_fail "rejects unknown directive" run_setup bad3 /tmp/bad3.conf
  expect_fail "rejects non-/64 subnet6" run_setup bad4 /tmp/bad4.conf
  expect_fail "rejects malformed ssh_key" run_setup bad5 /tmp/bad5.conf
  expect_fail "rejects subnet overlapping the LAN" run_setup bad6 /tmp/bad6.conf
  expect_fail "rejects invalid subnet octets" run_setup bad7 /tmp/bad7.conf
  on server ip route add 10.0.0.0/8 via "$LAN4.1"
  expect_fail "rejects subnet overlapping a route via the default gateway" run_setup bad8 /tmp/bad8.conf
  on server ip route del 10.0.0.0/8
  on server mv /root/.ssh/authorized_keys /root/.ssh/authorized_keys.bak
  expect_fail "lockout guard: no key" run_setup nokey
  on server sh -c 'echo "ssh-ed25519 AAAAnotarealkey me" >/root/.ssh/authorized_keys'
  expect_fail "lockout guard: only a malformed key" run_setup badkey
  on server mv /root/.ssh/authorized_keys.bak /root/.ssh/authorized_keys
  expect_eq "failed runs changed nothing" "$before" "$(snapshot)"

  on server sh -c 'echo "AuthorizedKeysFile /etc/ssh/keys/%u" >/etc/ssh/sshd_config.d/10-test.conf'
  expect_fail "lockout guard: key not in the AuthorizedKeysFile sshd uses" run_setup akf1
  on server sh -c 'mkdir -p /etc/ssh/keys && cp /root/.ssh/authorized_keys /etc/ssh/keys/root'
  expect "lockout guard: honours custom AuthorizedKeysFile" run_setup akf2
  on server rm -rf /etc/ssh/sshd_config.d/10-test.conf /etc/ssh/keys
  on server sh -c 'echo "DenyUsers root" >/etc/ssh/sshd_config.d/10-test.conf'
  expect_fail "lockout guard: honours DenyUsers" run_setup denyusers
  on server rm /etc/ssh/sshd_config.d/10-test.conf
  on server chmod 666 /root/.ssh/authorized_keys
  expect_fail "lockout guard: honours StrictModes permissions" run_setup strictmodes
  on server chmod 600 /root/.ssh/authorized_keys
  on server sed -i '1i PubkeyAuthentication no' /etc/ssh/sshd_config
  expect_fail "lockout guard: pubkey auth disabled" run_setup nopubkey
  on server sed -i '1d' /etc/ssh/sshd_config
  on server sed -i '1i PasswordAuthentication yes' /etc/ssh/sshd_config
  expect_fail "fails if SSH hardening is overridden" run_setup sshoverride
  on server sed -i '1d' /etc/ssh/sshd_config

  echo "Reboot"
  docker restart "$P-server" >/dev/null
  wait_for_systemd
  routes_to_inet server
  expect "wg0 up after reboot" on server wg show wg0
  expect "SSH key login works after reboot" ssh_login "$SERVER4"
  expect "forwarding enabled after reboot" on server sh -c \
    'test "$(sysctl -n net.ipv4.ip_forward)$(sysctl -n net.ipv6.conf.all.forwarding)" = 11'
  expect "firewall loaded after reboot" on server sh -c 'nft list table ip nat | grep -q dnat'
  # The server forgets client endpoints on reboot; clients re-handshake within
  # one PersistentKeepalive interval (25s).
  retry_eq "IPv4 port forward recovers after reboot" "homeserver $INET4" \
    seen_by outside "http://$SERVER4:8080" --interface "$INET4"
  expect_eq "IPv6 port forward recovers after reboot" "homeserver $INET6" \
    "$(seen_by outside "http://[$SERVER6]:8080" --interface "$INET6")"
  retry_eq "laptop recovers after reboot" "outside $SERVER4" seen_by laptop "http://$INET4:8000"

  echo "Server without IPv6"
  on server ip -6 route del default
  # The server keeps a specific route to the internet host, and that host can
  # route back to the tunnel subnet: un-NATed forwarding would now get replies.
  on outside ip -6 route replace fd66:66:66::/64 via "$SERVER6"
  expect "setup.sh succeeds without IPv6" run_setup noipv6
  expect "reports IPv6 as unavailable" grep -q "No IPv6 on this server" "$LOG_DIR/noipv6.log"
  expect_eq "client: IPv4 still exits via server" "outside $SERVER4" "$(seen_by laptop "http://$INET4:8000")"
  expect_eq "client: IPv6 dropped, not leaked" "<no response>" "$(seen_by laptop "http://[$INET6]:8000")"

  echo "Server with IPv6 disabled on new interfaces"
  on server sysctl -qw net.ipv6.conf.default.disable_ipv6=1
  expect "setup.sh succeeds" run_setup v6disabled
  expect "wg0 restarted IPv4-only" on server sh -c '! ip -6 addr show dev wg0 | grep -q inet6'
  expect "wg0 restarts cleanly (as on reboot)" on server systemctl restart wg-quick@wg0
  retry_eq "client: IPv4 still exits via server" "outside $SERVER4" seen_by laptop "http://$INET4:8000"
  expect_eq "client: IPv6 dropped, not leaked" "<no response>" "$(seen_by laptop "http://[$INET6]:8000")"

  echo "NAT'd endpoint"
  on server sed -i "s/^endpoint .*/endpoint 198.51.100.7:5468/" /opt/offsite-vpn/vpn.conf
  expect "setup.sh succeeds with endpoint host:port" run_setup natport
  expect_eq "client config uses the public port" "Endpoint = 198.51.100.7:5468" \
    "$(on server grep '^Endpoint' /opt/offsite-vpn/.clients/laptop.conf)"
  expect "WireGuard still listens on listen_port" on server sh -c 'test "$(wg show wg0 listen-port)" = 51820'
  on server sh -c 'cp /opt/offsite-vpn/vpn.conf /tmp/bad9.conf && echo "endpoint 1.2.3.4:99999" >>/tmp/bad9.conf'
  expect_fail "rejects bad endpoint port" run_setup bad9 /tmp/bad9.conf
}

for v in "${VERSIONS[@]}"; do run_tests "$v"; done

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
((FAIL == 0))
