import { Telegraf, Markup } from "telegraf";
import { MockDevice, type Channel } from "./device.js";
import { CoyoteV2Device } from "./coyote-v2.js";
import { ControlSession, type Action, type Mode } from "./control.js";
import { callbackData, parseCallbackData } from "./bot-security.js";
import { loadConfig } from "./config.js";
import { createInviteCode, inviteCodeMatches, normalizeInviteCode } from "./session-access.js";
import { startObsOverlay } from "./obs-overlay.js";
import { AutoRampController } from "./auto-ramp.js";
import { IOSBridgeServer, type IOSBridgeSnapshot } from "./ios-bridge.js";
import { IOSRelayDevice } from "./ios-relay-device.js";
import { LocalControlAPI } from "./local-control-api.js";
import { SystemAudioReactiveController, AUDIO_FREQUENCY_RANGES, type AudioMode, type AudioTarget, type FrequencyRange } from "./audio-reactive.js";

const config = loadConfig(process.env);
const { token, ownerUserId, allowedChatId, strengthLimit, sessionDurationMs, voteWindowMs, actionWindowMs, actionsPerWindow, obsHost, obsPort } = config;
const bot = new Telegraf(token);
const iosToken = (process.env.IOS_BRIDGE_TOKEN ?? "").trim();
let telegramState: "disabled" | "starting" | "online" | "error" = process.env.DG_DESKTOP_OFFLINE === "1" ? "disabled" : "starting";
let telegramError = "";
const iosBridge: IOSBridgeServer | null = iosToken ? new IOSBridgeServer(iosToken, {
  snapshot: iosSnapshot,
  command: iosOwnerCommand,
  hostDisconnected: () => {
    iosRelayDevice?.onHostLost();
    if (session?.snapshot().state === "active") {
      void stopSession().catch((error: unknown) => console.error("iPhone host failure stop:", error));
    }
  },
  botUsername: () => bot.botInfo?.username ?? "",
}) : null;
if (config.deviceMode === "ios" && !iosBridge) throw new Error("DG_DEVICE_MODE=ios requires IOS_BRIDGE_TOKEN");
const iosRelayDevice: IOSRelayDevice | null = config.deviceMode === "ios" && iosBridge ? new IOSRelayDevice(iosBridge) : null;
const device = config.deviceMode === "ble" ? new CoyoteV2Device() : iosRelayDevice ?? new MockDevice();
// No second Telegram poller: native macOS controls reuse the exact same session
// and BLE device. Loopback-only REST is optional and shares the bridge credential.
const localAPI = iosToken ? new LocalControlAPI(iosToken, {
  snapshot: async () => ({
    ...iosSnapshot(),
    sessionState: session?.snapshot().state ?? "none",
    device: await device.getStatus(),
    deviceMode: config.deviceMode,
    telegramState,
    telegramError,
    audioCaptureError: audioReactive.captureError,
    audioVolume: audioReactive.isEnabled("volume"),
    audioBeat: audioReactive.isEnabled("beat"),
    audioTarget, audioMinHz: audioRange.minHz, audioMaxHz: audioRange.maxHz,
    strengthLimit, obsURL: `http://127.0.0.1:${obsPort}/obs`,
  }),
  command: iosOwnerCommand,
}) : null;

let session: ControlSession | null = null;
let inviteCode = "";
let boundGroupId: number | null = null;
const inviteAuthorizedUsers = new Set<number>();
let sharedPanel: { chatId: number; messageId: number } | null = null;
let sharedPanelRefreshTimer: ReturnType<typeof setTimeout> | null = null;
const autoRamp = new AutoRampController();
const autoRampRates: Record<Channel, number> = { A: 3, B: 3 };
const autoRampMaxIncrease: Record<Channel, number> = { A: 10, B: 10 };
const AUTO_RAMP_RATE_OPTIONS = [1, 3, 5, 7, 11, 13, 17] as const;
const audioReactive = new SystemAudioReactiveController(device);
let audioTarget: AudioTarget = "both";
let audioRange: FrequencyRange = AUDIO_FREQUENCY_RANGES[0]!;

type ActionPoolPreset = "all" | "gentle" | "strength" | "waveform";
const ACTION_POOL_ORDER: ActionPoolPreset[] = ["all", "gentle", "strength", "waveform"];
let actionPoolPreset: ActionPoolPreset = "all";

interface OperatorEntry { userId: number; displayName: string }
let temporaryOperator: (OperatorEntry & { expiresAt: number }) | null = null;
const operatorQueue: OperatorEntry[] = [];
let operatorTimer: ReturnType<typeof setTimeout> | null = null;

function errorText(error: unknown): string {
  const message = error instanceof Error ? error.message : "未知错误";
  const translations: Array<[RegExp, string]> = [
    [/not found within 15 seconds/i, "15 秒内没有找到 DG-LAB 设备"],
    [/not connected/i, "设备尚未连接"],
    [/writing is not permitted/i, "设备不允许当前写入操作"],
    [/session is not active/i, "会话尚未启动，请等待管理员授权开始"],
    [/会话尚未启动$/, "会话尚未启动，请等待管理员授权开始"],
    [/user has not joined the session/i, "你还没有加入会话"],
    [/session cannot be armed/i, "会话无法启动"],
    [/invalid session duration/i, "会话时长无效"],
    [/invalid session limits/i, "会话强度上限无效"],
  ];
  return translations.reduce((text, [pattern, replacement]) => text.replace(pattern, replacement), message);
}

function stateText(state: string): string {
  return ({ draft: "草稿", active: "进行中", stopped: "已停止", fault: "故障" } as Record<string, string>)[state] ?? state;
}

function modeText(mode: Mode): string {
  return ({ collaboration: "管理员", voting: "投票", event: "活动/直播" } as Record<Mode, string>)[mode];
}

function waveformName(id: string): string {
  return ({ imported_0: "波浪", imported_1: "持续跳跃", imported_2: "渐强持续", imported_3: "最爱", imported_4: "按揉", imported_5: "跳强" } as Record<string, string>)[id] ?? id;
}

function voteText(vote: { channel: "A" | "B"; action: Action; count: number }): string {
  const action = vote.action.type === "strength_delta"
    ? `${vote.channel} ${vote.action.delta > 0 ? "+" : ""}${vote.action.delta}`
    : vote.action.type === "waveform" ? `${vote.channel} ${waveformName(vote.action.waveformId)}` : "停止";
  return `${action}=${vote.count}票`;
}

function displayName(from: { username?: string; first_name: string }): string {
  return from.username ? `@${from.username}` : from.first_name;
}

function commandArgument(text: string): string { return text.trim().split(/\s+/).slice(1).join(" "); }
function isOwner(userId: number): boolean { return userId === ownerUserId; }
function isGroupType(chatType: string | undefined): boolean { return chatType === "group" || chatType === "supergroup"; }
function inAllowedChat(chatId: number, chatType: string | undefined): boolean {
  return chatType === "private" || chatId === allowedChatId || chatId === boundGroupId;
}

