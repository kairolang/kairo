/// --- The Kairo Project -------------------------- Diagnostic/Engine.k --- ///
///
///   Diagnostic engine and poison-scope suppression (the builder is
///   DiagBuilder.k, the sink interface DiagSink.k).
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///
///
///   BasicDiagConsumer is intentionally not imported here. SourceManager
///       depends on DiagEngine, and BasicDiagConsumer depends on SourceManager
///       importing it here would create a circular dependency. Consumers are
///       registered by the driver.
///
/// --- Usage example ------------------------------------------------------ ///
///
///   var engine   = DiagEngine();
///   var consumer = BasicDiagConsumer();
///   engine.add_consumer(&consumer);
///
///   // Wire SourceManager without circular import pass a callback and context:
///   var sm = SourceManager(pool, vfm,
///       diag_engine_report_callback,
///       static_cast::<*void>(&engine));
///
///   // Compiler components hold *DiagEngine directly:
///   var lexer = Lexer(sm, &engine);
///
///   // Emit a diagnostic with labels, a fix-it, and an attached note:
///   engine.report(DiagCode(DiagID::SC041E), some_loc,
///           f"function '{name}' has a 'void' return type but returns '{ret}'")
///       .first(fn_name_range)
///       .second(ret_type_range, f"expected 'void', found '{ret}'")
///       .fix(ret_type_range, ret, f"change the return type to '{ret}'")
///       .note(DiagCode(DiagID::SC021N), ret_loc, "the return is here")
///           .child_first(ret_range, "returns here")
///       .emit();
///
///   consumer.finalize_to_stderr();
///   std::print(engine.summary());
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "Native/Types.hh"
ffi "c++" import "vector"
ffi "c++" import "llvm/ADT/DenseMap.h"
ffi "c++" import "llvm/ADT/StringSet.h"

import Diagnostic::Category::DiagCategory
import Diagnostic::Code::DiagCode
import Diagnostic::Consumer::DiagConsumer
import Diagnostic::DiagBuilder::DiagBuilder
import Diagnostic::DiagSink::DiagEngineVBase
import Diagnostic::Diagnostic::Diagnostic
import Diagnostic::Meta::DiagMeta
import Diagnostic::Registry::DiagID
import Diagnostic::Severity::DiagSeverity
import Location::SourceLocation::SourceLocation
import Location::SourceRange::SourceRange



/// Per-code diagnostic policy action, set from the command line and applied
/// uniformly at the single \c emit choke point.
///
///   \c Silence  drop the diagnostic entirely (\c --allow / \c -A)
///   \c Promote  raise a warning to an error   (\c --error / \c -E)
///   \c Forbid   force an error that downstream cannot override (\c --forbid / \c -F)
///   \c Warn     re-enable a code: an Ignored diagnostic is raised to a
///               warning, and (applied after \c -A) it lifts that silence (\c -W)
///
/// The policy table is keyed on category + number (see \c diag_policy_key),
/// e.g. \c SC005 and \c S005 are distinct; the severity letter is not part
/// of the address.
pub enum DiagAction {
    Silence,
    Promote,
    Forbid,
    Warn,
}

/// Dense index of \p cat, 1-based so a valid policy key is never 0.
pub fn diag_category_index(cat: DiagCategory) -> u32 {
    match cat {
        case DiagCategory::Syntax {
            return 1
        } case DiagCategory::Uncategorized {
            return 2
        } case DiagCategory::CodeGen {
            return 3
        } case DiagCategory::Memory {
            return 4
        } case DiagCategory::Resolution {
            return 5
        } case DiagCategory::Linker {
            return 6
        } case DiagCategory::Semantic {
            return 7
        } case DiagCategory::Portability {
            return 8
        } case DiagCategory::Lowering {
            return 9
        } case DiagCategory::Optimization {
            return 10
        } case DiagCategory::Internal {
            return 11
        } default {
            return 0
        }
    }
}

