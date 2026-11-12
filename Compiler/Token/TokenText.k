/// --- The Kairo Project ---------------------------- Token/TokenText.k --- ///
///
///   TokenText: the one way to get a token's spelling, and macro unwrapping.
///
///     Two layers, both here so they cannot drift:
///
///     1. unwrap_expansion()   the MECHANISM. Walks a TkMacroExpand chain
///        back to the original (kind, imm, def_range). No diagnostics, no
///        cursor movement, no policy. Every consumer that needs to look
///        through macro wrapping calls this; policy (emitting a diag on
///        depth overflow, skipping AtComment by advancing a cursor, etc.)
///        stays in the consumer.
///
///     2. TokenText::resolve()   the TEXT ACCESSOR. The only sanctioned way
///        to turn a token into its spelled text. Identifier spellings come
///        from the imm interner (synthesized identifiers have NO backing
///        source text); literals come from their imm payloads; operators
///        and keywords have canonical spellings; everything else falls back
///        to the source manager.
///
///     RULE: no consumer outside this file may call sm->get_text on a token
///     range to obtain token text. Raw source access is legitimate only for
///     source EXCERPTS (diagnostic carets, lexer escape errors)   never for
///     token spellings.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "Native/Types.hh"

import Lexer::Immediate::{
    Immediate,
    ImmediateTable,
}
import Location::SourceManager::SourceManager
import Location::SourceRange::SourceRange
import Macro::Sentinel::MacroSentinel
import Token::Token::Token
import Token::TokenCacheManager::TokenCacheManager
import Token::TokenKind::{
    TokenKind,
    is_valid_token_kind,
    token_kind_to_readable_string,
}

/// \struct UnwrappedToken
/// \brief result of walking a macro-expansion chain to its origin.
pub struct UnwrappedToken {
    pub var kind:        TokenKind ///< original token kind.
    pub var imm:         u32 ///< original imm index (ident/literal payload).
    pub var def_range:   SourceRange ///< innermost definition-body site.
    pub var depth:       u32                    = 0 ///< chain hops walked (0 = not wrapped).
    pub var hit_limit:   bool                   = false ///< chain exceeded max_depth; result truncated.
    pub var tbl:         unsafe *ImmediateTable ///< table used to unwrap the chain (may be null).
    var     sm:          unsafe *SourceManager ///< source manager used to unwrap the chain (may be null).
    pub var is_sentinel: bool                   = false ///< compiler marker (todo!/include!/embed!...),
    ///  kind stays TkMacroExpand, imm is the sentinel.
}

/// \brief walks a TkMacroExpand chain back to the original token identity.
///
/// \details wrap_token chains original_kind/original_imm through nested
///          wraps, so a well-formed token unwraps in one hop; the loop is
///          defensive against malformed chains. Pure mechanism: reports
///          nothing, moves nothing. Callers decide what hit_limit and
///          is_sentinel mean for them.
pub fn unwrap_expansion(tok:       Token,
                        tcm:       unsafe *TokenCacheManager,
                        max_depth: u32 = 32) -> UnwrappedToken {
    var r = UnwrappedToken{}
    r.kind      = tok.kind
    r.imm       = tok.imm
    r.def_range = tok.range

    eval if defined!(DEBUG) {
        if !(tcm != &null) {
            kairo::std::ice_fail(
                r"TokenCacheManager is null in unwrap_expansion",
            )
        }
    }

    // record table: owned by the file whose expander wrote the chain.
    // wrap_token stamps wrapped tokens with the invocation-site range,
    // so this resolves to the expanding file. pinned for the whole walk:
    // all records of a chain live in one table by construction.
    var unsafe *rec_tbl = tcm->get_imm_table_for_token(tok)
    r.tbl = rec_tbl
    r.sm  = tcm->get_source_manager()

    while (r.kind as u32) == (TokenKind::TkMacroExpand as u32) {
        if r.imm >= (MacroSentinel::Threshold as u32) {
            r.is_sentinel = true
            return r
        }

        if rec_tbl == &null || r.depth >= max_depth {
            r.hit_limit = r.depth >= max_depth
            return r
        }

        var unsafe *info = rec_tbl->get<Immediate::MacroExpansionInfo>(r.imm)
        if info == &null {
            // imm not present in the record table: malformed chain.
            // degrade with the wrapped identity; never crash in mechanism.
            r.hit_limit = true
            return r
        }

        r.kind      = info->original_kind
        r.imm       = info->original_imm
        r.def_range = info->def_range
        r.depth += 1
    }

    // payload table: owned by the ORIGINAL token's file. def_range is the
    // original token's own range (unwrapped tokens have consistent
    // range/imm), so it resolves to the table that owns r.imm.
    if r.depth > 0 {
        r.tbl = tcm->get_imm_table_for_token(Token(r.def_range, r.kind, r.imm))
    }

    return r
}

