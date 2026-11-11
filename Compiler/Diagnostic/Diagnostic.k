/// --- The Kairo Project ---------------------- Diagnostic/Diagnostic.k --- ///
///
///   Diagnostic instance and associated label and fix-it types.
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
import Location::SourceLocation::SourceLocation
import Location::SourceRange::SourceRange

/// Source annotation attached to a \c Diagnostic.
///
/// Labels mark source ranges with an underline style and optional message.
/// The \c PrettyConsumer renders \c StrikeThrough using Unicode combining
/// characters; all other consumers fall back to ASCII.
pub struct DiagLabel {
    /// Underline style applied to \c range in rendered output.
    pub enum Style derives u8 {
        Primary,       ///< Primary caret span.              ^^^
        Secondary,     ///< Secondary span.                  +++
        Highlight,     ///< Highlighted region.              ---
        StrikeThrough, ///< Struck-out region (ASCII + Unicode in pretty mode). ~~~
    }

    pub var text:  string      ///< Annotation message. Empty string = underline only.
    pub var range: SourceRange
    pub var style: Self::Style
}

/// A suggested edit attached to a \c Diagnostic.
///
/// Describes a single source replacement: remove \c range and insert
/// \c replacement in its place. \c message is shown to the user explaining
/// the intent of the fix.
/// The three fix-it edit shapes, kept explicitly separate rather than inferred
/// from range/replacement emptiness (which is ambiguous). Renderers key on this.
///   Add     insert \c replacement at a point (\c range is a zero-width caret)
///   Remove  delete \c range (\c replacement is empty)
///   Replace delete \c range and insert \c replacement in its place
pub enum FixKind {
    Add,
    Remove,
    Replace,
}

pub struct FixIt {
    pub var replacement: string
    pub var message:     string                         ///< e.g. "change the return type to 'i32'"
    pub var range:       SourceRange
    pub var kind:        FixKind     = FixKind::Replace ///< default preserves prior fix() behaviour
}


/// A single emitted diagnostic.
///
/// Carries the \c DiagCode, a human-readable message, an optional source
/// location, zero or more source labels, zero or more fix-it hints, and
/// zero or more child diagnostics (notes attached to a parent error or
/// warning).
///
/// Children are owned by the parent and destroyed in \c op delete.
/// Vectors are pre-reserved at construction to avoid small-size reallocations
/// on the common path.
pub class Diagnostic {
    pub var message:  string
    pub var children: cxx::std::vector<unsafe *Diagnostic> ///< Attached notes, owned by this diagnostic.
    pub var labels:   cxx::std::vector<DiagLabel> ///< Source annotations, in source order.
    pub var fixits:   cxx::std::vector<FixIt> ///< Suggested edits.
    pub var loc:      SourceLocation
    pub var code:     DiagCode
    pub var has_loc:  bool

    /// # Constructors

    /// Constructs an empty, invalid diagnostic.
    fn Diagnostic(self) {
        self.code    = DiagCode()
        self.message = ""
        self.has_loc = false
        self.labels.reserve(4)
        self.fixits.reserve(2)
        self.children.reserve(2)
    }

    /// Constructs a diagnostic with a known location.
    fn Diagnostic(self, _code: DiagCode, _loc: SourceLocation, _msg: string) {
        self.code    = _code
        self.message = _msg
        self.loc     = _loc
        self.has_loc = true
        self.labels.reserve(4)
        self.fixits.reserve(2)
        self.children.reserve(2)
    }

    /// Constructs a location-less diagnostic (e.g. linker or internal errors).
    fn Diagnostic(self, _code: DiagCode, _msg: string) {
        self.code    = _code
        self.message = _msg
        self.has_loc = false
        self.labels.reserve(4)
        self.fixits.reserve(2)
        self.children.reserve(2)
    }

    /// # Destructor

    // Move-only: the destructor destroys `children`, so a copy would destroy
    // them twice. The source is left with no children.
    @move fn Diagnostic(self, other: Self) {
        self.message  = cxx::std::move(other.message)
        self.children = cxx::std::move(other.children)
        self.labels   = cxx::std::move(other.labels)
        self.fixits   = cxx::std::move(other.fixits)
        self.loc      = other.loc
        self.code     = other.code
        self.has_loc  = other.has_loc
        other.children.clear()
    }

    /// Recursively destroys all owned child diagnostics.
    fn op finally (self) {
        for var i: usize = 0; i < self.children.size(); ++i {
            kairo::std::destroy(self.children[i])
        }
    }
}
