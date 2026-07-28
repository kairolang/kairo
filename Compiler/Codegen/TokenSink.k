/// --- The Kairo Project ----------------------- Codegen/TokenSink.k ------ ///
///
///   \brief THE place clang::Token is constructed. Emitters append through
///          the typed helpers (punct/id/str_lit/num/num_arena/str_arena);
///          nothing else in the compiler builds a clang token, ever.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "clang/Basic/SourceManager.h";
ffi "c++" import "clang/Basic/SourceLocation.h";
ffi "c++" import "clang/Basic/TokenKinds.h";
ffi "c++" import "clang/Lex/Preprocessor.h";
ffi "c++" import "clang/Lex/Token.h";

import Memory::ArenaAllocator::*;
import Memory::ArenaList::*;
import Location::SourceLocation::*;

/// One divergent-literal token awaiting its real ExpansionLoc. Recorded at
/// emit time (phase 1), consumed by patch_pending (phase 2).
struct PendingArenaTok {
    var tok_index: usize;   ///< index into _tokens
    var arena_off: u32;     ///< offset of the C++ spelling in _arena_text
    var arena_len: u32;     ///< length of the C++ spelling
    var kro_off:   u32;     ///< .kro expansion start (byte offset in kfid)
    var kro_len:   u32;     ///< .kro span length
}

class TokenSink {
    priv var _pp:    obs::<clang::Preprocessor>;
    priv var _csm:   obs::<clang::SourceManager>;
    priv var _cfid:  clang::FileID;              ///< clang FileID of the .kro buffer
    priv var _ksize: u32 = 0;                    ///< byte size of the Kairo file

    priv var _tokens:  ArenaList::<clang::Token>;
    priv var _pending: ArenaList::<PendingArenaTok>;

    priv var _arena_text: libcxx::string;
    priv var _dedup:      libcxx::unordered_map::<libcxx::string, u32>;
    priv var _sealed:     bool = false;

    /// \param arena  external arena for the token/pending lists; the caller
    ///               (CodegenBackend) guarantees it outlives the sink. The
    ///               TU's ASTContext node arena is the intended donor.
    fn TokenSink(self, pp: *clang::Preprocessor, csm: *clang::SourceManager,
                 cfid: clang::FileID, ksize: u32, arena: *ArenaAllocator) {
        self._pp    = pp;
        self._csm   = csm;
        self._cfid  = cfid;
        self._ksize = ksize;
        self._tokens.set_allocator(arena, 512);
        self._pending.set_allocator(arena, 64);
        self._arena_text.reserve(4096);
    }

    /// clang SourceLocation for a byte offset in the Kairo file. Out-of-file
    /// offsets are an EMITTER bug (a synthesized node whose lowered-from
    /// range was never stamped): ICE, never clamp.
    priv fn _kloc(self, off: u32) -> clang::SourceLocation {
        std::ICE(off < self._ksize,
            f"TokenSink: offset {off} is past end of Kairo file (size {self._ksize}); "
            "a synthesized node must carry its lowered-from range");
        return self._csm->getComposedLoc(self._cfid, off);
    }

    /// Punctuator / keyword-kind token borrowing its exact .kro bytes.
    fn punct(self, k: clang::tok::TokenKind, off: u32, len: u32) {
        var t = self._tokens.slot();
        t->startToken();
        t->setKind(k);
        t->setLocation(self._kloc(off));
        t->setLength(len);
    }

    /// Identifier from raw UTF-8 bytes. HOT PATH emitters pass
    /// imm-interner views (ctx->get_imm_table()->ident_bytes/ident_len),
    /// zero copies, zero transcodes. Bytes must outlive the parse: source
    /// mmaps and synth_names both do; anything else is an emitter bug.
    fn id(self, data: std::ConstPtr::<u8>, len: usize, off: u32, tok_len: u32) {
        var t = self._tokens.slot();
        t->startToken();
        t->setKind(clang::tok::identifier);
        t->setIdentifierInfo(self._pp->getIdentifierInfo(llvm::StringRef(
            reinterpret_cast::<std::ConstPtr::<std::Legacy::char>>(data), len)));
        t->setLocation(self._kloc(off));
        t->setLength(tok_len);
    }

    /// Byte-spelling convenience for synthesized/keyword identifiers the
    /// emitter has as a compile-time literal (pass r"...").
    fn id_lit(self, name: std::ConstPtr::<std::Legacy::char>, len: usize, off: u32, tok_len: u32) {
        var t = self._tokens.slot();
        t->startToken();
        t->setKind(clang::tok::identifier);
        t->setIdentifierInfo(self._pp->getIdentifierInfo(llvm::StringRef(name, len)));
        t->setLocation(self._kloc(off));
        t->setLength(tok_len);
    }

    /// String literal, byte view, spelling INCLUDES quotes. CreateString
    /// copies into clang scratch, so the view may die after the call.
    fn str_lit(self, data: std::ConstPtr::<u8>, len: usize, off: u32) {
        var t = self._tokens.slot();
        t->startToken();
        t->setKind(clang::tok::string_literal);
        var loc = self._kloc(off);
        self._pp->CreateString(llvm::StringRef(
            reinterpret_cast::<std::ConstPtr::<std::Legacy::char>>(data), len), *t, loc, loc);
    }

