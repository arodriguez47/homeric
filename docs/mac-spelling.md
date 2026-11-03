# Spelling on the Mac

Flutter has no spell check service on macOS (`nativeSpellCheckServiceDefined`
is false there), so Homeric asks macOS's own checker, `NSSpellChecker`, over
the `homeric/spelling` method channel. The app answers it with one Swift file.

## What the writer gets

- Red squiggles under misspelled words, in whatever languages macOS detects.
  The word still being typed waits until the writer moves on.
- In the right-click menu, under the format bar: the guesses (bold), then
  **Learn Spelling** and **Ignore Spelling**, or **No Guesses Found**.
  Learn adds the word to the user's dictionary for every app; Ignore lasts
  until the app quits. Every paragraph checks again at once.
- Autocorrect as the writer types, when System Settings › Keyboard › Text
  Input › "Correct spelling automatically" is on. A space, punctuation or
  Return ends a word; the correction is its own undo step (⌘Z puts it back).
- Text replacement from the same settings pane (`omw` → `On my way!`). One
  undo, or Backspace straight after, puts the shortcut back.
- Code, web addresses, `#tags`, `@names` and `[[links]]` keep what was typed.

## Host setup

1. Copy [`macos/HomericSpelling.swift`](macos/HomericSpelling.swift) into the
   app's `macos/Runner/`, add it to the Runner target, and register it in
   `MainFlutterWindow.awakeFromNib` after `RegisterGeneratedPlugins`:

   ```swift
   HomericSpelling.register(with: flutterViewController.registrar(forPlugin: "HomericSpelling"))
   ```

2. Pass the system checker to the editor. `homericSystemSpellChecker` picks
   Flutter's service on iOS and Android, `HomericMacSpelling` on macOS, and
   null on Windows, Linux and the web:

   ```dart
   spellCheckProvider: homericSystemSpellChecker(
     locale: () => WidgetsBinding.instance.platformDispatcher.locale,
   ),
   ```

3. For autocorrect and text replacement, install the writing feature on the
   Mac:

   ```dart
   if (HomericMacSpelling.forPlatform case final mac?) {
     HomericSystemCorrections(corrections: mac).installOn(controller);
   }
   ```

An app without the Swift file gets no squiggles and no corrections; nothing
else changes.

## Not possible in Flutter 3.47

- macOS's own inline predictive text (the grey completion after the caret)
  and the autocorrect bubble: AppKit draws those only in its own text views.
- The native Mac context menu with Spelling and Grammar, Substitutions and
  Speech submenus: Homeric draws its own menu.
- Grammar squiggles: `NSSpellChecker` can check grammar; Homeric doesn't ask
  yet.