/// Key into the per-code policy table: category index in the high byte, the
/// code number below it. Keying on the number alone made SC005, S005 and R005
/// one entry, so `-A SC005` silenced three unrelated diagnostics.
pub fn diag_policy_key(cat: DiagCategory, number: u32) -> u32 {
    return diag_category_index(cat) << 24 | number & 0x00FFFFFF
}

/// Parses a user-spelled code (\c R020E, \c sc005, \c C889W) into a policy key.
/// Returns 0 when the string has no recognised category prefix or no digits;
/// a bare number is rejected on purpose, since it cannot say which category
/// it means.
pub fn diag_policy_key_from_string(const code: string) -> u32 {
    var n           = code.length()
    var i:   usize  = 0
    var pfx: string = ""
    while i < n && (code[i] == (' ' as u8) || code[i] == ('\t' as u8)) {
        i += 1
    }

    while i < n {
        var c = code[i]
        if c >= ('a' as u8) && c <= ('z' as u8) {
            pfx.push_back(c - 32)
            i += 1
            continue
        }

        if c >= ('A' as u8) && c <= ('Z' as u8) {
            pfx.push_back(c)
            i += 1
            continue
        }

        break
    }

    var val:  u32  = 0
    var seen: bool = false
    while i < n {
        var c = code[i]
        if c >= ('0' as u8) && c <= ('9' as u8) {
            seen = true
            val  = val * 10 + ((c - ('0' as u8)) as u32)
            i += 1
            continue
        }

        break // digit run ended; a trailing severity letter is ignored
    }

    if !seen {
        return 0
    }

    var idx: u32 = 0
    if pfx == "S" {
        idx = 1
    } else if pfx == "U" {
        idx = 2
    } else if pfx == "C" {
        idx = 3
    } else if pfx == "M" {
        idx = 4
    } else if pfx == "R" {
        idx = 5
    } else if pfx == "L" {
        idx = 6
    } else if pfx == "SC" {
        idx = 7
    } else if pfx == "P" {
        idx = 8
    } else if pfx == "CL" {
        idx = 9
    } else if pfx == "OPT" {
        idx = 10
    } else if pfx == "I" {
        idx = 11
    }

    if idx == 0 {
        return 0
    }

    return idx << 24 | val & 0x00FFFFFF
}


/// Central diagnostic hub for a single compilation unit.
///
/// \c DiagEngine receives diagnostics from all compiler components, applies
/// suppression rules (poison scopes, error limits, \c -Werror), updates
/// per-severity counters, and forwards each live diagnostic to all registered
/// \c DiagConsumer instances.
///
/// Components hold a \c *DiagEngine directly. The engine owns all emitted
/// \c Diagnostic objects and frees them on destruction.
///
/// \par Poison scopes
/// A poison scope suppresses all errors and warnings of a given category that
/// fall inside a \c SourceRange. Used to silence cascading diagnostics after
/// a recovery point. Scopes are cleared explicitly via \c clear_poison() or
/// \c clear_all_poison().
///
/// \par Error limit
/// Once \c _error_count reaches \c _error_limit (default 50), further errors
/// and fatals are silently suppressed and counted in \c _suppressed_count.
///
/// \par Consumer registration
/// Consumers are registered with \c add_consumer() and unregistered with
/// \c remove_consumer(). The engine does not own consumers.
pub class DiagEngine derives DiagEngineVBase {
    /// A suppression entry binding a diagnostic category to a source scope.
    struct PoisonEntry {
        var category: DiagCategory
        var scope:    SourceRange
    }

