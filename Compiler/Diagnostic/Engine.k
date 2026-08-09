/// --- The Kairo Project -------------------------- Diagnostic/Engine.k --- ///
///
///   Diagnostic engine, builder, and poison-scope suppression.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
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
///           f"function '{name}' has a 'void' return type but returns '{ret}\x27")
///       .first(fn_name_range)
///       .second(ret_type_range, f"expected 'void', found '{ret}\x27")
///       .fix(ret_type_range, ret, f"change the return type to '{ret}\x27")
///       .note(DiagCode(DiagID::SC021N), ret_loc, "the return is here")
///           .child_first(ret_range, "returns here")
///       .emit();
///
///   consumer.finalize_to_stderr();
///   std::print(engine.summary());
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "Native/Types.hh";

import Location::SourceRange::*;
import Diagnostic::Registry::*;
import Diagnostic::Diagnostic::*;
import Diagnostic::Consumer::*;

class DiagEngineVBase {
    virtual fn emit(self, diag: *Diagnostic) { 0; };
}

class DiagEngine;

/// Per-code diagnostic policy action, set from the command line and applied
/// uniformly at the single \c emit choke point.
///
///   \c Silence  drop the diagnostic entirely (\c --allow / \c -A)
///   \c Promote  raise a warning to an error   (\c --error / \c -E)
///   \c Forbid   force an error that downstream cannot override (\c --forbid / \c -F)
///
/// The policy table is keyed on the NUMERIC part of the code only
/// (e.g. 25 for \c S025 / \c S025W, 889 for \c C889); the severity letter
/// is not part of the address.
enum DiagAction {
    Silence,
    Promote,
    Forbid,
}
class DiagBuilder;

/// Fluent builder for constructing and emitting a single \c Diagnostic.
///
/// Obtained from \c DiagEngine::report(). Labels, fix-its, and child
/// diagnostics are attached via chained method calls. The diagnostic is
/// emitted either by calling \c emit() explicitly or automatically on
/// destruction if \c emit() was never called.
///
/// Ownership of the underlying \c Diagnostic transfers to \c DiagEngine
/// on emission. If the builder is destroyed before \c emit() is called,
/// the diagnostic is emitted first, then the pointer is not freed the
/// engine owns it from that point.
///
/// \note All label and fix-it methods return \c ref!(DiagBuilder) to
///       support method chaining.
class DiagBuilder {
    priv var _engine:  obs::<DiagEngineVBase>;
    priv var _diag:    own::<Diagnostic>;
    priv var _emitted: bool;

    // --- Constructors --------------------------------------------------------

    fn DiagBuilder(self, engine: *DiagEngineVBase, code: DiagCode, loc: SourceLocation, msg: string) {
        if loc == SourceLocation::invalid() {
            self._engine  = engine;
            self._diag    = std::create::<Diagnostic>(code, msg);
            self._emitted = false;
            return;
        }

        self._engine  = engine;
        self._diag    = std::create::<Diagnostic>(code, loc, msg);
        self._emitted = false;
    }

    fn DiagBuilder(self, engine: *DiagEngineVBase, code: DiagCode, msg: string) {
        self._engine  = engine;
        self._diag    = std::create::<Diagnostic>(code, msg);
        self._emitted = false;
    }

    fn DiagBuilder(self, other: mref!(DiagBuilder)) {
        self._engine   = other._engine;
        self._diag     = other._diag;
        self._emitted  = other._emitted;
        other._emitted = true;     // source must not emit on its dtor
        other._diag    = &null;    // source no longer owns the diag
    }

    // Move-assign: drop what we hold (if un-emitted), then steal.
    fn op = (self, other: mref!(DiagBuilder)) -> ref!(DiagBuilder) {
        if (&self) == (&other) { return self; }
        if (!self._emitted) && (self._diag != &null) {
            std::destroy(self._diag);
        }
        self._engine   = other._engine;
        self._diag     = other._diag;
        self._emitted  = other._emitted;
        other._emitted = true;
        other._diag    = &null;
        return self;
    }

