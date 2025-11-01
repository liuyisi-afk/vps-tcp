#!/usr/bin/env bash
# 交互式 TLS/HTTP2/X25519/OCSP/Hybrid(KEM) 探测
# 支持直接粘贴 URL（自动提取主机名，如 https://www.bilibili.com/video/... -> www.bilibili.com）
set -euo pipefail

BOLD=$(printf '\033[1m'); GREEN=$(printf '\033[32m'); RED=$(printf '\033[31m'); YELLOW=$(printf '\033[33m'); DIM=$(printf '\033[2m'); RESET=$(printf '\033[0m')
ok(){ echo -e "${GREEN}OK${RESET}   - $*"; }
no(){ echo -e "${RED}NO${RESET}   - $*"; }
warn(){ echo -e "${YELLOW}WARN${RESET} - $*"; }

echo -e "${DIM}OpenSSL: $(openssl version 2>/dev/null || echo 'not found')${RESET}"
if command -v bssl >/dev/null 2>&1; then
  echo -e "${DIM}BoringSSL: $(bssl version 2>/dev/null || echo 'found')${RESET}"
fi

########################################
# 读取并规范化输入（可输入域名、带端口的主机名、或完整 URL）
########################################
read -rp "请输入要检测的域名或完整URL（必填）: " RAW_INPUT
[[ -z "${RAW_INPUT}" ]] && { echo "输入不能为空"; exit 1; }

read -rp "端口（留空自动：URL含端口则用之，否则443）: " PORT_INPUT

# 去掉前后空白
RAW_INPUT=$(echo "$RAW_INPUT" | awk '{$1=$1;print}')

# 1) 如果是 URL，剥离 scheme 与 path，仅保留 host[:port]
HOSTPORT=$(echo "$RAW_INPUT" | sed -E 's#^[[:space:]]*##; s#[[:space:]]*$##; s#^[a-zA-Z][a-zA-Z0-9+.-]*://##; s#/.*$##')

# 2) 如果用户直接给了 host[:port]，上面的处理也不会破坏
# 兼容 IPv6 [::1]:443 的形式（如果用户这么写）
if [[ "$HOSTPORT" =~ ^\[.*\](:[0-9]+)?$ ]]; then
  HOST=$(echo "$HOSTPORT" | sed -E 's#^\[([0-9a-fA-F:]+)\].*#\1#')
  PORT_FROM_INPUT=$(echo "$HOSTPORT" | sed -nE 's#^\[[0-9a-fA-F:]+\]:([0-9]+)$#\1#p')
else
  HOST=$(echo "$HOSTPORT" | sed -E 's#:.*$##')
  PORT_FROM_INPUT=$(echo "$HOSTPORT" | sed -nE 's#^.*:([0-9]+)$#\1#p')
fi

# 3) 端口优先级：显式输入 > URL/host里带的 > 默认443
PORT="${PORT_INPUT:-${PORT_FROM_INPUT:-443}}"

# 4) SNI 一律使用提取到的主机名（若是IP，也照样带上原 host 作为 -servername，通常为域名时才有意义）
SNI="${HOST}"

echo
echo -e "${BOLD}=== 目标：${HOST}:${PORT}（SNI: ${SNI}） ===${RESET}"
echo

# 结果收集
TLS13_RESULT="未知"
H2_TLS13_RESULT="未知"
H2_TLS12_RESULT="未知"
H2_ANY_RESULT="未知"
X25519_RESULT="未知"
HYBRID_RESULT="未知"   # X25519+MLKEM768（Kyber768）
OCSP_RESULT="未知"

########################################
# 1) TLS 1.3 支持探测（决定后续优先协议）
########################################
echo -e "${BOLD}>>> 检测 TLS 1.3 支持${RESET}"
TLS13_RAW=$(openssl s_client -connect "${HOST}:${PORT}" -servername "${SNI}" -tls1_3 </dev/null 2>&1 || true)
if echo "$TLS13_RAW" | grep -Eiq 'TLSv?1[._ ]?3'; then
  ok "支持 TLS 1.3"
  TLS13_RESULT="支持"
  PREFERRED_PROTO="-tls1_3"
else
  if echo "$TLS13_RAW" | grep -Eiq 'unknown option|-tls1_3'; then
    warn "你的 OpenSSL 可能太旧，无法使用 -tls1_3 选项"
  else
    no "未匹配到 TLS1.3（可能握手失败或被降级）"
  fi
  TLS13_RESULT=${TLS13_RESULT:-"不支持/失败"}
  PREFERRED_PROTO="-tls1_2"   # 自动退回 1.2 供后续使用
fi
echo "$TLS13_RAW" | sed -n '1,18p'
echo