    /// Serializes emit() and consumer registration.
    ///
    /// The engine is a process-wide sink reached from WORKER THREADS: the
    /// lexer runs on the pool and reports straight to emit() (bad escape,
    /// unterminated literal), so _all_diags, the counters and the consumer
    /// list are all touched concurrently. Unsynchronized, a vec growth racing
    /// a push_back relocates the buffer under another thread and double-frees
    /// the elements it moved   observed as a malloc abort inside
    /// ToolDiag::~ToolDiag during a reparse.
    ///
    /// Held across consumer dispatch, not just the bookkeeping, because a
    /// consumer's own storage (ToolDiagConsumer::diags) is shared state too and
    /// consumers are not individually locked. No consumer reports back into the
    /// engine, so this cannot re-enter   keep it that way, this is a plain
    /// non-recursive mutex.
    priv var _mu:          kairo::std::Mutex
    priv var _ice_flushed: bool              = false ///< flush_consumers_for_ice ran.

    priv var _poisoned:  cxx::std::vector<Self::PoisonEntry>
    priv var _consumers: cxx::std::vector<unsafe *DiagConsumer>
    /// Owns every DELIVERED diagnostic, so consumers can take a borrowed
    /// *Diagnostic in handle() without a lifetime question.
    ///
    /// This is a deferred-free list, NOT a log: nothing reads it but the
    /// destructor. So only diagnostics that actually reach a consumer belong
    /// here   a suppressed one is destroyed at its suppression site instead
    /// (the _suppress_depth path at the top of emit() always did this; the
    /// other four paths used to push, which is why a reparse loop retained
    /// ~26k diagnostics per pass while showing 64).
    ///
    /// Still unbounded within a run by design. A tool that reparses in a loop
    /// must call clear_retained() between passes.
    priv var _all_diags:             cxx::std::vector<unsafe *Diagnostic>
    priv var _error_count:           u32                                  = 0
    priv var _warn_count:            u32                                  = 0
    priv var _note_count:            u32                                  = 0
    priv var _remark_count:          u32                                  = 0
    priv var _ignored_count:         u32                                  = 0
    priv var _verbose_count:         u32                                  = 0
    priv var _debug_count:           u32                                  = 0
    priv var _fatal_count:           u32                                  = 0
    priv var _suppressed_count:      u32                                  = 0
    priv var _error_limit:           u32                                  = 50 ///< Max errors before suppression kicks in.
    priv var _suppress_depth:        u32                                  = 0
    priv var _warnings_as_errors:    bool                                 = false
    priv var _suppress_all_warnings: bool                                 = false ///< -w: drop every Warning-severity diagnostic.
    priv var _policy:                llvm::DenseMap<u64, DiagAction> ///< diag_policy_key (as u64: clear of the reserved keys) -> per-code action (see DiagAction). Probed only.
    priv var _warning_limit:         u32                                  = 0 ///< 0 = unlimited.
    priv var _note_limit:            u32                                  = 0 ///< per diagnostic; 0 = unlimited.
    priv var _fixit_limit:           u32                                  = 0xFFFFFFFF ///< per diagnostic (and per child); none = unlimited.
    priv var _quiet:                 bool                                 = false ///< --quiet: drop standalone warnings, notes, remarks.
    /// code hash : location : message of every located diagnostic delivered,
    /// so a second identical report is dropped. A file is tokenized
    /// more than once (the import scan, then the walk), and each lex
    /// reported its warnings again: one octal escape printed S025W 3 times.
    priv var _delivered: llvm::StringSet<llvm::MallocAllocator> ///< membership only; owns the key bytes
    /// The "too many ..." line is printed once per run. Keyed on its own flag,
    /// not on _suppressed_count: a prior -A/-w suppression bumps that counter
    /// and used to swallow the limit notice entirely.
    priv var _error_limit_noted: bool = false
    priv var _warn_limit_noted:  bool = false

    /// ## Constructors

    pub fn DiagEngine(self) {
        self._consumers.reserve(2)
        self._all_diags.reserve(64)
        self._poisoned.reserve(16)
    }

    /// ## Destructor

    /// Destroys all owned \c Diagnostic objects.
    fn op finally (self) {
        for var i: usize = 0; i < self._all_diags.size(); ++i {
            kairo::std::destroy(self._all_diags[i])
        }
    }

