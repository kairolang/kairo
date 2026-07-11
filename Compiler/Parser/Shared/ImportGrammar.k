/// --- The Kairo Project ---------------- Parser/Shared/ImportGrammar.k --- ///
///
///   THE import grammar. One implementation, multiple drivers.
///
///   Replaces the token-walking logic of:
///     - DeclParse::_parse_import          (structure was canonical)
///     - ImportProcessor::parse_import     (macro-bang handling was canonical)
///     - ImportProcessor::parse_grouped_imports
///     - DepScanner::scan_import
///
///   Produces a neutral ImportSpec. Drivers map it to their output type
///   (ImportDecl at the parser, ParsedImport in the PP until step 4).
///
///   CRTP host contract (T must provide):
///     fn ig_kind(self)      -> TokenKind   // resolved kind of current token
///     fn ig_peek_kind(self) -> TokenKind   // resolved kind of next token
///     fn ig_tok(self)       -> Token       // current token, by copy
///     fn ig_bump(self)                     // advance one token
///     fn ig_bump_nl(self)                  // advance one, then skip newlines
///     fn ig_eof(self)       -> bool
///     fn ig_err(self, r: SourceRange, msg: string, code: DiagID)
///
///   The grammar does NOT consume a trailing `;` and does NOT handle
///   visibility prefixes or `ffi` both are the caller's.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

import Token::Token::*;
import Token::TokenKind::*;
import Location::SourceRange::*;
import Diagnostic::Registry::*;

struct ImportSpecItem {
    var sub_path:  vec::<Token>;   ///< path segments relative to base
    var alias:     Token;          ///< `as <name>`; meaningful iff has_alias
    var has_alias: bool = false;
    var is_macro:  bool = false;   ///< trailing `!` on the item (mac!)
    var is_wildcard: bool = false; ///< `*` inside the brace list
    var range:     SourceRange = SourceRange::invalid();
}

struct ImportSpec {
    var segments:          vec::<Token>;  ///< base path (RAW: includes last seg)
    var items:             vec::<ImportSpecItem>;
    var alias:             Token;         ///< top-level `as`; iff has_alias
    var has_alias:         bool = false;
    var has_items:         bool = false;
    var is_wildcard:       bool = false;  ///< `import Foo::*`
    var is_module:         bool = false;  ///< `import module Foo`
    var last_seg_is_macro: bool = false;  ///< `import Foo::mac!` (bang on last seg)
    var range:             SourceRange = SourceRange::invalid();
    var ok:                bool = false;
}

class <T> ImportGrammar {
    priv inline fn igd(self) -> *T { return static_cast::<*T>(&self); }

    /// \brief parses one import statement. Precondition: current token is
    ///        `import` (caller verified; visibility already consumed by caller).
    fn parse_import_spec(self) -> ImportSpec {
        var spec = ImportSpec();

        // `import`
        var kw = igd()->ig_tok();
        var start = kw.range;
        var last  = kw.range;
        igd()->ig_bump_nl();

        // `module` qualifier
        if igd()->ig_kind() == TokenKind::KwModule {
            last = igd()->ig_tok().range;
            spec.is_module = true;
            igd()->ig_bump_nl();
        }

        // first path segment
        if igd()->ig_kind() != TokenKind::LitIdentifier {
            igd()->ig_err(start,
                "expected a module or symbol path after 'import\x27",
                DiagID::S046E);
            spec.range = start | last;
            return spec; // ok = false
        }
        spec.segments.push_back(igd()->ig_tok());
        last = igd()->ig_tok().range;
        igd()->ig_bump();

        // optional bang on a single-segment macro import: `import mac!`
        if igd()->ig_kind() == TokenKind::OpExclaim {
            spec.last_seg_is_macro = true;
            last = igd()->ig_tok().range;
            igd()->ig_bump();
        }

        // `::`-separated continuation
        while (igd()->ig_kind() == TokenKind::OpColonColon)
           && (!spec.last_seg_is_macro) {
            var pk = igd()->ig_peek_kind();

            if pk == TokenKind::OpLBrace {
                igd()->ig_bump_nl();                // consume `::`
                last = igd()->ig_tok().range;
                igd()->ig_bump_nl();                // consume `{`
                self._parse_item_list(&spec, &last);
                spec.has_items = spec.items.size() > 0;
                break;
            }

            if pk == TokenKind::OpStar {
                igd()->ig_bump_nl();                // consume `::`
                spec.is_wildcard = true;
                last = igd()->ig_tok().range;
                igd()->ig_bump();                   // consume `*`
                break;
            }

            if pk != TokenKind::LitIdentifier {
                break; // `::` followed by junk path ends; caller's problem
            }

            igd()->ig_bump_nl();                    // consume `::`
            spec.segments.push_back(igd()->ig_tok());
            last = igd()->ig_tok().range;
            igd()->ig_bump();

            if igd()->ig_kind() == TokenKind::OpExclaim {
                spec.last_seg_is_macro = true;
                last = igd()->ig_tok().range;
                igd()->ig_bump();
                // loop guard exits on next iteration: `mac!::x` is illegal
            }
        }

        // top-level alias: `as name` (with optional `!` for macro aliases)
        if igd()->ig_kind() == TokenKind::KwAs {
            igd()->ig_bump_nl();
            if igd()->ig_kind() == TokenKind::LitIdentifier {
                spec.alias     = igd()->ig_tok();
                spec.has_alias = true;
                last = igd()->ig_tok().range;
                igd()->ig_bump();
                if spec.last_seg_is_macro
                && (igd()->ig_kind() == TokenKind::OpExclaim) {
                    last = igd()->ig_tok().range;
                    igd()->ig_bump();
                }
            } else {
                igd()->ig_err(igd()->ig_tok().range,
                    "expected a name after 'as' in import declaration",
                    DiagID::S046E);
            }
        }

        spec.range = start | last;
        spec.ok    = true;
        return spec;
    }