    fn str_lit(self, spelling: std::ConstPtr::<std::Legacy::char>, len: usize, off: u32) {
        var t = self._tokens.slot();
        t->startToken();
        t->setKind(clang::tok::string_literal);
        self._pp->CreateString(llvm::StringRef(spelling, len), *t);
        var scratch = t->getLocation();
        var kstart  = self._kloc(off);
        var wrapped = self._csm->createExpansionLoc(
            scratch, kstart, kstart, len, true);
        t->setLocation(wrapped);
    }
    /// Numeric literal from a compile-time byte spelling (pass r"...").
    /// Twin of id_lit; the byte-view num() is for source-backed spellings.
    fn num_lit(self, spelling: std::ConstPtr::<std::Legacy::char>, len: usize, off: u32) {
        var t = self._tokens.slot();
        t->startToken();
        t->setKind(clang::tok::numeric_constant);
        var loc = self._kloc(off);
        self._pp->CreateString(llvm::StringRef(spelling, len), *t, loc, loc);
    }

    /// Numeric literal, byte view, text-identical to source.
    fn num(self, data: std::ConstPtr::<u8>, len: usize, off: u32) {
        var t = self._tokens.slot();
        t->startToken();
        t->setKind(clang::tok::numeric_constant);
        var loc = self._kloc(off);
        self._pp->CreateString(llvm::StringRef(
            reinterpret_cast::<std::ConstPtr::<std::Legacy::char>>(data), len), *t, loc, loc);
    }

    fn eof(self, off: u32) {
        var t = self._tokens.slot();
        t->startToken();
        t->setKind(clang::tok::eof);
        t->setLocation(self._kloc(off));
        t->setLength(0);
    }

    fn num_arena(self, cxx_value: ref!(nstring), kro_off: u32, kro_len: u32) {
        self._emit_arena_tok(clang::tok::numeric_constant, cxx_value, kro_off, kro_len);
    }

    fn str_arena(self, cxx_spelling: ref!(nstring), kro_off: u32, kro_len: u32) {
        self._emit_arena_tok(clang::tok::string_literal, cxx_spelling, kro_off, kro_len);
    }

    priv fn _intern(self, s: ref!(nstring)) -> u32 {
        std::ICE(!self._sealed, "TokenSink: intern after arena registration");
        var key = libcxx::string(s.raw_string());
        var it = self._dedup.find(key);
        if it != self._dedup.end() { return it->second; }
        var off = static_cast::<u32>(self._arena_text.size());
        self._arena_text.append(key);
        self._dedup.insert(libcxx::make_pair(key, off));
        return off;
    }

    priv fn _emit_arena_tok(self, k: clang::tok::TokenKind, spelling: ref!(nstring),
                            kro_off: u32, kro_len: u32) {
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
        p->kro_off   = kro_off;
        p->kro_len   = kro_len;
    }

    fn has_arena(self) -> bool { return self._arena_text.size() > 0; }

    /// The literal-arena bytes for registration as <kairo-literals>. Seals
    /// the arena: no further intern. The returned view aliases _arena_text,
    /// which outlives the parse because the sink outlives the TU run.
    fn seal_arena(self) -> llvm::StringRef {
        self._sealed = true;
        return llvm::StringRef(self._arena_text.data(), self._arena_text.size());
    }

    /// Patch every pending token with its real ExpansionLoc now that the
    /// arena buffer exists as \p afid. Spelling loc in the arena, expansion
    /// range on the original .kro bytes.
    fn patch_pending(self, afid: clang::FileID) {
        std::ICE(self._sealed || self._pending.empty(),
            "TokenSink: patch_pending before seal_arena");
        for var i: usize = 0; i < self._pending.size(); ++i {
            var p = self._pending.get(i);
            var spelling = self._csm->getComposedLoc(afid, p->arena_off);
            var loc = self._csm->createExpansionLoc(
                spelling,
                self._kloc(p->kro_off),
                self._kloc(p->kro_off + p->kro_len - 1),
                static_cast::<usize>(p->arena_len),
                true /* ExpansionIsTokenRange */);
            var t = self._tokens.get(p->tok_index);
            t->setLocation(loc);
            t->setLength(p->arena_len);
        }
    }

    fn token_count(self) -> usize { return self._tokens.size(); }
    fn get_token(self, i: usize) -> *clang::Token { return self._tokens.get(i); }

    /// Copy the build store into a clang-owned contiguous array and enter
    /// it into the preprocessor. The copy is REQUIRED: EnterTokenStream
    /// takes ownership and deletes the array never hand it arena memory.
    fn drain_into_pp(self) {
        std::ICE(self._pending.empty() || self._sealed,
            "TokenSink: drain with unpatched pending tokens");
        var n = self._tokens.size();
        std::ICE(n > 0, "TokenSink: drain on empty stream");

        var arr = libcxx::make_unique::<std::Legacy::array::<clang::Token>>(n);
        for (var i: usize = 0; i < n; ++i) {
            arr[i] = *(self._tokens.get(i));
        }

        self._pp->EnterTokenStream(libcxx::move(arr), n,
            /*DisableMacroExpansion=*/true, /*IsReinject=*/true);
    }
}