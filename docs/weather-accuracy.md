# 天气数据准确度调研

2026-11-05 · 位置：Queens Plaza North（Long Island City，约 40.751, -73.939）

## 结论

1. **现在用的 Open-Meteo 默认组合（`best_match`），对这个位置不是最准的。**过去 7 天，它提前一天的温度预报平均误差为 2.4–2.7 °C，并且系统性偏冷约 2 °C。
2. **美国国家气象局的 NBM（National Blend of Models，Open-Meteo 里叫 `ncep_nbm_conus`）明显更准**：温度误差 0.9–1.1 °C，偏差不到 1 °C，云量误差也最小。
3. **Open-Meteo 的"当前天气"是模型推算，不是实测。**2026-11-05 下午，它报"晴"（云量 7%），而附近三个气象站的实测都是阴天。这一项已经在 0bde7c6 改成采用最近的 NWS 气象站实测。
4. **建议**：预报数据改为优先用 NBM。NBM 没有的数据（紫外线）用默认组合补；离开美国时整体退回默认组合。

## 方法

- **预报**：Open-Meteo [Previous Runs API](https://open-meteo.com/en/docs) 的 `*_previous_day1` 变量，也就是各模型**提前一天**发布的逐小时预报，避免拿"事后分析"作弊。
- **实测**：美国气象局 api.weather.gov 上两个站逐小时的例行观测（每小时约 :51 分的 METAR）：
  - **KLGA** 拉瓜迪亚机场：约 6 km，自动站，云量报告完整
  - **KNYC** 中央公园：约 4 km，距离最近
- **时段**：截至 2026-11-05 20:34 UTC 的 7 天。KLGA 有 95 个小时、KNYC 有 142 个小时同时有预报和实测。
- **指标**：
  - 温度平均绝对误差（MAE）和偏差（预报减实测，负数表示预报偏冷）
  - 云量 MAE：实测云层换算成百分比（FEW 19%、SCT 44%、BKN 75%、OVC 100%），取最厚的一层
  - "阴不阴"命中率：预报和实测是否同时 ≥60% 或同时 <60%
  - 降雨：每小时 ≥0.2 mm 记为有雨
- **复现**：`python tools/verify_forecast.py`，可以隔一段时间再跑，看结论是否稳定。

## 结果

### KLGA 拉瓜迪亚（95 小时）

| 模型 | 温度 MAE | 偏差 | 云量 MAE | 阴/不阴 命中 |
|---|---|---|---|---|
| **NBM** | **1.10 °C** | **−0.75** | **25.3%** | 68% |
| ICON（德国 DWD） | 1.53 | −1.47 | 32.5% | 72% |
| ECMWF IFS 0.25° | 1.74 | −1.50 | 32.9% | 59% |
| GEM（加拿大） | 1.93 | −1.62 | 37.7% | 65% |
| GFS | 2.69 | −2.55 | 35.5% | 65% |
| **best_match（现在用的）** | **2.69** | **−2.55** | 35.5% | 65% |

### KNYC 中央公园（142 小时）

| 模型 | 温度 MAE | 偏差 | 云量 MAE | 阴/不阴 命中 |
|---|---|---|---|---|
| **NBM** | **0.92 °C** | **−0.16** | 21.1% | 91% |
| ICON | 1.13 | −0.56 | 32.3% | 75% |
| ECMWF IFS 0.25° | 1.28 | −0.85 | 29.5% | 77% |
| GEM | 1.54 | −0.88 | 7.6%\* | 92%\* |
| GFS | 2.37 | −2.13 | 40.7% | 61% |
| **best_match（现在用的）** | **2.37** | **−2.13** | 40.7% | 61% |

\* KNYC 的云层报告不完整，很多小时没有云层数据，所以 KNYC 的云量对比只能参考；判断云量以 KLGA 为准。

### 降雨

这 7 天只有 1 个小时有降水，NBM 报中了，其他模型都没报中，但样本太少，不能下结论。从前瞻预报能看出明显差别（11-05 下午取数）：

| 来源 | 11-05 当天降水 | 11-06（周五）降水 | 11-06 降水概率 |
|---|---|---|---|
| best_match | 0.0 mm | 2.5 mm | 98% |
| NBM | 5.2 mm | 25.8 mm | 98% |
| NWS 官方预报 | 今晚 "Light Rain" 82% | "Rain" | 90% |

- 当天中午中央公园实测到"Light Rain and Fog/Mist"。best_match 报当天 0 mm，NBM 报 5.2 mm。
- best_match 对周五降水量的预报，在当天下午几次刷新之间先后给出过 7.7、78.4、2.5 mm，跳动很大；NBM 和官方预报一致。

### 当前天气（11-05 约 15:30 本地时间）

| 来源 | 天空状况 |
|---|---|
| best_match "current"（模型） | Clear，云量 7–18% |
| NBM "current"（模型） | Partly Cloudy（weather_code 2） |
| KNYC 中央公园实测 | Cloudy（中午报过 Light Rain and Fog/Mist） |
| KLGA 拉瓜迪亚实测 | Mostly Cloudy / Cloudy |
| KJFK 肯尼迪机场实测 | Mostly Cloudy |

## 为什么默认组合不准

- Open-Meteo 文档说明：默认组合以 DWD ICON、NOAA GFS、ECMWF IFS 这几个全球模型为骨架，北美叠加 NOAA 的 RRFS 区域模型；每个变量、每个小时优先用分辨率最高的模型。"当前天气"取自模型的 15 分钟数据，**不是观测**。
- 在 Previous Runs API 里，best_match 的结果和 GFS 完全一样，说明在这个位置，提前一天的默认预报实际上就是 GFS。GFS 在这 7 天里是最差的。
- 实时版本可能还叠加了 RRFS，会稍好一点，但当天它仍然报"晴"、周五只报 2.5 mm，说明问题依然存在。
- NBM 是 NWS 把几十个模型做统计融合，并用历史观测做偏差校正的产品，也是 NWS 官方逐点预报的基础，所以在美国境内表现最好，在意料之中。

## 各项数据的现状和建议

| 看板上的数据 | 现在的来源 | 评价 | 建议 |
|---|---|---|---|
| 首页天空状况、图标 | 最近 NWS 站实测（KNYC） | 最好的来源 | 保持 |
| 天气预警 | NWS 官方 | 权威来源 | 保持 |
| 日出日落、月相 | 天文计算 | 精确 | 保持 |
| 当前温度、体感、湿度、露点、风 | best_match | 偏冷约 2 °C | **改用 NBM** |
| 逐小时、7 天预报 | best_match | 温度、云量都不如 NBM | **改用 NBM** |
| 降雨提示、降水量 | best_match | 不稳定，量级偏小 | **改用 NBM** |
| 紫外线 | best_match | NBM 没有这一项 | 继续用 best_match |
| 空气质量（US AQI） | Open-Meteo 大气模型（CAMS） | 模型值，不如实测 | 可选：改用 AirNow 实测（需要免费 API key） |

### NBM 的数据覆盖（用看板现在的请求测试）

- current 的所有字段、15 分钟降水、hourly、daily 都有值。
- `daily.uv_index_max` 全部为空。

### 实现方案

- **一次请求两份数据**：`models=ncep_nbm_conus,best_match`，不增加请求次数。
- **在 Lua 里合并**：每个字段优先用 NBM 的值，没有就用 best_match 的值（比如紫外线）。离开美国时 NBM 全部为空，会自动整体退回 best_match。
- **加单元测试**：覆盖合并逻辑，包括 NBM 缺字段、整体缺失这两种情况。
- **耗电**：只是响应体大约翻倍（几 KB），Wi-Fi 在线时间基本不变。

## 局限

- 只有 7 天、约 100–140 个小时的样本，而且是同一种天气形势。温度和云量的差距足够大，结论比较可靠；降雨基本没有样本。
- 评估的是**提前一天**的预报。看板首页更依赖未来几小时，短时效下模型之间的差距可能更小，也可能不同。
- 实时 best_match 可能比 Previous Runs API 里的版本略好，因为可能叠加了 RRFS，而这个接口里没有对应的历史版本可比。
- 公开的准确度排名（[ForecastAdvisor](https://forecastadvisor.com/NewYork/LongIslandCity/11101)）只评比 AccuWeather、微软这类消费级服务，2026 年美国 1–7 天预报排第一的是微软（[评分方法](https://forecastadvisor.com/docs/about)）。它没有评比 Open-Meteo 或 NBM，所以这份报告靠自己的实测对比。

## 参考

- [Open-Meteo Forecast API 文档](https://open-meteo.com/en/docs)：best_match 的组成、current 来自模型、Previous Runs API
- [Open-Meteo GFS & HRRR API](https://open-meteo.com/en/docs/gfs-api)：HRRR、NBM 覆盖范围
- [ForecastAdvisor – Long Island City](https://forecastadvisor.com/NewYork/LongIslandCity/11101)、[How It Works](https://forecastadvisor.com/docs/about)
- [BGR：天气 App 用哪个数据源](https://bgr.com/tech/which-weather-service-should-you-use-in-carrot-weather-and-other-iphone-weather-apps)
- NWS API：`api.weather.gov/stations/{KLGA,KNYC,KJFK}/observations`、`/gridpoints/OKX/35,44/forecast`
