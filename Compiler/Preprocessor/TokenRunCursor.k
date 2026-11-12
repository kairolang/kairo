/// --- The Kairo Project ---------------- Preprocessor/TokenRunCursor.k --- ///
///
///   TokenRunCursor: hosts the shared grammars over a lexed TokenBuffer.
///
///   It implements the shared-grammar host contract for PP-side drivers, over
///   raw kinds (the pre-expansion stream). Skips AtComment in bump: comments
///   inside import/macro headers are legal.
///
/// ------------------------------------------------------------------------ ///

import Diagnostic::Code::*
import Diagnostic::Engine::*
import Diagnostic::Registry::*
import Location::SourceRange::*
import Parser::Shared::ImportGrammar::*
import Parser::Shared::MacroHeaderGrammar::*
import Token::Token::*
import Token::TokenBuffer::*
import Token::TokenKind::*

pub class TokenRunCursor
  derives ImportGrammar<TokenRunCursor>,
          MacroHeaderGrammar<TokenRunCursor> {
    pub var  toks:  *TokenBuffer<512>
    pub var  idx:   usize
    priv var _diag: *DiagEngine?      ///< &null legal: scan-only mode (DepScanner)

    fn TokenRunCursor(self, toks: unsafe *(TokenBuffer<512>), start: usize, diag: *DiagEngine) {
        self.toks  = toks
        self.idx   = start
        self._diag = diag
        self._skip_comments()
    }

    priv fn _skip_comments(self) {
        while self.idx < self.toks->size()
            && self.toks->get(self.idx)->kind == TokenKind::AtComment {
            self.idx += 1
        }
    }

    fn ig_kind(self) -> TokenKind {
        if self.idx >= self.toks->size() {
            return TokenKind::TkEof
        }

        return self.toks->get(self.idx)->kind
    }

    fn ig_peek_kind(self) -> TokenKind {
        var j = self.idx + 1
        while j < self.toks->size() && self.toks->get(j)->kind == TokenKind::AtComment {
            j += 1
        }

        if j >= self.toks->size() {
            return TokenKind::TkEof
        }

        return self.toks->get(j)->kind
    }

    fn ig_tok(self) -> Token {
        if self.idx >= self.toks->size() {
            var t = Token()
            t.kind = TokenKind::TkEof
            return t
        }

        return *self.toks->get(self.idx)
    }

    fn ig_bump(self) {
        if self.idx < self.toks->size() {
            self.idx += 1
        }

        self._skip_comments()
    }

    fn ig_bump_nl(self) {
        self.ig_bump()
        while self.idx < self.toks->size()
            && self.toks->get(self.idx)->kind == TokenKind::TkNewLine {
            self.idx += 1
            self._skip_comments()
        }
    }

    fn ig_eof(self) -> bool {
        return self.idx >= self.toks->size()
    }

    fn ig_err(self, r: SourceRange, msg: string, code: DiagID) {
        if self._diag == &null { // scan-only: DepScanner stays silent,
            return
        }

        // real diagnostics come from the PP pass
        self._diag->report(DiagCode(code), r.start, msg).first(r)->emit()
    }

    fn ig_err_remove(self,
                     r:       SourceRange,
                     msg:     string,
                     code:    DiagID,
                     cut:     SourceRange,
                     fix_msg: string) {
        if self._diag == &null {
            return
        }

        var b = self._diag->report(DiagCode(code), r.start, msg)
        b.first(r)
        b.remove(cut, fix_msg)
        b.emit()
    }

    fn ig_err_insert(self,
                     r:       SourceRange,
                     msg:     string,
                     code:    DiagID,
                     at:      SourceRange,
                     text:    string,
                     fix_msg: string) {
        if self._diag == &null {
            return
        }

        var b = self._diag->report(DiagCode(code), r.start, msg)
        b.first(r)
        b.insert(at.start, text, fix_msg)
        b.emit()
    }
}
