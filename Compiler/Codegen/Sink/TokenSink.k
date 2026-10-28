/// --- The Kairo Project --------------------- Codegen/Sink/TokenSink.k --- ///
///
///   \brief THE place clang::Token is constructed. Emitters call the EmitSink
///          accumulators; nothing else in the compiler builds a clang token.
///
///   \par The three families, and why they are three
///     What separates them is NOT whether the C++ spelling matches the Kairo
///     bytes. It is whether clang ever READS those bytes:
///
///       punctuators   spelling comes from the KIND          length is free
///       ident/keyword spelling comes from the IdentifierInfo length is free
///       literals      spelling is getCharacterData(loc) +    length IS the
///                     getLength() bytes                      spelling
///
///     A token's length is CARET GEOMETRY, not spelling. That is what lets
///     `fn` become kw_auto with length 2, and what lets a preamble token
///     spelled `class` borrow a Kairo class name's span: nothing reads the
///     bytes, so the caret lands on what the user wrote.
///
///   \par Locations are any registered fid
///     A preamble declaration for `geo::vec::Vec2` borrows Vec2's own span,
///     which lives in another file. ClangLocMap::rebind registers EVERY
///     Kairo fid before this sink exists, so a location is translated
///     through the map (one resolve, one add) rather than through a single
///     per-file delta. Out-of-map is an emitter bug: ICE, never clamp.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "llvm/ADT/StringMap.h";
ffi "c++" import "llvm/ADT/DenseSet.h";
ffi "c++" import "clang/Basic/SourceManager.h";
ffi "c++" import "clang/Basic/SourceLocation.h";
ffi "c++" import "clang/Basic/TokenKinds.h";
ffi "c++" import "clang/Lex/Preprocessor.h";
ffi "c++" import "clang/Lex/Token.h";

import Memory::ArenaAllocator::*;
import Memory::ArenaList::*;
import Location::SourceLocation::*;
import Location::SourceRange::*;
import Token::Token::*;
import Token::TokenKind::*;
import Interop::Clang::ClangLocMap::*;
import Codegen::Sink::EmitSink::*;

/// One divergent-literal token awaiting its real ExpansionLoc. Recorded at
/// emit time (phase 1), consumed by patch_pending (phase 2).
///
/// Each entry opens an expansion of its own unless \c entry_len is 0: then
/// the token sits inside the expansion the entry before it opened, at its
/// own offset there (TokenSink::_pair). An expansion is a FileID, and one
/// FileID is what clang asks of the two halves of a pair it checks.
struct PendingArenaTok {
    var tok_index: usize;           ///< index into _tokens
    var arena_off: u32;             ///< offset of the C++ spelling in _arena_text
    var arena_len: u32;             ///< length of the C++ spelling
    var kro_start: SourceLocation;  ///< .kro expansion start
    var kro_len:   u32;             ///< .kro span length
    var entry_len: u32;             ///< bytes of the expansion this opens; 0 joins the previous one
}

/// A token holding a file byte it was not anchored on exactly (TokenSink::
/// _claim): which token, and the anchor it would claim from again if a
/// declaration's name needs that byte back.
struct HeldByte {
    var tok:    usize;
    var anchor: SourceLocation;
    var len:    u32;
}

class TokenSink derives EmitSink {
    priv var _pp:     obs::<clang::Preprocessor>;
    priv var _csm:    obs::<clang::SourceManager>;
    priv var _locmap: obs::<ClangLocMap>;
    priv var _cfid:   clang::FileID;   ///< clang FileID of the TU being emitted
    priv var _kfid:   FileID;          ///< Kairo fid of the TU being emitted
    priv var _kbase:  u32 = 0;         ///< Kairo raw loc of byte 0 of this file (eof anchor)
    priv var _ksize:  u32 = 0;

    priv var _tokens:  ArenaList::<clang::Token>;
    priv var _pending: ArenaList::<PendingArenaTok>;

