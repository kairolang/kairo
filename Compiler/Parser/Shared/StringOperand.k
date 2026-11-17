/// --- The Kairo Project ---------------- Parser/Shared/StringOperand.k --- ///
///
///   A string literal written where the grammar wants a fixed operand
///   rather than a value: the language of `ffi "c++"` and `inline "asm"`,
///   and the header of `ffi "c++" import "vector"`. Which prefixes such a
///   string may carry, and the one diagnostic for a prefix it may not; it
///   takes no literal suffix (`"c++"_x`), which names a literal operator
///   over a value, and the operand is not a value.
///
///   Shared by the preprocessor, which reads the whole `ffi ... import`
///   line, and the parser, which reads the language of an ffi block or
///   declaration and of an inline block. Each reports through its own sink:
///   the label on the string, and the removal of its prefix when
///   refused_prefix_fixable says so.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

import Lexer::Immediate::Immediate
import Location::SourceRange::SourceRange

/// What a fixed string operand names, which decides the prefixes it takes.
pub enum StringOperand {
    /// A language (`"c"`, `"c++"`, `"asm"`): a plain string, no prefix.
    Tag,
    /// A header path: a plain string or a raw one (`r"C:\sdk\gl.h"` keeps
    /// its backslashes). A format string or a byte string never names a
    /// file.
    Path,
}

/// The prefix letters `d` carries that a `what` operand does not take,
/// in the order `f`, `b`, `r`; "" when it takes the string as written.
pub fn refused_prefix(d: unsafe *Immediate::StringData, what: StringOperand) -> string {
    if d == &null {
        return ""
    }

    var out = ""
    if d->prefix_kind.has(Immediate::TextPrefixKind::Format) {
        out += "f"
    }

    if d->prefix_kind.has(Immediate::TextPrefixKind::Bytes) {
        out += "b"
    }

    if d->prefix_kind.has(Immediate::TextPrefixKind::Raw) && what == StringOperand::Tag {
        out += "r"
    }

    return out
}

/// The message for a `what` operand of `construct` (`ffi`, `inline`)
/// written with the refused prefix `letters`.
pub fn refused_prefix_message(what:            StringOperand,
                              const construct: string,
                              const letters:   string) -> string {
    if what == StringOperand::Tag {
        return f"the language of '{construct}' is a plain string; remove the '{letters}' prefix"
    }

    return f"an ffi header path is a plain or raw string; remove the '{letters}' prefix"
}

/// The message for a `what` operand of `construct` written with a literal
/// suffix.
pub fn refused_suffix_message(what: StringOperand, const construct: string) -> string {
    if what == StringOperand::Tag {
        return f"the language of '{construct}' is a plain string; remove the suffix"
    }

    return "an ffi header path takes no suffix; remove it"
}

/// True when removing `prefix`, a refused string's whole prefix, is the
/// fix-it: `letters` (refused_prefix) is all of it. A prefix that keeps a
/// letter the operand takes (`rf` on a path) gets none, since dropping all
/// of it would change what the raw string spells.
pub fn refused_prefix_fixable(prefix: SourceRange, const letters: string) -> bool {
    return prefix.is_valid() && (prefix.size() as usize) == letters.size()
}

/// The range a refusal labels: `lit` with its prefix `prefix` in front,
/// so the diagnostic starts at the letters it asks to remove.
pub fn prefixed_range(prefix: SourceRange, lit: SourceRange) -> SourceRange {
    if prefix.is_valid() {
        return prefix | lit
    }

    return lit
}
