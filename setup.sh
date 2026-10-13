#!/usr/bin/env bash
# offsite-vpn: turn a Debian box into a set-and-forget WireGuard VPN with port
# forwarding, a default-deny firewall, SSH hardening and unattended upgrades.
#
# Usage: sudo ./setup.sh [path/to/vpn.conf]
#
# Idempotent: re-running converges the box to vpn.conf. Existing client keys are
# never regenerated. See README.md (humans) and AGENTS.md (contributors).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${1:-$SCRIPT_DIR/vpn.conf}"
OUT_DIR="$SCRIPT_DIR/.clients"
STATE_DIR=/etc/wireguard/offsite-vpn
WG_IF=wg0
MARKER="# Managed by offsite-vpn (setup.sh). Edits are overwritten; change vpn.conf instead."

log()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# write_file PATH MODE < content
# Writes only if the content differs; sets WROTE=1 if it changed, else WROTE=0.
WROTE=0
write_file() {
  local path=$1 mode=$2 tmp
  tmp=$(mktemp)
  cat >"$tmp"
  if [[ -f $path ]] && cmp -s "$tmp" "$path"; then
    WROTE=0
  else
    WROTE=1
    install -D -m "$mode" "$tmp" "$path"
  fi
  rm -f "$tmp"
  chmod "$mode" "$path"
}

valid_port() { [[ $1 =~ ^[0-9]+$ ]] && (($1 >= 1 && $1 <= 65535)); }

[[ $EUID -eq 0 ]] || die "Run as root: sudo $0"
[[ -r /etc/os-release ]] || die "Cannot read /etc/os-release"
# shellcheck disable=SC1091
. /etc/os-release
[[ ${ID:-} == debian ]] || die "Only Debian is supported (found: ${ID:-unknown})"
if [[ -n ${VERSION_ID:-} ]] && ((${VERSION_ID%%.*} < 12)); then
  die "Debian 12 (bookworm) or newer required (found: $VERSION_ID)"
fi

exec 9>/run/offsite-vpn.lock
flock -n 9 || die "Another setup.sh run is in progress"

[[ -f $CONFIG_FILE ]] || die "Missing $CONFIG_FILE. Start with: cp vpn.conf.example vpn.conf"

WG_PORT=51820
ENDPOINT=""
ENDPOINT_PORT=""   # differs from listen_port behind NAT port forwarding
SUBNET=10.66.66.0/24
SUBNET6=fd66:66:66::/64
DNS="1.1.1.1, 1.0.0.1, 2606:4700:4700::1111, 2606:4700:4700::1001"
CLIENT_TO_CLIENT=no
REBOOT_TIME=04:00
CLIENTS=()
declare -A IS_CLIENT=()
FORWARDS=()   # "proto server_port client client_port"
SSH_KEYS=()