    priv var _arena_text: libcxx::string;
    priv var _dedup:      llvm::StringMap::<u32>;   ///< probed with the spelling's own bytes: a hit allocates nothing.
    /// EmitSink::unanchored: every token goes to the arena.
    priv var _unanchored: bool = false;
    /// Every punctuator goes to the arena, so its location's bytes are its
    /// spelling. Only a printer reads them -- the parser takes a punctuator
    /// from its kind -- so this is for `-E` (Backend/IncludeEmitter.k).
    pub var arena_puncts: bool = false;
    /// Kairo raw locations already given to a borrowed token. A second token
    /// at one of them moves within its anchor, or to the arena: see _claim.
    /// Raw locations, WIDENED to u64: the claim walk runs across the raw
    /// space unfiltered, and a u32 key could land on DenseSet's reserved
    /// 0xFFFFFFFF / 0xFFFFFFFE. Zero-extended, it never can.
    priv var _used:       llvm::DenseSet::<u64>;
    /// The bytes in _used held by a token that is not the exact spelling of
    /// its anchor (an index into _held_list), so an exact one can take them
    /// back (_steal). Keyed as _used is.
    priv var _held:       llvm::DenseMap::<u64, u64>;
    priv var _held_list:  vec::<HeldByte>;
    priv var _sealed:     bool = false;
    /// The last punctuator, while it is still the last token: one past its
    /// index (0 for none), its anchor, and the byte it claimed (invalid when
    /// it went to the arena). _pair reads them to place the second half of
    /// a checked pair, and may move this token to the arena after the fact.
    priv var _open_end:  usize = 0;
    priv var _open_loc:  SourceLocation;
    priv var _open_len:  u32 = 0;
    priv var _open_byte: SourceLocation;
    /// System headers the stream needs (system_header), for KairoInject to
    /// enter ahead of it: a token stream has no line for an #include.
    pub var system_headers: vec::<string>;

    fn TokenSink(self, pp: *clang::Preprocessor, csm: *clang::SourceManager,
                 locmap: *ClangLocMap, cfid: clang::FileID, kfid: FileID, ksize: u32,
                 arena: *ArenaAllocator) {
        ICE_IF(locmap == &null, "TokenSink: no ClangLocMap");
        ICE_IF(!locmap->ready(), "TokenSink: ClangLocMap not rebound; construct the sink inside the action window");
        self._pp     = pp;
        self._csm    = csm;
        self._locmap = locmap;
        self._cfid   = cfid;
        self._kfid   = kfid;
        self._kbase  = locmap->kairo_base(kfid);
        self._ksize  = ksize;

        self._tokens.set_allocator(arena, 512);
        self._pending.set_allocator(arena, 64);
        self._arena_text.reserve(4096);
    }

    /// # Conversions

    /// Kairo punctuator/operator TokenKind -> clang punctuator kind. 1:1,
    /// lexical, no judgement. clang::tok::unknown for anything unmapped.
    fn conv_kind(self, k: TokenKind) -> clang::tok::TokenKind {
        switch k {
            case TokenKind::OpLParen           { return clang::tok::l_paren;        }
            case TokenKind::OpRParen           { return clang::tok::r_paren;        }
            case TokenKind::OpLBrace           { return clang::tok::l_brace;        }
            case TokenKind::OpRBrace           { return clang::tok::r_brace;        }
            case TokenKind::OpLSquare          { return clang::tok::l_square;       }
            case TokenKind::OpRSquare          { return clang::tok::r_square;       }
            case TokenKind::OpSemicolon        { return clang::tok::semi;           }
            case TokenKind::OpComma            { return clang::tok::comma;          }
            case TokenKind::OpColon            { return clang::tok::colon;          }
            case TokenKind::OpColonColon       { return clang::tok::coloncolon;     }
            case TokenKind::OpDot              { return clang::tok::period;         }
            case TokenKind::OpArrow            { return clang::tok::arrow;          }
            case TokenKind::OpEllipsis         { return clang::tok::ellipsis;       }
            case TokenKind::OpPlus             { return clang::tok::plus;           }
            case TokenKind::OpMinus            { return clang::tok::minus;          }
            case TokenKind::OpStar             { return clang::tok::star;           }
            case TokenKind::OpSlash            { return clang::tok::slash;          }
            case TokenKind::OpPercent          { return clang::tok::percent;        }
            case TokenKind::OpPlusPlus         { return clang::tok::plusplus;       }
            case TokenKind::OpMinusMinus       { return clang::tok::minusminus;     }
            case TokenKind::OpEqualEqual       { return clang::tok::equalequal;     }
            case TokenKind::OpExclaimEqual     { return clang::tok::exclaimequal;   }
            case TokenKind::OpLess             { return clang::tok::less;           }
            case TokenKind::OpGreater          { return clang::tok::greater;        }
            case TokenKind::OpLessEqual        { return clang::tok::lessequal;      }
            case TokenKind::OpGreaterEqual     { return clang::tok::greaterequal;   }
            case TokenKind::OpLessEqualGreater { return clang::tok::spaceship;      }
            case TokenKind::OpAmpAmp           { return clang::tok::ampamp;         }
            case TokenKind::OpPipePipe         { return clang::tok::pipepipe;       }
            case TokenKind::OpExclaim          { return clang::tok::exclaim;        }
            case TokenKind::OpAmp              { return clang::tok::amp;            }
            case TokenKind::OpPipe             { return clang::tok::pipe;           }
            case TokenKind::OpCaret            { return clang::tok::caret;          }
            case TokenKind::OpTilde            { return clang::tok::tilde;          }
            case TokenKind::OpLessLess         { return clang::tok::lessless;       }
            case TokenKind::OpGreaterGreater   { return clang::tok::greatergreater; }
            case TokenKind::OpEqual            { return clang::tok::equal;          }
            case TokenKind::OpPlusEqual        { return clang::tok::plusequal;      }
            case TokenKind::OpMinusEqual       { return clang::tok::minusequal;     }
            case TokenKind::OpStarEqual        { return clang::tok::starequal;      }
            case TokenKind::OpSlashEqual       { return clang::tok::slashequal;     }
            case TokenKind::OpPercentEqual     { return clang::tok::percentequal;   }
            case TokenKind::OpAmpEqual         { return clang::tok::ampequal;       }
            case TokenKind::OpPipeEqual        { return clang::tok::pipeequal;      }
            case TokenKind::OpCaretEqual       { return clang::tok::caretequal;     }
            case TokenKind::AtVoid             { return clang::tok::kw_void;        }
            default { return clang::tok::unknown; }
        }
    }

