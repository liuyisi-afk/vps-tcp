#!/bin/bash

# 检查是否有 root 权限
if [ "$EUID" -ne 0 ]; then
  echo "请使用 root 权限运行此脚本。"
  exit 1
fi

# 配置文件路径
DNS_CONFIG_FILE="/etc/resolv.conf"

# 查询 IP 的地理位置
get_geo_info() {
  local ip="$1"
  # 使用 ipinfo.io 或者其他免费 API 获取地理信息
  local geo_info
  geo_info=$(curl -s "https://ipinfo.io/$ip/json" | jq -r '.country')
  echo "$geo_info"
}

# 修改 DNS 配置
set_dns() {
  local dns1="$1"
  local dns2="$2"
  local dns3="$3"

  # 备份原配置
  cp $DNS_CONFIG_FILE "${DNS_CONFIG_FILE}.bak"

  # 写入新的 DNS 配置
  cat > $DNS_CONFIG_FILE <<EOF
nameserver $dns1
nameserver $dns2
nameserver $dns3
EOF

  echo "DNS 已修改为: $dns1, $dns2, $dns3"
}

# 获取当前 IP
current_ip=$(curl -s https://ipinfo.io/ip)

if [ -z "$current_ip" ]; then
  echo "无法获取当前 IP 地址，请检查网络连接。"
  exit 1
fi

# 获取地理位置
geo_info=$(get_geo_info "$current_ip")

# 根据地理位置修改 DNS
case "$geo_info" in
  "TW"|"JP"|"HK")
    set_dns "154.12.177.22" "8.8.8.8" "1.1.1.1"
    ;;
  "SG")
    set_dns "157.20.104.47" "8.8.8.8" "1.1.1.1"
    ;;
  *)
    echo "当前 IP ($current_ip) 不属于指定区域，DNS 未修改。"
    ;;
esac