    // Copy is forbidden: a raw-pointer member with a freeing dtor double-frees
    // on any copy. Misuse (pass-by-value, auto b2 = b) is now a compile error.
    delete fn DiagBuilder(self, other: ref!(DiagBuilder));
    delete fn op = (self, other: ref!(DiagBuilder)) -> ref!(DiagBuilder);

    // --- Labels --------------------------------------------------------------

    /// Attaches a primary label (\c ^^^) to \p range.
    fn first(self, range: SourceRange, text: string = "") -> ref!(DiagBuilder) {
        if !range.is_valid() {
            return self;
        }

        var label = DiagLabel{};
        label.range = range;
        label.text  = text;
        label.style = DiagLabel::Style::Primary;
        self._diag->labels.push_back(label);
        return self;
    }

    /// Attaches a secondary label (\c +++) to \p range.
    fn second(self, range: SourceRange, text: string = "") -> ref!(DiagBuilder) {
        if !range.is_valid() {
            return self;
        }

        var label = DiagLabel{};
        label.range = range;
        label.text  = text;
        label.style = DiagLabel::Style::Secondary;
        self._diag->labels.push_back(label);
        return self;
    }

    /// Attaches a highlight label (\c ---) to \p range.
    fn highlight(self, range: SourceRange, text: string = "") -> ref!(DiagBuilder) {
        if !range.is_valid() {
            return self;
        }

        var label = DiagLabel{};
        label.range = range;
        label.text  = text;
        label.style = DiagLabel::Style::Highlight;
        self._diag->labels.push_back(label);
        return self;
    }

    /// Attaches a strikethrough label (\c ~~~) to \p range.
    /// Rendered with Unicode combining strikethrough in \c PrettyConsumer;
    /// falls back to ASCII in all other consumers.
    fn strike(self, range: SourceRange, text: string = "") -> ref!(DiagBuilder) {
        if !range.is_valid() {
            return self;
        }

        var label = DiagLabel{};
        label.range = range;
        label.text  = text;
        label.style = DiagLabel::Style::StrikeThrough;
        self._diag->labels.push_back(label);
        return self;
    }

    // --- Fix-its -------------------------------------------------------------

    /// Attaches a fix-it that replaces \p range with \p replacement.
    /// \p msg is shown to the user describing the intent of the edit.
    /// Replace \p range with \p replacement (the general edit).
    fn fix(self, range: SourceRange, replacement: string, msg: string) -> ref!(DiagBuilder) {
        if !range.is_valid() {
            return self;
        }

        var f = FixIt{};
        f.range       = range;
        f.replacement = replacement;
        f.message     = msg;
        f.kind        = FixKind::Replace;
        self._diag->fixits.push_back(f);
        return self;
    }

    /// Delete \p range (no insertion).
    fn remove(self, range: SourceRange, msg: string) -> ref!(DiagBuilder) {
        if !range.is_valid() {
            return self;
        }

        var f = FixIt{};
        f.range       = range;
        f.replacement = "";
        f.message     = msg;
        f.kind        = FixKind::Remove;
        self._diag->fixits.push_back(f);
        return self;
    }

    fn fix(self, msg: string) -> ref!(DiagBuilder) {
        var f = FixIt{};
        f.range       = SourceRange::invalid();
        f.replacement = "";
        f.message     = msg;
        
        self._diag->fixits.push_back(f);
        return self;
    }

    /// Attaches a fix-it that inserts \p text at \p loc (zero-length replacement).
    fn insert(self, loc: SourceLocation, text: string, msg: string) -> ref!(DiagBuilder) {
        var r = SourceRange{};
        r.start = loc;
        r.end   = loc;

        if !loc.is_valid() {
            return self;
        }

        var f = FixIt{};
        f.range       = r;
        f.replacement = text;
        f.message     = msg;
        f.kind        = FixKind::Add;
        self._diag->fixits.push_back(f);
        return self;
    }