    /// Kairo loc -> clang loc, any registered fid. Invalid means an
    /// unregistered fid (loaded after rebind) or a synthesized node whose
    /// lowered-from range was never stamped: emitter bug, ICE.
    priv fn _loc(self, loc: SourceLocation) -> clang::SourceLocation {
        ICE_IF(!loc.is_valid(), "TokenSink: invalid Kairo location; a synthesized node must carry its lowered-from range");
        var c = self._locmap->to_clang(loc);
        if (c.isInvalid()) { self.ice_at(SourceRange::from_bounds(loc, u32(1)), f"TokenSink: Kairo loc {loc.raw()} maps to no clang location (fid loaded after rebind?)"); }
        return c;
    }

    /// The bytes at \p loc in whichever registered file it lives in.
    priv fn _bytes(self, loc: SourceLocation, len: u32) -> llvm::StringRef {
        var cloc = self._loc(loc);
        var dec  = self._csm->getDecomposedLoc(cloc);
        var buf  = self._csm->getBufferData(dec.first);
        if (static_cast::<usize>(dec.second) + static_cast::<usize>(len) > buf.size()) { self.ice_at(SourceRange::from_bounds(loc, len), "TokenSink: span runs past the end of its buffer"); }
        return buf.substr(static_cast::<usize>(dec.second), static_cast::<usize>(len));
    }

    /// # EmitSink primitives

    override fn create(self, t: Token) -> bool {
        var len = t.range.size();
        if t.kind == TokenKind::LitIdentifier {
            return self._ident_from_bytes(t.range.start, len);
        }
        if (is_keyword(t.kind)) { self.ice_at(t.range, "TokenSink::create on a keyword token; emit it deliberately (kw_*) or let Lower/ rewrite it into a name"); }
        if ((!is_punctuator(t.kind)) && (!is_operator(t.kind)) && (t.kind != TokenKind::AtVoid)) { self.ice_at(t.range, "TokenSink::create accepts identifiers, punctuators and operators only"); }
        var k = self.conv_kind(t.kind);
        if (k == clang::tok::unknown) { self.ice_at(t.range, "TokenSink::create: no clang punctuator for this Kairo token kind; a Lower/ pass left an unlowered Kairo-only operator in the tree"); }
        return self._punct(k, t.range.start, len);
    }

    override fn create_ident(self, at: SourceRange, spelling: string) -> bool {
        return self._ident_lit(sref(spelling), at.start, at.size());
    }

    override fn punct(self, at: SourceRange, k: clang::tok::TokenKind) -> bool {
        return self._punct(k, at.start, at.size());
    }

    /// Kind AND IdentifierInfo: parser paths that call getIdentifierInfo()
    /// on a keyword would get null with the kind alone.
    override fn keyword(self, at: SourceRange, k: clang::tok::TokenKind) -> bool {
        var kws = clang::tok::getKeywordSpelling(k);
        if (kws == &null) { self.ice_at(at, "TokenSink::keyword: kind is not a keyword"); }
        return self._ident_lit(llvm::StringRef(kws, libcxx::strlen(kws)), at.start, at.size());
    }

    /// Borrowed literal: clang reads getLength() bytes at getLocation(), so
    /// the span must be the real spelling.
    override fn literal(self, at: SourceRange, k: clang::tok::TokenKind) -> bool {
        var bytes = self._bytes(at.start, at.size());
        var t = self._tokens.slot();
        t->startToken();
        t->setKind(k);
        var loc = self._loc(at.start);
        self._pp->CreateString(bytes, *t, loc, loc);
        return true;
    }

