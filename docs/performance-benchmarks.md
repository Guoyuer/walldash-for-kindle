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

在最终部署版 `fd50bad` 上又做了一次带天气的强制休眠。先发刷新，再发休眠，实机等天气完成后才入睡，RTC 正常唤醒。天气任务耗时 **2,496 ms**，休眠命令开始后测到的醒着时间为 **3,613 ms**，其中还等了 **1,550 ms** 才收到天气结果。天气先于休眠命令启动，因此这条记录只验证两者的协调，不用于估算自然天气唤醒的总开销。

优化版将 Wi‑Fi 等待和天气 HTTP 请求交给单个 KOReader 子进程。页面在请求期间用缓存继续响应，自动请求失败后按 1、2、4、8、15 分钟逐步退避。移除了插件的显式 `sync`，实机内核的休眠入口仍会记录 `PM: Syncing filesystems ... done.`。

上述实验的原始 TSV 已保存在本机的 `tools/inbox/deskdash-bench.tsv`（Git 忽略目录）。

## 并行请求与天气时段

`deskdash_weather_job.lua` 改为同时发出预报、预警、站点观测和 AQI 四个 `curl`，Wi‑Fi 只需开到最慢的那个返回。等待 Wi‑Fi 的轮询间隔从 1 s 缩短到 0.25 s。插电、Wi‑Fi 已连接时，3 次手动刷新的 `http` 阶段中位数为 **1,035 ms**（最大 2,344 ms），此前串行的四项合计为 2,496–3,924 ms。

电池模式下天气改为每 30 分钟一次，固定在本地 :03 和 :33，插电时每 15 分钟。AQI 只在缓存超过 55 分钟时请求，手动刷新时总会请求。按原先每次连网约 10 s 估算，每小时开 Wi‑Fi 的时间约从 55 s 降到 22 s，实际电流变化还要靠电池测试确认。

## 下一次会话的电池测试

1. 先确认设备上的 `deskdash_version.lua`，打开仪表盘首页，记录语言、时间制、方向和环境。运行 `bench on` 后拔掉墙充，让设备自然按分钟休眠。期间无需持续用 SSH 探测。
2. 采集至少一个完整夜间区间，最好 8–12 小时。到点接回墙充，导出阶段日志及 `/mnt/us/deskdash_power.csv`，运行 `python tools/power.py`。比较平均电流（mA）、每小时唤醒次数、醒着的比例、Wi‑Fi 等待和失败次数。保留测量起止时间，按这段范围筛 CSV。
3. 如需做续航 A/B，可在隔离 checkout 部署基线 `bb777b7`，用相同的时段、布局、网络和充电条件重复一晚。最后重新部署最新版本。夜间休眠策略不同，白天与凌晨 2–5 点的数据分开看。每组至少保留 20 次普通唤醒再比较 p95。

这次的插电强制休眠用于核对分阶段耗时和设备能否恢复。实际放电速率和续航提升尚未测量。

## 电流实测（2026-11-05，电池模式）

测量方法：读电量计 BD71827 的原始库仑计数（`registers` 中 0x79–0x7C，大端，放电时递减，休眠期间照常计数）。
换算约 **69800 计数/mAh（19.4 计数/s 每 mA）**，用 40 分钟和 1 小时的 `charge_now` 下降及每秒 `current_now` 三种方法核对一致。
功耗日志的 `cc` 列记录这个计数，`tools/power.py` 用它算 mA。

| 项目 | 电流 |
|---|---|
| 清醒空闲 | 约 62 mA |
| Wi‑Fi 连接中 | 约 170 mA（峰值约 350） |
| 前光 1084 | +22 mA |
| 休眠底电流（`rtcwake`，触摸未锁） | 约 3.5 mA |
| 休眠底电流（锁触摸 `/proc/touch`） | 约 3.1 mA |
| 每次休眠进出的固定开销 | 约 96 mA·s |
| 电池模式整体（19:02–20:00） | 约 9 mA，约 7 天 |

已排除：前光驱动断电（`bl_power=4`）、冻结原厂后台进程、蓝牙（未开）、Wi‑Fi 驱动（系统关 Wi‑Fi 时已卸载）。
原厂 Kindle 待机据说约 0.7 mA，差距多半来自绕过 powerd 的休眠流程。powerd 只在 `readyToSuspend`
状态接受 `rtcWakeup`。

### 原厂待机对照（2026-11-05 23:51 → 11-06 08:39）

退出 KOReader、关 Wi‑Fi，由 powerd 按原厂流程休眠约 8.6 h（中途 00:59 醒一次）。
- 库仑计数和 `charge_now` 一夜只降 3–5 mAh，比开头约 8 分钟的清醒耗电还少，说明 **powerd 的休眠期间库仑计数器不计数**，不能用它测原厂待机。
- 改用电压：按两次不同负载的读数估出内阻约 0.17 Ω，换算到同一负载后，电压一夜约降 20 mV。按驱动里 1500 mAh 的 OCV 表，约等于 29 mAh，扣掉开头的清醒耗电后，**原厂休眠约 2–3.5 mA**，和我们 `rtcwake` 的底电流（约 3 mA）同一量级。
- 结论：原厂"约 0.7 mA"的说法没有得到支持，底电流基本就是硬件水平。继续省电应以减少唤醒次数和缩短每次清醒为主。
