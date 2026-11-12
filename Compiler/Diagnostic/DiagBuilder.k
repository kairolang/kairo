/// --- The Kairo Project --------------------- Diagnostic/DiagBuilder.k --- ///
///
///   DiagBuilder: the fluent builder DiagEngine::report() returns.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "Native/Types.hh"
ffi "c++" import "vector"

import Diagnostic::Code::DiagCode
import Diagnostic::DiagSink::DiagEngineVBase
import Diagnostic::Diagnostic::{
    DiagLabel,
    Diagnostic,
    FixIt,
    FixKind,
}
import Diagnostic::Registry::DiagID
import Location::SourceLocation::SourceLocation
import Location::SourceRange::SourceRange

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
pub class DiagBuilder {
    priv var _engine:  *DiagEngineVBase
    priv var _diag:    unsafe *Diagnostic
    priv var _emitted: bool

    /// ## Constructors

    fn DiagBuilder(self,
                   engine: *DiagEngineVBase,
                   code:   DiagCode,
                   loc:    SourceLocation,
                   msg:    string) {
        // Suppressed before it exists: no Diagnostic, and _emitted set so
        // emit() and the destructor are no-ops; every attach below sees null.
        // Every field is set before the first return: Stage 1 rejects a
        // constructor return ahead of its last field initialization (SC001E).
        self._engine  = engine
        self._diag    = &null
        self._emitted = true
        if engine->drops(code) {
            return
        }

        self._emitted = false
        if loc == SourceLocation::invalid() {
            self._diag = kairo::std::create<Diagnostic>(code, msg)
            return
        }

        self._diag = kairo::std::create<Diagnostic>(code, loc, msg)
    }

    fn DiagBuilder(self, engine: *DiagEngineVBase, code: DiagCode, msg: string) {
        self._engine  = engine
        self._diag    = &null
        self._emitted = true
        if engine->drops(code) {
            return
        }

        self._diag    = kairo::std::create<Diagnostic>(code, msg)
        self._emitted = false
    }

    @move fn DiagBuilder(self, other: Self) {
        self._engine   = other._engine
        self._diag     = other._diag
        self._emitted  = other._emitted
        other._emitted = true           // source must not emit on its dtor
        other._diag    = &null          // source no longer owns the diag
    }

    // Assignment is derived from the @move constructor (self-check, destroy,
    // move in). The destroy runs the destructor, so assigning over a builder
    // that was never emitted ICEs like dropping one: that is a lost
    // diagnostic, and the ICE is what catches it.

    // Copy is forbidden: a raw-pointer member with a freeing dtor double-frees
    // on any copy. Misuse (pass-by-value, auto b2 = b) is a compile error.

    /// ## Labels

    /// Attaches a primary label (\c ^^^) to \p range.
    pub fn first(self, range: SourceRange, const text: string = "") -> unsafe *Self {
        if self._diag == &null {
            return unsafe &self
        }

        if !range.is_valid() {
            return unsafe &self
        }

        var label = DiagLabel{}
        label.range = range
        label.text  = text
        label.style = DiagLabel::Style::Primary
        self._diag->labels.push_back(label)
        return unsafe &self
    }

    /// Attaches a secondary label (\c +++) to \p range.
    pub fn second(self, range: SourceRange, const text: string = "") -> unsafe *Self {
        if self._diag == &null {
            return unsafe &self
        }

        if !range.is_valid() {
            return unsafe &self
        }

        var label = DiagLabel{}
        label.range = range
        label.text  = text
        label.style = DiagLabel::Style::Secondary
        self._diag->labels.push_back(label)
        return unsafe &self
    }

    /// Attaches a highlight label (\c ---) to \p range.
    fn highlight(self, range: SourceRange, const text: string = "") -> unsafe *Self {
        if self._diag == &null {
            return unsafe &self
        }

        if !range.is_valid() {
            return unsafe &self
        }

        var label = DiagLabel{}
        label.range = range
        label.text  = text
        label.style = DiagLabel::Style::Highlight
        self._diag->labels.push_back(label)
        return unsafe &self
    }