    override fn create_int(self, at: SourceRange, cxx: ref!(string)) -> bool {
        return self._arena_tok(clang::tok::numeric_constant, at, cxx);
    }

    /// \p cxx INCLUDES the quotes.
    override fn create_str(self, at: SourceRange, cxx: ref!(string)) -> bool {
        return self._arena_tok(clang::tok::string_literal, at, cxx);
    }

    /// \p cxx INCLUDES the quotes.
    override fn create_char(self, at: SourceRange, cxx: ref!(string)) -> bool {
        return self._arena_tok(clang::tok::char_constant, at, cxx);
    }

    /// Recorded, not emitted (system_headers); once per header.
    override fn unanchored(self, on: bool) { self._unanchored = on; }

    override fn system_header(self, at: SourceRange, name: string) -> bool {
        for var i: usize = 0; i < self.system_headers.size(); ++i {
            if self.system_headers[i] == name { return true; }
        }
        self.system_headers.push_back(name);
        return true;
    }

    /// End of stream. Zero length, anchored on the file's last byte.
    fn eof(self) -> bool {
        var last = self._kbase + self._ksize;
        if last > self._kbase { last = last - 1; }
        var t = self._tokens.slot();
        t->startToken();
        t->setKind(clang::tok::eof);
        t->setLocation(self._locmap->to_clang(self._locmap_loc(last)));
        t->setLength(0);
        return true;
    }

    /// A raw loc in THIS file as a SourceLocation. Only eof() needs it.
    priv fn _locmap_loc(self, raw: u32) -> SourceLocation {
        var base = self._locmap->kairo_base(self._kfid);
        var off  = static_cast::<usize>(raw - base);
        return self._locmap->ksm_loc(self._kfid, off);
    }

    /// # Construction internals

    /// \brief a location for a borrowed token anchored at [\p loc, +\p len):
    ///        \p loc itself when free, else the first free byte after it in
    ///        the same file, else invalid -- then the token must be an arena
    ///        token with its own expansion location.
    ///
    /// \details every token of one spell() string shares its anchor, so
    ///          `decltype(sizeof(0))` was seven tokens at ONE location. Clang
    ///          splices an annotation back into its backtracking cache by
    ///          searching for the token whose location equals the
    ///          annotation's start (Preprocessor::AnnotatePreviousCachedTokens).
    ///          With duplicates it matched the wrong one and corrupted the
    ///          stream, so any constructor taking a usize failed
    ///          ("expected function body after function declarator"): the
    ///          constructor-declarator check is a tentative parse, and it
    ///          annotates `decltype(...)`. A unique location per token is
    ///          the invariant; the caret still covers the same Kairo bytes.
    ///
    ///          Moving within the anchor comes before the arena: an arena
    ///          token is a MACRO location, and clang warns when the two halves
    ///          of a pair it checks (the `(` `{` opening a statement
    ///          expression) sit in different expansion contexts. Once the
    ///          bytes run out that cannot be avoided token by token, so _pair
    ///          places such halves together.
    ///
    ///          Past the anchor, the search walks on through the SAME file:
    ///          synthesized code reuses one source range for many nodes (an
    ///          f-string's whole lowering hangs off its literal), so a 1-byte
    ///          anchor is routinely taken, and landing a few bytes late keeps
    ///          the token a file location, and then backward from the anchor.
    ///          The file's own buffer bounds both -- the raw space runs on
    ///          into the neighbouring fids.
    ///
    ///          A NAME anchor (the whole span one identifier: a declaration's
    ///          name, CXXSpell::at) keeps its first byte for the token that
    ///          spells exactly that name (\p exact). That token's location is
    ///          the declaration's to clang -- "'Point' declared here" -- and
    ///          the wrapper and keywords anchored on the same name would
    ///          otherwise take the byte first and push it somewhere else in
    ///          the file. Only one exact token can have it; it goes to
    ///          whichever comes first, so a forward declaration anchors on
    ///          the decl's start instead (InterfaceEmitter::_fwd_decl).
    ///
    ///          The walk is not confined to the anchor, so a token anchored
    ///          EARLIER in the file can reach a later declaration's name byte
    ///          before that name is spelled: an ADT's definition is hundreds
    ///          of tokens, every one a byte further on. The exact token then
    ///          takes the byte back (_steal), and the token that held it
    ///          claims again from its own anchor. Without that, "member is
    ///          declared here" landed wherever the name's walk ended, lines
    ///          away from the field, and moved whenever the file did.
    priv fn _claim(self, loc: SourceLocation, len: u32, exact: bool = false) -> SourceLocation {
        return self._claim_for(loc, len, exact, self._tokens.size());
    }

