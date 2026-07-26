import { describe, expect, it } from "vitest";
import { formatDuration, stateLabel } from "./format";

describe("formatDuration", () => {
  it("formats short and long recordings", () => {
    expect(formatDuration(65_000)).toBe("1:05");
    expect(formatDuration(3_665_000)).toBe("1:01:05");
  });
});

describe("stateLabel", () => {
  it("maps processing states to Japanese", () => {
    expect(stateLabel("diarizing")).toBe("話者を解析中");
  });
});

