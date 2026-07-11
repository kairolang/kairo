/// --- The Kairo Project ------------------ Preprocessor/StreamCursor.k --- ///
///
///   Grammar host over a TokenSource. Gives ImportGrammar (and any future
///   shared grammar) the six ig_* methods against a forward stream, in
///   scan-only (silent) or diagnostic mode. DepScanner drives this;
///   PPWalker hosts the grammars itself because its ig_err reports and its
///   stream is entangled with expansion do NOT try to unify them.
///
/// ------------------------------------------------------------------------ ///

import Token::Token::*;
import Token::TokenKind::*;
import Preprocessor::TokenSource::*;
import Parser::Shared::ImportGrammar::*;
import Diagnostic::Engine::*;
import Diagnostic::Registry::*;

class StreamCursor
  derives ImportGrammar::<StreamCursor> {

    priv var _src:  obs::<TokenSource>;
    priv var _diag: obs::<DiagEngine>;   ///< null = scan-only, silent

    fn StreamCursor(self, src: *TokenSource, diag: *DiagEngine) {
        self._src  = src;
        self._diag = diag;
    }

    fn ig_kind(self)      -> TokenKind { return self._src->peek(0).kind; }
    fn ig_peek_kind(self) -> TokenKind { return self._src->peek(1).kind; }
    fn ig_tok(self)       -> Token     { return self._src->peek(0);      }
    fn ig_bump(self)                   { self._src->next();              }
    fn ig_bump_nl(self) {
        self._src->next();
        while self._src->peek(0).kind == TokenKind::TkNewLine { self._src->next(); }
    }
    fn ig_eof(self) -> bool { return self._src->at_eof(); }
    fn ig_err(self, r: SourceRange, msg: string, code: DiagID) {
        if self._diag == &null { return; } // scan-only: swallow
        self._diag->report(DiagCode(code), r.start, msg).first(r).emit();
    }
}