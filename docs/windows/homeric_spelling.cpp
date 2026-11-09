#include "homeric_spelling.h"

#include <flutter/standard_method_codec.h>
#include <flutter_windows.h>
#include <objbase.h>

#include <atomic>
#include <vector>

using Microsoft::WRL::ComPtr;

namespace {

// As many guesses as the Mac's handler gives.
constexpr size_t kMaxGuesses = 6;

// At most this many languages are checked, as each one checks every
// paragraph again.
constexpr size_t kMaxLanguages = 4;

// Posted to the message-only window when the checker changes.
constexpr UINT kChangedMessage = WM_APP + 0x51;

// How long after the app's own Learn or Ignore a change event is taken to
// be its echo. Windows sends one per checker, and not always at once.
constexpr ULONGLONG kOwnChangeEchoMs = 1000;

constexpr wchar_t kWindowClass[] = L"HOMERIC_SPELLING_WINDOW";

std::wstring Utf16FromUtf8(const std::string& text) {
  if (text.empty()) return std::wstring();
  const int length = ::MultiByteToWideChar(
      CP_UTF8, 0, text.data(), static_cast<int>(text.size()), nullptr, 0);
  if (length <= 0) return std::wstring();
  std::wstring wide(static_cast<size_t>(length), L'\0');
  ::MultiByteToWideChar(CP_UTF8, 0, text.data(),
                        static_cast<int>(text.size()), wide.data(), length);
  return wide;
}

std::string Utf8FromUtf16(const wchar_t* text, size_t size) {
  if (size == 0) return std::string();
  const int length =
      ::WideCharToMultiByte(CP_UTF8, 0, text, static_cast<int>(size), nullptr,
                            0, nullptr, nullptr);
  if (length <= 0) return std::string();
  std::string utf8(static_cast<size_t>(length), '\0');
  ::WideCharToMultiByte(CP_UTF8, 0, text, static_cast<int>(size), utf8.data(),
                        length, nullptr, nullptr);
  return utf8;
}

std::string Utf8FromUtf16(const std::wstring& text) {
  return Utf8FromUtf16(text.data(), text.size());
}

std::optional<std::wstring> StringArg(const flutter::EncodableMap* args,
                                      const char* key) {
  if (!args) return std::nullopt;
  auto it = args->find(flutter::EncodableValue(key));
  if (it == args->end()) return std::nullopt;
  const auto* text = std::get_if<std::string>(&it->second);
  if (!text) return std::nullopt;
  return Utf16FromUtf8(*text);
}

std::optional<int64_t> IntArg(const flutter::EncodableMap* args,
                              const char* key) {
  if (!args) return std::nullopt;
  auto it = args->find(flutter::EncodableValue(key));
  if (it == args->end()) return std::nullopt;
  return it->second.TryGetLongValue();
}

// The language [tag] narrows: "en" for "en-GB", "en" for "en".
std::wstring BaseLanguage(const std::wstring& tag) {
  return tag.substr(0, tag.find(L'-'));
}

// Adds [tag] and the language it narrows ("en" for "en-GB") to [tags].
void AddLanguage(std::vector<std::wstring>* tags, const std::wstring& tag) {
  if (tag.empty()) return;
  tags->push_back(tag);
  const std::wstring base = BaseLanguage(tag);
  if (!base.empty() && base != tag) tags->push_back(base);
}

// The languages to try, best first: the writer's Windows languages (Settings
// > Time & language > Language), then their regional format, then US
// English. The regional format comes after, as many set it only for dates
// and money.
std::vector<std::wstring> PreferredLanguages() {
  std::vector<std::wstring> tags;
  ULONG count = 0;
  ULONG size = 0;
  if (::GetUserPreferredUILanguages(MUI_LANGUAGE_NAME, &count, nullptr,
                                    &size) &&
      size > 0) {
    std::vector<wchar_t> names(size, L'\0');
    if (::GetUserPreferredUILanguages(MUI_LANGUAGE_NAME, &count, names.data(),
                                      &size)) {
      // A list of names, each ended by a nul, the list by another.
      for (const wchar_t* name = names.data(); *name;
           name += wcslen(name) + 1) {
        AddLanguage(&tags, name);
      }
    }
  }
  wchar_t locale[LOCALE_NAME_MAX_LENGTH] = {};
  if (::GetUserDefaultLocaleName(locale, LOCALE_NAME_MAX_LENGTH) > 0) {
    AddLanguage(&tags, locale);
  }
  tags.push_back(L"en-US");
  return tags;
}

// A checker for each of the writer's languages Windows can check, one per
// language ("en-GB" and "en-US" are one), best first; else one in any
// language Windows can check.
std::vector<ComPtr<ISpellChecker>> CreateCheckers() {
  std::vector<ComPtr<ISpellChecker>> checkers;
  ComPtr<ISpellCheckerFactory> factory;
  if (FAILED(::CoCreateInstance(__uuidof(SpellCheckerFactory), nullptr,
                                CLSCTX_INPROC_SERVER | CLSCTX_LOCAL_SERVER,
                                IID_PPV_ARGS(factory.GetAddressOf())))) {
    return checkers;
  }
  std::vector<std::wstring> covered;
  for (const std::wstring& tag : PreferredLanguages()) {
    if (checkers.size() >= kMaxLanguages) break;
    const std::wstring base = BaseLanguage(tag);
    bool seen = false;
    for (const std::wstring& done : covered) {
      if (done == base) seen = true;
    }
    if (seen) continue;
    BOOL supported = FALSE;
    ComPtr<ISpellChecker> checker;
    if (SUCCEEDED(factory->IsSupported(tag.c_str(), &supported)) &&
        supported &&
        SUCCEEDED(
            factory->CreateSpellChecker(tag.c_str(), checker.GetAddressOf())) &&
        checker) {
      checkers.push_back(checker);
      covered.push_back(base);
    }
  }
  if (!checkers.empty()) return checkers;
  ComPtr<IEnumString> languages;
  if (FAILED(factory->get_SupportedLanguages(languages.GetAddressOf())) ||
      !languages) {
    return checkers;
  }
  LPOLESTR tag = nullptr;
  ULONG fetched = 0;
  while (languages->Next(1, &tag, &fetched) == S_OK && fetched == 1) {
    ComPtr<ISpellChecker> checker;
    const HRESULT created =
        factory->CreateSpellChecker(tag, checker.GetAddressOf());
    ::CoTaskMemFree(tag);
    tag = nullptr;
    if (SUCCEEDED(created) && checker) {
      checkers.push_back(checker);
      break;
    }
  }
  return checkers;
}

// A misspelling one checker found: [start, start + length) in UTF-16.
struct Miss {
  ULONG start = 0;
  ULONG length = 0;
  CORRECTIVE_ACTION action = CORRECTIVE_ACTION_NONE;
  ComPtr<ISpellingError> error;
};

// The misspelled words [checker] finds in [text]. Spelling only, as on the
// Mac: a repeated word ("the the") is CORRECTIVE_ACTION_DELETE, which no
// guess can fix.
std::vector<Miss> MissesIn(ISpellChecker* checker, const std::wstring& text) {
  std::vector<Miss> misses;
  ComPtr<IEnumSpellingError> errors;
  if (FAILED(checker->Check(text.c_str(), errors.GetAddressOf())) || !errors) {
    return misses;
  }
  ComPtr<ISpellingError> error;
  while (errors->Next(error.ReleaseAndGetAddressOf()) == S_OK && error) {
    Miss miss;
    if (FAILED(error->get_StartIndex(&miss.start)) ||
        FAILED(error->get_Length(&miss.length)) ||
        FAILED(error->get_CorrectiveAction(&miss.action)) ||
        miss.length == 0 ||
        static_cast<size_t>(miss.start) + miss.length > text.size()) {
      continue;
    }
    if (miss.action != CORRECTIVE_ACTION_GET_SUGGESTIONS &&
        miss.action != CORRECTIVE_ACTION_REPLACE) {
      continue;
    }
    miss.error = error;
    misses.push_back(miss);
  }
  return misses;
}

// Whether any of [misses] overlaps [miss]. Languages can split a word
// differently ("l'homme"), so overlapping counts as the same word.
bool Overlaps(const std::vector<Miss>& misses, const Miss& miss) {
  for (const Miss& other : misses) {
    if (other.start < miss.start + miss.length &&
        miss.start < other.start + other.length) {
      return true;
    }
  }
  return false;
}

// Hears the checker change, on whatever thread Windows tells it, and
// passes it to the platform thread through [window].
class ChangedHandler final : public ISpellCheckerChangedEventHandler {
 public:
  explicit ChangedHandler(HWND window) : window_(window) {}