    /// ## Consumer registration

    /// Registers \p consumer to receive future diagnostics. Not owned.
    pub fn add_consumer(self, consumer: unsafe *DiagConsumer) {
        var lock = kairo::std::LockGuard(self._mu)
        self._consumers.push_back(consumer)
    }

    /// \brief detaches every consumer and hands the list back to the caller.
    ///
    /// \details The tooling path needs the engine to stop PRINTING for the
    ///          duration of a parse without losing the driver's own consumer
    ///          setup. Snapshot with this, install a collector, restore with
    ///          restore_consumers(). Consumers are non-owning observers here,
    ///          so moving the list around frees nothing.
    pub fn take_consumers(self) -> cxx::std::vector<unsafe *DiagConsumer> {
        var lock = kairo::std::LockGuard(self._mu)
        var out  = self._consumers
        self._consumers.clear()
        return out
    }

    /// \brief restores a list captured by take_consumers(), dropping whatever
    ///        is currently attached.
    pub fn restore_consumers(self, cs: cxx::std::vector<unsafe *DiagConsumer>) {
        var lock = kairo::std::LockGuard(self._mu)
        self._consumers = cs
    }

    /// Unregisters \p consumer. Linear scan; expects a small consumer count.
    pub fn remove_consumer(self, consumer: unsafe *DiagConsumer) {
        var lock       = kairo::std::LockGuard(self._mu)
        var j:   usize = 0
        for var i: usize = 0; i < self._consumers.size(); ++i {
            if self._consumers[i] != consumer {
                if i != j {
                    self._consumers[j] = self._consumers[i]
                }

                j += 1
            }
        }

        while self._consumers.size() > j {
            self._consumers.pop_back()
        }
    }

    /// \brief renders everything the consumers hold to stderr, now.
    ///
    /// \details For the ICE path only: the process aborts next, so the
    ///          driver's own end-of-run flush (CompilerInstance::flush_errors)
    ///          never happens, and a diagnostic naming the source that
    ///          triggered the ICE would die in the buffer. The driver keeps
    ///          exactly one console consumer attached, so this prints once.
    pub fn flush_consumers_for_ice(self) {
        var lock = kairo::std::LockGuard(self._mu)
        // Once: codegen_ice flushes and then ICE_FAILs, and the abort's own
        // hook (CompilerInstance::_flush_for_ice) flushes again; consumers
        // keep what they rendered, so a second pass printed it all twice.
        if self._ice_flushed {
            return
        }

        self._ice_flushed = true
        for var i: usize = 0; i < self._consumers.size(); ++i {
            self._consumers[i]->finalize_to_stderr()
        }
    }

    /// ## Report

    /// Creates a \c DiagBuilder for a diagnostic at \p loc.
    pub fn report(self, code: DiagCode, loc: SourceLocation, msg: string) -> DiagBuilder {
        if loc == SourceLocation::invalid() {
            return self.report(code, msg)
        }

        return DiagBuilder(&self, code, loc, msg)
    }

    /// Creates a \c DiagBuilder for a location-less diagnostic.
    pub fn report(self, code: DiagCode, msg: string) -> DiagBuilder {
        return DiagBuilder(&self, code, msg)
    }

    /// Convenience overloads accepting a raw \c DiagID.
    pub fn report(self, id: DiagID, loc: SourceLocation, msg: string) -> DiagBuilder {
        if loc == SourceLocation::invalid() {
            return self.report(DiagCode(id), msg)
        }

        return DiagBuilder(&self, DiagCode(id), loc, msg)
    }

    pub fn report(self, id: DiagID, msg: string) -> DiagBuilder {
        return DiagBuilder(&self, DiagCode(id), msg)
    }

    /// ## Poison scopes

    /// Suppresses all errors and warnings of \p category inside \p scope.
    fn poison(self, category: DiagCategory, scope: SourceRange) {
        var entry = Self::PoisonEntry{}
        entry.category = category
        entry.scope    = scope
        self._poisoned.push_back(entry)
    }

