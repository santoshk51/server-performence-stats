#!/usr/bin/env bash
# server-stats.sh — Basic server performance stats
# Author: You :)
# Usage: ./server-stats.sh

# ------------- helpers -------------
have() { command -v "$1" >/dev/null 2>&1; }

hr() { printf '%s\n' "------------------------------------------------------------"; }
section() { printf '\n%s\n%s\n' "$1" "============================================================"; }

human_kib() {
  # Convert KiB to a human-readable string (GiB/MiB/KiB)
  local kib=$1
  awk -v kib="$kib" 'BEGIN{
    if (kib >= 1024*1024) printf "%.2f GiB", kib/(1024*1024);
    else if (kib >= 1024) printf "%.2f MiB", kib/1024;
    else printf "%d KiB", kib;
  }'
}

# ------------- header -------------
printf "server-stats.sh  |  Host: %s  |  Date: %s\n" "$(hostname)" "$(date '+%Y-%m-%d %H:%M:%S %Z')"
hr

# ------------- OS / Kernel / Uptime / Load -------------
section "System"
# OS
if [ -r /etc/os-release ]; then
  . /etc/os-release
  printf "OS: %s %s\n" "${NAME:-Linux}" "${VERSION:-}"
else
  printf "OS: %s\n" "$(uname -s)"
fi
printf "Kernel: %s\n" "$(uname -r)"
# Uptime
if have uptime; then
  printf "Uptime: %s\n" "$(uptime -p 2>/dev/null || uptime)"
else
  # Fallback from /proc/uptime
  if [ -r /proc/uptime ]; then
    up=$(awk '{print int($1)}' /proc/uptime)
    d=$((up/86400)); h=$(( (up%86400)/3600 )); m=$(( (up%3600)/60 ))
    printf "Uptime: %dd %dh %dm\n" "$d" "$h" "$m"
  fi
fi
# Load averages
if [ -r /proc/loadavg ]; then
  read -r la1 la5 la15 _ < /proc/loadavg
  printf "Load averages (1/5/15 min): %s, %s, %s\n" "$la1" "$la5" "$la15"
fi
# Logged-in users
if have who; then
  users=$(who | wc -l | awk '{print $1}')
  printf "Logged-in users: %s\n" "$users"
fi

# ------------- CPU usage (overall) -------------
section "Total CPU Usage"
# Calculate CPU usage over ~1 second using /proc/stat deltas
if [ -r /proc/stat ]; then
  read -r _ a b c d e f g h i j < /proc/stat
  idle=$d
  total=$((a+b+c+d+e+f+g+h+i+j))
  sleep 1
  read -r _ a2 b2 c2 d2 e2 f2 g2 h2 i2 j2 < /proc/stat
  idle2=$d2
  total2=$((a2+b2+c2+d2+e2+f2+g2+h2+i2+j2))
  diff_idle=$((idle2-idle))
  diff_total=$((total2-total))
  if [ "$diff_total" -gt 0 ]; then
    usage=$(awk -v i="$diff_idle" -v t="$diff_total" 'BEGIN{ printf "%.2f", (1 - i/t) * 100 }')
    printf "CPU Usage: %s%%\n" "$usage"
  else
    printf "CPU Usage: n/a\n"
  fi
else
  printf "CPU Usage: /proc/stat not readable\n"
fi