    // --- Child diagnostics ---------------------------------------------------

    priv fn _add_child(self, code: DiagCode, loc: SourceLocation, msg: string) -> ref!(DiagBuilder) {
        if loc == SourceLocation::invalid() {
            return self._add_child_no_loc(code, msg);
        }

        var child = std::create::<Diagnostic>(code, loc, msg);
        self._diag->children.push_back(child);
        return self;
    }

    priv fn _add_child_no_loc(self, code: DiagCode, msg: string) -> ref!(DiagBuilder) {
        var child = std::create::<Diagnostic>(code, msg);
        self._diag->children.push_back(child);
        return self;
    }

    /// Attaches a child note. Overloaded for with/without source location.
    fn note(self, code: DiagCode, loc: SourceLocation, msg: string) -> ref!(DiagBuilder) {
        if loc == SourceLocation::invalid() {
            return self._add_child_no_loc(code, msg);
        }
        
        return self._add_child(code, loc, msg);
    }
    fn note(self, code: DiagCode, msg: string) -> ref!(DiagBuilder) {
        return self._add_child_no_loc(code, msg);
    }

    /// Attaches a child warning.
    fn warning(self, code: DiagCode, loc: SourceLocation, msg: string) -> ref!(DiagBuilder) {
        if loc == SourceLocation::invalid() {
            return self._add_child_no_loc(code, msg);
        }

        return self._add_child(code, loc, msg);
    }
    fn warning(self, code: DiagCode, msg: string) -> ref!(DiagBuilder) {
        return self._add_child_no_loc(code, msg);
    }

    /// Attaches a child remark.
    fn remark(self, code: DiagCode, loc: SourceLocation, msg: string) -> ref!(DiagBuilder) {
        if loc == SourceLocation::invalid() {
            return self._add_child_no_loc(code, msg);
        }

        return self._add_child(code, loc, msg);
    }
    fn remark(self, code: DiagCode, msg: string) -> ref!(DiagBuilder) {
        return self._add_child_no_loc(code, msg);
    }

    /// Attaches a child verbose note.
    fn verbose(self, code: DiagCode, loc: SourceLocation, msg: string) -> ref!(DiagBuilder) {
        if loc == SourceLocation::invalid() {
            return self._add_child_no_loc(code, msg);
        }

        return self._add_child(code, loc, msg);
    }

    /// Attaches a child debug note (stripped in release builds).
    fn debug_note(self, code: DiagCode, loc: SourceLocation, msg: string) -> ref!(DiagBuilder) {
        if loc == SourceLocation::invalid() {
            return self._add_child_no_loc(code, msg);
        }

        return self._add_child(code, loc, msg);
    }

    fn verbose(self, code: DiagCode, msg: string) -> ref!(DiagBuilder) {
        return self._add_child_no_loc(code, msg);
    }
    
    fn debug_note(self, code: DiagCode, msg: string) -> ref!(DiagBuilder) {
        return self._add_child_no_loc(code, msg);
    }

    // --- Child diagnostics (no independent code) -----------------------------
    //
    // A child diagnostic is not independently addressable: it is never emitted
    // to the engine on its own, never counted, never poison-checked, and never
    // explained. The only field the consumer reads is severity. These overloads
    // use the reserved I900 base so callers do not have to invent a code that
    // nothing consumes.

    /// Attaches a child note.
    fn note(self, loc: SourceLocation, msg: string) -> ref!(DiagBuilder) {
        if loc == SourceLocation::invalid() {
            return self._add_child_no_loc(DiagCode(DiagID::I900N), msg);
        }
        return self._add_child(DiagCode(DiagID::I900N), loc, msg);
    }
    fn note(self, msg: string) -> ref!(DiagBuilder) {
        return self._add_child_no_loc(DiagCode(DiagID::I900N), msg);
    }

