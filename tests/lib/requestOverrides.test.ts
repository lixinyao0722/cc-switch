import { describe, expect, it } from "vitest";
import {
  buildLocalProxyRequestOverrides,
  isProtectedLocalProxyHeaderName,
  isValidHttpHeaderName,
  isValidHttpHeaderValue,
  parseBodyOverrideJson,
  parseHeaderOverrideJson,
  parseRequestOverrideJson,
  resolveCodexActivitySummaryMode,
} from "@/lib/requestOverrides";

describe("requestOverrides", () => {
  const modelhubPolicy = {
    appId: "codex" as const,
    codexSessionHeaderAdapter: "modelhub" as const,
    codexActivitySummaryMode: "map" as const,
    codexMetadataModel: "gpt-5.6-sol",
    rememberInvalidEncryptedReasoning: true,
    retry429: {
      maxRetries: 10,
      baseDelayMs: 1000,
      maxDelayMs: 30000,
      honorRetryAfter: true,
    },
  };

  it("treats empty JSON fields as unset", () => {
    expect(buildLocalProxyRequestOverrides("", "   ")).toEqual({});
  });

  it("parses header and body override objects", () => {
    expect(
      buildLocalProxyRequestOverrides(
        '{ "X-Test": "ok" }',
        '{ "temperature": 0.2 }',
      ),
    ).toEqual({
      overrides: {
        headers: { "x-test": "ok" },
        body: { temperature: 0.2 },
      },
    });
  });

  it("rejects non-object body overrides", () => {
    expect(parseRequestOverrideJson("[]").error).toBeTruthy();
  });

  it("rejects non-string header values", () => {
    expect(parseHeaderOverrideJson('{ "X-Test": 1 }').error).toBeTruthy();
  });

  it("rejects invalid header names", () => {
    expect(isValidHttpHeaderName("X-Test")).toBe(true);
    expect(isValidHttpHeaderName("X Foo")).toBe(false);
    expect(isValidHttpHeaderName("Authorization:")).toBe(false);
    expect(parseHeaderOverrideJson('{ "X Foo": "bar" }').error).toBeTruthy();
  });

  it("rejects duplicate header names after case normalization", () => {
    expect(
      parseHeaderOverrideJson('{ "X-Foo": "a", "x-foo": "b" }').error,
    ).toBeTruthy();
  });

  it("rejects protected proxy-managed header names", () => {
    expect(isProtectedLocalProxyHeaderName("Content-Type")).toBe(true);
    expect(isProtectedLocalProxyHeaderName("authorization")).toBe(true);
    expect(isProtectedLocalProxyHeaderName("X-Test")).toBe(false);
    expect(
      parseHeaderOverrideJson('{ "content-type": "text/plain" }').error,
    ).toBeTruthy();
    expect(
      parseHeaderOverrideJson('{ "Authorization": "Bearer x" }').error,
    ).toBeTruthy();
  });

  it("matches backend header value control-character rule", () => {
    expect(isValidHttpHeaderValue("hello\tworld")).toBe(true);
    expect(isValidHttpHeaderValue("hello\nworld")).toBe(false);
  });

  it("rejects stream in body overrides", () => {
    expect(parseBodyOverrideJson('{ "stream": true }').error).toBeTruthy();
    expect(
      buildLocalProxyRequestOverrides("", '{ "stream": false }').error,
    ).toBeTruthy();
  });

  it("builds complete ModelHub proxy policy", () => {
    expect(
      buildLocalProxyRequestOverrides(
        "",
        '{ "max_output_tokens": 128000 }',
        modelhubPolicy,
      ),
    ).toEqual({
      overrides: {
        body: { max_output_tokens: 128000 },
        codexSessionHeaderAdapter: "modelhub",
        codexActivitySummaryMode: "map",
        codexMetadataModel: "gpt-5.6-sol",
        rememberInvalidEncryptedReasoning: true,
        retry429: {
          maxRetries: 10,
          baseDelayMs: 1000,
          maxDelayMs: 30000,
          honorRetryAfter: true,
        },
      },
    });
  });

  it("rejects retry count above ten", () => {
    expect(
      buildLocalProxyRequestOverrides("", "", {
        ...modelhubPolicy,
        retry429: { ...modelhubPolicy.retry429, maxRetries: 11 },
      }).error,
    ).toBeTruthy();
  });

  it("rejects max delay below base delay", () => {
    expect(
      buildLocalProxyRequestOverrides("", "", {
        ...modelhubPolicy,
        retry429: {
          ...modelhubPolicy.retry429,
          baseDelayMs: 2000,
          maxDelayMs: 1000,
        },
      }).error,
    ).toBeTruthy();
  });

  it("removes ModelHub-only fields for non-Codex providers", () => {
    expect(
      buildLocalProxyRequestOverrides("", '{ "temperature": 0.2 }', {
        ...modelhubPolicy,
        appId: "claude",
      }),
    ).toEqual({ overrides: { body: { temperature: 0.2 } } });
  });

  it("resolves legacy activity-summary blocking without overriding the new mode", () => {
    expect(
      resolveCodexActivitySummaryMode({ blockCodexActivitySummaries: true }),
    ).toBe("block");
    expect(
      resolveCodexActivitySummaryMode({
        blockCodexActivitySummaries: true,
        codexActivitySummaryMode: "map",
      }),
    ).toBe("map");
    expect(resolveCodexActivitySummaryMode(undefined)).toBe("passthrough");
  });

  it("requires a metadata target when activity summaries are mapped", () => {
    expect(
      buildLocalProxyRequestOverrides("", "", {
        ...modelhubPolicy,
        codexMetadataModel: "   ",
      }).error,
    ).toBe("Activity-summary mapping requires a metadata model");
  });

  it("drops every ModelHub-only policy when the session adapter is disabled", () => {
    expect(
      buildLocalProxyRequestOverrides("", '{ "temperature": 0.2 }', {
        ...modelhubPolicy,
        codexSessionHeaderAdapter: undefined,
      }),
    ).toEqual({ overrides: { body: { temperature: 0.2 } } });
  });

  it("preserves body max_output_tokens as a number", () => {
    const result = buildLocalProxyRequestOverrides(
      "",
      '{ "max_output_tokens": 128000 }',
      modelhubPolicy,
    );

    expect(result.overrides?.body?.max_output_tokens).toBe(128000);
    expect(typeof result.overrides?.body?.max_output_tokens).toBe("number");
  });
});