    /// _claim for token \p tok: the next one, or one _steal is moving.
    priv fn _claim_for(self, loc: SourceLocation, len: u32, exact: bool, tok: usize) -> SourceLocation {
        if self._unanchored { return SourceLocation::invalid(); }
        var dec   = self._csm->getDecomposedLoc(self._loc(loc));
        var avail = self._csm->getBufferData(dec.first).size() - static_cast::<usize>(dec.second);
        var from: usize = 0;
        if (!exact) && self._is_name_span(loc, len) { from = 1; }
        if exact && (avail > 0) {
            if self._used.insert(static_cast::<u64>(loc.raw())).second { return loc; }
            if self._steal(loc) { return loc; }
        }
        for var i: usize = from; i < avail; ++i {
            var at  = loc.advance(i);
            if !self._used.insert(static_cast::<u64>(at.raw())).second { continue; }
            if !exact { self._hold(at, tok, loc, len); }
            return at;
        }
        // Then backward: a closer anchored near the end of a small file
        // finds every later byte taken by its own opener's run.
        var before = static_cast::<usize>(dec.second);
        for var i: usize = 1; i <= before; ++i {
            var at  = loc.with_offset(0 - static_cast::<i64>(i));
            if !self._used.insert(static_cast::<u64>(at.raw())).second { continue; }
            if !exact { self._hold(at, tok, loc, len); }
            return at;
        }
        // Last, the kept byte itself: a unique location beats the arena.
        if (from == 1) && self._used.insert(static_cast::<u64>(loc.raw())).second {
            self._hold(loc, tok, loc, len);
            return loc;
        }
        return SourceLocation::invalid();
    }

    priv fn _hold(self, at: SourceLocation, tok: usize, anchor: SourceLocation, len: u32) {
        var h = HeldByte{};
        h.tok    = tok;
        h.anchor = anchor;
        h.len    = len;
        self._held[static_cast::<u64>(at.raw())] = static_cast::<u64>(self._held_list.size());
        self._held_list.push_back(h);
    }

    /// The exact token's byte \p at, taken back from the inexact token that
    /// holds it, which claims again from its own anchor, or, in a file whose
    /// every byte is taken (a small file with a lot of C++ behind it: the
    /// common case, not the corner), goes to the arena as it would have had
    /// it found none in the first place. Never from an exact token (a
    /// forward declaration and its definition: the first keeps it), nor
    /// from the punctuator _pair may still move to the arena.
    priv fn _steal(self, at: SourceLocation) -> bool {
        var key = static_cast::<u64>(at.raw());
        var it  = self._held.find(key);
        if it == self._held.end() { return false; }
        var hi = it->second;
        var h  = self._held_list[static_cast::<usize>(hi)];
        if (self._open_end != 0) && ((h.tok + 1) == self._open_end) { return false; }
        self._held.erase(key);
        var moved = self._claim_for(h.anchor, h.len, false, h.tok);
        if !moved.is_valid() {
            if self._to_arena(h) { return true; }
            self._held[key] = hi;
            return false;
        }
        var t = self._tokens.get(h.tok);
        t->setLocation(self._loc(moved));
        t->setLength(self._rest(h.anchor, moved, h.len));
        return true;
    }

    /// Token \p h.tok, already emitted at a file byte, given an arena entry
    /// instead (_arena_tok after the fact; patch_pending places it). An
    /// identifier or keyword is spelled by its IdentifierInfo, a punctuator
    /// by its kind. Not a half of a pair _completes_pair checks: moved to a
    /// macro location alone, it would split its pair across contexts.
    priv fn _to_arena(self, h: HeldByte) -> bool {
        var t = self._tokens.get(h.tok);
        var k = t->getKind();
        if (h.tok > 0) && self._checked_pair(self._tokens.get(h.tok - 1)->getKind(), k) { return false; }
        if (h.tok + 1) < self._tokens.size() {
            if self._checked_pair(k, self._tokens.get(h.tok + 1)->getKind()) { return false; }
        } else if (k == clang::tok::l_paren) || (k == clang::tok::r_brace) || (k == clang::tok::l_square)
               || (k == clang::tok::r_square) || (k == clang::tok::coloncolon) {
            // The last token: what follows it, and so its pair, is not known yet.
            return false;
        }
        var ns = string();
        var ii = t->getIdentifierInfo();
        if ii != &null {
            var nm = ii->getName();
            ns = string(nm.data(), nm.size());
        } else {
            var ps = clang::tok::getPunctuatorSpelling(k);
            if ps == &null { return false; }
            ns = string(ps, libcxx::strlen(ps));
        }
        var alen = static_cast::<u32>(ns.size());
        var p = self._pending.slot();
        p->tok_index = h.tok;
        p->arena_off = self._intern(ns);
        p->arena_len = alen;
        p->kro_start = h.anchor;
        p->kro_len   = h.len;
        p->entry_len = alen;
        t->setLength(alen);
        return true;
    }

