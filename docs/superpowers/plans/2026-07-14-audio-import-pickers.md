# Audio Import Pickers Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace audio import language and model text fields with typed, user-readable pickers.

**Architecture:** Keep `ImportOptions` and persistence unchanged. Add typed UI-only language/provider/model options in `AudioImportView.swift`; `AudioImportFormState.makeOptions()` maps selections to existing `en`/`zh` and WhisperKit model IDs.

**Tech Stack:** Swift 5.9, SwiftUI, Swift Testing, macOS 14.

## Global Constraints

- Preserve all existing uncommitted changes.
- Do not change SQLite schema or import coordinator interfaces.
- Current model catalog contains only local WhisperKit Large V3; no Groq audio request is added.
- Rebuild and sign `dist/HySimulatranslate.app` after verification.

---

### Task 1: Typed language and transcription model pickers

**Files:**
- Modify: `Sources/HySimulatranslate/Views/AudioImportView.swift`
- Modify: `Tests/HySimulatranslateTests/MeetingWorkspacePresentationTests.swift`

**Interfaces:**
- Produces: `AudioImportLanguageOption`, `AudioTranscriptionProvider`, `AudioTranscriptionModelOption`.
- `AudioImportFormState.makeOptions() -> ImportOptions` remains the persistence boundary.

- [ ] Update the existing audio-import default test to require “英语/中文”, `en/zh`, one local WhisperKit model option, and the real model ID.
- [ ] Run `swift test --filter MeetingWorkspacePresentationTests.audioImportLanguageAndModelDefaults` and confirm it fails because the typed options do not exist.
- [ ] Implement the option types and replace the three `TextField` controls with `Picker` controls.
- [ ] Run `swift test --filter MeetingWorkspacePresentationTests` and confirm all focused tests pass.
- [ ] Run `swift test`, `git diff --check`, and `swift build -c release`.
- [ ] Run `./script/package_dmg.sh package`, verify the app signature, and launch the rebuilt dist app.
