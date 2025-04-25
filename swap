#!/usr/bin/env bash
set -euo pipefail

# 1. 计算物理内存（单位：KB），并转换为 MB
mem_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
mem_mb=$(( mem_kb / 1024 ))

# 2. 计算 swap 大小为物理内存的 1.5 倍（向上取整）
swap_mb=$(( (mem_mb * 3 + 1) / 2 ))

echo "物理内存：${mem_mb}MB，计划创建 swap：${swap_mb}MB"

# 3. 检查是否已有 /swapfile
if grep -q '^/swapfile' /etc/fstab; then
  echo "/swapfile 已在 /etc/fstab 中，无需重复添加。"
  exit 0
fi

# 4. 创建 swap 文件
sudo swapoff -a
sudo rm -f /swapfile
# 优先使用 fallocate，若不支持再用 dd
if command -v fallocate &>/dev/null; then
  sudo fallocate -l "${swap_mb}M" /swapfile
else
  sudo dd if=/dev/zero of=/swapfile bs=1M count="${swap_mb}" status=progress
fi

# 5. 设置权限、格式化、启用
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile

# 6. 永久生效：写入 /etc/fstab
echo '/swapfile none swap defaults 0 0' | sudo tee -a /etc/fstab

echo "Swap 创建并启用完成！"