function poolText(): string {
  return ({ all: "全部动作", gentle: "温和动作", strength: "仅强度", waveform: "仅波形" } as Record<ActionPoolPreset, string>)[actionPoolPreset];
}

function isActionAllowed(action: Action): boolean {
  if (action.type === "stop" || actionPoolPreset === "all") return true;
  if (actionPoolPreset === "strength") return action.type === "strength_delta";
  if (actionPoolPreset === "waveform") return action.type === "waveform";
  if (action.type === "strength_delta") return Math.abs(action.delta) <= 3;
  return action.waveformId === "imported_0" || action.waveformId === "imported_4";
}

function clearOperatorState(): void {
  if (operatorTimer) clearTimeout(operatorTimer);
  operatorTimer = null;
  temporaryOperator = null;
  operatorQueue.splice(0);
}

function grantTemporaryOperator(entry: OperatorEntry): void {
  if (operatorTimer) clearTimeout(operatorTimer);
  temporaryOperator = { ...entry, expiresAt: Date.now() + 10_000 };
  operatorTimer = setTimeout(() => {
    temporaryOperator = null;
    operatorTimer = null;
    const next = operatorQueue.shift();
    if (next) grantTemporaryOperator(next);
    scheduleSharedPanelRefresh();
  }, 10_000);
  operatorTimer.unref?.();
  scheduleSharedPanelRefresh();
}

function enqueueTemporaryOperator(entry: OperatorEntry): number {
  if (temporaryOperator?.userId === entry.userId) return 0;
  const existing = operatorQueue.findIndex((candidate) => candidate.userId === entry.userId);
  if (existing >= 0) return existing + 1;
  operatorQueue.push(entry);
  if (!temporaryOperator) {
    const next = operatorQueue.shift();
    if (next) grantTemporaryOperator(next);
    return 0;
  }
  scheduleSharedPanelRefresh();
  return operatorQueue.length;
}

function removeFromOperatorQueue(userId: number): void {
  const index = operatorQueue.findIndex((entry) => entry.userId === userId);
  if (index >= 0) operatorQueue.splice(index, 1);
  scheduleSharedPanelRefresh();
}

function drawRandomOperator(): OperatorEntry {
  if (!session) throw new Error("当前没有会话");
  const candidates = session.participantEntries().filter((entry) => entry.userId !== ownerUserId);
  if (!candidates.length) throw new Error("当前没有可抽取的参与者");
  const selected = candidates[Math.floor(Math.random() * candidates.length)];
  if (!selected) throw new Error("抽取临时操作员失败");
  grantTemporaryOperator(selected);
  return selected;
}

function stopAutoRamp(): void { autoRamp.stop(); }
function stopAudioReactive(): void { audioReactive.stop(); }
function toggleAudioReactive(mode: "volume" | "beat"): void {
  if (!session || session.snapshot().state !== "active") throw new Error("请先手动启动并授权会话");
  audioReactive.toggleMode(session, mode, audioTarget, audioRange, (message) => {
    console.error(`音频采集故障: ${message}`);
    // Loss of audio input is an error, not silence: stop the session and both ramp timers.
    void stopSession().catch((error: unknown) => console.error("声控故障停止失败", error));
  });
}

function startAutoRamp(channel: Channel): void {
  if (!session) throw new Error("请先创建并启动会话");
  if (!session.isParticipant(ownerUserId) && session.snapshot().state === "active") session.addParticipant(ownerUserId, "管理员");
  autoRamp.start(session, channel, autoRampRates[channel], autoRampMaxIncrease[channel]);
}

function resetSessionRuntime(): void {
  inviteCode = createInviteCode();
  boundGroupId = null;
  inviteAuthorizedUsers.clear();
  inviteAuthorizedUsers.add(ownerUserId);
  sharedPanel = null;
  actionPoolPreset = "all";
  stopAutoRamp();
  stopAudioReactive();
  clearOperatorState();
}

function createSession(mode: Mode, chatId: number): ControlSession {
  resetSessionRuntime();
  session = new ControlSession({ id: crypto.randomUUID(), chatId, ownerUserId, mode, limitA: strengthLimit, limitB: strengthLimit, durationMs: sessionDurationMs, startedAt: 0, expiresAt: 0 }, device, strengthLimit, 2, actionWindowMs, voteWindowMs, Date.now, actionsPerWindow);
  return session;
}

// The owner controls when a bound group becomes interactive. Before an
// active session exists, non-owner group traffic is intentionally ignored.
bot.use(async (ctx, next) => {
  if (isGroupType(ctx.chat?.type) && !isOwner(ctx.from?.id ?? 0)
    && (ctx.chat?.id === boundGroupId || boundGroupId === null)
    && session?.snapshot().state !== "active") return;
  await next();
});

async function initializeDefaultLevels(): Promise<void> {
  if (!session) return;
  if (!session.isParticipant(ownerUserId)) session.addParticipant(ownerUserId, "管理员");
  await session.applyOwnerAction({ type: "strength_delta", channel: "A", delta: 1 });
  await session.applyOwnerAction({ type: "strength_delta", channel: "B", delta: 1 });
  await session.applyOwnerAction({ type: "waveform", channel: "A", waveformId: "imported_0", durationMs: 9999 });
  await session.applyOwnerAction({ type: "waveform", channel: "B", waveformId: "imported_0", durationMs: 9999 });
}

