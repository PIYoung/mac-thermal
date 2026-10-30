<p align="center"><img src="docs/images/app-icon.png" alt="Mac Thermal" width="64" height="64"></p>
<h1 align="center">Mac Thermal</h1>
<p align="center"><strong>在菜单栏，一眼了解Mac状态。</strong><br>Apple Silicon · macOS 14+ · MIT</p>
<p align="center"><a href="README.md">한국어</a> · <a href="README.en.md">English</a> · <a href="README.ja.md">日本語</a> · <strong>简体中文</strong></p>
<p align="center"><a href="https://github.com/PIYoung/mac-thermal/releases/latest"><strong>↓ 下载</strong></a> · <a href="RELEASES.md">更新记录</a></p>

<p align="center"><a href="https://github.com/PIYoung/mac-thermal/releases/tag/v2.17.0"><strong>v2.17.0</strong></a> · 应用 TOP 3 · 查看子进程</p>

## 菜单栏与面板

<p align="center"><img src="docs/images/menubar.png" alt="Codex机器人及CPU、GPU、SSD和网络菜单栏" width="460"></p>
<table align="center">
  <tr><th>Codex辅助面板</th><th>资源面板</th></tr>
  <tr>
    <td><a href="docs/images/codex-zh-CN-light.png"><img src="docs/images/codex-zh-CN-light.png" alt="Codex辅助面板" width="190"></a></td>
    <td><a href="docs/images/panel-zh-CN-cpu.png"><img src="docs/images/panel-zh-CN-cpu.png" alt="资源面板" width="215"></a></td>
  </tr>
</table>
<sub>由实际应用渲染器绘制的合成示例，半透明效果因macOS版本而异。</sub>

## 主要功能

- **菜单栏：** CPU温度与使用率、GPU使用率、SSD读写、网络速度及动画指示器。
- **点击面板：** CPU、GPU、内存、SSD、网络标签，近期图表，CPU/内存**应用 TOP 3**及子进程详情及系统运行时长。
- **温度与风扇：** CPU/GPU/SSD温度、内存**周边温度**、各指标独立警告颜色，以及CPU面板中的风扇状态和实测RPM。传感器支持因设备而异。
- **10分钟冷却（实验性）：** 在CPU → 风扇控制中按100 RPM步长选择目标。单独安装的管理员辅助程序最多控制10分钟，然后恢复Apple自动模式。基础监控不需要此辅助程序。
- **状态指引与AI说明：** 各资源标签页提供测量依据和建议操作。支持的macOS 26及以上设备可按需使用Apple设备端模型生成简短说明；模型不支持、持续高温或生成出错时会显示原因与基本指引。
- **Codex：** 左侧辅助面板显示今日本地令牌、输入/输出、缓存复用率和模型TOP 3。可选连接账号额度和活动摘要，通过纤细的原创滚动条一起浏览卡片。
- **磁盘清理：** 无需指定文件夹即可扫描主文件夹。自行选择候选文件，最终确认后移到废纸篓。也支持仅扫描指定文件夹。
- **设置：** 自选指标、10种CPU动画、动画效果及登录时启动。默认韩语，支持英语、日语及简体中文。

<details>
<summary>v2.16.0 — 可选风扇控制</summary>

- 目标不得低于当前转速或硬件最小值，也不得超过硬件最大值。保留紧凑、无重复标题的页面，以及与磁盘清理一致的`‹ CPU`返回导航。
- 在后续读取中确认生效。自动恢复至少复查10秒；无法确认时保留恢复记录。高温、热压力、传感器错误或连接断开会请求恢复自动模式。
- 已在一台Mac上实测3,000 RPM控制、取消、应用退出恢复、面板隐藏时运行以及完整10分钟到期。其他Mac、实际睡眠唤醒和辅助程序崩溃恢复仍未验证。[测试记录](docs/FAN_CONTROL_TESTS.md)

</details>

## 安装

1. 从[最新发布](https://github.com/PIYoung/mac-thermal/releases/latest)下载**DMG**，也提供ZIP。
2. 打开DMG，将**Mac Thermal.app**拖入**Applications**。
3. 启动后点击菜单栏。更新时安装新的发布版本。

> 此构建采用ad-hoc签名，未经Apple公证。如果macOS阻止运行，请勿关闭安全设置，可按下方说明从源码构建。下载文件可与`SHA256SUMS`核对。

**已安装风扇辅助程序时，请先用匹配的旧版工具移除，再替换应用。**

**风扇控制需要单独选择安装。** 使用DMG内按版本命名的Fan Tools文件夹或发布页的`fan-tools.zip`。请先阅读[安装、更新与移除说明](docs/FAN_CONTROL_SETUP.md)，再自行执行管理员安装。启动应用不会自动安装或开始控制。负载上升后，固定RPM可能无法提供足够冷却，也可能增加噪音和耗电。

<details>
<summary>从源码构建并安装</summary>

需要Apple Silicon，以及包含macOS 26 SDK的Xcode 26或兼容Command Line Tools。

```sh
git clone https://github.com/PIYoung/mac-thermal.git
cd mac-thermal
zsh scripts/install.sh --open
```

请先退出已运行的应用。安装到`~/Applications`，无需`sudo`。

</details>

## Codex记录与隐私

Codex记录读取**默认关闭**。开启后，仅从`~/.codex/sessions`提取模型名、令牌数字和时间，在内存中统计。这些文件也包含对话正文，但不会保留、显示或传输正文、命令和凭据，不修改原文件。关闭后停止读取并清除统计。

用量仅涵盖<strong>此Mac今日记录（UTC）</strong>，并非整个账号的用量或账单。可选的[官方登录连接](docs/CODEX_ACCOUNT.md)需单独同意，才会显示账号剩余额度和重置倒计时。每日数字摘要和累计令牌、连续使用天数等账号摘要，也分别需要额外同意。没有开发者数据收集服务器、分析SDK或远程日志上传。Codex运行时机器人缓慢移动，检测到新令牌记录后活跃移动10秒，再恢复缓慢移动。动画不代表实时令牌消耗或任务完成。

可在设置中选择开启额度重置通知（默认关闭）。应用运行且已连接账号额度时，确认服务器重置后仅发送一次本地通知。需要macOS通知权限，不增加查询或数据收集。

---

[技术说明](docs/DETAILS.md) · [安全](SECURITY.md) · [参与贡献](CONTRIBUTING.md) · [MIT许可证](LICENSE) · [第三方声明](THIRD_PARTY_NOTICES.txt)

<sub>在OpenAI Codex的AI协助和用户反馈下制作。</sub>