    /// [\p loc, +\p len) is one identifier (see _claim).
    priv fn _is_name_span(self, loc: SourceLocation, len: u32) -> bool {
        if len == 0 { return false; }
        var b = self._bytes(loc, len);
        for var i: usize = 0; i < b.size(); ++i {
            var c = b[i];
            var alpha = ((c >= 'a') && (c <= 'z')) || ((c >= 'A') && (c <= 'Z')) || (c == '_');
            var digit = (c >= '0') && (c <= '9');
            if (!alpha) && ((i == 0) || (!digit)) { return false; }
        }
        return true;
    }

    /// The caret length left for a token moved \p at - \p loc bytes into
    /// its anchor: the rest of the anchor, never zero.
    priv fn _rest(self, loc: SourceLocation, at: SourceLocation, len: u32) -> u32 {
        var moved = at.raw() - loc.raw();
        if moved >= len { return 1; }
        return len - moved;
    }

    priv fn _punct(self, k: clang::tok::TokenKind, loc: SourceLocation, len: u32) -> bool {
        if self._completes_pair(k) { return self._pair(k, loc, len); }
        var at = (SourceLocation::invalid()) if (self.arena_puncts) else (self._claim(loc, len));
        if !at.is_valid() {
            var p  = clang::tok::getPunctuatorSpelling(k);
            if (p == &null) { self.ice_at(SourceRange::from_bounds(loc, len), "TokenSink::_punct: kind has no punctuator spelling"); }
            var ns = string(p, libcxx::strlen(p));
            self._arena_tok(k, SourceRange::from_bounds(loc, len), ns);
            self._opened(loc, len, at);
            return true;
        }
        var t = self._tokens.slot();
        t->startToken();
        t->setKind(k);
        t->setLocation(self._loc(at));
        t->setLength(self._rest(loc, at, len));
        self._opened(loc, len, at);
        return true;
    }

    /// Remember the punctuator just emitted as a possible first half (see
    /// _completes_pair); \p at is its claimed byte, invalid for the arena.
    priv fn _opened(self, loc: SourceLocation, len: u32, at: SourceLocation) {
        self._open_end  = self._tokens.size();
        self._open_loc  = loc;
        self._open_len  = len;
        self._open_byte = at;
    }

    /// \brief whether \p k, as the next token, completes a pair with the
    ///        last one that clang checks for a split across contexts.
    ///
    /// \details the pairs of Parser::checkCompoundToken: `(` `{` and `}` `)`
    ///          around a statement expression, `[` `[` and `]` `]` around an
    ///          attribute (`[[noreturn]]` comes through spell()), `::` `*` in
    ///          a pointer to member. The same pairs elsewhere (`f({...})`,
    ///          `a[b[i]]`) get the same treatment, which costs nothing: it
    ///          only decides where a token's location lives.
    priv fn _completes_pair(self, k: clang::tok::TokenKind) -> bool {
        if (self._open_end == 0) || (self._open_end != self._tokens.size()) { return false; }
        return self._checked_pair(self._tokens.get(self._open_end - 1)->getKind(), k);
    }

    /// \p first then \p k is one of the pairs clang checks (_completes_pair).
    priv fn _checked_pair(self, first: clang::tok::TokenKind, k: clang::tok::TokenKind) -> bool {
        if (first == clang::tok::l_paren)    && (k == clang::tok::l_brace)  { return true; }
        if (first == clang::tok::r_brace)    && (k == clang::tok::r_paren)  { return true; }
        if (first == clang::tok::l_square)   && (k == clang::tok::l_square) { return true; }
        if (first == clang::tok::r_square)   && (k == clang::tok::r_square) { return true; }
        if (first == clang::tok::coloncolon) && (k == clang::tok::star)     { return true; }
        return false;
    }

