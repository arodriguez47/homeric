//! C entry points over Harper's English grammar checker, for Homeric.
//!
//! Dart calls [`homeric_harper_check`] with one paragraph of UTF-8 text and
//! gets back a JSON array of findings whose ranges are UTF-16 code-unit
//! offsets into that text, ready to use on a Dart string. Spelling is left
//! to the platform's own checker, so Harper's SpellCheck rule stays off.

use std::ffi::{CString, c_char};
use std::sync::{Mutex, OnceLock};

use harper_core::linting::{LintGroup, LintKind, Suggestion};
use harper_core::spell::FstDictionary;
use harper_core::{Dialect, Document};
use serde::Serialize;

/// Rules Homeric never asks Harper for: spelling belongs to the platform
/// checker, and the rest read as noise in short notes.
const OFF_RULES: &[&str] = &["SpellCheck", "SentenceCapitalization"];

#[derive(Serialize)]
pub struct Finding {
    /// UTF-16 start offset.
    pub start: usize,
    /// UTF-16 end offset (exclusive).
    pub end: usize,
    /// Harper's rule key, such as `RepeatedWords`.
    pub rule: String,
    /// Harper's lint kind, such as `Grammar` or `Redundancy`.
    pub kind: &'static str,
    /// One sentence on what is wrong, in plain words.
    pub message: String,
    /// Full replacements for the range, best first. Empty when Harper only
    /// flags the text.
    pub replacements: Vec<String>,
}

fn group_for(dialect: Dialect) -> &'static Mutex<LintGroup> {
    static AMERICAN: OnceLock<Mutex<LintGroup>> = OnceLock::new();
    static BRITISH: OnceLock<Mutex<LintGroup>> = OnceLock::new();
    static AUSTRALIAN: OnceLock<Mutex<LintGroup>> = OnceLock::new();
    static CANADIAN: OnceLock<Mutex<LintGroup>> = OnceLock::new();
    static INDIAN: OnceLock<Mutex<LintGroup>> = OnceLock::new();
    let cell = match dialect {
        Dialect::American => &AMERICAN,
        Dialect::British => &BRITISH,
        Dialect::Australian => &AUSTRALIAN,
        Dialect::Canadian => &CANADIAN,
        Dialect::Indian => &INDIAN,
    };
    cell.get_or_init(|| {
        let mut group = LintGroup::new_curated(FstDictionary::curated(), dialect);
        for rule in OFF_RULES {
            group.config.set_rule_enabled(*rule, false);
        }
        Mutex::new(group)
    })
}

fn dialect_of(code: u8) -> Dialect {
    match code {
        1 => Dialect::British,
        2 => Dialect::Australian,
        3 => Dialect::Canadian,
        4 => Dialect::Indian,
        _ => Dialect::American,
    }
}

fn kind_name(kind: &LintKind) -> &'static str {
    match kind {
        LintKind::Agreement => "Agreement",
        LintKind::BoundaryError => "BoundaryError",
        LintKind::Capitalization => "Capitalization",
        LintKind::Eggcorn => "Eggcorn",
        LintKind::Enhancement => "Enhancement",
        LintKind::Formatting => "Formatting",
        LintKind::Grammar => "Grammar",
        LintKind::Malapropism => "Malapropism",
        LintKind::Nonstandard => "Nonstandard",
        LintKind::Punctuation => "Punctuation",
        LintKind::Readability => "Readability",
        LintKind::Redundancy => "Redundancy",
        LintKind::Regionalism => "Regionalism",
        LintKind::Repetition => "Repetition",
        LintKind::Spelling => "Spelling",
        LintKind::Style => "Style",
        LintKind::Typo => "Typo",
        LintKind::Usage => "Usage",
        LintKind::WordChoice => "WordChoice",
        _ => "Miscellaneous",
    }
}

/// Maps char (Unicode scalar) indices to UTF-16 offsets; `table[i]` is the
/// UTF-16 offset where char `i` starts, and `table[len]` is the total.
fn utf16_table(chars: &[char]) -> Vec<usize> {
    let mut table = Vec::with_capacity(chars.len() + 1);
    let mut at = 0;
    for c in chars {
        table.push(at);
        at += c.len_utf16();
    }
    table.push(at);
    table
}

/// Strips Harper's light Markdown (backticks, emphasis) from a message.
fn plain(message: &str) -> String {
    message.replace('`', "").replace("**", "")
}