function panel(sessionId: string) {
  const cb = (code: string) => callbackData(sessionId, code);
  const rows: Array<Array<ReturnType<typeof Markup.button.callback>>> = [];
  if (actionPoolPreset !== "strength") {
    if (actionPoolPreset === "gentle") rows.push([Markup.button.callback("A波浪", cb("wa0")), Markup.button.callback("A按揉", cb("wa4"))]);
    else {
      rows.push([Markup.button.callback("A波浪", cb("wa0")), Markup.button.callback("A持续跳跃", cb("wa1")), Markup.button.callback("A渐强持续", cb("wa2"))]);
      rows.push([Markup.button.callback("A最爱", cb("wa3")), Markup.button.callback("A按揉", cb("wa4")), Markup.button.callback("A跳强", cb("wa5"))]);
    }
  }
  if (actionPoolPreset !== "waveform") {
    rows.push([Markup.button.callback("A +1", cb("a_p1")), Markup.button.callback("A +3", cb("a_p3")), ...(actionPoolPreset === "gentle" ? [] : [Markup.button.callback("A +5", cb("a_p5"))])]);
    rows.push([Markup.button.callback("A -1", cb("a_m1")), Markup.button.callback("A -3", cb("a_m3")), ...(actionPoolPreset === "gentle" ? [] : [Markup.button.callback("A -5", cb("a_m5"))])]);
  }
  if (actionPoolPreset !== "strength") {
    if (actionPoolPreset === "gentle") rows.push([Markup.button.callback("B波浪", cb("wb0")), Markup.button.callback("B按揉", cb("wb4"))]);
    else {
      rows.push([Markup.button.callback("B波浪", cb("wb0")), Markup.button.callback("B持续跳跃", cb("wb1")), Markup.button.callback("B渐强持续", cb("wb2"))]);
      rows.push([Markup.button.callback("B最爱", cb("wb3")), Markup.button.callback("B按揉", cb("wb4")), Markup.button.callback("B跳强", cb("wb5"))]);
    }
  }
  if (actionPoolPreset !== "waveform") {
    rows.push([Markup.button.callback("B +1", cb("b_p1")), Markup.button.callback("B +3", cb("b_p3")), ...(actionPoolPreset === "gentle" ? [] : [Markup.button.callback("B +5", cb("b_p5"))])]);
    rows.push([Markup.button.callback("B -1", cb("b_m1")), Markup.button.callback("B -3", cb("b_m3")), ...(actionPoolPreset === "gentle" ? [] : [Markup.button.callback("B -5", cb("b_m5"))])]);
  }
  rows.push([Markup.button.callback("加入会话", cb("join")), Markup.button.callback("退出会话", cb("leave"))]);
  if (session?.snapshot().mode === "event") {
    rows.push([Markup.button.callback("加入10秒操作队列", cb("queue_join")), Markup.button.callback("退出队列", cb("queue_leave"))]);
    rows.push([Markup.button.callback("随机抽取操作员（管理员）", cb("operator_draw")), Markup.button.callback(`动作池：${poolText()}`, cb("pool_cycle"))]);
  }
  rows.push([Markup.button.callback("立即停止（管理员）", cb("stop"))]);
  for (const channel of ["A", "B"] as const) {
    const name = channel.toLowerCase();
    rows.push([Markup.button.callback(`${channel}通道自动提升：${autoRamp.isEnabled(channel) ? "已开启" : "未开启"}`, cb(`ramp_${name}_toggle`))]);
    for (let offset = 0; offset < AUTO_RAMP_RATE_OPTIONS.length; offset += 4) {
      rows.push(AUTO_RAMP_RATE_OPTIONS.slice(offset, offset + 4).map((rate) =>
        Markup.button.callback(`${autoRampRates[channel] === rate ? "✓" : ""}${rate}秒`, cb(`ramp_${name}_${rate}`)),
      ));
    }
  }
  rows.push([
    Markup.button.callback(`${audioReactive.isEnabled("volume") ? "✓" : ""}音量响应`, cb("audio_volume")),
    Markup.button.callback(`${audioReactive.isEnabled("beat") ? "✓" : ""}节拍响应`, cb("audio_beat")),
    Markup.button.callback("关闭声控", cb("audio_off")),
  ]);
  rows.push([Markup.button.callback(`声控通道：${audioTarget === "both" ? "A+B" : audioTarget}`, cb("audio_target"))]);
  for (let offset = 0; offset < AUDIO_FREQUENCY_RANGES.length; offset += 4) {
    rows.push(AUDIO_FREQUENCY_RANGES.slice(offset, offset + 4).map((range, index) => {
      const label = range.minHz === range.maxHz ? `固定${range.minHz}Hz` : `${range.minHz}-${range.maxHz}Hz`;
      return Markup.button.callback(`${audioRange.minHz === range.minHz && audioRange.maxHz === range.maxHz ? "✓" : ""}${label}`, cb(`audio_range_${offset + index}`));
    }));
  }
  return Markup.inlineKeyboard(rows);
}

function adminMenu() {
  return Markup.inlineKeyboard([
    [Markup.button.callback("连接设备", "menu_connect"), Markup.button.callback("设备状态", "menu_status")],
    [Markup.button.callback("授权并启动管理员会话", "menu_new_collab"), Markup.button.callback("授权并启动投票会话", "menu_new_vote")],
    [Markup.button.callback("授权并启动活动/直播会话", "menu_new_event")],
    [Markup.button.callback("授权并启动会话", "menu_arm"), Markup.button.callback("撤销并归零", "menu_disarm")],
    [Markup.button.callback("查看多人邀请码", "menu_invite"), Markup.button.callback("断开设备", "menu_disconnect")],
  ]);
}

async function panelText(): Promise<string> {
  const deviceStatus = await device.getStatus();
  if (!session) return "DG-LAB：当前没有会话";
  const status = session.snapshot();
  const remaining = status.expiresAt > 0 ? `${Math.max(0, Math.ceil((status.expiresAt - Date.now()) / 1000))}秒` : "不限";
  const roundRemaining = status.voteRoundEndsAt > 0 ? Math.max(0, Math.ceil((status.voteRoundEndsAt - Date.now()) / 1000)) : 0;
  const operatorRemaining = temporaryOperator ? Math.max(0, Math.ceil((temporaryOperator.expiresAt - Date.now()) / 1000)) : 0;
  return [
    "DG-LAB 控制面板",
    `管理员：${status.state === "active" ? "已授权" : "未授权"}`,
    `设备：${deviceStatus.connected ? "已连接" : "未连接"}`,
    `设备电量：${deviceStatus.battery}%`,
    `状态：${stateText(status.state)}  模式：${modeText(status.mode)}`,
    `A：${status.currentA}/${status.limitA}  B：${status.currentB}/${status.limitB}`,
    `当前波形：A ${status.waveformA} / B ${status.waveformB}`,
    `声控：${audioReactive.mode === "off" ? "关闭" : audioReactive.mode === "both" ? "音量+节拍" : audioReactive.mode === "volume" ? "音量响应（静音慢速）" : "节拍响应"} / 通道 ${audioTarget === "both" ? "A+B" : audioTarget} / ${audioRange.minHz === audioRange.maxHz ? `固定${audioRange.minHz}Hz` : `${audioRange.minHz}-${audioRange.maxHz}Hz`}`,
    ...(status.mode === "collaboration" ? ["管理员模式：操作立即生效"] : [
      `当前票数：${status.voteCounts.length ? status.voteCounts.map(voteText).join("，") : "暂无"}`,
      `本轮剩余：${roundRemaining}秒`,
      "规则：每人每轮可分别投 A/B 强度和 A/B 波形各一次",
    ]),
    ...(status.mode === "event" ? [
      `动作池：${poolText()}`,
      `临时操作员：${temporaryOperator ? `${temporaryOperator.displayName}（剩余${operatorRemaining}秒）` : "无"}`,
      `操作队列：${operatorQueue.length}人`,
    ] : []),
    `操作人数：${status.operators.length}`,
    `操作人员：${status.operators.join("、") || "无"}`,
    `参与者：${status.participants}  剩余：${remaining}`,
    ...(boundGroupId ? [`绑定群聊：${boundGroupId}`] : []),
  ].join("\n");
}

async function inviteText(): Promise<string> {
  const me = bot.botInfo ?? await bot.telegram.getMe();
  return [
    `多人邀请码：${inviteCode}`,
    "该邀请码在当前会话结束前可由多人重复使用。",
    `私聊加入链接：https://t.me/${me.username}?start=${inviteCode}`,
    `群聊绑定：把 Bot 加入群后，由管理员在群内发送 /bindgroup ${inviteCode}`,
  ].join("\n");
}

