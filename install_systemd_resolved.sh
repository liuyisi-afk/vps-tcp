#!/usr/bin/env bash
set -euo pipefail

echo "=== 检查是否是 systemd 系统 ==="
PID1_COMM="$(ps -p 1 -o comm= || echo unknown)"

if [ "$PID1_COMM" != "systemd" ]; then
    echo "当前 PID 1 是: $PID1_COMM"
    echo "这通常说明你在容器/chroot 里，或者不是用 systemd 做 init。"
    echo "这种环境下不适合用 systemd-resolved，当时我给你的静态 /etc/resolv.conf 脚本更合适。"
    exit 1
fi

echo
echo "=== 更新 apt 软件源并安装 systemd-resolved ==="
apt update
apt install -y systemd-resolved

echo
echo "=== 启用并启动 systemd-resolved ==="
systemctl enable systemd-resolved.service
systemctl restart systemd-resolved.service

echo
echo "=== 配置自定义 DNS (8.8.8.8, 1.1.1.1, 2001:4860:4860::8888, 2001:4860:4860::8844) ==="
mkdir -p /etc/systemd/resolved.conf.d

cat > /etc/systemd/resolved.conf.d/99-custom-dns.conf << 'EOF'
[Resolve]
DNS=8.8.8.8 1.1.1.1 2001:4860:4860::8888 2001:4860:4860::8844
FallbackDNS=
DNSOverTLS=no
DNSSEC=no
EOF

echo "已写入 /etc/systemd/resolved.conf.d/99-custom-dns.conf"

echo
echo "=== 确保 /etc/resolv.conf 交给 systemd-resolved 管理 ==="
# 安装 systemd-resolved 时通常会自动处理这一点，但我们再检查一下
STUB_PATH="/run/systemd/resolve/stub-resolv.conf"
ALT_PATH="/run/systemd/resolve/resolv.conf"

if [ -e /etc/resolv.conf ] && [ ! -L /etc/resolv.conf ]; then
    BACKUP="/etc/resolv.conf.bak.$(date +%F_%H-%M-%S)"
    echo "备份原来的 /etc/resolv.conf -> $BACKUP"
    mv /etc/resolv.conf "$BACKUP"
fi

if [ -f "$STUB_PATH" ]; then
    ln -sf "$STUB_PATH" /etc/resolv.conf
    echo "/etc/resolv.conf -> $STUB_PATH"
elif [ -f "$ALT_PATH" ]; then
    ln -sf "$ALT_PATH" /etc/resolv.conf
    echo "/etc/resolv.conf -> $ALT_PATH"
else
    echo "警告: 找不到 systemd-resolved 生成的 resolv.conf 文件，请稍后手动检查。"
fi

echo
echo "=== 重启 systemd-resolved 应用新的 DNS 配置 ==="
systemctl restart systemd-resolved.service

echo
echo "=== 当前 DNS 状态(resolvectl status) ==="
if command -v resolvectl >/dev/null 2>&1; then
    resolvectl status
else
    echo "systemd-resolved 已安装，但没找到 resolvectl 命令（一般会一起装上）。"
fi

echo
echo "完成：systemd-resolved 已安装并启用，上游 DNS 为 8.8.8.8 / 1.1.1.1 / IPv6 2001:4860:4860::8888 / ::8844。"
