# kindle-mod

把越狱后的 Kindle Paperwhite 10 代（PW4，固件 5.18.1）做成挂墙的时钟 + 天气面板。

## 组成

| 目录 | 作用 |
|---|---|
| `deskdash.koplugin/` | KOReader 插件：4 页仪表盘（现在 / 逐小时 / 7 天 / 详情），逐小时和 7 天预报优先用 Open-Meteo 的 NBM，首页降水提示复用小时预报，实况天况和预警来自 NWS |
| `kdev/` | Kindle 端调试：`sshd.sh`（用 Jobman 自带的 dropbear 起一个只允许密钥登录的 SSH，仅限局域网）、`authorized_keys` |
| `docs/` | `weather-accuracy.md`：各天气数据源准确度调研（7 天实测对比，`tools/verify_forecast.py` 可复现） |
| `tools/` | 电脑端：`kctl.py`（命令 / 截图 / 推送，走 SSH）、`deploy_dash.sh`（部署插件，出错自动回滚）、`check.sh`（本地检查 + 测试） |
| `documents/` | Kindle 书库里的 scriptlet（SSH - Start） |

## 日常使用

- 开机后在 Kindle 书库里点 **KOReader**，仪表盘会自动打开。
- 左右滑动翻页；长按关闭（回到 KOReader，闲置 5 分钟后自动回来）；点一下立即刷新天气。
- 首页只显示时钟和天气。滑到其他页面，点右下角齿轮可切换中文 / English、12 / 24 小时和竖屏 / 横屏。点选立即保存，点面板外关闭。
- 自动打开、电池模式、华氏度在 KOReader 菜单 → 工具 → Desk dashboard。
- **电池模式**（默认开）：不插电时，每分钟画完就睡到下一分钟（`rtcwake`，墨水屏断电保持画面）。睡眠中触屏无效，**按一下电源键**唤醒，可滑动 60 秒（前光和 Wi-Fi 只在这时打开；平时 Wi-Fi 关着，每 30 分钟（:03、:33）更新天气时才连；插电时每 15 分钟）；离开首页或刚碰过屏幕时不睡。插着电时常亮。凌晨 2–5 点每 10 分钟才醒一次，也不更新天气。耗电记录在 `/mnt/us/deskdash_power.csv`（每小时一行），`python tools/power.py` 分析：平均电流、醒着占比、预计续航天数。

## 开发 / 调试

给 AI 助手 / 后续会话的完整背景见 [AGENTS.md](AGENTS.md)。

SSH 在 KOReader 启动时由插件自动开启；KOReader 没开时可以在书库里点 **SSH - Start**。只接受 `kdev/authorized_keys` 里的密钥，不允许密码登录。

电脑上的 `~/.ssh/config`：

```
Host kindle
    HostName 192.168.0.10
    User root
    IdentityFile ~/.ssh/kindle_ed25519
    IdentitiesOnly yes
```

```bash
ssh kindle
python tools/kctl.py shot             # 截图到 tools/inbox/shot.png
python tools/kctl.py dash next        # 翻页，等绘制完成再截图
python tools/kctl.py command restart  # 给插件发命令，不截图
python tools/kctl.py push kdev/sshd.sh
sh tools/check.sh                     # 本地检查 + 单元测试（<1 秒，需要 LuaJIT：winget install DEVCOM.LuaJIT）
sh tools/deploy_dash.sh               # 检查 → 推送 → 重启 → 验证（失败自动回滚）→ 截图，约 12 秒；--shots 截全部页面
```

注意：KOReader 会独占触摸屏，插件用 `dash` 命令控制。USB 连电脑时 `/mnt/us` 被卸载，SSH 登录会失败（密钥在 `/mnt/us` 上）。
