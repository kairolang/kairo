/// --- The Kairo Project ----------------------- Codegen/TokenSink.k ------ ///
///
///   \brief THE place clang::Token is constructed. Emitters call the
///          accumulators below; nothing else in the compiler builds a clang
///          token, ever.
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
///     "Length is free" is the most surprising and most load-bearing fact in
///     this file. A token's length is CARET GEOMETRY, not spelling. That is
///     what lets `fn` become kw_auto with length 2: nothing ever reads those
///     two bytes, so the span stays on what the user wrote while the parser
///     sees a four-letter keyword. Set a literal's length wrong and you get a
///     different literal; set a keyword's length wrong and you get a caret in
///     the wrong place, silently.
///
///   \par create / synth / create_*
///       create(t)          kind AND spelling derive from the token.
///                          Identifiers, punctuators, operators. A KEYWORD
///                          token is an ICE   a Kairo keyword has no
///                          automatic C++ meaning, so every keyword emission
///                          must be a named, deliberate call (kw_auto, ...).
///       synth(span, kind)  kind supplied, span borrowed. Covers structural
///                          keywords and BORROWED literals (a borrowed
///                          literal's span IS its spelling, so it satisfies
///                          the literal rule for free).
///       create_int/str     DIVERGENT literals only: bytes clang cannot find
///                          in the Kairo buffer, so they go to the arena and
///                          get a real ExpansionLoc in patch_pending.
///
///     Note the asymmetry: create/synth are pure appends, create_int/str
///     mutate arena + pending state. That is not an inconsistency   it is
///     exactly the borrowed/divergent distinction the location model rests
///     on, showing through the API instead of being hidden by it.
///
///   \par Accumulators return bool
///     true == a token was appended. Invariant violations (keyword through
///     create, unmapped punctuator, span outside the file) are ICEs, not
///     false   codegen has no diagnostics, so there is nothing for a caller
///     to do with a recoverable failure. false is reserved for "legitimately
///     emitted nothing", which composes with map/fold/variadic emit.
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
import Location::SourceRange::*;
import Token::Token::*;
import Token::TokenKind::*;

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
    priv var _pp:   obs::<clang::Preprocessor>;
    priv var _csm:  obs::<clang::SourceManager>;
    priv var _cfid: clang::FileID;          ///< clang FileID of this TU's file

    // --- The location arithmetic ---------------------------------------------
    //
    //  Kairo locations are GLOBAL: raw() indexes the whole session address
    //  space. clang locations are global too, but the two spaces disagree
    //  because VirtualFileManager 4 KB-aligns each file's base and clang
    //  packs. Within ONE file both advance byte for byte, so the difference is
    //  a constant:
    //
    //      kbase = ksm->get_loc(kfid, 0).raw()
    //      cbase = csm->getLocForStartOfFile(cfid).getRawEncoding()
    //      _delta = cbase - kbase
    //
    //      clang_raw = kairo_raw + _delta            <- one add, no lookup
    //
    //  This replaces getComposedLoc(cfid, off), which needed a file-relative
    //  offset (one subtraction) and an SLocEntry lookup to undo it.

    priv var _kbase: u32 = 0;   ///< Kairo raw loc of byte 0 of this file
    priv var _delta: i64 = 0;   ///< cbase - kbase
    priv var _ksize: u32 = 0;   ///< byte size of the Kairo file

    priv var _tokens:  ArenaList::<clang::Token>;
    priv var _pending: ArenaList::<PendingArenaTok>;

    priv var _arena_text: libcxx::string;
    priv var _dedup:      libcxx::unordered_map::<libcxx::string, u32>;
    priv var _sealed:     bool = false;

    /// \param kbase  Kairo raw loc of byte 0 of this TU's file
    ///               (ClangLocMap::kairo_base).
    /// \param arena  external arena for the token/pending lists; the caller
    ///               (CodegenBackend) guarantees it outlives the sink. The
    ///               TU's ASTContext node arena is the intended donor.
    fn TokenSink(self, pp: *clang::Preprocessor, csm: *clang::SourceManager,
                 cfid: clang::FileID, kbase: u32, ksize: u32,
                 arena: *ArenaAllocator) {
        self._pp    = pp;
        self._csm   = csm;
        self._cfid  = cfid;
        self._kbase = kbase;
        self._ksize = ksize;

        var cbase = csm->getLocForStartOfFile(cfid).getRawEncoding();
        self._delta = static_cast::<i64>(cbase) - static_cast::<i64>(kbase);

        self._tokens.set_allocator(arena, 512);
        self._pending.set_allocator(arena, 64);
        self._arena_text.reserve(4096);
    }

    // --- Conversions (pure; not accumulators, so they return values) ---------

    /// Kairo punctuator/operator TokenKind -> clang punctuator kind. 1:1,
    /// lexical, no judgement. clang::tok::unknown for anything unmapped, and
    /// callers ICE on that rather than emitting a silently wrong token.
    ///
    /// Unmapped means one of two things, both bugs: a Kairo-only operator
    /// (`..`, `..=`, `?`) that Lower/ failed to reduce, or a punctuator this
    /// table has not grown yet.
    ///
    /// Keywords are deliberately absent   clang::tok::getKeywordSpelling
    /// already owns every C++ keyword spelling, and Kairo keywords have no
    /// automatic C++ meaning anyway.
    fn conv_kind(self, k: TokenKind) -> clang::tok::TokenKind {
        switch k {
            // --- brackets / grouping
            case TokenKind::OpLParen        { return clang::tok::l_paren;        }
            case TokenKind::OpRParen        { return clang::tok::r_paren;        }
            case TokenKind::OpLBrace        { return clang::tok::l_brace;        }
            case TokenKind::OpRBrace        { return clang::tok::r_brace;        }
            case TokenKind::OpLSquare       { return clang::tok::l_square;       }
            case TokenKind::OpRSquare       { return clang::tok::r_square;       }

            // --- separators
            case TokenKind::OpSemicolon     { return clang::tok::semi;           }
            case TokenKind::OpComma         { return clang::tok::comma;          }
            case TokenKind::OpColon         { return clang::tok::colon;          }
            case TokenKind::OpColonColon    { return clang::tok::coloncolon;     }
            case TokenKind::OpDot           { return clang::tok::period;         }
            case TokenKind::OpArrow         { return clang::tok::arrow;          }
            case TokenKind::OpEllipsis      { return clang::tok::ellipsis;       }

            // --- arithmetic
            case TokenKind::OpPlus          { return clang::tok::plus;           }
            case TokenKind::OpMinus         { return clang::tok::minus;          }
            case TokenKind::OpStar          { return clang::tok::star;           }
            case TokenKind::OpSlash         { return clang::tok::slash;          }
            case TokenKind::OpPercent       { return clang::tok::percent;        }
            case TokenKind::OpPlusPlus      { return clang::tok::plusplus;       }
            case TokenKind::OpMinusMinus    { return clang::tok::minusminus;     }

            // --- comparison
            case TokenKind::OpEqualEqual       { return clang::tok::equalequal;     }
            case TokenKind::OpExclaimEqual     { return clang::tok::exclaimequal;   }
            case TokenKind::OpLess             { return clang::tok::less;           }
            case TokenKind::OpGreater          { return clang::tok::greater;        }
            case TokenKind::OpLessEqual        { return clang::tok::lessequal;      }
            case TokenKind::OpGreaterEqual     { return clang::tok::greaterequal;   }
            case TokenKind::OpLessEqualGreater { return clang::tok::spaceship;      }

            // --- logical / bitwise
            case TokenKind::OpAmpAmp        { return clang::tok::ampamp;         }
            case TokenKind::OpPipePipe      { return clang::tok::pipepipe;       }
            case TokenKind::OpExclaim       { return clang::tok::exclaim;        }
            case TokenKind::OpAmp           { return clang::tok::amp;            }
            case TokenKind::OpPipe          { return clang::tok::pipe;           }
            case TokenKind::OpCaret         { return clang::tok::caret;          }
            case TokenKind::OpTilde         { return clang::tok::tilde;          }
            case TokenKind::OpLessLess      { return clang::tok::lessless;       }
            case TokenKind::OpGreaterGreater { return clang::tok::greatergreater; }

            // --- assignment
            case TokenKind::OpEqual         { return clang::tok::equal;          }
            case TokenKind::OpPlusEqual     { return clang::tok::plusequal;      }
            case TokenKind::OpMinusEqual    { return clang::tok::minusequal;     }
            case TokenKind::OpStarEqual     { return clang::tok::starequal;      }
            case TokenKind::OpSlashEqual    { return clang::tok::slashequal;     }
            case TokenKind::OpPercentEqual  { return clang::tok::percentequal;   }
            case TokenKind::OpAmpEqual      { return clang::tok::ampequal;       }
            case TokenKind::OpPipeEqual     { return clang::tok::pipeequal;      }
            case TokenKind::OpCaretEqual    { return clang::tok::caretequal;     }

            // -- misc
            case TokenKind::AtVoid          { return clang::tok::kw_void;        }
            default { return clang::tok::unknown; }
        }
    }

    /// Kairo range -> clang SourceLocation of its first byte. One add.
    fn conv_loc(self, r: SourceRange) -> clang::SourceLocation {
        return self._loc(r.start.raw());
    }

    /// Raw Kairo loc -> clang loc. Out-of-file is an EMITTER bug (a
    /// synthesized node whose lowered-from range was never stamped): ICE,
    /// never clamp.
    priv fn _loc(self, raw: u32) -> clang::SourceLocation {
        std::ICE((raw >= self._kbase) && (raw < self._kbase + self._ksize),
            f"TokenSink: raw loc {raw} is outside this TU's file [{self._kbase}, {self._kbase + self._ksize}); a synthesized node must carry its lowered-from range");
        return clang::SourceLocation::getFromRawEncoding(
            static_cast::<u32>(static_cast::<i64>(raw) + self._delta));
    }

    /// File-relative byte offset of a raw Kairo loc. Needed only where clang
    /// wants an offset rather than a location (buffer reads, pending records).
    priv fn _off(self, raw: u32) -> u32 {
        std::ICE(raw >= self._kbase, "TokenSink: raw loc precedes this file");
        return raw - self._kbase;
    }

    priv fn _bytes(self, raw: u32, len: u32) -> llvm::StringRef {
        var buf = self._csm->getBufferData(self._cfid);
        var off = self._off(raw);
        std::ICE(static_cast::<usize>(off) + static_cast::<usize>(len) <= buf.size(),
            f"TokenSink: span [{off}, {len}) is past end of the Kairo buffer");
        return buf.substr(static_cast::<usize>(off), static_cast::<usize>(len));
    }

    // --- Accumulators ---------------------------------------------------------

    /// Kind AND spelling derive from \p t. Identifiers, punctuators, operators.
    ///
    /// A KEYWORD token ICEs on purpose. `void` and `i32` are Kairo keywords
    /// with no automatic C++ meaning; deciding what they become is name lookup
    /// and therefore sema's. Lower/ rewrites them into identifier chains
    /// (`i32` is an alias to `int32_t` in the runtime), and codegen emits
    /// whatever names it is handed.
    fn create(self, t: Token) -> bool {
        var raw = t.range.start.raw();
        var len = t.range.size();

        if t.kind == TokenKind::LitIdentifier {
            return self._ident(raw, len);
        }

        std::ICE(!is_keyword(t.kind),
            "TokenSink::create on a keyword token; a Kairo keyword has no "
            "automatic C++ meaning   emit it deliberately (kw_auto, kw_return, "
            "...) or let Lower/ rewrite it into a name");

        std::ICE(is_punctuator(t.kind) || is_operator(t.kind) || (t.kind == TokenKind::AtVoid),
            "TokenSink::create accepts identifiers, punctuators and operators "
            "only; literals go through synth (borrowed) or create_int/str "
            "(divergent)");

        var k = self.conv_kind(t.kind);
        std::ICE(k != clang::tok::unknown,
            "TokenSink::create: no clang punctuator for this Kairo token kind; "
            "a Lower/ pass left an unlowered Kairo-only operator in the tree");

        return self._punct(k, raw, len);
    }

    /// Kind supplied, span borrowed from \p t.
    fn synth(self, t: Token, k: clang::tok::TokenKind) -> bool {
        return self.synth(t.range, k);
    }

    /// Kind supplied, span borrowed from \p r.
    ///
    /// Covers structural keywords (`fn` -> kw_auto keeps `fn`'s two bytes) and
    /// BORROWED literals   a borrowed literal's span IS its spelling, so it
    /// satisfies the literal rule for free. That is ICE-checked below, because
    /// it is the one case where length is not free.
    fn synth(self, r: SourceRange, k: clang::tok::TokenKind) -> bool {
        var raw = r.start.raw();
        var len = r.size();

        if clang::tok::isLiteral(k) {
            // Length is the spelling here. The bytes clang will read must be
            // the literal text, so the span has to be the real one.
            return self._literal(k, raw, len);
        }

        var kws = clang::tok::getKeywordSpelling(k);
        if kws != &null {
            // Set kind AND IdentifierInfo. Kind alone is fragile: parser and
            // Sema paths that call Tok.getIdentifierInfo() on a keyword would
            // get null.
            return self._ident_lit(kws, libcxx::strlen(kws), raw, len);
        }

        return self._punct(k, raw, len);
    }

    /// One-byte synthesized token at the START of \p r. Opening delimiters.
    fn synth_at_start(self, r: SourceRange, k: clang::tok::TokenKind) -> bool {
        return self.synth(SourceRange::from_bounds(r.start, u32(1)), k);
    }

    /// One-byte synthesized token at the LAST byte of \p r. Closing
    /// delimiters, statement terminators, separators that follow a construct.
    ///
    /// The two anchors are separate because collapsing them puts the `{` caret
    /// on the block's closing brace   a real bug this API used to have.
    fn synth_at_end(self, r: SourceRange, k: clang::tok::TokenKind) -> bool {
        var n = r.size();
        var last = r.start;
        if n > 1 { last = last.advance(static_cast::<usize>(n - 1)); }
        return self.synth(SourceRange::from_bounds(last, u32(1)), k);
    }

    // --- Divergent literals (stateful: arena + pending) -----------------------

    fn create_int(self, t: Token, cxx: ref!(nstring)) -> bool {
        return self.create_int(t.range, cxx);
    }

    fn create_int(self, r: SourceRange, cxx: ref!(nstring)) -> bool {
        return self._arena_tok(clang::tok::numeric_constant, r, cxx);
    }

    fn create_str(self, t: Token, cxx: ref!(nstring)) -> bool {
        return self.create_str(t.range, cxx);
    }

    /// \p cxx INCLUDES the quotes.
    fn create_str(self, r: SourceRange, cxx: ref!(nstring)) -> bool {
        return self._arena_tok(clang::tok::string_literal, r, cxx);
    }

    // --- Structural keywords --------------------------------------------------
    //
    //  Sugar over synth(). Every one is determined by a node KIND or a node
    //  FIELD, never by a name   that is what makes them codegen's and not
    //  sema's. Extend as emitters land; an entry here with no caller is an
    //  invitation to use it somewhere it does not belong.

    fn kw_auto(self, t: Token) -> bool      { return self.synth(t, clang::tok::kw_auto);      }
    fn kw_return(self, t: Token) -> bool    { return self.synth(t, clang::tok::kw_return);    }
    fn kw_const(self, t: Token) -> bool     { return self.synth(t, clang::tok::kw_const);     }
    fn kw_static(self, t: Token) -> bool    { return self.synth(t, clang::tok::kw_static);    }
    fn kw_constexpr(self, t: Token) -> bool { return self.synth(t, clang::tok::kw_constexpr); }
    fn kw_if(self, t: Token) -> bool        { return self.synth(t, clang::tok::kw_if);        }
    fn kw_else(self, t: Token) -> bool      { return self.synth(t, clang::tok::kw_else);      }
    fn kw_while(self, t: Token) -> bool     { return self.synth(t, clang::tok::kw_while);     }
    fn kw_for(self, t: Token) -> bool       { return self.synth(t, clang::tok::kw_for);       }
    fn kw_break(self, t: Token) -> bool     { return self.synth(t, clang::tok::kw_break);     }
    fn kw_continue(self, t: Token) -> bool  { return self.synth(t, clang::tok::kw_continue);  }
    fn kw_switch(self, t: Token) -> bool    { return self.synth(t, clang::tok::kw_switch);    }
    fn kw_case(self, t: Token) -> bool      { return self.synth(t, clang::tok::kw_case);      }
    fn kw_default(self, t: Token) -> bool   { return self.synth(t, clang::tok::kw_default);   }

    /// End of stream. Zero length, so it can never be mistaken for a real
    /// token, anchored on the file's last byte so _loc accepts it.
    fn eof(self) -> bool {
        var raw = self._kbase + self._ksize;
        if raw > self._kbase { raw = raw - 1; }
        var t = self._tokens.slot();
        t->startToken();
        t->setKind(clang::tok::eof);
        t->setLocation(self._loc(raw));
        t->setLength(0);
        return true;
    }

    // --- Construction internals -----------------------------------------------

    priv fn _punct(self, k: clang::tok::TokenKind, raw: u32, len: u32) -> bool {
        var t = self._tokens.slot();
        t->startToken();
        t->setKind(k);
        t->setLocation(self._loc(raw));
        t->setLength(len);
        return true;
    }

    /// Borrowed identifier: the II is interned from the source bytes, and the
    /// preprocessor resolves any C++ keyword kind from it. That is how a
    /// borrowed `void` reaches the parser as kw_void without codegen ever
    /// owning a spelling -> kind table.
    priv fn _ident(self, raw: u32, len: u32) -> bool {
        var t = self._tokens.slot();
        t->startToken();
        t->setKind(clang::tok::identifier);
        t->setIdentifierInfo(self._pp->getIdentifierInfo(self._bytes(raw, len)));
        t->setLocation(self._loc(raw));
        t->setLength(len);
        return true;
    }

    priv fn _ident_lit(self, name: std::ConstPtr::<std::Legacy::char>, nlen: usize,
                       raw: u32, len: u32) -> bool {
        var t = self._tokens.slot();
        t->startToken();
        t->setKind(clang::tok::identifier);
        t->setIdentifierInfo(self._pp->getIdentifierInfo(llvm::StringRef(name, nlen)));
        t->setLocation(self._loc(raw));
        t->setLength(len);
        return true;
    }

    /// Borrowed literal. clang reads getLength() bytes at getLocation(), so
    /// the span must be the real spelling   which it is, by construction, for
    /// a borrowed literal. _bytes ICEs if it runs off the buffer.
    priv fn _literal(self, k: clang::tok::TokenKind, raw: u32, len: u32) -> bool {
        var bytes = self._bytes(raw, len);
        var t = self._tokens.slot();
        t->startToken();
        t->setKind(k);
        var loc = self._loc(raw);
        self._pp->CreateString(bytes, *t, loc, loc);
        return true;
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

    priv fn _arena_tok(self, k: clang::tok::TokenKind, r: SourceRange,
                       spelling: ref!(nstring)) -> bool {
        var raw = r.start.raw();
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
        p->kro_off   = self._off(raw);
        p->kro_len   = r.size();
        return true;
    }

    // --- Lifecycle ------------------------------------------------------------

    fn has_arena(self) -> bool { return self._arena_text.size() > 0; }

    /// The literal-arena bytes for registration as <kairo-literals>. Seals the
    /// arena: no further intern. The returned view aliases _arena_text, which
    /// outlives the parse because the sink outlives the TU run.
    fn seal_arena(self) -> llvm::StringRef {
        self._sealed = true;
        return llvm::StringRef(self._arena_text.data(), self._arena_text.size());
    }

    /// Patch every pending token with its real ExpansionLoc now that the arena
    /// buffer exists as \p afid. Spelling loc in the arena, expansion range on
    /// the original .kro bytes.
    fn patch_pending(self, afid: clang::FileID) {
        std::ICE(self._sealed || self._pending.empty(),
            "TokenSink: patch_pending before seal_arena");
        for var i: usize = 0; i < self._pending.size(); ++i {
            var p = self._pending.get(i);
            var spelling = self._csm->getComposedLoc(afid, p->arena_off);
            var loc = self._csm->createExpansionLoc(
                spelling,
                self._loc(self._kbase + p->kro_off),
                self._loc(self._kbase + p->kro_off + p->kro_len - 1),
                static_cast::<usize>(p->arena_len),
                true /* ExpansionIsTokenRange */);
            var t = self._tokens.get(p->tok_index);
            t->setLocation(loc);
            t->setLength(p->arena_len);
        }
    }

    /// Copy the build store into a clang-owned contiguous array and enter it
    /// into the preprocessor. The copy is REQUIRED: EnterTokenStream takes
    /// ownership and deletes the array   never hand it arena memory.
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

    // --- Introspection (TokenStreamPrinter) -----------------------------------

    fn token_count(self) -> usize { return self._tokens.size(); }
    fn get_token(self, i: usize) -> *clang::Token { return self._tokens.get(i); }

    fn pending_count(self) -> usize { return self._pending.size(); }
    fn get_pending(self, i: usize) -> *PendingArenaTok { return self._pending.get(i); }

    /// True when token \p tok_index took the arena (divergent-spelling) path.
    /// Linear scan on purpose: the pending list is tiny and a tok_index ->
    /// pending map would be state the sink does not otherwise need.
    fn is_divergent(self, tok_index: usize) -> bool {
        for var i: usize = 0; i < self._pending.size(); ++i {
            if self._pending.get(i)->tok_index == tok_index { return true; }
        }
        return false;
    }

    /// The interned C++ spelling of divergent token \p tok_index, or "" if the
    /// token is not divergent.
    fn divergent_spelling(self, tok_index: usize) -> string {
        for var i: usize = 0; i < self._pending.size(); ++i {
            var p = self._pending.get(i);
            if p->tok_index != tok_index { continue; }
            return string(self._arena_text.data() + static_cast::<usize>(p->arena_off),
                          static_cast::<usize>(p->arena_len));
        }
        return "";
    }

    /// Kairo byte offset of token \p i, or u32(-1) if it does not resolve into
    /// the Kairo file. Decomposes through the EXPANSION loc so borrowed and
    /// divergent tokens answer the same question: which .kro bytes does this
    /// token blame.
    fn kairo_offset(self, i: usize) -> u32 {
        var t   = self._tokens.get(i);
        var loc = t->getLocation();
        if loc.isInvalid() { return u32(-1); }

        var dec = self._csm->getDecomposedExpansionLoc(loc);
        if dec.first != self._cfid { return u32(-1); }

        return static_cast::<u32>(dec.second);
    }
}
