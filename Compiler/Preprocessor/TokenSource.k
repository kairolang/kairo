/// --- The Kairo Project ------------------ Preprocessor/TokenSource.k --- ///
///
///   Stacked token cursor for the single-pass PP walk.
///
///   Frame 0 is the streaming lexer. Frames above it are macro-expansion
///   splices. peek()/next() read the topmost live frame; exhausted splice
///   frames pop automatically. The frame stack IS the macro expansion
///   chain cycle detection is "is this name on the stack", and because
///   arguments are pre-expanded in the caller's context BEFORE a frame is
///   pushed, the quad!/square! false positive cannot occur.
///
///   Lookahead over frame 0 is buffered here (a small ring); the lexer is
///   strictly forward with no peek/rewind. Splice frames need no ring
///   they are random-access buffers.
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
import Token::TokenBuffer::*;
import Lexer::Lexer::*;
import Location::SourceRange::*;
import Preprocessor::PreprocessorSymbolTable::*; // SymbolID
import Diagnostic::Engine::*;
import Diagnostic::Registry::*;

/// \struct InvokeHop
/// \brief one active splice frame's contribution to a token's macro-origin
///        chain: where that level was invoked, and which macro produced it.
///        OUTERMOST-first order (see TokenSource::next_with_origin).
struct InvokeHop {
    var loc:  SourceRange;
    var name: SymbolID;
}

class TokenSource {
    struct SpliceFrame {
        var tokens:     obs::<TokenBuffer::<512>>; ///< NOT owned here; owner is the
                                                   ///  PP's per-run splice scratch list
        var cursor:     usize;
        var macro_name: SymbolID;    ///< producer; identifies chain membership
        var invoke_loc: SourceRange;
        var serial:     u64 = 0;     ///< unique dynamic expansion instance

        /// full origin chain THROUGH this frame (ancestors, outermost first,
        /// then this frame's own hop last), captured once at push_splice time.
        /// MUST be captured then, not read live off `_frames` later: a parent
        /// frame commonly goes exhausted-and-gets-popped by an UNRELATED
        /// _pop_dead()-triggering call (e.g. _expand's own depth() check)
        /// before a token belonging to (deeper) child frames is ever emitted,
        /// so by read time the parent may already be gone from the stack.
        var chain:      vec::<InvokeHop>;
    }

    priv var _lexer:       obs::<Lexer>;
    priv var _ring:        vec::<Token>;   ///< frame-0 lookahead
    priv var _frames:      vec::<SpliceFrame>;
    priv var _next_serial: u64  = 0;
    priv var _eof_seen:    bool = false;   ///< lexer has emitted its TkEof
    priv var _ring_eof:    bool = false;   ///< TkEof sitting in the ring / consumed

    priv var _diag:            obs::<DiagEngine> = &null; ///< null = no budget enforced (DAG scan pass)
    priv var _max_token_count: i32  = 0;    ///< 0 = unlimited; --cmax-token-count
    priv var _pulled_count:    usize = 0;   ///< frame-0 tokens pulled from the lexer
    priv var _budget_reported: bool = false;

    fn TokenSource(self, lexer: *Lexer) {
        self._lexer = lexer;
        self._ring.reserve(4);
    }

    /// \param max_token_count 0 = unlimited. \param diag used to report S065E once,
    ///        past the cap; pass &null (the other ctor) to enforce nothing, as the
    ///        DAG scanner's scan-only pass does its budget belongs to the real walk.
    fn TokenSource(self, lexer: *Lexer, max_token_count: i32, diag: *DiagEngine) {
        self._lexer           = lexer;
        self._max_token_count = max_token_count;
        self._diag            = diag;
        self._ring.reserve(4);
    }

    // --- frame stack (== expansion chain) --------------------------------

