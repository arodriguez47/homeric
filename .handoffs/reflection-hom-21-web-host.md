# HOM-21 web-host reflection

## What changed

- Added the standard minimal Flutter web host to the package playground and
  registered it in Flutter migration metadata.
- Added the Cupertino icon font dependency used by adaptive editor controls,
  removing the release-web missing-font warning.
- Added a source guard for the host, bootstrap, base URL, migration ownership,
  and icon dependency.
- Refreshed the IME and desktop evidence ledgers against the current tree.

## Assumptions

- The playground is an internal acceptance app, so a minimal unbranded web
  shell is preferable to product-specific PWA assets.
- Web remains best effort under HOM-21; the host does not change Flutter's CJK
  limitation or authorize a Nexus platform-default change.

## Failure modes

- A portable runner exists in Dart but no browser host can compile it.
- A fixed base URL breaks hosted acceptance builds.
- Flutter bootstrap is removed and the page becomes blank.
- Adaptive toolbar code references a font that is absent from the artifact.
- A successful build is mislabeled as native/browser input certification.

## Missing tests and follow-ups

- The managed browser rejected localhost while its admin policy was
  unavailable, so no browser-input result is claimed.
- Physical iOS/Android touch and IME matrices remain unrun.
- Native macOS physical actions remain unrun because the Mac was locked after
  the runner reached its ready state.
- Independent PR review remains required; this reflection is not self-approval.
