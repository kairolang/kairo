/// --- The Kairo Project ------------------ Preprocessor/StreamCursor.k --- ///
///
///   StreamCursor: hosts the shared grammars over a forward TokenSource.
///
///   Gives ImportGrammar and MacroHeaderGrammar the ig_* methods against a
///   forward stream, in scan-only (silent) or diagnostic mode. DepScanner
///   drives it over its scan stream; PPWalker over its walk stream, silent
///   while the walk is quiet. The grammars read the stream only through
///   these methods, so both hosts see the same tokens.
///
/// ------------------------------------------------------------------------ ///

import Diagnostic::Code::DiagCode
import Diagnostic::Engine::DiagEngine
import Diagnostic::Registry::DiagID
import Location::SourceRange::SourceRange
import Parser::Shared::ImportGrammar::{
    ImportGrammar,
    ig_finish,
    ig_finish_insert,
    ig_finish_remove,
}
import Parser::Shared::MacroHeaderGrammar::{
    MacroHeader,
    MacroHeaderGrammar,
}
import Preprocessor::TokenSource::TokenSource
import Token::Token::Token
import Token::TokenKind::TokenKind

pub class StreamCursor
  derives ImportGrammar<StreamCursor>,
          MacroHeaderGrammar<StreamCursor> {
    priv var _src:  *TokenSource
    priv var _diag: unsafe *DiagEngine ///< null = scan-only, silent

    fn StreamCursor(self, src: *TokenSource, diag: unsafe *DiagEngine) {
        self._src  = src
        self._diag = diag
    }

    /// MacroHeaderGrammar::parse_macro_header for a host outside the Parser
    /// module, where the grammar's method is not visible.
    pub fn macro_header(self) -> MacroHeader {
        return self.parse_macro_header()
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
        if self._diag == &null {
            return
        }

        var b = self._diag->report(DiagCode(code), r.start, msg)
        ig_finish(&b, r)
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
        ig_finish_remove(&b, r, cut, fix_msg)
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
        ig_finish_insert(&b, r, at, text, fix_msg)
    }
}
