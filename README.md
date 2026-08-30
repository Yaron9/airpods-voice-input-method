# AirPods Voice 输入法

AirPods Voice 输入法是一个原生 macOS 菜单栏 App。单击一次 AirPods 开始语音输入，再单击一次停止并自动发送，全程不需要触碰键盘。

正式版本：**1.0**

## 功能

- 单击 AirPods 开始语音输入。
- 再次单击停止输入，自动确认文字并发送。
- 支持连续多轮使用，每轮都会恢复到可再次启动的空闲状态。
- 默认模拟长按 `Fn`，也可配置 Control、Option、Command、Shift 或 F1–F12。
- 菜单栏提供运行状态、启动、停止、使用说明和退出。
- 不占用 Dock，不依赖 BetterTouchTool 或其他第三方自动化软件。
- 支持 Apple Silicon 和 Intel Mac，最低要求 macOS 13。

## 使用前设置

### 1. 设置语音输入法

在自己的语音输入法中，把语音输入快捷键设为：

```text
长按 Fn
```

1.0 已使用微信输入法完成实体 AirPods 多轮验收。其他输入法需要支持“按住快捷键录音，松开快捷键结束”。

### 2. 了解 AirPods 单击行为

App 运行时会接管 AirPods 的播放/暂停单击：

- 第一次单击：开始语音输入。
- 第二次单击：停止输入并发送。

因此 App 运行期间不能使用 AirPods 单击控制音乐。停止或退出 App 后，媒体控制恢复。

## 安装

1. 从 GitHub Releases 下载 `AirPods-Voice-Input-Method-1.0-macOS.pkg`。
2. 双击安装包并完成安装。
3. App 会安装到 `/Applications/AirPods Voice 输入法.app`。
4. 从系统“应用程序”目录打开 **AirPods Voice 输入法**。

1.0 安装器会自动停止并移除以前的测试版，避免两个版本同时接管 AirPods。

当前 GitHub 安装包使用 ad-hoc 签名，适合源码发布和直接分发。如果 macOS 阻止首次打开，请在 Finder 中右键 App，选择“打开”，再确认一次。

## 辅助功能权限

App 必须获得 macOS“辅助功能”权限，才能模拟长按语音键以及发送回车：

1. 打开“系统设置 → 隐私与安全性 → 辅助功能”。
2. 找到 **AirPods Voice 输入法** 并打开右侧开关。
3. 如果列表中没有它，点击 `+`，选择 `/Applications/AirPods Voice 输入法.app`。
4. 回到 App 提示框，点击“已授权，重新启动”。

必须授权的对象是 `/Applications/AirPods Voice 输入法.app`。不需要给终端、开发工具或 BetterTouchTool 授权，也不需要“完全磁盘访问”。App 本身不采集麦克风，麦克风权限由用户选择的语音输入法管理。

如果升级后系统仍显示旧权限但 App 提示未授权，请删除辅助功能列表中的旧条目，再从 `/Applications` 重新添加当前 App。ad-hoc 签名版本的二进制变化后，macOS 可能要求重新授权。

## 菜单栏

菜单栏图标提供：

- 当前运行状态。
- 当前语音快捷键。
- 启动或停止。
- 使用说明。
- 退出。

MacBook 菜单栏图标过多时，图标可能被摄像头刘海遮住。按住 `Command` 拖动图标，可将它移动到刘海右侧；位置会由 macOS 保存。

## 配置其他语音快捷键

默认配置文件是 [`config/voice-key`](config/voice-key)，内容为：

```text
fn
```

支持：

```text
fn control option command shift
f1 f2 f3 f4 f5 f6 f7 f8 f9 f10 f11 f12
```

修改后重启：

```bash
./scripts/stop.sh
./scripts/start.sh
```

也可以在源码运行时临时指定：

```bash
AIRPODS_VOICE_INPUT_KEY=option ./scripts/start.sh
```

## 工作原理

App 运行时通过 `MPRemoteCommandCenter` 持有 Now Playing 会话，从媒体系统接收 AirPods 单击。只接受来源为 macOS 蓝牙服务 `com.apple.bluetoothd` 的媒体事件，Mac 键盘播放键等其他来源不会启动语音。IOHID 监听作为备用通道，同一次实体操作通过 350ms 窗口去重。

第一次单击通过 `IOHIDPostEvent` 按下真实的 Fn modifier；第二次单击释放 Fn，并依次发送两次回车：第一次确认输入法组合文字，第二次发送消息。切换前台应用、60 秒安全超时或退出 App 时只释放按键，不会误发送。

## 日志与排查

- 主日志：`/tmp/airpods-voice-input-method/app.log`
- launchd 标准输出：`/tmp/airpods-voice-input-method/app.stdout.log`
- launchd 错误输出：`/tmp/airpods-voice-input-method/app.stderr.log`

确认进程：

```bash
pgrep -fl airpods-voice-input-method
```

停止并安全释放语音键：

```bash
./scripts/stop.sh
```

## 从源码构建

```bash
./scripts/build.sh
open "build/AirPods Voice 输入法.app"
```

默认使用 ad-hoc 签名。生成 PKG：

```bash
./scripts/package-release.sh
```

如需 Developer ID 直接分发，可同时指定 App 与安装包证书：

```bash
AIRPODS_VOICE_INPUT_SIGN_IDENTITY="Developer ID Application: …" \
AIRPODS_VOICE_INPUT_INSTALLER_SIGN_IDENTITY="Developer ID Installer: …" \
./scripts/package-release.sh
```

当前 1.0 使用系统未公开的媒体事件来源字段区分蓝牙耳机与键盘媒体键，适合直接分发；准备提交 Mac App Store 前，需要改为审核允许的公开接口并重新做实体测试。

## 测试

```bash
./tests/run-regression.sh
./tests/run-e2e.sh
```

回归覆盖：

- 四轮“单击开始、单击停止并发送”。
- Fn 的真实按下、释放以及四轮发送状态机。
- 两次回车的确认与发送。
- 非蓝牙媒体事件过滤。
- 其他可配置语音键。
- 异常退出时释放语音键且不误发送。
- 多副本启动、安装位置优先级和辅助功能权限恢复。

实体 AirPods 与微信输入法两轮验收：

```bash
./tests/hitl-two-cycle.sh
```

## 文件

- `src/airpods-voice-input-method.swift`：AirPods 单击接管、过滤、去重和语音输入状态机。
- `src/fn-injector.c`：IOHIDSystem Fn modifier 注入。
- `config/voice-key`：语音快捷键配置。
- `scripts/build.sh`：构建通用 App。
- `scripts/package-release.sh`：生成安装到 `/Applications` 的 PKG。
- `scripts/start.sh` / `scripts/stop.sh`：开发环境启动与安全停止。
- `tests/run-regression.sh`：完整回归。
- `tests/run-e2e.sh`：四轮语音交互回归。
- `tests/hitl-two-cycle.sh`：实体 AirPods 两轮验收。

## 许可与商业使用

源码使用 [PolyForm Noncommercial 1.0.0](LICENSE) 许可。个人学习、研究、非商业使用和非商业贡献均可；商业使用需要取得项目所有者的单独授权。该许可属于 source-available，不是 OSI 定义的开源许可证。

参与贡献前请阅读 [CONTRIBUTING.md](CONTRIBUTING.md)。
