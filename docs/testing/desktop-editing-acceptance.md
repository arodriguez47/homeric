# Desktop editing acceptance

This ledger records the evidence for
[HOM-19](https://linear.app/xana-studios/issue/HOM-19). Automated tests and a
release build support the implementation, but they do not replace interaction
with the real macOS text system.

## Current status

As of 2026-08-21, the automated desktop-editing matrix is green and the macOS
playground compiles in release mode. The HOM-19 source and focused playground
matrix also pass under an isolated Flutter 3.24.5 SDK. Manual AppKit acceptance
remains open, and the repository's protected compatibility runner needs repair
before it can serve as the canonical one-command gate. HOM-19 therefore has
strong implementation and SDK-compatibility evidence, but is not yet
platform-certified.

| Gate | Result | Evidence boundary |
|---|---|---|
| Controller, clipboard, input-session, paragraph, geometry, and overlay tests | PASS | 197 tests passed locally. Covers canonical undo/redo, stale-safe clipboard work, selectors, word commands, multi-click and drag selection, adaptive menu behavior, injected spelling results, caret timing, inactive selection, and release-safe geometry readiness. |
| Playground integration | PASS | 32 tests passed locally. Covers public controller history, clipboard feedback, injected spelling, input, block switching, presentation rebuilds, and one undo pipeline. |
| Complete Homeric package suite | PASS (current tree, 2026-08-22) | 745 tests passed with one intentional skip after the latest HOM-20 touch-lifecycle and HOM-21 input-action/adapter-trace changes. The mounted framework adapter trace remains a separate host-process gate. |
| Complete playground unit/widget suite | PASS | 38 tests passed on the same tree, including the package-owned web-host guard. |
| Homeric package analysis | PASS | Full package `flutter analyze` reported no issues after the HOM-21 geometry-capability change. |
| Playground analysis | PASS | Full playground `flutter analyze` reported no issues after the HOM-21 geometry-capability change. |
| macOS release build | PASS | `flutter build macos --release` produced `build/macos/Build/Products/Release/homeric_playground.app` (43.3 MB). Compilation proves release-safe code paths; it does not prove AppKit delivery or interaction. |
| Flutter 3.24 compatibility | PASS (corrected isolated matrix) / RUNNER BROKEN | Flutter 3.24.5 package analysis passed, 158 focused package tests passed, playground analysis passed, and 32 playground tests passed from an isolated copy. One test-only `DragUpdateDetails(kind:)` call was removed because that named parameter postdates Flutter 3.24; the originating touch kind remains supplied by `DragStartDetails`. The protected `tool/verify_flutter_3_24.sh` is currently stale because it references removed `test/render/paragraph_geometry_test.dart` instead of `test/render/geometry_test.dart`; its remaining selected tests reached 121 passes before that load error. No protected runner file was changed. |
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
