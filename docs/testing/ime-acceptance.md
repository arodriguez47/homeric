# Platform IME acceptance

HOM-21 tracks platform input-method behavior separately from editor logic.
Widget tests prove Homeric's epoch, composition, and geometry contracts; only
recorded runs on the named platform certify the platform integration.

## Current evidence

| Gate | Status | Evidence |
|---|---|---|
| Flutter widget tests | Pass | Delta input, composing-range grouping, stale epochs, focus transfer, connection loss, selector ordering, floating cursor, iOS autocorrection prompt painting, and attachment-bound caret/composing geometry |
| Mounted Dart/framework adapter trace | Pass in macOS, iPhone 17 Pro Simulator (iOS 26.5), and Android API 36 emulator test processes, 2026-08-21 | The playground mounted a focused platform input client and injected framework callbacks through Flutter's test messenger using debug client id `-1`. Homeric committed a composed Unicode replacement as one undo unit, committed visible composition once on connection loss, reattached with a different focused epoch capability, rejected the retired callback without changing canonical state, and routed `TextInputAction.newline` through one split/retarget/undo unit that accepted the next delta. This does not exercise native host delivery or client-id routing. |
| Flutter 3.24 compatibility | Pass | The affected input and editable-paragraph suites pass on isolated Flutter 3.24.5; scoped analysis is clean |
| macOS direct playground | Unverified historical note, 2026-08-20 | A prior interactive pass reported platform typing, dead-key composition, grapheme deletion, selection, and caret presentation, but no complete run record or artifact was retained. It is not certification evidence. |
| Windows desktop | Not run | Required before Windows certification |
| Linux desktop | Not run | Required before Linux certification |
| Physical iOS | Not run | Required before iOS certification |
| Physical Android | Not run | Required before Android certification |
| Web | Best effort only | Latin-script behavior is intended but currently unverified in this ledger; CJK remains blocked by [flutter/flutter#120613](https://github.com/flutter/flutter/issues/120613) |

The iOS autocorrection callback is now epoch-bound: a current request paints
the canonical replacement range with the selection color, while edits, blur,
focus transfer, platform close, or host replacement remove the transient
paint. This is automated framework evidence, not a physical iOS result.

Platform caret and composing rectangles now carry an opaque geometry lease
that rotates when the attached block or host capability changes. Automated
tests prove that a recycled prior row and a replaced same-block host cannot
overwrite the current IME candidate position; an ownerless attachment cannot
publish ambiguous geometry at all. This closes the in-process race, but actual
candidate-window placement still requires the named platform runs below.

The first iOS Simulator run exposed a real attachment failure:
`TextInputAction.none` is unsupported on iOS. Homeric now uses the supported
`TextInputAction.newline` default on every platform; its existing epoch-bound
newline action still owns structural paragraph breaks. The corrected trace
passes on iOS, Android, and macOS.

The mounted adapter trace is deliberately synthetic: Dart injects framework-
shaped delta messages into Flutter's test messenger with debug client id `-1`.
That path bypasses active-client id validation and does not originate in the
native host or engine. It proves the mounted Homeric/Flutter adapter's
composition, history, connection-loss, and retired-callback behavior in each
test process; it does not prove native delivery, client-id routing, dead keys,
Gboard, Pinyin, candidate windows, or other platform UI. Flutter's test tool
currently rejects web devices for `integration_test`, so the same trace could
not be run in Chrome.

## Repeatable automated trace

From `packages/homeric/examples/playground`:

```bash
flutter test integration_test/ime_editing_test.dart -d macos
flutter test integration_test/ime_editing_test.dart -d <ios-simulator-id>
flutter test integration_test/ime_editing_test.dart -d <android-device-id>
```

The trace reports `synthetic_framework_adapter: true` so its result cannot be
mistaken for physical keyboard or IME certification.

## Native macOS acceptance runner

From `packages/homeric/examples/playground`, launch the actual profile app:

```bash
flutter run -d macos --profile -t lib/native_ime_acceptance.dart
```

The runner opens one focused paragraph over the normal Homeric controller and
`TextInputConnection`. Follow the five on-screen steps: type `Z`, undo, redo,
enter `é` with the Option-E dead-key sequence, and undo it. Each accepted stage
prints `HOMERIC_NATIVE_IME_PASS`; a complete sequence ends with
`HOMERIC_NATIVE_IME_COMPLETE result=pass`. The accompanying
`HOMERIC_NATIVE_IME_STATE` JSON records canonical text, directional selection,
composition, history availability, active block, input owner, attachment, and
revision so the run can be retained as an artifact rather than a recollection.

This entrypoint uses no test messenger or debug client id. It is suitable for a
direct macOS record, but launching it alone is not a pass: retain the complete
terminal output, record the named hardware/OS/Flutter/build/input method, and
perform the candidate-geometry and VoiceOver checks separately. Automated Mac
UI capture in the current environment sees the Flutter surface as black and
exposes only the window container, so it cannot supply those visual or
accessibility results.

## Manual platform record

Create one record per tested OS/device. Include hardware, OS version, Flutter
revision, build mode, keyboard/input method, date, and a path to evidence. Use
`pass`, `fail`, or `not run` for certifiable flows. Use `blocked`, `best effort`,
or `N/A` only when the row names the platform limitation that prevents a normal
certification result.

| Flow | macOS | Windows | Linux | iOS | Android | Web |
|---|---|---|---|---|---|---|
| Plain Latin typing and replacement | Not run | Not run | Not run | Not run | Not run | Best effort |
| Marked/composing text commits as one undo unit | Not run | Not run | Not run | Not run | Not run | Not run |
| Dead keys and diacritics | Not run | Not run | Not run | Not run | Not run | Not run |
| Emoji and multi-code-point graphemes | Not run | Not run | Not run | Not run | Not run | Not run |
| CJK composition and candidate selection | Not run | Not run | Not run | Not run | Not run | Blocked |
| Autocorrect replacement prompt aligns to text | N/A | N/A | N/A | Not run | N/A | N/A |
| Candidate/composing geometry follows wrapping and scroll | Not run | Not run | Not run | Not run | Not run | Not run |
| Focus change commits or cancels composition once | Not run | Not run | Not run | Not run | Not run | Not run |
| Platform connection loss leaves no stale writer | Not run | Not run | Not run | Not run | Not run | Not run |
| Rapid switching leaves one active input epoch | Not run | Not run | Not run | Not run | Not run | Not run |

“Partial” records only the named sub-flow. It does not certify the whole row or
platform. Keep the compatibility editor available for any Nexus platform that
has not completed its applicable matrix.
