# Spelling on Windows

Flutter has no spell check service on Windows, so Homeric asks Windows' own
checker, `ISpellChecker` (`spellcheck.h`, Windows 8 and later), over the same
`homeric/spelling` method channel the Mac uses (see
[mac-spelling.md](mac-spelling.md)). The app answers it with one C++ file and
its header. The Dart side is the same class on both: `HomericSystemSpelling`,
also known by its first name, `HomericMacSpelling`.

## What the writer gets

- Red squiggles under misspelled words: words wrong in every one of the
  writer's Windows languages, so a bilingual writer sees none under either
  language. The word still being typed waits until the writer moves on.
- In the right-click menu, under the format bar: the guesses (bold), then
  **Add to dictionary** and **Ignore all**, or **No suggestions**, in
  Windows' own words (the Mac keeps its Learn Spelling, Ignore Spelling and
  No Guesses Found). Add to dictionary puts the word in the user's Windows
  dictionary for each of their languages, which other apps share; Ignore
  all lasts until the app quits. Every paragraph checks again at once, and
  again when the dictionary changes in another app.
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

One checker per language, for each language Windows can check from this
list, best first: the writer's Windows languages in order (Settings › Time &
language › Language, `en-GB`) and the language each narrows (`en`), then the
language of each keyboard layout (a language added for typing without its
display pack still counts), then the
regional format (Settings › Time & language › Region), then US English. The
regional format comes after the languages because many people set it only
for dates and money: an English writer with Spanish formats gets English,
and Spanish too only if Spanish is one of their languages. One checker
covers each language (`en-GB` and `en-US` are one), up to four. If none of
them can be checked, the handler uses any language Windows has a dictionary
for. Windows installs a dictionary with each language pack.

A word is squiggled only when every checker flags it, and its guesses come
from the first. The checkers are made on the first `check`, not at startup,
so loading the dictionaries never holds up the first frame; the languages
are those of that moment until the app restarts.

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
| `learn` | `{word}` | null; `ISpellChecker::Add` on every checker |
| `ignore` | `{word}` | null; `ISpellChecker::Ignore` on every checker |
| `settings` | none | `{autocorrect: false, replacement: false, replacements: {}}` |

The handler calls `settingsChanged` on Flutter when `SpellCheckerChanged`
fires. That event can come on any thread, so the handler passes it through
a message-only window to the platform thread, once however many checkers
fired. The events in the second after the app's own `learn` or `ignore` are
dropped, as the editor checks again after those by itself; the Mac doesn't
send them either.

`check` uses `ISpellChecker::Check` on every checker and keeps the words
they all flag (overlapping counts, as languages can split a word
differently). Each `ISpellingError` gives the word's start and length; `CORRECTIVE_ACTION_GET_SUGGESTIONS` takes its guesses from
`Suggest`, `CORRECTIVE_ACTION_REPLACE` puts the replacement first.
`CORRECTIVE_ACTION_DELETE` (a repeated word, "the the") is left out, as the
Mac checks spelling only.

## Not possible yet

- Picking up a language added in Settings while the app runs: the
  languages are read once, on the first check.
- Grammar: `ISpellChecker` checks spelling only.
- Windows' own context menu: Homeric draws its own menu, with Windows'
  words for the spelling rows.
