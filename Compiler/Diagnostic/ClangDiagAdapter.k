/// --- The Kairo Project ------------- Diagnostic/ClangDiagAdapter.k ------ ///
///
///   Adapter: clang::DiagnosticConsumer -> DiagEngine/BufferedDiagSink.
///   Translates backend diagnostics into Kairo Diagnostic objects so
///   PrettyDiagConsumer / BasicDiagConsumer render them identically to
///   frontend diagnostics. Renderers stay clang-unaware.
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "Native/Types.hh";
ffi "c++" import "clang/Basic/Diagnostic.h";
ffi "c++" import "clang/Basic/DiagnosticIDs.h";
ffi "c++" import "clang/Basic/SourceManager.h";
ffi "c++" import "llvm/ADT/SmallString.h";

import Location::SourceLocation::*;
import Location::SourceRange::*;
import Location::SourceManager::*;
import Diagnostic::Registry::*;
import Diagnostic::Engine::*;
import Diagnostic::BufferedDiagSink::*;
import Diagnostic::ClangDiagLookup::*;

/// One instance per bridged clang CompilerInstance (i.e. per TU).
/// Thread-confined: writes only to this TU's BufferedDiagSink, preserving
/// the byte-identical serial/parallel guarantee.
class ClangDiagAdapter derives clang::DiagnosticConsumer {
    pub var sink:       obs::<BufferedDiagSink>;
    pub var ksm:        obs::<SourceManager>;   ///< Kairo SM, for span construction
    pub var kfid:       FileID;                 ///< Kairo fid of the TU being compiled
    pub var clang_kfid: clang::FileID;          ///< clang FileID of the injected .kro buffer

    /// Note-attachment state: clang emits notes as separate HandleDiagnostic
    /// calls (lvl == Note) immediately after their primary. We hold the
    /// builder open (heap-allocated, owned) until the next primary or flush.
    priv var _open:        opt::<DiagBuilder> = &null; ///< owned; freed in _flush_open
    priv var _last_fwded:  bool = false;

    // ------------------------------------------------------------------
    //  clang::DiagnosticConsumer overrides
    // ------------------------------------------------------------------

    override fn BeginSourceFile(self, lo: cref::<clang::LangOptions>, pp: const_obs::<clang::Preprocessor>) {
        // nothing stashed; all queries go through Info at handle time
    }

    override fn EndSourceFile(self) {
        self._flush_open();
    }

    override fn HandleDiagnostic(self,
                        lvl:  clang::DiagnosticsEngine::Level,
                        info: cref::<clang::Diagnostic>) {
        // MANDATORY first: base impl maintains NumErrors/NumWarnings, which
        // CompilerInstance::ExecuteAction reads for pass/fail.
        clang::DiagnosticConsumer::HandleDiagnostic(lvl, info);

        var msg     = self._format(info);
        var kloc    = self._to_kairo_loc(info);      // invalid == "none"
        var is_note = lvl == clang::DiagnosticsEngine::Note;

        if (is_note) && (self._last_fwded) && (self._open != &null) {
            self._attach_child_note(kloc, msg);
            return;
        }

        self._flush_open();

        var code = self._map_code(lvl, info);        // C0xxx{E,W,R} / CL001x

        if kloc.is_valid() {
            self._open = std::create::<DiagBuilder>(
                self.sink, code, kloc.start, msg);
            self._open->first(kloc);
            self._apply_ranges_and_fixits(self._open, info);
            // stays open for trailing notes; emitted in _flush_open
        } else {
            // loc-less (cc1 args, target setup, header-blamed): plain no-loc
            self.sink->report(code, msg).emit();
            self._open = &null;                      // nothing to attach notes to
        }

        self._last_fwded = true;
    }

    override fn finish(self) { self._flush_open(); }

    // IncludeInDiagnosticCounts: leave defaulted (true).

    fn op delete (self) {
        self._flush_open();
    }

    // ------------------------------------------------------------------
    //  internals
    // ------------------------------------------------------------------

    priv fn _format(self, info: cref::<clang::Diagnostic>) -> string {
        var s: llvm::SmallString::<256>;
        info.FormatDiagnostic(s);
        return std::nstring_to_string(s.str().str());
    }

    /// clang loc -> Kairo SourceRange via EXPANSION loc (never spelling loc:
    /// arena literals spell in <kairo-literals>; expansion is the .kro span).
    /// Offsets in clang_kfid ARE byte offsets in the Kairo file, so the
    /// mapping is direct construction against ksm/kfid.
    ///
    /// Returns SourceRange::invalid() for "none": blamed in a header/runtime
    /// include -> loc-less forward; policy layer classifies.
    priv fn _to_kairo_loc(self, info: cref::<clang::Diagnostic>) -> SourceRange {
        if (!info.hasSourceManager()) || (info.getLocation().isInvalid()) {
            return SourceRange::invalid();
        }

        var dec = info.getSourceManager()
                      .getDecomposedExpansionLoc(info.getLocation());

        if dec.first != self.clang_kfid {
            return SourceRange::invalid();
        }

        // dec.second == byte offset into the .kro == byte offset in kfid.
        // Single-byte primary span; ranges/fixits widen it in
        // _apply_ranges_and_fixits.
        return self.ksm->get_range(self.kfid, static_cast::<usize>(dec.second), 1);
    }

