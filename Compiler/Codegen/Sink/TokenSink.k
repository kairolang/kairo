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
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "llvm/ADT/StringMap.h"
ffi "c++" import "llvm/ADT/DenseSet.h"
ffi "c++" import "clang/Basic/SourceManager.h"
ffi "c++" import "clang/Basic/SourceLocation.h"
ffi "c++" import "clang/Basic/TokenKinds.h"
ffi "c++" import "clang/Lex/Preprocessor.h"
ffi "c++" import "clang/Lex/Token.h"
ffi "c++" import "llvm/Support/MemoryBuffer.h"
ffi "c++" import "Native/Types.hh"
ffi "c++" import "Native/TokenArray.hh"
ffi "c++" import "string"
ffi "c++" import "vector"
ffi "c++" import "cstring"
ffi "c++" import "memory"
ffi "c++" import "utility"

import Codegen::Sink::EmitSink::EmitSink
import Interop::Clang::ClangLocMap::ClangLocMap
import Location::SourceLocation::SourceLocation
import Location::SourceManager::FileID
import Location::SourceRange::SourceRange
import Memory::ArenaAllocator::ArenaAllocator
import Memory::ArenaList::ArenaList
import Token::Token::Token
import Token::TokenKind::{
    TokenKind,
    is_keyword,
    is_operator,
    is_punctuator,
}

/// Where a stream is between its fill and clang. Literals go to the arena
/// while Filling; the arena becomes a clang buffer once (Sealed), the
/// pending tokens are pointed into it once (Patched), and the stream is
/// handed to the preprocessor once (Drained). A stream with no arena goes
/// from Filling to Drained. eof() is no stage: the interface PCH ends its
/// stream after the last include's sink was sealed and patched
/// (InterfacePCH::inject), and an eof token takes nothing from the arena.
pub enum SinkStage derives u8 {
    Filling = 0,
    Sealed,
    Patched,
    Drained,
}

/// One divergent-literal token awaiting its real ExpansionLoc. Recorded at
/// emit time (phase 1), consumed by patch_pending (phase 2).
///
/// Each entry opens an expansion of its own unless \c entry_len is 0: then
/// the token sits inside the expansion the entry before it opened, at its
/// own offset there (TokenSink::_pair). An expansion is a FileID, and one
/// FileID is what clang asks of the two halves of a pair it checks.
pub struct PendingArenaTok {
    var tok_index: usize          ///< index into _tokens
    var arena_off: u32            ///< offset of the C++ spelling in _arena_text
    var arena_len: u32            ///< length of the C++ spelling
    var kro_start: SourceLocation ///< .kro expansion start
    var kro_len:   u32            ///< .kro span length
    var entry_len: u32            ///< bytes of the expansion this opens; 0 joins the previous one
}

/// A token holding a file byte it was not anchored on exactly (TokenSink::
/// _claim): which token, and the anchor it would claim from again if a
/// declaration's name needs that byte back.
pub struct HeldByte {
    var tok:    usize
    var anchor: SourceLocation
    var len:    u32
}

pub class TokenSink derives EmitSink {
    priv var _pp:     unsafe *clang::Preprocessor
    priv var _csm:    unsafe *clang::SourceManager
    priv var _locmap: unsafe *ClangLocMap
    priv var _cfid:   clang::FileID ///< clang FileID of the TU being emitted
    priv var _kfid:   FileID ///< Kairo fid of the TU being emitted
    priv var _kbase:  u32                          = 0 ///< Kairo raw loc of byte 0 of this file (eof anchor)
    priv var _ksize:  u32                          = 0

    priv var _tokens:  ArenaList<clang::Token>
    priv var _pending: ArenaList<PendingArenaTok>

