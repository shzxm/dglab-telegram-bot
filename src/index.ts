import { Telegraf, Markup } from "telegraf";
import { MockDevice } from "./device.js";
import { CoyoteV2Device } from "./coyote-v2.js";
import { ControlSession, type Action, type Mode } from "./control.js";
import { callbackData, parseCallbackData } from "./bot-security.js";
import { loadConfig } from "./config.js";

const config = loadConfig(process.env);
const { token, ownerUserId, allowedChatId, strengthLimit, sessionDurationMs, voteWindowMs, actionWindowMs, actionsPerWindow } = config;

const bot = new Telegraf(token);
const device = config.deviceMode === "ble" ? new CoyoteV2Device() : new MockDevice();
let session: ControlSession | null = null;
let autoRampTimer: ReturnType<typeof setInterval> | null = null;
let autoRampStopTimer: ReturnType<typeof setTimeout> | null = null;
let autoRampRateSeconds = 3;

function errorText(error: unknown): string {
  const message = error instanceof Error ? error.message : "未知错误";
  const translations: Array<[RegExp, string]> = [
    [/not found within 15 seconds/i, "15 秒内没有找到 DG-LAB 设备"],
    [/not connected/i, "设备尚未连接"],
    [/writing is not permitted/i, "设备不允许当前写入操作"],
    [/session is not active/i, "会话尚未启动，请等待管理员授权开始"],
    [/会话尚未启动$/, "会话尚未启动，请等待管理员授权开始"],
    [/user has not joined the session/i, "你还没有加入会话"],
    [/user action is rate limited/i, "操作太频繁，每位用户每秒最多操作 3 次，请稍后再试"],
    [/session cannot be armed/i, "会话无法启动"],
    [/invalid session duration/i, "会话时长无效"],
    [/invalid session limits/i, "会话强度上限无效"],
  ];
  return translations.reduce((text, [pattern, replacement]) => text.replace(pattern, replacement), message);
}

function stateText(state: string): string {
  return ({ draft: "草稿", active: "进行中", stopped: "已停止", fault: "故障" } as Record<string, string>)[state] ?? state;
}

function voteText(vote: { channel: "A" | "B"; action: Action; count: number }): string {
  const action = vote.action.type === "strength_delta"
    ? `${vote.channel} ${vote.action.delta > 0 ? "+" : ""}${vote.action.delta}`
    : vote.action.type === "waveform" ? `${vote.channel} ${vote.action.waveformId}` : "停止";
  return `${action}=${vote.count}票`;
}

function stopAutoRamp(): void {
  if (autoRampTimer) clearInterval(autoRampTimer);
  if (autoRampStopTimer) clearTimeout(autoRampStopTimer);
  autoRampTimer = null;
  autoRampStopTimer = null;
}

function startAutoRamp(): void {
  if (!session) throw new Error("请先创建并启动会话");
  stopAutoRamp();
  if (!session.isParticipant(ownerUserId)) session.addParticipant(ownerUserId, "管理员");
  autoRampTimer = setInterval(() => {
    if (!session || session.snapshot().state !== "active") { stopAutoRamp(); return; }
    void session.applyOwnerAction({ type: "strength_delta", channel: "A", delta: 1 })
      .then(() => session?.applyOwnerAction({ type: "strength_delta", channel: "B", delta: 1 }))
      .catch(() => stopAutoRamp());
  }, autoRampRateSeconds * 1000);
  autoRampStopTimer = setTimeout(stopAutoRamp, 30_000);
}

async function initializeDefaultLevels(): Promise<void> {
  if (session && !session.isParticipant(ownerUserId)) session.addParticipant(ownerUserId, "管理员");
  await device.setStrength("A", 1);
  await device.setStrength("B", 1);
}