  STDMETHODIMP QueryInterface(REFIID id, void** object) override {
    if (!object) return E_POINTER;
    if (id == __uuidof(IUnknown) ||
        id == __uuidof(ISpellCheckerChangedEventHandler)) {
      *object = static_cast<ISpellCheckerChangedEventHandler*>(this);
      AddRef();
      return S_OK;
    }
    *object = nullptr;
    return E_NOINTERFACE;
  }

  STDMETHODIMP_(ULONG) AddRef() override { return ++references_; }

  STDMETHODIMP_(ULONG) Release() override {
    const ULONG left = --references_;
    if (left == 0) delete this;
    return left;
  }

  STDMETHODIMP Invoke(ISpellChecker* sender) override {
    ::PostMessageW(window_, kChangedMessage, 0, 0);
    return S_OK;
  }

 private:
  ~ChangedHandler() = default;

  std::atomic<ULONG> references_{1};
  HWND window_;
};

std::unique_ptr<HomericSpelling> g_spelling;

void OnRegistrarDestroyed(FlutterDesktopPluginRegistrarRef registrar) {
  g_spelling = nullptr;
}

}  // namespace

HomericSpelling::HomericSpelling(flutter::BinaryMessenger* messenger) {
  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "homeric/spelling",
      &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    HandleMethodCall(call, std::move(result));
  });
}

