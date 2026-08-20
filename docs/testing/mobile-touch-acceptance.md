# Mobile touch acceptance

HOM-20 adds the mobile touch-selection capability, but capability, automated
coverage, and platform certification are separate claims. Widget and
integration tests support the device run; they never replace it.

## Current evidence

| Gate | Status | Evidence |
|---|---|---|
| Flutter widget tests | Pass | Android/iOS controls, long press, word drag, handle crossing, magnifier, floating cursor, stale epochs, lifecycle cancellation, and rotation-safe ownership |
| Playground integration trace | Pass locally on macOS | The device harness builds and proves one lazy document owner, one shared controller/input session, and owner identity across rotation; touch assertions activate only on iOS/Android |
| Flutter 3.24 compatibility | Not run | The package still declares Flutter 3.24; local evidence used Flutter 3.44.4 (`ad70ec4617`) only |
| Real iOS device | Not run | Required before iOS certification |
| Real Android device | Not run | Required before Android certification |

The local integration trace does not simulate a mobile platform when it runs
on a desktop host. Its report records `physical_mobile_platform: false`, and
the long-press/handle assertions run only on iOS or Android.

## Repeatable automated setup

From `packages/homeric/examples/playground`:

```bash
flutter test integration_test/touch_editing_test.dart
```

On a connected device, use the device identifier so the same fixture and
invariants run against the platform build:

```bash
flutter test integration_test/touch_editing_test.dart -d <device-id>
```

The fixture includes wrapped text, Arabic and Hebrew, an emoji family,
combining characters, a folded delimiter projection, an inline replacement
slot, an empty paragraph, and enough rows to recycle the viewport.

## Manual device record

Create one record per physical device. Record the hardware model, OS version,
Flutter revision, build mode, date, and a link or path to visual evidence.
Use only `pass`, `fail`, or `not run` for each line.

| Flow | iOS device | Android device |
|---|---|---|
| Long press selects the visible word | Not run | Not run |
| Dragging either handle crosses the other endpoint correctly | Not run | Not run |
| Word drag crosses wrapped, bidi, emoji, and combining text | Not run | Not run |
| Selection crosses blocks and autoscrolls at both viewport edges | Not run | Not run |
| Magnifier tracks the moving endpoint and disappears on release | Not run | Not run |
| Copy/cut/paste toolbar acts once on canonical text | Not run | Not run |
| Hidden folds and inline slots keep stable caret/handle sides | Not run | Not run |
| Empty paragraph accepts focus and insertion | Not run | Not run |
| Read-only transition preserves selection and revokes mutation | Not run | Not run |
| Keyboard dismissal/Back gesture leaves no stale input owner | Not run | Not run |
| Background/resume requires fresh focus and a fresh input epoch | Not run | Not run |
| Rotation preserves document/controller state | Not run | Not run |
| Rapid focus switching leaves one active caret/session | Not run | Not run |
| iOS floating cursor is transient and commits at most once | Not run | N/A |

Certification requires every applicable row to pass on one physical iOS
device and one physical Android device. Simulator/emulator evidence should be
recorded separately and must not change either device status.