async function assertBoundGroupMember(userId: number): Promise<void> {
  if (!boundGroupId || userId === ownerUserId) return;
  let member;
  try { member = await bot.telegram.getChatMember(boundGroupId, userId); }
  catch { throw new Error("无法校验群成员身份，请确认 Bot 已加入绑定群并具有管理员权限"); }
  if (member.status === "left" || member.status === "kicked") throw new Error("只有当前绑定群的成员可以参加活动");
}

function canJoinFromContext(userId: number, chatId: number, suppliedCode?: string): boolean {
  return isOwner(userId) || chatId === boundGroupId || inviteAuthorizedUsers.has(userId) || inviteCodeMatches(inviteCode, suppliedCode);
}

async function joinCurrentSession(userId: number, name: string, chatId: number, suppliedCode?: string): Promise<void> {
  if (!session || session.snapshot().state !== "active") throw new Error("会话尚未启动，请等待管理员授权开始");
  if (!canJoinFromContext(userId, chatId, suppliedCode)) throw new Error("邀请码无效，请使用管理员提供的多人邀请码");
  await assertBoundGroupMember(userId);
  inviteAuthorizedUsers.add(userId);
  session.addParticipant(userId, name);
  scheduleSharedPanelRefresh();
}

async function publishGroupPanel(chatId: number): Promise<void> {
  if (!session) throw new Error("当前没有会话");
  const message = await bot.telegram.sendMessage(chatId, await panelText(), panel(session.config.id));
  sharedPanel = { chatId, messageId: message.message_id };
}

function scheduleSharedPanelRefresh(): void {
  if (!sharedPanel || !session || sharedPanelRefreshTimer) return;
  sharedPanelRefreshTimer = setTimeout(() => {
    sharedPanelRefreshTimer = null;
    if (!sharedPanel || !session) return;
    void panelText()
      .then((text) => bot.telegram.editMessageText(sharedPanel!.chatId, sharedPanel!.messageId, undefined, text, panel(session!.config.id)))
      .catch(() => undefined)
      .finally(() => {
        const snapshot = session?.snapshot();
        if ((snapshot?.voteRoundEndsAt ?? 0) > Date.now() || (temporaryOperator?.expiresAt ?? 0) > Date.now()) scheduleSharedPanelRefresh();
      });
  }, 750);
  sharedPanelRefreshTimer.unref?.();
}

async function stopSession(): Promise<void> {
  stopAutoRamp();
  stopAudioReactive();
  try {
    if (session) await session.stop();
    else await device.emergencyStop();
  } finally {
    clearOperatorState();
    scheduleSharedPanelRefresh();
  }
}

/** Reuses existing Telegram ControlSession logic, rather than running another Telegram poller. */
function iosSnapshot(): IOSBridgeSnapshot {
  const state = session?.snapshot();
  return {
    active: state?.state === "active",
    mode: state?.mode ?? "collaboration",
    strengthA: state?.currentA ?? 0, strengthB: state?.currentB ?? 0,
    waveformA: state?.waveformA ?? "波浪", waveformB: state?.waveformB ?? "波浪",
    participants: state?.participants ?? 0, operators: state?.operators ?? [],
    inviteCode, groupId: boundGroupId,
    eventPool: actionPoolPreset,
    expiresAt: state?.expiresAt ?? 0,
    votes: Object.fromEntries((state?.voteCounts ?? []).map(v =>
      [`${v.channel}:${v.action.type === "waveform" ? "waveform" : "strength"}:${JSON.stringify(v.action)}`, v.count])),
    rampA: autoRamp.isEnabled("A"), rampB: autoRamp.isEnabled("B"),
    rampDoneA: autoRamp.completed("A"), rampDoneB: autoRamp.completed("B"),
    rampRateA: autoRampRates.A, rampRateB: autoRampRates.B,
    rampMaxA: autoRampMaxIncrease.A, rampMaxB: autoRampMaxIncrease.B,
  };
}
function relayAction(value: Record<string, unknown>): Action {
  const channel = value.channel;
  if (channel !== "A" && channel !== "B") throw new Error("Invalid channel");
  if (value.type === "strength_delta") {
    const delta = value.delta;
    if (![-5,-3,-1,1,3,5].includes(Number(delta))) throw new Error("Invalid strength delta");
    return { type: "strength_delta", channel, delta: Number(delta) as 1|3|5|-1|-3|-5 };
  }
  if (value.type === "waveform") {
    const waveformId = String(value.waveformId ?? "");
    if (!/^(?:imported_[0-5]|soft|rhythm|rise)$/.test(waveformId)) throw new Error("Unknown waveform");
    return { type: "waveform", channel, waveformId, durationMs: 9999 };
  }
  throw new Error("Unsupported action");
}
async function iosOwnerCommand(name: string, payload: Record<string, unknown>): Promise<Record<string, unknown>> {
  const active = () => {
    if (!session || session.snapshot().state !== "active") throw new Error("No active session");
    return session;
  };
  switch (name) {
  case "status": return iosSnapshot() as unknown as Record<string, unknown>;
  case "device.status": return { ...iosSnapshot(), device: await device.getStatus() };
  case "device.connect": {
    if (session?.snapshot().state === "active") throw new Error("Stop the session before connecting");
    await device.connect();
    await device.emergencyStop();
    return { ...iosSnapshot(), device: await device.getStatus(), message: "Device connected and zeroed" };
  }
  case "session.create": {
    if (session?.snapshot().state === "active") throw new Error("Stop the current session before creating another");
    const mode = payload.mode;
    if (mode !== "collaboration" && mode !== "voting" && mode !== "event") throw new Error("Invalid mode");
    createSession(mode, allowedChatId);
    return { ...iosSnapshot(), message: "Session created; currently not armed" };
  }
  case "session.arm": {
    if (!session || session.snapshot().state !== "draft") throw new Error("Create a draft first");
    await session.arm(); // iPhone host always requires on-device physical approval first.
    await initializeDefaultLevels();
    return { ...iosSnapshot(), message: "Session authorized" };
  }
  case "session.stop": await stopSession(); return { ...iosSnapshot(), message: "Stopped and zeroed" };
  case "session.disconnect": {
    await stopSession();
    await device.disconnect(); session = null; inviteCode = "";
    return { ...iosSnapshot(), device: await device.getStatus(), message: "Stopped, zeroed and disconnected" };
  }
  case "owner.delta": {
    const action = relayAction({ type: "strength_delta", ...payload });
    await active().applyOwnerAction(action);
    return iosSnapshot() as unknown as Record<string, unknown>;
  }
  case "owner.waveform": {
    const action = relayAction({ type: "waveform", ...payload });
    await active().applyOwnerAction(action);
    return iosSnapshot() as unknown as Record<string, unknown>;
  }
  case "ramp.rate": {
    const channel = payload.channel;
    const rate = Number(payload.rateSeconds);
    if (channel !== "A" && channel !== "B") throw new Error("Invalid channel");
    AutoRampController.validateRate(rate);
    autoRampRates[channel] = rate;
    autoRamp.updateRate(channel, rate);
    return { ...iosSnapshot(), message: `${channel} interval: ${rate}s` };
  }
  case "ramp.maxIncrease": {
    const channel = payload.channel;
    const maximum = Number(payload.maxIncrease);
    if (channel !== "A" && channel !== "B") throw new Error("Invalid channel");
    AutoRampController.validateMaximum(maximum);
    autoRampMaxIncrease[channel] = maximum;
    autoRamp.updateMaximum(channel, maximum);
    return { ...iosSnapshot(), message: `${channel} ramp stops after +${maximum}` };
  }
  case "ramp.toggle": {
    const channel = payload.channel;
    if (channel !== "A" && channel !== "B") throw new Error("Invalid channel");
    if (autoRamp.isEnabled(channel)) autoRamp.stop(channel);
    else { active(); startAutoRamp(channel); }
    return { ...iosSnapshot(), message: `${channel} ramp ${autoRamp.isEnabled(channel) ? "ON" : "OFF"}` };
  }
  case "audio.off": stopAudioReactive(); return { ...iosSnapshot(), message: "Audio stopped" };
  case "audio.target": {
    const target = payload.target;
    if (target !== "A" && target !== "B" && target !== "both") throw new Error("Invalid audio target");
    audioTarget = target;
    audioReactive.updateSettings(audioTarget, audioRange);
    return { ...iosSnapshot(), message: `Audio target: ${target}` };
  }
  case "audio.volume": active(); toggleAudioReactive("volume"); return { ...iosSnapshot(), message: "Audio volume toggled" };
  case "audio.beat": active(); toggleAudioReactive("beat"); return { ...iosSnapshot(), message: "Audio beat toggled" };
  case "audio.range": {
    const minHz = Number(payload.minHz), maxHz = Number(payload.maxHz);
    if (!Number.isInteger(minHz) || !Number.isInteger(maxHz) || minHz < 1 || maxHz > 100 || minHz > maxHz) throw new Error("Invalid frequency range");
    audioRange = { minHz, maxHz }; audioReactive.updateSettings(audioTarget, audioRange);
    return { ...iosSnapshot(), message: `Audio frequency ${minHz}-${maxHz}Hz` };
  }
  case "session.invite": return { ...iosSnapshot(), message: await inviteText() };
  case "session.join": {
    const s = active();
    if (!s.isParticipant(ownerUserId)) s.addParticipant(ownerUserId, "iOS 管理员");
    return { ...iosSnapshot(), message: "Joined" };
  }
  case "group.bind": {
    const id = Number(payload.groupId);
    if (!Number.isSafeInteger(id) || id >= 0) throw new Error("Invalid group id");
    boundGroupId = id; active().config.chatId = id;
    await publishGroupPanel(id);
    return { ...iosSnapshot(), message: "Group linked" };
  }
  case "vote.submit": {
    const s = active(); const action = relayAction(payload);
    if (!s.isParticipant(ownerUserId)) s.addParticipant(ownerUserId, "iOS 管理员");
    const result = await s.submit(ownerUserId, action);
    return { ...iosSnapshot(), message: `Votes: ${result.votes}` };
  }
  case "event.queue": {
    if (active().snapshot().mode !== "event") throw new Error("Not in event mode");
    const position = enqueueTemporaryOperator({ userId: ownerUserId, displayName: "iPhone 管理员" });
    return { ...iosSnapshot(), message: `Queue position ${position}` };
  }
  case "event.queue.leave": removeFromOperatorQueue(ownerUserId); return { ...iosSnapshot(), message: "Left queue" };
  case "event.random": {
    if (active().snapshot().mode !== "event") throw new Error("Not in event mode");
    const picked = drawRandomOperator(); return { ...iosSnapshot(), message: `Operator ${picked.displayName}` };
  }
  case "event.pool": {
    const preset = payload.preset;
    if (preset !== "all" && preset !== "gentle" && preset !== "strength" && preset !== "waveform") throw new Error("Invalid pool");
    actionPoolPreset = preset;
    return { ...iosSnapshot(), message: `Action pool ${preset}` };
  }
  default: throw new Error("Unsupported iOS bridge command");
  }
}

