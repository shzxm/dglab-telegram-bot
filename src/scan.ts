import noble, { type Peripheral } from "@stoprocent/noble";
import { COYOTE_V2_NAME } from "./coyote-v2.js";

const timeoutMs = 10_000;
try {
  await noble.waitForPoweredOnAsync(5_000);
} catch (error) {
  console.error("无法初始化 macOS BLE 适配器。请在已登录的 macOS 桌面终端运行，并授予 Terminal/Node 蓝牙权限。", error instanceof Error ? error.message : error);
  process.exitCode = 1;
}
if (process.exitCode) process.exit();
const found = new Map<string, { id: string; name: string; rssi: number }>();
const onDiscover = (peripheral: Peripheral): void => {
  const name = peripheral.advertisement?.localName ?? "";
  if (name === COYOTE_V2_NAME) found.set(peripheral.id, { id: peripheral.id, name, rssi: peripheral.rssi });
};
noble.on("discover", onDiscover);
try {
  await noble.startScanningAsync([], false);
  await new Promise((resolve) => setTimeout(resolve, timeoutMs));
} finally {
  noble.removeListener("discover", onDiscover);
  await noble.stopScanningAsync().catch(() => undefined);
}

if (found.size === 0) {
  console.log(`未发现 ${COYOTE_V2_NAME}。请确认设备已开机、未被手机 App 占用，并允许 macOS 蓝牙权限。`);
} else {
  for (const item of found.values()) console.log(`${item.name}\tid=${item.id}\trssi=${item.rssi}`);
}