    /// \brief the second half of a checked pair, in the first half's
    ///        location context.
    ///
    /// \details clang warns when either half is a macro location and the
    ///          two are in different FileIDs, and patch_pending gives every
    ///          arena token an expansion, so a FileID, of its own. Two file
    ///          bytes are one FileID: nothing to do. Otherwise both halves
    ///          become ONE expansion over their joined spelling (`({`), each
    ///          at its own offset in it: one FileID, and still a unique
    ///          location apiece (see _claim).
    ///
    ///          A first half that took the file's last free byte gives it
    ///          back and joins the arena: left where it was, it would be a
    ///          file location paired with a macro one.
    priv fn _pair(self, k: clang::tok::TokenKind, loc: SourceLocation, len: u32) -> bool {
        // A second half never opens another pair: `]` `]` `]` is a nested
        // subscript, not two attribute ends.
        self._open_end = 0;
        var first = self._tokens.size() - 1;
        if self._open_byte.is_valid() {
            var at = self._claim(loc, len);
            if at.is_valid() {
                var t = self._tokens.slot();
                t->startToken();
                t->setKind(k);
                t->setLocation(self._loc(at));
                t->setLength(self._rest(loc, at, len));
                return true;
            }
            self._used.erase(static_cast::<u64>(self._open_byte.raw()));
            self._held.erase(static_cast::<u64>(self._open_byte.raw()));
            var h = self._pending.slot();
            h->tok_index = first;
            h->kro_start = self._open_loc;
            h->kro_len   = self._open_len;
        }

        var a = clang::tok::getPunctuatorSpelling(self._tokens.get(first)->getKind());
        var b = clang::tok::getPunctuatorSpelling(k);
        var alen = static_cast::<u32>(libcxx::strlen(a));
        var blen = static_cast::<u32>(libcxx::strlen(b));
        var joined: libcxx::string;
        joined.append(a);
        joined.append(b);
        var ns  = string(joined.data(), joined.size());
        var off = self._intern(ns);

        ICE_IF((self._pending.size() == 0), "TokenSink::_pair: the first half has no arena entry");
        var head = self._pending.get(self._pending.size() - 1);
        ICE_IF((head->tok_index != first), "TokenSink::_pair: the first half has no arena entry");
        head->arena_off = off;
        head->arena_len = alen;
        head->entry_len = alen + blen;

        var t = self._tokens.slot();
        t->startToken();
        t->setKind(k);
        t->setLength(blen);

        var p = self._pending.slot();
        p->tok_index = self._tokens.size() - 1;
        p->arena_off = off + alen;
        p->arena_len = blen;
        p->kro_start = loc;
        p->kro_len   = len;
        p->entry_len = 0;
        return true;
    }

    priv fn _ident_from_bytes(self, loc: SourceLocation, len: u32) -> bool {
        return self._ident_lit(self._bytes(loc, len), loc, len);
    }

    /// The kind comes from the IdentifierInfo here (`decltype` is
    /// kw_decltype), not from the lexer that reads the stream: TokenLexer
    /// re-kinds an identifier, but the prebuilt-token lexer behind a
    /// `#include "foo.k"` (Interop/Clang/KairoInclude.k) hands tokens to the
    /// parser as they are, and a keyword left tok::identifier is a parse
    /// error there.
    priv fn _ident_lit(self, name: llvm::StringRef, loc: SourceLocation, len: u32) -> bool {
        var ii = self._pp->getIdentifierInfo(name);
        var exact = (static_cast::<usize>(len) == name.size()) && (self._bytes(loc, len) == name);
        var at = self._claim(loc, len, exact);
        if !at.is_valid() {
            // Clang reads an identifier's spelling from its IdentifierInfo,
            // so the arena copy only buys the location.
            var ns = string(name.data(), name.size());
            self._arena_tok(clang::tok::identifier, SourceRange::from_bounds(loc, len), ns);
            var last = self._tokens.get(self._tokens.size() - 1);
            last->setIdentifierInfo(ii);
            last->setKind(ii->getTokenID());
            return true;
        }
        var t = self._tokens.slot();
        t->startToken();
        t->setKind(ii->getTokenID());
        t->setIdentifierInfo(ii);
        t->setLocation(self._loc(at));
        t->setLength(self._rest(loc, at, len));
        return true;
    }

    priv fn _intern(self, s: ref!(string)) -> u32 {
        ICE_IF(self._sealed, "TokenSink: intern after arena registration");
        var it = self._dedup.find(sref(s));
        if it != self._dedup.end() { return it->second; }
        var off = static_cast::<u32>(self._arena_text.size());
        self._arena_text.append(s.c_str(), s.size());
        // A separator no pp-number can continue through. NumericLiteralParser
        // reads ONE byte past the token (Sema::ActOnNumericConstant: "wants to
        // overread by one character") and trusts it to end the number; packed
        // back to back, `256` followed by `512` failed to lex. Offsets and
        // lengths are unaffected: the byte is never part of a token.
        self._arena_text.push_back('\n');
        self._dedup.try_emplace(sref(s), off);
        return off;
    }

    priv fn _arena_tok(self, k: clang::tok::TokenKind, r: SourceRange, spelling: ref!(string)) -> bool {
        var alen = static_cast::<u32>(spelling.size());
        var aoff = self._intern(spelling);

        var t = self._tokens.slot();
        t->startToken();
        t->setKind(k);
        t->setLength(alen);

        var p = self._pending.slot();
        p->tok_index = self._tokens.size() - 1;
        p->arena_off = aoff;
        p->arena_len = alen;
        p->kro_start = r.start;
        p->kro_len   = r.size();
        p->entry_len = alen;
        return true;
    }

