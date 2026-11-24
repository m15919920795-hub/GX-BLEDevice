# GX-BLEDevice

使用 Objective-C 和 UIKit 的 iPhone 工程，支持 iOS 14 或更新版本，只支持左、右横屏。

## 运行

1. 在 Xcode 打开 `GX-BLEDevice.xcodeproj`，等待软件包解析完成。工程通过 Swift Package Manager 依赖 CocoaAsyncSocket 7.6.5。
2. 在 GX-BLEDevice target 的 Signing & Capabilities 中选择自己的 Apple Developer Team。如有签名冲突，改用该团队下可用的唯一 Bundle Identifier。签名需要包含 Hotspot Configuration 和 Access Wi-Fi Information。
3. 选择 iPhone 真机运行。打开设备电源，点击「搜索并连接」，按 iOS 提示确认加入 Wi-Fi。

## 连接流程

`GXConnectionViewController` 显示连接进度，`GXDeviceConnectionCoordinator` 串联两个步骤：

1. `GXBLEScanner` 扫描约 3 秒，把以 `FPV-Drone-` 开头的完整 BLE 广播 Local Name 作为 SSID。按设备累计有效 RSSI，以中位数最高的设备为目标。蓝牙关闭与 App 无蓝牙权限分别提示。
2. `GXWiFiConnector` 用完整 SSID 申请临时加入开放热点。收到系统回调后，最多等 10 秒让路由更新，再显示当前 Wi-Fi 的 IPv4 网关。连接面向前台使用，锁屏、退出 App 或切换网络时，iOS 可能终止这次临时连接。
3. 点「查看图像」后，先通过 UDP 7080 获取图像 Key，再由 `BKUDPImageManager` 通过 UDP 7070 接收 JPEG。首次进入时按系统提示允许本地网络访问。

## UDP 指令

| 指令 | 用途 | 载荷 |
| --- | --- | --- |
| `00` | 查询画面方向 | `01` |
| `01` | 设置画面翻转 | `00` 或 `01` |
| `02` | 设置 Wi-Fi 名称 | 1 至 32 个 UTF-8 字节 |
| `03` | 设置信道 | 一个字节 |
| `05` | 查询设备信息以计算图像 Key | 请求为 `01`。回复载荷的前 6 字节求和，取低 8 位 |
| `17`、`18` | 设备上报录像、拍照 | 录像 `01` 开始、`02` 结束，拍照 `01` 触发 |

`BKUDPCommandManager` 绑定本地 UDP 7080，并向设备的 UDP 7080 发送初始化包 `00 00`。协议帧检查 `CC 5A` 帧头、长度和异或校验。等待 Key 时，两次查询至少相隔 1 秒，收到有效回复后停止查询。

## UDP 图像

- App 从同一个本地 UDP 端口发送 `20 36` 开流指令并接收图像分包。退出预览或进入后台时发送 `20 37` 停流。
- 每个分包的前 4 字节依次为帧号、结束标志、从 1 开始的包序号和保留位。结束标志为 1 时，连续分包的载荷组成一张 JPEG。
- `startReceivingFromHost:w32Key:` 使用由设备回复计算出的单字节值逐包恢复 JPEG 载荷。一次预览内的图像重试复用已有 Key。返回首页或切到后台会结束预览，下次进入重新获取。

## 真机验收

- 单台设备开机后，加入其热点，确认弹窗中的 IPv4 网关与 iPhone「设置 → Wi-Fi」里该网络的「路由器」地址一致。
- 点击「查看图像」，确认取得 Key 后预览能收到 JPEG。确认同一次预览里重试时复用 Key，切到后台后回到首页，重新进入时先重新获取 Key。
- 两台设备同时开机，把其中一台放在手机附近，检查是否选择 RSSI 更强的一台。
- 在「设置 → 蓝牙」关闭蓝牙后搜索，确认弹出开启提示。开启蓝牙后返回 App 再试。
- 在系统弹窗中拒绝 Wi-Fi 加入，确认 App 显示取消结果，并可重新搜索。
- 在 App 设置中关闭蓝牙权限，确认允许从提示框跳转到 App 设置。
