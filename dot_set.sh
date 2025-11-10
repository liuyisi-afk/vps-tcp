sudo bash << 'SCRIPT_END'
#!/usr/bin/env bash
set -euo pipefail

readonly TARGET_DNS_A="8.8.8.8#dns.google"
readonly TARGET_DNS_B="1.1.1.1#cloudflare-dns.com"
readonly TARGET_DNS="${TARGET_DNS_A} ${TARGET_DNS_B}"

readonly SECURE_RESOLVED_DROPIN="/etc/systemd/resolved.conf.d/99-hardening.conf"
readonly SECURE_RESOLVED_CONFIG="[Resolve]
DNS=${TARGET_DNS}
LLMNR=no
MulticastDNS=no
DNSSEC=allow-downgrade
DNSOverTLS=yes
"

readonly GREEN="\033[0;32m"
readonly YELLOW="\033[1;33m"
readonly RED="\033[0;31m"
readonly NC="\033[0m"
log() { echo -e "${GREEN}--> $1${NC}"; }
log_warn() { echo -e "${YELLOW}--> $1${NC}"; }
log_error() { echo -e "${RED}--> $1${NC}" >&2; }

disable_broken_apt_sources() {
  log "检查并暂时禁用可能损坏的第三方 APT 源..."
  local moved=false
  sudo mkdir -p /etc/apt/sources.list.d/disabled
  # 典型坏源：Caddy on Cloudsmith（路径/套件名不对）
  if ls /etc/apt/sources.list.d/*caddy* 1>/dev/null 2>&1; then
    while IFS= read -r -d '' f; do
      log_warn "检测到可能的 Caddy 源：$f -> 已禁用"
      sudo mv "$f" /etc/apt/sources.list.d/disabled/
      moved=true
    done < <(find /etc/apt/sources.list.d -maxdepth 1 -type f -iname '*caddy*' -print0)
  fi
  if [[ "$moved" == true ]]; then
    sudo apt-get clean
  fi
}

purify_and_harden_dns() {
  echo -e "\n--- 开始执行DNS净化与安全加固流程 ---"

  log "阶段一：正在清除所有潜在的DNS冲突源..."
  local dhclient_conf="/etc/dhcp/dhclient.conf"
  if [[ -f "$dhclient_conf" ]]; then
    if ! grep -q "ignore domain-name-servers;" "$dhclient_conf" || ! grep -q "ignore domain-search;" "$dhclient_conf"; then
      log "正在驯服 DHCP 客户端 (dhclient)..."
      {
        echo ""
        echo "ignore domain-name-servers;"
        echo "ignore domain-search;"
      } >> "$dhclient_conf"
      log "✅ 已确保 'ignore' 指令存在于 ${dhclient_conf}"
    fi
  fi

  local ifup_script="/etc/network/if-up.d/resolved"
  if [[ -f "$ifup_script" && -x "$ifup_script" ]]; then
    log "正在禁用有冲突的 if-up.d 兼容性脚本..."
    chmod -x "$ifup_script"
    log "✅ 已移除 ${ifup_script} 的可执行权限。"
  fi

  local interfaces_file="/etc/network/interfaces"
  if [[ -f "$interfaces_file" ]] && grep -qE '^[[:space:]]*dns-(nameservers|search|domain)' "$interfaces_file"; then
    log "正在净化 /etc/network/interfaces 中的残留 DNS 配置..."
    sed -i -E 's/^[[:space:]]*(dns-(nameservers|search|domain).*)/# \1/' "$interfaces_file"
    log "✅ 旧有 DNS 配置已注释。"
  fi

  log "阶段二：正在配置 systemd-resolved..."
  if ! command -v resolvectl >/dev/null 2>&1; then
    log "resolvectl 不存在，准备安装 systemd-resolved..."
    disable_broken_apt_sources
    sudo apt-get update >/dev/null
    sudo apt-get -y install systemd-resolved >/dev/null
  fi

  # 无论系统版本，只要装了 resolvconf 就移除
  if dpkg -s resolvconf >/dev/null 2>&1; then
    log "检测到会冲突的 'resolvconf'，正在卸载..."
    sudo apt-get -y remove resolvconf >/dev/null || true
    sudo rm -f /etc/resolv.conf || true
    log "✅ 'resolvconf' 已卸载。"
  fi

  log "正在启用并启动 systemd-resolved 服务..."
  sudo systemctl enable systemd-resolved >/dev/null
  sudo systemctl restart systemd-resolved

  log "写入 drop-in 配置并开启 DoT/DNSSEC..."
  sudo mkdir -p /etc/systemd/resolved.conf.d
  echo -e "${SECURE_RESOLVED_CONFIG}" | sudo tee "${SECURE_RESOLVED_DROPIN}" >/dev/null

  # 链接 stub resolv.conf（127.0.0.53）
  sudo ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf

  sudo systemctl reload-or-restart systemd-resolved
  sleep 1

  log "阶段三：正在安全地重启网络服务以应用所有更改..."
  if systemctl is-enabled --quiet networking.service 2>/dev/null; then
    sudo systemctl restart networking.service || log_warn "networking.service 重启失败（可能未使用 ifupdown），忽略。"
  fi

  echo -e "\n${GREEN}✅ 基础配置完成，开始校验...${NC}"

  # 刷新缓存并获取状态
  resolvectl flush-caches || true
  local st; st="$(resolvectl status || true)"

  # 校验目标 DNS（集合包含即可，不做行序精确匹配）
  local ok_dns=true
  grep -q "${TARGET_DNS_A}" <<<"$st" || ok_dns=false
  grep -q "${TARGET_DNS_B}" <<<"$st" || ok_dns=false

  # 关键安全标志
  local ok_flags=true
  grep -q "DNSSEC=allow-downgrade" <<<"$st" || ok_flags=false
  grep -Eq "DNS over TLS:[[:space:]]+yes|DNSOverTLS[[:space:]]*=[[:space:]]*yes" <<<"$st" || ok_flags=false
  grep -Eq "LLMNR:[[:space:]]+no|LLMNR setting:[[:space:]]+no|-LLMNR" <<<"$st" || ok_flags=false
  grep -Eq "MulticastDNS:[[:space:]]+no|mDNS[[:space:]]+no|-mDNS" <<<"$st" || ok_flags=false

  if [[ "$ok_dns" == true && "$ok_flags" == true ]]; then
    log "✅ 实时配置与安全目标一致。"
  else
    log_warn "部分状态未达标，当前摘要："
    echo "$st" | sed -n '1,140p'
  fi

  # 功能性探测（不作为失败条件）
  command -v dig >/dev/null 2>&1 || sudo apt-get -y install dnsutils >/dev/null 2>&1 || true
  (dig +time=2 +tries=1 example.com A >/dev/null 2>&1 && log "功能性查询 OK（example.com）") || log_warn "功能性查询失败（可能网络限制/防火墙）。"

  echo -e "\n${GREEN}✅ DNS净化脚本执行完成${NC}"
  echo "===================================================="
  echo "$st" | sed -n '1,200p'
  echo "===================================================="
  echo -e "贡献者：NSdesk（经增强与兼容性修订）"
  echo -e "注：若在酒店/企业网，DoT 可能被拦截；必要时将 DNSOverTLS 调整为 opportunistic 或临时注释。"
}

main() {
  if [[ $EUID -ne 0 ]]; then
    log_error "错误: 此脚本必须以 root 运行。请使用 'sudo'。"
    exit 1
  fi

  echo "--- 开始执行全面系统DNS健康检查 ---"
  local is_perfect=true

  echo -n "1. 检查 systemd-resolved 实时状态... "
  if ! command -v resolvectl >/dev/null 2>&1 || ! resolvectl status >/dev/null 2>&1; then
    echo -e "${YELLOW}服务未运行或无响应。${NC}"
    is_perfect=false
  else
    local status_output; status_output="$(resolvectl status || true)"
    local ok=true
    grep -q "DNSSEC=allow-downgrade" <<<"$status_output" || ok=false
    grep -Eq "DNS over TLS:[[:space:]]+yes|DNSOverTLS[[:space:]]*=[[:space:]]*yes" <<<"$status_output" || ok=false
    grep -q "${TARGET_DNS_A}" <<<"$status_output" || ok=false
    grep -q "${TARGET_DNS_B}" <<<"$status_output" || ok=false
    grep -Eq "LLMNR:[[:space:]]+no|LLMNR setting:[[:space:]]+no|-LLMNR" <<<"$status_output" || ok=false
    grep -Eq "MulticastDNS:[[:space:]]+no|mDNS[[:space:]]+no|-mDNS" <<<"$status_output" || ok=false

    if [[ "$ok" == true ]]; then
      echo -e "${GREEN}配置正确。${NC}"
    else
      echo -e "${YELLOW}实时配置与安全目标不符。${NC}"
      is_perfect=false
    fi
  fi

  echo -n "2. 检查 dhclient.conf 配置... "
  local dhclient_conf="/etc/dhcp/dhclient.conf"
  if [[ -f "$dhclient_conf" ]]; then
    if grep -q "ignore domain-name-servers;" "$dhclient_conf" && grep -q "ignore domain-search;" "$dhclient_conf"; then
      echo -e "${GREEN}已净化。${NC}"
    else
      echo -e "${YELLOW}未发现 'ignore' 净化参数。${NC}"
      is_perfect=false
    fi
  else
    echo -e "${GREEN}文件不存在，无需净化。${NC}"
  fi

  echo -n "3. 检查 if-up.d 冲突脚本... "
  local ifup_script="/etc/network/if-up.d/resolved"
  if [[ ! -f "$ifup_script" || ! -x "$ifup_script" ]]; then
    echo -e "${GREEN}已禁用或不存在。${NC}"
  else
    echo -e "${YELLOW}脚本存在且可执行。${NC}"
    is_perfect=false
  fi

  if [[ "$is_perfect" == true ]]; then
    echo -e "\n${GREEN}✅ 全面检查通过！系统DNS配置稳定且安全。无需任何操作。${NC}"
    echo -e "贡献者：NSdesk（经增强与兼容性修订）"
    exit 0
  else
    echo -e "\n${YELLOW}--> 一项或多项检查未通过。为了确保系统的长期稳定，将执行完整的净化与加固流程...${NC}"
    purify_and_harden_dns
  fi
}

main "$@"
SCRIPT_END
