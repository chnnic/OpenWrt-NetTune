#!/bin/sh
# OpenWrt 一键网络调优（BBR + 缓冲区 + backlog + conntrack，按内存自动分档）
# 用法：
#   sh nettune.sh            应用（可重复执行）
#   sh nettune.sh status     只查看当前值，不改动
#   sh nettune.sh uninstall  卸载并恢复原来的 /etc/sysctl.conf
# 说明：TCP 缓冲区/BBR 只影响路由器本机的 TCP（代理、frpc、iperf3、容器）；backlog 和 conntrack 影响转发。

CONF=/etc/sysctl.d/95-tune.conf
BAK=/etc/sysctl.conf.nettune.bak
KEEP=/etc/sysupgrade.conf

say()  { printf '%s\n' "$*"; }
ok()   { printf '  [OK]   %s\n' "$*"; }
warn() { printf '  [跳过] %s\n' "$*"; }
err()  { printf '  [失败] %s\n' "$*"; }

[ "$(id -u)" = 0 ] || { say "请用 root 运行"; exit 1; }
[ -f /etc/openwrt_release ] || say "提示：没检测到 /etc/openwrt_release，按普通 Linux 继续"

key_path() { echo "/proc/sys/$(echo "$1" | tr . /)"; }
has_key()  { [ -e "$(key_path "$1")" ]; }
norm()     { echo "$*" | tr -s ' \t' ' ' | sed 's/^ //;s/ $//'; }
mem_mb()   { awk '/^MemTotal/{print int($2/1024)}' /proc/meminfo; }

pkg_install() {
	if command -v apk >/dev/null 2>&1; then
		apk add "$@" >/dev/null 2>&1 || { apk update >/dev/null 2>&1 && apk add "$@" >/dev/null 2>&1; }
	elif command -v opkg >/dev/null 2>&1; then
		opkg install "$@" >/dev/null 2>&1 || { opkg update >/dev/null 2>&1 && opkg install "$@" >/dev/null 2>&1; }
	else
		return 1
	fi
}

ensure_bbr() {
	grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null && return 0
	modprobe tcp_bbr 2>/dev/null || insmod tcp_bbr 2>/dev/null
	grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null && return 0
	say "  内核没有 BBR，尝试安装 kmod-tcp-bbr ..."
	pkg_install kmod-tcp-bbr && { modprobe tcp_bbr 2>/dev/null || insmod tcp_bbr 2>/dev/null; }
	grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null
}

have_fq() {
	# 内核没有 sch_fq 时写 default_qdisc=fq 会报 No such file or directory
	modprobe sch_fq 2>/dev/null || insmod sch_fq 2>/dev/null
	grep -qw sch_fq /proc/modules 2>/dev/null && return 0
	cur=$(cat /proc/sys/net/core/default_qdisc 2>/dev/null)
	echo fq > /proc/sys/net/core/default_qdisc 2>/dev/null || return 1
	echo "$cur" > /proc/sys/net/core/default_qdisc 2>/dev/null
	return 0
}

ensure_fq() {
	have_fq && return 0
	say "  内核没有 sch_fq，尝试安装 kmod-sched ..."
	pkg_install kmod-sched && have_fq
}

# 按内存分档：conntrack 每条约 300 字节；缓冲区上限只是单连接上限，内核按 tcp_mem 总量兜底
pick_tier() {
	m=$(mem_mb)
	if   [ "$m" -le 160 ];  then TIER=128M; BUF=4194304;  BL=2000;  SYN=2048; TW=16384;  CT=16384;  CTB=4096
	elif [ "$m" -le 320 ];  then TIER=256M; BUF=8388608;  BL=5000;  SYN=4096; TW=32768;  CT=32768;  CTB=8192
	elif [ "$m" -le 640 ];  then TIER=512M; BUF=16777216; BL=10000; SYN=8192; TW=65536;  CT=65536;  CTB=16384
	elif [ "$m" -le 1280 ]; then TIER=1G;   BUF=67108864; BL=10000; SYN=8192; TW=65536;  CT=262144; CTB=65536
	else                         TIER=2G+;  BUF=67108864; BL=16384; SYN=8192; TW=131072; CT=524288; CTB=131072
	fi
}

gen_conf() {
	cat <<EOF
# 由 nettune.sh 生成：$(date '+%Y-%m-%d %H:%M')，内存 $(mem_mb)MB → $TIER 档
net.core.rmem_max = $BUF
net.core.wmem_max = $BUF
net.ipv4.tcp_rmem = 4096 131072 $BUF
net.ipv4.tcp_wmem = 4096 16384 $BUF
net.core.netdev_max_backlog = $BL
net.core.somaxconn = 4096
net.ipv4.tcp_max_syn_backlog = $SYN
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_max_tw_buckets = $TW
net.ipv4.tcp_no_metrics_save = 1
net.netfilter.nf_conntrack_max = $CT
net.netfilter.nf_conntrack_buckets = $CTB
EOF
	[ "$BBR" = 1 ] && echo "net.ipv4.tcp_congestion_control = bbr"
	[ "$FQ" = 1 ]  && echo "net.core.default_qdisc = fq"
}

conf_keys() { grep -v '^[[:space:]]*#' "$1" 2>/dev/null | grep '=' | cut -d= -f1 | tr -d ' \t'; }

