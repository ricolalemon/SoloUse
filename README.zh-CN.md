# SoloUse

**在 iPhone 上运行 Agent 循环，并操作这台 iPhone 的实验性应用。**

[English](README.md) · [安装说明](Docs/INSTALL.zh-CN.md) · [架构](Docs/ARCHITECTURE.md) · [已知限制](Docs/LIMITATIONS.md)

输入任务后，远程模型选择通用工具，iPhone 执行操作并返回截图与回执。SoloUse 在手机上提供截图控制、QuickJS 脚本、聊天历史和中断恢复。**执行循环在手机上，模型推理仍在远程；任务内容和截图会发送给模型服务。**

**状态：Developer Preview，开源开发预览版 0.21.2。** 最近一次真机验证使用原型版 0.21.1、iPhone 17 Pro Max / iOS 27.0.1。这不是 App Store 发行版，也不宣称首个、最快或已经适合所有日常任务。

## 已有能力

- 截图、查找与打开 App、点击、手势、按键输入和 Unicode 粘贴处理。
- 手机内的 QuickJS 短脚本与计算；不提供 Node.js、Shell 或任意文件／网络访问。
- 流式回复、工具进度、暂停／接管、通知回复和历史聊天。
- 截图按内容去重归档；活跃输入有图像窗口，并可自动整理上下文。
- 工具调用前后保存恢复点；重启后等待用户继续，不自动重放结果不确定的调用或排队脚本。
- 中英双语界面及 Markdown 回答。

默认 Agent 使用截图；XCTest 控件树组件只用于可选开发诊断。Lab 是合成测试 App，两者均不是普通任务的必装组件。

## 需要什么

| 项目 | 当前要求 |
| --- | --- |
| 手机 | iOS 27 真机，开启开发者模式；目前按竖屏操作 |
| 首次开发环境 | Mac、完整 Xcode 27 / iOS 27 SDK、Rust/rustup、XcodeGen、Python 3 |
| 签名 | 自己的开发团队、bundle ID 和设备配置 |
| 手机连接 | LocalDevVPN 已连接，开发者服务／DDI 已准备 |
| 模型 | 网络，以及当前实验性 ChatGPT/Codex 订阅通路接受的账号 |

订阅通路参考了公开 Codex 源码，**不属于受支持的公共 API 集成，也不是 OpenAI 认可的客户端**。代码许可不等于服务访问授权；当前没有 API Key 备用通路，账号和接口可用性可能变化。详见[限制说明](Docs/LIMITATIONS.md)。

## 构建与首次尝试

克隆源码并准备构建：

```sh
git clone https://github.com/ricolalemon/SoloUse.git
cd SoloUse
cp Config.local.xcconfig.example Config.local.xcconfig
# 编辑不会进入 Git 的本机配置：填写唯一前缀和自己的签名团队。
rustup target add aarch64-apple-ios
bash Scripts/build.sh
open SoloUse.xcodeproj
```

在 Xcode 选择 **SoloUse** scheme 和已连接、解锁的 iPhone，配置自己的团队并运行。脚本先生成未签名 Release 构建，不安装应用，也不包含开发者的签名材料。[完整安装与排障步骤](Docs/INSTALL.zh-CN.md)。

完成设备准备后，连接 LocalDevVPN，在「设备」页配对，在「账号」页登录。检查准备状态，再试一个无副作用任务，例如：**“打开设置，告诉我现在是什么页面，不修改任何设置。”** 首次运行请观察过程；返回 SoloUse 会暂停，点停止可结束任务。

文档中的首次安装流程需要 Mac。以前的拔线测试验证过运行时不依赖电脑，但手机完整重启后完全免电脑恢复尚未验证。

## 实测与边界

已经做过真实进程强杀后的续接测试；被打断的脚本不会自动重放。每日挑战测试触发过自动上下文整理，并保存了完整的新记录，**但游戏最终失败**，不能作为通关演示。证据范围见[验证说明](Docs/VALIDATION.md)。

通话冲突、系统后台回收、竖屏限制和服务端账号可用性仍会影响任务。截图已存档不等于模型始终记得其中的信息；输入回执成功也不等于业务操作成功。详见[已知限制](Docs/LIMITATIONS.md)。

## 隐私

登录凭据保存在 iOS Keychain；配对记录、聊天、历史图片和诊断都属于敏感本机数据。模型会收到截图和适用的历史上下文。即使日志已脱敏，诊断图片仍可能含有其他 App 的个人内容。请阅读[数据处理说明](Docs/PRIVACY.md)。

候选源码不包含历史真机截图、原始执行日志、配对记录、账号绑定、签名配置或 Apple 框架二进制。

## 开发与许可

```sh
bash Scripts/test.sh
python3 Scripts/check-release.py
python3 Scripts/package-source.py --output /tmp/SoloUse-source.zip
```

离线测试不需要模型账号，也不会操作手机；首次构建可能需要下载锁定的依赖。参见 [CONTRIBUTING.md](CONTRIBUTING.md)、[SECURITY.md](SECURITY.md) 和 [CHANGELOG.md](CHANGELOG.md)。

自有代码采用 **MIT**，明确标记的 Apache-2.0 改编文件及第三方代码保留各自许可。完整说明见 [LICENSE](LICENSE)、[NOTICE](NOTICE)、[第三方声明](THIRD_PARTY_NOTICES.md) 和 [Rust 依赖清单](Licenses/CARGO_DEPENDENCIES.md)。

SoloUse 与 Apple、OpenAI 无隶属或背书关系。LocalDevVPN 是单独安装的外部应用，未捆绑在源码中。