    /// # Lifecycle

    fn has_arena(self) -> bool { return self._arena_text.size() > 0; }

    fn seal_arena(self) -> llvm::StringRef {
        self._sealed = true;
        return llvm::StringRef(self._arena_text.data(), self._arena_text.size());
    }

    /// Spelling loc in the arena, expansion range on the original .kro bytes.
    /// An entry with entry_len 0 takes no expansion of its own: it is the
    /// rest of the one the entry before it opened (see _pair).
    fn patch_pending(self, afid: clang::FileID) {
        ICE_IF((!self._sealed) && (!self._pending.empty()), "TokenSink: patch_pending before seal_arena");
        var entry = clang::SourceLocation();
        var entry_off: u32 = 0;
        for var i: usize = 0; i < self._pending.size(); ++i {
            var p = self._pending.get(i);
            var t = self._tokens.get(p->tok_index);
            if p->entry_len == 0 {
                ICE_IF(entry.isInvalid(), "TokenSink: joined arena token with no expansion before it");
                t->setLocation(entry.getLocWithOffset(static_cast::<i32>(p->arena_off - entry_off)));
                t->setLength(p->arena_len);
                continue;
            }
            var spelling = self._csm->getComposedLoc(afid, p->arena_off);
            var end = p->kro_start;
            if p->kro_len > 1 { end = end.advance(static_cast::<usize>(p->kro_len - 1)); }
            var loc = self._csm->createExpansionLoc(
                spelling, self._loc(p->kro_start), self._loc(end),
                static_cast::<usize>(p->entry_len), true);
            entry     = loc;
            entry_off = p->arena_off;
            t->setLocation(loc);
            t->setLength(p->arena_len);
        }
    }

    /// Copy into a clang-owned array and enter it. The copy is REQUIRED:
    /// EnterTokenStream takes ownership and deletes the array.
    fn drain_into_pp(self) {
        ICE_IF((!self._pending.empty()) && (!self._sealed), "TokenSink: drain with unpatched pending tokens");
        var n = self._tokens.size();
        ICE_IF(n <= 0, "TokenSink: drain on empty stream");
        var arr = libcxx::make_unique::<std::Legacy::array::<clang::Token>>(n);
        for (var i: usize = 0; i < n; ++i) { arr[i] = *(self._tokens.get(i)); }
        self._pp->EnterTokenStream(libcxx::move(arr), n, true, true);
    }

    /// # Introspection (TokenStreamPrinter)

    fn token_count(self) -> usize { return self._tokens.size(); }
    fn get_token(self, i: usize) -> *clang::Token { return self._tokens.get(i); }
    fn pending_count(self) -> usize { return self._pending.size(); }
    fn get_pending(self, i: usize) -> *PendingArenaTok { return self._pending.get(i); }

    fn is_divergent(self, tok_index: usize) -> bool {
        for var i: usize = 0; i < self._pending.size(); ++i {
            if self._pending.get(i)->tok_index == tok_index { return true; }
        }
        return false;
    }

    fn divergent_spelling(self, tok_index: usize) -> string {
        for var i: usize = 0; i < self._pending.size(); ++i {
            var p = self._pending.get(i);
            if p->tok_index != tok_index { continue; }
            return string(self._arena_text.data() + static_cast::<usize>(p->arena_off),
                          static_cast::<usize>(p->arena_len));
        }
        return "";
    }

    /// Kairo byte offset of token \p i in whichever fid it blames, or
    /// u32(-1) if it blames none (scratch, predefines). The printer's fid
    /// column says which file; filtering to the home file here hid every
    /// preamble token's offset behind a `?`.
    fn kairo_offset(self, i: usize) -> u32 {
        var t   = self._tokens.get(i);
        var loc = t->getLocation();
        if loc.isInvalid() { return u32(-1); }
        var dec = self._csm->getDecomposedExpansionLoc(loc);
        if self._locmap->kairo_fid(dec.first) == static_cast::<FileID>(u32(-1)) { return u32(-1); }
        return static_cast::<u32>(dec.second);
    }

    /// The Kairo fid token \p i blames, or u32(-1).
    fn kairo_fid(self, i: usize) -> u32 {
        var t   = self._tokens.get(i);
        var loc = t->getLocation();
        if loc.isInvalid() { return u32(-1); }
        var dec = self._csm->getDecomposedExpansionLoc(loc);
        return static_cast::<u32>(self._locmap->kairo_fid(dec.first));
    }
}