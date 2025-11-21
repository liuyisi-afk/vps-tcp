# 1) APT 缓存 & 孤包
apt-get clean
apt-get autoclean -y
apt-get autoremove --purge -y

# 2) systemd 日志控制在 100MB
journalctl --vacuum-size=100M

# 3) 大于 50MB 的日志文件截断（服务不中断）
find /var/log -type f -name "*.log" -size +50M -exec truncate -s 0 {} \;

# 4) 清理临时目录（3 天未访问）
find /tmp -xdev -type f -atime +3 -delete
find /var/tmp -xdev -type f -atime +3 -delete

# 5) WordPress 缓存/升级残留（按你的站点路径）
rm -rf /home/web/html/换成你网址/wordpress/wp-content/{cache,boost-cache,autoptimize,w3tc}/* 2>/dev/null
rm -rf /home/web/html/换成你网址/wordpress/wp-content/../upgrade/* 2>/dev/null


# 6) Docker 占用（仍在使用 Docker 的做法）
if command -v docker >/dev/null 2>&1; then
  docker system df
  docker container prune -f
  docker image prune -af
  docker builder prune -af
  # 截断巨大的容器日志
  for f in /var/lib/docker/containers/*/*-json.log; do [ -f "$f" ] && : > "$f"; done
fi

# 看看释放效果
df -hT
du -xhd1 /var | sort -h
