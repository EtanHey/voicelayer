import { describe, expect, it } from "bun:test";
import {
  parseVoiceSdkCommand,
  serializeVoiceSdkEvent,
  type VoiceSdkEvent,
} from "../voicesdk/protocol";

describe("VoiceSDK protocol", () => {
  it("serializes semantic events as append-only NDJSON", () => {
    const event: VoiceSdkEvent = {
      type: "session.started",
      session_id: "session-1",
      product: "VoiceReview",
      artifact_id: "artifact-1",
      created_at: "2026-05-28T12:00:00.000Z",
      sequence: 1,
    };

    const line = serializeVoiceSdkEvent(event);

    expect(line).toBe(
      '{"type":"session.started","session_id":"session-1","product":"VoiceReview","artifact_id":"artifact-1","created_at":"2026-05-28T12:00:00.000Z","sequence":1}\n',
    );
  });

  it("supports the blueprint event names without mapping through legacy socket events", () => {
    const events: VoiceSdkEvent[] = [
      {
        type: "section.started",
        session_id: "s",
        section_id: "intro",
        title: "Intro",
        ordinal: 1,
        sequence: 2,
      },
      {
        type: "speak.started",
        session_id: "s",
        utterance_id: "u",
        voice_id: "theo",
        text_preview: "Hello",
        sequence: 3,
      },
      {
        type: "speak.chunk",
        session_id: "s",
        utterance_id: "u",
        index: 0,
        text: "Hello",
        final: true,
        sequence: 4,
      },
      {
        type: "speak.stopped",
        session_id: "s",
        utterance_id: "u",
        reason: "completed",
        sequence: 5,
      },
      {
        type: "listen.started",
        session_id: "s",
        turn_id: "t",
        mode: "vad",
        sequence: 6,
      },
      {
        type: "user.speech_started",
        session_id: "s",
        turn_id: "t",
        onset_ms: 125,
        sequence: 7,
      },
      {
        type: "user.interrupted",
        session_id: "s",
        turn_id: "t",
        stopped_utterance_id: "u",
        onset_to_stop_ms: 80,
        sequence: 8,
      },
      {
        type: "transcript.partial",
        session_id: "s",
        turn_id: "t",
        text: "part",
        confidence: 0.8,
        sequence: 9,
      },
      {
        type: "transcript.final",
        session_id: "s",
        turn_id: "t",
        raw_text: "raw",
        cleaned_text: "clean",
        stt_backend: "whisper.cpp",
        cleanup_backend: "rules",
        sequence: 10,
      },
      {
        type: "answer.final",
        session_id: "s",
        turn_id: "t",
        text: "answer",
        applies_to: "artifact",
        sequence: 11,
      },
      {
        type: "decision.recorded",
        session_id: "s",
        decision_id: "d",
        artifact_ref: "artifact",
        summary: "Ship it",
        status: "accepted",
        sequence: 12,
      },
      {
        type: "artifact.patch_proposed",
        session_id: "s",
        artifact_ref: "artifact",
        patch_ref: "patch",
        summary: "Patch",
        sequence: 13,
      },
      {
        type: "artifact.patch_applied",
        session_id: "s",
        artifact_ref: "artifact",
        patch_ref: "patch",
        sequence: 14,
      },
      {
        type: "session.ended",
        session_id: "s",
        reason: "completed",
        duration_ms: 500,
        sequence: 15,
      },
    ];

    expect(events.map((event) => JSON.parse(serializeVoiceSdkEvent(event)).type))
      .toEqual([
        "section.started",
        "speak.started",
        "speak.chunk",
        "speak.stopped",
        "listen.started",
        "user.speech_started",
        "user.interrupted",
        "transcript.partial",
        "transcript.final",
        "answer.final",
        "decision.recorded",
        "artifact.patch_proposed",
        "artifact.patch_applied",
        "session.ended",
      ]);
  });

  it("parses session commands from NDJSON lines", () => {
    expect(
      parseVoiceSdkCommand(
        '{"cmd":"session.start","product":"VoiceReview","artifact_id":"a1"}',
      ),
    ).toEqual({
      cmd: "session.start",
      product: "VoiceReview",
      artifact_id: "a1",
    });
    expect(
      parseVoiceSdkCommand(
        '{"cmd":"speak","session_id":"s","text":"Hello","voice_id":"theo"}',
      ),
    ).toEqual({
      cmd: "speak",
      session_id: "s",
      text: "Hello",
      voice_id: "theo",
    });
    expect(
      parseVoiceSdkCommand(
        '{"cmd":"listen","session_id":"s","mode":"push_to_talk","timeout_ms":5000}',
      ),
    ).toEqual({
      cmd: "listen",
      session_id: "s",
      mode: "push_to_talk",
      timeout_ms: 5000,
    });
    expect(
      parseVoiceSdkCommand(
        '{"cmd":"decision.record","session_id":"s","artifact_ref":"file.md","summary":"Keep","status":"accepted"}',
      ),
    ).toMatchObject({
      cmd: "decision.record",
      session_id: "s",
      artifact_ref: "file.md",
      summary: "Keep",
      status: "accepted",
    });
    expect(
      parseVoiceSdkCommand(
        '{"cmd":"session.end","session_id":"s","reason":"completed"}',
      ),
    ).toEqual({
      cmd: "session.end",
      session_id: "s",
      reason: "completed",
    });
  });

  it("rejects invalid or legacy commands", () => {
    expect(parseVoiceSdkCommand("not json")).toBeNull();
    expect(parseVoiceSdkCommand('{"cmd":"stop"}')).toBeNull();
    expect(parseVoiceSdkCommand('{"cmd":"speak","text":""}')).toBeNull();
  });
});
