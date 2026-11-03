import Cocoa
import FlutterMacOS

/// `homeric/spelling`, heard by Homeric's `HomericMacSpelling`: macOS's own
/// spell checker for the editor, which Flutter has no service for on macOS.
///
/// - `check` {text} answers each misspelled word as {start, end, guesses},
///   in UTF-16 offsets (Dart's), in whatever languages macOS detects.
/// - `correct` {text, start, end} answers what autocorrect makes of that
///   word, or nil.
/// - `learn` / `ignore` {word}: Learn Spelling (for good, in the user's
///   dictionary) and Ignore Spelling (until the app quits).
/// - `settings` answers {autocorrect, replacement, replacements}: the
///   Keyboard settings "Correct spelling automatically" and text
///   replacement, and the user's replacement list.
///
/// Calls `settingsChanged` on Flutter when either setting changes.
final class HomericSpelling: NSObject, FlutterPlugin {
  private let channel: FlutterMethodChannel
  private let checker = NSSpellChecker.shared
  private let documentTag = NSSpellChecker.uniqueSpellDocumentTag()
  private var observers: [NSObjectProtocol] = []

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "homeric/spelling", binaryMessenger: registrar.messenger)
    let instance = HomericSpelling(channel: channel)
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  private init(channel: FlutterMethodChannel) {
    self.channel = channel
    super.init()
    let tell: (Notification) -> Void = { [weak self] _ in
      self?.channel.invokeMethod("settingsChanged", arguments: nil)
    }
    for name in [
      NSSpellChecker.didChangeAutomaticSpellingCorrectionNotification,
      NSSpellChecker.didChangeAutomaticTextReplacementNotification,
    ] {
      observers.append(
        NotificationCenter.default.addObserver(
          forName: name, object: nil, queue: .main, using: tell))
    }
  }

  deinit {
    observers.forEach(NotificationCenter.default.removeObserver)
    NSSpellChecker.shared.closeSpellDocument(withTag: documentTag)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any]
    switch call.method {
    case "check":
      guard let text = args?["text"] as? String else { return result([]) }
      result(misspellings(in: text))
    case "correct":
      guard let text = args?["text"] as? String,
        let start = args?["start"] as? Int,
        let end = args?["end"] as? Int,
        start >= 0, end > start, end <= (text as NSString).length
      else { return result(nil) }
      result(correction(in: text, range: NSRange(location: start, length: end - start)))
    case "learn":
      if let word = args?["word"] as? String, !word.isEmpty { checker.learnWord(word) }
      result(nil)
    case "ignore":
      if let word = args?["word"] as? String, !word.isEmpty {
        checker.ignoreWord(word, inSpellDocumentWithTag: documentTag)
      }
      result(nil)
    case "settings":
      result([
        "autocorrect": NSSpellChecker.isAutomaticSpellingCorrectionEnabled,
        "replacement": NSSpellChecker.isAutomaticTextReplacementEnabled,
        "replacements": checker.userReplacementsDictionary,
      ])
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func misspellings(in text: String) -> [[String: Any]] {
    let length = (text as NSString).length
    guard length > 0 else { return [] }
    var orthography: NSOrthography?
    var wordCount = 0
    let found = checker.check(
      text, range: NSRange(location: 0, length: length),
      types: NSTextCheckingResult.CheckingType.spelling.rawValue,
      options: nil, inSpellDocumentWithTag: documentTag,
      orthography: &orthography, wordCount: &wordCount)
    return found.compactMap { match in
      guard match.resultType == .spelling, match.range.length > 0 else { return nil }
      let guesses =
        checker.guesses(
          forWordRange: match.range, in: text,
          language: orthography?.dominantLanguage ?? checker.language(),
          inSpellDocumentWithTag: documentTag) ?? []
      return [
        "start": match.range.location,
        "end": match.range.location + match.range.length,
        "guesses": Array(guesses.prefix(6)),
      ]
    }
  }

  /// Autocorrect's choice for the word at [range], as AppKit text views
  /// make it: a correction result, else the spell checker's correction.
  private func correction(in text: String, range: NSRange) -> String? {
    var orthography: NSOrthography?
    var wordCount = 0
    let types =
      NSTextCheckingResult.CheckingType.spelling.rawValue
      | NSTextCheckingResult.CheckingType.correction.rawValue
    let found = checker.check(
      text, range: range, types: types, options: nil,
      inSpellDocumentWithTag: documentTag,
      orthography: &orthography, wordCount: &wordCount)
    if let fix = found.first(where: {
      $0.resultType == .correction && NSEqualRanges($0.range, range)
    })?.replacementString {
      return fix
    }
    guard found.contains(where: { $0.resultType == .spelling }) else { return nil }
    return checker.correction(
      forWordRange: range, in: text,
      language: orthography?.dominantLanguage ?? checker.language(),
      inSpellDocumentWithTag: documentTag)
  }
}