    /// Attaches a child warning.
    fn warning(self, loc: SourceLocation, msg: string) -> ref!(DiagBuilder) {
        if loc == SourceLocation::invalid() {
            return self._add_child_no_loc(DiagCode(DiagID::I900W), msg);
        }
        return self._add_child(DiagCode(DiagID::I900W), loc, msg);
    }
    fn warning(self, msg: string) -> ref!(DiagBuilder) {
        return self._add_child_no_loc(DiagCode(DiagID::I900W), msg);
    }

    /// Attaches a child remark.
    fn remark(self, loc: SourceLocation, msg: string) -> ref!(DiagBuilder) {
        if loc == SourceLocation::invalid() {
            return self._add_child_no_loc(DiagCode(DiagID::I900R), msg);
        }
        return self._add_child(DiagCode(DiagID::I900R), loc, msg);
    }
    fn remark(self, msg: string) -> ref!(DiagBuilder) {
        return self._add_child_no_loc(DiagCode(DiagID::I900R), msg);
    }

    /// Attaches a child verbose note.
    fn verbose(self, loc: SourceLocation, msg: string) -> ref!(DiagBuilder) {
        if loc == SourceLocation::invalid() {
            return self._add_child_no_loc(DiagCode(DiagID::I900V), msg);
        }
        return self._add_child(DiagCode(DiagID::I900V), loc, msg);
    }
    fn verbose(self, msg: string) -> ref!(DiagBuilder) {
        return self._add_child_no_loc(DiagCode(DiagID::I900V), msg);
    }

    /// Attaches a child debug note (stripped in release builds).
    fn debug_note(self, loc: SourceLocation, msg: string) -> ref!(DiagBuilder) {
        if loc == SourceLocation::invalid() {
            return self._add_child_no_loc(DiagCode(DiagID::I900D), msg);
        }
        return self._add_child(DiagCode(DiagID::I900D), loc, msg);
    }
    fn debug_note(self, msg: string) -> ref!(DiagBuilder) {
        return self._add_child_no_loc(DiagCode(DiagID::I900D), msg);
    }

    // --- Child labels --------------------------------------------------------
    //
    // These attach labels to the most recently added child diagnostic.
    // Silently no-ops if no child has been added yet.

    /// Attaches a primary label to the last child diagnostic.
    fn child_first(self, range: SourceRange, text: string = "") -> ref!(DiagBuilder) {
        if range.is_invalid() {
            return self;
        }

        if self._diag->children.size() > 0 {
            var child = self._diag->children[self._diag->children.size() - 1];
            var label = DiagLabel{};
            label.range = range;
            label.text  = text;
            label.style = DiagLabel::Style::Primary;
            child->labels.push_back(label);
        }
        return self;
    }

    /// Attaches a secondary label to the last child diagnostic.
    fn child_second(self, range: SourceRange, text: string = "") -> ref!(DiagBuilder) {
        if range.is_invalid() {
            return self;
        }

        if self._diag->children.size() > 0 {
            var child = self._diag->children[self._diag->children.size() - 1];
            var label = DiagLabel{};
            label.range = range;
            label.text  = text;
            label.style = DiagLabel::Style::Secondary;
            child->labels.push_back(label);
        }
        return self;
    }

    /// Attaches a fix-it to the last child diagnostic.
    fn child_fix(self, range: SourceRange, replacement: string, msg: string) -> ref!(DiagBuilder) {
        if range.is_invalid() {
            return self;
        }

        if self._diag->children.size() > 0 {
            var child = self._diag->children[self._diag->children.size() - 1];
            var f = FixIt{};
            f.range       = range;
            f.replacement = replacement;
            f.message     = msg;
            child->fixits.push_back(f);
        }
        return self;
    }

    // --- Emission ------------------------------------------------------------

