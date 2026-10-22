# OpenWrt-NetTune

OpenWrt 一键网络调优：BBR + TCP 缓冲区 + backlog + conntrack，按内存自动分档，可重复执行、可一键卸载。纯 POSIX sh，busybox ash 直接跑，不需要 bash。

## 一键运行

```sh
wget -O /tmp/nettune.sh https://raw.githubusercontent.com/chnnic/OpenWrt-NetTune/main/nettune.sh && sh /tmp/nettune.sh
```

查看当前参数（不改动）：

```sh
sh /tmp/nettune.sh status
```

卸载（删除配置并恢复原来的 `/etc/sysctl.conf`）：

```sh
sh /tmp/nettune.sh uninstall
```

> 国内访问 raw.githubusercontent.com 不稳定时，可以先在电脑上下载，再 `scp -O nettune.sh root@路由器:/tmp/` 传上去运行。

## 做了什么

| 内存档位 | 128M | 256M | 512M | 1G | 2G+ |
|---|---|---|---|---|---|
| 单连接缓冲区上限 `rmem_max`/`wmem_max` | 4 MB | 8 MB | 16 MB | 64 MB | 64 MB |
| `netdev_max_backlog` | 2000 | 5000 | 10000 | 10000 | 16384 |
| `nf_conntrack_max` | 16384 | 32768 | 65536 | 262144 | 524288 |
| `nf_conntrack_buckets` | 4096 | 8192 | 16384 | 65536 | 131072 |

所有档位共用：`tcp_rmem`/`tcp_wmem` 中间值保持内核默认（131072 / 16384，避免每条连接一开始就占 1 MB），`tcp_fastopen=3`、`tcp_slow_start_after_idle=0`、`tcp_tw_reuse=1`、`tcp_no_metrics_save=1`、`somaxconn=4096`，以及 `tcp_congestion_control=bbr` + `default_qdisc=fq`。

脚本会：

1. 检测 BBR 和 `sch_fq`：内核没有就尝试用 apk / opkg 安装 `kmod-tcp-bbr`、`kmod-sched`，装不上就跳过（BBR 不依赖 fq 也能用内核自带 pacing）
2. 只写当前内核里存在的参数，不同版本的 OpenWrt / ImmortalWrt 都能用
3. 配置写到 `/etc/sysctl.d/95-tune.conf`；`/etc/sysctl.conf` 在它之后加载，里面的同名参数会被注释掉，原文件备份到 `/etc/sysctl.conf.nettune.bak`；sysctl.d 里排在后面、会覆盖本配置的文件会给出提示
4. 加入 `/etc/sysupgrade.conf`，升级固件时保留
5. 立即生效，并逐项核对显示 `[OK]` / `[失败]`

## 作用范围

TCP 缓冲区、BBR、fastopen 只影响**路由器本机**的 TCP 连接（代理、frpc、iperf3、Docker 容器等）；局域网设备经路由器转发的流量只受 backlog 和 conntrack 影响。

`tcp_adv_win_scale` 在内核 6.6 起已废弃，`vm.swappiness` 在没有 swap 的 OpenWrt 上没有作用，所以都不设置。

## 测试过的系统

- ImmortalWrt 25.12.2（内核 6.12，apk），MT7981 / MT7987A，1 GB
- ImmortalWrt 24.10 第三方固件（内核 6.6，opkg，无 sch_fq），MT7981，1 GB
