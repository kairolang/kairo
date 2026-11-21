/// --- The Kairo Project ---------------- Diagnostic/ClangDiagAdapter.k --- ///
///
///   Adapter: clang::DiagnosticConsumer -> DiagEngine/BufferedDiagSink.
///   Translates backend diagnostics into Kairo Diagnostic objects so
///   PrettyDiagConsumer / BasicDiagConsumer render them identically to
///   frontend diagnostics. Renderers stay clang-unaware.
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "llvm/ADT/DenseMap.h"
ffi "c++" import "Native/Types.hh"
ffi "c++" import "clang/Basic/Diagnostic.h"
ffi "c++" import "clang/Basic/DiagnosticIDs.h"
ffi "c++" import "clang/Basic/DiagnosticSema.h" // err_access*
ffi "c++" import "clang/Basic/SourceManager.h"
ffi "c++" import "llvm/ADT/SmallString.h"
ffi "c++" import "clang/Lex/Lexer.h"
ffi "c++" import "vector"

import Diagnostic::BufferedDiagSink::BufferedDiagSink
import Diagnostic::ClangDiagLookup::clang_diag_number
import Diagnostic::Code::DiagCode
import Diagnostic::DiagBuilder::DiagBuilder
import Diagnostic::Registry::{
    Diag,
    DiagID,
}
import Diagnostic::Severity::DiagSeverity
import Interop::Clang::ClangLocMap::ClangLocMap
import Location::SourceManager::{
    FileID,
    SourceManager,
}
import Location::SourceRange::SourceRange
import Native::ClangDiag::{
    clang_ctor_source,
    clang_diag_mutable_copy,
    clang_diag_names_namespace,
}
import Support::Ascii::{
    find,
    has_at,
    is_ident_char,
}
import Support::FileIO::Path::Path

/// A clang fix-it edit of the Kairo source: `at` replaced by `text`
/// ("" removes it).
pub struct ClangFixEdit {
    pub var at:   SourceRange = SourceRange::invalid()
    pub var text: string      = ""
}

/// A note clang reported after the group's primary.
pub struct ClangNote {
    pub var at:    SourceRange = SourceRange::invalid()
    pub var msg:   string      = ""
    pub var frame: bool        = false ///< an instantiation-context note (ClangDiagAdapter::_is_frame)
}

/// One clang primary and its notes, collected by ClangDiagAdapter until the
/// group is whole (see ClangDiagAdapter::_g).
pub class ClangDiagGroup {
    pub var on:    bool           = false
    pub var code:  DiagCode       = DiagCode(Diag::CL(1, DiagSeverity::Error))
    pub var at:    SourceRange    = SourceRange::invalid()
    pub var msg:   string         = ""
    pub var hl:    [SourceRange] ///< highlighted ranges
    pub var fixes: [ClangFixEdit]
    pub var notes: [ClangNote]
    /// A record of the group that copies only from a non-const lvalue
    /// (clang_diag_mutable_copy): its name, the record whose copy
    /// constructor forces that and the field leading to it ("" for its
    /// own), that constructor's source parameter, and where both are.
    pub var why_rec:      string      = ""
    pub var why_ctor_rec: string      = ""
    pub var why_field:    string      = ""
    pub var why_param:    string      = ""
    pub var why_ctor_at:  SourceRange = SourceRange::invalid()
    pub var why_param_at: SourceRange = SourceRange::invalid()
    /// Some text of the group is about building or copying a value, so the
    /// record above is the cause, not a bystander named in a frame.
    pub var about_copy: bool = false

    fn ClangDiagGroup(self) { }

    fn reset(self) {
        self.on  = false
        self.at  = SourceRange::invalid()
        self.msg = ""
        self.hl.clear()
        self.fixes.clear()
        self.notes.clear()
        self.why_rec      = ""
        self.why_ctor_rec = ""
        self.why_field    = ""
        self.why_param    = ""
        self.why_ctor_at  = SourceRange::invalid()
        self.why_param_at = SourceRange::invalid()
        self.about_copy   = false
    }

    /// The group names a Kairo record that copies only from a non-const
    /// lvalue, and is about copying one.
    fn explained(self) -> bool {
        return self.about_copy && !self.why_rec.is_empty() && self.why_ctor_at.is_valid()
    }
}

/// One instance per bridged clang CompilerInstance (i.e. per TU).
/// Thread-confined: writes only to this TU's BufferedDiagSink, preserving
/// the byte-identical serial/parallel guarantee.
pub class ClangDiagAdapter derives clang::DiagnosticConsumer {
    pub var sink: unsafe *BufferedDiagSink
    pub var ksm:  unsafe *SourceManager    ///< Kairo SM, for span construction
    pub var kfid: FileID                   ///< Kairo fid of the TU being compiled

    /// The live fid map. Asked per diagnostic, never snapshotted.
    ///
    /// Not cached as a clang::FileID: FrontendAction::BeginSourceFile calls
    /// clearIDTables and clang restarts its ID counter after that, so a
    /// stored id would match whatever header happens to land on the same ID,
    /// and every diagnostic in that header would render against this TU's
    /// Kairo file at a bogus offset. The map knows when it was last rebound.
    pub var locmap: unsafe *ClangLocMap

