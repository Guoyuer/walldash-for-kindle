# kindle-mod

把越狱后的 Kindle Paperwhite 10 代（PW4，固件 5.18.1）做成挂墙的时钟 + 天气面板。

## 组成

| 目录 | 作用 |
|---|---|
| `deskdash.koplugin/` | KOReader 插件：4 页仪表盘（现在 / 逐小时 / 7 天 / 详情），数据来自 Open-Meteo + ip-api |
| `kdev/` | Kindle 端调试：`sshd.sh`（用 Jobman 自带的 dropbear 起一个只允许密钥登录的 SSH，仅限局域网）、`authorized_keys`、`ktap`（模拟触摸） |
| `tools/` | 电脑端：`kctl.py`（命令 / 截图 / 推送，走 SSH）、`deploy_dash.sh`（部署插件） |
| `documents/` | Kindle 书库里的 scriptlet（SSH - Start） |

## 日常使用

- 开机后在 Kindle 书库里点 **KOReader**，仪表盘会自动打开。
- 左右滑动翻页；长按关闭（回到 KOReader，闲置 5 分钟后自动回来）；点一下立即刷新天气。
- 设置：KOReader 菜单 → 工具 → Desk dashboard（自动打开、24 小时制、电池模式、华氏度）。
- **电池模式**（默认开）：不插电时，每分钟画完就睡到下一分钟（`rtcwake`，墨水屏断电保持画面）。睡眠中触屏无效，**按一下电源键**唤醒，可滑动 60 秒；离开首页或刚碰过屏幕时不睡。插着电时常亮。电量记录在 `/mnt/us/deskdash_battery.log`（每次更新天气记一行）。

## 开发 / 调试

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
python tools/kctl.py dash next        # 给插件发命令：next | prev | refresh | close | quit | sleep | page N
python tools/kctl.py push kdev/sshd.sh
sh tools/deploy_dash.sh               # 推送插件并重启 KOReader
```

注意：KOReader 会独占触摸屏，所以 `kctl.py tap/swipe` 只在 Kindle 原生界面里有效；插件用 `dash` 命令控制。USB 连电脑时 `/mnt/us` 被卸载，SSH 登录会失败（密钥在 `/mnt/us` 上）。