HomericSpelling::~HomericSpelling() {
  for (Checker& checker : checkers_) {
    if (checker.listening) {
      checker.checker->remove_SpellCheckerChanged(checker.changed_cookie);
    }
  }
  if (window_) {
    ::SetWindowLongPtrW(window_, GWLP_USERDATA, 0);
    ::DestroyWindow(window_);
  }
}

bool HomericSpelling::EnsureCheckers() {
  if (tried_checkers_) return !checkers_.empty();
  tried_checkers_ = true;
  for (ComPtr<ISpellChecker>& checker : CreateCheckers()) {
    Checker entry;
    entry.checker = checker;
    checkers_.push_back(entry);
  }
  if (checkers_.empty()) return false;

  HINSTANCE instance = ::GetModuleHandleW(nullptr);
  WNDCLASSEXW window_class = {};
  window_class.cbSize = sizeof(WNDCLASSEXW);
  window_class.lpfnWndProc = WindowProc;
  window_class.hInstance = instance;
  window_class.lpszClassName = kWindowClass;
  ::RegisterClassExW(&window_class);  // Fails harmlessly if already there.
  window_ = ::CreateWindowExW(0, kWindowClass, L"", 0, 0, 0, 0, 0,
                              HWND_MESSAGE, nullptr, instance, nullptr);
  if (!window_) return true;  // Checks, but won't hear changes.
  ::SetWindowLongPtrW(window_, GWLP_USERDATA,
                      reinterpret_cast<LONG_PTR>(this));

  ChangedHandler* handler = new ChangedHandler(window_);
  for (Checker& checker : checkers_) {
    checker.listening = SUCCEEDED(checker.checker->add_SpellCheckerChanged(
        handler, &checker.changed_cookie));
  }
  handler->Release();  // The checkers hold it while they listen.
  return true;
}

