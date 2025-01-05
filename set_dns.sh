#!/bin/bash

# 确保以 root 用户权限运行
if [ "$EUID" -ne 0 ]; then
  echo "请使用 root 权限运行此脚本。"
  exit 1
fi

# 定义脚本路径
DNS_SCRIPT_PATH="/usr/local/bin/set_dns.sh"
SERVICE_FILE="/etc/systemd/system/set_dns.service"

# 检查或下载 set_dns.sh 脚本
if [ ! -f "$DNS_SCRIPT_PATH" ]; then
  echo "set_dns.sh 脚本不存在，正在下载..."
  curl -o "$DNS_SCRIPT_PATH" "https://raw.githubusercontent.com/liuyisi-afk/vps-tcp/main/set_dns.sh"
  if [ $? -ne 0 ]; then
    echo "下载 set_dns.sh 脚本失败，请检查网络连接或仓库地址是否正确。"
    exit 1
  fi
  echo "下载完成。"
else
  echo "已检测到 $DNS_SCRIPT_PATH，跳过下载。"
fi

# 确保脚本有执行权限
chmod +x "$DNS_SCRIPT_PATH"

# 创建 systemd 服务文件
echo "正在创建 systemd 服务文件..."
cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Set DNS based on IP location
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$DNS_SCRIPT_PATH
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

# 启用并启动服务
echo "启用并启动服务..."
systemctl enable set_dns.service
systemctl start set_dns.service

# 检查服务状态
echo "服务状态如下："
systemctl status set_dns.service --no-pager

echo "设置完成！DNS 设置脚本已配置为开机自启动。"