# ------------- Memory usage -------------
section "Memory Usage"
if [ -r /proc/meminfo ]; then
  mem_total_kib=$(awk '/MemTotal:/ {print $2}' /proc/meminfo)
  mem_avail_kib=$(awk '/MemAvailable:/ {print $2}' /proc/meminfo)
  if [ -z "$mem_avail_kib" ]; then
    # Older kernels may not have MemAvailable; approximate using free(1) if present
    if have free; then
      mem_total_kib=$(free -k | awk '/Mem:/ {print $2}')
      mem_free_kib=$(free -k | awk '/Mem:/ {print $4}')
      mem_buff_cache_kib=$(free -k | awk '/Mem:/ {print $6}')
      mem_avail_kib=$((mem_free_kib + mem_buff_cache_kib))
    else
      mem_avail_kib=0
    fi
  fi
  mem_used_kib=$((mem_total_kib - mem_avail_kib))
  mem_pct=$(awk -v u="$mem_used_kib" -v t="$mem_total_kib" 'BEGIN{ printf "%.2f", (u/t)*100 }')
  printf "Total: %s\n" "$(human_kib "$mem_total_kib")"
  printf "Used : %s\n" "$(human_kib "$mem_used_kib")"
  printf "Free : %s\n" "$(human_kib "$mem_avail_kib")"
  printf "Usage: %s%%\n" "$mem_pct"
else
  printf "/proc/meminfo not readable\n"
fi

# ------------- Disk usage (aggregate) -------------
section "Disk Usage (excluding tmpfs/devtmpfs)"
if have df; then
  # Sum POSIX -P output in KiB; exclude tmpfs/devtmpfs
  df -kP | awk 'NR>1 && $1 !~ /^(tmpfs|devtmpfs)$/ {sum_size+=$2; sum_used+=$3; sum_avail+=$4} END{
    printf "Total: "; 
    cmd=sprintf("awk -v kib=%d -f -", sum_size); 
    print kib |& cmd; 
  }' 2>/dev/null
  # Because using a function across awk processes is hairy, redo with a small shell block
  total_kib=$(df -kP | awk 'NR>1 && $1 !~ /^(tmpfs|devtmpfs)$/ {sum+=$2} END{print sum+0}')
  used_kib=$(df -kP | awk 'NR>1 && $1 !~ /^(tmpfs|devtmpfs)$/ {sum+=$3} END{print sum+0}')
  avail_kib=$(df -kP | awk 'NR>1 && $1 !~ /^(tmpfs|devtmpfs)$/ {sum+=$4} END{print sum+0}')
  if [ -n "$total_kib" ] && [ "$total_kib" -gt 0 ]; then
    disk_pct=$(awk -v u="$used_kib" -v t="$total_kib" 'BEGIN{ printf "%.2f", (u/t)*100 }')
    printf "Total: %s\n" "$(human_kib "$total_kib")"
    printf "Used : %s\n" "$(human_kib "$used_kib")"
    printf "Free : %s\n" "$(human_kib "$avail_kib")"
    printf "Usage: %s%%\n" "$disk_pct"
  else
    printf "No eligible filesystems found.\n"
  fi
else
  printf "df command not available.\n"
fi

# ------------- Top 5 processes by CPU -------------
section "Top 5 Processes by CPU"
if have ps; then
  # Use comm for short name; adjust to full command with 'cmd' if you prefer
  ps -eo pid,comm,%cpu,%mem --sort=-%cpu | awk 'NR==1 || NR<=6 {printf "%-8s %-25s %6s %6s\n", $1, $2, $3, $4}'
else
  printf "ps command not available.\n"
fi

# ------------- Top 5 processes by Memory -------------
section "Top 5 Processes by Memory"
if have ps; then
  ps -eo pid,comm,%cpu,%mem --sort=-%mem | awk 'NR==1 || NR<=6 {printf "%-8s %-25s %6s %6s\n", $1, $2, $3, $4}'
else
  printf "ps command not available.\n"
fi

# ------------- Stretch: Failed login attempts (best effort, no root) -------------
section "Security (failed SSH login attempts — best effort)"
shown=0
if have lastb; then
  echo "Recent failed logins (lastb):"
  lastb -n 10 2>/dev/null || true
  shown=1
else
  for f in /var/log/auth.log /var/log/secure; do
    if [ -r "$f" ]; then
      echo "Recent failed SSH logins from $f:"
      grep -i 'Failed password' "$f" | tail -n 10 || true
      shown=1
      break
    fi
  done
fi
if [ "$shown" -eq 0 ]; then
  echo "No permission or data source found (try running with sudo, or install util-linux for 'lastb')."
fi

hr
echo "Done."