/// \brief canonical display text for a macro sentinel imm value.
pub fn sentinel_text(imm: u32) -> string {
    if imm == (MacroSentinel::Todo as u32) {
        return "<todo>"
    }

    if imm == (MacroSentinel::Unreachable as u32) {
        return "<unreachable>"
    }

    if imm == (MacroSentinel::Include as u32) {
        return "<include>"
    }

    if imm == (MacroSentinel::EmbedStr as u32) {
        return "<embed_str>"
    }

    if imm == (MacroSentinel::Embed as u32) {
        return "<embed>"
    }

    if imm == (MacroSentinel::UnreachableUnchecked as u32) {
        return "<unreachable_unchecked>"
    }

    return "<unknown_macro>"
}

pub class TokenText {
    pub var text:      string
    pub var range:     SourceRange
    pub var is_expand: bool        = false
    pub var is_marker: bool        = false

    fn TokenText(self,
                 const txt: string,
                 rng:       SourceRange,
                 expand:    bool = false,
                 marker:    bool = false) -> void {
        self.text      = txt
        self.range     = rng
        self.is_expand = expand
        self.is_marker = marker
    }

    /// \brief resolves a token to its spelled text.
    pub static fn resolve(tok: Token, tcm: unsafe *TokenCacheManager) -> TokenText {
        eval if defined!(DEBUG) {
            if !(tcm != &null) {
                kairo::std::ice_fail(
                    r"TokenCacheManager is null in TokenText::resolve",
                )
            }
        }

        var        u    = unwrap_expansion(tok, tcm)
        var unsafe *tbl = u.tbl
        var unsafe *sm  = u.sm

        eval if defined!(DEBUG) {
            if !(sm != &null) {
                kairo::std::ice_fail(
                    r"SourceManager is null in TokenText::resolve",
                )
            }
        }

        eval if defined!(DEBUG) {
            if !(tbl != &null) {
                kairo::std::ice_fail(
                    r"ImmediateTable is null in TokenText::resolve",
                )
            }
        }

        // compiler-internal markers (todo!/include!/embed!...), not source tokens
        if u.is_sentinel {
            return TokenText(sentinel_text(u.imm), u.def_range, true, true)
        }

        var kind      = u.kind
        var imm       = u.imm
        var tok_range = u.def_range
        var is_expand = u.depth > 0

        var create = fn (s: string) -> TokenText {
            return TokenText(s, tok_range, is_expand, false)
        }

        // these have no meaningful text return canonical representation
        match kind {
            case TokenKind::TkUnknown {
                return create("$unknown$")
            } case TokenKind::TkEof {
                return create("$eof$")
            } case TokenKind::TkError {
                return create("$error$")
            } case TokenKind::TkNewLine {
                return create("\\n")
            } case TokenKind::TkWhitespace {
                return create(" ")
            } case TokenKind::TkFileStart {
                return create("$start$")
            } case TokenKind::TkFileEnd {
                return create("$end$")
            } case TokenKind::TkGenerated {
                return create("$generated$")
            } case TokenKind::TkMacroExpand {
                return create("$macro_expand$")
            } case TokenKind::TkCodeComplete {
                return create("$IDE_COMPL$")
            } case TokenKind::BiFile {
                return create("__file__")
            } case TokenKind::BiLine {
                return create("__line__")
            } case TokenKind::BiColumn {
                return create("__column__")
            } case TokenKind::BiFunction {
                return create("__function__")
            } case TokenKind::BiModule {
                return create("__module__")
            } case TokenKind::LitInt {
                if tbl != &null {
                    var unsafe *int_data = tbl->get<Immediate::IntData>(imm)
                    return create(f"{int_data->value_lo}")
                }

                return create(sm->get_text(tok_range))
            } case TokenKind::LitFloat {
                if tbl != &null {
                    var unsafe *float_data = tbl->get<Immediate::FloatData>(imm)
                    return create(f"{float_data->value_ieee as f64}")
                }

                return create(sm->get_text(tok_range))
            } case TokenKind::LitIdentifier {
                // identifier spelling lives in the imm interner, NEVER in the
                // source range: synthesized identifiers (unique_id!, gensym)
                // have no backing source text, and `imm` here is the UNWRAPPED
                // ident index (tok.imm on a wrapped token is the expansion
                // record, not the ident   see unwrap_expansion).
                if tbl != &null {
                    return create(tbl->get_ident(imm))
                }

                return create(
                    f"$FALLBACK-MISSING-INTERN$ {sm->get_text(tok_range)}",
                )
            } case TokenKind::LitString {
                if tbl != &null {
                    var str_text = tbl->string_text(imm, sm)
                    return create(f"\"{str_text}\"")
                }

                return create(
                    f"$FALLBACK-MISSING-STRING-INTERN$ {sm->get_text(tok_range)}",
                )
            } case TokenKind::AtComment, TokenKind::LitChar,  TokenKind::KwMutable,
                   TokenKind::AtByte,    TokenKind::AtChar,   TokenKind::AtF8,
                   TokenKind::AtF8E4M3,  TokenKind::AtF8E5M2, TokenKind::AtBf16,
                   TokenKind::AtF512 {
                // the source bytes. A comment and a char literal have no fixed
                // spelling; the eight words never had a row here, and for a lexed
                // token their source bytes are the table's spelling anyway.
                // Moving them to the table is its own change, not this one.
                return TokenText(
                    sm->get_text(tok_range),
                    tok_range,
                    is_expand,
                    false,
                )
            } default {
                // keywords, operators, primitive-type words, `null` and `Self`:
                // TokenKind's spelling table, so a new keyword is spelled once.
                // A value that is not a kind (the enum is @open) keeps the
                // source bytes rather than the table's "UNKNOWN".
                if is_valid_token_kind(kind as u32) {
                    return create(token_kind_to_readable_string(kind))
                }

                return TokenText(
                    sm->get_text(tok_range),
                    tok_range,
                    is_expand,
                    false,
                )
            }

            // LitString / LitChar deliberately fall through to the range
            // fallback below: their spelled text (quotes, prefixes, escapes)
            // is exactly the source bytes. Decoded VALUES come from their imm
            // payloads (StringData/CharData), which is a different question
            // than spelling.
        }

        // string/char literals, doc comments, and anything unlisted: the
        // source bytes are the spelling.
        //
        // THIS is dead-code, the default branch handles it, but we keep it here for clarity.
    }

