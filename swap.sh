#!/usr/bin/env bash
set -euo pipefail

# 1. 读取物理内存总量（单位：KB），并转换为 MB
mem_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
mem_mb=$(( mem_kb / 1024 ))

# 2. 计算 swap 大小为物理内存的 2 倍
swap_mb=$(( mem_mb * 2 ))

echo "物理内存：${mem_mb}MB，计划创建 swap：${swap_mb}MB"

# 3. 停用并删除所有现有 Swap
echo "停用所有现有 Swap..."
sudo swapoff -a                                              # 停用所有 Swap 分区/文件 :contentReference[oaicite:0]{index=0}

echo "移除 /etc/fstab 中的 Swap 条目..."
# 备份并删除包含 'swap' 关键字的行（匹配挂载点为 swap 的条目）
sudo cp /etc/fstab /etc/fstab.bak
sudo sed -i '/\sswap\s\+/d' /etc/fstab                      # 删除 fstab 中所有 swap 挂载行 :contentReference[oaicite:1]{index=1}

# 4. 清理旧的 Swap 文件（如果存在 /swapfile）
if [ -f /swapfile ]; then
  echo "检测到旧的 /swapfile，正在删除..."
  sudo rm -f /swapfile                                      # 删除旧 swap 文件 :contentReference[oaicite:2]{index=2}
fi

# 5. 创建并启用新的 swapfile
echo "创建新的 swap 文件 (/swapfile) 大小：${swap_mb}MB..."
if command -v fallocate &>/dev/null; then
  sudo fallocate -l "${swap_mb}M" /swapfile
else
  sudo dd if=/dev/zero of=/swapfile bs=1M count="${swap_mb}" status=progress
fi

sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile

# 6. 将新 Swap 挂载写入 fstab，实现开机自动启用
echo "/swapfile none swap defaults 0 0" | sudo tee -a /etc/fstab

echo "Swap (${swap_mb}MB) 创建并启用完成！"
