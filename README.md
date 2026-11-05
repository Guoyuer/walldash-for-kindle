# kindle-mod

把越狱后的 Kindle Paperwhite 10 代（PW4，固件 5.18.1）做成挂墙的时钟 + 天气面板。

## 组成

| 目录 | 作用 |
|---|---|
| `deskdash.koplugin/` | KOReader 插件：4 页仪表盘（现在 / 逐小时 / 7 天 / 详情），数据来自 Open-Meteo + ip-api |
| `devagent/` | Kindle 端调试代理：通过 Wi-Fi 轮询电脑上的中继，执行命令、上传截图 |
| `tools/` | 电脑端：`devserver.py`（中继）、`kctl.py`（命令 / 截图 / 推送）、`deploy_dash.sh`（部署插件） |
| `documents/` | Kindle 书库里的 scriptlet（Dev Agent 启动 / 停止） |

## 日常使用

- 开机后在 Kindle 书库里点 **KOReader**，仪表盘会自动打开。
- 左右滑动翻页；向下滑关闭（回到 KOReader）；点一下立即刷新天气。
- 设置：KOReader 菜单 → 工具 → Desk dashboard（自动打开、24 小时制、华氏度）。

## 开发 / 调试

1. 电脑上：`python tools/devserver.py`（第一次运行前生成 `tools/.devtoken`，并写入 `devagent/config.sh`：`SRV=http://<电脑IP>:8765`、`TOK=<token>`）
2. Kindle 上：点 **Dev Agent - Start**
3. 常用命令：

```bash
python tools/kctl.py run "uname -a"
python tools/kctl.py shot
python tools/kctl.py dash next        # 给插件发命令：next | prev | refresh | close | page N
sh tools/deploy_dash.sh               # 推送插件并重启 KOReader
```

注意：KOReader 会独占触摸屏，所以 `kctl.py tap/swipe` 只在 Kindle 原生界面里有效；插件用 `dash` 命令控制。