    /// \brief null-tolerant spelling accessor for scanners that resolve the imm
    ///        table per token (PP scanners hold only a tcm, not a fixed table).
    ///
    /// \details identical to \c resolve().get_text() when \p tbl is non-null;
    ///          falls back to raw source when the table can't be reached (e.g.
    ///          a token whose range doesn't map to a live fid). For raw lexed
    ///          identifiers the two agree, so this is behavior-neutral today and
    ///          becomes the correct path once expansion can synthesize tokens.
    pub static fn spelling(tok: Token, tcm: unsafe *TokenCacheManager) -> string {
        eval if defined!(DEBUG) {
            if !(tcm != &null) {
                kairo::std::ice_fail(
                    r"TokenCacheManager is null in TokenText::spelling",
                )
            }
        }

        var unsafe *tbl = tcm->get_imm_table_for_token(tok)
        var unsafe *sm  = tcm->get_source_manager()

        if tbl == &null {
            return sm->get_text(tok.range)
        }

        return *TokenText::resolve(tok, tcm).get_text()
    }

    /// \brief raw source slice for a RANGE (not a token).
    pub static fn from_range(range: SourceRange, sm: unsafe *SourceManager) -> TokenText {
        eval if defined!(DEBUG) {
            if !(sm != &null) {
                kairo::std::ice_fail(
                    r"SourceManager is null in TokenText::from_range",
                )
            }
        }

        return TokenText(sm->get_text(range), range, false, false)
    }

    /// \brief a view of the spelled text, not a copy.
    /// \details Callers that keep the text past the owning TokenText, or
    ///          change it, must copy it: `var s = *tt.get_text();`. Most
    ///          callers read it off a temporary (`TokenText::resolve(..)
    ///          .get_text()`), where the view lives to the end of the full
    ///          expression, which is as long as they use it.
    pub fn get_text(const self) -> unsafe *const string {
        return unsafe &self.text
    }

    fn get_range(self) -> SourceRange {
        return self.range
    }

    fn is_macro_expansion(self) -> bool {
        return self.is_expand
    }

    fn is_macro_marker(self) -> bool {
        return self.is_marker
    }
}
