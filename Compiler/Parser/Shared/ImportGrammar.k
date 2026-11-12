/// --- The Kairo Project ---------------- Parser/Shared/ImportGrammar.k --- ///
///
///   The one import grammar, shared by the parser and the preprocessor.
///
///   One implementation, multiple drivers: the parser (DeclParse) and the
///   preprocessor (PPWalker, and DepScanner through StreamCursor) all walk
///   imports through it.
///
///   Produces a neutral ImportSpec. Drivers map it to their output type
///   (ImportDecl at the parser).
///
///   CRTP host contract (T must provide):
///     fn ig_kind(self)      -> TokenKind   // resolved kind of current token
///     fn ig_peek_kind(self) -> TokenKind   // resolved kind of next token
///     fn ig_tok(self)       -> Token       // current token, by copy
///     fn ig_bump(self)                     // advance one token
///     fn ig_bump_nl(self)                  // advance one, then skip newlines
///     fn ig_eof(self)       -> bool
///     fn ig_err(self, r: SourceRange, msg: string, code: DiagID)
///     fn ig_err_remove(self, r: SourceRange, msg: string, code: DiagID,
///                   cut: SourceRange, fix_msg: string) // + removal fix-it
///     fn ig_err_insert(self, r: SourceRange, msg: string, code: DiagID,
///                   at: SourceRange, text: string, fix_msg: string) // + insertion fix-it
///
///   The grammar does NOT consume a trailing `;` and does NOT handle visibility
///   prefixes or `ffi` -- both are the caller's.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "vector"

import AST::Node::Declarations::ImportKind
import Diagnostic::Registry::DiagID
import Location::SourceRange::SourceRange
import Token::Token::Token
import Token::TokenKind::TokenKind
import Token::TokenKind::is_annotation
import Token::TokenKind::token_kind_to_readable_string

pub struct ImportSpecItem {
    pub var sub_path:    cxx::std::vector<Token> ///< path segments relative to base
    pub var alias:       Token ///< `as <name>`; meaningful iff has_alias
    pub var has_alias:   bool                    = false
    pub var is_macro:    bool                    = false ///< trailing `!` on the item (mac!)
    pub var is_wildcard: bool                    = false ///< `*` inside the brace list
    pub var range:       SourceRange             = SourceRange::invalid()
}

pub struct ImportSpec {
    pub var segments:    cxx::std::vector<Token> ///< base path (RAW: includes last seg)
    pub var items:       cxx::std::vector<ImportSpecItem>
    pub var alias:       Token ///< top-level `as`; iff has_alias
    pub var has_alias:   bool                             = false
    pub var has_items:   bool                             = false
    pub var is_wildcard: bool                             = false ///< `import Foo::*`
    /// Where the path is looked for: the search roots (`import foo`), the
    /// importing file's directory (`import self::foo`) or its module root
    /// (`import module::foo`). The anchor keyword is never a segment.
    pub var kind:              ImportKind  = ImportKind::Native
    pub var last_seg_is_macro: bool        = false ///< `import Foo::mac!` (bang on last seg)
    pub var range:             SourceRange = SourceRange::invalid()
    pub var ok:                bool        = false
}

// TODO(DUCK-GENERIC): T uses ig_bump, ig_bump_nl, ig_eof, ig_err, ig_err_remove, ig_kind, ig_peek_kind, ig_tok. Stage 0 was duck-typed; bound it or keep `: type`.
/// \brief true for a token that can be an import path segment: a name, or a
///        primitive type's word.
///
/// \details A segment names a FILE or a declaration in one, and a file may be
///          called `f8.k`, `i32.k` or `bool.k`: the word lexes as a type
///          keyword, and refusing it made such a file impossible to import
///         . Only where the word would become the BOUND name does it
///          clash with the type (_check_bound_word).
pub fn is_import_path_word(k: TokenKind) -> bool {
    return k == TokenKind::LitIdentifier || (is_annotation(k) && k != TokenKind::AtComment)
}

pub class <T: type> ImportGrammar {
    priv inline fn igd(self) -> unsafe *T {
        return unsafe ((&self) as *T)
    }

    /// \brief S046E when a primitive type's word would be the name an import
    ///        binds: `import self::i32` binds `i32`, and `i32::f()` reads as
    ///        the type, never the module. Fix-it: an `as` name after it.
    /// \p kind is the word's RESOLVED kind (ig_kind when it was read): a
    /// segment a macro expanded is a wrapper token whose own kind says
    /// nothing about the word.
    priv fn _check_bound_word(self, word: Token, kind: TokenKind) {
        if kind == TokenKind::LitIdentifier {
            return
        }

        var w = token_kind_to_readable_string(kind)
        self.igd()->ig_err_insert(
            word.range,
            f"an import cannot bind the name '{w}': it is a primitive type, so '{w}::' names the type, not this module; give it another name with 'as', or import its contents with '::*'",
            DiagID::S046E,
            SourceRange(word.range.end, word.range.end),
            f" as {w}_mod",
            f"bind it as '{w}_mod'",
        )
    }

