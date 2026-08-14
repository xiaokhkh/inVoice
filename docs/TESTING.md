# Testing checklist

## Automated core tests

Run from the repository root:

```bash
swift test
```

The `VoiceOpsCore` package covers the Fn/board Session state machine, early
key-up during startup, stale Session rejection, one-time insertion ownership,
cooldown, the two-event Cmd+V plan, clipboard deep snapshots, conditional
restore, copy-only fallback, consecutive injections, and delivery-slot
serialization.

## Sidecars

- Start ASR and LLM servers without errors.
- Run `scripts/smoke_llm.sh` and verify JSON response.
- Run `scripts/smoke_asr.sh` and verify JSON response (likely empty text for silence).
- POST a short wav to `/v1/asr/transcribe` and verify JSON response.
- POST a sample request to `/v1/llm/generate` and verify JSON response.

## macOS app

- Launch app and confirm menu bar icon appears.
- Focus a text field in another app (Slack/Chrome/VSCode).
- Hold Fn or one board control to start streaming; verify preview feedback updates but the focused field is not mutated yet.
- Release Fn or the board control; verify exactly one final result is pasted.
- Confirm no overlay or focus change occurs during Fn hold.
- If Accessibility is disabled, verify text is copied to clipboard and no injection occurs.
- Release immediately during startup and confirm recording does not remain stuck.
- Switch applications during final ASR and confirm the result is copied rather than pasted into the new app.
- Copy new clipboard content during injection and confirm it is not overwritten by delayed restoration.
- Repeat in Codex, a browser contenteditable, Feishu, TextEdit, Terminal/iTerm2, and a non-QWERTY keyboard layout.
