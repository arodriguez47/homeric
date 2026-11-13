# homeric_harper

On-device English grammar checking for Homeric editors, through
[Harper](https://github.com/Automattic/harper) (Apache 2.0).

```dart
final suite = HomericProofingSuite(sources: [
  HarperProofingSource(),
  HomericPhraseRules(myRules),
]);
// HomericEditableParagraph(proofreader: suite, ...)
```

- `rust/` wraps `harper-core` in four C functions; `hook/build.dart` builds
  it for the target platform with `native_toolchain_rust`.
- Checks run on one background isolate, one paragraph at a time. Ranges come
  back as UTF-16 offsets.
- Spelling stays with the platform checker: Harper's `SpellCheck` and
  `SentenceCapitalization` rules are off.

## Building

Install [rustup](https://rustup.rs). The first build downloads the toolchain
pinned in `rust/rust-toolchain.toml` with every target the apps ship to, then
compiles Harper (a few minutes per platform; cached after that). Android also
needs the NDK that Flutter already uses. The web build gets a stub that finds
nothing.

## Testing

`cd rust && cargo test` checks the Rust side. `flutter test` builds the
library for the host and runs the Dart tests through it.
