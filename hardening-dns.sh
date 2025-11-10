#!/usr/bin/env bash
# Harden DNS on Debian/systemd VPS:
# - Ignore provider-pushed DNS (DHCP/NM)
# - Remove conflicting resolvconf
# - Enable systemd-resolved with DoT + DNSSEC
# - Disable LLMNR/mDNS
# - High-availability DNS: Cloudflare + Google
# - Idempotent, with backups and checks
set -euo pipefail

TS="$(date +%Y%m%d%H%M%S)"

log() { printf "\033[1;32m[+] %s\033[0m\n" "$*"; }
warn() { printf "\033[1;33m[!] %s\033[0m\n" "$*"; }
err() { printf "\033[1;31m[x] %s\033[0m\n" "$*"; }
backup() {
  local p="$1"
  if [ -e "$p" ]; then
    cp -a "$p" "${p}.bak.${TS}"
    log "Backup: ${p} -> ${p}.bak.${TS}"
  fi
}
require_root() {
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    err "Please run as root."
    exit 1
  fi
}
cmd_exists() { command -v "$1" >/dev/null 2>&1; }

require_root

log "=== DNS Hardening (systemd-resolved + DoT + DNSSEC) ==="

# 0) Basic environment info
OS_PRETTY="$(grep -E '^PRETTY_NAME=' /etc/os-release 2>/dev/null | cut -d= -f2- | tr -d '"')"
log "Detected OS: ${OS_PRETTY:-unknown}"
if ! pidof systemd >/dev/null 2>&1; then
  err "This script requires systemd."
  exit 1
fi

# 1) Remove conflicting packages (resolvconf) and prepare apt
if cmd_exists apt-get; then
  export DEBIAN_FRONTEND=noninteractive
  if dpkg -l | awk '$1=="ii" && $2=="resolvconf"{print}' >/dev/null; then
    log "Removing conflicting package: resolvconf"
    apt-get remove --purge -y resolvconf || true
  else
    log "resolvconf not installed — OK"
  fi
else
  warn "apt-get not found; skipping resolvconf purge."
fi

# 2) DHCP client hardening (dhclient): ignore provider DNS & search domains
DHCLIENT_CONF="/etc/dhcp/dhclient.conf"
mkdir -p /etc/dhcp
if [ ! -f "$DHCLIENT_CONF" ]; then
  touch "$DHCLIENT_CONF"
fi
backup "$DHCLIENT_CONF"

ensure_line() {
  local file="$1"; shift
  local line="$*"
  grep -Fqs "$line" "$file" || echo "$line" >> "$file"
}

log "Hardening dhclient to ignore provider DNS/search"
ensure_line "$DHCLIENT_CONF" ""
ensure_line "$DHCLIENT_CONF" "# --- managed by hardening-dns ${TS} ---"
ensure_line "$DHCLIENT_CONF" "supersede domain-name-servers 127.0.0.1;"
ensure_line "$DHCLIENT_CONF" "supersede domain-search \"\";"