function inAllowedChat(chatId: number): boolean { return chatId === allowedChatId; }
function isOwner(userId: number): boolean { return userId === ownerUserId; }
function panel(sessionId: string) {
  const cb = (code: string) => callbackData(sessionId, code);
  return Markup.inlineKeyboard([
    [Markup.button.callback("A波浪", cb("wa0")), Markup.button.callback("A持续跳跃", cb("wa1")), Markup.button.callback("A渐强持续", cb("wa2"))],
    [Markup.button.callback("A最爱", cb("wa3")), Markup.button.callback("A按揉", cb("wa4")), Markup.button.callback("A跳强", cb("wa5"))],
    [Markup.button.callback("A +1", cb("a_p1")), Markup.button.callback("A +3", cb("a_p3")), Markup.button.callback("A +5", cb("a_p5"))],
    [Markup.button.callback("A -1", cb("a_m1")), Markup.button.callback("A -3", cb("a_m3")), Markup.button.callback("A -5", cb("a_m5"))],
    [Markup.button.callback("B波浪", cb("wb0")), Markup.button.callback("B持续跳跃", cb("wb1")), Markup.button.callback("B渐强持续", cb("wb2"))],
    [Markup.button.callback("B最爱", cb("wb3")), Markup.button.callback("B按揉", cb("wb4")), Markup.button.callback("B跳强", cb("wb5"))],
    [Markup.button.callback("B +1", cb("b_p1")), Markup.button.callback("B +3", cb("b_p3")), Markup.button.callback("B +5", cb("b_p5"))],
    [Markup.button.callback("B -1", cb("b_m1")), Markup.button.callback("B -3", cb("b_m3")), Markup.button.callback("B -5", cb("b_m5"))],
    [Markup.button.callback("加入会话", cb("join")), Markup.button.callback("退出会话", cb("leave"))],
    [Markup.button.callback("立即停止（管理员）", cb("stop"))],
    [Markup.button.callback(`自动提升30秒：${autoRampTimer ? "已开启" : "未开启"}`, cb("auto_ramp_toggle"))],
    [Markup.button.callback(`提升速率：每${autoRampRateSeconds}秒`, cb("auto_ramp_rate"))],
  ]);
}

function adminMenu() {
  return Markup.inlineKeyboard([
    [Markup.button.callback("连接设备", "menu_connect"), Markup.button.callback("设备状态", "menu_status")],
    [Markup.button.callback("授权并启动管理员会话", "menu_new_collab"), Markup.button.callback("授权并启动投票会话", "menu_new_vote")],
    [Markup.button.callback("授权并启动会话", "menu_arm"), Markup.button.callback("撤销并归零", "menu_disarm")],
    [Markup.button.callback("断开设备", "menu_disconnect")],
  ]);
}

bot.start(async (ctx) => {
  if (!inAllowedChat(ctx.chat.id)) return;
  if (!isOwner(ctx.from.id)) {
    if (session && session.snapshot().state === "active") {
      await ctx.reply(await panelText(), panel(session.config.id));
    } else {
      await ctx.reply("当前没有进行中的会话，请等待管理员发起会话。");
    }
    return;
  }
  await ctx.reply(`已识别为管理员，请使用下方按钮操作。\n强度上限为 ${strengthLimit}，每次可调整 ±1、±3 或 ±5。`, adminMenu());
});

bot.command("help", async (ctx) => {
  if (!inAllowedChat(ctx.chat.id)) return;
  await ctx.reply(`请使用按钮操作。强度上限为 ${strengthLimit}，每次只能调整 ±1、±3 或 ±5。私信模式下不接受其他聊天的操作。`, adminMenu());
});

async function panelText(): Promise<string> {
  const deviceStatus = await device.getStatus();
  if (!session) return "DG-LAB：当前没有会话";
  const status = session.snapshot();
  const remaining = status.expiresAt > 0 ? `${Math.max(0, Math.ceil((status.expiresAt - Date.now()) / 1000))}秒` : "不限";
  return [
    "DG-LAB 控制面板",
    `管理员：${status.state === "active" ? "已授权" : "未授权"}`,
    `设备：${deviceStatus.connected ? "已连接" : "未连接"}`,
    `设备电量：${deviceStatus.battery}%`,
    `状态：${stateText(status.state)}  模式：${status.mode === "voting" ? "投票" : "管理员"}`,
    `A：${status.currentA}/${status.limitA}  B：${status.currentB}/${status.limitB}`,
    `当前波形：A ${status.waveformA} / B ${status.waveformB}`,
    ...(status.mode === "voting" ? [] : ["管理员模式：操作立即生效"]),
    `操作人数：${status.operators.length}`,
    `操作人员：${status.operators.join("、") || "无"}`,
    ...(status.mode === "voting" ? [`当前票数：${status.voteCounts.length ? status.voteCounts.map(voteText).join("，") : "暂无"}`, "规则：每人每轮可分别投 A/B 强度和 A/B 波形各一次"] : []),
    `参与者：${status.participants}  剩余：${remaining}`,
  ].join("\n");
}

