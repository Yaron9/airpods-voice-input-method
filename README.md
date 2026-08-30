# AirPods Siri → 微信输入法语音桥接

一个原生 macOS 菜单栏 App：长按 AirPods 左耳启动语音输入，单击停止并发送。App 不占用 Dock，只提供运行状态、启动、停止、使用说明和退出。

## 普通用户安装

不需要 Xcode、开发证书或 BetterTouchTool：

1. 下载发布页中的 `AirPods-Siri-Voice-Bridge-*-macOS.zip` 并解压。
2. 把 **AirPods Siri Voice Bridge.app** 拖进“应用程序”文件夹。
3. 第一次双击尝试打开。由于当前测试版没有 Apple Developer ID 公证，macOS 会阻止启动。
4. 打开“系统设置 → 隐私与安全性”，向下找到刚被阻止的 App，点击“仍要打开”并确认。
5. 按照下文完成语音输入法、AirPods 左耳和辅助功能三项设置。

上述 Gatekeeper 操作只需在首次安装或更新版本后进行。只从本仓库发布页或作者提供的可信渠道下载文件。

## 使用前必须设置

### 1. 设置语音输入法

打开你的语音输入法设置，将语音输入快捷键设为：

```text
长按 Fn
```

本项目已经使用微信输入法完成实机验证。其他输入法需要支持“按住快捷键录音，松开快捷键结束”。

### 2. 设置 AirPods 左耳

在 Mac 或 iPhone 的蓝牙设置中打开 AirPods 详情，将：

```text
按住 AirPods → 左耳 → Siri
```

设置会随 AirPods 同步。完成后，长按左耳会唤醒 Siri，桥接 App 才能识别这次操作。

### 3. 授予辅助功能权限

App 必须获得 macOS“辅助功能”权限，才能模拟长按语音键和发送回车：

1. 先运行一次 App；首次启动时 macOS 可能自动弹出授权提示。
2. 打开“系统设置 → 隐私与安全性 → 辅助功能”。
3. 找到 **AirPods Siri Voice Bridge** 并打开右侧开关。
4. 如果列表中没有它，点击 `+`，从“应用程序”文件夹选择 **AirPods Siri Voice Bridge.app**。源码开发版位于 `~/Applications`。
5. 回到菜单栏，点击波形图标并选择“启动”；必要时退出并重新打开 App。

必须授权的对象是 **AirPods Siri Voice Bridge.app**，不需要给 BetterTouchTool、终端或开发工具授权。桥接 App 本身不采集麦克风，麦克风权限由你使用的语音输入法自行管理，也不需要“完全磁盘访问”。当前实机验证只需“辅助功能”；如果其他 macOS 版本因备用的耳机按键监听额外弹出“输入监控”提示，仅在单击无法停止时按系统提示授权即可。

如果系统已经打开开关但 App 仍提示无权限，请删除辅助功能列表中的旧条目，再从“应用程序”文件夹重新添加上述 App。不要授权 `build/` 目录中的临时构建版本。无证书 ad-hoc 版本更新二进制后，macOS 可能要求重新执行这次授权；同一个 ZIP 重装不会反复变化。

## 已解决的根因

旧实现监听 Siri 的 `#HotKey type: 10/11/12` 日志。它们实际是所有键盘事件的通用 `keyDown/keyUp/flagsChanged`，不是 AirPods 的按下和松开；桥接器自己注入的 Fn 还会再次进入同一日志通道。

真实 AirPods 实体操作在本机留下的稳定调用是：

```text
SiriNCActionHearstDoubleTap - BluetoothHFP
```

AirPods 只给 Siri 一次调用，不公开可用的按下/松开对。微信输入法则会忽略普通 `CGEvent` 注入。修复采用两项变化：

1. 只接受 `HearstDoubleTap/BluetoothHFP`，拒绝普通键盘和菜单栏 Siri 调用。
2. 用 `IOHIDPostEvent` 发送真正的 Fn modifier `NX_FLAGSCHANGED + NX_SECONDARYFNMASK`。注入时保留用户正在按住的 Shift/Cmd/Option/Ctrl。
3. 录音期间通过 `MPRemoteCommandCenter` 临时接管 AirPods 单击；停止后立即归还媒体控制，避免误启动 Music。

收到 AirPods 调用后，桥接器会结束 Siri/SiriNCService，等待 150ms 完成音频释放和焦点恢复，再启动微信输入法语音。

## 高级：配置其他语音按键

编辑 [`config/voice-key`](config/voice-key)，文件中只保留一个按键名称。默认值：

```text
fn
```

支持以下值：

```text
fn control option command shift
f1 f2 f3 f4 f5 f6 f7 f8 f9 f10 f11 f12
```

修改后重启桥接器：

```bash
./scripts/stop.sh
./scripts/start.sh
```

也可以只为本次启动临时覆盖，不修改文件：

```bash
AIRPODS_BRIDGE_VOICE_KEY=option ./scripts/start.sh
```

普通用户保持 `fn` 即可。本项目不自动读取输入法快捷键：不同输入法使用不同的私有配置格式，显式配置一个按键更简单、稳定，也便于排查问题。

