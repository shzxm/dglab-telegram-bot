import { randomBytes } from "node:crypto";

const ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";

export function createInviteCode(length = 8): string {
  if (!Number.isInteger(length) || length < 6 || length > 16) throw new Error("邀请码长度必须为 6 到 16 位");
  const bytes = randomBytes(length);
  return [...bytes].map((value) => ALPHABET[value % ALPHABET.length]).join("");
}

export function normalizeInviteCode(value: string | undefined): string {
  return (value ?? "").trim().toUpperCase().replace(/[^A-Z0-9]/g, "");
}

export function inviteCodeMatches(expected: string, supplied: string | undefined): boolean {
  const normalized = normalizeInviteCode(supplied);
  return normalized.length > 0 && normalized === normalizeInviteCode(expected);
}
