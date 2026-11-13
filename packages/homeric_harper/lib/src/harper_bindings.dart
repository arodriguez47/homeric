// The C entry points of rust/src/lib.rs, bound through the code asset
// that hook/build.dart builds.
import 'dart:ffi';

@Native<Pointer<Char> Function(Pointer<Uint8>, UintPtr, Uint8)>(
  symbol: 'homeric_harper_check',
)
external Pointer<Char> harperCheck(
  Pointer<Uint8> text,
  int length,
  int dialect,
);

@Native<Void Function(Uint8)>(symbol: 'homeric_harper_warm_up')
external void harperWarmUp(int dialect);

@Native<Void Function(Pointer<Char>)>(symbol: 'homeric_harper_free')
external void harperFree(Pointer<Char> json);

@Native<Pointer<Uint8> Function(UintPtr)>(symbol: 'homeric_harper_alloc')
external Pointer<Uint8> harperAlloc(int length);

@Native<Void Function(Pointer<Uint8>, UintPtr)>(
  symbol: 'homeric_harper_dealloc',
)
external void harperDealloc(Pointer<Uint8> bytes, int length);
