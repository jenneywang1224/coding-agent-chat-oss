import { describe, it, expect } from "vitest";
import { findSafeCutIndex } from "../src/context-compressor.js";
import type { ChatMessage } from "../src/types.js";

/**
 * `findSafeCutIndex` is the contract that guarantees the compressed messages
 * array still forms a valid request for the DeepSeek/OpenAI chat completions
 * API. The invariant we enforce: `messages.slice(cutIdx)` must not start with
 * a `role: "tool"` message, otherwise the API rejects the request because the
 * `tool_call_id` references an `assistant.tool_calls` we no longer include.
 */
describe("findSafeCutIndex", () => {
  const sys = (): ChatMessage => ({ role: "system", content: "sys" });
  const user = (text = "u"): ChatMessage => ({ role: "user", content: text });
  const asstText = (text = "a"): ChatMessage => ({ role: "assistant", content: text });
  const asstTool = (callId: string, name = "read_file"): ChatMessage => ({
    role: "assistant",
    content: null,
    tool_calls: [
      { id: callId, type: "function", function: { name, arguments: "{}" } },
    ],
  });
  const tool = (callId: string, output = "ok"): ChatMessage => ({
    role: "tool",
    content: output,
    tool_call_id: callId,
  });

  it("keeps cut as-is when the proposed message is not a tool message", () => {
    const messages = [sys(), user("u1"), asstText("a1"), user("u2"), asstText("a2")];
    // proposed cut at index 3 (user) — already safe
    expect(findSafeCutIndex(messages, 3)).toBe(3);
  });

  it("walks back from a tool message to the matching assistant(tool_calls)", () => {
    // [system, user, asst(tc1), tool(tc1), asst("done")]
    const messages = [
      sys(),
      user("u1"),
      asstTool("tc1"),
      tool("tc1", "result"),
      asstText("done"),
    ];
    // proposed cut at 3 (tool) — must walk back to 2 (asst(tc1)) to keep the pair
    const safe = findSafeCutIndex(messages, 3);
    expect(safe).toBe(2);
    expect(messages[safe].role).toBe("assistant");
    expect(messages[safe].tool_calls?.[0]?.id).toBe("tc1");
  });

  it("walks back across multiple tool responses to the assistant", () => {
    // assistant emitted two tool_calls, both responses follow.
    const messages = [
      sys(),
      user("u1"),
      asstTool("tc1"),
      tool("tc1"),
      tool("tc2"),
      asstText("done"),
    ];
    // proposed cut at 4 (second tool) — walk back: 3 tool → 2 asst
    expect(findSafeCutIndex(messages, 4)).toBe(2);
  });

  it("floors at index 1 so the system message is always preserved", () => {
    // pathological: every message after system is a tool message
    const messages = [sys(), tool("x"), tool("y"), tool("z")];
    // proposed cut at 3 (tool) — walk back through 2,1 stops at 1
    expect(findSafeCutIndex(messages, 3)).toBe(1);
  });

  it("clamps oversized proposed cut to messages.length", () => {
    const messages = [sys(), user(), asstText()];
    expect(findSafeCutIndex(messages, 999)).toBe(3);
  });

  it("clamps undersized proposed cut to 1", () => {
    const messages = [sys(), user(), asstText()];
    expect(findSafeCutIndex(messages, -5)).toBe(1);
  });

  it("makes the resulting slice a valid suffix (no leading tool message)", () => {
    // Realistic 20-message conversation with mixed tool blocks.
    const messages: ChatMessage[] = [sys(), user("u0")];
    for (let i = 1; i <= 6; i++) {
      messages.push(asstTool(`tc${i}`));
      messages.push(tool(`tc${i}`));
    }
    messages.push(asstText("final"));

    for (let proposed = 1; proposed <= messages.length; proposed++) {
      const cut = findSafeCutIndex(messages, proposed);
      const suffix = messages.slice(cut);
      if (suffix.length > 0) {
        expect(suffix[0].role, `cut=${cut}`).not.toBe("tool");
      }
    }
  });
});
