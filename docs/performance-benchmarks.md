# DeskDash 性能基线与复测

设备为 Kindle Paperwhite 4，固件 5.18.1，Linux 4.1.15-lab126，KOReader 2026.7.2。以下插电样本在 2026-11-05 用同一台 Kindle、同一 Wi‑Fi 采集。内置闪存此前三次 32 MiB 直接顺序读约为 50–67 MiB/s，这组数据只描述块设备顺序读。

## 复现

让 Kindle 接墙充并打开仪表盘。以下命令从仓库根目录依次运行。

```powershell
python tools/kctl.py command 'bench on'
python tools/kctl.py command refresh
python tools/kctl.py command 'page 2'
python tools/kctl.py command 'page 4'
python tools/kctl.py command 'page 1'
python tools/kctl.py command sleep
# RTC 唤醒并重新连上 Wi‑Fi 后
python tools/benchmark.py
python tools/kctl.py command 'bench off'
```

- `sleep` 强制跑一次分钟更新和实际的 suspend-to-RAM，即使插着电。在本地秒数约 38–50 时发命令，减少等下一分钟的时间。距下一次唤醒不足 5 秒时，本轮可能跳过休眠。
- `refresh` 的命令回执等待天气结果完成并重绘。要验证**请求进行中仍能翻页**，可以先执行 `python tools/kctl.py run "echo refresh > /tmp/deskdash_cmd"`，等该命令被消费后再执行 `python tools/kctl.py command 'page 2'`。对照日志里的翻页回执时间和天气完成时间。
- 默认分析设备的 `/tmp/deskdash_bench.tsv`。可用 `ssh kindle 'cat /tmp/deskdash_bench.tsv' > tools/inbox/deskdash-bench.tsv` 留档，再用 `python tools/benchmark.py tools/inbox/deskdash-bench.tsv --version bb777b7` 读单个版本。原始行是 UTC 时间、版本、类别、阶段和毫秒。日志保存在设备临时目录，重启 KOReader 会保留，重启 Kindle 前先导出。
- 计时默认关闭，每次重启 KOReader 后要重新开启。统计按版本和阶段分组，样本数达到 20 才显示 p95。

## 计时口径

| 类别 | 测量范围 |
| --- | --- |
| `command` | 仪表盘开始处理远程命令到重绘完成。分为 `dispatch`（包括页面构建）、`submit` 和 `epdc_wait`。不含 SSH、等待命令轮询、物理触摸手势识别或截图传输。 |
| `refresh_input` | 刷新命令在 UI 线程的 `dispatch`。优化前包含同步天气请求，优化后只等后台任务启动。比较两个版本时用 `dispatch`。 |
| `weather` | Wi‑Fi 等待、定位、预报、预警、AQI、站点观测和工作任务总时长。数据源仍按原有顺序请求。 |
| `wake` / `weather_wake` | 分钟回调到下一次 suspend-to-RAM 返回之间的单调时钟时间。包含构建、刷屏、无线及前光处理、休眠进出开销，时钟在 suspend 期间停止。带天气任务的自动唤醒单独归类。强制睡眠样本不覆盖 RTC 唤醒到分钟回调之间的时间。 |

## 插电结果

基线 `bb777b7` 保留同步天气和休眠前的显式 `sync`。对照版本 `4803980` 使用后台任务和内核休眠同步。采样时 Wi‑Fi 已连接，两个版本的站点都已缓存。

| 指标 | 基线 `bb777b7` | 优化版 `4803980` |
| --- | ---: | ---: |
| UI 处理刷新命令 | 5,653 ms（1 次） | 282、4 ms（2 次） |
| 天气工作总时长 | 5,646 ms（1 次） | 2,863、3,924 ms（2 次） |
| 普通强制休眠循环的醒着时间 | 2,516 ms（1 次） | 2,010 ms（1 次） |
| EPDC 等待 | 477 ms | 477 ms |
| 无线与前光处理 | 234 ms | 214 ms |
| 插件显式 `sync` | 208 ms | 已移除 |
| `rtcwake` 内的休眠进出时间 | 1,300 ms | 1,296 ms |

优化版第一轮天气在后台运行时，逐小时页在 **613 ms** 内完成重绘，回执先于天气结果。天气总耗时包含网络波动，两组的差值不能用来估算 API 提速。两次普通休眠各只有一个样本，构建等环节也有变化，约半秒的总差值不能全部归因于移除 `sync`。

优化版将 Wi‑Fi 等待和天气 HTTP 请求交给单个 KOReader 子进程。页面在请求期间用缓存继续响应，自动请求失败后按 1、2、4、8、15 分钟逐步退避。移除了插件的显式 `sync`，实机内核的休眠入口仍会记录 `PM: Syncing filesystems ... done.`。

## 下一次会话的电池测试

1. 先确认设备上的 `deskdash_version.lua`，打开仪表盘首页，记录语言、时间制、方向和环境。运行 `bench on` 后拔掉墙充，让设备自然按分钟休眠。期间无需持续用 SSH 探测。
2. 采集至少一个完整夜间区间，最好 8–12 小时。到点接回墙充，导出阶段日志及 `/mnt/us/deskdash_power.csv`，运行 `python tools/power.py`。比较平均电流（mA）、每小时唤醒次数、醒着的比例、Wi‑Fi 等待和失败次数。保留测量起止时间，按这段范围筛 CSV。
3. 如需做续航 A/B，可在隔离 checkout 部署基线 `bb777b7`，用相同的时段、布局、网络和充电条件重复一晚。最后重新部署最新版本。夜间休眠策略不同，白天与凌晨 2–5 点的数据分开看。每组至少保留 20 次普通唤醒再比较 p95。

这次的插电强制休眠用于核对分阶段耗时和设备能否恢复。实际放电速率和续航提升尚未测量。
