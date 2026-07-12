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

class TokenSource {
    struct SpliceFrame {
        var tokens:     obs::<TokenBuffer::<512>>; ///< NOT owned here; owner is the
                                                   ///  PP's per-run splice scratch list
        var cursor:     usize;
        var macro_name: SymbolID;    ///< producer; identifies chain membership
        var invoke_loc: SourceRange;
        var serial:     u64 = 0;     ///< unique dynamic expansion instance
    }

    priv var _lexer:       obs::<Lexer>;
    priv var _ring:        vec::<Token>;   ///< frame-0 lookahead
    priv var _frames:      vec::<SpliceFrame>;
    priv var _next_serial: u64  = 0;
    priv var _eof_seen:    bool = false;   ///< lexer has emitted its TkEof
    priv var _ring_eof:    bool = false;   ///< TkEof sitting in the ring / consumed

    fn TokenSource(self, lexer: *Lexer) {
        self._lexer = lexer;
        self._ring.reserve(4);
    }

    // --- frame stack (== expansion chain) --------------------------------

    fn push_splice(
        self,
        tokens: *(TokenBuffer::<512>),
        name: SymbolID,
        loc: SourceRange
    ) {
        self._next_serial += 1;

        var f = SpliceFrame();
        f.tokens     = tokens;
        f.cursor     = 0;
        f.macro_name = name;
        f.invoke_loc = loc;
        f.serial     = self._next_serial;

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
        var t = Token();
        // CONTRACT: fn Lexer::next(out: *Token) -> bool
        //   emits exactly one TkEof, returns true for it, false thereafter.
        if !self._lexer->next(&t) {
            self._eof_seen = true;
            return false;
        }
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