    /// Returns true if \p loc falls inside an active poison scope for \p category.
    fn is_poisoned(self, category: DiagCategory, loc: SourceLocation) -> bool {
        for var i: usize = 0; i < self._poisoned.size(); ++i {
            if self._poisoned[i].category == category {
                if self._poisoned[i].scope.contains(loc) {
                    return true
                }
            }
        }

        return false
    }

    /// Removes all poison scopes for \p category.
    fn clear_poison(self, category: DiagCategory) {
        var j: usize = 0
        for var i: usize = 0; i < self._poisoned.size(); ++i {
            if self._poisoned[i].category != category {
                if i != j {
                    self._poisoned[j] = self._poisoned[i]
                }

                j += 1
            }
        }

        while self._poisoned.size() > j {
            self._poisoned.pop_back()
        }
    }

    /// Removes all active poison scopes.
    fn clear_all_poison(self) {
        self._poisoned.clear()
    }

    /// ## Emission

    /// Applies suppression rules, updates counters, and forwards \p diag to
    /// all registered consumers. Takes ownership of \p diag.
    ///
    /// Suppression order:
    ///   1. Poison scope errors and warnings inside a poisoned range are dropped.
    ///   2. \c -Werror  warnings are promoted to errors before limit checking.
    ///   3. Error limit errors and fatals beyond \c _error_limit are dropped.
    fn emit(self, diag: unsafe *Diagnostic) {
        // Whole body, not just the push_back: every early-return path below
        // also mutates _suppressed_count and _all_diags. See _mu.
        var lock = kairo::std::LockGuard(self._mu)

        if self._suppress_depth > 0 {
            kairo::std::destroy(diag)
            return
        }

        // Before every counter and policy: a repeat is not a second finding,
        // so it neither counts toward a limit nor reaches a consumer. Only
        // located diagnostics; a location-less one (a driver notice) carries
        // no identity to compare beyond its text.
        if diag->has_loc {
            var key: string = f"{diag->code.hash()}:{diag->loc.raw()}:{diag->message}"
            if !self._delivered.insert(kairo::sref(key)).second {
                kairo::std::destroy(diag)
                return
            }
        }

        var sev = diag->code.severity()
        var cat = diag->code.category()

        if diag->has_loc {
            if sev == DiagSeverity::Error || sev == DiagSeverity::Warning {
                if self.is_poisoned(cat, diag->loc) {
                    self._suppressed_count += 1
                    kairo::std::destroy(diag) // suppressed: never reaches a consumer
                    return
                }
            }
        }

        /// ### Per-code policy + global warning control
        /// Applied at the single choke point so it governs ALL diagnostics
        /// (native S### and clang-adapter C### alike). Keyed on the numeric
        /// part of the code only; the severity letter is not part of the key.
        ///
        /// Precedence, highest wins (do not reorder):
        ///   1. Forbid  (--forbid/-F) -> force Error, non-overridable.
        ///   2. Promote (--error/-E)  -> Warning becomes Error.
        ///   3. Silence (--allow/-A)  -> drop, count suppressed, return.
        ///   4. -w (_suppress_all_warnings) -> drop all Warning-severity.
        ///   5. --Werror (_warnings_as_errors) -> blanket Warning -> Error.
        /// Explicit per-code policy beats blanket flags: --allow beats
        /// --Werror; --forbid beats a later --warn/enable.
        var num = diag_policy_key(cat, diag->code.number())
        var pit = self._policy.find(num as u64)
        if pit != self._policy.end() {
            match pit->second {
                case DiagAction::Forbid {
                    // Non-overridable: force Error regardless of prior severity.
                    if sev != DiagSeverity::Error && sev != DiagSeverity::Fatal {
                        diag->code = self._override_severity(diag->code, DiagSeverity::Error)
                        sev        = DiagSeverity::Error
                    }
                } case DiagAction::Promote {
                    if sev == DiagSeverity::Warning {
                        diag->code = self._override_severity(diag->code, DiagSeverity::Error)
                        sev        = DiagSeverity::Error
                    }
                } case DiagAction::Silence {
                    // Errors and fatals are never silenced: dropping one would
                    // let a broken program compile and exit 0.
                    if sev != DiagSeverity::Error && sev != DiagSeverity::Fatal {
                        self._suppressed_count += 1
                        kairo::std::destroy(diag) // suppressed: never reaches a consumer
                        return
                    }
                } case DiagAction::Warn {
                    // An Ignored-severity code is invisible until asked for.
                    if sev == DiagSeverity::Ignored {
                        diag->code = self._override_severity(diag->code, DiagSeverity::Warning)
                        sev        = DiagSeverity::Warning
                    }
                }
            }
        } else if self._suppress_all_warnings && sev == DiagSeverity::Warning {
            self._suppressed_count += 1
            kairo::std::destroy(diag) // suppressed: never reaches a consumer
            return
        } else if sev == DiagSeverity::Warning && self._warnings_as_errors {
            diag->code = self._override_severity(diag->code, DiagSeverity::Error)
            sev        = DiagSeverity::Error
        }

        // --quiet, after the policy block so a -Werror promoted warning is an
        // error by now and still prints.
        if self._quiet {
            if sev == DiagSeverity::Warning
                || sev == DiagSeverity::Note
                || sev == DiagSeverity::Remark {
                self._suppressed_count += 1
                kairo::std::destroy(diag)
                return
            }
        }

        if sev == DiagSeverity::Warning && self._warning_limit != 0 {
            if self._warn_count >= self._warning_limit {
                if !self._warn_limit_noted {
                    self._warn_limit_noted = true
                    var unsafe *wlimit_diag = kairo::std::create<Diagnostic>(
                        DiagCode(DiagID::U024W),
                        f"too many warnings emitted, further warnings will be suppressed",
                    )

                    self._all_diags.push_back(wlimit_diag)
                    for var i: usize = 0; i < self._consumers.size(); ++i {
                        self._consumers[i]->handle(wlimit_diag)
                    }
                }

                self._suppressed_count += 1
                kairo::std::destroy(diag) // over the warning limit: nobody sees it
                return
            }
        }

        // 0 = unlimited (--cmax-errors=0). Without the guard every error was
        // "over" a limit of 0 and was dropped, so a broken program exited 0.
        if sev == DiagSeverity::Error || sev == DiagSeverity::Fatal {
            if self._error_limit != 0 && self._error_count >= self._error_limit {
                if !self._error_limit_noted {
                    self._error_limit_noted = true
                    var unsafe *limit_diag = kairo::std::create<Diagnostic>(
                        DiagCode(DiagID::I957E),
                        f"too many errors emitted, further errors will be suppressed",
                    )

                    self._all_diags.push_back(limit_diag)
                    for var i: usize = 0; i < self._consumers.size(); ++i {
                        self._consumers[i]->handle(limit_diag)
                    }
                }

                self._suppressed_count += 1
                kairo::std::destroy(diag) // over the error limit: nobody sees it
                return
            }
        }

        match sev {
            case DiagSeverity::Ignored {
                self._ignored_count += 1
            } case DiagSeverity::Remark {
                self._remark_count += 1
            } case DiagSeverity::Verbose {
                self._verbose_count += 1
            } case DiagSeverity::Note {
                self._note_count += 1
            } case DiagSeverity::Debug {
                self._debug_count += 1
            } case DiagSeverity::Warning {
                self._warn_count += 1
            } case DiagSeverity::Error {
                self._error_count += 1
            } case DiagSeverity::Fatal {
                self._fatal_count += 1
                self._error_count += 1
            } default { }
        }

        // --cmax-notes / --cmax-suggestion-count: trim before delivery so every
        // consumer (and the tooling collector) sees the same capped diagnostic.
        if self._note_limit != 0 {
            while diag->children.size() > (self._note_limit as usize) {
                kairo::std::destroy(diag->children[diag->children.size() - 1])
                diag->children.pop_back()
            }
        }

        while diag->fixits.size() > (self._fixit_limit as usize) {
            diag->fixits.pop_back()
        }

        for var i: usize = 0; i < diag->children.size(); ++i {
            while diag->children[i]->fixits.size() > (self._fixit_limit as usize) {
                diag->children[i]->fixits.pop_back()
            }
        }

        self._all_diags.push_back(diag)

        for var i: usize = 0; i < self._consumers.size(); ++i {
            self._consumers[i]->handle(diag)
        }
    }

