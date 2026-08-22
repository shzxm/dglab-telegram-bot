/** Compact callback payloads bind every button to the session that rendered it. */
export function callbackData(sessionId: string, code: string): string {
  const sid = sessionId.replaceAll("-", "").slice(0, 12);
  if (!/^[a-f0-9]{12}$/.test(sid)) throw new Error("invalid session id");
  if (!/^[a-z0-9_]+$/.test(code)) throw new Error("invalid callback code");
  return `s:${sid}:${code}`;
}

export function parseCallbackData(data: string, sessionId: string): string | null {
  const match = /^s:([a-f0-9]{12}):([a-z0-9_]+)$/.exec(data);
  const sid = sessionId.replaceAll("-", "").slice(0, 12);
  if (!match || !match[1] || !match[2] || match[1] !== sid) return null;
  return match[2];
}
