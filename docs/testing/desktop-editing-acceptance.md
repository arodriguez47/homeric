# Desktop editing acceptance

This ledger records the evidence for
[HOM-19](https://linear.app/xana-studios/issue/HOM-19). Automated tests and a
release build support the implementation, but they do not replace interaction
with the real macOS text system.

## Current status

As of 2026-08-22, the automated desktop-editing matrix is green and the macOS
playground compiles in release mode. The HOM-19 source and focused playground
matrix also pass under an isolated Flutter 3.24.5 SDK. The checked-in local
compatibility gate now validates its targets and passes the complete package
and playground analysis/test matrix on that SDK. Manual AppKit acceptance
remains open, so HOM-19 has strong implementation and SDK-compatibility
evidence but is not yet platform-certified.

| Gate | Result | Evidence boundary |
|---|---|---|
| Controller, clipboard, input-session, paragraph, geometry, and overlay tests | PASS | 197 tests passed locally. Covers canonical undo/redo, stale-safe clipboard work, selectors, word commands, multi-click and drag selection, adaptive menu behavior, injected spelling results, caret timing, inactive selection, and release-safe geometry readiness. |
| Playground integration | PASS | 32 tests passed locally. Covers public controller history, clipboard feedback, injected spelling, input, block switching, presentation rebuilds, and one undo pipeline. |
| Complete Homeric package suite | PASS (current tree, 2026-08-22) | 745 tests passed with one intentional skip after the latest HOM-20 touch-lifecycle and HOM-21 input-action/adapter-trace changes. The mounted framework adapter trace remains a separate host-process gate. |
| Complete playground unit/widget suite | PASS | 38 tests passed on the same tree, including the package-owned web-host guard. |
| Homeric package analysis | PASS | Full package `flutter analyze` reported no issues after the HOM-21 geometry-capability change. |
| Playground analysis | PASS | Full playground `flutter analyze` reported no issues after the HOM-21 geometry-capability change. |
| macOS release build | PASS | `flutter build macos --release` produced `build/macos/Build/Products/Release/homeric_playground.app` (43.3 MB). Compilation proves release-safe code paths; it does not prove AppKit delivery or interaction. |
| Flutter 3.24 compatibility | PASS (tracked local gate) | On 2026-08-22, `scripts/verify_flutter_3_24.sh /private/tmp/flutter-3.24.5/bin/flutter` validated its package/playground targets, analyzed both projects, and passed their complete unit/widget suites under Flutter 3.24.5 (`dec2ee5c1f`). The protected untracked `tool/verify_flutter_3_24.sh` was not changed or used as evidence. |
| Manual macOS acceptance | NOT RUN / HISTORICAL NOTE ONLY | An August 20 interactive pass was reported, but no complete record with hardware, OS, Flutter revision, build mode, input method, and evidence path was retained. It is not certification evidence. The full checklist below remains open. |

## Manual macOS checklist

Run the release playground and verify each action produces one visible result
and one history unit where applicable:

- Cmd-C, Cmd-X, Cmd-V, Cmd-A, Cmd-Z, and Cmd-Shift-Z.
- Option-Left/Right, Shift-Option-Left/Right, and Option-Delete.
- Single, double, and triple click; word drag; paragraph drag; pointer cancel.
- Right-click inside and outside an expanded selection; keyboard traversal;
  Escape dismissal; stale menu actions after a block switch.
- The injected spelling fixture, suggestion replacement, and one-step undo.
- Caret blink/reset, inactive selection tint, and Reduce Motion's static caret.
- Rapid block switching while clipboard or spelling work is pending.
- The macOS Edit menu and AppKit selector delivery, confirming no duplicate
  mutation after a physical shortcut.

Record OS, Flutter version, hardware, result, and any deviation here before
calling HOM-19 platform-certified.