    /// \brief selective import list: past the `{`, consumes through `}`.
    priv fn _parse_item_list(self, spec: *ImportSpec, last: *SourceRange) {
        var open = *last;

        while !igd()->ig_eof() {
            var k = igd()->ig_kind();

            if k == TokenKind::OpRBrace {
                (*last) = igd()->ig_tok().range;
                igd()->ig_bump();
                return;
            }

            if (k == TokenKind::TkNewLine) || (k == TokenKind::OpComma) {
                igd()->ig_bump();
                continue;
            }

            // wildcard item: `{*, ...}`
            if k == TokenKind::OpStar {
                var item = ImportSpecItem();
                item.is_wildcard = true;
                item.range = igd()->ig_tok().range;
                (*last) = item.range;
                igd()->ig_bump();
                spec->items.push_back(item);
                continue;
            }

            if k != TokenKind::LitIdentifier {
                igd()->ig_err(igd()->ig_tok().range,
                    "expected an import item name or '*' in selective import list",
                    DiagID::S046E);
                igd()->ig_bump(); // forward progress; outer recovery owns the rest
                continue;
            }

            // named item: ident (:: ident)* !? (as alias !?)?
            var item = ImportSpecItem();
            var item_start = igd()->ig_tok().range;
            item.sub_path.push_back(igd()->ig_tok());
            (*last) = igd()->ig_tok().range;
            igd()->ig_bump();

            while (igd()->ig_kind() == TokenKind::OpColonColon)
               && (igd()->ig_peek_kind() == TokenKind::LitIdentifier) {
                igd()->ig_bump_nl();
                item.sub_path.push_back(igd()->ig_tok());
                (*last) = igd()->ig_tok().range;
                igd()->ig_bump();
            }

            if igd()->ig_kind() == TokenKind::OpExclaim {
                item.is_macro = true;
                (*last) = igd()->ig_tok().range;
                igd()->ig_bump();
            }

            if igd()->ig_kind() == TokenKind::KwAs {
                igd()->ig_bump_nl();
                if igd()->ig_kind() == TokenKind::LitIdentifier {
                    item.alias     = igd()->ig_tok();
                    item.has_alias = true;
                    (*last) = igd()->ig_tok().range;
                    igd()->ig_bump();
                    if item.is_macro
                    && (igd()->ig_kind() == TokenKind::OpExclaim) {
                        (*last) = igd()->ig_tok().range;
                        igd()->ig_bump();
                    }
                } else {
                    igd()->ig_err(igd()->ig_tok().range,
                        "expected a name after 'as' in import item",
                        DiagID::S046E);
                }
            }

            item.range = item_start | (*last);
            spec->items.push_back(item);
        }

        // EOF before `}`
        igd()->ig_err(open,
            "expected '}' to close the selective import list",
            DiagID::S051E);
    }
}