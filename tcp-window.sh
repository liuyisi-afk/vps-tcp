#!/bin/bash

# 确保脚本以 root 用户身份运行
if [ "$(id -u)" -ne 0 ]; then
  echo "请以 root 用户身份运行此脚本。"
  exit 1
fi

# 删除 /etc/sysctl.conf 文件中的所有内容
> /etc/sysctl.conf

# 重新写入新的配置到 /etc/sysctl.conf
cat <<EOF >> /etc/sysctl.conf

# 内核参数
kernel.msgmnb=65536
kernel.msgmax=65536
kernel.shmmax=68719476736
kernel.shmall=4294967296
vm.swappiness=200
net.core.rps_sock_flow_entries=65536

# 文件系统参数
fs.file-max=10240000
fs.inotify.max_user_instances=131072

# TCP/IP协议栈参数
net.ipv4.tcp_retries1=3
net.ipv4.tcp_retries2=3
net.ipv4.tcp_orphan_retries=1
net.ipv4.tcp_max_orphans=32768
net.ipv4.tcp_syn_retries=1
net.ipv4.tcp_synack_retries=3
net.ipv4.tcp_fin_timeout=10
net.ipv4.tcp_max_tw_buckets=32768
net.core.netdev_budget=65536
net.ipv4.tcp_max_syn_backlog=819200
net.core.netdev_max_backlog=262144
net.core.somaxconn=65536
net.ipv4.tcp_notsent_lowat=16384
net.ipv4.tcp_keepalive_time=60
net.ipv4.tcp_keepalive_probes=3
net.ipv4.tcp_keepalive_intvl=20
net.ipv4.tcp_window_scaling=1
net.ipv4.tcp_adv_win_scale=1
net.ipv4.tcp_moderate_rcvbuf=1

# 网络缓冲区参数
net.core.rmem_max=67108864
net.core.wmem_max=67108864
net.ipv4.tcp_rmem=8192 87380 67108864
net.ipv4.tcp_wmem=8192 65536 67108864
net.ipv4.udp_rmem_min=8192
net.ipv4.udp_wmem_min=8192
net.ipv4.tcp_mem=262144 1048576 4194304
net.ipv4.udp_mem=262144 1048576 4194304

# TCP 拥塞控制
net.ipv4.tcp_congestion_control=bbr

# 默认队列算法
net.core.default_qdisc=fq

# 本地端口范围
net.ipv4.ip_local_port_range=1025 65535

EOF

# 使配置生效
sysctl -p

echo "所有配置已成功替换并生效！"