const obsServer = startObsOverlay(obsHost, obsPort, () => {
  const status = session?.snapshot();
  return {
    active: status?.state === "active",
    mode: status ? modeText(status.mode) : "无",
    participants: status?.participants ?? 0,
    strengthA: status?.currentA ?? 0,
    strengthB: status?.currentB ?? 0,
    waveformA: status?.waveformA ?? "-",
    waveformB: status?.waveformB ?? "-",
    votes: status?.voteCounts.map(voteText) ?? [],
    roundRemainingSeconds: status?.voteRoundEndsAt ? Math.max(0, Math.ceil((status.voteRoundEndsAt - Date.now()) / 1000)) : 0,
    temporaryOperator: temporaryOperator?.displayName ?? "",
    operatorRemainingSeconds: temporaryOperator ? Math.max(0, Math.ceil((temporaryOperator.expiresAt - Date.now()) / 1000)) : 0,
    queueLength: operatorQueue.length,
  };
});
obsServer.on("error", (error) => console.error("OBS overlay error", error));

bot.start(async (ctx) => {
  if (!inAllowedChat(ctx.chat.id, ctx.chat.type)) return;
  const suppliedCode = normalizeInviteCode(ctx.startPayload || commandArgument(ctx.message.text));
  if (!isOwner(ctx.from.id) && suppliedCode && inviteCodeMatches(inviteCode, suppliedCode)) {
    inviteAuthorizedUsers.add(ctx.from.id);
    if (session?.snapshot().state === "active") await joinCurrentSession(ctx.from.id, displayName(ctx.from), ctx.chat.id, suppliedCode);
  }
  if (!isOwner(ctx.from.id)) {
    if (session?.snapshot().state === "active" && (inviteAuthorizedUsers.has(ctx.from.id) || session.isParticipant(ctx.from.id))) await ctx.reply(await panelText(), panel(session.config.id));
    else if (session?.snapshot().state === "active") await ctx.reply("当前有进行中的会话，请使用管理员提供的多人邀请码加入。");
    else await ctx.reply("当前没有进行中的会话，请等待管理员发起会话。");
    return;
  }
  await ctx.reply(`已识别为管理员。强度上限为 ${strengthLimit}，每次可调整 ±1、±3 或 ±5。`, adminMenu());
});

bot.command("help", async (ctx) => {
  if (!inAllowedChat(ctx.chat.id, ctx.chat.type)) return;
  await ctx.reply([
    "/start 邀请码  打开并加入会话",
    "/join 邀请码   加入当前会话",
    "/panel          打开当前控制面板",
    "/queue          加入10秒临时操作队列",
    "/status         查看设备和会话状态",
    "/bindgroup 邀请码  管理员在群内绑定会话",
    "/invite         管理员查看多人邀请码",
    "/audiofreq 5 20  设置节拍响应频率范围（1–100Hz）",
    "声控需要 macOS 系统音频录制权限；静音低速播放，捕获故障会结束会话。",
    "活动模式每五秒结算 A/B 强度和 A/B 波形四类结果。",
  ].join("\n"), isOwner(ctx.from.id) ? adminMenu() : undefined);
});

