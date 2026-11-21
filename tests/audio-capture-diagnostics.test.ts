import { describe, expect, it } from "vitest";
import { explainAudioCaptureFailure } from "../src/audio-reactive.js";

describe("macOS ScreenCaptureKit diagnostics", () => {
  it("does not misclassify missing displays as a permissions-only issue", () => {
    const report = explainAudioCaptureFailure('SCStreamErrorDomain Code=-3815 "找不到任何要捕捉的显示器或窗口"');
    expect(report).toContain("显示器");
    expect(report).toContain("无头 Mac");
  });
  it("identifies permissions failure and unknown failure separately", () => {
    expect(explainAudioCaptureFailure("permission denied")).toContain("权限");
    expect(explainAudioCaptureFailure("unrecognized stream failure")).toContain("诊断日志");
  });
});