    /// ## Configuration

    /// Sets the maximum number of errors before suppression. Default: 50.
    /// 0 means unlimited.
    pub fn set_error_limit(self, limit: u32) {
        self._error_limit = limit
    }

    /// Suppresses warnings after \p limit have been delivered. 0 = unlimited.
    pub fn set_warning_limit(self, limit: u32) {
        self._warning_limit = limit
    }

    /// Caps the notes attached to one diagnostic. 0 = unlimited.
    pub fn set_note_limit(self, limit: u32) {
        self._note_limit = limit
    }

    /// Caps the fix-its attached to one diagnostic (and to each note).
    pub fn set_fixit_limit(self, limit: u32) {
        self._fixit_limit = limit
    }

    /// --quiet: standalone warnings, notes and remarks are dropped.
    pub fn set_quiet(self, val: bool) {
        self._quiet = val
    }

    fn push_suppress(self) {
        self._suppress_depth += 1
    }

    fn pop_suppress(self) {
        if self._suppress_depth > 0 {
            self._suppress_depth -= 1
        }
    }

    /// Promotes all warnings to errors when \p val is true.
    pub fn set_warnings_as_errors(self, val: bool) {
        self._warnings_as_errors = val
    }

    /// Suppresses every Warning-severity diagnostic when \p val is true (\c -w).
    pub fn set_suppress_all_warnings(self, val: bool) {
        self._suppress_all_warnings = val
    }

