sudo bash << 'SCRIPT_END'
#!/usr/bin/env bash
set -euo pipefail

### =========================
### DNS 极致加固一键脚本（整合版）
### 功能：
###  - DoT 强制：DNSOverTLS=yes（证书校验，防劫持/窥探）
###  - DNSSEC：严格校验（可切 allow-downgrade 以适配受限网络）
###  - 收缩面：禁用 LLMNR / mDNS
###  - 高可用：Google + Cloudflare（含 IPv6）
###  - 可靠性：APT 锁处理 + 坏源禁用 + 临时直连 DNS 自救
### =========================

# ---- 配置参数（可按需调整） ----
TARGET_DNS=(
  "8.8.8.8#dns.google"
  "1.1.1.1#cloudflare-dns.com"
  "2001:4860:4860::8888#dns.google"
  "2606:4700:4700::1111#cloudflare-dns.com"
)
DNSSEC_MODE="yes"          # 受限网络可改 "allow-downgrade"
DOT_MODE="yes"             # 受限网络可改 "opportunistic"
RESOLVED_DROPIN="/etc/systemd/resolved.conf.d/99-hardened-dot.conf"

# ---- 彩色输出 ----
GREEN="\033[0;32m"; YELLOW="\033[1;33m"; RED="\033[0;31m"; NC="\033[0m"
log()  { echo -e "${GREEN}--> $*${NC}"; }
warn() { echo -e "${YELLOW}--> $*${NC}"; }
err()  { echo -e "${RED}--> $*${NC}" >&2; }

# ---- APT 锁处理：等待/温柔终止 ----
wait_for_apt_lock() {
  local tries=60 sleep_s=5
  local locks=(/var/lib/dpkg/lock-frontend /var/cache/apt/archives/lock)
  for ((i=1;i<=tries;i++)); do
    local busy=false
    for L in "${locks[@]}"; do
      if fuser "$L" >/dev/null 2>&1; then busy=true; fi
    done
    if ! $busy; then return 0; fi
    systemctl stop apt-daily.service apt-daily-upgrade.service unattended-upgrades.service 2>/dev/null || true
    echo -e "\e[1;33m--> APT/Dpkg 正忙（第 $i 次检查），等待 ${sleep_s}s...\e[0m"
    sleep "$sleep_s"
  done
  echo -e "\e[0;31m--> APT 锁长时间未释放，尝试温柔终止占用进程...\e[0m"
  pgrep -a 'apt|apt-get|dpkg' | sed 's/^/   /' || true
  pkill -TERM apt apt-get dpkg 2>/dev/null || true
  sleep 3
  pkill -KILL apt apt-get dpkg 2>/dev/null || true
}

# ---- 临时直连 DNS（当 stub 存在但 resolved 未运行时）----
ensure_dns_for_apt() {
  if readlink /etc/resolv.conf 2>/dev/null | grep -q 'stub-resolv.conf'; then
    if ! systemctl is-active --quiet systemd-resolved; then
      warn "检测到 stub resolv.conf 但 systemd-resolved 未运行，临时写入直连 resolv.conf 以救援 APT"
      cp -a /etc/resolv.conf /etc/resolv.conf.pre-apt.$(date +%s) 2>/dev/null || true
      printf "nameserver 8.8.8.8\nnameserver 1.1.1.1\n" > /etc/resolv.conf
    fi
  fi
}