    priv var _arena_text: cxx::std::string
    priv var _dedup:      llvm::StringMap<u32> ///< probed with the spelling's own bytes: a hit allocates nothing.
    /// EmitSink::unanchored: every token goes to the arena.
    priv var _unanchored: bool = false
    /// Every punctuator goes to the arena, so its location's bytes are its
    /// spelling. Only a printer reads them -- the parser takes a punctuator
    /// from its kind -- so this is for `-E` (Backend/IncludeEmitter.k).
    pub var arena_puncts: bool = false
    /// Kairo raw locations already given to a borrowed token. A second token
    /// at one of them moves within its anchor, or to the arena: see _claim.
    /// Raw locations, WIDENED to u64: the claim walk runs across the raw
    /// space unfiltered, and a u32 key could land on DenseSet's reserved
    /// 0xFFFFFFFF / 0xFFFFFFFE. Zero-extended, it never can.
    priv var _used: llvm::DenseSet<u64>
    /// anchor raw -> h: every byte at offsets [1, h) from that anchor is in
    /// _used. The forward claim walk starts past them instead of re-probing
    /// each one: many tokens share one anchor, and the probes were O(k^2) per
    /// anchor (the top Kairo symbol of the codegen workers). Valid because
    /// _used only grows; the one erase clears it.
    priv var _claim_hint: llvm::DenseMap<u64, u64>
    /// raw r in _used -> r' > r with every byte in [r, r') in _used: a skip
    /// pointer shared by ALL anchors. _claim_hint only spares an
    /// anchor its own earlier walk; a file with far more C++ than Kairo
    /// bytes (the 65k-line diagnostic registry) has thousands of distinct
    /// anchors each walking the same growing run of taken bytes, O(n^2)
    /// probes: 34 min of the registry compile. Valid while _used only
    /// grows; the one erase clears it with _claim_hint.
    priv var _next_free: llvm::DenseMap<u64, u64>
    /// The same, over SETTLED bytes: in _used and not a stray (_stray_at),
    /// so no claim can ever take them. Inside its own anchor a walk tests
    /// every taken byte for a stray; a long anchor many tokens share (again
    /// the registry) made that O(len) per token. A settled byte stays
    /// settled: a byte is held once, when it is first taken, and a steal
    /// re-holds it inside the stealer's anchor. The exceptions clear this:
    /// the one _used erase, and a failed _steal, which un-holds and
    /// re-holds its byte around a nested walk that saw it settled.
    priv var _next_unsettled: llvm::DenseMap<u64, u64>
    /// The bytes in _used held by a token that is not the exact spelling of
    /// its anchor (an index into _held_list), so an exact one can take them
    /// back (_steal). Keyed as _used is.
    priv var _held:      llvm::DenseMap<u64, u64>
    priv var _held_list: cxx::std::vector<HeldByte>
    priv var _stage:     SinkStage                  = SinkStage::Filling
    /// The last punctuator, while it is still the last token: one past its
    /// index (0 for none), its anchor, and the byte it claimed (invalid when
    /// it went to the arena). _pair reads them to place the second half of
    /// a checked pair, and may move this token to the arena after the fact.
    priv var _open_end:  usize          = 0
    priv var _open_loc:  SourceLocation
    priv var _open_len:  u32            = 0
    priv var _open_byte: SourceLocation
    /// System headers the stream needs (system_header), for KairoInject to
    /// enter ahead of it: a token stream has no line for an #include.
    pub var system_headers: cxx::std::vector<string>

    fn TokenSink(self,
                 pp:     unsafe *clang::Preprocessor,
                 csm:    unsafe *clang::SourceManager,
                 locmap: unsafe *ClangLocMap,
                 cfid:   clang::FileID,
                 kfid:   FileID,
                 ksize:  u32,
                 arena:  unsafe *ArenaAllocator) {
        if locmap == &null {
            kairo::std::ice_fail("TokenSink: no ClangLocMap")
        }

        if !locmap->ready() {
            kairo::std::ice_fail(
                "TokenSink: ClangLocMap not rebound; construct the sink inside the action window",
            )
        }

        self._pp     = pp
        self._csm    = csm
        self._locmap = locmap
        self._cfid   = cfid
        self._kfid   = kfid
        self._kbase  = locmap->kairo_base(kfid)
        self._ksize  = ksize

        self._tokens.set_allocator(arena, 512)
        self._pending.set_allocator(arena, 64)
        self._arena_text.reserve(4096)
    }

    /// # Conversions

    /// Kairo punctuator/operator TokenKind -> clang punctuator kind. 1:1,
    /// lexical, no judgement. clang::tok::unknown for anything unmapped.
    fn conv_kind(self, k: TokenKind) -> clang::tok::TokenKind {
        match k {
            case TokenKind::OpLParen {
                return clang::tok::l_paren
            } case TokenKind::OpRParen {
                return clang::tok::r_paren
            } case TokenKind::OpLBrace {
                return clang::tok::l_brace
            } case TokenKind::OpRBrace {
                return clang::tok::r_brace
            } case TokenKind::OpLSquare {
                return clang::tok::l_square
            } case TokenKind::OpRSquare {
                return clang::tok::r_square
            } case TokenKind::OpSemicolon {
                return clang::tok::semi
            } case TokenKind::OpComma {
                return clang::tok::comma
            } case TokenKind::OpColon {
                return clang::tok::colon
            } case TokenKind::OpColonColon {
                return clang::tok::coloncolon
            } case TokenKind::OpDot {
                return clang::tok::period
            } case TokenKind::OpArrow {
                return clang::tok::arrow
            } case TokenKind::OpEllipsis {
                return clang::tok::ellipsis
            } case TokenKind::OpPlus {
                return clang::tok::plus
            } case TokenKind::OpMinus {
                return clang::tok::minus
            } case TokenKind::OpStar {
                return clang::tok::star
            } case TokenKind::OpSlash {
                return clang::tok::slash
            } case TokenKind::OpPercent {
                return clang::tok::percent
            } case TokenKind::OpPlusPlus {
                return clang::tok::plusplus
            } case TokenKind::OpMinusMinus {
                return clang::tok::minusminus
            } case TokenKind::OpEqualEqual {
                return clang::tok::equalequal
            } case TokenKind::OpExclaimEqual {
                return clang::tok::exclaimequal
            } case TokenKind::OpLess {
                return clang::tok::less
            } case TokenKind::OpGreater {
                return clang::tok::greater
            } case TokenKind::OpLessEqual {
                return clang::tok::lessequal
            } case TokenKind::OpGreaterEqual {
                return clang::tok::greaterequal
            } case TokenKind::OpLessEqualGreater {
                return clang::tok::spaceship
            } case TokenKind::OpAmpAmp {
                return clang::tok::ampamp
            } case TokenKind::OpPipePipe {
                return clang::tok::pipepipe
            } case TokenKind::OpExclaim {
                return clang::tok::exclaim
            } case TokenKind::OpAmp {
                return clang::tok::amp
            } case TokenKind::OpPipe {
                return clang::tok::pipe
            } case TokenKind::OpCaret {
                return clang::tok::caret
            } case TokenKind::OpTilde {
                return clang::tok::tilde
            } case TokenKind::OpLessLess {
                return clang::tok::lessless
            } case TokenKind::OpGreaterGreater {
                return clang::tok::greatergreater
            } case TokenKind::OpEqual {
                return clang::tok::equal
            } case TokenKind::OpPlusEqual {
                return clang::tok::plusequal
            } case TokenKind::OpMinusEqual {
                return clang::tok::minusequal
            } case TokenKind::OpStarEqual {
                return clang::tok::starequal
            } case TokenKind::OpSlashEqual {
                return clang::tok::slashequal
            } case TokenKind::OpPercentEqual {
                return clang::tok::percentequal
            } case TokenKind::OpAmpEqual {
                return clang::tok::ampequal
            } case TokenKind::OpPipeEqual {
                return clang::tok::pipeequal
            } case TokenKind::OpCaretEqual {
                return clang::tok::caretequal
            } case TokenKind::AtVoid {
                return clang::tok::kw_void
            } default {
                return clang::tok::unknown
            }
        }
    }