# 别的文件里同名参数会覆盖本配置：sysctl.conf 最后加载，sysctl.d 里排在 95 之后的也会覆盖
fix_overrides() {
	if [ -f /etc/sysctl.conf ]; then
		hit=0
		for k in $(conf_keys "$CONF"); do
			grep -qE "^[[:space:]]*$k[[:space:]]*=" /etc/sysctl.conf && hit=1
		done
		if [ "$hit" = 1 ]; then
			[ -f "$BAK" ] || cp /etc/sysctl.conf "$BAK"
			for k in $(conf_keys "$CONF"); do
				sed -i "s|^[[:space:]]*\($k[[:space:]]*=\)|# nettune: \1|" /etc/sysctl.conf
			done
			ok "/etc/sysctl.conf 里的重复参数已注释（原文件备份到 $BAK）"
		fi
	fi
	for f in /etc/sysctl.d/*.conf; do
		[ -f "$f" ] || continue
		[ "$f" = "$CONF" ] && continue
		b=$(basename "$f")
		[ "$(printf '%s\n%s\n' "$b" 95-tune.conf | sort | tail -1)" = "$b" ] || continue
		for k in $(conf_keys "$CONF"); do
			grep -qE "^[[:space:]]*$k[[:space:]]*=" "$f" && warn "$f 也设置了 $k，会覆盖本配置"
		done
	done
}

reload() {
	if [ -x /etc/init.d/sysctl ]; then
		/etc/init.d/sysctl restart >/dev/null 2>&1
	else
		for f in /etc/sysctl.d/*.conf /etc/sysctl.conf; do [ -f "$f" ] && sysctl -q -p "$f" >/dev/null 2>&1; done
	fi
	# 重新加载有时遇到单个坏参数就静默失败，这里再逐项写一次本配置
	grep -v '^[[:space:]]*#' "$CONF" | grep '=' | while IFS='=' read -r k v; do
		k=$(norm "$k"); v=$(norm "$v")
		sysctl -q -w "$k=$v" >/dev/null 2>&1
	done
}

verify() {
	bad=0
	grep -v '^[[:space:]]*#' "$CONF" | grep '=' | while IFS='=' read -r k v; do
		k=$(norm "$k"); v=$(norm "$v")
		cur=$(norm "$(sysctl -n "$k" 2>/dev/null)")
		if [ "$cur" = "$v" ]; then ok "$k = $cur"; else err "$k 期望 [$v] 实际 [$cur]"; fi
	done
}

show_status() {
	say "内存 $(mem_mb)MB，内核 $(uname -r)"
	for k in net.ipv4.tcp_congestion_control net.core.default_qdisc net.core.rmem_max net.core.wmem_max \
		net.ipv4.tcp_rmem net.ipv4.tcp_wmem net.core.netdev_max_backlog net.ipv4.tcp_max_syn_backlog \
		net.ipv4.tcp_fastopen net.ipv4.tcp_slow_start_after_idle net.ipv4.tcp_max_tw_buckets \
		net.netfilter.nf_conntrack_max net.netfilter.nf_conntrack_buckets net.netfilter.nf_conntrack_count; do
		has_key "$k" && printf '  %-40s %s\n' "$k" "$(norm "$(sysctl -n "$k" 2>/dev/null)")"
	done
	say "  可用拥塞算法: $(cat /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null)"
	[ -f "$CONF" ] && say "  已安装: $CONF" || say "  未安装"
}

do_apply() {
	say "== 检测环境"
	pick_tier
	ok "内存 $(mem_mb)MB → $TIER 档"
	BBR=0; FQ=0
	if ensure_bbr; then BBR=1; ok "BBR 可用"; else warn "BBR 不可用（固件没有 kmod-tcp-bbr 且装不上），保持原拥塞算法"; fi
	if ensure_fq; then FQ=1; ok "fq 队列可用"; else warn "sch_fq 不可用，保持原队列（BBR 用内核自带 pacing，影响不大）"; fi
	# 模块没加载时 conntrack 参数不存在，先尝试加载
	has_key net.netfilter.nf_conntrack_max || modprobe nf_conntrack 2>/dev/null

	say "== 写入 $CONF"
	tmp=$(mktemp)
	gen_conf > "$tmp"
	: > "$CONF.new"
	while IFS= read -r line; do
		case "$line" in
			\#*|'') echo "$line" >> "$CONF.new" ;;
			*) k=$(norm "${line%%=*}")
			   if has_key "$k"; then echo "$line" >> "$CONF.new"; else warn "内核没有 $k，不写入"; fi ;;
		esac
	done < "$tmp"
	rm -f "$tmp"
	mv "$CONF.new" "$CONF"
	ok "已写入"

	fix_overrides

	if [ -f "$KEEP" ]; then
		grep -qx "$CONF" "$KEEP" || echo "$CONF" >> "$KEEP"
		ok "已加入 $KEEP（升级固件时保留）"
	fi

	say "== 生效并核对"
	reload
	verify
	has_key net.netfilter.nf_conntrack_count && say "  当前连接数 $(sysctl -n net.netfilter.nf_conntrack_count)"
	say "完成。可重复执行；卸载：sh $0 uninstall"
}

do_uninstall() {
	rm -f "$CONF"
	[ -f "$KEEP" ] && sed -i "\|^$CONF\$|d" "$KEEP"
	if [ -f "$BAK" ]; then mv "$BAK" /etc/sysctl.conf; ok "已恢复 /etc/sysctl.conf"; fi
	[ -x /etc/init.d/sysctl ] && /etc/init.d/sysctl restart >/dev/null 2>&1
	ok "已卸载。没有被其他配置覆盖的参数要重启后才回到内核默认值"
}

case "$1" in
	status)    show_status ;;
	uninstall) do_uninstall ;;
	''|apply)  do_apply ;;
	*) say "用法: sh $0 [apply|status|uninstall]"; exit 1 ;;
esac
