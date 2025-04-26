#!/bin/bash

set -e

CONFIG_FILE="/usr/local/x-ui/bin/config.json"
SERVICE_FILE="/etc/systemd/system/x-ui-restart.service"
TIMER_FILE="/etc/systemd/system/x-ui-restart.timer"

echo "🛠️ 正在备份原始配置..."
cp "$CONFIG_FILE" "$CONFIG_FILE.bak.$(date +%s)"

echo "📦 正在优化 config.json..."
jq ' 
  .log = {
    "loglevel": "warning",
    "access": "",
    "error": ""
  }
  | .inbounds |= map(
      if has("sniffing") then .sniffing.enabled = false | . 
      else . + {"sniffing": {"enabled": false}} end
    )
  | .routing.domainStrategy = "IPIfNonMatch"
' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"

echo "📄 正在创建 systemd service..."
cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Restart x-ui service
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/systemctl restart x-ui.service
EOF

echo "⏰ 正在创建 systemd timer..."
cat > "$TIMER_FILE" <<EOF
[Unit]
Description=Daily restart of x-ui

[Timer]
OnCalendar=daily
Persistent=true

[Install]
WantedBy=timers.target
EOF

echo "🔄 正在重载 systemd 并启用定时器..."
systemctl daemon-reload
systemctl enable --now x-ui-restart.timer

echo "✅ 优化完成，x-ui 已设置为每日定时重启，并降低内存占用！"
