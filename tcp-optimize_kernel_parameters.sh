# 优化内核参数
optimize_kernel_parameters() {
    # 询问用户是否继续
    read -p "您确定要优化内核参数吗？(y/n): " choice
    case "$choice" in
      [Yy]*)
        echo "正在备份原始内核参数 /etc/sysctl.conf → /etc/sysctl.conf.bak"
        cp /etc/sysctl.conf /etc/sysctl.conf.bak

        # 1. 检测总内存
        echo "检测系统总内存……"
        mem_kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
        mem_mb=$((mem_kb/1024))
        echo "  系统总内存: ${mem_mb} MB"

        # 2. 手动/默认输入 RTT & 带宽
        read -p "是否手动输入延迟(RTT ms)和带宽(Mbit/s)? [y/N]: " manual
        if [[ $manual =~ ^[Yy] ]]; then
          read -p "  请输入 你ping服务器的延迟(ms 只输入数字): " rtt
          read -p "  请输入 你的宽带网速(Mbit/s 只输入数字): " bw
        else
          rtt=160
          bw=400
          echo "  使用默认 RTT=${rtt} ms, 带宽=${bw} Mbit/s"
        fi
        : ${rtt:=100}
        : ${bw:=100}

        # 3. 计算 BDP(字节)
        #    bw_bytes = bw * 1024*1024 /8
        #    BDP = bw_bytes * (rtt/1000)
        bw_bytes=$(awk "BEGIN{printf \"%.0f\", $bw*1024*1024/8}")
        bdp=$(awk "BEGIN{printf \"%.0f\", $bw_bytes*$rtt/1000}")
        echo "  计算得到 BDP = ${bdp} 字节"

        # 4. 根据内存分区决定基准 rmem_max/adv_scale
        if [ "$mem_mb" -le 512 ]; then
            case_rmem=$((16*1024*1024))   # 16MB
            adv_case=-3
        elif [ "$mem_mb" -le 1024 ]; then
            case_rmem=$((32*1024*1024))   # 32MB
            adv_case=-2
        else
            case_rmem=$((64*1024*1024))   # 64MB
            adv_case=-1
        fi

        # 5. 综合 BDP 和 内存上限 (不超过总内存的一半) 来算最终的 rmem_max
        target_rmem=$case_rmem
        # 如果 BDP 要求更大，就用 BDP
        if [ "$bdp" -gt "$target_rmem" ]; then
            target_rmem=$bdp
        fi
        # 不超过总内存的一半
        half_mem_bytes=$((mem_kb*1024/2))
        if [ "$target_rmem" -gt "$half_mem_bytes" ]; then
            target_rmem=$half_mem_bytes
        fi
        # 最低保证
        if [ "$target_rmem" -lt 4096 ]; then
            target_rmem=4096
        fi


        # 6. 动态选 adv_win_scale：若 BDP 超过基准，则放大窗口 (adv=0)，否则用分区给定值
        if [ "$bdp" -gt "$case_rmem" ]; then
            adv_scale=0
        else
            adv_scale=$adv_case
        fi

        # 7. 构造待写入的参数列表
        parameters=(
          "net.core.default_qdisc = fq_pie"
          "net.ipv4.tcp_congestion_control = bbr"
          "net.core.rmem_max = $target_rmem"
          "net.core.wmem_max = $target_rmem"
          "net.ipv4.tcp_rmem = 4096 87380 $target_rmem"
          "net.ipv4.tcp_wmem = 4096 16384 $target_rmem"
          "net.ipv4.tcp_window_scaling = 1"
          "net.ipv4.tcp_adv_win_scale = $adv_scale"
          "net.ipv4.tcp_low_latency = 1"
          "net.ipv4.tcp_notsent_lowat = 131072"
          "net.ipv4.tcp_slow_start_after_idle = 0"
          "net.ipv4.tcp_sack = 1"
          "net.ipv4.tcp_timestamps = 1"
          "net.ipv4.ip_forward = 1"
          "vm.overcommit_memory = 1"
          "fs.inotify.max_user_watches = 524288"
        )

        # 8. 注释掉老的 tcp_fastopen (如果存在)
        sed -i 's/^[[:space:]]*net\.ipv4\.tcp_fastopen/#&/' /etc/sysctl.conf

        # 9. 写入或更新 sysctl.conf
        for p in "${parameters[@]}"; do
          key="${p%% =*}"
          if grep -qE "^\s*${key}\b" /etc/sysctl.conf; then
            # 已有，替换整行
            sed -i "s|^\s*${key}.*|${p}|" /etc/sysctl.conf
          else
            # 没有，追加到末尾
            echo "${p}" >> /etc/sysctl.conf
          fi
        done

        # 10. 重新加载生效
        sysctl -p

        echo "====== 内核参数优化完成 ======"
        ;;

      [Nn]*)
        echo "内核参数优化已取消。"
        ;;

      *)
        echo "无效输入，退出。"
        return 1
        ;;
    esac
}