    /// Translates one clang CharSourceRange into a Kairo SourceRange,
    /// or invalid if either endpoint escapes clang_kfid.
    priv fn _range_in_kfid(self, cr: cref::<clang::CharSourceRange>, info: cref::<clang::Diagnostic>) -> SourceRange {
        if (!cr.isValid()) || (!info.hasSourceManager()) {
            return SourceRange::invalid();
        }

        var b = info.getSourceManager().getDecomposedExpansionLoc(cr.getBegin());
        var e = info.getSourceManager().getDecomposedExpansionLoc(cr.getEnd());

        if (b.first != self.clang_kfid) || (e.first != self.clang_kfid) {
            return SourceRange::invalid();
        }

        var start: usize = static_cast::<usize>(b.second);
        var end:   usize = static_cast::<usize>(e.second);

        // Token ranges end at the START of the last token. Without dragging
        // clang::Lexer::MeasureTokenLength (needs stashed LangOptions) into
        // the adapter, cover at least the first byte of that token.
        // TODO(diag): exact token end via MeasureTokenLength once LangOptions
        // is stashed in BeginSourceFile.
        if cr.isTokenRange() {
            end += 1;
        }

        if end <= start {
            end = start + 1;
        }

        return self.ksm->get_range(self.kfid, start, end - start);
    }

    priv fn _map_severity(self, lvl: clang::DiagnosticsEngine::Level) -> DiagSeverity {
        // Stage 1: backend-detected user error. Fatal maps to Error here;
        // Stage 2 flips E->F ("compiler bug") via CompilerInvocation policy,
        // in ONE place: here.
        if lvl == clang::DiagnosticsEngine::Fatal   { return DiagSeverity::Error;   }
        if lvl == clang::DiagnosticsEngine::Error   { return DiagSeverity::Error;   }
        if lvl == clang::DiagnosticsEngine::Warning { return DiagSeverity::Warning; }
        if lvl == clang::DiagnosticsEngine::Remark  { return DiagSeverity::Remark;  }
        if lvl == clang::DiagnosticsEngine::Note    { return DiagSeverity::Note;    }
        return DiagSeverity::Ignored;
    }

    /// Grouped diags (have a -W option) map into the stable C-code space
    /// (Clang.diag.toml, keyed via clang_diag_number). Ungrouped diags
    /// (hard errors, unattached notes) fall back to the CL001 placeholder
    /// family, which carries every severity letter.
    priv fn _map_code(self, lvl: clang::DiagnosticsEngine::Level, info: cref::<clang::Diagnostic>) -> DiagCode {
        var sev = self._map_severity(lvl);
        var de  = info.getDiags();

        if de != &null {
            var wopt = de->getDiagnosticIDs()->getWarningOptionForDiag(info.getID());
            if !wopt.empty() {
                var num = clang_diag_number(std::nstring_to_string(wopt.str()));
                if num != 0 {
                    return DiagCode(Diag::C(num, sev));
                }
            }
        }

        return DiagCode(Diag::CL(1, sev));
    }

    priv fn _apply_ranges_and_fixits(self, b: *DiagBuilder, info: cref::<clang::Diagnostic>) {
        if !info.hasSourceManager() {
            return;
        }

        var nr = info.getNumRanges();
        for var i: u32 = 0; i < nr; ++i {
            var r = self._range_in_kfid(info.getRange(i), info);
            if r.is_valid() {
                b->second(r);
            }
        }

        var nf = info.getNumFixItHints();
        for var i: u32 = 0; i < nf; ++i {
            var h = info.getFixItHint(i);

            // insert-from-range hints reference OTHER source; not expressible
            // in the Kairo fix-it model. Skip.
            if h.InsertFromRange.isValid() {
                continue;
            }

            var rr   = self._range_in_kfid(h.RemoveRange, info);
            var text = std::nstring_to_string(h.CodeToInsert);
            if rr.is_valid() {
                var msg = "apply the change suggested by the backend";
                // Map clang's (RemoveRange, CodeToInsert) onto the three Kairo
                // fix-it shapes: empty remove-range => pure insertion (Add);
                // empty insertion text => pure deletion (Remove); both => Replace.
                if rr.is_empty() {
                    b->insert(rr.start, text, msg);
                } else if text.length() == 0 {
                    b->remove(rr, msg);
                } else {
                    b->fix(rr, text, msg);
                }
            }
        }
    }

    priv fn _attach_child_note(self, kloc: SourceRange, msg: string) {
        if self._open == &null {
            return;
        }

        if kloc.is_valid() {
            self._open->note(kloc.start, msg);
            self._open->child_first(kloc);
        } else {
            self._open->note(msg);
        }
    }

    priv fn _flush_open(self) {
        if self._open != &null {
            self._open->emit();
            std::destroy(self._open);
            self._open = &null;
        }
    }
}