    /// A header set's own clang instance maps its files through ITS table,
    /// not the backend's locmap: clang FileID hash -> Kairo fid, 0 for none
    /// (HeaderSet::cfid_to_kfid). Set instead of `locmap` for that instance;
    /// a raw table rather than the set so this layer never imports Interop's
    /// HeaderSet (which imports the backend, which imports this).
    pub var fidmap: unsafe *const llvm::DenseMap<u64, u32> = &null ///< HeaderSet::cfid_to_kfid (u64 key: see there).
    /// A header set's synthesized main buffer: line - 1 -> the .k import
    /// span that line includes (HeaderSet::_main_locs). Null otherwise.
    pub var  main_locs: unsafe *const cxx::std::vector<SourceRange> = &null
    priv var _lo:       unsafe *const clang::LangOptions            = &null ///< owned by the CI, valid for the action.

    /// Note-attachment state: clang emits notes as separate HandleDiagnostic
    /// calls (lvl == Note) immediately after their primary, which stays
    /// open in _g until the next primary or flush.
    priv var _last_fwded: bool = false
    /// The open primary is clang's "redefinition of 'X'" in a C++ file:
    /// the file it is in, and X (see _explain_redefinition). Empty otherwise.
    priv var _redef_file: string = ""
    priv var _redef_name: string = ""

    /// The codegen compile of a Kairo TU (CodegenJob): an error inside C++
    /// that a template instantiation from Kairo code reached is reported at
    /// that Kairo code (_flush_group). Off for a header set's own parse and
    /// fills and for a C/C++ input, whose chains end in C++ or at an import.
    pub var reanchor: bool = false
    /// Show the re-anchored error's C++ instantiation chain (--diag-cxx-chain).
    pub var cxx_chain: bool = false
    /// Directories whose `.k` files are the library's (builtin, std): a frame
    /// there is never the anchor, the user's call into it is.
    pub var lib_roots: cxx::std::vector<string>

    /// The group being collected: clang's primary and the notes after it,
    /// built into one Diagnostic when the next primary arrives or at
    /// flush. The anchor of a re-anchored error is in a note (the outermost
    /// instantiation frame), so nothing is built before the group is whole;
    /// what needs the clang::Diagnostic (ranges, fix-its, the record a
    /// copy fails for) is read in HandleDiagnostic, the only place it lives.
    priv var _g: ClangDiagGroup
    /// A re-anchored error not yet emitted: the next group re-anchored at
    /// the same Kairo place is folded into it, so one call gets one error.
    priv var _held:    unsafe *DiagBuilder = &null ///< owned; emitted by _emit_held
    priv var _held_at: SourceRange         = SourceRange::invalid()

    /// # clang::DiagnosticConsumer overrides

    pub override fn BeginSourceFile(self,
                                    const lo: clang::LangOptions,
                                    pp:       unsafe *const clang::Preprocessor) {
        self._lo = unsafe &lo
    }

    pub override fn EndSourceFile(self) {
        self._flush_all()
        self._lo = &null
    }