    /// Kairo loc -> clang loc, any registered fid. Invalid means an
    /// unregistered fid (loaded after rebind) or a synthesized node whose
    /// lowered-from range was never stamped: emitter bug, ICE.
    priv fn _loc(self, loc: SourceLocation) -> clang::SourceLocation {
        if !loc.is_valid() {
            kairo::std::ice_fail(
                "TokenSink: invalid Kairo location; a synthesized node must carry its lowered-from range",
            )
        }

        var c = self._locmap->to_clang(loc)
        if c.isInvalid() {
            self.ice_at(
                SourceRange::from_bounds(loc, 1 as u32),
                f"TokenSink: Kairo loc {loc.raw()} maps to no clang location (fid loaded after rebind?)",
            )
        }

        return c
    }

    /// The bytes at \p loc in whichever registered file it lives in.
    priv fn _bytes(self, loc: SourceLocation, len: u32) -> llvm::StringRef {
        var cloc = self._loc(loc)
        var dec  = self._csm->getDecomposedLoc(cloc)
        var buf  = self._csm->getBufferData(dec.first)
        if (dec.second as usize) + (len as usize) > buf.size() {
            self.ice_at(
                SourceRange::from_bounds(loc, len),
                "TokenSink: span runs past the end of its buffer",
            )
        }

        return buf.substr(dec.second as usize, (len as usize))
    }

    /// # EmitSink primitives

    override fn create(self, t: Token) -> bool {
        var len = t.range.size()
        if t.kind == TokenKind::LitIdentifier {
            return self._ident_from_bytes(t.range.start, len)
        }

        if is_keyword(t.kind) {
            self.ice_at(
                t.range,
                "TokenSink::create on a keyword token; emit it deliberately (kw_*) or let Lower/ rewrite it into a name",
            )
        }

        if !is_punctuator(t.kind) && !is_operator(t.kind) && t.kind != TokenKind::AtVoid {
            self.ice_at(
                t.range,
                "TokenSink::create accepts identifiers, punctuators and operators only",
            )
        }

        var k = self.conv_kind(t.kind)
        if k == clang::tok::unknown {
            self.ice_at(
                t.range,
                "TokenSink::create: no clang punctuator for this Kairo token kind; a Lower/ pass left an unlowered Kairo-only operator in the tree",
            )
        }

        return self._punct(k, t.range.start, len)
    }

    override fn create_ident(self, at: SourceRange, const spelling: string) -> bool {
        return self._ident_lit(kairo::sref(spelling), at.start, at.size())
    }

    override fn punct(self, at: SourceRange, k: clang::tok::TokenKind) -> bool {
        return self._punct(k, at.start, at.size())
    }

    /// Kind AND IdentifierInfo: parser paths that call getIdentifierInfo()
    /// on a keyword would get null with the kind alone.
    override fn keyword(self, at: SourceRange, k: clang::tok::TokenKind) -> bool {
        var unsafe *kws = clang::tok::getKeywordSpelling(k)
        if kws == &null {
            self.ice_at(at, "TokenSink::keyword: kind is not a keyword")
        }

        return self._ident_lit(llvm::StringRef(kws, cxx::std::strlen(kws)), at.start, at.size())
    }

    /// Borrowed literal: clang reads getLength() bytes at getLocation(), so
    /// the span must be the real spelling.
    override fn literal(self, at: SourceRange, k: clang::tok::TokenKind) -> bool {
        var        bytes = self._bytes(at.start, at.size())
        var unsafe *t    = self._tokens.slot()
        t->startToken()
        t->setKind(k)
        var loc = self._loc(at.start)
        self._pp->CreateString(bytes, &*t, loc, loc)
        return true
    }

    override fn create_int(self, at: SourceRange, @inout cxx_v: string) -> bool {
        return self._arena_tok(clang::tok::numeric_constant, at, &cxx_v)
    }

    /// \p cxx INCLUDES the quotes.
    override fn create_str(self, at: SourceRange, @inout cxx_v: string) -> bool {
        return self._arena_tok(clang::tok::string_literal, at, &cxx_v)
    }

    /// \p cxx INCLUDES the quotes.
    override fn create_char(self, at: SourceRange, @inout cxx_v: string) -> bool {
        return self._arena_tok(clang::tok::char_constant, at, &cxx_v)
    }

