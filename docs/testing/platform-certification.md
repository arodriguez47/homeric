# Homeric platform certification matrix

Host-facing acceptance checklist for desktop IME, mobile touch, and
accessibility. This document consolidates the open certification rows from
[`ime-acceptance.md`](ime-acceptance.md),
[`desktop-editing-acceptance.md`](desktop-editing-acceptance.md), and
[`mobile-touch-acceptance.md`](mobile-touch-acceptance.md) into one host
matrix.

**Claim boundary:** automated widget/integration tests and release builds
prove implementation and CI-runnable coverage. They do **not** certify real
device or interactive platform runs. Real-device rows are listed as follow-up.

## CI-runnable automated gates

| Area | Command (from repo / package) | What it covers | Real-device? |
|---|---|---|---|
| Package unit + widget suite | `cd packages/homeric && flutter test` | Model, transform, decorations, controller, clipboard, paragraph, document, input session, geometry | No |
| Platform certification smoke | `cd packages/homeric && flutter test test/editing/platform_certification_smoke_test.dart` | Documents the matrix contract; smoke-checks paste policy default, grabber default width, selection snapshot surface | No |
| Playground unit/widget | `cd packages/homeric/examples/playground && flutter test` | Public controller/session/paragraph host wiring | No |
| Desktop editing matrix | See `desktop-editing-acceptance.md` | Clipboard, selection, spelling, caret | No |
| Mobile touch widgets | See `mobile-touch-acceptance.md` | Handles, magnifier, long-press, floating cursor | No |
| IME widget + mounted adapter | See `ime-acceptance.md` | Composition, epoch, geometry lease, newline action | No |
| Accessibility semantics widgets | Package editable paragraph/document semantics tests under `test/editing/` | Heading role, grabber move labels, text-bearing semantics | No |

## Desktop IME checklist (manual / real host — follow-up)

Record OS, Flutter revision, hardware, build mode, and input method before
claiming certification.

- [ ] Latin typing commits one undo unit per composed replacement
- [ ] Dead-key / accent composition shows composing underline and commits on confirm
- [ ] CJK IME candidate window tracks caret (macOS AppKit / Windows / Linux)
- [ ] Backspace deletes one grapheme cluster, not one code unit
- [ ] Arrow / Option-arrow / word delete match platform conventions
- [ ] Focus transfer and connection loss commit visible composition once
- [ ] No duplicate mutation from Edit-menu selectors + physical shortcuts

**Status:** not run on this batch. Prior ledgers remain the source of historical notes.

## Mobile touch checklist (manual / real device — follow-up)

- [ ] Long-press expands word selection with platform handles
- [ ] Handle drag crosses block boundaries without a second selection owner
- [ ] Magnifier appears on iOS/Android during drag
- [ ] Floating cursor (iOS) moves caret without scrolling ownership races
- [ ] Soft keyboard insert/delete while a handle is active stays epoch-safe
- [ ] Rotation retains one controller / input-session owner

**Status:** simulator/emulator evidence exists in `mobile-touch-acceptance.md`;
physical iOS and Android devices remain **Not run**.

## Accessibility checklist (manual + automated)

Automated:

- [x] Editable paragraph exposes text-bearing semantics (widget tests)
- [x] Optional `semanticsHeader` for heading blocks (widget tests)
- [x] Block grabber exposes "Move block…" semantics when reorderable (widget tests)

Manual follow-up (real VoiceOver / TalkBack / screen reader):

- [ ] Rotor / reading order matches visual block order
- [ ] Selection announcements stay coherent across block boundaries
- [ ] Grabber custom actions are discoverable when `blockGrabberWidth > 0`
- [ ] Collapsed grabber (`blockGrabberWidth == 0`) does not leave orphaned move semantics

## Web / Linux / Windows follow-up

| Host | Status |
|---|---|
| Web (Latin) | Best-effort; CJK blocked by flutter/flutter#120613 |
| Linux desktop | Not run |
| Windows desktop | Not run |
| Physical iOS | Not run |
| Physical Android | Not run |

## How to extend this matrix

1. Add a CI-runnable widget or integration test under `packages/homeric/test/`
   or the playground `integration_test/` harness.
2. Link the test path in the automated gates table above.
3. Keep real-device rows unchecked until a recorded run with hardware, OS,
   Flutter revision, and evidence path is attached.
