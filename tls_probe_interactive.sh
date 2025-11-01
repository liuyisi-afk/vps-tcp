#!/usr/bin/env bash
# 交互式 TLS/HTTP2/X25519/OCSP/Hybrid(KEM) 探测
set -euo pipefail

BOLD=$(printf '\033[1m'); GREEN=$(printf '\033[32m'); RED=$(printf '\033[31m'); YELLOW=$(printf '\033[33m'); DIM=$(printf '\033[2m'); RESET=$(printf '\033[0m')
ok(){ echo -e "${GREEN}OK${RESET}   - $*"; }
no(){ echo -e "${RED}NO${RESET}   - $*"; }
warn(){ echo -e "${YELLOW}WARN${RESET} - $*"; }

echo -e "${DIM}OpenSSL: $(openssl version 2>/dev/null || echo 'not found')${RESET}"
if command -v bssl >/dev/null 2>&1; then
  echo -e "${DIM}BoringSSL: $(bssl version 2>/dev/null || echo 'found')${RESET}"
fi

read -rp "请输入域名（必填）: " DOMAIN
[[ -z "${DOMAIN}" ]] && { echo "域名不能为空"; exit 1; }
read -rp "端口（默认443）: " PORT; PORT=${PORT:-443}

echo
echo -e "${BOLD}=== 目标：${DOMAIN}:${PORT} ===${RESET}"
echo

# 结果收集
TLS13_RESULT="未知"
H2_TLS13_RESULT="未知"
H2_TLS12_RESULT="未知"
H2_ANY_RESULT="未知"
X25519_RESULT="未知"
OCSP_RESULT="未知"
HYBRID_RESULT="未知"   # X25519+MLKEM768（Kyber768）混合

########################################
# TLS 1.3
########################################
echo -e "${BOLD}>>> 检测 TLS 1.3 支持${RESET}"
TLS13_RAW=$(openssl s_client -connect "${DOMAIN}:${PORT}" -servername "${DOMAIN}" -tls1_3 </dev/null 2>&1 || true)
if echo "$TLS13_RAW" | grep -Eiq 'TLSv?1[._ ]?3'; then
  ok "支持 TLS 1.3（匹配到 TLSv1.3）"
  TLS13_RESULT="支持"
else
  if echo "$TLS13_RAW" | grep -Eiq 'unknown option|-tls1_3'; then
    warn "你的 OpenSSL 可能太旧，无法使用 -tls1_3 选项"
    TLS13_RESULT="无法检测（OpenSSL过旧）"
  else
    no "未匹配到 TLS1.3（可能握手失败或被降级）"
    TLS13_RESULT="不支持/失败"
  fi
fi
echo "$TLS13_RAW" | sed -n '1,18p'
echo

########################################
# HTTP/2 (h2) via ALPN/NPN on TLS1.3/1.2
########################################
check_h2() {
  local proto_flag="$1"    # -tls1_3 或 -tls1_2
  local label="$2"
  local out
  out=$(openssl s_client -connect "${DOMAIN}:${PORT}" -servername "${DOMAIN}" ${proto_flag} -alpn h2 </dev/null 2>&1 || true)
  if echo "$out" | grep -Eiq 'ALPN protocol: *h2'; then
    echo "h2(${label} ALPN): YES"; echo "$out" | sed -n '1,14p'; return 0
  fi
  if echo "$out" | grep -Eiq 'Next protocol|NPN.*h2'; then
    echo "h2(${label} NPN): YES"; echo "$out" | sed -n '1,14p'; return 0
  fi
  echo "h2(${label}): NO"; echo "$out" | sed -n '1,14p'; return 1
}

echo -e "${BOLD}>>> 检测 HTTP/2 (h2) 协商${RESET}"
H2_ANY=1
if check_h2 -tls1_3 "TLS1.3"; then H2_TLS13_RESULT="支持"; H2_ANY=0; else H2_TLS13_RESULT="未协商"; fi
echo
if check_h2 -tls1_2 "TLS1.2"; then H2_TLS12_RESULT="支持"; H2_ANY=0; else H2_TLS12_RESULT="未协商"; fi
echo
if [[ $H2_ANY -eq 0 ]]; then H2_ANY_RESULT="支持"; ok "整体：支持 HTTP/2"; else H2_ANY_RESULT="未协商"; no "整体：未协商到 h2"; fi
echo

########################################
# X25519（以及混合 KEM 线索）
########################################
echo -e "${BOLD}>>> 检测 X25519（TLS1.3 下仅给 X25519 候选）${RESET}"
X25519_RAW=$(openssl s_client -connect "${DOMAIN}:${PORT}" -servername "${DOMAIN}" -tls1_3 -groups X25519 </dev/null 2>&1 || true)