    /// Attaches a strikethrough label (\c ~~~) to \p range.
    /// Rendered with Unicode combining strikethrough in \c PrettyConsumer;
    /// falls back to ASCII in all other consumers.
    fn strike(self, range: SourceRange, const text: string = "") -> unsafe *Self {
        if self._diag == &null {
            return unsafe &self
        }

        if !range.is_valid() {
            return unsafe &self
        }

        var label = DiagLabel{}
        label.range = range
        label.text  = text
        label.style = DiagLabel::Style::StrikeThrough
        self._diag->labels.push_back(label)
        return unsafe &self
    }

    /// ## Fix-its

    /// Attaches a fix-it that replaces \p range with \p replacement.
    /// \p msg is shown to the user describing the intent of the edit.
    /// Replace \p range with \p replacement (the general edit).
    pub fn fix(self,
               range:             SourceRange,
               const replacement: string,
               const msg:         string) -> unsafe *Self {
        if self._diag == &null {
            return unsafe &self
        }

        if !range.is_valid() {
            return unsafe &self
        }

        var f = FixIt{}
        f.range       = range
        f.replacement = replacement
        f.message     = msg
        f.kind        = FixKind::Replace
        self._diag->fixits.push_back(f)
        return unsafe &self
    }

    /// Delete \p range (no insertion).
    pub fn remove(self, range: SourceRange, const msg: string) -> unsafe *Self {
        if self._diag == &null {
            return unsafe &self
        }

        if !range.is_valid() {
            return unsafe &self
        }

        var f = FixIt{}
        f.range       = range
        f.replacement = ""
        f.message     = msg
        f.kind        = FixKind::Remove
        self._diag->fixits.push_back(f)
        return unsafe &self
    }

    pub fn fix(self, const msg: string) -> unsafe *Self {
        if self._diag == &null {
            return unsafe &self
        }

        var f = FixIt{}
        f.range       = SourceRange::invalid()
        f.replacement = ""
        f.message     = msg

        self._diag->fixits.push_back(f)
        return unsafe &self
    }

    /// Attaches a fix-it that inserts \p text at \p loc (zero-length replacement).
    pub fn insert(self,
                  loc:        SourceLocation,
                  const text: string,
                  const msg:  string) -> unsafe *Self {
        if self._diag == &null {
            return unsafe &self
        }

        var r = SourceRange()
        r.start = loc
        r.end   = loc

        if !loc.is_valid() {
            return unsafe &self
        }

        var f = FixIt{}
        f.range       = r
        f.replacement = text
        f.message     = msg
        f.kind        = FixKind::Add
        self._diag->fixits.push_back(f)
        return unsafe &self
    }

    /// ## Child diagnostics

    priv fn _add_child(self, code: DiagCode, loc: SourceLocation, msg: string) -> unsafe *Self {
        if self._diag == &null {
            return unsafe &self
        }

        if loc == SourceLocation::invalid() {
            return self._add_child_no_loc(code, msg)
        }

        var unsafe *child = kairo::std::create<Diagnostic>(code, loc, msg)
        self._diag->children.push_back(child)
        return unsafe &self
    }

    priv fn _add_child_no_loc(self, code: DiagCode, msg: string) -> unsafe *Self {
        if self._diag == &null {
            return unsafe &self
        }

        var unsafe *child = kairo::std::create<Diagnostic>(code, msg)
        self._diag->children.push_back(child)
        return unsafe &self
    }

    /// Attaches a child note. Overloaded for with/without source location.
    ///
    /// Every child adder returns THIS builder, the parent's: `->first(r)`
    /// after it labels the parent, not the note. Label the note with
    /// `->child_first(r)`; `->first(r)` would label the parent, drawing the
    /// note's range on the parent's own line, or on another file's line of
    /// the same number.
    pub fn note(self,
                const code: DiagCode,
                loc:        SourceLocation,
                const msg:  string) -> unsafe *Self {
        if self._diag == &null {
            return unsafe &self
        }

        if loc == SourceLocation::invalid() {
            return self._add_child_no_loc(code, msg)
        }

        return self._add_child(code, loc, msg)
    }

    pub fn note(self, const code: DiagCode, const msg: string) -> unsafe *Self {
        if self._diag == &null {
            return unsafe &self
        }

        return self._add_child_no_loc(code, msg)
    }

    /// Attaches a child warning.
    pub fn warning(self,
                   const code: DiagCode,
                   loc:        SourceLocation,
                   const msg:  string) -> unsafe *Self {
        if self._diag == &null {
            return unsafe &self
        }

        if loc == SourceLocation::invalid() {
            return self._add_child_no_loc(code, msg)
        }

        return self._add_child(code, loc, msg)
    }

