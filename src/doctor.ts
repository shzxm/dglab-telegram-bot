import { execFileSync } from "node:child_process";
import { loadConfig } from "./config.js";

function command(name: string, args: string[]): string {
  try { return execFileSync(name, args, { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] }); }
  catch { return ""; }
}

console.log(`Node: ${process.version} (${Number(process.versions.node.split(".")[0]) >= 20 ? "OK" : "需要 Node 20+"})`);
try {
  const env = { ...process.env };
  if (!env.TG_BOT_TOKEN) env.TG_BOT_TOKEN = command("launchctl", ["getenv", "TG_BOT_TOKEN"]).trim();
  if (!env.TG_OWNER_USER_ID) env.TG_OWNER_USER_ID = command("launchctl", ["getenv", "TG_OWNER_USER_ID"]).trim();
  if (!env.TG_ALLOWED_CHAT_ID) env.TG_ALLOWED_CHAT_ID = command("launchctl", ["getenv", "TG_ALLOWED_CHAT_ID"]).trim();
  const config = loadConfig(env);
  console.log(`配置：OK (device mode: ${config.deviceMode})`);
} catch (error) {
  console.log(`配置：${error instanceof Error ? error.message : "无效"}`);
}

if (process.platform === "darwin") {
  const bluetooth = command("system_profiler", ["SPBluetoothDataType"]);
  console.log(`macOS 蓝牙控制器：${/State:\s+On/.test(bluetooth) ? "On" : "未确认"}`);
  const ioreg = command("ioreg", ["-n", "Root", "-d1"]);
  console.log(`macOS 屏幕：${/CGSSessionScreenIsLocked"?\s*=\s*Yes/.test(ioreg) ? "锁定（请解锁后运行 BLE 扫描）" : "未检测到锁定"}`);
} else {
  console.log(`平台：${process.platform}（当前 BLE 适配器检查仅针对 macOS）`);
}
