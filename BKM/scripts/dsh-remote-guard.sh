#!/bin/bash
# DSH Remote 令牌爆破防护
#
# 逻辑：同一 IP 在 10 分钟内累计 10 次 401，就用 iptables 封禁它的 80/443，1 小时后自动解封。
# 由 cron 每分钟执行：* * * * * root /usr/local/bin/dsh-remote-guard.sh
#
# 为什么不用 fail2ban：
#   1. 默认 action 依赖 firewalld，很多机器上 firewalld 根本没跑 → 封禁静默失败
#   2. nginx 访问日志的时间戳在 [ ] 里，默认日期模板解析不出来 → 计数永远是 0
# 自己写反而更可控，40 行就能看懂。

LOG="${DSH_GUARD_LOG:-/var/log/nginx/dsh-access.log}"
STATE_DIR="${DSH_GUARD_STATE:-/var/lib/dsh-guard}"
CHAIN="DSH_GUARD"
MAXRETRY=10
FINDTIME=600      # 10 分钟
BANTIME=3600      # 1 小时
PORTS="80,443"

mkdir -p "$STATE_DIR"
COUNT_FILE="$STATE_DIR/counts"
OFFSET_FILE="$STATE_DIR/offset"
BAN_FILE="$STATE_DIR/banned"

touch "$COUNT_FILE" "$BAN_FILE"
[ -f "$OFFSET_FILE" ] || echo 0 > "$OFFSET_FILE"

# ---------- 确保自定义链存在 ----------
iptables -nL "$CHAIN" >/dev/null 2>&1 || iptables -N "$CHAIN" 2>/dev/null || true
iptables -C INPUT -j "$CHAIN" >/dev/null 2>&1 || iptables -I INPUT -j "$CHAIN" 2>/dev/null || true

NOW=$(date +%s)

# ---------- 1) 只读取新增日志（记录字节偏移，避免重复计数）----------
if [ -f "$LOG" ]; then
    SIZE=$(stat -c%s "$LOG")
    OFFSET=$(cat "$OFFSET_FILE" 2>/dev/null || echo 0)
    [ "$SIZE" -lt "$OFFSET" ] && OFFSET=0      # 日志轮转后从头读

    if [ "$SIZE" -gt "$OFFSET" ]; then
        tail -c +$((OFFSET + 1)) "$LOG" | awk '$9 == 401 {print $1}' | sort | uniq -c |
        while read -r cnt ip; do
            echo "$NOW $ip $cnt" >> "$COUNT_FILE"
        done
        echo "$SIZE" > "$OFFSET_FILE"
    fi
fi

# ---------- 2) 清掉过期的计数 ----------
awk -v now="$NOW" -v win="$FINDTIME" '$1 >= now - win' "$COUNT_FILE" > "$COUNT_FILE.tmp" &&
    mv "$COUNT_FILE.tmp" "$COUNT_FILE"

# ---------- 3) 达到阈值就封禁 ----------
awk '{c[$2] += $3} END {for (ip in c) if (c[ip] >= '"$MAXRETRY"') print ip}' \
    "$COUNT_FILE" > "$STATE_DIR/to_ban.tmp"

while read -r ip; do
    [ -z "$ip" ] && continue
    # 跳过本机与内网，避免误封
    case "$ip" in
        127.*|::1|10.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*) continue ;;
    esac
    grep -q "^$ip " "$BAN_FILE" 2>/dev/null && continue

    EXP=$((NOW + BANTIME))
    iptables -A "$CHAIN" -s "$ip" -p tcp -m multiport --dports "$PORTS" -j DROP 2>/dev/null || true
    echo "$ip $EXP" >> "$BAN_FILE"
    logger -t dsh-guard "BANNED $ip for ${BANTIME}s (>=${MAXRETRY} x 401 in ${FINDTIME}s)"
done < "$STATE_DIR/to_ban.tmp"

# ---------- 4) 解除到期封禁 ----------
if [ -s "$BAN_FILE" ]; then
    while read -r ip exp; do
        [ -z "$ip" ] && continue
        if [ "$exp" -le "$NOW" ]; then
            iptables -D "$CHAIN" -s "$ip" -p tcp -m multiport --dports "$PORTS" -j DROP 2>/dev/null || true
            logger -t dsh-guard "UNBANNED $ip (expired)"
        else
            echo "$ip $exp"
        fi
    done < "$BAN_FILE" > "$BAN_FILE.tmp"
    mv "$BAN_FILE.tmp" "$BAN_FILE"
fi