    override fn HandleDiagnostic(self,
                                 lvl:        clang::DiagnosticsEngine::Level,
                                 const info: clang::Diagnostic) {
        // MANDATORY first: base impl maintains NumErrors/NumWarnings, which
        // CompilerInstance::ExecuteAction reads for pass/fail.
        clang::DiagnosticConsumer::HandleDiagnostic(self, lvl, info)

        var msg     = self._format(info)
        var kloc    = self._to_kairo_loc(info)              // invalid == "none"
        var is_note = lvl == clang::DiagnosticsEngine::Note

        // A loc in no file Kairo loaded still names one clang knows. Keep it
        // in the text, as the TextDiagnosticPrinter this replaces did, so a
        // header-set diagnostic before its fids exist (build time) is not
        // left pointing nowhere.
        if !kloc.is_valid() && info.hasSourceManager() && info.getLocation().isValid() {
            var pl = info.getSourceManager().getPresumedLoc(info.getLocation())
            if pl.isValid() {
                var file = string(
                    unsafe ((llvm::StringRef(pl.getFilename()).str().c_str() as unsafe *const u8) as *const u8),
                )

                msg = f"{file}:{pl.getLine()}:{pl.getColumn()}: {msg}"
            }
        }

        // "'hn_test' declared here" about a module namespace: codegen wrote it,
        // so the note points at an arbitrary token of the user's `.k` file and
        // names nothing they declared. A namespace from a header keeps
        // its note.
        if is_note
            && kloc.is_valid()
            && self._in_kairo_source(kloc)
            && (clang_diag_names_namespace(info) || self._declared_elsewhere(kloc, msg)) {
            return
        }

        if is_note && self._last_fwded && self._g.on {
            self._add_note(kloc, msg, ClangDiagAdapter::_is_frame(msg))
            self._note_cause(info, msg)
            self._explain_redefinition(kloc, info)
            return
        }

        self._flush_open()
        self._redef_file = ""
        self._redef_name = ""
        if lvl == clang::DiagnosticsEngine::Error
            && kloc.is_valid()
            && (!self._in_kairo_source(kloc))
            && msg.starts_with("redefinition of \x27") {
            // "redefinition of 'Base'" (or "... as different kind of
            // symbol"): the quoted name, quotes kept.
            var q2: usize = 17
            while q2 < msg.size() && msg.data()[q2] != ('\x27' as u8) {
                q2 += 1
            }

            if q2 < msg.size() {
                self._redef_file = self.ksm->get_filename(kloc)
                self._redef_name = msg.subslice(16, q2 - 15)
            }
        }

        var code = self._map_code(lvl, info) // C0xxx{E,W,R} / CL001x

        // An access error in Kairo's own emitted C++ is never the user's:
        // AccessCheck admitted the access, and the record's C++ access
        // levels and friend list (InterfaceEmitter::_cxx_vis, _friends) are
        // meant to admit exactly that. Said as the compiler bug it is, not
        // as a clang error the user should fix. A C++ host's own access
        // errors (kcc) are in its own file and stay clang's.
        if lvl == clang::DiagnosticsEngine::Error
            && kloc.is_valid()
            && self._in_kairo_source(kloc)
            && self._is_access_error(info) {
            code = DiagCode(DiagID::I003E)
            msg = "the emitted C++ refuses an access Kairo accepted (AccessCheck and the record's C++ access levels or friends disagree; a compiler bug): " + msg
        }

        if kloc.is_valid() {
            self._g.reset()
            self._g.on   = true
            self._g.code = code
            self._g.at   = kloc
            self._g.msg  = msg.copy()
            self._collect_ranges_and_fixits(info)
            self._note_cause(info, msg)
            // stays open for trailing notes; built in _flush_open
        } else {
            // loc-less (cc1 args, target setup, header-blamed): plain no-loc
            self._emit_held()
            self.sink->report(code, msg.copy()).emit()
        }

        self._last_fwded = true
    }

    pub override fn finish(self) {
        self._flush_all()
    }

    // IncludeInDiagnosticCounts: leave defaulted (true).

    fn ClangDiagAdapter(self) = default

    // Not transferable: clang holds it as its consumer and it owns the held DiagBuilder; a copy would flush it twice.
    @copy fn ClangDiagAdapter(self, const other: Self) = delete

    fn op finally (self) {
        self._flush_all()
    }

    /// # internals

    /// The Kairo fid behind a clang FileID, or u32(-1) for none: through the
    /// header set's table when one is set, else the backend's locmap.
    priv fn _kfid_of(self, cfid: clang::FileID, const csm: clang::SourceManager) -> FileID {
        if self.fidmap != &null {
            var it = self.fidmap->find(cfid.getHashValue() as u64)
            if it != self.fidmap->end() && it->second != 0 {
                return it->second
            }

            // The table fills at index(), after the build. A build-time
            // diagnostic (a bad header) would otherwise render as bare
            // text with no snippet: load the header by path instead. Same
            // bytes, so clang's offset is the Kairo offset. load_file is
            // _load_mu-guarded, so the pool thread may call it.
            return self._load_by_path(cfid, csm)
        }

        // Neither: a C/C++ input compiled by clang's own driver (ClangJobs).
        // Kairo never loaded its files, so load them as they are named.
        if self.locmap == &null {
            return self._load_by_path(cfid, csm)
        }

        return self.locmap->kairo_fid(cfid)
    }

    priv fn _load_by_path(self, cfid: clang::FileID, const csm: clang::SourceManager) -> FileID {
        var none = (u32::MAX as FileID)
        if self.ksm == &null {
            return none
        }

        var fe = csm.getFileEntryRefForID(cfid)
        if !fe.has_value() {
            return none
        }

        var name = fe->getName()
        var p = Path(
            string(
                unsafe ((name.data() as unsafe *const u8) as *const u8),
                name.size(),
            ),
        )

        // Checked here: load_file reports a missing path as I005F itself.
        if !p.exists() || !p.is_regular_file() {
            return none
        }

        var kf = self.ksm->load_file(p)
        // load_file builds the line index on the pool; a diagnostic rendered
        // before it is done reads line 0, column 0.
        if kf != none {
            self.ksm->wait_for_line_index(kf)
        }

        return kf
    }

