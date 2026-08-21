# Mobile touch acceptance

HOM-20 adds the mobile touch-selection capability, but capability, automated
coverage, and platform certification are separate claims. Widget and
integration tests support the device run; they never replace it.

## Current evidence

| Gate | Status | Evidence |
|---|---|---|
| Flutter widget tests | Pass | Android/iOS controls, long press, word drag, handle crossing, magnifier, floating cursor, stale epochs, lifecycle cancellation, and rotation-safe ownership |
| Playground integration trace | Pass on macOS and the named mobile simulators | The device harness builds and proves one lazy document owner, one shared controller/input session, and owner identity across rotation; platform touch assertions activate only on iOS/Android |
| iOS release host build | Pass | On 2026-08-21, `flutter build ios --release --no-codesign` built `Runner.app` (17.0 MB) with Flutter 3.44.4 and Xcode 26.6. This proves the device harness has a compilable iOS host, not touch behavior on hardware. |
| Android release host build | Pass | On 2026-08-21, `flutter build apk --release` built `app-release.apk` (49.7 MB) against Android SDK 36. This proves the device harness has a compilable Android host, not touch behavior on hardware. |
| iPhone 17 Pro Simulator (iOS 26.5) | Pass | On 2026-08-21, `flutter test integration_test/touch_editing_test.dart -d FFC3D351-102C-4890-9810-4E710C3B76B5` passed. The mounted iOS host kept the focused long-press selection collapsed, exposed exactly one derived caret handle, rejected pointer movement as a second canonical selection route while floating-cursor callbacks owned movement, retained one controller/input owner, and revoked a document drag capability across synthetic rotation. This is Simulator integration evidence, not physical-device or manual-touch certification. |
| Android API 36 emulator | Pass | On 2026-08-21, `flutter test integration_test/touch_editing_test.dart -d emulator-5554` passed on the `Homeric_API_36` Google APIs arm64 AVD. The live Android host expanded selection from an injected touch gesture, exposed current endpoint geometry and both handles, retained one controller/input owner, and revoked an explicitly active document drag capability across a synthetic surface rotation. This is emulator integration evidence, not a physical-device or manual-touch certification. |
| Flutter 3.24 compatibility | Pass | An isolated Flutter 3.24.5 (`dec2ee5c1f`) run analyzed the package and playground, passed the 154-test editor/input/geometry matrix, and passed all 32 playground view-model tests using the current `geometry_test.dart` suite. |
| Real iOS device | Not run | Required before iOS certification |
| Real Android device | Not run | Required before Android certification |

The local integration trace does not simulate a mobile platform when it runs
on a desktop host. Its report records `physical_mobile_platform: false`, and
the long-press/handle assertions run only on iOS or Android.

The playground now includes standard `dev.homeric.homericPlayground` iOS and
Android application hosts. Before 2026-08-21 it contained only the macOS host,
so the connected-device commands below could not launch on either mobile
platform even though the integration test existed. Both release hosts now
compile. No physical iOS or Android device was connected during this run, so
the certification rows remain `Not run`. The iPhone 17 Pro Simulator and a
dedicated Android API 36 emulator passed the platform-specific integration
traces recorded above.

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
