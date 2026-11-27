# iOS UI 来源与适配说明

MotoNav iOS 0.16.0 的本轮界面参考移植并适配自 **[coolcoolmanman（GitHub：@coolcoolmanman-design）](https://github.com/coolcoolmanman-design)** 维护的 **[MotoNav](https://github.com/coolcoolmanman-design/MotoNav)**。

- 参考版本：**0.15.21-tpms**。
- 固定参考提交：[c01d6db1a323e91d0b0210b796d9bb6a0cd7bd0f](https://github.com/coolcoolmanman-design/MotoNav/tree/c01d6db1a323e91d0b0210b796d9bb6a0cd7bd0f)。
- 原项目条款：[参考提交中的 LICENSE.md](https://github.com/coolcoolmanman-design/MotoNav/blob/c01d6db1a323e91d0b0210b796d9bb6a0cd7bd0f/LICENSE.md)。

感谢原作者提供的界面设计与实现。四栏目结构、语义配色、玻璃导航栏、设备卡、圆屏连接动画和轨迹页面布局是本轮 UI 的主要参考范围。

适配在本项目 iOS 0.16.0 功能基础上进行，保留本项目的选路、蓝牙、天气、轨迹和媒体处理；移除参考界面的日常调试信息入口，并为旧系统保留系统材质回退。胎压、音乐封面及参考分支其他固件协议扩展不在本次移植范围。Build12 App 图标来自本项目维护者提供的图片。

本项目继续保留 AI 辅助开发说明和[非商业使用条款](../LICENSE.md)。第三方代码、资源、商标及服务保留各自来源和适用条款；免费分发修改版本时应继续保留本来源说明，并标注修改内容。


## 1.75C 适配补充

Build 22 的封面编码及对应回归测试改编自 [Charlie-healer/ESP32S3 fe5241e](https://github.com/Charlie-healer/ESP32S3/tree/fe5241efd5fc0bf0b2e03ac3f4bb2dd99fbcddb6)；沿用[原项目非商业使用条款](https://github.com/Charlie-healer/ESP32S3/blob/fe5241efd5fc0bf0b2e03ac3f4bb2dd99fbcddb6/LICENSE.md)。本分支增加了输入校验、按设备启用、仅 Apple iTunes 查询、限时及导航优先的发送机制。详见 [1.75C 适配与验收](175C-COMPAT.md)。


Build 23 的 LyTPMS 广播格式参考 [coolcoolmanman-design/MotoNav 的 TpmsManager.swift](https://github.com/coolcoolmanman-design/MotoNav/blob/a4ea8a0533ebdd6aba6b954bc5087845e35a00e2/ios/MotoNav/TpmsManager.swift)；保留该项目的[非商业使用条款](https://github.com/coolcoolmanman-design/MotoNav/blob/a4ea8a0533ebdd6aba6b954bc5087845e35a00e2/LICENSE.md)。本分支重新实现显式轮位绑定、过期处理及 Charlie-healer 1.75C 的竖线分隔数据格式。
