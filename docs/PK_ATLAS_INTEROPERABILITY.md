# DG-Lab Control × 药时 PK Atlas · 跨应用互动

**相关项目：** [PK Atlas](https://github.com/shzxm/pk-atlas)（药代模型 Web/PWA 与 SwiftUI iOS）

## 当前真实实现：双向手动打开 App

| 操作 | URL | 安全行为 |
| --- | --- | --- |
| DG-Lab → 药时 | pkatlas://open?source=dglab | 只唤起药时；不传递刺激参数 |
| 药时 → DG-Lab | dglabcontrol://open?source=pkatlas | 只唤起 DG-Lab；提示用户另行授权，不连接/启动设备 |

两款 iOS App 在自身 Info.plist 中注册 URL scheme。只有用户点击按钮才会发起跳转。没有自动读取服药记录、上传药物数据或由药代模型触发电刺激。

## 真正的远程控制链路

DG-Lab iOS ↔ MBP Telegram Bot **与药时无关**。iOS 通过独立随机 IOS_BRIDGE_TOKEN 连接受信任局域网内的 WebSocket 服务（或配置带认证的 WSS），Telegram Bot 仍只有一个轮询进程。设备模式：

- mock：纯模拟，不连接实体设备；首次安装/开发推荐。
- ble：MBP 连接真实 DG-Lab 设备，iOS 可作为已授权的远程控制界面。
- ios：iPhone 是经过现场同意的 BLE 主机；Mac Bot 仅桥接会话、投票与命令。

设备不得同时由 iPhone 与 MBP 占用。不要将 ws://:8788、OBS 状态接口或桥接密钥公开到互联网。

## 明确不提供的行为

绝不依据血药浓度、反算剂量、日记内容或者任何药物模型结果，自动修改电刺激强度、频率、波形或状态；这既不是设备安全联锁，也不是生理闭环。软件取值上限（包括 133）不是人体安全阈值。请保持独立、立即可操作的物理停止手段。

## 验证

1. 只用模拟模式测试手动跨应用打开/返回。
2. 确认深度链接没有启动任何设备会话、增加强度或生成刺激命令。
3. 确认药时的记录和同步版本不受 DG-Lab 页面切换影响。
4. 真实设备连接必须在控制程序内由用户单独授权。
