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

x86 软路由 / 虚拟机，再加一步多核分流（可选）：

```sh
sh /tmp/nettune.sh x86
```

卸载（删除配置并恢复原来的 `/etc/sysctl.conf`，x86 步骤也一并撤销）：

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

## x86 可选步骤：多核分流

`sh nettune.sh x86` 只在 x86 上执行（ARM 默认拒绝：开了硬件加速的 ARM 路由器打开数据包引导可能反而变慢，确实要用可以 `FORCE=1 sh nettune.sh x86`）。单核机器直接跳过。

1. **数据包引导** `network.globals.packet_steering=2`：把软件收包分流（RPS）铺到全部 CPU。不用 `1`，因为 `1` 会把一张网卡所有接收队列的 RPS 指到同一个核，多队列网卡反而被收窄成单核
2. **irqbalance**：没有就自动安装并启用，把网卡硬中断分到多个核（数据包引导只管软件分流，两者互补）
3. **网卡多队列**：没有 ethtool 就自动安装；把每张物理网卡的 combined 队列数设为 min(网卡上限, CPU 核数)。写成 `/etc/hotplug.d/net/50-nettune-queues`，开机和网卡热插拔时自动重设，并加入 sysupgrade.conf
4. 提示：虚拟机网卡只有 1 个队列时，提示在 PVE 里设置 Multiqueue；Intel i225/i226（igc）提示断流时可关 EEE；e1000 等模拟网卡建议换 virtio

原来的 packet_steering 和 irqbalance 设置记录在 `/etc/nettune.state`，`uninstall` 时按原样恢复。

## 作用范围

TCP 缓冲区、BBR、fastopen 只影响**路由器本机**的 TCP 连接（代理、frpc、iperf3、Docker 容器等）；局域网设备经路由器转发的流量只受 backlog 和 conntrack 影响。

`tcp_adv_win_scale` 在内核 6.6 起已废弃，`vm.swappiness` 在没有 swap 的 OpenWrt 上没有作用，所以都不设置。

## 测试过的系统

- ImmortalWrt 25.12.2（内核 6.12，apk），mediatek/filogic，1 GB
- ImmortalWrt 24.10 第三方固件（内核 6.6，opkg，无 sch_fq），mediatek/filogic，1 GB
- OpenWrt 25.12.6 与 24.10.8 官方 x86-64 镜像（QEMU，4 核，4 队列 virtio-net）：BBR / fq 模块自动安装；x86 步骤生效后 RPS 为 `f f f f`、4 个队列中断分到 4 个核；重启后保持；队列被改成 1 后热插拔钩子恢复为 4；卸载后完全还原
