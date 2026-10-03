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
ffi "c++" import "clang/Lex/Lexer.h";

import Location::SourceLocation::*;
import Location::SourceRange::*;
import Location::SourceManager::*;
import Diagnostic::Registry::*;
import Diagnostic::Engine::*;
import Diagnostic::BufferedDiagSink::*;
import Diagnostic::ClangDiagLookup::*;
import Interop::Clang::ClangLocMap::*;

/// One instance per bridged clang CompilerInstance (i.e. per TU).
/// Thread-confined: writes only to this TU's BufferedDiagSink, preserving
/// the byte-identical serial/parallel guarantee.
class ClangDiagAdapter derives clang::DiagnosticConsumer {
    pub var sink:       obs::<BufferedDiagSink>;
    pub var ksm:        obs::<SourceManager>;              ///< Kairo SM, for span construction
    pub var kfid:       FileID;                            ///< Kairo fid of the TU being compiled

    /// The live fid map. Asked per diagnostic, never snapshotted.
    ///
    /// This used to be a cached `clang_kfid: clang::FileID`, which was dead
    /// the moment FrontendAction::BeginSourceFile called clearIDTables   and
    /// worse, clang restarts its ID counter after that, so the stale value
    /// would start matching whatever header happened to land on the same ID.
    /// Every diagnostic in that header then rendered against this TU's Kairo
    /// file at a bogus offset. Ask the map; it knows when it was last rebound.
    pub var locmap:     obs::<ClangLocMap>;

    /// A header set's own clang instance maps its files through ITS table,
    /// not the backend's locmap: clang FileID hash -> Kairo fid, 0 for none
    /// (HeaderSet::cfid_to_kfid). Set instead of `locmap` for that instance;
    /// a raw table rather than the set so this layer never imports Interop's
    /// HeaderSet (which imports the backend, which imports this).
    pub var fidmap: const_obs::<libcxx::unordered_map::<u32, u32>> = &null;
    priv var _lo: const_obs::<clang::LangOptions> = &null; ///< owned by the CI, valid for the action.

    /// Note-attachment state: clang emits notes as separate HandleDiagnostic
    /// calls (lvl == Note) immediately after their primary. We hold the
    /// builder open (heap-allocated, owned) until the next primary or flush.
    priv var _open:        opt::<DiagBuilder> = &null; ///< owned; freed in _flush_open
    priv var _last_fwded:  bool = false;

    // ------------------------------------------------------------------
    //  clang::DiagnosticConsumer overrides
    // ------------------------------------------------------------------

    override fn BeginSourceFile(self, lo: cref::<clang::LangOptions>, pp: const_obs::<clang::Preprocessor>) {
        self._lo = &lo;
    }

    override fn EndSourceFile(self) {
        self._flush_open();
        self._lo = &null;
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

        // A loc in no file Kairo loaded still names one clang knows. Keep it
        // in the text, as the TextDiagnosticPrinter this replaces did, so a
        // header-set diagnostic before its fids exist (build time) is not
        // left pointing nowhere.
        if (!kloc.is_valid()) && info.hasSourceManager() && info.getLocation().isValid() {
            var pl = info.getSourceManager().getPresumedLoc(info.getLocation());
            if pl.isValid() {
                var file = std::nstring_to_string(llvm::StringRef(pl.getFilename()).str());
                msg = f"{file}:{pl.getLine()}:{pl.getColumn()}: {msg}";
            }
        }

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

    /// The Kairo fid behind a clang FileID, or u32(-1) for none: through the
    /// header set's table when one is set, else the backend's locmap.
    priv fn _kfid_of(self, cfid: clang::FileID) -> FileID {
        if self.fidmap != &null {
            var it = self.fidmap->find(cfid.getHashValue());
            if it == self.fidmap->end() { return static_cast::<FileID>(u32(-1)); }
            if it->second == 0 { return static_cast::<FileID>(u32(-1)); }
            return static_cast::<FileID>(it->second);
        }
        if self.locmap == &null { return static_cast::<FileID>(u32(-1)); }
        return self.locmap->kairo_fid(cfid);
    }

    priv fn _format(self, info: cref::<clang::Diagnostic>) -> string {
        var s: llvm::SmallString::<256>;
        info.FormatDiagnostic(s);
        return std::nstring_to_string(s.str().str());
    }

    /// clang loc -> Kairo SourceRange via EXPANSION loc (never spelling loc:
    /// arena literals spell in <kairo-literals>; expansion is the .kro span).
    /// The FileID names the Kairo fid (ClangLocMap::kairo_fid): this TU's,
    /// another Kairo file's in the block, or an imported C++ header's by
    /// path. Offsets in any of them ARE byte offsets in that Kairo file (same
    /// bytes), so the mapping is direct construction against THAT fid.
    ///
    /// Returns SourceRange::invalid() for "none": a loc in no file Kairo
    /// loaded (runtime include, scratch buffer) -> loc-less forward; policy
    /// layer classifies.
    priv fn _to_kairo_loc(self, info: cref::<clang::Diagnostic>) -> SourceRange {
        if (!info.hasSourceManager()) || (info.getLocation().isInvalid()) {
            return SourceRange::invalid();
        }

        var dec = info.getSourceManager()
                      .getDecomposedExpansionLoc(info.getLocation());

        var kf = self._kfid_of(dec.first);
        if kf == static_cast::<FileID>(u32(-1)) { return SourceRange::invalid(); }

        // dec.second == byte offset in kf. Single-byte primary span;
        // ranges/fixits widen it in _apply_ranges_and_fixits.
        return self.ksm->get_range(kf, static_cast::<usize>(dec.second), 1);
    }

    /// Translates one clang CharSourceRange into a Kairo SourceRange in the
    /// fid its BEGIN is in, or invalid if the end is in a different file (or
    /// in none): a span cannot cross files.
    priv fn _range_in_kfid(self, cr: cref::<clang::CharSourceRange>, info: cref::<clang::Diagnostic>) -> SourceRange {
        if (!cr.isValid()) || (!info.hasSourceManager()) {
            return SourceRange::invalid();
        }

        var b = info.getSourceManager().getDecomposedExpansionLoc(cr.getBegin());
        var e = info.getSourceManager().getDecomposedExpansionLoc(cr.getEnd());

        var kb = self._kfid_of(b.first);
        if kb == static_cast::<FileID>(u32(-1)) { return SourceRange::invalid(); }
        if self._kfid_of(e.first) != kb { return SourceRange::invalid(); }

        var start: usize = static_cast::<usize>(b.second);
        var end:   usize = static_cast::<usize>(e.second);

        // Token ranges end at the START of the last token. Without dragging
        // clang::Lexer::MeasureTokenLength (needs stashed LangOptions) into
        // the adapter, cover at least the first byte of that token.
        // TODO(diag): exact token end via MeasureTokenLength once LangOptions
        // is stashed in BeginSourceFile.
        if cr.isTokenRange() {
            var tlen: u32 = 1;
            if self._lo != &null {
                tlen = clang::Lexer::MeasureTokenLength(
                    cr.getEnd(), info.getSourceManager(), *self._lo);
                if tlen == 0 { tlen = 1; }
            }
            end += static_cast::<usize>(tlen);
        }

        if end <= start {
            end = start + 1;
        }

        return self.ksm->get_range(kb, start, end - start);
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
                b->highlight(r);
            }
        }

