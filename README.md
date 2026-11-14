# WallDash for Kindle

[English](README.en.md)

把旧 Kindle Paperwhite 4 挂在墙上，变成远处也能看清的墨水屏时钟和天气面板。WallDash 运行在已越狱设备上的 KOReader 中。四页分别显示当前天气、24 小时温度和降水概率、7 天预报，以及风、紫外线、空气质量和月相等详情。

<img src="docs/dashboard.png" width="320" alt="WallDash 首页，显示时钟、当前温度和降雨提示">

## 支持范围

支持 **Kindle Paperwhite 4（第 10 代，2018）**。实测组合为固件 **5.18.1** 和 KOReader **2026.07.2**（`kindlehf`）。[桌面界面测试](CONTRIBUTING.md#ui-and-hardware-testing)可在 KOReader 的 SDL 环境运行。

## 安装

1. 在已越狱的 PW4 上安装并运行一次 [KOReader](https://github.com/koreader/koreader/wiki/Installation-on-Kindle-devices)。
2. 退出 KOReader，用 USB 把 Kindle 连到电脑。从 [Releases](https://github.com/Guoyuer/walldash-for-kindle/releases) 下载并解压插件 ZIP，或克隆本仓库。把整个 `deskdash.koplugin` 文件夹复制到 Kindle USB 盘的 `koreader/plugins/` 下。确认最终路径为 `koreader/plugins/deskdash.koplugin/main.lua`。
3. 安全弹出 Kindle，连上 Wi-Fi，再从书库打开 KOReader。WallDash 默认自动打开。也可以在 KOReader 的 **工具 → WallDash → Open dashboard** 打开。

更新时先退出 KOReader，再替换插件目录。卸载时退出 KOReader 并删除插件目录，在插件管理里重新启用 **Auto suspend**，然后重启 KOReader。

## 操作与电池模式

- 左右滑动翻页，轻点刷新天气，长按返回 KOReader。开启自动打开时，文件管理器闲置约 5 分钟后会重新打开 WallDash。天气页闲置约 2 分钟后回到时钟页。
- 第 2–4 页右下角的齿轮可切换中文或 English、12 或 24 小时制、摄氏或华氏，以及横屏或竖屏。
- **电池模式默认开启。** 拔电后，时钟页闲置时每分钟唤醒并更新，凌晨 2:00–5:00 改为每 10 分钟。按电源键可唤醒操作约 60 秒。通常电池供电时每小时、插电时每 15 分钟自动更新天气。凌晨 2:00–5:00 两种供电状态都暂停定时天气更新。
- 在 KOReader 的 **工具 → WallDash** 可关闭自动打开或电池模式。WallDash 在 PW4 上会将 KOReader 的 Auto suspend 标为禁用，从下次启动生效。关闭 WallDash 的电池模式也适用。

## 天气数据与隐私

默认通过 [ip-api](https://ip-api.com/docs/api:json) 的 HTTP 接口按公网 IP 查找大致位置。预报、降水临近预报和 AQI 由 [Open-Meteo](https://open-meteo.com/) 提供并经 WallDash 整理展示。美国境内的气象站实况和预警来自 [美国国家气象局](https://www.weather.gov/documentation/services-web-api)。天气请求会向对应服务发送经纬度。

如需固定位置或跳过 IP 定位，可[手动设置经纬度](docs/weather-accuracy.md#fixed-location)。

Open-Meteo 数据采用 [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/)。项目默认使用仅供非商业用途的免费 API，详见 [Open-Meteo 服务条款](https://open-meteo.com/en/terms)。

## 开发与贡献

参见[贡献指南](CONTRIBUTING.md)。项目源码采用 [GNU AGPL v3](LICENSE)。
