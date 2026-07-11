/// --- The Kairo Project -------------- Preprocessor/TokenRunCursor.k --- ///
///
///   Index cursor over a lexed TokenBuffer, implementing the shared-grammar
///   host contract for PP-side drivers. Raw kinds (pre-expansion stream).
///   Skips AtComment in bump comments inside import/macro headers are
///   legal and were silently mishandled by the old hand-rolled walkers.
///
/// ------------------------------------------------------------------------ ///

import Token::TokenBuffer::*;
import Parser::Shared::ImportGrammar::*;
import Parser::Shared::MacroHeaderGrammar::*;
import Diagnostic::Engine::*;
import Diagnostic::Registry::*;

class TokenRunCursor
  derives ImportGrammar::<TokenRunCursor>,
          MacroHeaderGrammar::<TokenRunCursor> {
    pub var toks: obs::<TokenBuffer::<512>>;
    pub var idx:  usize;
    priv var _diag: obs::<DiagEngine>; ///< &null legal: scan-only mode (DepScanner)

    fn TokenRunCursor(self, toks: *(TokenBuffer::<512>), start: usize, diag: *DiagEngine) {
        self.toks  = toks;
        self.idx   = start;
        self._diag = diag;
        self._skip_comments();
    }

    priv fn _skip_comments(self) {
        while (self.idx < self.toks->size())
           && (self.toks->get(self.idx)->kind == TokenKind::AtComment) {
            self.idx += 1;
        }
    }

    fn ig_kind(self) -> TokenKind {
        if self.idx >= self.toks->size() { return TokenKind::TkEof; }
        return self.toks->get(self.idx)->kind;
    }

    fn ig_peek_kind(self) -> TokenKind {
        var j = self.idx + 1;
        while (j < self.toks->size())
           && (self.toks->get(j)->kind == TokenKind::AtComment) { j += 1; }
        if j >= self.toks->size() { return TokenKind::TkEof; }
        return self.toks->get(j)->kind;
    }

    fn ig_tok(self) -> Token {
        if self.idx >= self.toks->size() { var t = Token(); t.kind = TokenKind::TkEof; return t; }
        return *(self.toks->get(self.idx));
    }

    fn ig_bump(self) {
        if self.idx < self.toks->size() { self.idx += 1; }
        self._skip_comments();
    }

    fn ig_bump_nl(self) {
        self.ig_bump();
        while (self.idx < self.toks->size())
           && (self.toks->get(self.idx)->kind == TokenKind::TkNewLine) {
            self.idx += 1;
            self._skip_comments();
        }
    }

    fn ig_eof(self) -> bool { return self.idx >= self.toks->size(); }

    fn ig_err(self, r: SourceRange, msg: string, code: DiagID) {
        if self._diag == &null { return; } // scan-only: DepScanner stays silent,
                                           // real diagnostics come from the PP pass
        self._diag->report(DiagCode(code), r.start, msg).first(r).emit();
    }
}