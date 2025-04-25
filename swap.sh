#!/usr/bin/env bash
set -euo pipefail

# 1. 读取物理内存总量（单位：KB），并转换为 MB
mem_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
mem_mb=$(( mem_kb / 1024 ))

# 2. 计算 swap 大小为物理内存的 2 倍
swap_mb=$(( mem_mb * 2 ))

echo "物理内存：${mem_mb}MB，计划创建 swap：${swap_mb}MB"

# 3. 停用并清理所有现有 Swap
echo "停用所有现有 Swap..."
sudo swapoff -a

# 4. 备份并移除 /etc/fstab 中所有 swap 条目
echo "备份 /etc/fstab，并移除所有 swap 挂载行..."
sudo cp /etc/fstab /etc/fstab.bak
sudo sed -i '/\sswap\s\+/d' /etc/fstab

# 5. 删除旧的 /swapfile 文件（如果存在）
if [ -f /swapfile ]; then
  echo "检测到旧的 /swapfile，正在删除..."
  sudo rm -f /swapfile
fi

# 6. 创建新的 swapfile
echo "创建新的 swap 文件 (/swapfile) 大小：${swap_mb}MB..."
if command -v fallocate &>/dev/null; then
  sudo fallocate -l "${swap_mb}M" /swapfile
else
  sudo dd if=/dev/zero of=/swapfile bs=1M count="${swap_mb}" status=progress
fi

# 7. 设置权限、格式化并启用 swap
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile

# 8. 将新 Swap 挂载信息写入 /etc/fstab，确保重启生效
echo "/swapfile none swap defaults 0 0" | sudo tee -a /etc/fstab

echo "✅ Swap (${swap_mb}MB) 已创建并启用，/etc/fstab 已更新。"
