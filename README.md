# 会议录音

本地录下「你的麦克风 + 对方的系统音频」，合成一个 `.m4a`。不上传、不注册、不转录。转录交给你自己的助手。

**不用安装 Xcode。**

微信通话里，对方的声音走的是系统音频，不是麦克风。所以必须两路一起录。

## 两条路

| | 菜单栏 App | 一条命令的后备 |
| --- | --- | --- |
| 要不要编译 | 不用。GitHub Actions 在苹果机器上编好，你下载 zip | 不用。Homebrew 装现成工具 |
| 系统音频怎么来 | macOS 自带的 ScreenCaptureKit，**不用 BlackHole** | BlackHole + 多输出设备 |
| 系统 | macOS 13 或更新，Apple Silicon | macOS 12 或更新，装得了 Homebrew 即可 |
| 什么时候用 | 装好后一直挂在菜单栏 | 现在就要录，或者还没等到构建完成 |

两条路的文件都在同一个文件夹：

`文稿/MeetingRecordings/会议录音_年月日_时分秒.m4a`

文件名用 Mac 当前时区。时区设成上海，名字就是上海时间。

## 菜单栏 App（推荐）

构建发生在 GitHub 的 macOS 托管机器上，不在你的电脑上。

1. 把这个仓库放在 GitHub 上。
2. 打开 **Actions** → **Build macOS App**。推送之后它会自己跑；也可以点 **Run workflow**。
3. 跑完后，在该次运行页面底部下载 Artifact **MeetingRecorder-arm64**（保留 14 天）。
4. 如果打了 `v` 开头的 tag（例如 `v1.0.0`），同一个 zip 也会出现在 **Releases**。
5. 解压。里面有 `MeetingRecorder.app` 和 `请先读我.txt`。
6. 先把 App 拖进「应用程序」，再授权。授权之后再移动，系统可能要求重新勾选。
7. 如果提示无法打开或已损坏，在终端执行（路径改成你的）：

```bash
xattr -dr com.apple.quarantine /Applications/MeetingRecorder.app
```

然后在 Finder 里**右键 → 打开 → 仍要打开**。这是 ad-hoc 签名，没有苹果公证，Gatekeeper 会拦从网上下来的包。这是预期现象。

8. 点菜单栏麦克风图标。第一次会展开权限说明。允许这两项：

- **麦克风**
- **屏幕录制**（较新系统里叫 **屏幕与系统音频录制**）

允许屏幕录制之后，**完全退出再打开**。macOS 不会让当前进程立刻拿到这项权限。本应用不保存画面，只是用这项权限采集系统音频。

9. 点 **开始录音**。菜单栏图标变红，并显示时间。再点 **停止录音**。用「打开录音文件夹」或「在访达中显示最近一次」找到文件。

每次重新下载一份新 zip，签名都会变，权限要再授一次。

### 权限字符串

系统弹出的说明来自 App 的 `Info.plist`：

| 系统设置里的开关 | Info.plist 键 | 文案 |
| --- | --- | --- |
| 麦克风 | `NSMicrophoneUsageDescription` | 会议录音需要使用麦克风，以录下你在微信或会议中的发言。录音只保存在本机。 |
| 屏幕录制 / 屏幕与系统音频录制 | `NSScreenCaptureUsageDescription` | 会议录音需要「屏幕录制」权限来采集系统音频（微信里对方的声音）。本应用不保存屏幕画面，只把声音写进本机音频文件。 |
| 若系统另外询问系统音频 | `NSAudioCaptureUsageDescription` | 会议录音需要采集系统音频，以录下微信或会议中对方的声音。录音只保存在本机。 |

实际采集用的是 ScreenCaptureKit（屏幕录制这一项），不是虚拟声卡，也不是 Core Audio 进程 tap。第三行是留给较新系统可能出现的系统音频说明，避免那张提示是空白。

没有单独的「只录系统音频、不在屏幕录制列表里出现」的开关。苹果把这件事放在屏幕录制里，即使我们把画面收成 2×2、每秒 1 帧并立刻丢掉。

### 用微信时

1. 先允许上面的两项权限，并重启过本应用。
2. 微信正常打语音或视频，输出设备用你平时的扬声器或耳机即可，不用改。
3. 点 **开始录音**。你说话走麦克风，对方说话走系统音频，写进同一个文件。
4. 通话结束点 **停止录音**。把 m4a 发给助手做转录。

菜单里两根电平（麦克风 / 系统音频）用来确认两路都有声音。对方说话时「系统音频」应该动。如果一直不动，多半是屏幕录制没生效：退出应用再开，或到系统设置里确认开关是开的。

## 一条命令的后备（不编译）

这条路**需要 BlackHole**。菜单栏 App 能用之后就不必再靠它。

在仓库目录：

```bash
bash fallback/install.sh
```

脚本会用 Homebrew 安装 `ffmpeg`、`blackhole-2ch`，并尽量安装 SwiftBar。BlackHole 是声卡驱动，安装器会要管理员密码。如果它要求重启，重启后再继续。

然后做一次多输出设备（否则要么听不到，要么录不到对方）：