# ---- 禁用常见第三方坏源，避免 update 卡死 ----
disable_broken_apt_sources() {
  log "检查并暂时禁用可能导致 APT 卡住的第三方源..."
  mkdir -p /etc/apt/sources.list.d/disabled
  local patterns='cloudsmith|caddy|docker|nodesource|gitlab|grafana|mongodb|elastic|postgres|hashicorp|brave|vscode|chrome|opera|mariadb|microsoft|google'
  shopt -s nullglob
  for f in /etc/apt/sources.list.d/*.list; do
    if grep -Eqi "(${patterns})" "$f"; then
      warn "禁用第三方源：$f"
      mv "$f" /etc/apt/sources.list.d/disabled/
    fi
  done
  shopt -u nullglob
  apt-get clean
}

# ---- 安全包管理封装 ----
apt_update_safe() {
  wait_for_apt_lock
  ensure_dns_for_apt
  disable_broken_apt_sources || true
  apt-get update \
    -o Acquire::ForceIPv4=true \
    -o Acquire::http::Timeout=10 \
    -o Acquire::https::Timeout=10 \
    -o Acquire::Retries=2
}

apt_install_safe() {
  wait_for_apt_lock
  ensure_dns_for_apt
  apt-get install -y "$@" \
    -o Acquire::ForceIPv4=true \
    -o Acquire::http::Timeout=10 \
    -o Acquire::https::Timeout=10 \
    -o Acquire::Retries=2
}

# ---- 前置：必须是 root ----
if [[ $EUID -ne 0 ]]; then
  err "请以 root 执行（使用 sudo）。"
  exit 1
fi

log "开始：DoT + DNSSEC + 关闭 LLMNR/mDNS + 高可用 DNS 池"

# ---- 53 端口占用提醒（不强杀）----
if command -v ss >/dev/null 2>&1; then
  if ss -lunpt 2>/dev/null | grep -qE ':(53)\s'; then
    warn "检测到本机有进程监听 53/UDP（可能 dnsmasq/bind9/unbound/Docker 自定义 DNS），可能与 systemd-resolved 冲突："
    ss -lunpt | grep -E ':(53)\s' || true
  fi
fi

# ---- 安装 / 启用 systemd-resolved ----
if ! command -v resolvectl >/dev/null 2>&1; then
  log "安装 systemd-resolved..."
  apt_update_safe
  apt_install_safe systemd-resolved
fi

# 移除 resolvconf（避免抢 /etc/resolv.conf）
if dpkg -s resolvconf >/dev/null 2>&1; then
  warn "检测到 resolvconf，准备卸载以避免冲突..."
  apt_install_safe apt-utils >/dev/null 2>&1 || true
  apt-get -y remove resolvconf || true
  rm -f /etc/resolv.conf || true
fi

log "启用并启动 systemd-resolved..."
systemctl enable systemd-resolved >/dev/null
systemctl restart systemd-resolved

# ---- 写入 drop-in 配置（DoT/DNSSEC + 禁用 LLMNR/mDNS + 全域 ~.）----
log "写入加固配置：${RESOLVED_DROPIN}"
mkdir -p /etc/systemd/resolved.conf.d
{
  echo "[Resolve]"
  echo -n "DNS="
  printf "%s " "${TARGET_DNS[@]}"
  echo
  echo "DNSSEC=${DNSSEC_MODE}"
  echo "DNSOverTLS=${DOT_MODE}"
  echo "LLMNR=no"
  echo "MulticastDNS=no"
  echo "Domains=~."
} > "${RESOLVED_DROPIN}"

# ---- 链接 stub resolv.conf 并重载 ----
log "链接 /etc/resolv.conf -> /run/systemd/resolve/stub-resolv.conf"
ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf

log "重载/重启 systemd-resolved 应用新配置..."
systemctl reload-or-restart systemd-resolved

# ---- 健康检查 ----
log "刷新本地 DNS 缓存..."
resolvectl flush-caches || true
sleep 1

echo
echo "========== resolvectl status (摘要) =========="
resolvectl status | sed -n '1,160p'
echo "=============================================="
echo

# ---- 功能性测试 ----
if ! command -v dig >/dev/null 2>&1; then
  apt_update_safe || true
  apt_install_safe dnsutils || true
fi

if command -v dig >/dev/null 2>&1; then
  log "功能测试：dig @127.0.0.53 example.com A（超时2秒，重试1次）"
  if dig @127.0.0.53 -p 53 example.com A +time=2 +tries=1 +nocmd +noall +answer; then
    log "DNS 查询成功：本地缓存已启用（后续解析更快）。"
  else
    warn "DNS 查询失败：上游可能拦截 853/TCP（DoT）。可将 DNSOverTLS 改为 opportunistic 或临时关闭再排障。"
  fi
fi

log "全部完成！已强制 DoT、开启 DNSSEC、禁用 LLMNR/mDNS、启用本地缓存，并使用 Google + Cloudflare 高可用池。"
SCRIPT_END