    /// The cheap half of emit()'s policy, decided from the code alone.
    /// Only the -w rule is safe to decide early: a per-code policy (--allow,
    /// --error, --forbid, --warn) can change the severity, so a code that has
    /// one is never dropped here, and errors / fatals never are.
    fn drops(self, const code: DiagCode) -> bool {
        if !self._suppress_all_warnings {
            return false
        }

        if code.severity() != DiagSeverity::Warning {
            return false
        }

        var num = diag_policy_key(code.category(), code.number())
        return !self._policy.contains(num as u64)
    }

    /// Installs a per-code policy action, keyed by \c diag_policy_key
    /// (category + number, severity-letter-agnostic). Last write wins.
    pub fn set_policy(self, code: u32, action: DiagAction) {
        self._policy[code as u64] = action
    }

    /// Returns a copy of \p code re-tagged at \p new_sev. Used to promote a
    /// warning to an error at the emit choke point.
    ///
    /// Severity is baked into a code\'s identity (the hash encodes
    /// category+number+severity) and the error-severity twin of a given code
    /// is not guaranteed to exist in the registry (e.g. S025W has no S025E).
    /// We therefore synthesize the meta directly: the category, number, brief,
    /// and group are preserved; only the severity and the derived id-string
    /// hash change. Consumers render from meta.severity and (code as string),
    /// both of which recompute correctly from the synthesized meta.
    priv fn _override_severity(self, code: DiagCode, new_sev: DiagSeverity) -> DiagCode {
        var m: DiagMeta
        m.brief    = code.brief()
        m.group    = code.group()
        m.number   = code.number()
        m.category = code.category()
        m.severity = new_sev
        // hash encodes category+number+severity for registry re-lookup. A
        // promoted diagnostic is terminal (rendered now, never re-resolved):
        // consumers read only meta.severity and (code as string), neither of
        // which uses hash, and the error-severity twin (e.g. S025E) may not
        // exist in the registry at all. We deliberately carry the original hash
        // forward rather than synthesize a new one; it never round-trips.
        m.hash = code.hash()
        return DiagCode(m)
    }

