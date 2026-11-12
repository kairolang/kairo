/// --- The Kairo Project ------------------ Preprocessor/StreamCursor.k --- ///
///
///   StreamCursor: hosts the shared grammars over a forward TokenSource.
///
///   Gives ImportGrammar (and any future shared grammar) the ig_* methods
///   against a forward stream, in scan-only (silent) or diagnostic mode.
///   DepScanner drives this; PPWalker hosts the grammars itself because its
///   ig_err reports and its stream is entangled with expansion -- do NOT try to
///   unify them.
///
/// ------------------------------------------------------------------------ ///

import Diagnostic::Code::DiagCode
import Diagnostic::Engine::DiagEngine
import Diagnostic::Registry::DiagID
import Location::SourceRange::SourceRange
import Parser::Shared::ImportGrammar::ImportGrammar
import Preprocessor::TokenSource::TokenSource
import Token::Token::Token
import Token::TokenKind::TokenKind

pub class StreamCursor
  derives ImportGrammar<StreamCursor> {
    priv var _src:  *TokenSource
    priv var _diag: unsafe *DiagEngine ///< null = scan-only, silent

    fn StreamCursor(self, src: *TokenSource, diag: unsafe *DiagEngine) {
        self._src  = src
        self._diag = diag
    }

    fn ig_kind(self) -> TokenKind {
        return self._src->peek(0).kind
    }

    fn ig_peek_kind(self) -> TokenKind {
        return self._src->peek(1).kind
    }

    fn ig_tok(self) -> Token {
        return self._src->peek(0)
    }

    fn ig_bump(self) {
        self._src->next()
    }

    fn ig_bump_nl(self) {
        self._src->next()
        while self._src->peek(0).kind == TokenKind::TkNewLine {
            self._src->next()
        }
    }

    fn ig_eof(self) -> bool {
        return self._src->at_eof()
    }

    fn ig_err(self, r: SourceRange, const msg: string, code: DiagID) {
        if self._diag == &null { // scan-only: swallow
            return
        }

        self._diag->report(DiagCode(code), r.start, msg).first(r)->emit()
    }

    fn ig_err_remove(self,
                     r:             SourceRange,
                     const msg:     string,
                     code:          DiagID,
                     cut:           SourceRange,
                     const fix_msg: string) {
        if self._diag == &null {
            return
        }

        var b = self._diag->report(DiagCode(code), r.start, msg)
        b.first(r)
        b.remove(cut, fix_msg)
        b.emit()
    }

    fn ig_err_insert(self,
                     r:             SourceRange,
                     const msg:     string,
                     code:          DiagID,
                     at:            SourceRange,
                     const text:    string,
                     const fix_msg: string) {
        if self._diag == &null {
            return
        }

        var b = self._diag->report(DiagCode(code), r.start, msg)
        b.first(r)
        b.insert(at.start, text, fix_msg)
        b.emit()
    }
}
