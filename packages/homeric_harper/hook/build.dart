import 'package:hooks/hooks.dart';
import 'package:native_toolchain_rust/native_toolchain_rust.dart';

/// Builds Harper's grammar checker (rust/) into the app for the platform
/// being built. Needs rustup on the building machine; it downloads the
/// pinned toolchain in rust/rust-toolchain.toml on first use.
void main(List<String> args) async {
  await build(args, (input, output) async {
    await const RustBuilder(
      assetName: 'src/harper_bindings.dart',
    ).run(input: input, output: output);
  });
}