# 3) Clean static DNS directives in ifupdown (/etc/network/interfaces*)
for f in /etc/network/interfaces /etc/network/interfaces.d/*; do
  [ -e "$f" ] || continue
  backup "$f"
  # Comment out dns-nameservers, dns-search, dns-domain
  sed -i -E 's/^[[:space:]]*(dns-nameservers|dns-search|dns-domain)\b/# (disabled by dns-hardening) &/I' "$f"
  log "Sanitized static DNS lines in $f"
done

# 4) NetworkManager: ignore DHCP DNS & use systemd-resolved
if systemctl list-unit-files | grep -q '^NetworkManager\.service'; then
  log "Configuring NetworkManager to ignore auto DNS and use systemd-resolved"
  NM_CONF="/etc/NetworkManager/NetworkManager.conf"
  if [ -f "$NM_CONF" ]; then backup "$NM_CONF"; fi
  mkdir -p /etc/NetworkManager/conf.d

  # Ensure dns=systemd-resolved in main config
  if ! grep -Eq '^\s*dns\s*=\s*systemd-resolved\b' "$NM_CONF" 2>/dev/null; then
    if ! grep -Eq '^\[main\]' "$NM_CONF" 2>/dev/null; then
      printf "[main]\n" >> "$NM_CONF"
    fi
    printf "dns=systemd-resolved\n" >> "$NM_CONF"
  fi

  # For all connections: ignore auto DNS
  if cmd_exists nmcli; then
    while IFS= read -r UUID; do
      [ -n "$UUID" ] || continue
      nmcli con mod "$UUID" ipv4.ignore-auto-dns yes || true
      nmcli con mod "$UUID" ipv6.ignore-auto-dns yes || true
    done < <(nmcli -t -f UUID con show | sed '/^$/d')
  else
    warn "nmcli not found, create per-connection config manually if needed."
  fi
  systemctl try-restart NetworkManager || true
else
  log "NetworkManager not detected — OK"
fi

# 5) systemd-networkd: disable LLMNR/mDNS globally; try to ignore DHCP DNS if .network files exist
NETWORKD_CONF="/etc/systemd/networkd.conf"
backup "$NETWORKD_CONF" || true
mkdir -p /etc/systemd
cat > "$NETWORKD_CONF" <<'EOF'
# Managed by dns-hardening
[Network]
LLMNR=no
MulticastDNS=no
EOF
log "Set LLMNR=no, MulticastDNS=no in $NETWORKD_CONF"

# For each existing .network, add drop-in to ignore DHCP DNS/domains
if [ -d /etc/systemd/network ]; then
  find /etc/systemd/network -maxdepth 1 -type f -name "*.network" | while read -r NETF; do
    DN="$(dirname "$NETF")/$(basename "$NETF").d"
    mkdir -p "$DN"
    cat > "$DN/10-ignore-dhcp-dns.conf" <<'EOF'
# Managed by dns-hardening
[DHCP]
UseDNS=false
UseDomains=false
EOF
    log "Added DHCP DNS ignore drop-in for $(basename "$NETF")"
  done
  # Restart networkd if it exists
  if systemctl list-unit-files | grep -q '^systemd-networkd\.service'; then
    systemctl try-restart systemd-networkd || true
  fi
fi

# 6) Configure systemd-resolved (DoT + DNSSEC + stub listener + HA DNS)
RESOLVED_CONF="/etc/systemd/resolved.conf"
backup "$RESOLVED_CONF" || true
cat > "$RESOLVED_CONF" <<'EOF'
# Managed by dns-hardening
[Resolve]
# High-availability DNS pool: Cloudflare + Google (IPv4 + IPv6)
DNS=1.1.1.1 8.8.8.8 2606:4700:4700::1111 2001:4860:4860::8888
FallbackDNS=1.0.0.1 8.8.4.4 2606:4700:4700::1001 2001:4860:4860::8844

# Force DNS-over-TLS for upstream
DNSOverTLS=yes

# Enable DNSSEC validation (set to 'allow-downgrade' if you hit broken domains)
DNSSEC=yes

# Reduce local attack surface
LLMNR=no
MulticastDNS=no

# Ensure local stub is on 127.0.0.53
DNSStubListener=yes
EOF

log "Enabling and starting systemd-resolved"
systemctl enable systemd-resolved >/dev/null 2>&1 || true
systemctl restart systemd-resolved

# 7) Ensure /etc/resolv.conf is a symlink to the stub
RESOLV_SYMLINK_TARGET="/run/systemd/resolve/stub-resolv.conf"
if [ ! -e "$RESOLV_SYMLINK_TARGET" ]; then
  # Fallback file provides full upstream list; still acceptable
  RESOLV_SYMLINK_TARGET="/run/systemd/resolve/resolv.conf"
fi

# Try to remove immutable attribute if set
if cmd_exists chattr; then
  if lsattr /etc/resolv.conf 2>/dev/null | grep -q 'i-'; then
    warn "/etc/resolv.conf is immutable; removing immutable flag"
    chattr -i /etc/resolv.conf || true
  fi
fi

if [ -L /etc/resolv.conf ]; then
  CUR_TGT="$(readlink -f /etc/resolv.conf || true)"
  if [ "$CUR_TGT" != "$RESOLV_SYMLINK_TARGET" ]; then
    backup /etc/resolv.conf
    ln -sf "$RESOLV_SYMLINK_TARGET" /etc/resolv.conf
    log "Updated /etc/resolv.conf symlink -> $RESOLV_SYMLINK_TARGET"
  else
    log "/etc/resolv.conf already points to $RESOLV_SYMLINK_TARGET"
  fi
else
  backup /etc/resolv.conf
  ln -sf "$RESOLV_SYMLINK_TARGET" /etc/resolv.conf
  log "Linked /etc/resolv.conf -> $RESOLV_SYMLINK_TARGET"
fi

# 8) Check for port 53 conflicts on 127.0.0.53 (should be used by systemd-resolved)
if cmd_exists ss; then
  if ss -ltnp | grep -E '(:53\s)' | grep -v systemd-resolved >/dev/null 2>&1; then
    warn "Detected other process listening on TCP/53. This may conflict with systemd-resolved stub."
    ss -ltnp | grep -E '(:53\s)' || true
  fi
  if ss -lunp | grep -E '(:53\s)' | grep -v systemd-resolved >/dev/null 2>&1; then
    warn "Detected other process listening on UDP/53."
    ss -lunp | grep -E '(:53\s)' || true
  fi
fi

# 9) Flush caches and show status
resolvectl flush-caches || true

log "=== Final status (resolvectl) ==="
if cmd_exists resolvectl; then
  resolvectl status || true
else
  systemd-resolve --status || true
fi

log "=== Quick tests ==="
if cmd_exists dig; then
  log "dig @127.0.0.53 example.com +adflag +dnssec +tls-ca => (AD flag expected when validated)"
  dig @127.0.0.53 example.com +adflag +dnssec +timeout=3 || true
else
  log "Install 'dnsutils' to run 'dig' tests: apt-get update && apt-get install -y dnsutils"
fi

log "Done. If any connection manager re-applies DNS, reboot once or share the logs above."