    /// Recorded, not emitted (system_headers); once per header.
    override fn unanchored(self, on: bool) {
        self._unanchored = on
    }

    override fn is_unanchored(self) -> bool {
        return self._unanchored
    }

    override fn system_header(self, at: SourceRange, const name: string) -> bool {
        for var i: usize = 0; i < self.system_headers.size(); ++i {
            if self.system_headers[i] == name {
                return true
            }
        }

        self.system_headers.push_back(name)
        return true
    }

    /// End of stream. Zero length, anchored on the file's last byte.
    fn eof(self) -> bool {
        eval if defined!(DEBUG) {
            if self._stage == SinkStage::Drained {
                kairo::std::ice_fail("TokenSink: eof after the stream was drained")
            }
        }

        var last = self._kbase + self._ksize
        if last > self._kbase {
            last = last - 1
        }

        var unsafe *t = self._tokens.slot()
        t->startToken()
        t->setKind(clang::tok::eof)
        t->setLocation(self._locmap->to_clang(self._locmap_loc(last)))
        t->setLength(0)
        return true
    }

    /// A raw loc in THIS file as a SourceLocation. Only eof() needs it.
    priv fn _locmap_loc(self, raw: u32) -> SourceLocation {
        var base = self._locmap->kairo_base(self._kfid)
        var off  = ((raw - base) as usize)
        return self._locmap->ksm_loc(self._kfid, off)
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
    ///
    ///          A walker is a TENANT of the bytes it lands on, past its own
    ///          anchor: a later token anchored on one of them takes it back
    ///          (_stray_at, then _steal), and the walker walks on. A token
    ///          whose anchor holds a free-or-stray byte gets it however late
    ///          it is emitted, so its byte depends on its node, not on how
    ///          much C++ was emitted before it; only tokens anchored on the
    ///          same bytes go first come. Under pure first come, a few
    ///          functions' signatures and `namespace` wrappers, each anchored
    ///          on a short name, would run through the next functions'
    ///          bytes, and a later body's `.` would find its own byte held by
    ///          a parameter type from three lines up -- clang's "member
    ///          reference base type" would land on the closing brace below
    ///          it.
    priv fn _claim(self, loc: SourceLocation, len: u32, exact: bool = false) -> SourceLocation {
        return self._claim_for(loc, len, exact, self._tokens.size())
    }

    /// _claim for token \p tok: the next one, or one _steal is moving.
    /// Offsets [1, i] from the anchor keyed \p hkey are all in _used now
    /// (the walk passed or took each), so the next walk may start past them.
    priv fn _hint_used(self, hkey: u64, i: usize) {
        if i < 1 {
            return
        }

        var h  = ((i + 1) as u64)
        var it = self._claim_hint.find(hkey)
        if it == self._claim_hint.end() {
            self._claim_hint.try_emplace(hkey, h)
            return
        }

        if it->second < h {
            it->second = h
        }
    }

    /// The first raw at or after \p r0 that is not in _used. Every pointer
    /// on the way is redirected to the answer (path compression), so a run
    /// of taken bytes is crossed once, not once per anchor that meets it.
    priv fn _skip_used(self, r0: u64) -> u64 {
        var r = r0
        while self._used.contains(r) {
            var it = self._next_free.find(r)
            if it != self._next_free.end() {
                r = it->second
            } else {
                r = r + 1
            }
        }

        var x = r0
        while x != r {
            var it = self._next_free.find(x)
            var nx = x + 1
            if it != self._next_free.end() {
                nx         = it->second
                it->second = r
            } else {
                self._next_free.try_emplace(x, r)
            }

            x = nx
        }

        return r
    }

    /// The first raw at or after \p r0 that is free or a stray, with the
    /// same path compression as _skip_used.
    priv fn _skip_settled(self, r0: u64) -> u64 {
        var r = r0
        while self._used.contains(r) && !self._stray_raw(r) {
            var it = self._next_unsettled.find(r)
            if it != self._next_unsettled.end() {
                r = it->second
            } else {
                r = r + 1
            }
        }

        var x = r0
        while x != r {
            var it = self._next_unsettled.find(x)
            var nx = x + 1
            if it != self._next_unsettled.end() {
                nx         = it->second
                it->second = r
            } else {
                self._next_unsettled.try_emplace(x, r)
            }

            x = nx
        }

        return r
    }

    priv fn _stray_raw(self, r: u64) -> bool {
        var it = self._held.find(r)
        if it == self._held.end() {
            return false
        }

        var h  = self._held_list[it->second as usize]
        var lo = (h.anchor.raw() as u64)
        return r < lo || r - lo >= (h.len as u64)
    }

    priv fn _claim_for(self,
                       loc:   SourceLocation,
                       len:   u32,
                       exact: bool,
                       tok:   usize) -> SourceLocation {
        if self._unanchored {
            return SourceLocation::invalid()
        }

        var dec         = self._csm->getDecomposedLoc(self._loc(loc))
        var avail       = self._csm->getBufferData(dec.first).size() - (dec.second as usize)
        var from: usize = 0
        if !exact && self._is_name_span(loc, len) {
            from = 1
        }

        if exact && avail > 0 {
            if self._used.insert(loc.raw() as u64).second {
                return loc
            }

            if self._steal(loc) {
                return loc
            }
        }

        // Below `lim` a used byte may still be stolen (the stray check), so
        // only bytes from `lim` on are skipped through the hint.
        var hkey           = (loc.raw() as u64)
        var skip_to: usize = 0
        var hit            = self._claim_hint.find(hkey)
        if hit != self._claim_hint.end() {
            skip_to = (hit->second as usize)
        }

        var lim: usize = 1
        if !exact && (len as usize) > lim {
            lim = (len as usize)
        }

        for var i: usize = from; i < avail; ++i {
            if i >= lim && i < skip_to {
                i = skip_to - 1
                continue
            }

            // Inside the anchor (non-exact: exact never steals) a settled byte
            // only `continue`s below, so the first free-or-stray one is
            // where the walk would act.
            if i < lim && !exact && i < (len as usize) {
                var r  = (loc.raw() as u64) + (i as u64)
                var nf = self._skip_settled(r)
                if nf != r {
                    i = (nf - (loc.raw() as u64)) as usize
                    if i >= avail {
                        break
                    }

                    if i >= lim && i < skip_to {
                        i = skip_to
                        if i >= avail {
                            break
                        }
                    }
                }
            }

            // Past the anchor's own bytes a taken byte is only skipped (no
            // stray check), so jumping to the first free byte lands where
            // the byte-by-byte walk would.
            if i >= lim {
                var r  = (loc.raw() as u64) + (i as u64)
                var nf = self._skip_used(r)
                if nf != r {
                    i = (nf - (loc.raw() as u64)) as usize
                    if i >= avail {
                        break
                    }
                }
            }

            var at = loc.advance(i)
            if !self._used.insert(at.raw() as u64).second {
                // A byte of this token's own anchor, held by a token that
                // walked onto it from somewhere else: it is this one's.
                if !exact && i < (len as usize) && self._stray_at(at) && self._steal(at) {
                    self._hold(at, tok, loc, len)
                    self._hint_used(hkey, i)
                    return at
                }

                continue
            }

            if !exact {
                self._hold(at, tok, loc, len)
            }

            self._hint_used(hkey, i)
            return at
        }

        self._hint_used(hkey, avail)
        // Then backward: a closer anchored near the end of a small file
        // finds every later byte taken by its own opener's run.
        var before = (dec.second as usize)
        for var i: usize = 1; i <= before; ++i {
            var at = loc.with_offset(0 - (i as i64))
            if !self._used.insert(at.raw() as u64).second {
                continue
            }

            if !exact {
                self._hold(at, tok, loc, len)
            }

            return at
        }

        // Last, the kept byte itself: a unique location beats the arena.
        if from == 1 && self._used.insert(loc.raw() as u64).second {
            self._hold(loc, tok, loc, len)
            return loc
        }

        return SourceLocation::invalid()
    }

    /// The byte \p at is held (an inexact token's, so _steal can move it)
    /// by a token whose own anchor does not cover it: one that walked there
    /// because its anchor's bytes were taken. A token at home in its anchor
    /// is never a stray, so two tokens anchored on one span cannot take a
    /// byte back and forth.
    priv fn _stray_at(self, at: SourceLocation) -> bool {
        var it = self._held.find(at.raw() as u64)
        if it == self._held.end() {
            return false
        }

        var h  = self._held_list[it->second as usize]
        var lo = h.anchor.raw()
        var r  = at.raw()
        return r < lo || r - lo >= h.len
    }

    priv fn _hold(self, at: SourceLocation, tok: usize, anchor: SourceLocation, len: u32) {
        var h = HeldByte{}
        h.tok                       = tok
        h.anchor                    = anchor
        h.len                       = len
        self._held[at.raw() as u64] = (self._held_list.size() as u64)
        self._held_list.push_back(h)
    }

    /// The exact token's byte \p at, taken back from the inexact token that
    /// holds it, which claims again from its own anchor, or, in a file whose
    /// every byte is taken (a small file with a lot of C++ behind it: the
    /// common case, not the corner), goes to the arena as it would have had
    /// it found none in the first place. Never from an exact token (a
    /// forward declaration and its definition: the first keeps it), nor
    /// from the punctuator _pair may still move to the arena.
    priv fn _steal(self, at: SourceLocation) -> bool {
        var key = (at.raw() as u64)
        var it  = self._held.find(key)
        if it == self._held.end() {
            return false
        }

        var hi = it->second
        var h  = self._held_list[hi as usize]
        if self._open_end != 0 && h.tok + 1 == self._open_end {
            return false
        }

        self._held.erase(key)
        var moved = self._claim_for(h.anchor, h.len, false, h.tok)
        if !moved.is_valid() {
            if self._to_arena(h) {
                return true
            }

            self._held[key] = hi
            self._next_unsettled.clear() // the nested walk saw this byte settled
            return false
        }

        var unsafe *t = self._tokens.get(h.tok)
        t->setLocation(self._loc(moved))
        t->setLength(self._rest(h.anchor, moved, h.len))
        return true
    }

    /// Token \p h.tok, already emitted at a file byte, given an arena entry
    /// instead (_arena_tok after the fact; patch_pending places it). An
    /// identifier or keyword is spelled by its IdentifierInfo, a punctuator
    /// by its kind. Not a half of a pair _completes_pair checks: moved to a
    /// macro location alone, it would split its pair across contexts.
    priv fn _to_arena(self, h: HeldByte) -> bool {
        var unsafe *t = self._tokens.get(h.tok)
        var        k  = t->getKind()
        if h.tok > 0 && self._checked_pair(self._tokens.get(h.tok - 1)->getKind(), k) {
            return false
        }

        if h.tok + 1 < self._tokens.size() {
            if self._checked_pair(k, self._tokens.get(h.tok + 1)->getKind()) {
                return false
            }
        } else if k == clang::tok::l_paren
            || k == clang::tok::r_brace
            || k == clang::tok::l_square
            || k == clang::tok::r_square
            || k == clang::tok::coloncolon {
            // The last token: what follows it, and so its pair, is not known yet.
            return false
        }

        var        ns  = string()
        var unsafe *ii = t->getIdentifierInfo()
        if ii != &null {
            var nm = ii->getName()
            ns = string(unsafe ((nm.data() as unsafe *const u8) as *const u8), nm.size())
        } else {
            var unsafe *ps = clang::tok::getPunctuatorSpelling(k)
            if ps == &null {
                return false
            }

            ns = string(unsafe ((ps as unsafe *const u8) as *const u8), cxx::std::strlen(ps))
        }

        var        alen = (ns.size() as u32)
        var unsafe *p   = self._pending.slot()
        p->tok_index = h.tok
        p->arena_off = self._intern(&ns)
        p->arena_len = alen
        p->kro_start = h.anchor
        p->kro_len   = h.len
        p->entry_len = alen
        t->setLength(alen)
        return true
    }

    /// [\p loc, +\p len) is one identifier (see _claim).
    priv fn _is_name_span(self, loc: SourceLocation, len: u32) -> bool {
        if len == 0 {
            return false
        }

        var b = self._bytes(loc, len)
        for var i: usize = 0; i < b.size(); ++i {
            var c = b[i] as u8
            var alpha = c >= ('a' as u8) && c <= ('z' as u8)
                || c >= ('A' as u8) && c <= ('Z' as u8)
                || c == ('_' as u8)
            var digit = c >= ('0' as u8) && c <= ('9' as u8)
            if !alpha && (i == 0 || !digit) {
                return false
            }
        }

        return true
    }

    /// The caret length left for a token moved \p at - \p loc bytes into
    /// its anchor: the rest of the anchor, never zero.
    priv fn _rest(self, loc: SourceLocation, at: SourceLocation, len: u32) -> u32 {
        var moved = at.raw() - loc.raw()
        if moved >= len {
            return 1
        }

        return len - moved
    }

    priv fn _punct(self, k: clang::tok::TokenKind, loc: SourceLocation, len: u32) -> bool {
        if self._completes_pair(k) {
            return self._pair(k, loc, len)
        }

        var at = if (self.arena_puncts) => (SourceLocation::invalid()) else => self._claim(loc, len)
        if !at.is_valid() {
            var unsafe *p = clang::tok::getPunctuatorSpelling(k)
            if p == &null {
                self.ice_at(
                    SourceRange::from_bounds(loc, len),
                    "TokenSink::_punct: kind has no punctuator spelling",
                )
            }

            var ns = string(unsafe ((p as unsafe *const u8) as *const u8), cxx::std::strlen(p))
            self._arena_tok(k, SourceRange::from_bounds(loc, len), &ns)
            self._opened(loc, len, at)
            return true
        }

        var unsafe *t = self._tokens.slot()
        t->startToken()
        t->setKind(k)
        t->setLocation(self._loc(at))
        t->setLength(self._rest(loc, at, len))
        self._opened(loc, len, at)
        return true
    }

    /// Remember the punctuator just emitted as a possible first half (see
    /// _completes_pair); \p at is its claimed byte, invalid for the arena.
    priv fn _opened(self, loc: SourceLocation, len: u32, at: SourceLocation) {
        self._open_end  = self._tokens.size()
        self._open_loc  = loc
        self._open_len  = len
        self._open_byte = at
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
        if self._open_end == 0 || self._open_end != self._tokens.size() {
            return false
        }

        return self._checked_pair(self._tokens.get(self._open_end - 1)->getKind(), k)
    }

    /// \p first then \p k is one of the pairs clang checks (_completes_pair).
    priv fn _checked_pair(self, first: clang::tok::TokenKind, k: clang::tok::TokenKind) -> bool {
        if first == clang::tok::l_paren && k == clang::tok::l_brace {
            return true
        }

        if first == clang::tok::r_brace && k == clang::tok::r_paren {
            return true
        }

        if first == clang::tok::l_square && k == clang::tok::l_square {
            return true
        }

        if first == clang::tok::r_square && k == clang::tok::r_square {
            return true
        }

        if first == clang::tok::coloncolon && k == clang::tok::star {
            return true
        }

        return false
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
        self._open_end = 0
        var first = self._tokens.size() - 1
        if self._open_byte.is_valid() {
            var at = self._claim(loc, len)
            if at.is_valid() {
                var unsafe *t = self._tokens.slot()
                t->startToken()
                t->setKind(k)
                t->setLocation(self._loc(at))
                t->setLength(self._rest(loc, at, len))
                return true
            }

            self._used.erase(self._open_byte.raw() as u64)
            self._claim_hint.clear() // a byte left _used: no prefix is known whole any more.
            self._next_free.clear()  // nor any run.
            self._next_unsettled.clear()
            self._held.erase(self._open_byte.raw() as u64)
            var unsafe *h = self._pending.slot()
            h->tok_index = first
            h->kro_start = self._open_loc
            h->kro_len   = self._open_len
        }

        var unsafe *a = clang::tok::getPunctuatorSpelling(self._tokens.get(first)->getKind())
        var unsafe *b                       = clang::tok::getPunctuatorSpelling(k)
        var        alen                     = (cxx::std::strlen(a) as u32)
        var        blen                     = (cxx::std::strlen(b) as u32)
        var        joined: cxx::std::string
        joined.append(a)
        joined.append(b)
        var ns  = string(unsafe ((joined.data() as unsafe *const u8) as *const u8), joined.size())
        var off = self._intern(&ns)

        if self._pending.size() == 0 {
            kairo::std::ice_fail("TokenSink::_pair: the first half has no arena entry")
        }

        var unsafe *head = self._pending.get(self._pending.size() - 1)
        if head->tok_index != first {
            kairo::std::ice_fail("TokenSink::_pair: the first half has no arena entry")
        }

        head->arena_off = off
        head->arena_len = alen
        head->entry_len = alen + blen

        var unsafe *t = self._tokens.slot()
        t->startToken()
        t->setKind(k)
        t->setLength(blen)

        var unsafe *p = self._pending.slot()
        p->tok_index = self._tokens.size() - 1
        p->arena_off = off + alen
        p->arena_len = blen
        p->kro_start = loc
        p->kro_len   = len
        p->entry_len = 0
        return true
    }

    priv fn _ident_from_bytes(self, loc: SourceLocation, len: u32) -> bool {
        return self._ident_lit(self._bytes(loc, len), loc, len)
    }

    /// The kind comes from the IdentifierInfo here (`decltype` is
    /// kw_decltype), not from the lexer that reads the stream: TokenLexer
    /// re-kinds an identifier, but the prebuilt-token lexer behind a
    /// `#include "foo.k"` (Interop/Clang/KairoInclude.k) hands tokens to the
    /// parser as they are, and a keyword left tok::identifier is a parse
    /// error there.
    priv fn _ident_lit(self, name: llvm::StringRef, loc: SourceLocation, len: u32) -> bool {
        var unsafe *ii   = self._pp->getIdentifierInfo(name)
        var        exact = (len as usize) == name.size() && self._bytes(loc, len) == name
        var        at    = self._claim(loc, len, exact)
        if !at.is_valid() {
            // Clang reads an identifier's spelling from its IdentifierInfo,
            // so the arena copy only buys the location.
            var ns = string(unsafe ((name.data() as unsafe *const u8) as *const u8), name.size())
            self._arena_tok(clang::tok::identifier, SourceRange::from_bounds(loc, len), &ns)
            var unsafe *last = self._tokens.get(self._tokens.size() - 1)
            last->setIdentifierInfo(ii)
            last->setKind(ii->getTokenID())
            return true
        }

        var unsafe *t = self._tokens.slot()
        t->startToken()
        t->setKind(ii->getTokenID())
        t->setIdentifierInfo(ii)
        t->setLocation(self._loc(at))
        t->setLength(self._rest(loc, at, len))
        return true
    }

    priv fn _intern(self, @inout s: string) -> u32 {
        if self._stage != SinkStage::Filling {
            kairo::std::ice_fail("TokenSink: intern after arena registration")
        }

        var it = self._dedup.find(kairo::sref(s))
        if it != self._dedup.end() {
            return it->second
        }

        var off = (self._arena_text.size() as u32)
        self._arena_text.append(s.c_str(), s.size())
        // A separator no pp-number can continue through. NumericLiteralParser
        // reads ONE byte past the token (Sema::ActOnNumericConstant: "wants to
        // overread by one character") and trusts it to end the number; packed
        // back to back, `256` followed by `512` failed to lex. Offsets and
        // lengths are unaffected: the byte is never part of a token.
        self._arena_text.push_back(10)
        self._dedup.try_emplace(kairo::sref(s), off)
        return off
    }

    priv fn _arena_tok(self,
                       k:               clang::tok::TokenKind,
                       r:               SourceRange,
                       @inout spelling: string) -> bool {
        var alen = (spelling.size() as u32)
        var aoff = self._intern(&spelling)

        var unsafe *t = self._tokens.slot()
        t->startToken()
        t->setKind(k)
        t->setLength(alen)

        var unsafe *p = self._pending.slot()
        p->tok_index = self._tokens.size() - 1
        p->arena_off = aoff
        p->arena_len = alen
        p->kro_start = r.start
        p->kro_len   = r.size()
        p->entry_len = alen
        return true
    }

    /// # Lifecycle

    fn has_arena(self) -> bool {
        return self._arena_text.size() > 0
    }

    fn seal_arena(self) -> llvm::StringRef {
        eval if defined!(DEBUG) {
            if self._stage != SinkStage::Filling {
                kairo::std::ice_fail("TokenSink: seal_arena twice, or after drain")
            }
        }

        self._stage = SinkStage::Sealed
        return llvm::StringRef(self._arena_text.data(), self._arena_text.size())
    }

    /// The arena as a clang buffer and every pending token patched into it:
    /// what a stream needs before clang reads it, for each of its drivers
    /// (KairoInject, IncludeEmitter). A stream with no literals needs none.
    fn finish(self) {
        if !self.has_arena() {
            return
        }

        var view = self.seal_arena()
        var buf = llvm::MemoryBuffer::getMemBufferCopy(
            view,
            llvm::Twine(kairo::sref(r"<kairo-literals>")),
        )

        var afid = self._csm->createFileID(cxx::std::move(buf), clang::SrcMgr::C_User)
        self.patch_pending(afid)
    }

    /// Spelling loc in the arena, expansion range on the original .kro bytes.
    /// An entry with entry_len 0 takes no expansion of its own: it is the
    /// rest of the one the entry before it opened (see _pair).
    fn patch_pending(self, afid: clang::FileID) {
        if self._stage == SinkStage::Filling && !self._pending.empty() {
            kairo::std::ice_fail("TokenSink: patch_pending before seal_arena")
        }

        // A second patch would open every pending token's expansion again,
        // over a stream clang may already hold.
        eval if defined!(DEBUG) {
            if self._stage == SinkStage::Patched || self._stage == SinkStage::Drained {
                kairo::std::ice_fail("TokenSink: patch_pending twice, or after drain")
            }
        }

        if self._stage == SinkStage::Sealed {
            self._stage = SinkStage::Patched
        }

        var entry          = clang::SourceLocation()
        var entry_off: u32 = 0
        for var i: usize = 0; i < self._pending.size(); ++i {
            var unsafe *p = self._pending.get(i)
            var unsafe *t = self._tokens.get(p->tok_index)
            if p->entry_len == 0 {
                if entry.isInvalid() {
                    kairo::std::ice_fail(
                        "TokenSink: joined arena token with no expansion before it",
                    )
                }

                t->setLocation(entry.getLocWithOffset((p->arena_off - entry_off) as i32))
                t->setLength(p->arena_len)
                continue
            }

            var spelling = self._csm->getComposedLoc(afid, p->arena_off)
            var end      = p->kro_start
            if p->kro_len > 1 {
                end = end.advance((p->kro_len - 1) as usize)
            }

            var loc = self._csm->createExpansionLoc(
                spelling,
                self._loc(p->kro_start),
                self._loc(end),
                p->entry_len,
                true,
            )

            entry     = loc
            entry_off = p->arena_off
            t->setLocation(loc)
            t->setLength(p->arena_len)
        }
    }

    /// Copy into a clang-owned array and enter it. The copy is REQUIRED:
    /// EnterTokenStream takes ownership and deletes the array.
    fn drain_into_pp(self) {
        // Patched, not merely sealed: a sealed stream's pending tokens still
        // carry no location.
        if !self._pending.empty() && self._stage != SinkStage::Patched {
            kairo::std::ice_fail("TokenSink: drain with unpatched pending tokens")
        }

        eval if defined!(DEBUG) {
            if self._stage == SinkStage::Drained {
                kairo::std::ice_fail("TokenSink: drained twice")
            }
        }

        self._stage = SinkStage::Drained

        var n = self._tokens.size()
        if n <= 0 {
            kairo::std::ice_fail("TokenSink: drain on empty stream")
        }

        var arr = cxx::std::make_unique<kairo::TokenArray>(n)
        for var i: usize = 0; i < n; ++i {
            arr[i] = *self._tokens.get(i)
        }

        self._pp->EnterTokenStream(cxx::std::move(arr), n as u32, true, true)
    }

    /// # Introspection (TokenStreamPrinter)

    fn token_count(self) -> usize {
        return self._tokens.size()
    }

    fn get_token(self, i: usize) -> unsafe *clang::Token {
        return self._tokens.get(i)
    }

    fn pending_count(self) -> usize {
        return self._pending.size()
    }

    fn get_pending(self, i: usize) -> unsafe *PendingArenaTok {
        return self._pending.get(i)
    }

    fn is_divergent(self, tok_index: usize) -> bool {
        for var i: usize = 0; i < self._pending.size(); ++i {
            if self._pending.get(i)->tok_index == tok_index {
                return true
            }
        }

        return false
    }

    fn divergent_spelling(self, tok_index: usize) -> string {
        for var i: usize = 0; i < self._pending.size(); ++i {
            var unsafe *p = self._pending.get(i)
            if p->tok_index != tok_index {
                continue
            }

            return string(
                unsafe (((self._arena_text.data() as unsafe *const u8) + (p->arena_off as usize)) as *const u8),
                p->arena_len as usize,
            )
        }

        return ""
    }

    /// Kairo byte offset of token \p i in whichever fid it blames, or
    /// u32(-1) if it blames none (scratch, predefines). The printer's fid
    /// column says which file; filtering to the home file here hid every
    /// preamble token's offset behind a `?`.
    fn kairo_offset(self, i: usize) -> u32 {
        var unsafe *t  = self._tokens.get(i)
        var        loc = t->getLocation()
        if loc.isInvalid() {
            return u32::MAX
        }

        var dec = self._csm->getDecomposedExpansionLoc(loc)
        if self._locmap->kairo_fid(dec.first) == (u32::MAX as FileID) {
            return u32::MAX
        }

        return dec.second
    }

    /// The Kairo fid token \p i blames, or u32(-1).
    fn kairo_fid(self, i: usize) -> u32 {
        var unsafe *t  = self._tokens.get(i)
        var        loc = t->getLocation()
        if loc.isInvalid() {
            return u32::MAX
        }

        var dec = self._csm->getDecomposedExpansionLoc(loc)
        return self._locmap->kairo_fid(dec.first)
    }
}