    /// ## Counters

    /// \brief counts \p warns warnings that were rendered by an earlier
    ///        run and are replayed as text (Driver/ModuleRecords.k), so the
    ///        totals and the exit status are the recorded run's.
    pub fn add_replayed(self, warns: u32) {
        var lock = kairo::std::LockGuard(self._mu)
        self._warn_count += warns
    }

    pub fn has_errors(self) -> bool {
        return self._error_count > 0
    }

    /// Every Diagnostic the engine has ever taken ownership of, including
    /// suppressed and poisoned ones. Never pruned, so this only ever grows
    /// within a run   exposed so a reparse loop can see whether it is the
    /// thing that is growing.
    fn retained_diag_count(self) -> usize {
        return self._all_diags.size()
    }

    /// \brief frees every retained diagnostic and resets the counters.
    ///
    /// \details For a reparse loop: without this the engine accumulates one
    ///          full run's diagnostics per pass forever. Counters go with them
    ///          so error_count() keeps meaning "this pass", which is what the
    ///          tooling path already assumes when it snapshots the counts
    ///          around a parse.
    ///
    /// \warning Invalidates every *Diagnostic previously handed to a consumer.
    ///          Safe because consumers copy what they need (see ToolDiag) and
    ///          none retain the pointer   do not call it mid-emit.
    pub fn clear_retained(self) {
        var lock = kairo::std::LockGuard(self._mu)

        for var i: usize = 0; i < self._all_diags.size(); ++i {
            kairo::std::destroy(self._all_diags[i])
        }

        self._all_diags.clear()
        // a reparse (kairo watch) reports its findings afresh
        self._delivered.clear()

        self._error_count       = 0
        self._warn_count        = 0
        self._note_count        = 0
        self._remark_count      = 0
        self._ignored_count     = 0
        self._verbose_count     = 0
        self._debug_count       = 0
        self._fatal_count       = 0
        self._suppressed_count  = 0
        self._error_limit_noted = false
        self._warn_limit_noted  = false
    }

    pub fn has_fatal(self) -> bool {
        return self._fatal_count > 0
    }

    pub fn fatal_count(self) -> u32 {
        return self._fatal_count
    }

    pub fn error_count(self) -> u32 {
        return self._error_count
    }

    pub fn warn_count(self) -> u32 {
        return self._warn_count
    }

    fn note_count(self) -> u32 {
        return self._note_count
    }

    fn remark_count(self) -> u32 {
        return self._remark_count
    }

    fn ignored_count(self) -> u32 {
        return self._ignored_count
    }

    fn verbose_count(self) -> u32 {
        return self._verbose_count
    }

    fn debug_count(self) -> u32 {
        return self._debug_count
    }

    fn suppressed_count(self) -> u32 {
        return self._suppressed_count
    }

    /// ## Summary

    /// Returns a human-readable summary of emitted diagnostic counts,
    /// e.g. \c "3 error(s), 1 warning(s), 2 suppressed".
    fn summary(self) -> string {
        var out: string
        if self._error_count > 0 {
            out += f"{self._error_count} error(s)"
        }

        if self._warn_count > 0 {
            if out.length() > 0 {
                out += ", "
            }

            out += f"{self._warn_count} warning(s)"
        }

        if self._note_count > 0 {
            if out.length() > 0 {
                out += ", "
            }

            out += f"{self._note_count} note(s)"
        }

        if self._suppressed_count > 0 {
            if out.length() > 0 {
                out += ", "
            }

            out += f"{self._suppressed_count} suppressed"
        }

        if out.length() == 0 {
            out = "no diagnostics"
        }

        return out
    }
}
