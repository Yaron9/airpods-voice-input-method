# AirPods 单击 → 微信输入法语音桥接

一个原生 macOS 菜单栏 App：第一次单击 AirPods 启动语音输入，第二次单击停止并发送。App 不占用 Dock，也不依赖 Siri。

## 普通用户安装

不需要 Xcode、开发证书或 BetterTouchTool：

1. 下载发布页中的 `AirPods-Siri-Voice-Bridge-*-macOS.pkg`。
2. 双击 PKG。由于当前测试版没有 Apple Developer ID 公证，macOS 可能阻止启动安装器。
3. 如果被阻止，打开“系统设置 → 隐私与安全性”，向下找到刚被阻止的安装器，点击“仍要打开”并确认。
4. 按安装器提示完成安装；App 会自动放到 `/Applications`，不需要手动拖动。
5. 从系统“应用程序”目录打开 **AirPods Siri Voice Bridge**，再按照下文完成三项设置。

上述 Gatekeeper 操作只需在首次安装或更新版本后进行。只从本仓库发布页或作者提供的可信渠道下载文件。

不要直接运行 ZIP、下载目录或源码目录里的 App 副本。新版会优先保留 `/Applications` 中的正式副本并自动关闭其他副本，避免菜单栏同时出现两个图标或权限状态不一致。

## 使用前必须设置

### 1. 设置语音输入法

打开你的语音输入法设置，将语音输入快捷键设为：

```text
长按 Fn
```

本项目已经使用微信输入法完成实机验证。其他输入法需要支持“按住快捷键录音，松开快捷键结束”。

### 2. AirPods 单击说明

App 运行时会常驻接管 AirPods 的播放/暂停单击：第一次单击开始语音输入，第二次单击停止并发送。因此运行期间不能再用 AirPods 单击控制音乐；停止或退出 App 后，媒体控制会恢复。

### 3. 授予辅助功能权限

App 必须获得 macOS“辅助功能”权限，才能模拟长按语音键和发送回车：

1. 先运行一次 App；首次启动时 macOS 可能自动弹出授权提示。
2. 打开“系统设置 → 隐私与安全性 → 辅助功能”。
3. 找到 **AirPods Siri Voice Bridge** 并打开右侧开关。
4. 如果列表中没有它，点击 `+`，从系统“应用程序”文件夹选择 `/Applications/AirPods Siri Voice Bridge.app`。
5. 回到 App 的提示框，点击“已授权，重新启动”。App 会重新启动一次，让 macOS 在新进程中刷新权限，然后自动运行桥接器。

必须授权的对象是 **AirPods Siri Voice Bridge.app**，不需要给 BetterTouchTool、终端或开发工具授权。桥接 App 本身不采集麦克风，麦克风权限由你使用的语音输入法自行管理，也不需要“完全磁盘访问”。当前实机验证只需“辅助功能”；如果其他 macOS 版本因备用的耳机按键监听额外弹出“输入监控”提示，仅在单击无法停止时按系统提示授权即可。

如果系统已经打开开关但 App 仍提示无权限，不要反复删除或添加：直接点击 App 提示框里的“已授权，重新启动”。只有列表中的条目指向旧位置，或者安装了二进制已变化的新版本时，才需要删除旧条目并从 `/Applications` 重新添加。不要授权下载或 `build/` 目录中的临时构建版本。无证书 ad-hoc 版本更新二进制后，macOS 可能要求重新授权；同一版本 PKG 重装不会反复变化。

## 实现原理

App 在运行期间通过 `MPRemoteCommandCenter` 持有 Now Playing 会话，从媒体系统接收 AirPods 单击；同时使用 IOHID 作为备用监听，并用 350ms 去重窗口合并同一次实体操作。第一次单击通过 `IOHIDPostEvent` 按下真正的 Fn modifier，第二次单击释放 Fn，并依次发送两次回车完成输入法确认与消息发送。整个流程不启动、关闭或监听 Siri。

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

