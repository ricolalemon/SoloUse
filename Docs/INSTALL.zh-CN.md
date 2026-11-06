# 从源码安装

[English](INSTALL.md) · [README](../README.zh-CN.md)

这是开发者安装流程，不是一键 IPA 安装器。请使用自己的签名材料；源码不提供已签名应用、证书、设备编号或描述文件。

## 1. 准备 Mac

- 安装完整 Xcode 27 和 iOS 27 SDK，完成首次启动准备；仅安装 Command Line Tools 不够。确认 `xcode-select -p` 指向目标 Xcode，必要时在 Xcode → Settings → Locations 中选择。
- 安装 XcodeGen（`brew install xcodegen`）、[Rust/rustup](https://rustup.rs/)、Python 3 和 Git。
- 执行 `rustup target add aarch64-apple-ios`。
- 用 `xcodebuild -version`、`cargo --version`、`xcodegen --version` 确认命令可用。

## 2. 设置自己的应用标识

在源码根目录执行：

```sh
cp Config.local.xcconfig.example Config.local.xcconfig
```

编辑 `SOLOUSE_BUNDLE_PREFIX`，使用属于自己的反向域名前缀，例如 `dev.yourname.solouse`。主 App 为 `<prefix>.probe`，可选 Lab 为 `<prefix>.lab`，诊断测试组件为 `<prefix>.tree`。填入自己的 `DEVELOPMENT_TEAM`，或在 Xcode 选择团队。

本机配置已被 Git 忽略；项目文件由 XcodeGen 生成，重新生成会覆盖直接在项目中做的部分修改，所以长期签名设置应保存在本机配置中。后台任务标识及诊断组件引用会跟随前缀，不使用作者的团队 ID。

历史真机验证使用付费开发签名。完整流程尚未验证 Personal Team／免费账号，不把“未签名构建成功”当作免费安装保证。描述文件到期后需按自己的签名方式续签。

## 3. 构建

```sh
bash Scripts/build.sh
open SoloUse.xcodeproj
```

脚本会按锁文件编译 iPhone Rust 静态库，复制到被忽略的 `Build/`，生成 Xcode 工程，并完成未签名 Release 构建。输出默认放在被忽略的 `.build/`。可以用 `SOLOUSE_BUILD_DIR`、`SOLOUSE_NATIVE_TARGET_DIR` 指定其他构建目录；设置 `SOLOUSE_CONFIGURATION=Debug` 才会启用开发诊断入口。

遇到 `library not found for -lsolouse_core`，重新执行 `bash Scripts/build-native.sh`；不要把不明来源的静态库复制进源码仓库。

## 4. 准备并安装到 iPhone

1. 用数据线连接 Mac，解锁手机，按提示信任电脑。
2. 在「设置 → 隐私与安全性」开启开发者模式，完成重启和确认。找不到开关时，先让 Xcode 的 Devices and Simulators 识别设备。
3. 等待 Xcode 完成设备准备，这一步提供原型所需的开发者服务／DDI。先解决 SDK 与系统版本不匹配的问题。
4. Xcode 中选择 **SoloUse** scheme、你的手机和开发团队，使用自动签名后运行。若手机要求信任开发者，按「设置 → 通用 → VPN 与设备管理」中的实际提示处理。
5. 在手机上单独安装并连接 [LocalDevVPN](https://apps.apple.com/app/localdevvpn/id6755608044)。普通任务使用它提供的本机开发服务通路，不能用任意远端地址或直连诊断选项替代。

## 5. 配对和登录

1. 打开 SoloUse 的「设备」页，开始本机配对。
2. 按 App 与 iOS 开发者配对界面的提示，选择 SoloUse 主机并输入显示的 PIN。系统文案可能不同；完成前保持 VPN 连接、手机解锁。
3. 运行准备检查，分别确认连接、截图和控制。若系统提示电话／VoIP 冲突，请自行结束通话后再试。
4. 到「账号」页发起登录，在 OpenAI 自己的授权页完成设备码流程后返回。如果账号不允许设备码登录，参考[官方认证说明](https://developers.openai.com/codex/auth)及工作区设置；SoloUse 没有自己的密码表单，也没有 API Key 备用入口。
5. 从账号实际返回的目录选择模型；文档里的历史模型名称不代表当前一定可用。

## 6. 首次任务与恢复

先试：“打开设置，告诉我当前页面，不修改设置。”观察过程。返回 SoloUse 会暂停；点停止可结束任务。使用个人 App 前先阅读[隐私说明](PRIVACY.md)。

首次成功后，在 VPN 与互联网保持可用时拔掉 USB，再重复无副作用任务。这是在验证你的设备运行时是否可脱离电脑，不能仅凭安装成功推断。

进程中断后，重新打开 SoloUse，选择「从恢复点继续」，或在原聊天里追问。继续时需重新观察；已经完成的操作不会撤销，脚本变量和执行位置也不会跨进程保留。手机完整重启是另一种情况，需重新检查 DDI、开发者服务和签名，必要时连接 Xcode。

## 常见问题

| 现象 | 排查方向 |
| --- | --- |
| 装不上或打不开 | 自己的 bundle 前缀、签名团队／描述文件、设备配置、开发者模式与信任状态 |
| VPN 连接但准备检查失败 | DDI、本机配对、锁屏和通话是不同检查项 |
| 屏幕会话被占用 | 关闭其他屏幕共享；只有能用已保存标记确认属于 SoloUse 的残留连接会自动清理，旧版无标记连接不会强制抢占 |
| 登录或模型请求被拒绝 | 账号／工作区权限、设备码功能与实验性接口状态；登录成功不等于所有模型或速度档位都可用 |
| 回到 SoloUse 后暂停 | 这是接管行为；检查画面后主动继续 |
| 粘贴提示或输入不对 | 按实际系统提示授权，并核对输入框与输入法；备份剪贴板可能要求 App 在前台 |
| 后台任务被系统结束 | 从保存的聊天恢复，并先核对回执；不能把结果不确定的操作当作没有执行 |

## 可选开发组件

**SoloUseLab** scheme 用于合成输入测试。**SoloUseTree** 是可选 XCTest 诊断，普通 Agent 不需要安装。`Scripts/prepare_tree_runner.py` 只供开发者处理本机 Xcode 构建产物；不要把复制出的 Apple 框架放进源码发行包。