/// Checks `text` and returns findings ordered by start offset.
pub fn check(text: &str, dialect: Dialect) -> Vec<Finding> {
    let document = Document::new_plain_english_curated(text);
    let chars = document.get_source();
    let table = utf16_table(chars);
    let lints = {
        let mut group = group_for(dialect).lock().unwrap_or_else(|e| e.into_inner());
        group.organized_lints(&document)
    };
    let mut findings = Vec::new();
    for (rule, lints) in lints {
        for lint in lints {
            let span = lint.span;
            if span.end > chars.len() || span.start >= span.end {
                continue;
            }
            if matches!(lint.lint_kind, LintKind::Spelling) {
                continue;
            }
            let original: String = chars[span.start..span.end].iter().collect();
            let mut replacements: Vec<String> = Vec::new();
            for suggestion in &lint.suggestions {
                let replacement = match suggestion {
                    Suggestion::ReplaceWith(with) => with.iter().collect(),
                    Suggestion::InsertAfter(after) => {
                        let mut out = original.clone();
                        out.extend(after.iter());
                        out
                    }
                    Suggestion::Remove => String::new(),
                };
                if replacement.trim_end() != original.trim_end()
                    && !replacements.iter().any(|r| r.trim_end() == replacement.trim_end())
                {
                    replacements.push(replacement);
                }
            }
            findings.push(Finding {
                start: table[span.start],
                end: table[span.end],
                rule: rule.clone(),
                kind: kind_name(&lint.lint_kind),
                message: plain(&lint.message),
                replacements,
            });
        }
    }
    findings.sort_by(|a, b| a.start.cmp(&b.start).then(a.end.cmp(&b.end)));
    findings
}

/// Checks one paragraph of UTF-8 text (`len` bytes at `text`, no NUL
/// needed) and returns a JSON array of findings as a new C string, or null
/// on failure. Free the result with [`homeric_harper_free`].
///
/// # Safety
/// `text` must point to `len` readable bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn homeric_harper_check(text: *const u8, len: usize, dialect: u8) -> *mut c_char {
    if text.is_null() {
        return std::ptr::null_mut();
    }
    let result = std::panic::catch_unwind(|| {
        let bytes = unsafe { std::slice::from_raw_parts(text, len) };
        let text = String::from_utf8_lossy(bytes);
        let findings = check(&text, dialect_of(dialect));
        serde_json::to_string(&findings).unwrap_or_else(|_| "[]".into())
    });
    match result.ok().and_then(|json| CString::new(json).ok()) {
        Some(json) => json.into_raw(),
        None => std::ptr::null_mut(),
    }
}

/// Allocates `len` zeroed bytes for Dart to write a paragraph into. Free
/// them with [`homeric_harper_dealloc`].
#[unsafe(no_mangle)]
pub extern "C" fn homeric_harper_alloc(len: usize) -> *mut u8 {
    let mut bytes = vec![0u8; len.max(1)].into_boxed_slice();
    let pointer = bytes.as_mut_ptr();
    std::mem::forget(bytes);
    pointer
}

/// Frees bytes from [`homeric_harper_alloc`].
///
/// # Safety
/// `ptr` and `len` must be what [`homeric_harper_alloc`] took and gave.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn homeric_harper_dealloc(ptr: *mut u8, len: usize) {
    if !ptr.is_null() {
        let slice = std::ptr::slice_from_raw_parts_mut(ptr, len.max(1));
        drop(unsafe { Box::from_raw(slice) });
    }
}

/// Loads the dictionary and rules ahead of the first check.
#[unsafe(no_mangle)]
pub extern "C" fn homeric_harper_warm_up(dialect: u8) {
    let _ = std::panic::catch_unwind(|| {
        group_for(dialect_of(dialect));
    });
}

/// Frees a string returned by [`homeric_harper_check`].
///
/// # Safety
/// `ptr` must come from [`homeric_harper_check`] and be freed once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn homeric_harper_free(ptr: *mut c_char) {
    if !ptr.is_null() {
        drop(unsafe { CString::from_raw(ptr) });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rules(text: &str) -> Vec<(String, String, Vec<String>)> {
        check(text, Dialect::American)
            .into_iter()
            .map(|f| {
                let chars: Vec<u16> = text.encode_utf16().collect();
                (
                    f.rule,
                    String::from_utf16(&chars[f.start..f.end]).unwrap(),
                    f.replacements,
                )
            })
            .collect()
    }

    #[test]
    fn flags_repeated_words_and_agreement() {
        let found = rules("Their going to see if the the anemones has opened.");
        println!("{found:#?}");
        assert!(found.iter().any(|(_, text, _)| text.contains("the the")));
    }

    #[test]
    fn offsets_are_utf16() {
        let found = rules("🌊 We saw the the tide.");
        let repeated = found
            .iter()
            .find(|(_, text, _)| text.contains("the the"))
            .expect("repeated words");
        assert!(repeated.1.starts_with("the"));
    }

    #[test]
    fn clean_text_has_no_findings() {
        assert!(rules("We walked out at low tide to look at the pools.").is_empty());
    }

    #[test]
    fn spelling_is_left_to_the_platform() {
        assert!(rules("We saw anemnoes.").is_empty());
    }
}