bot.command("connect", async (ctx) => {
  if (!inAllowedChat(ctx.chat.id) || !isOwner(ctx.from.id)) return;
  try {
    await device.connect();
    await device.emergencyStop();
    await ctx.reply("设备已连接，A/B 已归零。现在可以 /newsession。");
  } catch (error) {
    await ctx.reply(`连接失败：${errorText(error)}`);
  }
});

bot.command("newsession", async (ctx) => {
  if (!inAllowedChat(ctx.chat.id) || !isOwner(ctx.from.id)) return;
  if (session && session.snapshot().state === "active") {
    await ctx.reply("已有进行中的会话，请先 /stop 或 /disarm。");
    return;
  }
  const mode: Mode = ctx.message.text.includes("voting") ? "voting" : "collaboration";
  session = new ControlSession({ id: crypto.randomUUID(), chatId: ctx.chat.id, ownerUserId, mode, limitA: strengthLimit, limitB: strengthLimit, durationMs: sessionDurationMs, startedAt: 0, expiresAt: 0 }, device, strengthLimit, 2, actionWindowMs, voteWindowMs, Date.now, actionsPerWindow);
  await ctx.reply(`会话已创建（尚未启动），模式：${mode === "voting" ? "投票" : "管理员"}。请点击“授权并启动会话”。`, adminMenu());
});

bot.command("arm", async (ctx) => {
  if (!inAllowedChat(ctx.chat.id) || !isOwner(ctx.from.id) || !session) return;
  if (session.snapshot().state !== "draft") {
    await ctx.reply("会话已经启动或已结束，请使用当前面板操作。", session.snapshot().state === "active" ? panel(session.config.id) : adminMenu());
    return;
  }
  try {
    await session.arm();
    await ctx.reply(await panelText(), panel(session.config.id));
  } catch (error) {
    await ctx.reply(`启动失败：${errorText(error)}\n请确认 DG-LAB 已开机、靠近 Mac 且未被其他 App 占用。`, adminMenu());
  }
});

bot.command("join", async (ctx) => {
  if (!inAllowedChat(ctx.chat.id) || !session) return;
  if (session.snapshot().mode === "collaboration" && !isOwner(ctx.from.id)) {
    const message = await ctx.reply("当前是管理员模式，只有管理员可以操作。");
    setTimeout(() => { void ctx.telegram.deleteMessage(ctx.chat.id, message.message_id).catch(() => undefined); }, 5000).unref?.();
    return;
  }
  session.addParticipant(ctx.from.id, ctx.from.username ? `@${ctx.from.username}` : ctx.from.first_name);
  await ctx.reply(await panelText(), panel(session.config.id));
});

bot.command("panel", async (ctx) => {
  if (!inAllowedChat(ctx.chat.id) || !session || session.snapshot().state !== "active") return;
  await ctx.reply(await panelText(), panel(session.config.id));
});

bot.command("stop", async (ctx) => {
  if (!inAllowedChat(ctx.chat.id) || !session || !isOwner(ctx.from.id)) return;
  await session.stop();
  stopAutoRamp();
  await ctx.reply("已立即停止并归零。");
});

bot.command("disarm", async (ctx) => {
  if (!inAllowedChat(ctx.chat.id) || !isOwner(ctx.from.id) || !session) return;
  await session.stop();
  stopAutoRamp();
  await ctx.reply("会话已撤销授权并归零。");
});

bot.command("status", async (ctx) => {
  if (!inAllowedChat(ctx.chat.id)) return;
  const deviceStatus = await device.getStatus();
  const sessionStatus = session?.snapshot();
  await ctx.reply(sessionStatus
    ? `设备：${deviceStatus.connected ? "已连接" : "未连接"}\n电量：${deviceStatus.battery}%\nA=${deviceStatus.strengthA} B=${deviceStatus.strengthB}\n会话：${stateText(sessionStatus.state)}，参与者 ${sessionStatus.participants}`
    : `设备：${deviceStatus.connected ? "已连接" : "未连接"}\n电量：${deviceStatus.battery}%\nA=${deviceStatus.strengthA} B=${deviceStatus.strengthB}\n当前没有会话`);
});

bot.command("disconnect", async (ctx) => {
  if (!inAllowedChat(ctx.chat.id) || !isOwner(ctx.from.id)) return;
  if (session) await session.stop().catch(() => undefined);
  stopAutoRamp();
  await device.disconnect();
  session = null;
  await ctx.reply("设备已停止并断开。");
});

