bash <<'CHECK_END'
set -euo pipefail
RED='\033[0;31m'; GREEN='\033[0;32m'; YEL='\033[1;33m'; NC='\033[0m'
ok(){ echo -e "${GREEN}[OK] $*${NC}"; }
bad(){ echo -e "${RED}[FAIL] $*${NC}"; exit 1; }
warn(){ echo -e "${YEL}[WARN] $*${NC}"; }

# 1) 服务状态
systemctl is-active --quiet systemd-resolved && ok "systemd-resolved active" || bad "systemd-resolved not active"

# 2) resolv.conf 链接
target="$(readlink -f /etc/resolv.conf || true)"
echo "$target" | grep -q '/run/systemd/resolve/stub-resolv.conf' && ok "resolv.conf -> stub" || bad "resolv.conf 未指向 stub: $target"

# 3) 读取状态
s="$(resolvectl status 2>/dev/null || true)"
[[ -n "$s" ]] || bad "无法读取 resolvectl status"

# 4) 关键项
echo "$s" | grep -q 'DNS over TLS:[[:space:]]\+yes'  && ok "DoT yes"   || bad "DoT 未启用"
echo "$s" | grep -q 'DNSSEC=.*yes'                  && ok "DNSSEC yes" || bad "DNSSEC 未启用"
echo "$s" | egrep -q 'LLMNR:[[:space:]]+no|-LLMNR'  && ok "LLMNR no"   || bad "LLMNR 未关闭"
echo "$s" | egrep -q 'MulticastDNS:[[:space:]]+no|-mDNS' && ok "mDNS no" || bad "mDNS 未关闭"
echo "$s" | grep -q '8\.8\.8\.8#dns\.google'        && ok "Google DoT" || bad "未见 8.8.8.8#dns.google"
echo "$s" | grep -q '1\.1\.1\.1#cloudflare-dns\.com'&& ok "Cloudflare DoT" || bad "未见 1.1.1.1#cloudflare-dns.com"

# 5) 本地监听 53
ss -lunp 2>/dev/null | grep -q '127\.0\.0\.53:53' && ok "127.0.0.53:53 监听" || warn "未检测到本地 53 监听（可能输出格式差异）"

# 6) 功能性解析
if command -v dig >/dev/null 2>&1; then
  dig @127.0.0.53 example.com A +time=2 +tries=1 +nocmd +noall +answer >/dev/null && ok "功能查询成功" || bad "功能查询失败"
else
  warn "未安装 dig，跳过功能测试"
fi

ok "全部检查通过"
CHECK_END