bot.command("bindgroup", async (ctx) => {
  if (!isOwner(ctx.from.id)) { await ctx.reply("只有管理员可以绑定群聊。"); return; }
  if (!isGroupType(ctx.chat.type)) { await ctx.reply("请在目标群聊中发送此命令。"); return; }
  if (!session || !inviteCodeMatches(inviteCode, commandArgument(ctx.message.text))) { await ctx.reply("当前没有会话，或邀请码不正确。"); return; }
  boundGroupId = ctx.chat.id;
  session.config.chatId = ctx.chat.id;
  await ctx.reply("群聊已绑定到当前会话。邀请码仍可由多人重复使用。");
  if (session.snapshot().state === "active") await publishGroupPanel(ctx.chat.id);
});

bot.command("invite", async (ctx) => {
  if (!inAllowedChat(ctx.chat.id, ctx.chat.type) || !isOwner(ctx.from.id) || !session) return;
  await ctx.reply(await inviteText());
});

bot.command("connect", async (ctx) => {
  if (!inAllowedChat(ctx.chat.id, ctx.chat.type) || !isOwner(ctx.from.id)) return;
  try { await device.connect(); await device.emergencyStop(); await ctx.reply("设备已连接，A/B 已归零。现在可以创建会话。"); }
  catch (error) { await ctx.reply(`连接失败：${errorText(error)}`); }
});

bot.command("newsession", async (ctx) => {
  if (!inAllowedChat(ctx.chat.id, ctx.chat.type) || !isOwner(ctx.from.id)) return;
  if (session?.snapshot().state === "active") { await ctx.reply("已有进行中的会话，请先 /stop 或 /disarm。"); return; }
  const argument = commandArgument(ctx.message.text).toLowerCase();
  const mode: Mode = argument.includes("event") || argument.includes("活动") ? "event" : argument.includes("voting") || argument.includes("投票") ? "voting" : "collaboration";
  createSession(mode, ctx.chat.id);
  await ctx.reply(`会话已创建（尚未启动），模式：${modeText(mode)}。\n${await inviteText()}\n请点击“授权并启动会话”。`, adminMenu());
});

bot.command("arm", async (ctx) => {
  if (!inAllowedChat(ctx.chat.id, ctx.chat.type) || !isOwner(ctx.from.id) || !session) return;
  if (session.snapshot().state !== "draft") { await ctx.reply("会话已经启动或已结束。", session.snapshot().state === "active" ? panel(session.config.id) : adminMenu()); return; }
  try {
    await session.arm();
    await initializeDefaultLevels();
    await ctx.reply(`${await panelText()}\n\n${await inviteText()}`, panel(session.config.id));
  } catch (error) {
    await ctx.reply(`启动失败：${errorText(error)}\n请确认 DG-LAB 已开机、靠近 Mac 且未被其他 App 占用。`, adminMenu());
  }
});

bot.command("join", async (ctx) => {
  if (!inAllowedChat(ctx.chat.id, ctx.chat.type) || !session) return;
  try {
    if (session.snapshot().mode === "collaboration" && !isOwner(ctx.from.id)) throw new Error("当前是管理员模式，其他成员只能查看");
    await joinCurrentSession(ctx.from.id, displayName(ctx.from), ctx.chat.id, commandArgument(ctx.message.text));
    await ctx.reply(await panelText(), panel(session.config.id));
  } catch (error) { await ctx.reply(errorText(error)); }
});

bot.command("queue", async (ctx) => {
  if (!inAllowedChat(ctx.chat.id, ctx.chat.type) || !session) return;
  try {
    if (session.snapshot().mode !== "event") throw new Error("只有活动/直播模式提供临时操作队列");
    if (!session.isParticipant(ctx.from.id)) throw new Error("请先加入会话");
    await assertBoundGroupMember(ctx.from.id);
    const position = enqueueTemporaryOperator({ userId: ctx.from.id, displayName: displayName(ctx.from) });
    await ctx.reply(position === 0 ? "你已获得10秒临时操作权。" : `已加入操作队列，当前排位：${position}。`);
  } catch (error) { await ctx.reply(errorText(error)); }
});

bot.command("audiofreq", async (ctx) => {
  if (!inAllowedChat(ctx.chat.id, ctx.chat.type) || !isOwner(ctx.from.id)) return;
  const args = commandArgument(ctx.message.text).split(/\s+/).map(Number);
  const [minHz, maxHz] = args;
  if (args.length !== 2 || minHz === undefined || maxHz === undefined ||
      !Number.isInteger(minHz) || !Number.isInteger(maxHz) || minHz < 1 || maxHz > 100 || minHz > maxHz) {
    await ctx.reply("请使用 /audiofreq 最低Hz 最高Hz（整数，1 ≤ 最低 ≤ 最高 ≤ 100；相同则为固定频率）"); return;
  }
  audioRange = { minHz, maxHz };
  audioReactive.updateSettings(audioTarget, audioRange);
  await ctx.reply(`声控波形周期频率已设为 ${minHz === maxHz ? `固定 ${minHz} Hz` : `${minHz}-${maxHz} Hz`}（不改变电流强度）`);
});

bot.command("panel", async (ctx) => {
  if (!inAllowedChat(ctx.chat.id, ctx.chat.type) || !session || session.snapshot().state !== "active") return;
  await ctx.reply(await panelText(), panel(session.config.id));
});

bot.command("stop", async (ctx) => {
  if (!inAllowedChat(ctx.chat.id, ctx.chat.type) || !session || !isOwner(ctx.from.id)) return;
  await stopSession();
  await ctx.reply("已立即停止并归零。");
});

bot.command("disarm", async (ctx) => {
  if (!inAllowedChat(ctx.chat.id, ctx.chat.type) || !isOwner(ctx.from.id) || !session) return;
  await stopSession();
  await ctx.reply("会话已撤销授权并归零。");
});

bot.command("status", async (ctx) => {
  if (!inAllowedChat(ctx.chat.id, ctx.chat.type)) return;
  const deviceStatus = await device.getStatus();
  const status = session?.snapshot();
  await ctx.reply(status
    ? `设备：${deviceStatus.connected ? "已连接" : "未连接"}\n电量：${deviceStatus.battery}%\nA=${deviceStatus.strengthA} B=${deviceStatus.strengthB}\n会话：${stateText(status.state)}，模式：${modeText(status.mode)}，参与者 ${status.participants}`
    : `设备：${deviceStatus.connected ? "已连接" : "未连接"}\n电量：${deviceStatus.battery}%\n当前没有会话`);
});

bot.command("disconnect", async (ctx) => {
  if (!inAllowedChat(ctx.chat.id, ctx.chat.type) || !isOwner(ctx.from.id)) return;
  if (session) await stopSession().catch(() => undefined);
  await device.disconnect();
  session = null;
  inviteCode = "";
  await ctx.reply("设备已停止并断开。");
});

