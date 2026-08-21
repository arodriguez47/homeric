# HOM-20 mobile host reflection

## What changed

- Added the standard Flutter iOS and Android application hosts to the existing
  playground without replacing its macOS host or application code.
- Updated Flutter migration metadata to retain all three configured native
  platforms.
- Recorded build-level evidence separately from physical-device certification
  in `docs/testing/mobile-touch-acceptance.md`.
- Ran the touch integration trace on a dedicated Android API 36 emulator and
  recorded that evidence separately from the unchanged physical-device gate.
- Corrected the integration harness to keep the live device's actual pixel
  ratio and initial surface metrics. The prior synthetic 900×700 override
  collapsed the document viewport on the emulator and created a false overlay
  failure even though endpoint geometry remained current.

## Assumptions

- `dev.homeric.homericPlayground` is the appropriate non-production identifier
  for the package-owned acceptance app; it matches the existing macOS host.
- Generated Flutter launch assets and runner projects are acceptable scaffolding
  for a test playground and are not product branding.

## Failure modes considered

- The platform generator initially replaced the migration platform list rather
  than extending it. The macOS entry was restored so later Flutter migrations
  do not treat the existing host as unmanaged.
- A successful mobile build can be mistaken for touch or IME certification.
  The acceptance ledger explicitly keeps both physical-device rows `Not run`.
- Generator-created README, sample widget test, and IDE files were removed or
  ignored so the change does not add unrelated template surface.
- A held test gesture is not a reliable owner witness on the device binding.
  The trace therefore uses the touch gesture to prove selection and handle
  presentation, then explicitly establishes one document drag capability for
  the rotation-revocation assertion. Package widget tests retain the detailed
  gesture-owner and magnifier lifecycle coverage.

## Verification

- `flutter build ios --release --no-codesign`: pass; 17.0 MB `Runner.app`.
- `flutter build apk --release`: pass; 49.7 MB release APK.
- `flutter test integration_test/touch_editing_test.dart`: pass on the local
  macOS host; mobile-only assertions remained inactive.
- `flutter test integration_test/touch_editing_test.dart -d emulator-5554`:
  pass on Android 16 / API 36, including touch selection, current endpoint
  geometry, visible start/end handles, and rotation cleanup.
- `flutter test test/editing/editable_document_test.dart test/editing/editable_paragraph_test.dart test/input/text_input_session_test.dart`:
  pass, 136 tests.
- Playground `flutter test`: pass, 37 tests.
- `flutter analyze`: no issues in the playground.

## Missing tests and follow-ups

- Run the documented integration and manual matrices on one physical iOS device
  and one physical Android device.
- Replace generated launcher assets only if the playground becomes a
  distributed product rather than an internal acceptance harness.
- Independent review of this scaffold/evidence slice remains pending; do not
  use this reflection as self-approval.
