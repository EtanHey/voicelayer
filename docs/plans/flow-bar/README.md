# Flow Bar — VoiceLayer Floating Widget

> Free, open-source Wispr Flow alternative for Claude Code.
> Native macOS SwiftUI pill + Unix socket IPC to VoiceLayer MCP server.

**Design doc:** [../2026-02-24-flow-bar-design.md](../2026-02-24-flow-bar-design.md)
**Research:** `docs.local/logs/research-{1..6}-*.md`

---

## Progress

| # | Phase | Folder | Status | Branch | PR |
|---|-------|--------|--------|--------|----|
| 1 | Socket Server (Bun) | [phase-1](phase-1/) | done | feature/phase-1-socket-server | PR #20 merged |
| 2 | State Emission | [phase-2](phase-2/) | done | feature/phase-2-state-emission | PR #21 merged |
| 3 | SwiftUI App Scaffold | [phase-3](phase-3/) | done | feature/phase-3-swiftui-scaffold | PR #22 merged |
| 4 | Socket Client + State | [phase-4](phase-4/) | done | feature/phase-4-socket-client-state | PR #23 (merged with Phase 3) |
| 5 | Waveform + Visual Polish | [phase-5](phase-5/) | in progress | feature/phase-5-waveform-polish | |
| 6 | Integration + CLI | [phase-6](phase-6/) | pending | | |
| 7 | Live Dictation (v1.5) | [phase-7](phase-7/) | pending | | |

---

## Architecture

```
┌─────────────────────┐       Unix socket        ┌──────────────────┐
│  VoiceLayer MCP     │  ◄──────────────────────► │  Flow Bar        │
│  (Bun/TypeScript)   │  /tmp/voicelayer.sock     │  (SwiftUI app)   │
│                     │                           │                  │
│  Creates socket     │  JSON newline-delimited   │  Reconnecting    │
│  Sends state events │  ────────────────────►    │  client          │
│  Receives commands  │  ◄────────────────────    │  Sends commands  │
└─────────────────────┘                           └──────────────────┘
```

## Key Research Findings

| # | Topic | Key Insight | Source |
|---|-------|-------------|--------|
| 1 | whisper streaming | No `--stream` flag on whisper-cli. Need whisper-server sidecar compiled from source. ~1.5-2s latency per 3s chunk. | research-1 |
| 2 | SwiftUI + socket | NSPanel + `.nonactivatingPanel` for non-focus-stealing. `NWEndpoint.unix()` for socket client. `.accessory` activation policy. | research-2 |
| 3 | Bun socket | `Bun.listen({ unix })` native API. Backpressure via drain handler. Coexists cleanly with MCP stdio. | research-3 |
| 4 | macOS audio | sox DOES trigger orange dot. AVAudioEngine recommended for SwiftUI app (10-40x lower latency, proper permissions). | research-4 |
| 5 | Waveform | TimelineView 60fps, golden-ratio phase offsets, 3 modes (idle/listening/speech). Complete Swift code ready. | research-5 |
| 6 | Wispr Flow | Electron ~800MB RAM, cloud-hybrid ASR, screenshot-based context, $8/mo. Native Swift beats it on resources. | research-6 |

## Execution Rules

Each phase = one branch = one PR. TDD: write tests first, then implement.

See `/large-plan` skill for the full protocol.

## Cross-Phase Knowledge

Update this section as phases complete:
- Socket protocol spec → phase-1/findings.md
- State machine transitions → phase-2/findings.md
- SwiftUI window tricks → phase-3/findings.md
- Waveform animation tuning → phase-5/findings.md