    /// Emits the diagnostic to \c DiagEngineVBase. Idempotent subsequent calls
    /// are no-ops. Ownership of \c _diag transfers to the engine.
    fn emit(self); // defined out-of-line after DiagEngineVBase

    // --- Destructor ----------------------------------------------------------

    /// Emits the diagnostic if \c emit() was never called explicitly.
    /// If the builder was never emitted and emit fails, \c _diag is freed
    /// to avoid a leak.
    fn op delete (self) {
        if !self._emitted {
            // built but never emitted: a bug. We do NOT implicitly emit
            // implicit emit-at-scope-exit collides with suppression scopes
            // (TentativeGuard) and hides the mistake. Debug aborts; release
            // frees the orphan to avoid a leak, dropping the diagnostic.
             ICE_FAIL("DiagBuilder dropped without emit()");
            if self._diag != &null {
                std::destroy(self._diag);
            }
        }
    }
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
class DiagEngine derives DiagEngineVBase {

    /// A suppression entry binding a diagnostic category to a source scope.
    struct PoisonEntry {
        var category: DiagCategory;
        var scope:    SourceRange;
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
    priv var _mu:                 std::Mutex;

    priv var _poisoned:           vec::<PoisonEntry>;
    priv var _consumers:          vec::<obs::<DiagConsumer>>;
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
    priv var _all_diags:          vec::<own::<Diagnostic>>;
    priv var _error_count:        u32  = 0;
    priv var _warn_count:         u32  = 0;
    priv var _note_count:         u32  = 0;
    priv var _remark_count:       u32  = 0;
    priv var _ignored_count:      u32  = 0;
    priv var _verbose_count:      u32  = 0;
    priv var _debug_count:        u32  = 0;
    priv var _fatal_count:        u32  = 0;
    priv var _suppressed_count:   u32  = 0;
    priv var _error_limit:        u32  = 50; ///< Max errors before suppression kicks in.
    priv var _suppress_depth:     u32  = 0;
    priv var _warnings_as_errors: bool = false;
    priv var _suppress_all_warnings: bool = false;   ///< -w: drop every Warning-severity diagnostic.
    priv var _policy: map::<u32, DiagAction>;        ///< numeric-code -> per-code action (see DiagAction).

    // --- Constructors --------------------------------------------------------

    fn DiagEngine(self) {
        self._consumers.reserve(2);
        self._all_diags.reserve(64);
        self._poisoned.reserve(16);
    }

    // --- Destructor ----------------------------------------------------------

    /// Destroys all owned \c Diagnostic objects.
    fn op delete (self) {
        for var i: usize = 0; i < self._all_diags.size(); ++i {
            std::destroy(self._all_diags[i]);
        }
    }

    // --- Consumer registration -----------------------------------------------

    /// Registers \p consumer to receive future diagnostics. Not owned.
    fn add_consumer(self, consumer: *DiagConsumer) {
        var lock = std::LockGuard(self._mu);
        self._consumers.push_back(consumer);
    }

    /// \brief detaches every consumer and hands the list back to the caller.
    ///
    /// \details The tooling path needs the engine to stop PRINTING for the
    ///          duration of a parse without losing the driver's own consumer
    ///          setup. Snapshot with this, install a collector, restore with
    ///          restore_consumers(). Consumers are non-owning observers here,
    ///          so moving the list around frees nothing.
    fn take_consumers(self) -> vec::<obs::<DiagConsumer>> {
        var lock = std::LockGuard(self._mu);
        var out = self._consumers;
        self._consumers.clear();
        return out;
    }

    /// \brief restores a list captured by take_consumers(), dropping whatever
    ///        is currently attached.
    fn restore_consumers(self, cs: vec::<obs::<DiagConsumer>>) {
        var lock = std::LockGuard(self._mu);
        self._consumers = cs;
    }

