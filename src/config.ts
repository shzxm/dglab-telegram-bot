import { existsSync, readFileSync } from "node:fs";
import { resolve } from "node:path";

export type DeviceMode = "mock" | "ble";

export interface AppConfig {
  token: string;
  ownerUserId: number;
  allowedChatId: number;
  deviceMode: DeviceMode;
  strengthLimit: number;
  sessionDurationMs: number;
  voteWindowMs: number;
  actionWindowMs: number;
  actionsPerWindow: number;
  obsHost: string;
  obsPort: number;
}

interface FileConfig {
  telegramToken?: string;
  ownerUserId?: number;
  allowedChatId?: number;
  deviceMode?: DeviceMode;
  strengthLimit?: number;
  sessionDurationSeconds?: number;
  voteWindowSeconds?: number;
  actionWindowMs?: number;
  actionsPerWindow?: number;
  obsHost?: string;
  obsPort?: number;
}

export function loadConfig(env: NodeJS.ProcessEnv): AppConfig {
  const file = readFileConfig(env.DGLAB_CONFIG_FILE);
  const token = (env.TG_BOT_TOKEN ?? file.telegramToken ?? "").trim();
  if (!/^\d{6,15}:[A-Za-z0-9_-]{20,}$/.test(token)) throw new Error("TG_BOT_TOKEN is missing or invalid; configure it through Keychain or environment");
  const ownerUserId = parseSafeInteger(env.TG_OWNER_USER_ID ?? value(file.ownerUserId), "TG_OWNER_USER_ID");
  const allowedChatId = parseSafeInteger(env.TG_ALLOWED_CHAT_ID ?? value(file.allowedChatId) ?? String(ownerUserId), "TG_ALLOWED_CHAT_ID");
  const deviceMode = (env.DG_DEVICE_MODE ?? file.deviceMode ?? "mock") as string;
  if (deviceMode !== "mock" && deviceMode !== "ble") throw new Error("DG_DEVICE_MODE must be mock or ble");
  const strengthLimit = parseBoundedInteger(env.DG_STRENGTH_LIMIT ?? value(file.strengthLimit) ?? "133", "DG_STRENGTH_LIMIT", 1, 133);
  const sessionDurationMs = parseBoundedInteger(env.DG_SESSION_DURATION_SECONDS ?? value(file.sessionDurationSeconds) ?? "9999", "DG_SESSION_DURATION_SECONDS", 1, 24 * 60 * 60) * 1000;
  const voteWindowMs = parseBoundedInteger(env.DG_VOTE_WINDOW_SECONDS ?? value(file.voteWindowSeconds) ?? "5", "DG_VOTE_WINDOW_SECONDS", 1, 60) * 1000;
  const actionWindowMs = parseBoundedInteger(env.DG_ACTION_WINDOW_MS ?? value(file.actionWindowMs) ?? "1000", "DG_ACTION_WINDOW_MS", 100, 60_000);
  const actionsPerWindow = parseBoundedInteger(env.DG_ACTIONS_PER_WINDOW ?? value(file.actionsPerWindow) ?? "3", "DG_ACTIONS_PER_WINDOW", 1, 100);
  const obsHost = (env.DG_OBS_HOST ?? file.obsHost ?? "127.0.0.1").trim();
  const obsPort = parseBoundedInteger(env.DG_OBS_PORT ?? value(file.obsPort) ?? "8787", "DG_OBS_PORT", 1, 65535);
  return { token, ownerUserId, allowedChatId, deviceMode, strengthLimit, sessionDurationMs, voteWindowMs, actionWindowMs, actionsPerWindow, obsHost, obsPort };
}

function readFileConfig(path: string | undefined): FileConfig {
  const filePath = resolve(path ?? "config.json");
  if (!existsSync(filePath)) return {};
  try { return JSON.parse(readFileSync(filePath, "utf8")) as FileConfig; }
  catch { throw new Error(`无法读取配置文件：${filePath}`); }
}

function value(value: number | undefined): string | undefined { return value === undefined ? undefined : String(value); }

function parseSafeInteger(value: string | undefined, name: string): number {
  const parsed = Number(value);
  if (!Number.isSafeInteger(parsed)) throw new Error(`${name} must be a safe integer`);
  return parsed;
}

function parseBoundedInteger(value: string, name: string, min: number, max: number): number {
  const parsed = Number(value);
  if (!Number.isInteger(parsed) || parsed < min || parsed > max) throw new Error(`${name} must be an integer from ${min} to ${max}`);
  return parsed;
}