## 使用

普通用户直接打开“应用程序”文件夹中的 App。源码开发者完成上面的三项设置后，可运行：

```bash
./scripts/start.sh
```

启动成功后，菜单栏会出现波形图标：

- 实心图标：桥接运行中。
- 空心图标：桥接已停止。
- 点击图标可启动、停止、查看使用说明或退出 App。

### 刘海屏看不到图标

MacBook 菜单栏图标过多时，部分图标会被摄像头刘海遮住。App 已尽量缩小图标占位，并会记住手动调整后的位置。第一次使用时：

1. 临时退出一个不常用的菜单栏 App，让桥接图标露出来。
2. 按住 `Command (⌘)`，把波形图标拖到控制中心旁边。
3. 松开后位置会自动保存，以后启动仍会回到这里。

不要把图标拖出菜单栏；拖出代表移除并退出 App。macOS 没有允许普通 App 强制抢占最右侧位置的公开接口，因此本项目不使用可能影响稳定性和 App Store 审核的私有 API。

- 第一次长按 AirPods：启动语音输入。
- 单击 AirPods：结束语音输入，先用一次回车确认输入法组合文字，再用第二次回车发送。
- 停止桥接器：`./scripts/stop.sh`
- 启动脚本通过当前图形会话的 `launchd` 托管桥接器；关闭终端或开发工具不会导致桥接器退出。
- 源码启动脚本会把稳定的 App Bundle 安装到 `~/Applications/AirPods Siri Voice Bridge.app`，避免每次从临时构建路径授权。
- 长按 AirPods 后会关闭 Siri，重新激活触发前的应用并恢复输入焦点，然后持续按住配置的语音键；录音期间单击 AirPods 会释放该键、结束输入并发送回车。
- 只有主动单击停止且原应用仍保持焦点时才发送回车；切换焦点、安全超时或桥接器退出时不会误发送。
- 使用微信输入法时，若它自行结束录音，桥接器也会立即释放语音键。
- 语音键最长保持 60 秒，避免异常情况下按键永久卡住。
- 运行日志：`/tmp/airpods-fn-test/siri-bridge.log`

桥接器不会创建 LaunchAgent，也不会开机自启。

## 打包给别人使用

运行：

```bash
./scripts/package-release.sh
```

脚本会生成同时支持 Apple Silicon 和 Intel Mac 的 ZIP，位置在 `dist/`。默认使用 ad-hoc 签名，不需要 Apple 开发证书；用户需要按“普通用户安装”中的步骤首次手动允许。

这里的 ad-hoc 签名不是 Apple 证书，只是 macOS App 正常运行所需的本地完整性签名。完全不签名会让 Gatekeeper 和辅助功能授权更不稳定，因此发布包保留这层无需账号、无需付费的签名。

如果以后希望付费用户双击即可正常安装，建议加入 Apple Developer Program，改用 Developer ID 签名并公证，而不必上架 Mac App Store。可通过 `AIRPODS_BRIDGE_SIGN_IDENTITY` 指定 Developer ID：

```bash
AIRPODS_BRIDGE_SIGN_IDENTITY="Developer ID Application: …" ./scripts/package-release.sh
```

## 许可与贡献

本项目以 [PolyForm Noncommercial 1.0.0](LICENSE) 提供源码：个人学习、研究、非商业使用和非商业贡献均可；商业使用需要取得项目所有者的单独授权。它是 source-available 许可，不属于 OSI 定义的开源许可证。

欢迎提交 Issue 和 Pull Request。为保证项目所有者能够统一进行商业发行，提交贡献前请阅读 [CONTRIBUTING.md](CONTRIBUTING.md) 中的贡献授权条款。

## 验证

```bash
./tests/run-regression.sh
```

回归测试包括：

- 普通 `#HotKey`、键盘 Siri、菜单栏 Siri 均不会被识别为 AirPods。
- 测试开始时显式选择微信输入法，避免当前输入源为 ABC 时产生假阴性。
- 回放本机真实 AirPods 事件签名。
- 使用默认配置通过 HID 层保持 Fn 2 秒，并从 WeType 系统日志验证录音确实 `startRunning` 和 `stopRunning`。
- 验证所有支持的按键名称、大小写归一化、默认值和非法配置拒绝逻辑。
- 使用独立前台接收器验证主动停止后确实收到 Return `keyCode 36`，并验证异常退出清理时不注入回车。
- 在语音键按住期间发送 stop request，验证进程优雅退出前一定补发 key-up。

`--self-test` 使用 2 秒按住模式，测试结束后不会遗留录音；生产模式持续按住配置键，直到 AirPods 单击停止。

## 文件

- `src/airpods-siri-voice-bridge.swift`：AirPods 事件过滤、Siri 音频释放和状态机。
- `src/fn-injector.c`：IOHIDSystem Fn modifier 注入。
- `config/voice-key`：语音输入法激活键配置。
- `scripts/build.sh`：构建。
- `scripts/start.sh` / `scripts/stop.sh`：通过 `launchd` 持久启动，并在停止时执行 Fn 释放清理。
- `tests/run-regression.sh`：端到端回归测试。
