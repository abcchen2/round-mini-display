# MotoNav iOS 0.16.2 · Build16

iPhone 配合 1.75 圆屏使用，最低 iOS 15。保留「导航、轨迹、圆屏、我的」四栏目及已有地图、收藏、历史、途经点和语音功能。**iOS 不包含红绿灯读秒。**

## 下载与安装

- [Build16 未签名 IPA](https://github.com/zyn950929/MotoNav/releases/download/motonav-2026.11.01-r2/MotoNav-0.16.2-build16-unsigned.ipa)
- [对应源码 ZIP](https://github.com/zyn950929/MotoNav/releases/download/motonav-2026.11.01-r2/MotoNav-iOS-0.16.2-build16-Source.zip)
- [配套 1.75 固件与一键烧录](../firmware/README.md)

IPA 不能直接点击安装。使用 iLoader、Sideloadly 等工具，以自己的 Apple 账号签名安装；免费签名通常每 7 天需续签。按手机提示信任开发者、开启开发者模式。覆盖更新沿用原签名身份和实际 Bundle ID，保留 Key、配对、设置与记录；分享扩展也需要签名。

## 本版修复

- **息屏底图和楼块**：缓存读取、地图发送不再被截图繁忙或失败退避挡住。前台先准备整条路线道路，再补建筑；锁屏继续读取和发送已准备的数据，回到前台后再补新区域。
- **换图传输**：保留完整建筑包到实际发送时再决策，发送前与发送中的道路带宽预留保持一致，避免传到一半取消重发；减少整包复制和重复计算。
- **偏航重算**：采用定位准确度自适应的偏航确认，至少两帧确认；成功/失败冷却分别为 6/8 秒，12 秒恢复期限。请求和会话隔离，旧结果不会覆盖新导航。
- **圆屏停顿**：配合 `7.12.10-phone.8` 分步收图固件，处理中继续绘图。用户已在同路线息屏回放中确认底图和楼块正常，无肉眼可见卡顿。

锁屏前请等待沿线地图准备完成。**偏航进入未缓存区域仍可能需要前台补图**；后台定位、语音和蓝牙仍受系统权限及调度影响。本轮回放不代表所有路线、弱网或真实道路都已验证。

## 地图、导航和已有功能

保留摩托车网页路线、驾车、自行车规划，备选路线和真实/模拟导航，60/100/120 km/h 模拟速度，最多三个有序途经点、加油站、常用地点与历史。保留四种地图风格、音乐控制、天气、轨迹和本地地图衔接记录。

App 内填写自己的高德 iOS Key，绑定签名后实际 Bundle ID。天气配置按使用者自己的服务填写。源码不含维护者个人 Key、Cookie、签名证书或天气 Host。记录默认关闭，不自动上传。

## 从源码构建

Mac 安装 Xcode 和 CocoaPods 1.16.2，在仓库根目录运行：

```sh
bash build-ios.sh
```

依赖由 `ios/Podfile.lock` 锁定，输出 `output/ios/MotoNav-0.16.2-build16-unsigned.ipa`。也可使用仓库的 [iOS Build and Verify](https://github.com/zyn950929/MotoNav/actions/workflows/release-ios.yml)，产物同样需要自己签名。

## UI 来源与致谢

UI 参考移植并适配自 **[coolcoolmanman（@coolcoolmanman-design）的 MotoNav](https://github.com/coolcoolmanman-design/MotoNav)**，参考版本 0.15.21-tpms，固定提交 [c01d6db1](https://github.com/coolcoolmanman-design/MotoNav/tree/c01d6db1a323e91d0b0210b796d9bb6a0cd7bd0f)。参考范围、适配与许可见 [UI-SOURCE-NOTICE.md](UI-SOURCE-NOTICE.md)，感谢原作者的设计与实现。

自主改动由 AI 辅助开发，沿用仓库[非商业使用条款](../LICENSE.md)，第三方 SDK 与资源遵循各自许可。[本轮更新与验证](../docs/RELEASE-IOS-FIRMWARE-2026-11-01.md)。