bot.on("callback_query", async (ctx) => {
  if (!("data" in ctx.callbackQuery) || !ctx.chat || !inAllowedChat(ctx.chat.id)) return;
  await ctx.answerCbQuery();
  const raw = ctx.callbackQuery.data;
  if (raw.startsWith("menu_")) {
    if (!isOwner(ctx.from.id)) {
      await ctx.reply("只有管理员可以执行此操作。");
      return;
    }
    try {
      if (raw === "menu_connect") {
        await device.connect();
        await device.emergencyStop();
        await ctx.reply("设备已连接，A/B 已归零。", adminMenu());
      } else if (raw === "menu_status") {
        await ctx.reply(await panelText(), session?.snapshot().state === "active" ? panel(session.config.id) : adminMenu());
      } else if (raw === "menu_new_collab" || raw === "menu_new_vote") {
        if (session && session.snapshot().state === "active") {
          await ctx.reply("已有进行中的会话，请先撤销。", panel(session.config.id));
          return;
        }
        const mode: Mode = raw === "menu_new_vote" ? "voting" : "collaboration";
        session = new ControlSession({ id: crypto.randomUUID(), chatId: ctx.chat.id, ownerUserId, mode, limitA: strengthLimit, limitB: strengthLimit, durationMs: sessionDurationMs, startedAt: 0, expiresAt: 0 }, device, strengthLimit, 2, actionWindowMs, voteWindowMs, Date.now, actionsPerWindow);
        await session.arm();
        await initializeDefaultLevels();
        await ctx.reply(await panelText(), panel(session.config.id));
      } else if (raw === "menu_arm") {
        if (!session) { await ctx.reply("请先创建会话。", adminMenu()); return; }
        if (session.snapshot().state !== "draft") {
          await ctx.reply("会话已经启动或已结束，请使用当前面板操作。", session.snapshot().state === "active" ? panel(session.config.id) : adminMenu());
          return;
        }
        await session.arm();
        await initializeDefaultLevels();
        await ctx.reply(await panelText(), panel(session.config.id));
      } else if (raw === "menu_disarm") {
        if (session) await session.stop();
        await ctx.reply("会话已撤销并归零。", adminMenu());
      } else if (raw === "menu_disconnect") {
        if (session) await session.stop().catch(() => undefined);
        await device.disconnect();
        session = null;
        await ctx.reply("设备已停止并断开。", adminMenu());
      }
    } catch (error) {
      await ctx.reply(`操作失败：${errorText(error)}`, adminMenu());
    }
    return;
  }
  if (!session) return;
  const code = parseCallbackData(raw, session.config.id);
  if (!code) {
    await ctx.reply("此控制面板已失效，请使用 /panel 获取当前面板。");
    return;
  }
  const actions: Record<string, Action> = {
    a_p1: { type: "strength_delta", channel: "A", delta: 1 }, a_p3: { type: "strength_delta", channel: "A", delta: 3 }, a_p5: { type: "strength_delta", channel: "A", delta: 5 },
    a_m1: { type: "strength_delta", channel: "A", delta: -1 }, a_m3: { type: "strength_delta", channel: "A", delta: -3 }, a_m5: { type: "strength_delta", channel: "A", delta: -5 },
    b_p1: { type: "strength_delta", channel: "B", delta: 1 }, b_p3: { type: "strength_delta", channel: "B", delta: 3 }, b_p5: { type: "strength_delta", channel: "B", delta: 5 },
    b_m1: { type: "strength_delta", channel: "B", delta: -1 }, b_m3: { type: "strength_delta", channel: "B", delta: -3 }, b_m5: { type: "strength_delta", channel: "B", delta: -5 },
    wa0: { type: "waveform", channel: "A", waveformId: "imported_0", durationMs: 9999 }, wa1: { type: "waveform", channel: "A", waveformId: "imported_1", durationMs: 9999 }, wa2: { type: "waveform", channel: "A", waveformId: "imported_2", durationMs: 9999 }, wa3: { type: "waveform", channel: "A", waveformId: "imported_3", durationMs: 9999 }, wa4: { type: "waveform", channel: "A", waveformId: "imported_4", durationMs: 9999 }, wa5: { type: "waveform", channel: "A", waveformId: "imported_5", durationMs: 9999 },
    wb0: { type: "waveform", channel: "B", waveformId: "imported_0", durationMs: 9999 }, wb1: { type: "waveform", channel: "B", waveformId: "imported_1", durationMs: 9999 }, wb2: { type: "waveform", channel: "B", waveformId: "imported_2", durationMs: 9999 }, wb3: { type: "waveform", channel: "B", waveformId: "imported_3", durationMs: 9999 }, wb4: { type: "waveform", channel: "B", waveformId: "imported_4", durationMs: 9999 }, wb5: { type: "waveform", channel: "B", waveformId: "imported_5", durationMs: 9999 },
    w_soft: { type: "waveform", channel: "A", waveformId: "soft", durationMs: 1000 },
    w_rhythm: { type: "waveform", channel: "A", waveformId: "rhythm", durationMs: 3000 },
    w_rise: { type: "waveform", channel: "A", waveformId: "rise", durationMs: 3000 },
    stop: { type: "stop" },
  };
  try {
    if (session.snapshot().mode === "collaboration" && !isOwner(ctx.from.id)) {
      const message = await ctx.reply("当前是管理员模式，只有管理员可以操作。");
      setTimeout(() => { void ctx.telegram.deleteMessage(ctx.chat!.id, message.message_id).catch(() => undefined); }, 5000).unref?.();
      return;
    }
    if (code === "auto_ramp_toggle" || code === "auto_ramp_rate") {
      if (!isOwner(ctx.from.id)) { await ctx.reply("只有管理员可以使用自动提升。"); return; }
      if (code === "auto_ramp_toggle") {
        if (autoRampTimer) stopAutoRamp(); else startAutoRamp();
      } else {
        const rates = [3, 5, 7, 11, 13];
        autoRampRateSeconds = rates[(rates.indexOf(autoRampRateSeconds) + 1) % rates.length] ?? 3;
      }
      await ctx.editMessageText(await panelText(), panel(session.config.id));
      return;
    }
    if (code === "join") {
      session.addParticipant(ctx.from.id, ctx.from.username ? `@${ctx.from.username}` : ctx.from.first_name);
      await ctx.editMessageText(await panelText(), panel(session.config.id));
      return;
    }
    if (code === "leave") {
      session.removeParticipant(ctx.from.id);
      await ctx.editMessageText(await panelText(), panel(session.config.id));
      return;
    }
    const action = actions[code];
    if (!action) return;
    if (action.type === "stop") {
      if (!isOwner(ctx.from.id)) { await ctx.reply("只有管理员可以停止不限时会话。"); return; }
      stopAutoRamp();
    }
    const result = await session.submit(ctx.from.id, action);
    try {
      await ctx.editMessageText(await panelText(), panel(session.config.id));
    } catch {
      await ctx.reply(await panelText(), panel(session.config.id));
    }
    if (!result.accepted && session.snapshot().mode === "voting") {
      const voteMessage = await ctx.reply(`投票已记录：${result.votes} 票，5 秒后按最终票数最高的动作生效。`);
      setTimeout(() => { void ctx.telegram.deleteMessage(ctx.chat!.id, voteMessage.message_id).catch(() => undefined); }, 5000).unref?.();
    }
  } catch (error) {
    const errorMessage = await ctx.reply(errorText(error));
    setTimeout(() => { void ctx.telegram.deleteMessage(ctx.chat!.id, errorMessage.message_id).catch(() => undefined); }, 5000).unref?.();
  }
});

