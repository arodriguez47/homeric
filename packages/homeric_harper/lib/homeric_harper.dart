/// On-device English grammar checking for Homeric editors, through Harper
/// (https://writewithharper.com, Apache 2.0).
///
/// Add a [HarperProofingSource] to a `HomericProofingSuite`. Building an
/// app with this package needs rustup on the building machine; the pinned
/// toolchain downloads on first build. The web build finds nothing.
library;

export 'src/harper_source_web.dart'
    if (dart.library.ffi) 'src/harper_source_io.dart';