void HomericSpelling::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
  const std::string& method = call.method_name();
  if (method == "check") {
    const std::optional<std::wstring> text = StringArg(args, "text");
    if (!text || !EnsureCheckers()) {
      result->Success(flutter::EncodableValue(flutter::EncodableList()));
      return;
    }
    result->Success(flutter::EncodableValue(Misspellings(*text)));
  } else if (method == "correct") {
    const std::optional<std::wstring> text = StringArg(args, "text");
    const std::optional<int64_t> start = IntArg(args, "start");
    const std::optional<int64_t> end = IntArg(args, "end");
    if (!text || !start || !end || *start < 0 || *end <= *start ||
        *end > static_cast<int64_t>(text->size()) || !EnsureCheckers()) {
      result->Success();
      return;
    }
    const std::optional<std::wstring> fix =
        Correction(text->substr(static_cast<size_t>(*start),
                                static_cast<size_t>(*end - *start)));
    if (fix) {
      result->Success(flutter::EncodableValue(Utf8FromUtf16(*fix)));
    } else {
      result->Success();
    }
  } else if (method == "learn" || method == "ignore") {
    const std::optional<std::wstring> word = StringArg(args, "word");
    if (word && !word->empty() && EnsureCheckers()) {
      // The editor checks again by itself; Windows' echo of this change
      // would only make it check twice.
      own_change_until_ = ::GetTickCount64() + kOwnChangeEchoMs;
      for (Checker& checker : checkers_) {
        if (method == "learn") {
          checker.checker->Add(word->c_str());
        } else {
          checker.checker->Ignore(word->c_str());
        }
      }
    }
    result->Success();
  } else if (method == "settings") {
    // Windows' "Autocorrect misspelled words" lives in undocumented
    // registry values that mean the touch keyboard on some versions, and
    // it keeps no text replacement list, so the editor leaves typing alone.
    result->Success(flutter::EncodableValue(flutter::EncodableMap{
        {flutter::EncodableValue("autocorrect"), flutter::EncodableValue(false)},
        {flutter::EncodableValue("replacement"), flutter::EncodableValue(false)},
        {flutter::EncodableValue("replacements"),
         flutter::EncodableValue(flutter::EncodableMap())},
    }));
  } else {
    result->NotImplemented();
  }
}

// The words every checker flags, with the first checker's guesses: its
// autocorrect replacement first, then its suggestions.
flutter::EncodableList HomericSpelling::Misspellings(
    const std::wstring& text) {
  flutter::EncodableList found;
  if (text.empty()) return found;
  std::vector<Miss> misses = MissesIn(checkers_.front().checker.Get(), text);
  for (size_t i = 1; i < checkers_.size() && !misses.empty(); ++i) {
    const std::vector<Miss> others = MissesIn(checkers_[i].checker.Get(), text);
    std::vector<Miss> kept;
    for (const Miss& miss : misses) {
      if (Overlaps(others, miss)) kept.push_back(miss);
    }
    misses.swap(kept);
  }
  for (const Miss& miss : misses) {
    flutter::EncodableList guesses;
    if (miss.action == CORRECTIVE_ACTION_REPLACE) {
      LPWSTR replacement = nullptr;
      if (SUCCEEDED(miss.error->get_Replacement(&replacement)) &&
          replacement) {
        if (*replacement) {
          guesses.push_back(flutter::EncodableValue(
              Utf8FromUtf16(replacement, wcslen(replacement))));
        }
        ::CoTaskMemFree(replacement);
      }
    }
    for (flutter::EncodableValue& guess :
         Guesses(text.substr(miss.start, miss.length))) {
      if (guesses.size() >= kMaxGuesses) break;
      bool seen = false;
      for (const flutter::EncodableValue& kept : guesses) {
        if (kept == guess) seen = true;
      }
      if (!seen) guesses.push_back(std::move(guess));
    }
    found.push_back(flutter::EncodableValue(flutter::EncodableMap{
        {flutter::EncodableValue("start"),
         flutter::EncodableValue(static_cast<int32_t>(miss.start))},
        {flutter::EncodableValue("end"),
         flutter::EncodableValue(
             static_cast<int32_t>(miss.start + miss.length))},
        {flutter::EncodableValue("guesses"), flutter::EncodableValue(guesses)},
    }));
  }
  return found;
}

