# 1.75 圆屏通用固件 7.12.10-phone.8

适用于 **微雪 ESP32-S3-Touch-AMOLED-1.75**。安卓普通版、安卓读秒版和 iOS 共用；不需要按手机系统分别烧录。公开源码及镜像使用通用 MotoNav / 品牌开机，不包含私人开机资源。

## 下载与烧录

- [Windows 一键烧录 ZIP](https://github.com/zyn950929/MotoNav/releases/download/motonav-2026.11.01-r2/MotoNav-1.75-v7.12.10-phone.8-Universal-Flasher.zip)：完整解压，双击 `一键烧录.bat`。
- [macOS 一键烧录 ZIP](https://github.com/zyn950929/MotoNav/releases/download/motonav-2026.11.01-r2/MotoNav-1.75-v7.12.10-phone.8-macOS-OneClick.zip)：完整解压，双击 `一键烧录.command`，自动选择 Apple 芯片或 Intel 原生工具。
- [固件源码 ZIP](https://github.com/zyn950929/MotoNav/releases/download/motonav-2026.11.01-r2/MotoNav-Firmware-Source-1.75-v7.12.10-phone.8.zip)
- [仅固件镜像 ZIP](https://github.com/zyn950929/MotoNav/releases/download/motonav-2026.11.01-r2/MotoNav-universal-firmware-7.12.10-phone.8.zip)：供已有烧录环境使用。

两个一键包使用完全相同的应用及完整镜像。已有同板型、同分区 MotoNav，选默认“应用升级”，写入 `0x10000`，保留配对和设置。首次安装或救砖才选完整安装，**会清空设置**。

**不能刷到 1.75C、1.85B 或 M5Stack。** 1.85B 目录保持原 7.12.3-185B，本轮没有升级其镜像。

## 本版改动

把地图清空备用缓冲、解码和楼块继承拆成小步，主循环每次目标处理约 16 毫秒；旧图继续显示，新图全部完成后才切换并确认。重复末包只查询确认，不会重启未完成任务。断连、换图、换风格、停止导航或改变楼块开关时取消旧任务。

地图格式、原导航、路线、车道、摄像头、读秒、音乐和天气协议保持兼容。楼块保留仍由 `#BC` 显式开启；未发送该指令的旧安卓客户端保持默认行为。支持新客户端的等待定位及到达停留指令；旧导航指令会退出这些状态。

保留 pages.5 的页面顺序、主页 24 小时时间及日期、旋转记忆、音乐、天气、电池空闲关机和插电保护。没有叠加 Deflate / XOR 实验协议，不需要更新安卓 App。

## 验证范围

生产解码器像素/边界/进度回归和实际接收队列测试覆盖取消、重复包、会话变化及延迟确认；原页面、旋转、电源和媒体测试继续运行。安卓与 iOS 的既有分包格式及确认方式均兼容。

相同处理代码在 1.75 + iPhone Build16 息屏模拟回放中已获用户确认：底图和楼块正常，无肉眼可见卡顿。计时版最长帧由约 339～358 毫秒降至约 123 毫秒；正常固件不带额外计时输出。公开镜像只替换通用开机并重新编译，**没有再刷到用户的私人圆屏**；本轮未做安卓实路复测。桌面计时不能当作圆屏帧率。

Mac 包会在 Apple 芯片和 Intel 的 macOS 环境核对原生工具与模拟写入流程；不会在云端刷真实设备。实际构建与包校验结果见[本轮说明](../docs/RELEASE-IOS-FIRMWARE-2026-11-01.md)。

## 自行编译与打包

安装 Arduino CLI、Espressif ESP32 Arduino Core **3.3.10**；依赖库已放在 `libraries/`。在仓库根目录执行：

```sh
python3 firmware/build.py
```

Windows：`firmware/build.ps1 -Board 175`。输出 `firmware/dist/175/panel0`。

`package_flasher.py` 生成 Windows、Mac 一键包和源码包，运行 `--help` 查看参数。普通用户直接下载完整 ZIP，不需要另装 Arduino、Python 或 Xcode。
