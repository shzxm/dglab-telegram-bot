import { describe, expect, it } from "vitest";
import { loadConfig } from "../src/config.js";

describe("macOS embedded App, offline and safe-by-default", () => {
  it("allows local Mock controls without requiring Telegram credentials", () => {
    const c = loadConfig({ DG_DESKTOP_OFFLINE: "1", DG_DEVICE_MODE: "mock" });
    expect(c.deviceMode).toBe("mock");
    expect(c.ownerUserId).toBe(1);
    expect(c.token).toContain("LOCAL_TEST_TOKEN_NEVER_USED");
  });
  it("requires an actual Bot token when online", () => {
    expect(() => loadConfig({ DG_DEVICE_MODE: "mock" })).toThrow(/TG_BOT_TOKEN/);
  });
  it("does not silently upgrade Mock mode to real BLE", () => {
    const c = loadConfig({ DG_DESKTOP_OFFLINE: "1" });
    expect(c.deviceMode).toBe("mock");
  });
  it("validates device modes even in local-only test mode", () => {
    expect(() => loadConfig({ DG_DESKTOP_OFFLINE: "1", DG_DEVICE_MODE: "unexpected" })).toThrow(/DG_DEVICE_MODE/);
  });
});