########################################
# 2) HTTP/2 (h2) 协商（同时试 1.3 与 1.2）
########################################
check_h2() {
  local flag="$1"; local label="$2"
  local out; out=$(openssl s_client -connect "${HOST}:${PORT}" -servername "${SNI}" ${flag} -alpn h2 </dev/null 2>&1 || true)
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
# 3) X25519 / 混合 KEM（自适应 1.3/1.2）
########################################
echo -e "${BOLD}>>> 检测 X25519 支持（自适应 TLS 版本）${RESET}"
if [[ "$PREFERRED_PROTO" == "-tls1_3" ]]; then
  X25519_RAW=$(openssl s_client -connect "${HOST}:${PORT}" -servername "${SNI}" -tls1_3 -groups X25519 </dev/null 2>&1 || true)
else
  X25519_RAW=$(openssl s_client -connect "${HOST}:${PORT}" -servername "${SNI}" -tls1_2 -curves X25519 </dev/null 2>&1 || true)
fi
if echo "$X25519_RAW" | grep -Eiq 'X25519'; then
  ok "支持 X25519"
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

# 初步侦测是否为 X25519+MLKEM768（Kyber768）混合
TLS_ALL="$TLS13_RAW
$X25519_RAW"
if echo "$TLS_ALL" | grep -Eiq '(MLKEM|Kyber).*(X25519)|X25519.*(MLKEM|Kyber)|X25519(Kyber|MLKEM)768|mlkem768x25519'; then
  ok "侦测到混合密钥交换：X25519+MLKEM-768（Kyber-768）"
  HYBRID_RESULT="是（X25519+MLKEM768）"
else
  if command -v bssl >/dev/null 2>&1; then
    echo -e "${BOLD}>>> 追加 bssl 检测混合组${RESET}"
    BSSL_OUT=$(echo | bssl client -connect "${HOST}:${PORT}" -servername "${SNI}" 2>&1 || true)
    echo "$BSSL_OUT" | sed -n '1,25p'
    if echo "$BSSL_OUT" | grep -Eiq 'X25519(Kyber|MLKEM)768|MLKEM|Kyber'; then
      ok "bssl 识别到 X25519+MLKEM-768（或 Kyber-768）"
      HYBRID_RESULT="是（bssl识别）"
    else
      warn "未从 bssl 输出识别到混合组关键字"
      HYBRID_RESULT="未知（客户端未显示）"
    fi
  else
    warn "未识别到混合组关键字；可能是纯 X25519，或 OpenSSL 未显示混合组名"
    HYBRID_RESULT="未知（客户端未显示）"
  fi
fi
echo

########################################
# 4) OCSP Stapling（用可用协议；若无则双试）
########################################
echo -e "${BOLD}>>> 检测 OCSP Stapling（装订）${RESET}"
OCSP_PROTO=$PREFERRED_PROTO
OCSP_BLOCK=$(echo QUIT | openssl s_client -connect "${HOST}:${PORT}" -servername "${SNI}" ${OCSP_PROTO} -status 2>/dev/null | sed -n '/OCSP response:/,/---/p' || true)
if [[ -z "$OCSP_BLOCK" ]]; then
  ALT_PROTO=$([[ "$PREFERRED_PROTO" == "-tls1_3" ]] && echo "-tls1_2" || echo "-tls1_3")
  OCSP_BLOCK=$(echo QUIT | openssl s_client -connect "${HOST}:${PORT}" -servername "${SNI}" ${ALT_PROTO} -status 2>/dev/null | sed -n '/OCSP response:/,/---/p' || true)
fi
if [[ -n "$OCSP_BLOCK" ]] && echo "$OCSP_BLOCK" | grep -Eiq 'OCSP Response Status: *successful'; then
  ok "已启用 OCSP Stapling（且响应成功）"; OCSP_RESULT="已启用"; echo "$OCSP_BLOCK"
elif [[ -n "$OCSP_BLOCK" ]] && echo "$OCSP_BLOCK" | grep -Eiq 'no response sent'; then
  no "未启用 OCSP Stapling（未装订响应）"; OCSP_RESULT="未启用"; echo "$OCSP_BLOCK"
else
  warn "未检测到装订响应（可能未启用或当下节点未返回）"; OCSP_RESULT="未检测到"; [[ -n "$OCSP_BLOCK" ]] && echo "$OCSP_BLOCK"
fi
echo

echo -e "${DIM}提示：CDN/多活/IPv4/IPv6 节点可能配置不同；如需分别测试，可改用具体 IP 连接，同时保留 -servername 域名以确保证书与 ALPN 正确。${RESET}"
echo

########################################
# 运行结果汇总
########################################
echo -e "${BOLD}=== 运行结果汇总 ===${RESET}"
printf " %-22s : %s\n" "规范化主机名"          "$HOST"
printf " %-22s : %s\n" "目标端口"              "$PORT"
printf " %-22s : %s\n" "SNI(服务器名指示)"      "$SNI"
printf " %-22s : %s\n" "TLS 1.3"               "$TLS13_RESULT"
printf " %-22s : %s\n" "HTTP/2 (总)"            "$H2_ANY_RESULT"
printf " %-22s : %s\n" "  ├─TLS1.3 下 h2"       "$H2_TLS13_RESULT"
printf " %-22s : %s\n" "  └─TLS1.2 下 h2"       "$H2_TLS12_RESULT"
printf " %-22s : %s\n" "X25519"                 "$X25519_RESULT"
printf " %-22s : %s\n" "X25519+MLKEM768(混合)"  "$HYBRID_RESULT"
printf " %-22s : %s\n" "OCSP Stapling"          "$OCSP_RESULT"
echo
