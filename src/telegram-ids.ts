type TelegramUpdate = {
  update_id?: number;
  message?: {
    from?: { id?: number };
    chat?: { id?: number; type?: string; title?: string };
  };
};

const token = process.env.TG_BOT_TOKEN || await readKeychainToken();
if (!token) throw new Error("TG_BOT_TOKEN is not set and Keychain item is unavailable");
const response = await fetch(`https://api.telegram.org/bot${token}/getUpdates?limit=100&timeout=0`);
if (!response.ok) throw new Error(`Telegram getUpdates failed: HTTP ${response.status}`);
const payload = await response.json() as { ok?: boolean; result?: TelegramUpdate[] };
if (!payload.ok) throw new Error("Telegram getUpdates returned ok=false");

const rows = new Map<string, { userId: number; chatId: number; type: string; title: string }>();
for (const update of payload.result ?? []) {
  const from = update.message?.from?.id;
  const chat = update.message?.chat;
  if (from === undefined || chat?.id === undefined) continue;
  rows.set(`${from}:${chat.id}`, { userId: from, chatId: chat.id, type: chat.type ?? "unknown", title: chat.title ?? "" });
}
if (rows.size === 0) {
  console.log("没有待处理的普通消息。请先私聊机器人发送 /start，并在目标群发送一条消息后重试。");
} else {
  for (const row of rows.values()) console.log(`user_id=${row.userId}\tchat_id=${row.chatId}\ttype=${row.type}\ttitle=${row.title}`);
}

async function readKeychainToken(): Promise<string> {
  const { execFile } = await import("node:child_process");
  const { promisify } = await import("node:util");
  try {
    return (await promisify(execFile)("security", ["find-generic-password", "-a", process.env.USER ?? "", "-s", "dglab-telegram-bot", "-w"])).stdout.trim();
  } catch { return ""; }
}
