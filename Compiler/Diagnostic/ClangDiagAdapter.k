/// --- The Kairo Project ------------- Diagnostic/ClangDiagAdapter.k ------ ///
///
///   Adapter: clang::DiagnosticConsumer -> DiagEngine/BufferedDiagSink.
///   Translates backend diagnostics into Kairo Diagnostic objects so
///   PrettyDiagConsumer / BasicDiagConsumer render them identically to
///   frontend diagnostics. Renderers stay clang-unaware.
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "clang/Basic/Diagnostic.h";
ffi "c++" import "clang/Basic/DiagnosticIDs.h";
ffi "c++" import "clang/Basic/SourceManager.h";
ffi "c++" import "llvm/ADT/SmallString.h";

import Diagnostic::Engine::*;
import Diagnostic::BufferedDiagSink::*;
import Location::SourceManager::*;

/// One instance per bridged clang CompilerInstance (i.e. per TU).
/// Thread-confined: writes only to this TU's BufferedDiagSink, preserving
/// the byte-identical serial/parallel guarantee.
class ClangDiagAdapter derives clang::DiagnosticConsumer {
    pub var sink:      obs::<BufferedDiagSink>;
    pub var ksm:       obs::<SourceManager>;   ///< Kairo SM, for span construction
    pub var kfid:      u32;                    ///< Kairo fid of the TU being compiled
    pub var clang_kfid: clang::FileID;         ///< clang FileID of the injected .kro buffer

    /// Note-attachment state: clang emits notes as separate HandleDiagnostic
    /// calls (lvl == Note) immediately after their primary. We hold the
    /// builder open until the next primary or flush.
    priv var _open:        opt::<DiagBuilder>;
    priv var _last_fwded:  bool = false;

    // ------------------------------------------------------------------
    //  clang::DiagnosticConsumer overrides
    // ------------------------------------------------------------------

    fn BeginSourceFile(self, lo: &const clang::LangOptions, pp: unsafe *clang::Preprocessor) override {
        // nothing stashed; all queries go through Info at handle time
    }

    fn EndSourceFile(self) override {
        self._flush_open();
    }

    fn HandleDiagnostic(self,
                        lvl:  clang::DiagnosticsEngine::Level,
                        info: &const clang::Diagnostic) override {
        // MANDATORY first: base impl maintains NumErrors/NumWarnings, which
        // CompilerInstance::ExecuteAction reads for pass/fail.
        inline "c++" {
            ::clang::DiagnosticConsumer::HandleDiagnostic(lvl, info);
        }

        var msg     = self._format(info);
        var tail    = self._identity_tail(info);
        var kloc    = self._to_kairo_loc(info);      // opt<SourceRange>
        var is_note = self._is_note(lvl);

        if is_note && self._last_fwded && self._open.has_value() {
            // child of the open primary — mirrors DiagBuilder.note() shape
            self._attach_child_note(kloc, msg);
            return;
        }

        self._flush_open();

        var code = self._map_code(lvl);              // B00xE / B00xW / B00xN
        if kloc.has_value() {
            var b = self.sink->report(code, kloc.value().start, f"{msg}{tail}");
            b.first(kloc.value());
            self._apply_ranges_and_fixits(&b, info);
            self._open = b;                          // stay open for trailing notes
        } else {
            // loc-less (cc1 args, target setup): plain no-loc diagnostic
            self.sink->report(code, f"{msg}{tail}").emit();
            self._open = opt::<DiagBuilder>();       // nothing to attach notes to
        }
        self._last_fwded = true;
    }

    fn finish(self) override { self._flush_open(); }

    // IncludeInDiagnosticCounts: leave defaulted (true).

    // ------------------------------------------------------------------
    //  Translation helpers
    // ------------------------------------------------------------------

    priv fn _format(self, info: &const clang::Diagnostic) -> string {
        inline "c++" {
            ::llvm::SmallString<256> s;
            info.FormatDiagnostic(s);
            return /* SmallString -> kairo string */;
        }
    }

    /// " [-Wunused-variable]" / " [Semantic Issue]" tail. Clang identity
    /// travels in the MESSAGE, never in the code space — clang diag IDs are
    /// tablegen ordinals and renumber across releases.
    priv fn _identity_tail(self, info: &const clang::Diagnostic) -> string {
        inline "c++" {
            ::llvm::StringRef wopt;
            if (auto *de = info.getDiags())
                wopt = de->getDiagnosticIDs()->getWarningOptionForDiag(info.getID());
                // NOTE clang>=20: instance method. Static call won't compile on 22.x.
            if (!wopt.empty())
                return /* " [-W" + wopt + "]" as kairo string */;
            unsigned cat = ::clang::DiagnosticIDs::getCategoryNumberForDiag(info.getID());
            auto cname   = ::clang::DiagnosticIDs::getCategoryNameFromID(cat);
            return /* cname.empty() ? "" : " [" + cname + "]" */;
        }
    }

    /// clang loc -> Kairo SourceRange via EXPANSION loc (never spelling loc:
    /// arena literals spell in <kairo-literals>; expansion is the .kro span).
    /// Offsets in clang_kfid ARE byte offsets in the Kairo file, so the
    /// mapping is direct construction against ksm/kfid.
    priv fn _to_kairo_loc(self, info: &const clang::Diagnostic) -> opt::<SourceRange> {
        inline "c++" {
            if (!info.hasSourceManager() || info.getLocation().isInvalid())
                return /* none */;
            auto &sm = info.getSourceManager();
            auto dec = sm.getDecomposedExpansionLoc(info.getLocation());
            if (dec.first != this->clang_kfid)
                return /* none: blamed in a header/runtime include ->
                          loc-less forward; policy layer classifies */;
            // dec.second == byte offset into the .kro
            return /* SourceRange at (this->kfid, dec.second) via ksm */;
        }
    }

    priv fn _map_code(self, lvl: clang::DiagnosticsEngine::Level) -> DiagID {
        // Fatal/Error -> B001E   (Stage 1: backend-detected user error)
        // Warning     -> B002W
        // Remark      -> B003R
        // Note (unattached, degenerate) -> B004N
        // Stage 2 flips E->F("compiler bug") via CompilerInvocation policy,
        // in ONE place: here.
    }

    priv fn _apply_ranges_and_fixits(self, b: *DiagBuilder, info: &const clang::Diagnostic) {
        // info.getRanges()   -> extra labels (same expansion-loc translation)
        // info.getFixItHints() -> b.fixit(...) — renderer already handles both
    }

    priv fn _flush_open(self) {
        if self._open.has_value() { self._open.value().emit(); self._open = opt::<DiagBuilder>(); }
    }
}