    /// \brief parses one import statement. Precondition: current token is
    ///        `import` (caller verified; visibility already consumed by caller).
    pub fn parse_import_spec(self) -> ImportSpec {
        var spec = ImportSpec()

        // `import`
        var kw    = self.igd()->ig_tok()
        var start = kw.range
        var last  = kw.range
        self.igd()->ig_bump_nl()

        // Anchor: `self::` or `module::` picks the one place the path is
        // looked for (Compiler/Spec/Imports.md#import-forms). Neither keyword
        // becomes a segment, so everything downstream of the spec -- the
        // bound name, file_seg_count, the symbol walk -- reads the path
        // exactly as it reads a plain import's.
        var ak = self.igd()->ig_kind()
        if (ak == TokenKind::KwSelf || ak == TokenKind::KwModule)
            && self.igd()->ig_peek_kind() == TokenKind::OpColonColon {
            spec.kind = if (ak == TokenKind::KwSelf) => (ImportKind::SelfRelative)
                        else => ImportKind::ModuleRelative
            last = self.igd()->ig_tok().range
            self.igd()->ig_bump_nl() // consume the anchor
            last = self.igd()->ig_tok().range
            self.igd()->ig_bump_nl() // consume `::`
            if !is_import_path_word(self.igd()->ig_kind()) {
                var anchor_kw = if (ak == TokenKind::KwSelf) => ("self") else => "module"
                self.igd()->ig_err(
                    start | last,
                    f"expected a module path after '{anchor_kw}::'",
                    DiagID::S046E,
                )

                spec.range = start | last
                return spec // ok = false
            }
        } else if ak == TokenKind::KwModule {
            // The removed `import module foo`. It forced the directory form
            // (foo/module.k); each import form looks in exactly one
            // place, so the plain path says the same thing. Parsed on as a
            // plain import, so the one error is all this line reports.
            var mod_tok = self.igd()->ig_tok()
            self.igd()->ig_bump_nl()
            var cut = SourceRange::from_bounds(
                mod_tok.range.start,
                self.igd()->ig_tok().range.start,
            )

            self.igd()->ig_err_remove(
                mod_tok.range,
                "'import module foo' was removed; write 'import foo' (a library or -I path), 'import self::foo' (beside this file) or 'import module::foo' (from this module's root)",
                DiagID::S089E,
                cut,
                "remove 'module'",
            )
        }

        // first path segment
        if !is_import_path_word(self.igd()->ig_kind()) {
            self.igd()->ig_err(
                start,
                "expected a module or symbol path after 'import'",
                DiagID::S046E,
            )

            spec.range = start | last
            return spec // ok = false
        }

        var last_kind = self.igd()->ig_kind() // the last segment's resolved kind
        spec.segments.push_back(self.igd()->ig_tok())
        last = self.igd()->ig_tok().range
        self.igd()->ig_bump()

        // optional bang on a single-segment macro import: `import mac!`
        if self.igd()->ig_kind() == TokenKind::OpExclaim {
            spec.last_seg_is_macro = true
            last                   = self.igd()->ig_tok().range
            self.igd()->ig_bump()
        }

        // `::`-separated continuation
        while self.igd()->ig_kind() == TokenKind::OpColonColon && !spec.last_seg_is_macro {
            var pk = self.igd()->ig_peek_kind()

            if pk == TokenKind::OpLBrace {
                self.igd()->ig_bump_nl() // consume `::`
                last = self.igd()->ig_tok().range
                self.igd()->ig_bump_nl() // consume `{`
                self._parse_item_list(&spec, &last)
                spec.has_items = spec.items.size() > 0
                break
            }

            if pk == TokenKind::OpStar {
                self.igd()->ig_bump_nl() // consume `::`
                spec.is_wildcard = true
                last             = self.igd()->ig_tok().range
                self.igd()->ig_bump() // consume `*`
                break
            }

            if !is_import_path_word(pk) {
                break // `::` followed by junk path ends; caller's problem
            }

            self.igd()->ig_bump_nl() // consume `::`
            last_kind = self.igd()->ig_kind()
            spec.segments.push_back(self.igd()->ig_tok())
            last = self.igd()->ig_tok().range
            self.igd()->ig_bump()

            if self.igd()->ig_kind() == TokenKind::OpExclaim {
                spec.last_seg_is_macro = true
                last                   = self.igd()->ig_tok().range
                self.igd()->ig_bump()
                // loop guard exits on next iteration: `mac!::x` is illegal
            }
        }

        // top-level alias: `as name` (with optional `!` for macro aliases)
        if self.igd()->ig_kind() == TokenKind::KwAs {
            self.igd()->ig_bump_nl()
            if self.igd()->ig_kind() == TokenKind::LitIdentifier {
                spec.alias     = self.igd()->ig_tok()
                spec.has_alias = true
                last           = self.igd()->ig_tok().range
                self.igd()->ig_bump()
                if spec.last_seg_is_macro && self.igd()->ig_kind() == TokenKind::OpExclaim {
                    last = self.igd()->ig_tok().range
                    self.igd()->ig_bump()
                }
            } else {
                self.igd()->ig_err(
                    self.igd()->ig_tok().range,
                    "expected a name after 'as' in import declaration",
                    DiagID::S046E,
                )
            }
        }

        if !spec.has_alias && !spec.has_items && !spec.is_wildcard && spec.segments.size() > 0 {
            self._check_bound_word(spec.segments[spec.segments.size() - 1], last_kind)
        }

        spec.range = start | last
        spec.ok    = true
        return spec
    }