    /// Unregisters \p consumer. Linear scan; expects a small consumer count.
    fn remove_consumer(self, consumer: *DiagConsumer) {
        var lock = std::LockGuard(self._mu);
        var j: usize = 0;
        for var i: usize = 0; i < self._consumers.size(); ++i {
            if self._consumers[i] != consumer {
                if i != j {
                    self._consumers[j] = self._consumers[i];
                }

                j += 1;
            }
        }

        while self._consumers.size() > j {
            self._consumers.pop_back();
        }
    }

    // --- Report --------------------------------------------------------------

    /// Creates a \c DiagBuilder for a diagnostic at \p loc.
    fn report(self, code: DiagCode, loc: SourceLocation, msg: string) -> DiagBuilder {
        if loc == SourceLocation::invalid() {
            return self.report(code, msg);
        }

        return DiagBuilder(&self, code, loc, msg);
    }

    /// Creates a \c DiagBuilder for a location-less diagnostic.
    fn report(self, code: DiagCode, msg: string) -> DiagBuilder {
        return DiagBuilder(&self, code, msg);
    }

    /// Convenience overloads accepting a raw \c DiagID.
    fn report(self, id: DiagID, loc: SourceLocation, msg: string) -> DiagBuilder {
        if loc == SourceLocation::invalid() {
            return self.report(DiagCode(id), msg);
        }

        return DiagBuilder(&self, DiagCode(id), loc, msg);
    }

    fn report(self, id: DiagID, msg: string) -> DiagBuilder {
        return DiagBuilder(&self, DiagCode(id), msg);
    }

    // --- Poison scopes -------------------------------------------------------

    /// Suppresses all errors and warnings of \p category inside \p scope.
    fn poison(self, category: DiagCategory, scope: SourceRange) {
        var entry = PoisonEntry{};
        entry.category = category;
        entry.scope    = scope;
        self._poisoned.push_back(entry);
    }

    /// Returns true if \p loc falls inside an active poison scope for \p category.
    fn is_poisoned(self, category: DiagCategory, loc: SourceLocation) -> bool {
        for var i: usize = 0; i < self._poisoned.size(); ++i {
            if self._poisoned[i].category == category {
                if self._poisoned[i].scope.contains(loc) {
                    return true;
                }
            }
        }
        return false;
    }

    /// Removes all poison scopes for \p category.
    fn clear_poison(self, category: DiagCategory) {
        var j: usize = 0;
        for var i: usize = 0; i < self._poisoned.size(); ++i {
            if self._poisoned[i].category != category {
                if i != j {
                    self._poisoned[j] = self._poisoned[i];
                }

                j += 1;
            }
        }

        while self._poisoned.size() > j {
            self._poisoned.pop_back();
        }
    }

    /// Removes all active poison scopes.
    fn clear_all_poison(self) {
        self._poisoned.clear();
    }

    // --- Emission ------------------------------------------------------------