bot.catch((error, ctx) => {
  console.error("Telegram handler error", error);
  void ctx.reply("操作失败，设备已保持安全状态。请稍后重试。", adminMenu()).catch(() => undefined);
});

bot.launch().then(async () => {
  await bot.telegram.setMyCommands([
    { command: "start", description: "打开控制面板" },
    { command: "help", description: "查看中文操作说明" },
    { command: "join", description: "加入当前会话" },
    { command: "status", description: "查看设备和会话状态" },
    { command: "connect", description: "管理员：连接 DG-LAB 设备" },
    { command: "newsession", description: "管理员：创建会话" },
    { command: "arm", description: "管理员：授权并启动会话" },
    { command: "panel", description: "打开当前控制面板" },
    { command: "stop", description: "管理员：停止会话" },
    { command: "disarm", description: "管理员：撤销并归零" },
    { command: "disconnect", description: "管理员：停止并断开设备" },
  ]);
  console.log(`DG-LAB Telegram bot started in ${process.env.DG_DEVICE_MODE === "ble" ? "BLE" : "MOCK"} mode`);
});

async function shutdown(signal: "SIGINT" | "SIGTERM"): Promise<void> {
  await session?.stop().catch(() => undefined);
  await device.disconnect().catch(() => undefined);
  bot.stop(signal);
}

process.once("SIGINT", () => { void shutdown("SIGINT"); });
process.once("SIGTERM", () => { void shutdown("SIGTERM"); });
