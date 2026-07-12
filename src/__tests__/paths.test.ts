import { describe, it, expect } from "bun:test";
import * as paths from "../paths";

/**
 * Dev-socket isolation (supersedes closed PR #265).
 *
 * A dev/agent instance must NEVER bind the live VoiceBar socket that Etan's
 * dictation uses (R-013). `VOICELAYER_SOCKET_PATH` is the sanctioned isolation
 * knob under the canonical VOICELAYER_* naming; the legacy `QA_VOICE_SOCKET_PATH`
 * remains a back-compat alias. When both are set, the canonical name wins.
 */
describe("VOICELAYER_SOCKET_PATH dev-socket isolation", () => {
  const DEV = "/tmp/voicelayer-dev.sock";
  const LEGACY = "/tmp/voicelayer-legacy.sock";
  const MCP_DEV = "/tmp/voicelayer-mcp-dev.sock";
  const MCP_LEGACY = "/tmp/voicelayer-mcp-legacy.sock";

  it("VOICELAYER_SOCKET_PATH overrides the default VoiceBar socket", () => {
    expect(
      paths.getVoiceBarSocketPath({
        VOICELAYER_SOCKET_PATH: DEV,
      } as NodeJS.ProcessEnv),
    ).toBe(DEV);
  });

  it("VOICELAYER_SOCKET_PATH takes precedence over the legacy QA_VOICE_SOCKET_PATH", () => {
    expect(
      paths.getVoiceBarSocketPath({
        VOICELAYER_SOCKET_PATH: DEV,
        QA_VOICE_SOCKET_PATH: LEGACY,
      } as NodeJS.ProcessEnv),
    ).toBe(DEV);
  });

  it("legacy QA_VOICE_SOCKET_PATH still works alone (back-compat)", () => {
    expect(
      paths.getVoiceBarSocketPath({
        QA_VOICE_SOCKET_PATH: LEGACY,
      } as NodeJS.ProcessEnv),
    ).toBe(LEGACY);
  });

  it("falls back to the fixed default when no override is set", () => {
    expect(paths.getVoiceBarSocketPath({} as NodeJS.ProcessEnv)).toBe(
      "/tmp/voicelayer.sock",
    );
  });

  it("isDefaultVoiceBarSocketPath is false for either env name, true for neither", () => {
    expect(paths.isDefaultVoiceBarSocketPath({} as NodeJS.ProcessEnv)).toBe(
      true,
    );
    expect(
      paths.isDefaultVoiceBarSocketPath({
        VOICELAYER_SOCKET_PATH: DEV,
      } as NodeJS.ProcessEnv),
    ).toBe(false);
    expect(
      paths.isDefaultVoiceBarSocketPath({
        QA_VOICE_SOCKET_PATH: LEGACY,
      } as NodeJS.ProcessEnv),
    ).toBe(false);
  });

  it("VOICELAYER_MCP_SOCKET_PATH overrides the MCP socket, precedence over legacy", () => {
    expect(
      paths.getMcpSocketPath({
        VOICELAYER_MCP_SOCKET_PATH: MCP_DEV,
        QA_VOICE_MCP_SOCKET_PATH: MCP_LEGACY,
      } as NodeJS.ProcessEnv),
    ).toBe(MCP_DEV);
    expect(
      paths.getMcpSocketPath({
        QA_VOICE_MCP_SOCKET_PATH: MCP_LEGACY,
      } as NodeJS.ProcessEnv),
    ).toBe(MCP_LEGACY);
  });

  it("getMcpSocketOverridePath honors the canonical name, then legacy, else null", () => {
    expect(paths.getMcpSocketOverridePath({} as NodeJS.ProcessEnv)).toBeNull();
    expect(
      paths.getMcpSocketOverridePath({
        VOICELAYER_MCP_SOCKET_PATH: MCP_DEV,
        QA_VOICE_MCP_SOCKET_PATH: MCP_LEGACY,
      } as NodeJS.ProcessEnv),
    ).toBe(MCP_DEV);
    expect(
      paths.getMcpSocketOverridePath({
        QA_VOICE_MCP_SOCKET_PATH: MCP_LEGACY,
      } as NodeJS.ProcessEnv),
    ).toBe(MCP_LEGACY);
  });

  it("isDefaultMcpSocketPath reflects either MCP env name", () => {
    expect(paths.isDefaultMcpSocketPath({} as NodeJS.ProcessEnv)).toBe(true);
    expect(
      paths.isDefaultMcpSocketPath({
        VOICELAYER_MCP_SOCKET_PATH: MCP_DEV,
      } as NodeJS.ProcessEnv),
    ).toBe(false);
    expect(
      paths.isDefaultMcpSocketPath({
        QA_VOICE_MCP_SOCKET_PATH: MCP_LEGACY,
      } as NodeJS.ProcessEnv),
    ).toBe(false);
  });
});
