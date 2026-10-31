# 提词大师 iOS 版

这是给 iPhone 用的原生 Swift 工程。**不需要 Mac**：代码推到 GitHub，用它的免费 macOS 机器编译出安装包，
再在 Windows 上用 Sideloadly + 你的 Apple ID 签进手机。

---

## 一、编译（一次性，约 10 分钟）

1. 注册 GitHub（免费）：https://github.com/signup
2. 新建一个仓库（New repository），名字随便，比如 `tidanci-ios`，选 **Private** 也可以，点 Create
3. 把本文件夹（`ios-app` 里的**全部内容**）传上去：
   - 网页上点 **Add file → Upload files**，把 `Tidanci` 文件夹、`project.yml` 一起拖进去，Commit
   - 如果 `.github` 这个隐藏文件夹没传上去（很常见），手动补：
     **Add file → Create new file**，文件名填 `.github/workflows/build.yml`，
     把本机 `.github/workflows/build.yml` 的内容粘进去，Commit
4. 点仓库上方的 **Actions** → 左边选 `build-ios` → 右边 **Run workflow** → 绿色按钮
5. 等 3~6 分钟，跑完点进这次运行，页面底部 **Artifacts** 里下载 `Tidanci-ipa.zip`，解压得到 `Tidanci.ipa`

> 第一次编译有一定概率报错（这工程是在没有 Xcode 的机器上写的）。把 Actions 里红色的报错行贴给我，我改完你再点一次 Run 就行。

## 二、装进 iPhone（一次性，约 10 分钟）

1. Windows 上装 **iTunes**（微软商店搜 iTunes 装那个桌面版，Sideloadly 需要它的驱动）
2. 装 **Sideloadly**：https://sideloadly.io
3. iPhone 用数据线插电脑，手机上点「信任此电脑」
4. 打开 Sideloadly：
   - IPA 那一栏把 `Tidanci.ipa` 拖进去
   - Apple ID 填你自己的 Apple ID
   - 点 Start，按提示输 Apple ID 密码（会走一次双重验证，正常）
5. 装完后，手机上：**设置 → 通用 → VPN与设备管理 → 开发者App → 点你的 Apple ID → 信任**
6. 回桌面打开「提词大师」，相机 / 麦克风 / 语音识别 三个权限都给

## 三、会过期的说明（重要）

免费 Apple ID 签的 App **7 天过期**，到期点开就闪退。到期的处理：

- 重新打开 Sideloadly，把同一个 ipa 再 Start 一次（1 分钟，不用重新编译）
- 或者装 **AltStore**（同作者的另一个工具），电脑和手机在同一 WiFi 下每周自动帮你续签

想彻底不过期只有两条路：买 Apple 开发者账号（688 元/年，可上 TestFlight 给人扫码装），
或者买第三方签名（便宜但会掉签）。**先用免费的把功能试明白再说。**

免费账号限制：同时最多 3 个自签 App，同一周最多注册 10 个 App ID。

---

## 工程结构

```
project.yml                  XcodeGen 工程描述（云端用它生成 .xcodeproj）
.github/workflows/build.yml  云端编译脚本
Tidanci/
  App.swift                  入口、首页（台本列表）、台本编辑
  PrompterView.swift         拍摄页：相机预览 + 台本滚动 + 录制
  Align.swift                拼音 + 台本模糊对齐（跟读的核心）
  SpeechFollower.swift       系统离线语音识别封装
  CameraRecorder.swift       相机、录制、音频分流
  WorksView.swift            作品列表、播放、存相册
  Store.swift                台本 / 作品的本地存储
  Theme.swift                配色
tools/make_icon.py           生成 App 图标（纯 Python）
```

## 和安卓版的差异

| | 安卓版 | iOS 版 |
|---|---|---|
| 语音识别 | 内置 sherpa-onnx 离线模型（26MB / 162MB） | 系统 `SFSpeechRecognizer` 离线识别，零体积、更准 |
| 拼音 | 自建 77KB 读音表 | 系统 `CFStringTransform`，不占体积 |
| 美颜 | 自写 OpenGL 着色器 | **暂未做**（下一步） |
| 4K | 有 | 有（机型支持才行，前置一般只有 1080P） |

跟读算法两边是同一套：台本约束 + 拼音容错 + 自由起点编辑距离，所以「读错字也不卡住」这条是共通的。
