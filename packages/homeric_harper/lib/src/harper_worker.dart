import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'harper_bindings.dart';

/// Runs Harper on one background isolate, one paragraph at a time, so the
/// UI thread never waits on a check and a long Sheet queues its paragraphs
/// rather than starting an isolate for each.
final class HarperWorker {
  HarperWorker._(this._requests, this._replies, this._isolate);

  static Future<HarperWorker>? _starting;

  /// The one worker, started on first use.
  static Future<HarperWorker> shared() => _starting ??= _start().then(
    (worker) => worker,
    onError: (Object e) {
      _starting = null;
      throw e;
    },
  );

  static Future<HarperWorker> _start() async {
    final replies = ReceivePort();
    final isolate = await Isolate.spawn(
      _main,
      replies.sendPort,
      debugName: 'homeric_harper',
      errorsAreFatal: false,
    );
    final stream = replies.asBroadcastStream();
    final requests = await stream.first as SendPort;
    final worker = HarperWorker._(requests, stream, isolate);
    worker._listen();
    return worker;
  }

  final SendPort _requests;
  final Stream<Object?> _replies;
  final Isolate _isolate;
  final _pending = <int, Completer<String?>>{};
  var _next = 0;

  void _listen() {
    _replies.listen((message) {
      if (message case (final int id, final String? json)) {
        _pending.remove(id)?.complete(json);
      }
    });
  }

  /// Harper's findings for [text] as JSON, or null when the check failed.
  Future<String?> check(String text, int dialect) {
    final id = _next++;
    final completer = Completer<String?>();
    _pending[id] = completer;
    _requests.send((id, text, dialect));
    return completer.future;
  }

  /// Loads the dictionary ahead of the first check.
  void warmUp(int dialect) => _requests.send(('warm', dialect));

  void dispose() {
    _isolate.kill(priority: Isolate.immediate);
    for (final pending in _pending.values) {
      pending.complete(null);
    }
    _pending.clear();
    _starting = null;
  }

  static void _main(SendPort replies) {
    final requests = ReceivePort();
    replies.send(requests.sendPort);
    requests.listen((message) {
      switch (message) {
        case ('warm', final int dialect):
          try {
            harperWarmUp(dialect);
          } on Object {
            // The first check reports it.
          }
        case (final int id, final String text, final int dialect):
          // A native call that throws (a missing library or symbol) still
          // answers, so the caller falls back instead of waiting forever.
          String? json;
          try {
            json = _check(text, dialect);
          } on Object {
            json = null;
          }
          replies.send((id, json));
      }
    });
  }

  static String? _check(String text, int dialect) {
    final bytes = utf8.encode(text);
    final native = harperAlloc(bytes.length);
    if (native == nullptr) return null;
    try {
      native.asTypedList(bytes.length).setAll(0, bytes);
      final result = harperCheck(native, bytes.length, dialect);
      if (result == nullptr) return null;
      try {
        return _readCString(result);
      } finally {
        harperFree(result);
      }
    } finally {
      harperDealloc(native, bytes.length);
    }
  }
}

String _readCString(Pointer<Char> pointer) {
  final bytes = pointer.cast<Uint8>();
  var length = 0;
  while (bytes[length] != 0) {
    length++;
  }
  return utf8.decode(Uint8List.fromList(bytes.asTypedList(length)));
}
