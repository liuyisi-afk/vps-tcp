#!/bin/bash

# 检查是否为 root 权限运行
if [ "$EUID" -ne 0 ]; then
  echo "请以 root 权限运行此脚本。"
  exit 1
fi

# 定义目标端口
TARGET_PORT=34110
SSH_CONFIG_FILE="/etc/ssh/sshd_config"

# 修改 SSH 配置文件中的端口
echo "正在修改 SSH 配置文件：$SSH_CONFIG_FILE ..."
if grep -q "^#Port" "$SSH_CONFIG_FILE"; then
  sed -i "s/^#Port.*/Port $TARGET_PORT/" "$SSH_CONFIG_FILE"
elif grep -q "^Port" "$SSH_CONFIG_FILE"; then
  sed -i "s/^Port.*/Port $TARGET_PORT/" "$SSH_CONFIG_FILE"
else
  echo "Port $TARGET_PORT" >> "$SSH_CONFIG_FILE"
fi

echo "SSH 端口已修改为 $TARGET_PORT。"

# 安装并配置 UFW 防火墙
echo "正在安装并配置 UFW 防火墙..."
if ! command -v ufw &>/dev/null; then
  apt update && apt install -y ufw
fi

ufw allow "$TARGET_PORT"/tcp
ufw deny 22/tcp

# 启用 UFW（如果尚未启用）
ufw enable <<EOF
y
EOF

echo "UFW 防火墙已配置：允许 $TARGET_PORT，拒绝 22。"

# 重启 SSH 服务
echo "正在重启 SSH 服务..."
if systemctl restart sshd; then
  echo "SSH 服务重启成功！"
  echo "现在可以通过端口 $TARGET_PORT 使用 SSH 登录。"
else
  echo "SSH 服务重启失败，请检查配置文件是否正确。"
  exit 1
fi

# 显示防火墙状态
echo "防火墙状态："
ufw status verbose