flutter::EncodableList HomericSpelling::Guesses(const std::wstring& word) {
  flutter::EncodableList guesses;
  ComPtr<IEnumString> suggestions;
  if (FAILED(checkers_.front().checker->Suggest(word.c_str(),
                                                 suggestions.GetAddressOf())) ||
      !suggestions) {
    return guesses;
  }
  LPOLESTR suggestion = nullptr;
  ULONG fetched = 0;
  while (guesses.size() < kMaxGuesses &&
         suggestions->Next(1, &suggestion, &fetched) == S_OK && fetched == 1) {
    if (suggestion && *suggestion) {
      guesses.push_back(flutter::EncodableValue(
          Utf8FromUtf16(suggestion, wcslen(suggestion))));
    }
    ::CoTaskMemFree(suggestion);
    suggestion = nullptr;
  }
  return guesses;
}

// Autocorrect's choice for [word]: the replacement the first checker's
// autocorrect list gives it (CORRECTIVE_ACTION_REPLACE), else null. Windows
// never guesses a correction the way the Mac does; a word with only
// suggestions, or one another of the writer's languages knows, is left as
// typed.
std::optional<std::wstring> HomericSpelling::Correction(
    const std::wstring& word) {
  const std::vector<Miss> misses =
      MissesIn(checkers_.front().checker.Get(), word);
  if (misses.empty()) return std::nullopt;
  const Miss& miss = misses.front();
  if (miss.action != CORRECTIVE_ACTION_REPLACE || miss.start != 0 ||
      miss.length != word.size()) {
    return std::nullopt;
  }
  for (size_t i = 1; i < checkers_.size(); ++i) {
    if (!Overlaps(MissesIn(checkers_[i].checker.Get(), word), miss)) {
      return std::nullopt;
    }
  }
  LPWSTR replacement = nullptr;
  if (FAILED(miss.error->get_Replacement(&replacement)) || !replacement) {
    return std::nullopt;
  }
  std::wstring fix(replacement);
  ::CoTaskMemFree(replacement);
  if (fix.empty()) return std::nullopt;
  return fix;
}

void HomericSpelling::TellSettingsChanged() {
  channel_->InvokeMethod("settingsChanged", nullptr);
}

LRESULT CALLBACK HomericSpelling::WindowProc(HWND window, UINT message,
                                             WPARAM wparam, LPARAM lparam) {
  if (message == kChangedMessage) {
    // One change can fire once per checker: tell Flutter once.
    MSG queued;
    while (::PeekMessageW(&queued, window, kChangedMessage, kChangedMessage,
                          PM_REMOVE)) {
    }
    auto* spelling = reinterpret_cast<HomericSpelling*>(
        ::GetWindowLongPtrW(window, GWLP_USERDATA));
    if (spelling && ::GetTickCount64() >= spelling->own_change_until_) {
      spelling->TellSettingsChanged();
    }
    return 0;
  }
  return ::DefWindowProcW(window, message, wparam, lparam);
}

void RegisterHomericSpelling(flutter::FlutterEngine* engine) {
  g_spelling = std::make_unique<HomericSpelling>(engine->messenger());
  // Gone with the engine, before its messenger.
  FlutterDesktopPluginRegistrarSetDestructionHandler(
      engine->GetRegistrarForPlugin("HomericSpelling"), OnRegistrarDestroyed);
}