    /// Applies suppression rules, updates counters, and forwards \p diag to
    /// all registered consumers. Takes ownership of \p diag.
    ///
    /// Suppression order:
    ///   1. Poison scope errors and warnings inside a poisoned range are dropped.
    ///   2. \c -Werror  warnings are promoted to errors before limit checking.
    ///   3. Error limit errors and fatals beyond \c _error_limit are dropped.
    fn emit(self, diag: *Diagnostic) {
        // Whole body, not just the push_back: every early-return path below
        // also mutates _suppressed_count and _all_diags. See _mu.
        var lock = std::LockGuard(self._mu);

        if self._suppress_depth > 0 {
            std::destroy(diag);
            return;
        }

        var sev = diag->code.severity();
        var cat = diag->code.category();

        if diag->has_loc {
            if sev == DiagSeverity::Error || sev == DiagSeverity::Warning {
                if self.is_poisoned(cat, diag->loc) {
                    self._suppressed_count += 1;
                    std::destroy(diag);   // suppressed: never reaches a consumer
                    return;
                }
            }
        }

        // --- Per-code policy + global warning control --------------------
        // Applied at the single choke point so it governs ALL diagnostics
        // (native S### and clang-adapter C### alike). Keyed on the numeric
        // part of the code only; the severity letter is not part of the key.
        //
        // Precedence, highest wins (do not reorder):
        //   1. Forbid  (--forbid/-F) -> force Error, non-overridable.
        //   2. Promote (--error/-E)  -> Warning becomes Error.
        //   3. Silence (--allow/-A)  -> drop, count suppressed, return.
        //   4. -w (_suppress_all_warnings) -> drop all Warning-severity.
        //   5. --Werror (_warnings_as_errors) -> blanket Warning -> Error.
        // Explicit per-code policy beats blanket flags: --allow beats
        // --Werror; --forbid beats a later --warn/enable.
        var num = diag->code.number();
        if self._policy.contains(num) {
            switch self._policy[num] {
                case DiagAction::Forbid {
                    // Non-overridable: force Error regardless of prior severity.
                    if sev != DiagSeverity::Error && sev != DiagSeverity::Fatal {
                        diag->code = self._override_severity(diag->code, DiagSeverity::Error);
                        sev = DiagSeverity::Error;
                    }
                }
                case DiagAction::Promote {
                    if sev == DiagSeverity::Warning {
                        diag->code = self._override_severity(diag->code, DiagSeverity::Error);
                        sev = DiagSeverity::Error;
                    }
                }
                case DiagAction::Silence {
                    self._suppressed_count += 1;
                    std::destroy(diag);   // suppressed: never reaches a consumer
                    return;
                }
                default {}
            }
        } else if self._suppress_all_warnings && sev == DiagSeverity::Warning {
            self._suppressed_count += 1;
            std::destroy(diag);   // suppressed: never reaches a consumer
            return;
        } else if sev == DiagSeverity::Warning && self._warnings_as_errors {
            diag->code = self._override_severity(diag->code, DiagSeverity::Error);
            sev = DiagSeverity::Error;
        }

        if sev == DiagSeverity::Error || sev == DiagSeverity::Fatal {
            if self._error_count >= self._error_limit {
                if self._suppressed_count == 0 {
                    var limit_diag = std::create::<Diagnostic>(
                        DiagCode(DiagID::I957E),
                        f"too many errors emitted, further errors will be suppressed");
                    self._all_diags.push_back(limit_diag);
                    for var i: usize = 0; i < self._consumers.size(); ++i {
                        self._consumers[i]->handle(limit_diag);
                    }
                }

                self._suppressed_count += 1;
                std::destroy(diag);   // over the error limit: nobody sees it
                return;
            }
        }

        switch sev {
            case DiagSeverity::Ignored  { self._ignored_count += 1; }
            case DiagSeverity::Remark   { self._remark_count  += 1; }
            case DiagSeverity::Verbose  { self._verbose_count += 1; }
            case DiagSeverity::Note     { self._note_count    += 1; }
            case DiagSeverity::Debug    { self._debug_count   += 1; }
            case DiagSeverity::Warning  { self._warn_count    += 1; }
            case DiagSeverity::Error    { self._error_count   += 1; }
            case DiagSeverity::Fatal    { self._fatal_count   += 1;
                                          self._error_count   += 1; }
            default {}
        }

        self._all_diags.push_back(diag);

        for var i: usize = 0; i < self._consumers.size(); ++i {
            self._consumers[i]->handle(diag);
        }
    }

    // --- Configuration -------------------------------------------------------

    /// Sets the maximum number of errors before suppression. Default: 50.
    fn set_error_limit(self, limit: u32) { self._error_limit = limit; }
    fn push_suppress(self) {
        self._suppress_depth += 1;
    }
    fn pop_suppress(self)  {
        if self._suppress_depth > 0 {
            self._suppress_depth -= 1;
        }
    }