if echo "$X25519_RAW" | grep -Eiq 'X25519'; then
  ok "支持 X25519（握手输出包含 X25519）"
  X25519_RESULT="支持"
else
  if echo "$X25519_RAW" | grep -Eiq 'no shared (groups|curves)|handshake failure'; then
    no "不支持 X25519（或未能达成共享曲线）"
    X25519_RESULT="不支持/失败"
  else
    warn "未检测到 X25519 关键字（可能被选了其他曲线）"
    X25519_RESULT="未检测到"
  fi
fi
echo "$X25519_RAW" | sed -n '1,20p'
echo

# 初步判定是否为“X25519 + MLKEM-768（Kyber-768）”混合：
# 各实现可能打印的关键字：MLKEM, Kyber, Kyber768, ML-KEM-768, X25519Kyber768, X25519MLKEM768, mlkem768x25519
if echo "$TLS13_RAW" "$X25519_RAW" | grep -Eiq '(MLKEM|Kyber).*(X25519)|X25519.*(MLKEM|Kyber)|X25519(Kyber|MLKEM)768|mlkem768x25519'; then
  ok "侦测到混合密钥交换：X25519 + MLKEM-768（Kyber-768）"
  HYBRID_RESULT="是（X25519+MLKEM768）"
else
  # 若 openssl 看不到混合组名，但确实想更稳地判断，尝试用 bssl 辅助（若存在）
  if command -v bssl >/dev/null 2>&1; then
    echo -e "${BOLD}>>> 追加：使用 bssl 辅助判断混合组${RESET}"
    # bssl 一般会打印 "Group: X25519Kyber768" 或类似文案
    BSSL_OUT=$(echo | bssl client -connect "${DOMAIN}:${PORT}" -servername "${DOMAIN}" 2>&1 || true)
    echo "$BSSL_OUT" | sed -n '1,25p'
    if echo "$BSSL_OUT" | grep -Eiq 'X25519(Kyber|MLKEM)768|MLKEM|Kyber'; then
      ok "bssl 显示为 X25519+MLKEM-768（或 Kyber-768）"
      HYBRID_RESULT="是（bssl识别）"
    else
      warn "未从 bssl 输出中识别到混合组关键字"
      HYBRID_RESULT="未知（客户端未显示）"
    fi
  else
    warn "未识别到混合组关键字；可能是纯 X25519，或 OpenSSL 未显示混合组名"
    HYBRID_RESULT="未知（客户端未显示）"
  fi
fi
echo

########################################
# OCSP Stapling
########################################
echo -e "${BOLD}>>> 检测 OCSP Stapling（装订）${RESET}"
OCSP_BLOCK=$(echo QUIT | openssl s_client -connect "${DOMAIN}:${PORT}" -servername "${DOMAIN}" -tls1_3 -status 2>/dev/null | sed -n '/OCSP response:/,/---/p' || true)
if [[ -n "$OCSP_BLOCK" ]] && echo "$OCSP_BLOCK" | grep -Eiq 'OCSP Response Status: *successful'; then
  ok "已启用 OCSP Stapling（且响应成功）"
  OCSP_RESULT="已启用"
  echo "$OCSP_BLOCK"
elif [[ -n "$OCSP_BLOCK" ]] && echo "$OCSP_BLOCK" | grep -Eiq 'no response sent'; then
  no "未启用 OCSP Stapling（未装订响应）"
  OCSP_RESULT="未启用"
  echo "$OCSP_BLOCK"
else
  warn "未检测到装订响应（可能未启用或当下节点未返回）"
  OCSP_RESULT="未检测到"
  [[ -n "$OCSP_BLOCK" ]] && echo "$OCSP_BLOCK"
fi

echo
echo -e "${DIM}提示：CDN/多活/IPv4/IPv6 节点可能配置不同；如需分别测试，可改用具体 IP 连接，同时保留 -servername 域名以确保证书与 ALPN 正确。${RESET}"
echo

########################################
# 运行结果汇总
########################################
echo -e "${BOLD}=== 运行结果汇总 ===${RESET}"
printf " %-20s : %s\n" "TLS 1.3"                 "$TLS13_RESULT"
printf " %-20s : %s\n" "HTTP/2 (总)"              "$H2_ANY_RESULT"
printf " %-20s : %s\n" "  ├─TLS1.3 下 h2"         "$H2_TLS13_RESULT"
printf " %-20s : %s\n" "  └─TLS1.2 下 h2"         "$H2_TLS12_RESULT"
printf " %-20s : %s\n" "X25519"                   "$X25519_RESULT"
printf " %-20s : %s\n" "X25519+MLKEM768(混合)"    "$HYBRID_RESULT"
printf " %-20s : %s\n" "OCSP Stapling"            "$OCSP_RESULT"
echo
