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
#include <vector>

// `homeric/spelling`, heard by Homeric's `HomericSystemSpelling`
// (`HomericMacSpelling`): Windows' own spell checker for the editor, which
// Flutter has no service for on Windows. The same calls the Mac's
// HomericSpelling.swift answers, with the same shapes.
//
// - `check` {text} answers each misspelled word as {start, end, guesses},
//   in UTF-16 offsets (Dart's). A word is misspelled only when it is wrong
//   in every one of the writer's Windows languages, so a bilingual writer
//   sees no squiggles under either language.
// - `correct` {text, start, end} answers what Windows' autocorrect list
//   makes of that word, or null.
// - `learn` / `ignore` {word}: Add to dictionary (for good, in the user's
//   dictionary, shared with other apps) and Ignore all (until the app
//   quits), in every language.
// - `settings` answers {autocorrect, replacement, replacements}. Windows
//   keeps no setting an app can read for autocorrect with a hardware
//   keyboard, and no text replacement list, so all three are off or empty:
//   the writer gets squiggles and guesses, and typing is left alone.
//
// Calls `settingsChanged` on Flutter when the checker changes under the app
// (a word learned in another app, a dictionary edited), so every paragraph
// checks again. Its own Learn and Ignore are not passed on: the editor
// checks again after those by itself.
//
// The checkers are made on the first call that needs them, not at startup,
// as loading the dictionaries takes time the first frame shouldn't wait for.
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
  // One language's checker and its change event.
  struct Checker {
    Microsoft::WRL::ComPtr<ISpellChecker> checker;
    DWORD changed_cookie = 0;
    bool listening = false;
  };

  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  // Makes the checkers the first time, and says whether there are any.
  bool EnsureCheckers();

  flutter::EncodableList Misspellings(const std::wstring& text);
  std::optional<std::wstring> Correction(const std::wstring& word);
  flutter::EncodableList Guesses(const std::wstring& word);

  // Tells Flutter, on the platform thread, that the checker changed.
  void TellSettingsChanged();
  static LRESULT CALLBACK WindowProc(HWND window, UINT message, WPARAM wparam,
                                     LPARAM lparam);

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  // The writer's languages, best first. The first gives the guesses.
  std::vector<Checker> checkers_;
  bool tried_checkers_ = false;
  // A message-only window: the checker's change events can come on any
  // thread, and Flutter's channel takes calls only on the platform thread.
  HWND window_ = nullptr;
  // Change events until this tick come from the app's own Learn or Ignore.
  ULONGLONG own_change_until_ = 0;
};

// Answers `homeric/spelling` for [engine] until the engine shuts down. Call
// once, after RegisterPlugins.
void RegisterHomericSpelling(flutter::FlutterEngine* engine);

#endif  // HOMERIC_SPELLING_H_