1. 打开「音频 MIDI 设置」（安装脚本会试着帮你打开；也可以聚焦搜索）。
2. 左下角 **+** → **创建多输出设备**。
3. 勾选你的扬声器或耳机，再勾选 **BlackHole 2ch**。
4. 主设备选扬声器，不要选 BlackHole。
5. **系统设置 → 声音 → 输出** 选这个多输出设备。
6. **输入**保持你的麦克风，不要改成 BlackHole。

检查并录音：

```bash
~/.meeting-recorder/record.sh devices
~/.meeting-recorder/record.sh start
~/.meeting-recorder/record.sh stop
```

打开 SwiftBar 后，菜单栏有一个圆点。灰点是空闲，红点加时间是正在录音。菜单里是「开始录音」「停止录音」「打开录音文件夹」。

第一次录音时，系统可能问是否允许「终端」或 SwiftBar 使用麦克风，选允许。

`~/.local/bin/meeting-recorder` 是同一支脚本。如果终端找不到它，把 `~/.local/bin` 加进 PATH，或直接用上面的完整路径。

这条路把两路分别录成临时 wav，停止时混成 m4a。两块声卡的时钟长时间会有一点点漂移，几小时的会更明显。菜单栏 App 用同一条时间轴混音，没有这个问题。

## 系统版本

- **菜单栏 App**：macOS 13（Ventura）及以上。系统音频 API `SCStreamConfiguration.capturesAudio` 从 13.0 开始。建议 macOS 14 或更新。只提供 Apple Silicon（arm64）构建。
- **后备脚本**：能装 Homebrew、ffmpeg、BlackHole 的 Mac 即可，包含 Intel。
- macOS 12 及更早没有这套系统音频采集，菜单栏 App 不能用。不要为了这条路去装完整 Xcode，也不要装 BlackHole 给菜单栏 App——它用不到。

受 DRM 保护的播放（例如部分 Apple Music）可能录成静音。微信、浏览器、普通会议软件一般可以。

## 签名

zip 里的 App 是 **ad-hoc 签名**（`codesign -s -`），没有开发者证书，也没有公证。

- 麦克风和屏幕录制认的是这个签名。不签名的话，权限经常勾上也不生效。
- 每次重新构建，cdhash 都会变，系统把它当成另一个 App，要重新授权。
- 没有开 App Sandbox，也没有开 Hardened Runtime，这样本地 ad-hoc 运行时麦克风不会被沙盒额外拦住。
- 应用不申请网络权限，代码里没有上传。

本仓库在 Linux 上写的，这里没有 macOS SDK，没法在这边编译或签名。工程文件和 GitHub Actions 是按能在 `macos-latest` 上编过的方式写的。`scripts/build-app.sh` 是 Actions 里实际执行的命令。

## 隐私

只写本地文件。没有账号，没有统计，没有云同步。

如果你的 Mac 打开了「桌面与文稿」iCloud，系统可能会自己同步 `文稿/MeetingRecordings`。那是 macOS 的同步，不是这个应用在上传。不想同步就把这个文件夹移出文稿，或关掉文稿的 iCloud（应用本身没有设置项可以关）。

## 文件长什么样

AAC，48 kHz，立体声，约 128 kbps，一个 `.m4a`。两路已经混在一起，不是两条音轨。正常停止会收尾，文件可以直接播。App 每约 10 秒写一次片段，万一进程被强杀，多半还能播到最后一个片段（可能少几秒）。

## 出问题的时候

- **菜单栏没有图标**：看顶部状态栏，不要在程序坞里找。这是只驻留菜单栏的应用。图标被系统收进「控制中心」的话，按住 Command 把它拖出来。
- **系统设置的列表里没有这个 App**：先点一次「允许」或「开始录音」，macOS 才会把它加进列表。名字是「会议录音」或 `MeetingRecorder`。
- **对方没有声音**：屏幕录制开关开了，但是没有退出重开。或者后备方案里系统输出没有走 BlackHole。
- **自己没有声音**：麦克风开关。后备方案还要看终端 / SwiftBar 有没有麦克风权限。
- **文件很短或打不开**：点的是停止，不是直接强制退出。强制退出时 App 会尽量先保存。
- **Actions 失败**：工作流在 `.github/workflows/build-macos-app.yml`。如果 `macos-latest` 的镜像以后变了，把 `runs-on` 改成当时还带 Xcode 的 `macos-15` 或 `macos-14`。

## 想改代码

仍然不必在自己的 Mac 上装 Xcode。改完推上去，等 Actions 重新出 zip。

工程是普通的 Xcode 项目（`MeetingRecorder.xcodeproj`），部署目标 macOS 13，只编 arm64。入口是菜单栏 `NSStatusItem`，面板是 SwiftUI。系统音频在 `SystemAudioCapture.swift`，麦克风在 `MicrophoneCapture.swift`，混音和写文件在 `RecordingEngine.swift`。麦克风没有开语音处理：那条路径会把系统音频采集弄成静音。

画面配置故意是 2×2、每秒 1 帧，并且仍然挂了一个把画面丢掉的输出。不要把帧间隔改成 `CMTimeScale.max`，那会按显示器刷新率合成全屏，空耗 CPU。