bot.on("callback_query", async (ctx) => {
  if (!("data" in ctx.callbackQuery) || !ctx.chat || !inAllowedChat(ctx.chat.id, ctx.chat.type)) return;
  let answered = false;
  const answer = async (text?: string) => {
    if (answered) return;
    answered = true;
    await ctx.answerCbQuery(text).catch(() => undefined);
  };
  const raw = ctx.callbackQuery.data;
  if (raw.startsWith("menu_")) {
    await answer();
    if (!isOwner(ctx.from.id)) { await ctx.reply("只有管理员可以执行此操作。"); return; }
    try {
      if (raw === "menu_connect") {
        await device.connect(); await device.emergencyStop(); await ctx.reply("设备已连接，A/B 已归零。", adminMenu());
      } else if (raw === "menu_status") {
        await ctx.reply(await panelText(), session?.snapshot().state === "active" ? panel(session.config.id) : adminMenu());
      } else if (raw === "menu_new_collab" || raw === "menu_new_vote" || raw === "menu_new_event") {
        if (session?.snapshot().state === "active") { await ctx.reply("已有进行中的会话，请先撤销。", panel(session.config.id)); return; }
        const mode: Mode = raw === "menu_new_event" ? "event" : raw === "menu_new_vote" ? "voting" : "collaboration";
        createSession(mode, ctx.chat.id);
        await session!.arm();
        await initializeDefaultLevels();
        await ctx.reply(`${await panelText()}\n\n${await inviteText()}`, panel(session!.config.id));
      } else if (raw === "menu_arm") {
        if (!session) { await ctx.reply("请先创建会话。", adminMenu()); return; }
        if (session.snapshot().state !== "draft") { await ctx.reply("会话已经启动或已结束。", session.snapshot().state === "active" ? panel(session.config.id) : adminMenu()); return; }
        await session.arm(); await initializeDefaultLevels(); await ctx.reply(`${await panelText()}\n\n${await inviteText()}`, panel(session.config.id));
      } else if (raw === "menu_invite") {
        if (!session) { await ctx.reply("请先创建会话。", adminMenu()); return; }
        await ctx.reply(await inviteText());
      } else if (raw === "menu_disarm") {
        if (session) await stopSession();
        await ctx.reply("会话已撤销并归零。", adminMenu());
      } else if (raw === "menu_disconnect") {
        if (session) await stopSession().catch(() => undefined);
        await device.disconnect(); session = null; inviteCode = ""; await ctx.reply("设备已停止并断开。", adminMenu());
      }
    } catch (error) { await ctx.reply(`操作失败：${errorText(error)}`, adminMenu()); }
    return;
  }
  if (!session) { await answer("当前没有会话"); return; }
  const code = parseCallbackData(raw, session.config.id);
  if (!code) { await answer("此控制面板已失效"); return; }
  const actions: Record<string, Action> = {
    a_p1: { type: "strength_delta", channel: "A", delta: 1 }, a_p3: { type: "strength_delta", channel: "A", delta: 3 }, a_p5: { type: "strength_delta", channel: "A", delta: 5 },
    a_m1: { type: "strength_delta", channel: "A", delta: -1 }, a_m3: { type: "strength_delta", channel: "A", delta: -3 }, a_m5: { type: "strength_delta", channel: "A", delta: -5 },
    b_p1: { type: "strength_delta", channel: "B", delta: 1 }, b_p3: { type: "strength_delta", channel: "B", delta: 3 }, b_p5: { type: "strength_delta", channel: "B", delta: 5 },
    b_m1: { type: "strength_delta", channel: "B", delta: -1 }, b_m3: { type: "strength_delta", channel: "B", delta: -3 }, b_m5: { type: "strength_delta", channel: "B", delta: -5 },
    wa0: { type: "waveform", channel: "A", waveformId: "imported_0", durationMs: 9999 }, wa1: { type: "waveform", channel: "A", waveformId: "imported_1", durationMs: 9999 }, wa2: { type: "waveform", channel: "A", waveformId: "imported_2", durationMs: 9999 }, wa3: { type: "waveform", channel: "A", waveformId: "imported_3", durationMs: 9999 }, wa4: { type: "waveform", channel: "A", waveformId: "imported_4", durationMs: 9999 }, wa5: { type: "waveform", channel: "A", waveformId: "imported_5", durationMs: 9999 },
    wb0: { type: "waveform", channel: "B", waveformId: "imported_0", durationMs: 9999 }, wb1: { type: "waveform", channel: "B", waveformId: "imported_1", durationMs: 9999 }, wb2: { type: "waveform", channel: "B", waveformId: "imported_2", durationMs: 9999 }, wb3: { type: "waveform", channel: "B", waveformId: "imported_3", durationMs: 9999 }, wb4: { type: "waveform", channel: "B", waveformId: "imported_4", durationMs: 9999 }, wb5: { type: "waveform", channel: "B", waveformId: "imported_5", durationMs: 9999 },
    stop: { type: "stop" },
  };
  try {
    const status = session.snapshot();
    if (status.mode === "collaboration" && !isOwner(ctx.from.id)) throw new Error("当前是管理员模式，只有管理员可以操作");
    if (code === "join") {
      await joinCurrentSession(ctx.from.id, displayName(ctx.from), ctx.chat.id);
      await answer("已加入当前会话");
    } else if (code === "leave") {
      session.removeParticipant(ctx.from.id); removeFromOperatorQueue(ctx.from.id); await answer("已退出当前会话");
    } else if (code === "queue_join") {
      if (status.mode !== "event") throw new Error("当前不是活动模式");
      if (!session.isParticipant(ctx.from.id)) throw new Error("请先加入会话");
      await assertBoundGroupMember(ctx.from.id);
      const position = enqueueTemporaryOperator({ userId: ctx.from.id, displayName: displayName(ctx.from) });
      await answer(position === 0 ? "你已获得10秒临时操作权" : `已加入队列，排位 ${position}`);
    } else if (code === "queue_leave") {
      removeFromOperatorQueue(ctx.from.id); await answer("已退出操作队列");
    } else if (code === "operator_draw") {
      if (!isOwner(ctx.from.id)) throw new Error("只有管理员可以抽取临时操作员");
      const selected = drawRandomOperator(); await answer(`已抽取 ${selected.displayName}`);
    } else if (code === "pool_cycle") {
      if (!isOwner(ctx.from.id)) throw new Error("只有管理员可以设置动作池");
      actionPoolPreset = ACTION_POOL_ORDER[(ACTION_POOL_ORDER.indexOf(actionPoolPreset) + 1) % ACTION_POOL_ORDER.length] ?? "all";
      await answer(`动作池已切换为：${poolText()}`);
    } else if (["audio_volume", "audio_beat", "audio_off", "audio_target"].includes(code) || /^audio_range_[0-7]$/.test(code)) {
      if (!isOwner(ctx.from.id)) throw new Error("只有管理员可以控制系统音频响应");
      if (code === "audio_off") stopAudioReactive();
      else if (code === "audio_volume" || code === "audio_beat") {
        const newMode = code === "audio_volume" ? "volume" : "beat";
        toggleAudioReactive(newMode);
      } else if (code === "audio_target") {
        audioTarget = audioTarget === "both" ? "A" : audioTarget === "A" ? "B" : "both";
        audioReactive.updateSettings(audioTarget, audioRange);
      } else {
        const rangeIndex = Number(code.split("_")[2]);
        audioRange = AUDIO_FREQUENCY_RANGES[rangeIndex] ?? audioRange;
        audioReactive.updateSettings(audioTarget, audioRange);
      }
      await answer(audioReactive.mode === "off" ? "声控已关闭" : `声控：${audioReactive.mode === "both" ? "音量+节拍" : audioReactive.mode === "volume" ? "音量响应" : "节拍响应"}；可与 A/B 自动提升一起使用`);
    } else if (/^ramp_[ab]_(?:toggle|1|3|5|7|11|13|17)$/.test(code)) {
      if (!isOwner(ctx.from.id)) throw new Error("只有管理员可以使用自动提升");
      const channel: Channel = code.startsWith("ramp_a_") ? "A" : "B";
      if (code.endsWith("_toggle")) {
        if (autoRamp.isEnabled(channel)) autoRamp.stop(channel);
        else startAutoRamp(channel);
      } else {
        const rate = Number(code.split("_")[2]);
        if (!AUTO_RAMP_RATE_OPTIONS.some((candidate) => candidate === rate)) throw new Error("提升频率无效");
        autoRampRates[channel] = rate;
        autoRamp.updateRate(channel, rate);
      }
      await answer();
    } else {
      const action = actions[code];
      if (!action) { await answer("未知操作"); return; }
      if (!isActionAllowed(action)) throw new Error(`当前管理员动作池不允许此操作：${poolText()}`);
      if (action.type === "stop") {
        if (!isOwner(ctx.from.id)) throw new Error("只有管理员可以停止会话");
        await stopSession(); await answer("已立即停止并归零");
      } else if (isOwner(ctx.from.id) || (temporaryOperator?.userId === ctx.from.id && temporaryOperator.expiresAt > Date.now())) {
        if (isOwner(ctx.from.id)) await session.applyOwnerAction(action);
        else await session.applyTemporaryOperatorAction(ctx.from.id, action);
        await answer("操作已立即生效");
      } else {
        await assertBoundGroupMember(ctx.from.id);
        const result = await session.submit(ctx.from.id, action);
        await answer(`投票已记录：${result.votes}票，5秒后结算`);
      }
    }
    if (ctx.chat.id === boundGroupId) scheduleSharedPanelRefresh();
    else await ctx.editMessageText(await panelText(), panel(session.config.id)).catch(() => undefined);
    scheduleSharedPanelRefresh();
  } catch (error) { await answer(errorText(error)); }
});