    priv fn _format(self, const info: clang::Diagnostic) -> string {
        var s: llvm::SmallString<256>
        info.FormatDiagnostic(&s)
        return string(
            unsafe ((s.str().str().c_str() as unsafe *const u8) as *const u8),
        )
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
    priv fn _to_kairo_loc(self, const info: clang::Diagnostic) -> SourceRange {
        if !info.hasSourceManager() || info.getLocation().isInvalid() {
            return SourceRange::invalid()
        }

        var dec = info.getSourceManager().getDecomposedExpansionLoc(
            info.getLocation(),
        )

        var *csm = &info.getSourceManager()
        // The set's own `#include` lines: the .k import that wrote them.
        if self.main_locs != &null && dec.first == csm->getMainFileID() {
            var line = (csm->getLineNumber(dec.first, dec.second) as usize)
            if line > 0 && line <= self.main_locs->size() {
                return (*self.main_locs)[line - 1]
            }

            return SourceRange::invalid()
        }

        var kf = self._kfid_of(dec.first, *csm)
        if kf == (u32::MAX as FileID) {
            return SourceRange::invalid()
        }

        // dec.second == byte offset in kf. Single-byte primary span;
        // ranges/fixits widen it in _apply_ranges_and_fixits.
        return self.ksm->get_range(kf, dec.second as usize, 1)
    }

    /// Translates one clang CharSourceRange into a Kairo SourceRange in the
    /// fid its BEGIN is in, or invalid if the end is in a different file (or
    /// in none): a span cannot cross files.
    priv fn _range_in_kfid(self,
                           const cr:   clang::CharSourceRange,
                           const info: clang::Diagnostic) -> SourceRange {
        if !cr.isValid() || !info.hasSourceManager() {
            return SourceRange::invalid()
        }

        var b = info.getSourceManager().getDecomposedExpansionLoc(cr.getBegin())
        var e = info.getSourceManager().getDecomposedExpansionLoc(cr.getEnd())

        // A range in a set's injected main has no Kairo bytes behind it.
        if self.main_locs != &null && b.first == info.getSourceManager().getMainFileID() {
            return SourceRange::invalid()
        }

        var kb = self._kfid_of(b.first, info.getSourceManager())
        if kb == (u32::MAX as FileID) {
            return SourceRange::invalid()
        }

        if self._kfid_of(e.first, info.getSourceManager()) != kb {
            return SourceRange::invalid()
        }

        var start: usize = (b.second as usize)
        var end:   usize = (e.second as usize)

        // Token ranges end at the START of the last token. Without dragging
        // clang::Lexer::MeasureTokenLength (needs stashed LangOptions) into
        // the adapter, cover at least the first byte of that token.
        // TODO(diag): exact token end via MeasureTokenLength once LangOptions
        // is stashed in BeginSourceFile.
        if cr.isTokenRange() {
            var tlen: u32 = 1
            if self._lo != &null {
                tlen = clang::Lexer::MeasureTokenLength(
                    cr.getEnd(),
                    info.getSourceManager(),
                    *self._lo,
                )

                if tlen == 0 {
                    tlen = 1
                }
            }

            end += (tlen as usize)
        }

        if end <= start {
            end = start + 1
        }

        return self.ksm->get_range(kb, start, end - start)
    }

    /// `msg` is a "'X' declared here" note whose location in a `.k` file
    /// does not spell X: the declaration is one codegen wrote (a module
    /// namespace, under typo correction, passes its name as text, so
    /// clang_diag_names_namespace cannot see it), and the note would point
    /// the user at an unrelated token.
    priv fn _declared_elsewhere(self, kloc: SourceRange, const msg: string) -> bool {
        if !msg.ends_with("declared here") {
            return false
        }

        var q1: usize = msg.size()
        var q2: usize = msg.size()
        for var i: usize = 0; i < msg.size(); ++i {
            if msg.data()[i] != ('\'' as u8) {
                continue
            }

            if q1 == msg.size() {
                q1 = i
            } else {
                q2 = i
                break
            }
        }

        if q2 == msg.size() || q2 <= q1 + 1 {
            return false
        }

        var name = msg.subslice(q1 + 1, q2 - q1 - 1)
        // A qualified name is spelled by its last component at the declaration.
        for var i: usize = name.size(); i > 1; --i {
            if name.data()[i - 1] == (':' as u8) && name.data()[i - 2] == (':' as u8) {
                name = name.subslice(i, name.size() - i)
                break
            }
        }

        if name.size() == 0 {
            return false
        }

        var line = self.ksm->get_full_line(kloc.start)
        var col  = self.ksm->get_line_col(kloc.start).column
        if col == 0 || col - 1 >= line.size() {
            return false
        }

        var rest = line.subslice(col - 1, line.size() - (col - 1))
        return !rest.starts_with(name)
    }

    /// `r` is in a `.k` file: C++ Kairo emitted, not a host's own source.
    priv fn _in_kairo_source(self, r: SourceRange) -> bool {
        var nm = self.ksm->get_filename(r)
        var n  = nm.size()
        return n >= 2 && nm.data()[n - 2] == ('.' as u8) && nm.data()[n - 1] == ('k' as u8)
    }

    /// clang's access refusals of a member, a constructor or a destructor:
    /// the IDs whose text says "is a private member", "calling a private
    /// constructor" or "has private destructor" (and their protected
    /// forms). `calling a private destructor` (err_access_dtor) and the
    /// special-member forms `has private copy constructor`
    /// (err_access_base_ctor, err_access_field_ctor) are not among them.
    priv fn _is_access_error(self, const info: clang::Diagnostic) -> bool {
        var id = info.getID()
        return id == (clang::diag::err_access as u32)
            || id == (clang::diag::err_access_ctor as u32)
            || id == (clang::diag::err_access_friend_function as u32)
            || id == (clang::diag::err_access_dtor_base as u32)
            || id == (clang::diag::err_access_dtor_vbase as u32)
            || id == (clang::diag::err_access_dtor_temp as u32)
            || id == (clang::diag::err_access_dtor_exception as u32)
            || id == (clang::diag::err_access_dtor_field as u32)
            || id == (clang::diag::err_access_dtor_var as u32)
            || id == (clang::diag::err_access_dtor_ivar as u32)
    }

    priv fn _has(self, const s: string, const sub: string) -> bool {
        return find(s, sub, 0) != usize::MAX
    }

    priv fn _map_severity(self, lvl: clang::DiagnosticsEngine::Level) -> DiagSeverity {
        // Stage 1: backend-detected user error. Fatal maps to Error here;
        // Stage 2 flips E->F ("compiler bug") via CompilerInvocation policy,
        // in ONE place: here.
        if lvl == clang::DiagnosticsEngine::Fatal {
            return DiagSeverity::Error
        }

        if lvl == clang::DiagnosticsEngine::Error {
            return DiagSeverity::Error
        }

        if lvl == clang::DiagnosticsEngine::Warning {
            return DiagSeverity::Warning
        }

        if lvl == clang::DiagnosticsEngine::Remark {
            return DiagSeverity::Remark
        }

        if lvl == clang::DiagnosticsEngine::Note {
            return DiagSeverity::Note
        }

        return DiagSeverity::Ignored
    }

    /// Grouped diags (have a -W option) map into the stable C-code space
    /// (Clang.diag.toml, keyed via clang_diag_number). Ungrouped diags
    /// (hard errors, unattached notes) fall back to the CL001 placeholder
    /// family, which carries every severity letter.
    priv fn _map_code(self,
                      lvl:        clang::DiagnosticsEngine::Level,
                      const info: clang::Diagnostic) -> DiagCode {
        var        sev = self._map_severity(lvl)
        var unsafe *de = info.getDiags()

        if de != &null {
            var wopt = de->getDiagnosticIDs()->getWarningOptionForDiag(
                info.getID(),
            )

            if !wopt.empty() {
                var num = clang_diag_number(
                    string(
                        unsafe ((wopt.str().c_str() as unsafe *const u8) as *const u8),
                    ),
                )

                if num != 0 {
                    return DiagCode(Diag::C(num, sev))
                }
            }
        }

        return DiagCode(Diag::CL(1, sev))
    }

    /// The primary's highlighted ranges and its fix-its, into _g.
    priv fn _collect_ranges_and_fixits(self, const info: clang::Diagnostic) {
        if !info.hasSourceManager() {
            return
        }

        var nr = info.getNumRanges()
        for var i: u32 = 0; i < nr; ++i {
            var r = self._range_in_kfid(info.getRange(i), info)
            if r.is_valid() {
                self._g.hl.push(r)
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
        var nf = info.getNumFixItHints()
        if nf == 0 {
            return
        }

        for var i: u32 = 0; i < nf; ++i {
            if !self._kairo_fixit(info.getFixItHint(i), info) {
                return
            }
        }

        for var i: u32 = 0; i < nf; ++i {
            var h  = info.getFixItHint(i)
            var rr = self._range_in_kfid(h.RemoveRange, info)
            var text = string(
                unsafe ((h.CodeToInsert.data() as unsafe *const u8) as *const u8),
                h.CodeToInsert.size(),
            )

            // No text: the edit is a removal (_replay).
            var fx = ClangFixEdit()
            fx.at   = rr
            fx.text = text.copy()
            self._g.fixes.push(fx)
        }
    }

    /// `h` is a removal or a replacement of ONE token whose spelling in the
    /// emitted C++ equals the Kairo text at the position it maps to. The C++
    /// spelling is read at the SPELLING location: a token the emitter
    /// synthesized is spelled in a scratch buffer and only EXPANDS into the
    /// Kairo file, so its text there differs from the Kairo token it borrowed
    /// a location from, and that difference is exactly what rejects it.
    priv fn _kairo_fixit(self, const h: clang::FixItHint, const info: clang::Diagnostic) -> bool {
        if h.InsertFromRange.isValid() {
            return false
        }

        if self._lo == &null { // no LangOptions: no token measure, no proof.
            return false
        }

        var cr = h.RemoveRange
        if !cr.isValid() || !cr.isTokenRange() {
            return false
        }

        if cr.getBegin() != cr.getEnd() { // a token range of exactly one token.
            return false
        }

        var rr = self._range_in_kfid(cr, info)
        if !rr.is_valid() || rr.is_empty() {
            return false
        }

        var *sm = &info.getSourceManager()
        var sp  = sm->getSpellingLoc(cr.getBegin())
        var len = clang::Lexer::MeasureTokenLength(sp, *sm, *self._lo)
        if len == 0 {
            return false
        }

        var        bad   = false
        var unsafe *data = sm->getCharacterData(sp, unsafe &bad)
        if bad || data == &null {
            return false
        }

        var cxx_v = string(
            unsafe ((data as unsafe *const u8) as *const u8),
            len as usize,
        )

        return cxx_v == self.ksm->get_text(rr)
    }

    /// After clang's "previous definition is here" for an open
    /// "redefinition of 'X'" whose two definitions are in two different C++
    /// files: say why that is an error in Kairo at all. Every C++
    /// header a Kairo file imports is parsed into ONE translation unit
    /// (HeaderSet), so two headers that each define `struct Base` are C++'s
    /// redefinition, though neither header includes the other and C++ users
    /// would never see them together. Without this the user saw only clang's
    /// error and, under it, every name of both headers unresolved.
    priv fn _explain_redefinition(self, kloc: SourceRange, const info: clang::Diagnostic) {
        if self._redef_file.is_empty() || (!kloc.is_valid()) || self._in_kairo_source(kloc) {
            return
        }

        if info.getID() != (clang::diag::note_previous_definition as u32) {
            return
        }

        var prev = self.ksm->get_filename(kloc)
        if prev == self._redef_file {
            return
        }

        var a = Path(prev).filename()
        var b = Path(self._redef_file).filename()
        if a == b {
            a = prev.copy()
            b = self._redef_file.copy()
        }

        var name = self._redef_name.copy()
        self._redef_file = ""
        self._redef_name = ""
        self._attach_child_note(
            SourceRange::invalid(),
            f"'{a}' and '{b}' both define {name}: every C++ header a Kairo file imports is parsed into one translation unit, so two headers cannot both define a type of the same name; import them from different Kairo files, or put one of the definitions in a namespace",
        )
    }

    priv fn _attach_child_note(self, kloc: SourceRange, msg: string) {
        self._add_note(kloc, msg, false)
    }

    priv fn _add_note(self, kloc: SourceRange, const msg: string, frame: bool) {
        if !self._g.on {
            return
        }

        var n = ClangNote()
        n.at    = kloc
        n.msg   = msg.copy()
        n.frame = frame
        self._g.notes.push(n)
    }

    /// The open group is whole: build it. A held re-anchored error stays
    /// held, since the next group may fold into it (_flush_all ends that).
    priv fn _flush_open(self) {
        if !self._g.on {
            return
        }

        self._g.on = false
        var ai = self._anchor()
        if ai != usize::MAX {
            self._reanchor_group(ai)
            return
        }

        self._emit_held()
        self._replay()
    }

    priv fn _flush_all(self) {
        self._flush_open()
        self._emit_held()
    }

    priv fn _emit_held(self) {
        if self._held != &null {
            self._held->emit()
            @destroy unsafe (self._held as *DiagBuilder)
            self._held    = &null
            self._held_at = SourceRange::invalid()
        }
    }

    /// The group as clang reported it, at clang's location, every note in
    /// order. A Kairo record it fails to copy adds the Kairo reason and
    /// the `const` fix (_explain_copy).
    priv fn _replay(self) {
        var unsafe *b = unsafe (@create DiagBuilder(
            unsafe (self.sink as *BufferedDiagSink),
            self._g.code.copy(),
            self._g.at.start,
            self._g.msg.copy(),
        ) as unsafe *DiagBuilder)

        b->first(self._g.at)
        for var i: usize = 0; i < self._g.hl.size(); ++i {
            b->highlight(self._g.hl[i])
        }

        // No message on a fix-it: the edit is the whole message, and the
        // pretty form shows it inline as a diff.
        for var i: usize = 0; i < self._g.fixes.size(); ++i {
            var *fx = &self._g.fixes[i]
            var msg = ""
            if fx->text.size() == 0 {
                b->remove(fx->at, msg)
            } else {
                b->fix(fx->at, fx->text, msg)
            }
        }

        for var i: usize = 0; i < self._g.notes.size(); ++i {
            self._note_into(b, i)
        }

        if self._g.explained() {
            b->note(
                f"'{self._g.why_rec}' cannot be copied from a const object or a temporary: {self._copy_cause()}",
            )

            self._explain_copy(b)
        }

        b->emit()
        @destroy unsafe (b as *DiagBuilder)
    }

    priv fn _note_into(self, b: unsafe *DiagBuilder, i: usize) {
        var *n = &self._g.notes[i]
        if n->at.is_valid() {
            b->note(n->at.start, n->msg)->child_first(n->at)
        } else {
            b->note(n->msg)
        }
    }

    /// The note index of the frame to report the group at, or usize::MAX:
    /// the OUTERMOST instantiation frame (clang prints them innermost
    /// first) in a Kairo file of the user's, when the error itself is not
    /// in one. That frame is the Kairo code whose use of a C++ (or library)
    /// template made clang instantiate the body that does not compile; an
    /// error already in the user's Kairo code is reported where it is.
    priv fn _anchor(self) -> usize {
        if !self.reanchor || self._user_kairo(self._g.at) {
            return usize::MAX
        }

        var found = usize::MAX
        for var i: usize = 0; i < self._g.notes.size(); ++i {
            if self._g.notes[i].frame && self._user_kairo(self._g.notes[i].at) {
                found = i
            }
        }

        return found
    }

    /// `r` is in a `.k` file outside the library roots.
    priv fn _user_kairo(self, r: SourceRange) -> bool {
        if !r.is_valid() || !self._in_kairo_source(r) {
            return false
        }

        var nm = self.ksm->get_filename(r)
        for var i: usize = 0; i < self.lib_roots.size(); ++i {
            var root = self.lib_roots[i].copy()
            if root.is_empty() {
                continue
            }

            if !root.ends_with("/") {
                root += "/"
            }

            if nm.starts_with(root) {
                return false
            }
        }

        return true
    }

    /// One error at the Kairo frame `ai` for the open group: clang's
    /// message as the reason, its location as a note, the frames folded
    /// into a count (all of them under --diag-cxx-chain). A group at the
    /// place of the held error is folded into that one.
    priv fn _reanchor_group(self, ai: usize) {
        var at = self._g.notes[ai].at
        if self._held != &null && self._held_at == at {
            self._held->note(
                self._g.at.start,
                f"C++ also reports: {self._g.msg}",
            )->child_first(self._g.at)

            if self.cxx_chain {
                for var i: usize = 0; i < self._g.notes.size(); ++i {
                    self._note_into(self._held, i)
                }
            }

            return
        }

        self._emit_held()
        var what      = ClangDiagAdapter::_frame_entity(self._g.notes[ai].msg)
        var explained = self._g.explained()
        var code      = DiagCode(DiagID::CL002E)
        var text      = f"instantiating {what} here does not compile in C++: {self._g.msg}"
        if explained {
            code = DiagCode(DiagID::SC302E)
            text = f"'{self._g.why_rec}' cannot be copied here: instantiating {what} copies it from a const object or a temporary, and {self._copy_cause()}"
        }

        var unsafe *b = unsafe (@create DiagBuilder(
            unsafe (self.sink as *BufferedDiagSink),
            code,
            at.start,
            text,
        ) as unsafe *DiagBuilder)

        b->first(at)
        if explained {
            self._explain_copy(b)
        }

        var at_text = "the C++ error is here, in the template's body"
        if explained {
            at_text = f"C++ reports: {self._g.msg}"
        }

        b->note(self._g.at.start, at_text)->child_first(self._g.at)
        var frames: usize = 0
        for var i: usize = 0; i < self._g.notes.size(); ++i {
            var frame = self._g.notes[i].frame
            if frame {
                frames += 1
            }

            if self.cxx_chain || (!frame && !explained) {
                self._note_into(b, i)
            }
        }

        if frames > 1 && !self.cxx_chain {
            b->note(
                f"{frames} C++ instantiation steps lead from this use to the error; --diag-cxx-chain shows them",
            )
        }

        b->note(
            "C++ reports a template that does not compile once, at its first use: a later use of the same template fails for the same reason",
        )

        self._held    = b
        self._held_at = at
    }

    /// What the frame `msg` instantiates: "member function 'X::f'" of
    /// "in instantiation of member function 'X::f' requested here".
    static fn _frame_entity(const msg: string) -> string {
        var pre = "in instantiation of "
        var suf = " requested here"
        if msg.starts_with(pre) {
            var n = msg.size() - pre.size()
            if msg.ends_with(suf) && n > suf.size() {
                n -= suf.size()
            }

            return msg.subslice(pre.size(), n)
        }

        return "a C++ template"
    }

    /// `msg` is one of clang's instantiation-context notes: the stack of
    /// template instantiations, default arguments, substitutions and
    /// implicit members that leads from the use to the error.
    static fn _is_frame(const msg: string) -> bool {
        return msg.starts_with("in instantiation of ")
            || msg.starts_with("while substituting ")
            || msg.starts_with("while checking ")
            || msg.starts_with("in evaluation of exception specification ")
            || msg.starts_with("during template argument deduction ")
            || msg.ends_with(" first required here")
            || msg.ends_with(" requested here")
    }

    /// Why the group's record copies only from a non-const lvalue.
    priv fn _copy_cause(self) -> string {
        var c    = self._g.why_ctor_rec.copy()
        var p    = self._g.why_param.copy()
        var tail = f"takes a non-const '{p}' (C++ '{c}({c}&)')"
        if self._g.why_field.is_empty() {
            return f"its copy constructor {tail} and it has no move constructor"
        }

        return f"its field '{self._g.why_field}' is a '{c}', whose copy constructor {tail} and which has no move constructor"
    }

    /// The Kairo fix on `b`: a note at the copy constructor and, where
    /// the parameter's Kairo text is its name, `const` inserted before it.
    priv fn _explain_copy(self, b: unsafe *DiagBuilder) {
        var p = self._g.why_param.copy()
        if self._g.why_param_at.is_valid() {
            b->insert(self._g.why_param_at.start, "const ", f"make '{p}' const")
        }

        b->note(
            self._g.why_ctor_at.start,
            f"the copy constructor of '{self._g.why_ctor_rec}' is declared here; with 'const {p}' it copies from const objects and temporaries too",
        )->child_first(self._g.why_ctor_at)
    }

    /// Reads off one diagnostic of the open group whether it is about
    /// copying, and the first Kairo record among its arguments that copies
    /// only from a non-const lvalue (clang_diag_mutable_copy).
    priv fn _note_cause(self, const info: clang::Diagnostic, const msg: string) {
        if !self._g.on {
            return
        }

        if !self._g.about_copy {
            self._g.about_copy = self._has(msg, "construct")
                || self._has(msg, "initialization of")
                || self._has(msg, "overloaded '='")
                || self._has(msg, "Insertable")
                || self._has(msg, "copy")
                || self._has(msg, "move")
                || self._has(msg, "conversion")
        }

        if !self._g.why_rec.is_empty() || !info.hasSourceManager() {
            return
        }

        var c = clang_diag_mutable_copy(info)
        if c.ctor == &null || c.rec == &null {
            return
        }

        var unsafe *csm = unsafe &info.getSourceManager()
        var ctor_rec = ClangDiagAdapter::_std(
            c.ctor->getParent()->getNameAsString(),
        )

        var ctor_at = self._kairo_range_at(
            c.ctor->getLocation(),
            csm,
            ctor_rec.size(),
        )

        // Only a Kairo record has a Kairo declaration to point at and fix.
        if !ctor_at.is_valid() || !self._in_kairo_source(ctor_at) {
            return
        }

        var unsafe *src  = clang_ctor_source(c.ctor)
        var        pname = "other"
        var        p_at  = SourceRange::invalid()
        if src != &null {
            var nm = ClangDiagAdapter::_std(src->getNameAsString())
            if !nm.is_empty() {
                pname = nm.copy()
                p_at  = self._param_in_decl(ctor_at, nm)
            }
        }

        // The parameter's own name is the better place for the note: it is
        // what the fix changes.
        if p_at.is_valid() {
            ctor_at = p_at
        }

        self._g.why_rec      = ClangDiagAdapter::_std(c.rec->getNameAsString())
        self._g.why_ctor_rec = ctor_rec.copy()
        self._g.why_param    = pname.copy()
        self._g.why_ctor_at  = ctor_at
        self._g.why_param_at = p_at
        if c.field != &null {
            self._g.why_field = ClangDiagAdapter::_std(
                c.field->getNameAsString(),
            )
        }
    }

    /// `loc` (its expansion) in Kairo terms, `len` bytes long, or invalid.
    priv fn _kairo_range_at(self,
                            loc: clang::SourceLocation,
                            csm: unsafe *const clang::SourceManager,
                            len: usize) -> SourceRange {
        if loc.isInvalid() || csm == &null {
            return SourceRange::invalid()
        }

        var dec = csm->getDecomposedExpansionLoc(loc)
        if self.main_locs != &null && dec.first == csm->getMainFileID() {
            return SourceRange::invalid()
        }

        var kf = self._kfid_of(dec.first, *csm)
        if kf == (u32::MAX as FileID) {
            return SourceRange::invalid()
        }

        return self.ksm->get_range(
            kf,
            dec.second as usize,
            if (len > 0) => (len) else => 1,
        )
    }

    /// Where the Kairo declaration starting on the line of `at` names its
    /// parameter `nm` (`nm:`, as a whole word, not already `const`), or
    /// invalid. The emitted constructor's tokens carry locations near, not
    /// exactly at, the Kairo tokens they come from, so the name is found in
    /// the Kairo text, up to the body's `{` or a `;`.
    priv fn _param_in_decl(self, at: SourceRange, const nm: string) -> SourceRange {
        if !at.is_valid() || nm.is_empty() {
            return SourceRange::invalid()
        }

        var res  = self.ksm->resolve(at.start)
        var kf   = (res.fid as FileID)
        var off  = res.offset as usize
        var col  = self.ksm->get_line_col(at.start).column
        var size = self.ksm->get_file_size(kf)
        if col == 0 || col - 1 > off || off >= size {
            return SourceRange::invalid()
        }

        off -= col - 1
        var n = size - off
        if n > 512 {
            n = 512
        }

        var text = self.ksm->get_text(self.ksm->get_range(kf, off, n))
        var m    = nm.size()
        for var i: usize = 0; i + m <= text.size(); ++i {
            var ch = text.data()[i]
            if ch == ('{' as u8) || ch == (';' as u8) {
                break
            }

            if !has_at(text, i, nm) {
                continue
            }

            if i > 0 && is_ident_char(text.data()[i - 1]) {
                continue
            }

            var j = i + m
            if j < text.size() && is_ident_char(text.data()[j]) {
                continue
            }

            while j < text.size() && text.data()[j] == (' ' as u8) {
                j += 1
            }

            if j >= text.size() || text.data()[j] != (':' as u8) {
                continue
            }

            if i >= 6 && has_at(text, i - 6, "const ") {
                return SourceRange::invalid()
            }

            return self.ksm->get_range(kf, off + i, m)
        }

        return SourceRange::invalid()
    }

    static fn _std(const s: cxx::std::string) -> string {
        return string(
            unsafe ((s.c_str() as unsafe *const u8) as *const u8),
            s.size(),
        )
    }
}
