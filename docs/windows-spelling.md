# Spelling on Windows

Flutter has no spell check service on Windows, so Homeric asks Windows' own
checker, `ISpellChecker` (`spellcheck.h`, Windows 8 and later), over the same
`homeric/spelling` method channel the Mac uses (see
[mac-spelling.md](mac-spelling.md)). The app answers it with one C++ file and
its header. The Dart side is the same class on both: `HomericSystemSpelling`,
also known by its first name, `HomericMacSpelling`.

## What the writer gets

- Red squiggles under misspelled words, in the writer's Windows language.
  The word still being typed waits until the writer moves on.
- In the right-click menu, under the format bar: the guesses (bold), then
  **Learn Spelling** and **Ignore Spelling**, or **No Guesses Found**.
  Learn adds the word to the user's Windows dictionary for that language,
  which other apps share; Ignore lasts until the app quits. Every paragraph
  checks again at once, and again when the dictionary changes in another
  app.
- A word on Windows' autocorrect list (`teh`) is squiggled with its
  replacement as the first guess.
- Code, web addresses, `#tags`, `@names` and `[[links]]` keep what was typed.

Typing is left alone: no autocorrect and no text replacement. Windows keeps
its "Autocorrect misspelled words" switch in registry values that are not
documented and on some versions mean only the touch keyboard, and it has no
text replacement list, so the handler's `settings` answers `autocorrect` and
`replacement` false and `replacements` empty. Turn on autocorrect in the
handler only once a setting can be read reliably.

## Language

One checker, in the first language Windows can check from this list: the
writer's regional format (Settings › Time & language › Region, `en-GB`), the
language it narrows (`en`), the Windows display languages in order, US
English, then any language Windows has a dictionary for. Windows installs a
dictionary with each language pack. The language is chosen when the app
starts.

## Host setup

1. Copy [`windows/homeric_spelling.h`](windows/homeric_spelling.h) and
   [`windows/homeric_spelling.cpp`](windows/homeric_spelling.cpp) into the
   app's `windows/runner/`, and add the `.cpp` to `add_executable` in
   `windows/runner/CMakeLists.txt`. It uses COM from `ole32.lib`, which
   CMake links by default; to say so:

   ```cmake
   target_link_libraries(${BINARY_NAME} PRIVATE "ole32.lib")
   ```

2. Register it in `FlutterWindow::OnCreate` (`flutter_window.cpp`), after
   `RegisterPlugins`:

   ```cpp
   #include "homeric_spelling.h"
   ...
   RegisterPlugins(flutter_controller_->engine());
   RegisterHomericSpelling(flutter_controller_->engine());
   ```

   It lives until the engine shuts down. The runner's `main.cpp` must have
   called `CoInitializeEx` first, as Flutter's template does.

3. Pass the system checker to the editor. `homericSystemSpellChecker` picks
   `HomericSystemSpelling` on Windows, as on macOS:

   ```dart
   spellCheckProvider: homericSystemSpellChecker(
     locale: () => WidgetsBinding.instance.platformDispatcher.locale,
   ),
   ```

   `HomericSystemCorrections` can be installed on Windows too
   (`HomericSystemSpelling.forPlatform` is not null there); with both
   settings off it changes nothing as the writer types.

An app without the C++ files gets no squiggles; nothing else changes.

## The channel

Offsets are UTF-16 code units on both sides: Dart's string indices and
Windows' `wchar_t` indices.

| Call | Arguments | Answer |
| --- | --- | --- |
| `check` | `{text}` | `[{start, end, guesses}]`, up to 6 guesses each |
| `correct` | `{text, start, end}` | the autocorrect list's replacement for that word, or null |
| `learn` | `{word}` | null; `ISpellChecker::Add` |
| `ignore` | `{word}` | null; `ISpellChecker::Ignore` |
| `settings` | none | `{autocorrect: false, replacement: false, replacements: {}}` |

The handler calls `settingsChanged` on Flutter when `SpellCheckerChanged`
fires. That event can come on any thread, so the handler passes it through
a message-only window to the platform thread.

`check` uses `ISpellChecker::Check`. Each `ISpellingError` gives the word's
start and length; `CORRECTIVE_ACTION_GET_SUGGESTIONS` takes its guesses from
`Suggest`, `CORRECTIVE_ACTION_REPLACE` puts the replacement first.
`CORRECTIVE_ACTION_DELETE` (a repeated word, "the the") is left out, as the
Mac checks spelling only.

## Not possible yet

- More than one language at a time: the Mac detects the language per
  paragraph; Windows checks in one.
- Grammar: `ISpellChecker` checks spelling only.
- Windows' own context menu with Add to dictionary: Homeric draws its own
  menu, with the Mac's words.