    /// \param parent_chain the chain to inherit, captured by the CALLER at
    ///        invocation-DETECTION time (InvocationInfo.parent_chain), not
    ///        derived here from `self._frames`. By the time push_splice runs
    ///        (end of _expand, after its own depth()/budget checks), an
    ///        exhausted parent frame may already have been popped by one of
    ///        THOSE checks reading self._frames here would silently lose it.
    ///        See TokenSource::current_chain / PPWalker::_detect_invocation.
    fn push_splice(
        self,
        tokens: *(TokenBuffer::<512>),
        name: SymbolID,
        loc: SourceRange,
        parent_chain: *vec::<InvokeHop>
    ) {
        self._next_serial += 1;

        var f = SpliceFrame();
        f.tokens     = tokens;
        f.cursor     = 0;
        f.macro_name = name;
        f.invoke_loc = loc;
        f.serial     = self._next_serial;

        for var i: usize = 0; i < parent_chain->size(); ++i {
            f.chain.push_back((*parent_chain)[i]);
        }
        // An invalid loc (e.g. _expand_buffer's synthetic argument-pre-expand
        // frame) contributes no hop of its own but still passes the parent
        // chain through transparently.
        if loc.is_valid() {
            var hop = InvokeHop();
            hop.loc  = loc;
            hop.name = name;
            f.chain.push_back(hop);
        }

        self._frames.push_back(f);
    }

    fn current_expansion_serial(self) -> u64 {
        if self._frames.size() == 0 {
            return 0;
        }

        return self._frames.back().serial;
    }

    fn depth(self) -> usize {
        self._pop_dead();
        return self._frames.size();
    }

    fn in_splice(self) -> bool {
        self._pop_dead();
        return self._frames.size() > 0;
    }

    fn in_active_chain(self, name: SymbolID) -> bool {
        if name == 0 { return false; }
        for f in self._frames {
            if (f.macro_name != 0) && (f.macro_name == name) { return true; }
        }
        return false;
    }

    fn snapshot_chain(self, out: *vec::<SymbolID>) {
        for f in self._frames {
            if f.macro_name != 0 { out->push_back(f.macro_name); }
        }
    }

    fn top_invoke_loc(self) -> SourceRange {
        if self._frames.size() == 0 { return SourceRange::invalid(); }
        return self._frames.back().invoke_loc;
    }

    fn bottom_invoke_loc(self) -> SourceRange {
        for var i: usize = 0; i < self._frames.size(); ++i {
            var f = &self._frames[i];
            if f->invoke_loc.is_valid() { return f->invoke_loc; }
        }
        return SourceRange::invalid();
    }

    /// \brief the chain a NEW push_splice, called right now, should inherit as
    ///        its parent: the current top frame's own already-resolved chain,
    ///        or empty if no frame is active.
    ///
    ///        Deliberately does NOT call _pop_dead() first: this is meant to
    ///        be read at invocation-DETECTION time (PPWalker::_detect_invocation,
    ///        into InvocationInfo.parent_chain), which runs before that
    ///        invocation's own _expand has any chance to pop an
    ///        exhausted-but-not-yet-popped parent frame via its depth()/budget
    ///        checks. Reading `self._frames` directly at push_splice's OWN
    ///        (later) call time would frequently be too late.
    fn current_chain(self, out: *vec::<InvokeHop>) {
        out->clear();
        if self._frames.size() == 0 { return; }
        var top = &self._frames.back();
        for var i: usize = 0; i < top->chain.size(); ++i {
            out->push_back(top->chain[i]);
        }
    }