bot.catch((error) => { console.error("Telegram handler error", error); });

if (localAPI) {
  const apiPort = Number(process.env.DG_LOCAL_API_PORT ?? "8789");
  localAPI.listen(apiPort);
}

if (iosBridge) {
  const host = (process.env.IOS_BRIDGE_HOST ?? "127.0.0.1").trim();
  const port = Number(process.env.IOS_BRIDGE_PORT ?? "8788");
  if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error("Invalid iOS bridge port");
  iosBridge.listen(host, port);
}

if (process.env.DG_DESKTOP_OFFLINE !== "1") {
  // The authenticated local API may be up before Telegram's getMe/polling
  // succeeds. Expose this distinction so the GUI does not claim TG is ready.
  const reportPending = setTimeout(() => {
    if (telegramState === "starting") {
      console.warn("Telegram still initializing after 15 seconds; check Bot API connectivity and token");
    }
  }, 15_000);
  reportPending.unref?.();
  bot.launch({ dropPendingUpdates: true }).then(async () => {
  telegramState = "online";
  clearTimeout(reportPending);
  try { await bot.telegram.setMyCommands([
    { command: "start", description: "打开控制面板或使用邀请码加入" },
    { command: "help", description: "查看中文操作说明" },
    { command: "join", description: "使用多人邀请码加入会话" },
    { command: "queue", description: "加入10秒临时操作队列" },
    { command: "status", description: "查看设备和会话状态" },
    { command: "panel", description: "打开当前控制面板" },
    { command: "audiofreq", description: "管理员：设置声控波形频率范围" },
    { command: "bindgroup", description: "管理员：绑定当前群聊" },
    { command: "invite", description: "管理员：查看多人邀请码" },
    { command: "connect", description: "管理员：连接 DG-LAB 设备" },
    { command: "newsession", description: "管理员：创建会话" },
    { command: "arm", description: "管理员：授权并启动会话" },
    { command: "stop", description: "管理员：停止会话" },
    { command: "disarm", description: "管理员：撤销并归零" },
    { command: "disconnect", description: "管理员：停止并断开设备" },
  ]); } catch (error) {
    telegramError = error instanceof Error ? error.message : String(error);
    console.error("Telegram setMyCommands warning:", telegramError);
  }
  console.log(`DG-LAB Telegram bot started in ${config.deviceMode === "ble" ? "BLE" : config.deviceMode === "ios" ? "iOS relay" : "MOCK"} mode`);
  console.log(`OBS overlay: http://${obsHost}:${obsPort}/obs`);
  }).catch((error: unknown) => {
    clearTimeout(reportPending);
    telegramState = "error";
    telegramError = error instanceof Error ? error.message : String(error);
    console.error("Telegram launch error:", telegramError);
  });
} else {
  console.log("DG-LAB desktop local-only mode: Telegram polling disabled");
}

// A GUI crash must not leave an independent embedded engine controlling hardware.
// The process watchdog is silent when no GUI parent is provided (standalone Bot).
if (process.env.DG_DESKTOP_PARENT_PID) {
  const parentPid = Number(process.env.DG_DESKTOP_PARENT_PID);
  if (!Number.isSafeInteger(parentPid) || parentPid < 2) throw new Error("Invalid desktop parent PID");
  setInterval(() => {
    try { process.kill(parentPid, 0); }
    catch { void shutdown("SIGTERM"); }
  }, 1200).unref();
}

let shutdownStarted = false;
async function shutdown(signal: "SIGINT" | "SIGTERM"): Promise<void> {
  if (shutdownStarted) return;
  shutdownStarted = true;
  stopAudioReactive();
  stopAutoRamp();
  let firstError: unknown;
  try { await stopSession(); } catch (error) { firstError = error; }
  try { await device.disconnect(); } catch (error) { firstError ??= error; }
  if (firstError) {
    console.error("Safe shutdown blocked: unable to confirm hardware stop", firstError);
    // Do not report success while real hardware status is uncertain.
    process.exitCode = 1;
    shutdownStarted = false;
    return;
  }
  clearOperatorState();
  obsServer.close();
  iosBridge?.close();
  localAPI?.close();
  if (process.env.DG_DESKTOP_OFFLINE !== "1") {
    try { bot.stop(signal); } catch (error) { console.error("Telegram shutdown warning", error); }
  }
  // This process is an owned app helper. Once all output has been stopped and
  // device disconnect confirmed, exit explicitly rather than keeping polling
  // / WebSocket / BLE library event-loop handles indefinitely alive.
  process.exit(0);
}

process.on("SIGINT", () => { void shutdown("SIGINT"); });
process.on("SIGTERM", () => { void shutdown("SIGTERM"); });