    /// Promotes all warnings to errors when \p val is true.
    fn set_warnings_as_errors(self, val: bool)  { self._warnings_as_errors = val; }

    /// Suppresses every Warning-severity diagnostic when \p val is true (\c -w).
    fn set_suppress_all_warnings(self, val: bool) { self._suppress_all_warnings = val; }

    /// Installs a per-code policy action, keyed on the numeric part of the
    /// code (severity-letter-agnostic). Last write for a given number wins.
    fn set_policy(self, code: u32, action: DiagAction) { self._policy[code] = action; }

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
        var m: DiagMeta;
        m.brief    = code.brief();
        m.group    = code.group();
        m.number   = code.number();
        m.category = code.category();
        m.severity = new_sev;
        // hash encodes category+number+severity for registry re-lookup. A
        // promoted diagnostic is terminal (rendered now, never re-resolved):
        // consumers read only meta.severity and (code as string), neither of
        // which uses hash, and the error-severity twin (e.g. S025E) may not
        // exist in the registry at all. We deliberately carry the original hash
        // forward rather than synthesize a new one; it never round-trips.
        m.hash     = code.hash();
        return DiagCode(m);
    }

    // --- Counters ------------------------------------------------------------

    fn has_errors(self) -> bool      { return self._error_count > 0;  }
    /// Every Diagnostic the engine has ever taken ownership of, including
    /// suppressed and poisoned ones. Never pruned, so this only ever grows
    /// within a run   exposed so a reparse loop can see whether it is the
    /// thing that is growing.
    fn retained_diag_count(self) -> usize { return self._all_diags.size(); }

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
    fn clear_retained(self) {
        var lock = std::LockGuard(self._mu);

        for var i: usize = 0; i < self._all_diags.size(); ++i {
            std::destroy(self._all_diags[i]);
        }
        self._all_diags.clear();

        self._error_count      = 0;
        self._warn_count       = 0;
        self._note_count       = 0;
        self._remark_count     = 0;
        self._ignored_count    = 0;
        self._verbose_count    = 0;
        self._debug_count      = 0;
        self._fatal_count      = 0;
        self._suppressed_count = 0;
    }

    fn has_fatal(self) -> bool       { return self._fatal_count > 0;  }
    fn error_count(self) -> u32      { return self._error_count;      }
    fn warn_count(self) -> u32       { return self._warn_count;       }
    fn note_count(self) -> u32       { return self._note_count;       }
    fn remark_count(self) -> u32     { return self._remark_count;     }
    fn ignored_count(self) -> u32    { return self._ignored_count;    }
    fn verbose_count(self) -> u32    { return self._verbose_count;    }
    fn debug_count(self) -> u32      { return self._debug_count;      }
    fn suppressed_count(self) -> u32 { return self._suppressed_count; }

    // --- Summary -------------------------------------------------------------

    /// Returns a human-readable summary of emitted diagnostic counts,
    /// e.g. \c "3 error(s), 1 warning(s), 2 suppressed".
    fn summary(self) -> string {
        var out: string;
        if self._error_count > 0 {
            out += f"{self._error_count} error(s)";
        }
        if self._warn_count > 0 {
            if out.length() > 0 { out += ", "; }
            out += f"{self._warn_count} warning(s)";
        }
        if self._note_count > 0 {
            if out.length() > 0 { out += ", "; }
            out += f"{self._note_count} note(s)";
        }
        if self._suppressed_count > 0 {
            if out.length() > 0 { out += ", "; }
            out += f"{self._suppressed_count} suppressed";
        }
        if out.length() == 0 {
            out = "no diagnostics";
        }
        return out;
    }
}

// --- Out-of-line definitions -------------------------------------------------

/// Emits the diagnostic to the engine. Idempotent.
/// Ownership of \c _diag transfers to \c DiagEngine on first call.
fn DiagBuilder::emit() {
    if self._emitted {
        return;
    }
    self._emitted = true;
    self._engine->emit(self._diag);
}