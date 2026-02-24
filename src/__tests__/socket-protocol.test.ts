import { describe, it, expect } from "bun:test";
import {
  serializeEvent,
  parseCommand,
  type SocketEvent,
  type SocketCommand,
} from "../socket-protocol";

describe("socket-protocol", () => {
  describe("serializeEvent", () => {
    it("serializes state idle event to NDJSON", () => {
      const event: SocketEvent = { type: "state", state: "idle" };
      const result = serializeEvent(event);
      expect(result).toBe('{"type":"state","state":"idle"}\n');
    });

    it("serializes state speaking event with text and voice", () => {
      const event: SocketEvent = {
        type: "state",
        state: "speaking",
        text: "Hello world",
        voice: "jenny",
      };
      const result = serializeEvent(event);
      expect(result).toEndWith("\n");
      const parsed = JSON.parse(result.trim());
      expect(parsed.type).toBe("state");
      expect(parsed.state).toBe("speaking");
      expect(parsed.text).toBe("Hello world");
      expect(parsed.voice).toBe("jenny");
    });

    it("serializes state recording event with mode", () => {
      const event: SocketEvent = {
        type: "state",
        state: "recording",
        mode: "vad",
        silence_mode: "quick",
      };
      const result = serializeEvent(event);
      const parsed = JSON.parse(result.trim());
      expect(parsed.state).toBe("recording");
      expect(parsed.mode).toBe("vad");
      expect(parsed.silence_mode).toBe("quick");
    });

    it("serializes speech detected event", () => {
      const event: SocketEvent = { type: "speech", detected: true };
      const result = serializeEvent(event);
      expect(result).toBe('{"type":"speech","detected":true}\n');
    });

    it("serializes transcription event", () => {
      const event: SocketEvent = {
        type: "transcription",
        text: "The user said this",
      };
      const result = serializeEvent(event);
      const parsed = JSON.parse(result.trim());
      expect(parsed.type).toBe("transcription");
      expect(parsed.text).toBe("The user said this");
    });

    it("serializes partial transcription event", () => {
      const event: SocketEvent = {
        type: "transcription",
        text: "The user",
        partial: true,
      };
      const result = serializeEvent(event);
      const parsed = JSON.parse(result.trim());
      expect(parsed.partial).toBe(true);
    });

    it("serializes error event", () => {
      const event: SocketEvent = {
        type: "error",
        message: "Mic not available",
        recoverable: true,
      };
      const result = serializeEvent(event);
      const parsed = JSON.parse(result.trim());
      expect(parsed.type).toBe("error");
      expect(parsed.message).toBe("Mic not available");
      expect(parsed.recoverable).toBe(true);
    });

    it("always ends with newline", () => {
      const events: SocketEvent[] = [
        { type: "state", state: "idle" },
        { type: "speech", detected: false },
        { type: "transcription", text: "test" },
        { type: "error", message: "err", recoverable: false },
      ];
      for (const event of events) {
        expect(serializeEvent(event)).toEndWith("\n");
      }
    });
  });

  describe("parseCommand", () => {
    it("parses stop command", () => {
      const result = parseCommand('{"cmd":"stop"}');
      expect(result).toEqual({ cmd: "stop" });
    });

    it("parses replay command", () => {
      const result = parseCommand('{"cmd":"replay"}');
      expect(result).toEqual({ cmd: "replay" });
    });

    it("parses toggle command with all fields", () => {
      const result = parseCommand(
        '{"cmd":"toggle","scope":"tts","enabled":false}',
      );
      expect(result).toEqual({ cmd: "toggle", scope: "tts", enabled: false });
    });

    it("parses toggle command with mic scope", () => {
      const result = parseCommand(
        '{"cmd":"toggle","scope":"mic","enabled":true}',
      );
      expect(result).toEqual({ cmd: "toggle", scope: "mic", enabled: true });
    });

    it("defaults toggle scope to all when missing", () => {
      const result = parseCommand('{"cmd":"toggle","enabled":true}');
      expect(result).toEqual({ cmd: "toggle", scope: "all", enabled: true });
    });

    it("defaults toggle scope to all when invalid", () => {
      const result = parseCommand(
        '{"cmd":"toggle","scope":"invalid","enabled":true}',
      );
      expect(result).toEqual({ cmd: "toggle", scope: "all", enabled: true });
    });

    it("returns null for toggle without enabled", () => {
      const result = parseCommand('{"cmd":"toggle","scope":"tts"}');
      expect(result).toBeNull();
    });

    it("returns null for invalid JSON", () => {
      expect(parseCommand("not json")).toBeNull();
    });

    it("returns null for non-object", () => {
      expect(parseCommand('"just a string"')).toBeNull();
    });

    it("returns null for missing cmd field", () => {
      expect(parseCommand('{"type":"stop"}')).toBeNull();
    });

    it("returns null for unknown command", () => {
      expect(parseCommand('{"cmd":"unknown"}')).toBeNull();
    });

    it("returns null for empty string", () => {
      expect(parseCommand("")).toBeNull();
    });

    it("ignores extra fields on stop command", () => {
      const result = parseCommand('{"cmd":"stop","extra":"data"}');
      expect(result).toEqual({ cmd: "stop" });
    });
  });
});
