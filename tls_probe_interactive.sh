#!/usr/bin/env bash
# 交互式 TLS/HTTP2/X25519/OCSP 探测（兼容多种 OpenSSL 输出）
set -euo pipefail

BOLD=$(printf '\033[1m'); GREEN=$(printf '\033[32m'); RED=$(printf '\033[31m'); YELLOW=$(printf '\033[33m'); DIM=$(printf '\033[2m'); RESET=$(printf '\033[0m')
ok(){ echo -e "${GREEN}OK${RESET}   - $*"; }
no(){ echo -e "${RED}NO${RESET}   - $*"; }
warn(){ echo -e "${YELLOW}WARN${RESET} - $*"; }

echo -e "${DIM}OpenSSL: $(openssl version 2>/dev/null || echo 'not found')${RESET}"

read -rp "请输入域名（必填）: " DOMAIN
[[ -z "${DOMAIN}" ]] && { echo "域名不能为空"; exit 1; }
read -rp "端口（默认443）: " PORT; PORT=${PORT:-443}

echo
echo -e "${BOLD}=== 目标：${DOMAIN}:${PORT} ===${RESET}"
echo

########################################
# TLS 1.3
########################################
echo -e "${BOLD}>>> 检测 TLS 1.3 支持${RESET}"
TLS13_RAW=$(openssl s_client -connect "${DOMAIN}:${PORT}" -servername "${DOMAIN}" -tls1_3 </dev/null 2>&1 || true)
# 兼容多种输出：Protocol  : TLSv1.3 / Protocol version: TLSv1.3 / New, TLSv1.3, ...
if echo "$TLS13_RAW" | grep -Eiq 'TLSv?1[._ ]?3'; then
  ok "支持 TLS 1.3（匹配到 TLSv1.3）"
else
  if echo "$TLS13_RAW" | grep -Eiq 'unknown option|-tls1_3'; then
    warn "你的 OpenSSL 可能太旧，无法使用 -tls1_3 选项"
  else
    no "未匹配到 TLS1.3（可能握手失败或被降级）"
  fi
fi
echo "$TLS13_RAW" | sed -n '1,18p'
echo

########################################
# HTTP/2 (h2) via ALPN/NPN on TLS1.3/1.2
########################################
check_h2() {
  local proto_flag="$1"    # -tls1_3 或 -tls1_2
  local label="$2"         # 显示标签
  local out
  out=$(openssl s_client -connect "${DOMAIN}:${PORT}" -servername "${DOMAIN}" ${proto_flag} -alpn h2 </dev/null 2>&1 || true)
  if echo "$out" | grep -Eiq 'ALPN protocol: *h2'; then
    echo "h2(${label} ALPN): YES"; echo "$out" | sed -n '1,14p'; return 0
  fi
  # 旧环境尝试 NPN（已废弃，但有些老栈还显示 next protocol）
  if echo "$out" | grep -Eiq 'Next protocol|NPN.*h2'; then
    echo "h2(${label} NPN): YES"; echo "$out" | sed -n '1,14p'; return 0
  fi
  echo "h2(${label}): NO"; echo "$out" | sed -n '1,14p'; return 1
}

echo -e "${BOLD}>>> 检测 HTTP/2 (h2) 协商${RESET}"
H2_ANY=1
check_h2 -tls1_3 "TLS1.3" && H2_ANY=0
echo
check_h2 -tls1_2 "TLS1.2" && H2_ANY=0 || true
echo
if [[ $H2_ANY -eq 0 ]]; then
  ok "支持 HTTP/2（至少在一种协议下协商到 h2）"
else
  no "未协商到 h2（可能仅支持 h3 或仅 http/1.1；或需特定 SNI/节点）"
fi
echo

########################################
# X25519
########################################
echo -e "${BOLD}>>> 检测 X25519（TLS1.3 下仅给 X25519 候选）${RESET}"
X25519_RAW=$(openssl s_client -connect "${DOMAIN}:${PORT}" -servername "${DOMAIN}" -tls1_3 -groups X25519 </dev/null 2>&1 || true)
# OpenSSL 不同版本可能打印：Server Temp Key: X25519 / key exchange: X25519 / Kx= X25519
if echo "$X25519_RAW" | grep -Eiq 'X25519'; then
  ok "支持 X25519（握手输出包含 X25519）"
else
  if echo "$X25519_RAW" | grep -Eiq 'no shared (groups|curves)|handshake failure'; then
    no "不支持 X25519（或未能达成共享曲线）"
  else
    warn "未检测到 X25519 关键字（可能被选了其他曲线）"
  fi
fi
echo "$X25519_RAW" | sed -n '1,18p'
echo

########################################
# OCSP Stapling
########################################
echo -e "${BOLD}>>> 检测 OCSP Stapling（装订）${RESET}"
OCSP_BLOCK=$(echo QUIT | openssl s_client -connect "${DOMAIN}:${PORT}" -servername "${DOMAIN}" -tls1_3 -status 2>/dev/null | sed -n '/OCSP response:/,/---/p' || true)
if [[ -n "$OCSP_BLOCK" ]] && echo "$OCSP_BLOCK" | grep -Eiq 'OCSP Response Status: *successful'; then
  ok "已启用 OCSP Stapling（且响应成功）"
  echo "$OCSP_BLOCK"
elif [[ -n "$OCSP_BLOCK" ]] && echo "$OCSP_BLOCK" | grep -Eiq 'no response sent'; then
  no "未启用 OCSP Stapling（未装订响应）"
  echo "$OCSP_BLOCK"
else
  warn "未检测到装订响应（可能未启用或当下节点未返回）"
  [[ -n "$OCSP_BLOCK" ]] && echo "$OCSP_BLOCK"
fi

echo
echo -e "${DIM}提示：CDN/多活/IPv4/IPv6 节点可能配置不同；如需分别测试，可改用具体 IP 连接，同时保留 -servername 域名以确保证书与 ALPN 正确。${RESET}"