lineno=0
while IFS= read -r line || [[ -n $line ]]; do
  lineno=$((lineno + 1))
  line=${line%%#*}
  read -r -a w <<<"$line" || true
  ((${#w[@]})) || continue
  where="$CONFIG_FILE:$lineno"
  case ${w[0]} in
    listen_port)
      valid_port "${w[1]:-}" || die "$where: bad port '${w[1]:-}'"
      WG_PORT=${w[1]} ;;
    endpoint)
      [[ -n ${w[1]:-} ]] || die "$where: endpoint needs a value"
      ENDPOINT=${w[1]}
      if [[ $ENDPOINT =~ ^\[(.+)\]:([0-9]+)$ || $ENDPOINT =~ ^([^:]+):([0-9]+)$ ]]; then
        ENDPOINT=${BASH_REMATCH[1]} ENDPOINT_PORT=${BASH_REMATCH[2]}
        valid_port "$ENDPOINT_PORT" || die "$where: bad endpoint port '$ENDPOINT_PORT'"
      fi ;;
    subnet)
      [[ ${w[1]:-} =~ ^([0-9]{1,3}\.){3}0/24$ ]] || die "$where: subnet must look like 10.66.66.0/24"
      SUBNET=${w[1]} ;;
    subnet6)
      [[ ${w[1]:-} =~ ^[0-9a-fA-F]{1,4}(:[0-9a-fA-F]{1,4}){0,3}::/64$ ]] ||
        die "$where: subnet6 must look like fd66:66:66::/64"
      SUBNET6=${w[1],,} ;;
    dns)
      ((${#w[@]} > 1)) || die "$where: dns needs at least one server"
      DNS=$(IFS=,; echo "${w[*]:1}"); DNS=${DNS//,/, } ;;
    client_to_client)
      [[ ${w[1]:-} =~ ^(yes|no)$ ]] || die "$where: client_to_client must be yes or no"
      CLIENT_TO_CLIENT=${w[1]} ;;
    reboot_time)
      [[ ${w[1]:-} =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || die "$where: reboot_time must be HH:MM"
      REBOOT_TIME=${w[1]} ;;
    ssh_key)
      ((${#w[@]} >= 3)) || die "$where: ssh_key needs '<type> <base64> [comment]'"
      SSH_KEYS+=("${w[*]:1}") ;;
    client)
      ((${#w[@]} == 2)) || die "$where: expected 'client <name>'"
      name=${w[1]}
      [[ $name =~ ^[A-Za-z0-9_-]{1,32}$ ]] || die "$where: client name must be 1-32 chars of [A-Za-z0-9_-]"
      [[ -z ${IS_CLIENT[$name]:-} ]] || die "$where: duplicate client '$name'"
      CLIENTS+=("$name"); IS_CLIENT[$name]=1 ;;
    forward)
      ((${#w[@]} == 5)) || die "$where: expected 'forward <tcp|udp> <server_port> <client> <client_port>'"
      [[ ${w[1]} =~ ^(tcp|udp)$ ]] || die "$where: protocol must be tcp or udp"
      valid_port "${w[2]}" || die "$where: bad server port '${w[2]}'"
      valid_port "${w[4]}" || die "$where: bad client port '${w[4]}'"
      FORWARDS+=("${w[1]} ${w[2]} ${w[3]} ${w[4]}") ;;
    *) die "$where: unknown directive '${w[0]}'" ;;
  esac
done <"$CONFIG_FILE"

NET=${SUBNET%.0/24}    # 10.66.66     -> hosts are $NET.<n>
NET6=${SUBNET6%/64}    # fd66:66:66:: -> hosts are $NET6<n>
IFS=. read -r o1 o2 o3 <<<"$NET"
((o1 <= 255 && o2 <= 255 && o3 <= 255)) || die "subnet $SUBNET is not a valid IPv4 network"

HAVE_SSHD=0
command -v sshd >/dev/null && HAVE_SSHD=1

if ((HAVE_SSHD)); then
  for key in "${SSH_KEYS[@]}"; do
    ssh-keygen -l -f - <<<"$key" >/dev/null 2>&1 || die "ssh_key is not a valid SSH public key: ${key:0:40}..."
  done
fi

# wireguard-tools, not the wireguard metapackage: that can pull in a kernel, and
# Debian kernels already ship the module.
PACKAGES=(wireguard-tools nftables qrencode curl ca-certificates iproute2
          unattended-upgrades apt-listchanges needrestart)
missing=()
for p in "${PACKAGES[@]}"; do
  dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep "install ok installed" >/dev/null || missing+=("$p")
done
if ((${#missing[@]})); then
  log "Installing: ${missing[*]}"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -q
  apt-get install -y -q --no-install-recommends "${missing[@]}"
fi

default_dev() { ip "$1" route show default | awk '{for (i=1;i<NF;i++) if ($i=="dev") {print $(i+1); exit}}'; }
WAN_IF=$(default_dev -4)
[[ -n $WAN_IF ]] || die "No IPv4 default route found; this script needs an IPv4-connected server"
# Some images disable IPv6 for new interfaces; wg0 must then stay IPv4-only or
# wg-quick fails to start.
IPV6_STACK=0
[[ $(cat /proc/sys/net/ipv6/conf/default/disable_ipv6 2>/dev/null) == 0 ]] && IPV6_STACK=1
WAN6_IF=""
if ((IPV6_STACK)); then
  WAN6_IF=$(default_dev -6)
  if [[ -n $WAN6_IF && $(ip -6 addr show dev "$WAN6_IF" scope global) != *inet6* ]]; then
    WAN6_IF=""
  fi
fi

SSH_PORTS=()
if ((HAVE_SSHD)); then
  mapfile -t SSH_PORTS < <(
    { sshd -T 2>/dev/null | awk '$1=="port" {print $2}'
      [[ -n ${SSH_CONNECTION:-} ]] && echo "${SSH_CONNECTION##* }"
    } | sort -un)
  ((${#SSH_PORTS[@]})) || SSH_PORTS=(22)
fi

declare -A SEEN_FWD=()
for f in "${FORWARDS[@]}"; do
  read -r proto sport cname _ <<<"$f"
  [[ -n ${IS_CLIENT[$cname]:-} ]] || die "forward $f: unknown client '$cname'"
  [[ -z ${SEEN_FWD[$proto/$sport]:-} ]] || die "forward $f: $proto/$sport is forwarded twice"
  SEEN_FWD[$proto/$sport]=1
  [[ $proto == udp && $sport == "$WG_PORT" ]] && die "forward $f: conflicts with WireGuard port"
  for p in "${SSH_PORTS[@]}"; do
    [[ $proto == tcp && $sport == "$p" ]] && die "forward $f: conflicts with SSH port"
  done
done

# A tunnel subnet overlapping a route the box already has (e.g. the cloud VPC)
# would hijack that traffic. python3 is present: unattended-upgrades needs it.
overlapping_routes() {
  { ip -o -4 route show table all; ip -o -6 route show table all 2>/dev/null; } | python3 -I -c '
import ipaddress, sys
wg, subnets = sys.argv[1], [ipaddress.ip_network(n) for n in sys.argv[2:]]
for line in sys.stdin:
    t = line.split()
    if t[0] in ("local", "broadcast", "multicast", "anycast"):
        continue
    if t[0] in ("unicast", "unreachable", "blackhole", "prohibit", "throw"):
        t = t[1:]
    if t[0] == "default" or ("dev" in t and t[t.index("dev") + 1] == wg):
        continue
    net = ipaddress.ip_network(t[0], strict=False)
    if any(net.version == n.version and net.overlaps(n) for n in subnets):
        print(" ".join(t))
' "$WG_IF" "$@"
}
tunnel_subnets=("$SUBNET")
((IPV6_STACK)) && tunnel_subnets+=("$SUBNET6")
mapfile -t overlaps < <(overlapping_routes "${tunnel_subnets[@]}")
((${#overlaps[@]} == 0)) ||
  die "Tunnel subnet overlaps existing route(s): ${overlaps[*]}. Pick another subnet/subnet6 in vpn.conf."

sshd_value() { awk -v k="$1" '$1 == k {$1 = ""; print}' | xargs; }   # stdin: sshd -T output
sshd_config_for() { sshd -T -C "user=$1,host=localhost,addr=127.0.0.1" 2>/dev/null; }
expand_keys_path() {   # PATTERN USER HOME, as sshd expands AuthorizedKeysFile
  local f=${1//%h/$3}
  f=${f//%u/$2}; f=${f//%%/%}
  [[ $f == /* ]] || f="$3/$f"
  echo "$f"
}
# sshd's StrictModes ignores keys in group/world-writable paths.
keys_path_safe() {
  local p=$1 owner mode
  while [[ $p != / ]]; do
    read -r owner mode < <(stat -c '%U %a' "$p")
    if [[ $owner != "$2" && $owner != root ]] || (((8#$mode & 8#022) != 0)); then return 1; fi
    p=$(dirname "$p")
  done
}
matches_any() {   # WORD PATTERN...  (sshd globs; user@host patterns match on user)
  local w=$1 p; shift
  for p in "$@"; do
    # shellcheck disable=SC2053
    [[ $w == ${p%%@*} ]] && return 0
  done
  return 1
}
any_group_matches() {   # USER PATTERN...
  local g groups
  read -r -a groups < <(id -nG "$1")
  shift
  for g in "${groups[@]}"; do matches_any "$g" "$@" && return 0; done
  return 1
}
account_accepts_key() {   # USER HOME: would sshd (config on disk) accept a key for USER?
  local user=$1 home=$2 cfg pat f
  local -a deny allow dgroups agroups pats
  cfg=$(sshd_config_for "$user") || return 1
  [[ $(sshd_value pubkeyauthentication <<<"$cfg") == yes ]] || return 1
  [[ $(sshd_value authenticationmethods <<<"$cfg") == any ]] || return 1
  if [[ $user == root && ! $(sshd_value permitrootlogin <<<"$cfg") =~ ^(yes|prohibit-password|without-password)$ ]]; then
    return 1
  fi
  read -r -a deny <<<"$(sshd_value denyusers <<<"$cfg")"
  read -r -a allow <<<"$(sshd_value allowusers <<<"$cfg")"
  read -r -a dgroups <<<"$(sshd_value denygroups <<<"$cfg")"
  read -r -a agroups <<<"$(sshd_value allowgroups <<<"$cfg")"
  if matches_any "$user" "${deny[@]}"; then return 1; fi
  if ((${#allow[@]})) && ! matches_any "$user" "${allow[@]}"; then return 1; fi
  if any_group_matches "$user" "${dgroups[@]}"; then return 1; fi
  if ((${#agroups[@]})) && ! any_group_matches "$user" "${agroups[@]}"; then return 1; fi
  read -r -a pats <<<"$(sshd_value authorizedkeysfile <<<"$cfg")"
  for pat in "${pats[@]}"; do
    f=$(expand_keys_path "$pat" "$user" "$home")
    if [[ -f $f ]] && keys_path_safe "$f" "$user" && ssh-keygen -l -f "$f" >/dev/null 2>&1; then return 0; fi
  done
  return 1
}
# Password login gets disabled, so some account must be able to log in with a key.
ssh_access_ok() {
  local user uid home shell
  while IFS=: read -r user _ uid _ _ home shell; do
    [[ $uid == 0 || $uid -ge 1000 ]] || continue
    [[ -x $shell && $shell != */nologin && $shell != */false ]] || continue
    if account_accepts_key "$user" "$home"; then return 0; fi
  done < <(getent passwd)
  return 1
}

if ((${#SSH_KEYS[@]})); then
  ((HAVE_SSHD)) || die "ssh_key given but openssh-server is not installed"
  KEY_USER=${SUDO_USER:-root}
  KEY_HOME=$(getent passwd "$KEY_USER" | cut -d: -f6)
  KEY_GROUP=$(id -gn "$KEY_USER")
  read -r pat _ < <(sshd_config_for "$KEY_USER" | sshd_value authorizedkeysfile)
  ak=$(expand_keys_path "$pat" "$KEY_USER" "$KEY_HOME")
  if [[ $ak == "$KEY_HOME"/* ]]; then
    install -d -m 700 -o "$KEY_USER" -g "$KEY_GROUP" "$(dirname "$ak")"
  else
    install -d -m 755 "$(dirname "$ak")"
  fi
  [[ -e $ak ]] || install -m 600 -o "$KEY_USER" -g "$KEY_GROUP" /dev/null "$ak"
  for key in "${SSH_KEYS[@]}"; do
    if ! grep -qxF "$key" "$ak"; then
      echo "$key" >>"$ak"
      log "Authorized SSH key for $KEY_USER in $ak: ${key:0:40}..."
    fi
  done
fi

if ((HAVE_SSHD)) && ! ssh_access_ok; then
  die "No account could log in with an SSH key, and password login is about to be disabled.
       Add your public key via 'ssh_key ...' in vpn.conf (and check sshd_config Allow/Deny/Match rules)."
fi

# Auto-detected endpoints are saved so a later detection glitch can't rewrite
# every client config.
SAVE_ENDPOINT=0
if [[ -z $ENDPOINT ]]; then
  if [[ -s $STATE_DIR/endpoint ]]; then
    ENDPOINT=$(<"$STATE_DIR/endpoint")
  else
    ENDPOINT=$(curl -4 -fsS --max-time 10 https://api.ipify.org || true)
    [[ $ENDPOINT =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die "Could not auto-detect public IP; set 'endpoint' in vpn.conf"
    SAVE_ENDPOINT=1
  fi
fi
install -d -m 700 "$STATE_DIR" "$STATE_DIR/clients" "$STATE_DIR/revoked"
if ((SAVE_ENDPOINT)); then
  echo "$ENDPOINT" >"$STATE_DIR/endpoint"
  log "Detected public endpoint $ENDPOINT (saved to $STATE_DIR/endpoint)"
fi
ENDPOINT_HOSTPORT="$ENDPOINT:${ENDPOINT_PORT:-$WG_PORT}"
[[ $ENDPOINT == *:* ]] && ENDPOINT_HOSTPORT="[$ENDPOINT]:${ENDPOINT_PORT:-$WG_PORT}"

render_sysctl() {
  echo "$MARKER"
  echo "net.ipv4.ip_forward = 1"
  if [[ -n $WAN6_IF ]]; then
    # With forwarding on, the kernel ignores router advertisements unless
    # accept_ra=2, and an SLAAC-configured box would lose its IPv6 default route.
    echo "net.ipv6.conf.${WAN6_IF//./\/}.accept_ra = 2"
    echo "net.ipv6.conf.all.forwarding = 1"
  fi
  cat <<EOF
net.ipv4.tcp_syncookies = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_source_route = 0
EOF
}
# Not `render | write_file`: a pipeline would run write_file in a subshell and lose WROTE.
write_file /etc/sysctl.d/90-offsite-vpn.conf 644 < <(render_sysctl)
if ((WROTE)); then sysctl -q -p /etc/sysctl.d/90-offsite-vpn.conf; fi

# Key state is the source of truth and is never regenerated once created:
#   $STATE_DIR/server.key
#   $STATE_DIR/clients/<name>/{private.key,psk,host}   host = last octet / IPv6 group
if [[ ! -s $STATE_DIR/server.key ]]; then
  (umask 077; wg genkey >"$STATE_DIR/server.key")
  log "Generated server key"
fi
SERVER_PUB=$(wg pubkey <"$STATE_DIR/server.key")

for d in "$STATE_DIR"/clients/*/; do
  [[ -d $d ]] || continue
  name=$(basename "$d")
  if [[ -z ${IS_CLIENT[$name]:-} ]]; then
    mv "$d" "$STATE_DIR/revoked/$name.$(date +%Y%m%d%H%M%S)"
    rm -f "$OUT_DIR/$name.conf" "$OUT_DIR/$name.png"
    warn "Revoked client '$name' (not in config). Keys archived in $STATE_DIR/revoked/"
  fi
done

next_free_host() {
  local used=" " h
  for h in "$STATE_DIR"/clients/*/host; do [[ -f $h ]] && used+="$(<"$h") "; done
  for ((h = 2; h <= 254; h++)); do
    [[ $used == *" $h "* ]] || { echo "$h"; return; }
  done
  die "Subnet $SUBNET is full"
}

declare -A CLIENT_HOST=()
NEW_CLIENTS=()
for name in "${CLIENTS[@]}"; do
  d=$STATE_DIR/clients/$name
  install -d -m 700 "$d"
  if [[ ! -s $d/private.key ]]; then
    (umask 077; wg genkey >"$d/private.key")
    NEW_CLIENTS+=("$name")
  fi
  [[ -s $d/psk ]] || (umask 077; wg genpsk >"$d/psk")
  [[ -s $d/host ]] || next_free_host >"$d/host"
  CLIENT_HOST[$name]=$(<"$d/host")
done

ip4() { echo "$NET.${CLIENT_HOST[$1]}"; }
ip6() { echo "$NET6${CLIENT_HOST[$1]}"; }

render_wg_server() {
  local name d
  echo "$MARKER"
  echo "[Interface]"
  if ((IPV6_STACK)); then echo "Address = $NET.1/24, ${NET6}1/64"; else echo "Address = $NET.1/24"; fi
  echo "ListenPort = $WG_PORT"
  echo "PrivateKey = $(<"$STATE_DIR/server.key")"
  for name in "${CLIENTS[@]}"; do
    d=$STATE_DIR/clients/$name
    echo
    echo "[Peer]"
    echo "# $name"
    echo "PublicKey = $(wg pubkey <"$d/private.key")"
    echo "PresharedKey = $(<"$d/psk")"
    if ((IPV6_STACK)); then
      echo "AllowedIPs = $(ip4 "$name")/32, $(ip6 "$name")/128"
    else
      echo "AllowedIPs = $(ip4 "$name")/32"
    fi
  done
}
write_file "/etc/wireguard/$WG_IF.conf" 600 < <(render_wg_server)
wg_changed=$WROTE

systemctl enable --quiet "wg-quick@$WG_IF"
if ! systemctl is-active --quiet "wg-quick@$WG_IF"; then
  log "Starting WireGuard"
  systemctl start "wg-quick@$WG_IF"
elif ((wg_changed)); then
  wg_addrs=$(ip addr show dev "$WG_IF")
  has_v6=0
  [[ $wg_addrs == *"inet6 ${NET6}1/64 "* ]] && has_v6=1
  if [[ $wg_addrs == *"inet $NET.1/24 "* && $has_v6 == "$IPV6_STACK" &&
        $(wg show "$WG_IF" listen-port) == "$WG_PORT" ]]; then
    log "Reloading WireGuard peers"
    wg syncconf "$WG_IF" <(wg-quick strip "$WG_IF")
  else
    log "Restarting WireGuard (address/port changed)"
    systemctl restart "wg-quick@$WG_IF"
  fi
fi

render_nat_table() {
  local fam=$1 wan=$2 subnet=$3 addr_fn=$4 f proto sport cname cport addr
  cat <<EOF

table $fam nat {
  chain prerouting {
    type nat hook prerouting priority dstnat; policy accept;
EOF
  for f in "${FORWARDS[@]}"; do
    read -r proto sport cname cport <<<"$f"
    addr=$("$addr_fn" "$cname")
    if [[ $fam == ip6 ]]; then addr="[$addr]"; fi
    echo "    fib daddr type local $proto dport $sport dnat to $addr:$cport"
  done
  cat <<EOF
  }

  chain postrouting {
    type nat hook postrouting priority srcnat; policy accept;
EOF
  if [[ -n $wan ]]; then
    echo "    oifname \"$wan\" $fam saddr $subnet masquerade"
  fi
  echo "  }"
  echo "}"
}

render_nftables() {
  local ssh_set
  ssh_set=$(IFS=,; echo "${SSH_PORTS[*]:-22}")
  cat <<EOF
#!/usr/sbin/nft -f
$MARKER
flush ruleset

table inet filter {
  chain input {
    type filter hook input priority filter; policy drop;
    ct state established,related accept
    ct state invalid drop
    iif "lo" accept
    meta l4proto { icmp, icmpv6 } accept
    tcp dport { $ssh_set } accept
    udp dport $WG_PORT accept
  }

  chain forward {
    type filter hook forward priority filter; policy drop;
    tcp flags & (syn|rst) == syn tcp option maxseg size set rt mtu
    ct state established,related accept
    ct state invalid drop
    meta nfproto ipv4 iifname "$WG_IF" oifname "$WAN_IF" accept
    oifname "$WG_IF" ct status dnat accept
EOF
  # Without an IPv6 uplink, clients' IPv6 must be dropped, not forwarded un-NATed.
  if [[ -n $WAN6_IF ]]; then
    echo "    meta nfproto ipv6 iifname \"$WG_IF\" oifname \"$WAN6_IF\" accept"
  fi
  if [[ $CLIENT_TO_CLIENT == yes ]]; then
    echo "    iifname \"$WG_IF\" oifname \"$WG_IF\" accept"
  fi
  cat <<EOF
  }

  chain output {
    type filter hook output priority filter; policy accept;
  }
}
EOF
  render_nat_table ip "$WAN_IF" "$SUBNET" ip4
  if ((IPV6_STACK)); then render_nat_table ip6 "$WAN6_IF" "$SUBNET6" ip6; fi
}

nft_rules=$(render_nftables)
nft -c -f - <<<"$nft_rules" || die "Generated nftables ruleset is invalid (bug)"
if [[ -f /etc/nftables.conf && ! -f /etc/nftables.conf.orig ]] && ! grep -qF "$MARKER" /etc/nftables.conf; then
  cp -a /etc/nftables.conf /etc/nftables.conf.orig
fi
write_file /etc/nftables.conf 755 <<<"$nft_rules"
systemctl enable --quiet nftables
if ((WROTE)) || ! systemctl is-active --quiet nftables; then
  log "Applying firewall"
  systemctl restart nftables
fi

if ((HAVE_SSHD)); then
  # sshd uses the first value it reads, so 00- beats cloud-init's 50-*.conf.
  write_file /etc/ssh/sshd_config.d/00-offsite-vpn.conf 644 <<EOF
$MARKER
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitEmptyPasswords no
PermitRootLogin prohibit-password
PubkeyAuthentication yes
X11Forwarding no
MaxAuthTries 3
LoginGraceTime 30
EOF
  # Checked against the config on disk before reloading, so a bad result never goes live.
  problem=""
  if ! sshd -t; then
    problem="sshd -t failed"
  elif ! grep -qx "passwordauthentication no" <<<"$(sshd -T)" || ! grep -qx "kbdinteractiveauthentication no" <<<"$(sshd -T)"; then
    problem="an earlier setting in /etc/ssh/sshd_config overrides it (or sshd_config.d/*.conf isn't included)"
  elif ! ssh_access_ok; then
    problem="no account could log in with an SSH key afterwards"
  fi
  if [[ -n $problem ]]; then
    if ((WROTE)); then rm -f /etc/ssh/sshd_config.d/00-offsite-vpn.conf; fi
    die "SSH hardening not applied: $problem"
  fi
  if ((WROTE)); then
    log "Reloading SSH (password login disabled)"
    systemctl reload ssh
  fi
else
  warn "openssh-server not installed; skipping SSH hardening"
fi

write_file /etc/apt/apt.conf.d/20auto-upgrades 644 <<EOF
$MARKER
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF

write_file /etc/apt/apt.conf.d/52offsite-vpn-unattended-upgrades 644 <<EOF
$MARKER
Unattended-Upgrade::Origins-Pattern {
  "origin=Debian,codename=\${distro_codename},label=Debian";
  "origin=Debian,codename=\${distro_codename}-updates";
  "origin=Debian,codename=\${distro_codename},label=Debian-Security";
  "origin=Debian,codename=\${distro_codename}-security,label=Debian-Security";
};
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-WithUsers "true";
Unattended-Upgrade::Automatic-Reboot-Time "$REBOOT_TIME";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-New-Unused-Dependencies "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Dpkg::Options { "--force-confdef"; "--force-confold"; };
EOF

# Restart services using outdated libraries without prompting.
write_file /etc/needrestart/conf.d/offsite-vpn.conf 644 <<EOF
$MARKER
\$nrconf{restart} = 'a';
EOF

systemctl enable --quiet --now apt-daily.timer apt-daily-upgrade.timer

render_client() {
  local name=$1 d=$STATE_DIR/clients/$1
  echo "# offsite-vpn client: $name"
  echo "[Interface]"
  echo "PrivateKey = $(<"$d/private.key")"
  echo "Address = $(ip4 "$name")/32, $(ip6 "$name")/128"
  echo "DNS = $DNS"
  echo
  echo "[Peer]"
  echo "PublicKey = $SERVER_PUB"
  echo "PresharedKey = $(<"$d/psk")"
  echo "Endpoint = $ENDPOINT_HOSTPORT"
  echo "AllowedIPs = 0.0.0.0/0, ::/0"
  echo "PersistentKeepalive = 25"
}

OWNER=$(stat -c %u:%g "$SCRIPT_DIR")
install -d -m 700 "$OUT_DIR"
chown "$OWNER" "$OUT_DIR"

for name in "${CLIENTS[@]}"; do
  write_file "$OUT_DIR/$name.conf" 600 < <(render_client "$name")
  if ((WROTE)) || [[ ! -f $OUT_DIR/$name.png ]]; then
    qrencode -t png -o "$OUT_DIR/$name.png" -r "$OUT_DIR/$name.conf"
    chmod 600 "$OUT_DIR/$name.png"
  fi
  chown "$OWNER" "$OUT_DIR/$name.conf" "$OUT_DIR/$name.png"
done

echo
log "Done. Endpoint: $ENDPOINT_HOSTPORT/udp, listening on udp/$WG_PORT  (WAN: $WAN_IF, IPv6 WAN: ${WAN6_IF:-none}, SSH ports: ${SSH_PORTS[*]:-none})"
for name in "${CLIENTS[@]}"; do
  new=""; [[ " ${NEW_CLIENTS[*]} " == *" $name "* ]] && new=" [NEW]"
  printf '    %-20s %-12s %-20s %s%s\n' "$name" "$(ip4 "$name")" "$(ip6 "$name")" \
    "$OUT_DIR/$name.conf" "$new"
done
for f in "${FORWARDS[@]}"; do
  read -r proto sport cname cport <<<"$f"
  echo "    forward $proto :$sport -> $cname:$cport"
done
if [[ -z $WAN6_IF ]]; then
  echo "    No IPv6 on this server: clients' IPv6 traffic is dropped (not leaked)."
fi
echo
echo "Copy configs off the box, e.g.:  scp -r ${SUDO_USER:-root}@${ENDPOINT_HOSTPORT%:*}:$OUT_DIR ."
echo "Remember to allow udp/$WG_PORT (and forwarded ports) in your cloud provider's firewall."