- 第一次单击 AirPods：启动语音输入。
- 第二次单击 AirPods：结束语音输入，先用一次回车确认输入法组合文字，再用第二次回车发送。
- 停止桥接器：`./scripts/stop.sh`
- 启动脚本通过当前图形会话的 `launchd` 托管桥接器；关闭终端或开发工具不会导致桥接器退出。
- 源码启动脚本会优先复用 PKG 已安装到 `/Applications` 的正式 App，且不会尝试覆盖它；尚未安装 PKG 时才运行 `build/` 中的开发副本。
- 第一次单击后持续按住配置的语音键；第二次单击会释放该键、结束输入并发送回车。
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

脚本会生成同时支持 Apple Silicon 和 Intel Mac 的 PKG 安装程序，位置在 `dist/`。安装器会把 App 放到 `/Applications`，避免从下载目录运行时触发 App Translocation。默认 App 使用 ad-hoc 签名，不需要 Apple 开发证书；用户需要按“普通用户安装”中的步骤首次手动允许安装器。

这里的 ad-hoc 签名不是 Apple 证书，只是 macOS App 正常运行所需的本地完整性签名。完全不签名会让 Gatekeeper 和辅助功能授权更不稳定，因此发布包保留这层无需账号、无需付费的签名。

如果以后希望付费用户双击即可正常安装，建议加入 Apple Developer Program，改用 Developer ID Application 和 Developer ID Installer 签名并公证，而不必上架 Mac App Store。发布时必须同时指定 App 与安装器证书：

```bash
AIRPODS_BRIDGE_SIGN_IDENTITY="Developer ID Application: …" \
AIRPODS_BRIDGE_INSTALLER_SIGN_IDENTITY="Developer ID Installer: …" \
./scripts/package-release.sh
```

## 许可与贡献

本项目以 [PolyForm Noncommercial 1.0.0](LICENSE) 提供源码：个人学习、研究、非商业使用和非商业贡献均可；商业使用需要取得项目所有者的单独授权。它是 source-available 许可，不属于 OSI 定义的开源许可证。

欢迎提交 Issue 和 Pull Request。为保证项目所有者能够统一进行商业发行，提交贡献前请阅读 [CONTRIBUTING.md](CONTRIBUTING.md) 中的贡献授权条款。

## 验证

```bash
./tests/run-regression.sh
./tests/run-single-click-e2e.sh
```

回归测试包括：

- 测试开始时显式选择微信输入法，避免当前输入源为 ABC 时产生假阴性。
- 连续四轮“单击开始、单击停止并发送”，并断言桥接日志中没有 Siri/DoAP 参与。
- 使用默认配置通过 HID 层保持 Fn，并从 WeType 系统日志验证录音确实 `startRunning` 和 `stopRunning`。
- 验证所有支持的按键名称、大小写归一化、默认值和非法配置拒绝逻辑。
- 使用独立前台接收器验证主动停止后确实收到 Return `keyCode 36`，并验证异常退出清理时不注入回车。
- 使用独立媒体探针验证空闲状态的 Now Playing 会话能接管实体 AirPods 单击，且不会启动原媒体。
- 在语音键按住期间发送 stop request，验证进程优雅退出前一定补发 key-up。

`--self-test` 使用 2 秒按住模式，测试结束后不会遗留录音；生产模式持续按住配置键，直到 AirPods 单击停止。

## 文件

- `src/airpods-siri-voice-bridge.swift`：AirPods 单击接管、去重和语音输入状态机。
- `src/fn-injector.c`：IOHIDSystem Fn modifier 注入。
- `config/voice-key`：语音输入法激活键配置。
- `scripts/build.sh`：构建。
- `scripts/start.sh` / `scripts/stop.sh`：通过 `launchd` 持久启动，并在停止时执行 Fn 释放清理。
- `tests/run-regression.sh`：端到端回归测试。
- `tests/run-multicycle-e2e.sh`：四轮 AirPods 行为仿真，验证每轮微信录音启动、停止和发送。
- `tests/run-single-click-e2e.sh`：四轮无 Siri 单击启动/停止/发送回归。
- `tests/media-single-click-probe.swift`：实体 AirPods 空闲单击媒体接管探针。
- `tests/hitl-two-cycle.sh`：需要实体 AirPods 时使用的两轮实时验收脚本。
