#ifndef HOMERIC_SPELLING_H_
#define HOMERIC_SPELLING_H_

// windows.h first: spellcheck.h needs its types.
#include <windows.h>

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/flutter_engine.h>
#include <flutter/method_channel.h>
#include <spellcheck.h>
#include <wrl/client.h>

#include <memory>
#include <optional>
#include <string>

// `homeric/spelling`, heard by Homeric's `HomericSystemSpelling`
// (`HomericMacSpelling`): Windows' own spell checker for the editor, which
// Flutter has no service for on Windows. The same calls the Mac's
// HomericSpelling.swift answers, with the same shapes.
//
// - `check` {text} answers each misspelled word as {start, end, guesses},
//   in UTF-16 offsets (Dart's), in the writer's Windows language.
// - `correct` {text, start, end} answers what Windows' autocorrect list
//   makes of that word, or null.
// - `learn` / `ignore` {word}: Learn Spelling (for good, in the user's
//   dictionary, shared with other apps) and Ignore Spelling (until the app
//   quits).
// - `settings` answers {autocorrect, replacement, replacements}. Windows
//   keeps no setting an app can read for autocorrect with a hardware
//   keyboard, and no text replacement list, so all three are off or empty:
//   the writer gets squiggles and guesses, and typing is left alone.
//
// Calls `settingsChanged` on Flutter when the checker changes under the app
// (a word learned in another app, a dictionary edited), so every paragraph
// checks again.
//
// Uses ISpellCheckerFactory from spellcheck.h (Windows 8 and later). On a
// Windows without it every call answers as if nothing is misspelled.
class HomericSpelling {
 public:
  explicit HomericSpelling(flutter::BinaryMessenger* messenger);
  ~HomericSpelling();

  HomericSpelling(const HomericSpelling&) = delete;
  HomericSpelling& operator=(const HomericSpelling&) = delete;

 private:
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  flutter::EncodableList Misspellings(const std::wstring& text);
  std::optional<std::wstring> Correction(const std::wstring& word);
  flutter::EncodableList Guesses(const std::wstring& word);

  // Tells Flutter, on the platform thread, that the checker changed.
  void TellSettingsChanged();
  static LRESULT CALLBACK WindowProc(HWND window, UINT message, WPARAM wparam,
                                     LPARAM lparam);

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  Microsoft::WRL::ComPtr<ISpellChecker> checker_;
  // A message-only window: the checker's change events can come on any
  // thread, and Flutter's channel takes calls only on the platform thread.
  HWND window_ = nullptr;
  DWORD changed_cookie_ = 0;
  bool listening_ = false;
};

// Answers `homeric/spelling` for [engine] until the engine shuts down. Call
// once, after RegisterPlugins.
void RegisterHomericSpelling(flutter::FlutterEngine* engine);

#endif  // HOMERIC_SPELLING_H_
