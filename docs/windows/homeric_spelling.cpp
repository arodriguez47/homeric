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

// Posted to the message-only window when the checker changes.
constexpr UINT kChangedMessage = WM_APP + 0x51;

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

// Adds [tag] and the language it narrows ("en" for "en-GB") to [tags].
void AddLanguage(std::vector<std::wstring>* tags, const std::wstring& tag) {
  if (tag.empty()) return;
  tags->push_back(tag);
  const size_t dash = tag.find(L'-');
  if (dash != std::wstring::npos && dash > 0) {
    tags->push_back(tag.substr(0, dash));
  }
}

// The languages to try, best first: the writer's regional format, then
// their Windows display languages, then US English.
std::vector<std::wstring> PreferredLanguages() {
  std::vector<std::wstring> tags;
  wchar_t locale[LOCALE_NAME_MAX_LENGTH] = {};
  if (::GetUserDefaultLocaleName(locale, LOCALE_NAME_MAX_LENGTH) > 0) {
    AddLanguage(&tags, locale);
  }
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
  tags.push_back(L"en-US");
  return tags;
}

// A checker in the first preferred language Windows can check, else in
// any language it can.
ComPtr<ISpellChecker> CreateChecker() {
  ComPtr<ISpellCheckerFactory> factory;
  if (FAILED(::CoCreateInstance(__uuidof(SpellCheckerFactory), nullptr,
                                CLSCTX_INPROC_SERVER | CLSCTX_LOCAL_SERVER,
                                IID_PPV_ARGS(factory.GetAddressOf())))) {
    return nullptr;
  }
  ComPtr<ISpellChecker> checker;
  for (const std::wstring& tag : PreferredLanguages()) {
    BOOL supported = FALSE;
    if (SUCCEEDED(factory->IsSupported(tag.c_str(), &supported)) &&
        supported &&
        SUCCEEDED(factory->CreateSpellChecker(
            tag.c_str(), checker.ReleaseAndGetAddressOf())) &&
        checker) {
      return checker;
    }
  }
  ComPtr<IEnumString> languages;
  if (FAILED(factory->get_SupportedLanguages(languages.GetAddressOf())) ||
      !languages) {
    return nullptr;
  }
  LPOLESTR tag = nullptr;
  ULONG fetched = 0;
  while (languages->Next(1, &tag, &fetched) == S_OK && fetched == 1) {
    const HRESULT created =
        factory->CreateSpellChecker(tag, checker.ReleaseAndGetAddressOf());
    ::CoTaskMemFree(tag);
    tag = nullptr;
    if (SUCCEEDED(created) && checker) return checker;
  }
  return nullptr;
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

  checker_ = CreateChecker();
  if (!checker_) return;

  HINSTANCE instance = ::GetModuleHandleW(nullptr);
  WNDCLASSEXW window_class = {};
  window_class.cbSize = sizeof(WNDCLASSEXW);
  window_class.lpfnWndProc = WindowProc;
  window_class.hInstance = instance;
  window_class.lpszClassName = kWindowClass;
  ::RegisterClassExW(&window_class);  // Fails harmlessly if already there.
  window_ = ::CreateWindowExW(0, kWindowClass, L"", 0, 0, 0, 0, 0,
                              HWND_MESSAGE, nullptr, instance, nullptr);
  if (!window_) return;
  ::SetWindowLongPtrW(window_, GWLP_USERDATA,
                      reinterpret_cast<LONG_PTR>(this));

  ChangedHandler* handler = new ChangedHandler(window_);
  listening_ =
      SUCCEEDED(checker_->add_SpellCheckerChanged(handler, &changed_cookie_));
  handler->Release();  // The checker holds it while it listens.
}

HomericSpelling::~HomericSpelling() {
  if (listening_ && checker_) {
    checker_->remove_SpellCheckerChanged(changed_cookie_);
  }
  if (window_) {
    ::SetWindowLongPtrW(window_, GWLP_USERDATA, 0);
    ::DestroyWindow(window_);
  }
}