    /// \brief selective import list: past the `{`, consumes through `}`.
    priv fn _parse_item_list(self, spec: *ImportSpec, last: *SourceRange) {
        var open = *last

        while !self.igd()->ig_eof() {
            var k = self.igd()->ig_kind()

            if k == TokenKind::OpRBrace {
                *last = self.igd()->ig_tok().range
                self.igd()->ig_bump()
                return
            }

            if k == TokenKind::TkNewLine || k == TokenKind::OpComma {
                self.igd()->ig_bump()
                continue
            }

            // wildcard item: `{*, ...}`
            if k == TokenKind::OpStar {
                var item = ImportSpecItem()
                item.is_wildcard = true
                item.range       = self.igd()->ig_tok().range
                *last            = item.range
                self.igd()->ig_bump()
                spec->items.push_back(item)
                continue
            }

            if !is_import_path_word(k) {
                self.igd()->ig_err(
                    self.igd()->ig_tok().range,
                    "expected an import item name or '*' in selective import list",
                    DiagID::S046E,
                )

                self.igd()->ig_bump() // forward progress; outer recovery owns the rest
                continue
            }

            // named item: ident (:: ident)* !? (as alias !?)?
            var item       = ImportSpecItem()
            var item_start = self.igd()->ig_tok().range
            var item_kind = self.igd()->ig_kind() // the last sub-path segment's resolved kind
            item.sub_path.push_back(self.igd()->ig_tok())
            *last = self.igd()->ig_tok().range
            self.igd()->ig_bump()

            while self.igd()->ig_kind() == TokenKind::OpColonColon
                && is_import_path_word(self.igd()->ig_peek_kind()) {
                self.igd()->ig_bump_nl()
                item_kind = self.igd()->ig_kind()
                item.sub_path.push_back(self.igd()->ig_tok())
                *last = self.igd()->ig_tok().range
                self.igd()->ig_bump()
            }

            if self.igd()->ig_kind() == TokenKind::OpExclaim {
                item.is_macro = true
                *last         = self.igd()->ig_tok().range
                self.igd()->ig_bump()
            }

            if self.igd()->ig_kind() == TokenKind::KwAs {
                self.igd()->ig_bump_nl()
                if self.igd()->ig_kind() == TokenKind::LitIdentifier {
                    item.alias     = self.igd()->ig_tok()
                    item.has_alias = true
                    *last          = self.igd()->ig_tok().range
                    self.igd()->ig_bump()
                    if item.is_macro && self.igd()->ig_kind() == TokenKind::OpExclaim {
                        *last = self.igd()->ig_tok().range
                        self.igd()->ig_bump()
                    }
                } else {
                    self.igd()->ig_err(
                        self.igd()->ig_tok().range,
                        "expected a name after 'as' in import item",
                        DiagID::S046E,
                    )
                }
            }

            if !item.has_alias {
                self._check_bound_word(item.sub_path[item.sub_path.size() - 1], item_kind)
            }

            item.range = item_start | *last
            spec->items.push_back(item)
        }

        // EOF before `}`
        self.igd()->ig_err(open, "expected '}' to close the selective import list", DiagID::S051E)
    }
}