    fn warning(self, const code: DiagCode, const msg: string) -> unsafe *Self {
        if self._diag == &null {
            return unsafe &self
        }

        return self._add_child_no_loc(code, msg)
    }

    /// Attaches a child remark.
    fn remark(self, const code: DiagCode, loc: SourceLocation, const msg: string) -> unsafe *Self {
        if self._diag == &null {
            return unsafe &self
        }

        if loc == SourceLocation::invalid() {
            return self._add_child_no_loc(code, msg)
        }

        return self._add_child(code, loc, msg)
    }

    fn remark(self, const code: DiagCode, const msg: string) -> unsafe *Self {
        if self._diag == &null {
            return unsafe &self
        }

        return self._add_child_no_loc(code, msg)
    }

    /// Attaches a child verbose note.
    fn verbose(self, const code: DiagCode, loc: SourceLocation, const msg: string) -> unsafe *Self {
        if self._diag == &null {
            return unsafe &self
        }

        if loc == SourceLocation::invalid() {
            return self._add_child_no_loc(code, msg)
        }

        return self._add_child(code, loc, msg)
    }

    /// Attaches a child debug note (stripped in release builds).
    fn debug_note(self,
                  const code: DiagCode,
                  loc:        SourceLocation,
                  const msg:  string) -> unsafe *Self {
        if self._diag == &null {
            return unsafe &self
        }

        if loc == SourceLocation::invalid() {
            return self._add_child_no_loc(code, msg)
        }

        return self._add_child(code, loc, msg)
    }

    fn verbose(self, const code: DiagCode, const msg: string) -> unsafe *Self {
        if self._diag == &null {
            return unsafe &self
        }

        return self._add_child_no_loc(code, msg)
    }

    fn debug_note(self, const code: DiagCode, const msg: string) -> unsafe *Self {
        if self._diag == &null {
            return unsafe &self
        }

        return self._add_child_no_loc(code, msg)
    }

    /// ## Child diagnostics (no independent code)
    ///
    /// A child diagnostic is not independently addressable: it is never emitted
    /// to the engine on its own, never counted, never poison-checked, and never
    /// explained. The only field the consumer reads is severity. These overloads
    /// use the reserved I900 base so callers do not have to invent a code that
    /// nothing consumes.

    /// Attaches a child note; label it with child_first (see the note above).
    pub fn note(self, loc: SourceLocation, const msg: string) -> unsafe *Self {
        if self._diag == &null {
            return unsafe &self
        }

        if loc == SourceLocation::invalid() {
            return self._add_child_no_loc(DiagCode(DiagID::I900N), msg)
        }

        return self._add_child(DiagCode(DiagID::I900N), loc, msg)
    }

    pub fn note(self, const msg: string) -> unsafe *Self {
        if self._diag == &null {
            return unsafe &self
        }

        return self._add_child_no_loc(DiagCode(DiagID::I900N), msg)
    }

    /// Attaches a child warning.
    fn warning(self, loc: SourceLocation, const msg: string) -> unsafe *Self {
        if self._diag == &null {
            return unsafe &self
        }

        if loc == SourceLocation::invalid() {
            return self._add_child_no_loc(DiagCode(DiagID::I900W), msg)
        }

        return self._add_child(DiagCode(DiagID::I900W), loc, msg)
    }

    fn warning(self, const msg: string) -> unsafe *Self {
        if self._diag == &null {
            return unsafe &self
        }

        return self._add_child_no_loc(DiagCode(DiagID::I900W), msg)
    }

    /// Attaches a child remark.
    fn remark(self, loc: SourceLocation, const msg: string) -> unsafe *Self {
        if self._diag == &null {
            return unsafe &self
        }

        if loc == SourceLocation::invalid() {
            return self._add_child_no_loc(DiagCode(DiagID::I900R), msg)
        }

        return self._add_child(DiagCode(DiagID::I900R), loc, msg)
    }

    pub fn remark(self, const msg: string) -> unsafe *Self {
        if self._diag == &null {
            return unsafe &self
        }

        return self._add_child_no_loc(DiagCode(DiagID::I900R), msg)
    }