        // A clang fix-it is an edit to the EMITTED C++, and most emitted
        // tokens have no Kairo token of their own: `const`, `&`, a cast, a
        // qualifier all carry the location of whatever Kairo token they were
        // generated from. Applied to the Kairo source such an edit is
        // nonsense -- `const &` inserted into the middle of `other`. So a
        // hint survives only where the C++ edit IS a Kairo edit: it removes
        // or replaces exactly one token that the emitted C++ spells the same
        // as the Kairo source does. Never an insertion: an insertion point
        // between emitted tokens names no Kairo position. All-or-nothing
        // over the diagnostic's hints, because clang's multi-hint fixes are
        // one edit and half of one is worse than none. The message stays.
        var nf = info.getNumFixItHints();
        if nf == 0 { return; }
        for var i: u32 = 0; i < nf; ++i {
            if !self._kairo_fixit(info.getFixItHint(i), info) { return; }
        }

        for var i: u32 = 0; i < nf; ++i {
            var h    = info.getFixItHint(i);
            var rr   = self._range_in_kfid(h.RemoveRange, info);
            var text = std::nstring_to_string(h.CodeToInsert);
            var msg  = "apply the change suggested by the backend";
            if text.length() == 0 {
                b->remove(rr, msg);
            } else {
                b->fix(rr, text, msg);
            }
        }
    }

    /// \p h is a removal or a replacement of ONE token whose spelling in the
    /// emitted C++ equals the Kairo text at the position it maps to. The C++
    /// spelling is read at the SPELLING location: a token the emitter
    /// synthesized is spelled in a scratch buffer and only EXPANDS into the
    /// Kairo file, so its text there differs from the Kairo token it borrowed
    /// a location from, and that difference is exactly what rejects it.
    priv fn _kairo_fixit(self, h: cref::<clang::FixItHint>, info: cref::<clang::Diagnostic>) -> bool {
        if h.InsertFromRange.isValid() { return false; }
        if self._lo == &null { return false; }     // no LangOptions: no token measure, no proof.
        var cr = h.RemoveRange;
        if (!cr.isValid()) || (!cr.isTokenRange()) { return false; }
        if cr.getBegin() != cr.getEnd() { return false; }   // a token range of exactly one token.

        var rr = self._range_in_kfid(cr, info);
        if (!rr.is_valid()) || rr.is_empty() { return false; }

        var sm  = &(info.getSourceManager());
        var sp  = sm->getSpellingLoc(cr.getBegin());
        var len = clang::Lexer::MeasureTokenLength(sp, *sm, *self._lo);
        if len == 0 { return false; }
        var bad  = false;
        var data = sm->getCharacterData(sp, &bad);
        if bad || (data == &null) { return false; }

        var cxx = string(data, static_cast::<usize>(len));
        return cxx == self.ksm->get_text(rr);
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