void HomericSpelling::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
  const std::string& method = call.method_name();
  if (method == "check") {
    const std::optional<std::wstring> text = StringArg(args, "text");
    if (!text || !checker_) {
      result->Success(flutter::EncodableValue(flutter::EncodableList()));
      return;
    }
    result->Success(flutter::EncodableValue(Misspellings(*text)));
  } else if (method == "correct") {
    const std::optional<std::wstring> text = StringArg(args, "text");
    const std::optional<int64_t> start = IntArg(args, "start");
    const std::optional<int64_t> end = IntArg(args, "end");
    if (!text || !start || !end || !checker_ || *start < 0 ||
        *end <= *start || *end > static_cast<int64_t>(text->size())) {
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
    if (word && !word->empty() && checker_) {
      if (method == "learn") {
        checker_->Add(word->c_str());
      } else {
        checker_->Ignore(word->c_str());
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

flutter::EncodableList HomericSpelling::Misspellings(
    const std::wstring& text) {
  flutter::EncodableList found;
  if (text.empty()) return found;
  ComPtr<IEnumSpellingError> errors;
  if (FAILED(checker_->Check(text.c_str(), errors.GetAddressOf())) ||
      !errors) {
    return found;
  }
  ComPtr<ISpellingError> error;
  while (errors->Next(error.ReleaseAndGetAddressOf()) == S_OK && error) {
    ULONG start = 0;
    ULONG length = 0;
    CORRECTIVE_ACTION action = CORRECTIVE_ACTION_NONE;
    if (FAILED(error->get_StartIndex(&start)) ||
        FAILED(error->get_Length(&length)) ||
        FAILED(error->get_CorrectiveAction(&action)) || length == 0 ||
        static_cast<size_t>(start) + length > text.size()) {
      continue;
    }
    // Spelling only, as on the Mac: a repeated word ("the the") is
    // CORRECTIVE_ACTION_DELETE, which no guess can fix.
    if (action != CORRECTIVE_ACTION_GET_SUGGESTIONS &&
        action != CORRECTIVE_ACTION_REPLACE) {
      continue;
    }
    flutter::EncodableList guesses;
    if (action == CORRECTIVE_ACTION_REPLACE) {
      LPWSTR replacement = nullptr;
      if (SUCCEEDED(error->get_Replacement(&replacement)) && replacement) {
        if (*replacement) {
          guesses.push_back(flutter::EncodableValue(
              Utf8FromUtf16(replacement, wcslen(replacement))));
        }
        ::CoTaskMemFree(replacement);
      }
    }
    for (flutter::EncodableValue& guess : Guesses(text.substr(start, length))) {
      if (guesses.size() >= kMaxGuesses) break;
      bool seen = false;
      for (const flutter::EncodableValue& kept : guesses) {
        if (kept == guess) seen = true;
      }
      if (!seen) guesses.push_back(std::move(guess));
    }
    found.push_back(flutter::EncodableValue(flutter::EncodableMap{
        {flutter::EncodableValue("start"),
         flutter::EncodableValue(static_cast<int32_t>(start))},
        {flutter::EncodableValue("end"),
         flutter::EncodableValue(static_cast<int32_t>(start + length))},
        {flutter::EncodableValue("guesses"), flutter::EncodableValue(guesses)},
    }));
  }
  return found;
}

flutter::EncodableList HomericSpelling::Guesses(const std::wstring& word) {
  flutter::EncodableList guesses;
  ComPtr<IEnumString> suggestions;
  if (FAILED(checker_->Suggest(word.c_str(), suggestions.GetAddressOf())) ||
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

// Autocorrect's choice for [word]: the replacement Windows' autocorrect
// list gives it (CORRECTIVE_ACTION_REPLACE), else null. Windows never
// guesses a correction the way the Mac does; a word with only suggestions
// is left as typed.
std::optional<std::wstring> HomericSpelling::Correction(
    const std::wstring& word) {
  ComPtr<IEnumSpellingError> errors;
  if (FAILED(checker_->Check(word.c_str(), errors.GetAddressOf())) ||
      !errors) {
    return std::nullopt;
  }
  ComPtr<ISpellingError> error;
  if (errors->Next(error.GetAddressOf()) != S_OK || !error) {
    return std::nullopt;
  }
  ULONG start = 0;
  ULONG length = 0;
  CORRECTIVE_ACTION action = CORRECTIVE_ACTION_NONE;
  if (FAILED(error->get_StartIndex(&start)) ||
      FAILED(error->get_Length(&length)) ||
      FAILED(error->get_CorrectiveAction(&action)) ||
      action != CORRECTIVE_ACTION_REPLACE || start != 0 ||
      length != word.size()) {
    return std::nullopt;
  }
  LPWSTR replacement = nullptr;
  if (FAILED(error->get_Replacement(&replacement)) || !replacement) {
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
    auto* spelling = reinterpret_cast<HomericSpelling*>(
        ::GetWindowLongPtrW(window, GWLP_USERDATA));
    if (spelling) spelling->TellSettingsChanged();
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