    /// Attaches a child verbose note.
    fn verbose(self, loc: SourceLocation, const msg: string) -> unsafe *Self {
        if self._diag == &null {
            return unsafe &self
        }

        if loc == SourceLocation::invalid() {
            return self._add_child_no_loc(DiagCode(DiagID::I900V), msg)
        }

        return self._add_child(DiagCode(DiagID::I900V), loc, msg)
    }

    fn verbose(self, const msg: string) -> unsafe *Self {
        if self._diag == &null {
            return unsafe &self
        }

        return self._add_child_no_loc(DiagCode(DiagID::I900V), msg)
    }

    /// Attaches a child debug note (stripped in release builds).
    fn debug_note(self, loc: SourceLocation, const msg: string) -> unsafe *Self {
        if self._diag == &null {
            return unsafe &self
        }

        if loc == SourceLocation::invalid() {
            return self._add_child_no_loc(DiagCode(DiagID::I900D), msg)
        }

        return self._add_child(DiagCode(DiagID::I900D), loc, msg)
    }

    fn debug_note(self, const msg: string) -> unsafe *Self {
        if self._diag == &null {
            return unsafe &self
        }

        return self._add_child_no_loc(DiagCode(DiagID::I900D), msg)
    }

    /// ## Child labels
    ///
    /// These attach labels to the most recently added child diagnostic.
    /// Silently no-ops if no child has been added yet.

    /// Attaches a primary label to the last child diagnostic.
    pub fn child_first(self, range: SourceRange, const text: string = "") -> unsafe *Self {
        if self._diag == &null {
            return unsafe &self
        }

        if range.is_invalid() {
            return unsafe &self
        }

        if self._diag->children.size() > 0 {
            var unsafe *child = self._diag->children[self._diag->children.size() - 1]
            var label = DiagLabel{}
            label.range = range
            label.text  = text
            label.style = DiagLabel::Style::Primary
            child->labels.push_back(label)
        }

        return unsafe &self
    }

    /// Attaches a secondary label to the last child diagnostic.
    fn child_second(self, range: SourceRange, const text: string = "") -> unsafe *Self {
        if self._diag == &null {
            return unsafe &self
        }

        if range.is_invalid() {
            return unsafe &self
        }

        if self._diag->children.size() > 0 {
            var unsafe *child = self._diag->children[self._diag->children.size() - 1]
            var label = DiagLabel{}
            label.range = range
            label.text  = text
            label.style = DiagLabel::Style::Secondary
            child->labels.push_back(label)
        }

        return unsafe &self
    }

    /// Attaches a fix-it to the last child diagnostic.
    pub fn child_fix(self,
                     range:             SourceRange,
                     const replacement: string,
                     const msg:         string) -> unsafe *Self {
        if self._diag == &null {
            return unsafe &self
        }

        if range.is_invalid() {
            return unsafe &self
        }

        if self._diag->children.size() > 0 {
            var unsafe *child = self._diag->children[self._diag->children.size() - 1]
            var f = FixIt{}
            f.range       = range
            f.replacement = replacement
            f.message     = msg
            child->fixits.push_back(f)
        }

        return unsafe &self
    }

    /// ## Emission

    /// Emits the diagnostic to \c DiagEngineVBase. Idempotent subsequent calls
    /// are no-ops. Ownership of \c _diag transfers to the engine.
    pub fn emit(self) {
        if self._emitted {
            return
        }

        self._emitted = true
        self._engine->emit(self._diag)
        // The engine owns it now, and may already have destroyed it (a
        // duplicate, a poisoned range, the error limit). Null makes a later
        // attach (`b.emit(); b.note(...)`) the no-op every attach already is
        // for a dropped builder, instead of a write into freed memory.
        self._diag = &null
    }

    /// ## Destructor

    /// Emits the diagnostic if \c emit() was never called explicitly.
    /// If the builder was never emitted and emit fails, \c _diag is freed
    /// to avoid a leak.
    fn op finally (self) {
        if !self._emitted {
            // built but never emitted: a bug. We do NOT implicitly emit
            // implicit emit-at-scope-exit collides with suppression scopes
            // (TentativeGuard) and hides the mistake. Debug aborts; release
            // frees the orphan to avoid a leak, dropping the diagnostic.
            kairo::std::ice_fail("DiagBuilder dropped without emit()")
        }
    }
}