    /// \brief like next(), but ALSO returns the pulled token's full macro-origin
    ///        chain (empty for a frame-0/non-macro token).
    ///
    ///        Reads the TOP frame's `chain` field, which push_splice already
    ///        resolved in full at push time -- NOT a live walk of `_frames`.
    ///        A live walk would be wrong: a parent frame routinely goes
    ///        exhausted-and-gets-popped (via an unrelated _pop_dead()-triggering
    ///        call, e.g. _expand's own depth() check) before a token belonging
    ///        to a deeper child frame is ever pulled, so by the time this runs
    ///        the parent may already be gone from `_frames` even though it's
    ///        very much still part of this token's origin.
    ///
    ///        Order: OUTERMOST hop first (index 0), INNERMOST last -- the
    ///        order PPWalker::_wrap_origin wants for building the expansion
    ///        chain attach_macro_expansion_chain (ASTParse.k) later walks
    ///        outward, ending on the true call site.
    fn next_with_origin(self, out_chain: *vec::<InvokeHop>) -> Token {
        out_chain->clear();
        self._pop_dead();

        if self._frames.size() > 0 {
            var top = &self._frames.back();
            for var i: usize = 0; i < top->chain.size(); ++i {
                out_chain->push_back(top->chain[i]);
            }
        }

        return self.next();
    }

    // --- internal: keep the topmost frame live ---------------------------

    priv fn _pop_dead(self) {
        while self._frames.size() > 0 {
            var top = &self._frames.back();
            if top->cursor < top->tokens->size() { return; }
            self._frames.pop_back();
        }
    }

    /// pull one lexer token into the ring; returns false at true exhaustion.
    priv fn _pull_into_ring(self) -> bool {
        if self._eof_seen { return false; }

        if (self._max_token_count > 0) && (self._pulled_count >= usize(self._max_token_count)) {
            if (!self._budget_reported) && (self._diag != &null) {
                self._budget_reported = true;
                self._diag->report(DiagID::S065E,
                    f"preprocessor token budget exceeded (limit {self._max_token_count}); "
                    "raise it with --cmax-token-count=N"
                ).emit();
            }
            self._eof_seen = true;
            return false;
        }

        var t = Token();
        // CONTRACT: fn Lexer::next(out: *Token) -> bool
        //   emits exactly one TkEof, returns true for it, false thereafter.
        if !self._lexer->next(&t) {
            self._eof_seen = true;
            return false;
        }
        self._pulled_count += 1;
        if t.kind == TokenKind::TkEof {
            self._eof_seen = true;
        }
        self._ring.push_back(t);
        return true;
    }

    // --- cursor ----------------------------------------------------------

    fn peek(self, n: usize = 0) -> Token {
        self._pop_dead();

        if self._frames.size() > 0 {
            var top = &self._frames.back();
            var idx = top->cursor + n;
            if idx < top->tokens->size() {
                return *(top->tokens->get(idx));
            }
            // Cross-frame lookahead is refused by design: the import/macro
            // grammar needs at most peek(1) and legal input never splits a
            // construct across a splice boundary. Return a non-match token.
            var u = Token();
            u.kind = TokenKind::TkUnknown;
            return u;
        }

        // frame 0: fill ring to n
        while self._ring.size() <= n {
            if !self._pull_into_ring() {
                var e = Token();
                e.kind = TokenKind::TkEof;
                return e;
            }
        }
        return self._ring[n];
    }

    fn next(self) -> Token {
        self._pop_dead();

        if self._frames.size() > 0 {
            var top = &self._frames.back();
            var t = *(top->tokens->get(top->cursor));
            top->cursor += 1;
            return t;
        }

        if self._ring.size() > 0 {
            var t = self._ring[0];
            self._ring.erase(self._ring.begin()); // small ring; fine
            if t.kind == TokenKind::TkEof { self._ring_eof = true; }
            return t;
        }

        if !self._pull_into_ring() {
            var e = Token();
            e.kind = TokenKind::TkEof;
            self._ring_eof = true;
            return e;
        }
        var t = self._ring[0];
        self._ring.erase(self._ring.begin());
        if t.kind == TokenKind::TkEof { self._ring_eof = true; }
        return t;
    }

    fn at_eof(self) -> bool {
        self._pop_dead();
        if self._frames.size() > 0 { return false; }
        // exhausted when: lexer done, ring empty (or only a consumed TkEof)
        if self._ring.size() > 0 {
            if (self._ring.size() == 1) && (self._ring[0].kind == TokenKind::TkEof) {
                return true;
            }
            return false;
        }
        return self._eof_seen;
    }
}