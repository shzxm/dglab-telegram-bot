import { CoyoteV2Device } from "./coyote-v2.js";
import noble from "@stoprocent/noble";

const device = new CoyoteV2Device();
try {
  await device.connect();
  console.log("连接成功：", await device.getStatus());
  if (process.env.BLE_LOW_TEST === "1") {
    await device.setStrength("A", 1);
    console.log("低级别测试已设置 A=1：", await device.getStatus());
    await device.playWaveform("A", "soft", 500);
    await device.emergencyStop();
    console.log("低级别波形结束并归零：", await device.getStatus());
  }
  await device.emergencyStop();
  console.log("已执行安全归零：", await device.getStatus());
} finally {
  await device.disconnect().catch((error: unknown) => console.error("断开时出错：", error));
  noble.stop();
}
