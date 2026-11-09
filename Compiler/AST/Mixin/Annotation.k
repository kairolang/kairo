/// --- The Kairo Project ----------------------- AST/Mixin/Annotation.k --- ///
///
///   Visibility and annotation mixins used by Decl/Stmt/Expr/Type nodes.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------- ///

ffi "c++" import "Native/Types.hh"
ffi "c++" import "vector"

import AST::ASTSupport::{
    FrozenList,
    create_empty_frozen_list,
}
import AST::Node::Base::{
    Decl,
    Expr,
}
import Location::SourceRange::SourceRange
import Memory::ArenaAllocator::ArenaAllocator
import Memory::ArenaList::ArenaList
import Support::FlagSet::{
    FlagBit,
    FlagSet,
}

pub enum VisibilityKind derives u8 {
    None = 0, ///< No keyword written. Sema resolves to a default.
    Private,
    Protected,
    Public,
    Internal, ///< Visible within the same module, including submodules.
    ///< Not accessible across module boundaries even with import.
}

/// CRTP mixin: Decl nodes derive VisibilityAnnotation::<SelfType> to get
/// inline visibility storage and the query/mutation API.
///
/// `None` means no visibility keyword was written. The language's default
/// visibility rule is applied by sema, not here do NOT treat `None` as
/// a synonym for `Public` at the AST level.
pub class <T> VisibilityAnnotation {
    @move
    fn VisibilityAnnotation(self, other: Self) = default
    fn VisibilityAnnotation(self) = default
    pub var visibility:        VisibilityKind = VisibilityKind::None
    pub var _visibility_range: SourceRange    = SourceRange::invalid()

    /// # Queries

    pub fn is_public(const self) -> bool {
        return self.visibility == VisibilityKind::Public
    }

    pub fn is_private(const self) -> bool {
        return self.visibility == VisibilityKind::Private
    }

    pub fn is_protected(const self) -> bool {
        return self.visibility == VisibilityKind::Protected
    }

    fn is_internal(const self) -> bool {
        return self.visibility == VisibilityKind::Internal
    }

    /// True if no visibility keyword was written. Sema will apply the
    /// language default; at the AST level this is NOT equivalent to public.
    fn is_unspecified(const self) -> bool {
        return self.visibility == VisibilityKind::None
    }

    /// True if any visibility keyword was written.
    pub fn has_visibility(const self) -> bool {
        return self.visibility != VisibilityKind::None
    }

    pub fn visibility_range(const self) -> SourceRange {
        return self._visibility_range
    }

    /// # Mutation

    pub fn set_visibility(self, kind: VisibilityKind, range: SourceRange) {
        self.visibility        = kind
        self._visibility_range = range
    }

    fn clear_visibility(self) {
        self.visibility        = VisibilityKind::None
        self._visibility_range = SourceRange::invalid()
    }

    // switch v {
    //     case 0  { return VisibilityKind::None;      }
    //     case 1  { return VisibilityKind::Private;   }
    //     case 2  { return VisibilityKind::Protected; }
    //     case 3  { return VisibilityKind::Public;    }
    //     case 4  { return VisibilityKind::Internal;  }
    //     default { return VisibilityKind::None;      }
    // }
}

/// Syntactic kind of a source-level annotation.
///
/// Visibility is handled separately by VisibilityAnnotation and is NOT
/// a member of this enum.
pub enum AnnotationKind derives u8 {
    Attribute = 0, ///< @inline, @deprecated, etc.
    DocComment,    ///< /// ... attached to the following declaration,
    ///  is concatenated into one token if multiple lines
    LineComment,  ///< //  ... kept for tools that want to preserve non-doc comments
    BlockComment, ///< /*  ... */
}

/// Presence bits for annotation kinds. One bit per AnnotationKind; the set
/// present is a FlagSet (Support/FlagSet.k). Used to make has_*() queries
/// O(1) without scanning the entry list.
pub enum AnnotationPresence derives u8 {
    HasAttribute    = 1 << 0,
    HasDocComment   = 1 << 1,
    HasLineComment  = 1 << 2,
    HasBlockComment = 1 << 3,
}

/// AnnotationPresence's variants are its FlagSet's bits (Support/FlagSet.k).
extend AnnotationPresence impl FlagBit<u8> {
    inline fn bit(const self) -> u8 {
        return self as u8
    }
}

/// A single annotation entry.
///
/// For Attribute entries, `name` is the imm ident index of the attribute name
/// (e.g. the index for "inline" in `@inline`). For comment entries,
/// `name` is u32(-1) (the invalid sentinel); do NOT use 0, which is a valid
/// imm ident index.
pub class AnnotationEntry {
    pub var kind:  AnnotationKind           = AnnotationKind::Attribute
    pub var name:  u32                      = u32::MAX
    pub var range: SourceRange              = SourceRange::invalid()
    pub var args:  FrozenList<unsafe *Expr>

    /// The declaration this attribute's NAME refers to, when it refers to one
    /// at all. Written by NameResolution N(b); null otherwise.
    ///
    /// Most attributes (`@inline`, `@deprecated`) are compiler builtins with
    /// no declaration anywhere, so a null here is the NORMAL case and is never
    /// diagnosed. It is non-null for user-defined attribute macros, which are
    /// ordinary decls (ProcedureMacroDecl) reached by ordinary lookup   that
    /// is what makes jump-to-def work on `@my_macro`.
    ///
    /// Argument expressions in `args` are NOT resolved by N: attribute
    /// argument folding is a later concern, names only here.
    pub var resolved_decl: unsafe *Decl = &null

    fn AnnotationEntry(self) { }

    pub fn AnnotationEntry(self, k: AnnotationKind, n: u32, r: SourceRange) {
        self.kind  = k
        self.name  = n
        self.range = r
        self.args  = create_empty_frozen_list<unsafe *Expr>()
    }
}

/// CRTP mixin: attaches an ArenaList of annotation entries plus a
/// presence bitmask for O(1) existence checks.
///
/// Call `init_annotations(ctx)` exactly once before any `add_*` call.
pub class <T> Annotation {
    pub var annotations: ArenaList<AnnotationEntry>

    /// `presence` is a redundant set of which AnnotationKinds are present
    /// in `annotations`. It exists so `has_*()` queries on sema hot paths are
    /// O(1) instead of scanning the list.
    pub var presence: FlagSet<AnnotationPresence, u8>

    pub fn init_annotations(self, arena: unsafe *ArenaAllocator) {
        self.annotations.set_allocator(arena, 2)
    }

    /// # O(1) presence queries

    fn has_any_annotation(const self) -> bool {
        return !self.presence.empty()
    }

    pub fn has_attribute(const self) -> bool {
        return self.presence.has(AnnotationPresence::HasAttribute)
    }

    fn has_doc_comment(const self) -> bool {
        return self.presence.has(AnnotationPresence::HasDocComment)
    }

    fn has_line_comment(const self) -> bool {
        return self.presence.has(AnnotationPresence::HasLineComment)
    }

    fn has_block_comment(const self) -> bool {
        return self.presence.has(AnnotationPresence::HasBlockComment)
    }

    fn has_kind(const self, kind: AnnotationKind) -> bool {
        return self.presence.has(Annotation<T>::_bit_for(kind))
    }

    /// # O(N) range / lookup queries

    /// First range for `kind`, or invalid() if none. Guard with has_kind()
    /// to avoid the scan when you only need presence.
    fn first_range(self, kind: AnnotationKind) -> SourceRange {
        if !self.has_kind(kind) {
            return SourceRange::invalid()
        }

        for var i: usize = 0; i < self.annotations.size(); ++i {
            var unsafe *entry = self.annotations.get(i)
            if entry->kind == kind {
                return entry->range
            }
        }

        return SourceRange::invalid()
    }

    /// True if an attribute with the given interned name is present.
    pub fn has_attribute_named(self, name: u32) -> bool {
        if !self.has_attribute() {
            return false
        }

        for var i: usize = 0; i < self.annotations.size(); ++i {
            var unsafe *entry = self.annotations.get(i)
            if entry->kind == AnnotationKind::Attribute && entry->name == name {
                return true
            }
        }

        return false
    }

    pub fn attribute_range(self, name: u32) -> SourceRange {
        if !self.has_attribute() {
            return SourceRange::invalid()
        }

        for var i: usize = 0; i < self.annotations.size(); ++i {
            var unsafe *entry = self.annotations.get(i)
            if entry->kind == AnnotationKind::Attribute && entry->name == name {
                return entry->range
            }
        }

        return SourceRange::invalid()
    }

    /// Append all attribute entries to `out`. Preserves source order.
    fn collect_attributes(self, @inout out: cxx::std::vector<unsafe *AnnotationEntry>) {
        if !self.has_attribute() {
            return
        }

        for var i: usize = 0; i < self.annotations.size(); ++i {
            var unsafe *entry = self.annotations.get(i)
            if entry->kind == AnnotationKind::Attribute {
                out.push_back(entry)
            }
        }
    }

    /// # Mutation
    /// NOTE: add_* functions do NOT check for duplicates. If you need to enforce
    /// uniqueness, check with has_*() first and decide how to handle duplicates
    /// (e.g. ignore, merge spans, emit a diag, etc).

    pub fn add_annotation(self, kind: AnnotationKind, name: u32, range: SourceRange) {
        if !self.annotations.has_allocator() {
            kairo::std::ice_fail("Annotation::add_* called before init_annotations()")
        }

        self.annotations.push(AnnotationEntry(kind, name, range))
        self.presence.set(Annotation<T>::_bit_for(kind))
    }

    pub fn add_annotation(self,
                          kind:  AnnotationKind,
                          name:  u32,
                          range: SourceRange,
                          args:  FrozenList<unsafe *Expr>) {
        if !self.annotations.has_allocator() {
            kairo::std::ice_fail("Annotation::add_* called before allocator wiring")
        }

        var e = AnnotationEntry(kind, name, range)
        e.args = args
        self.annotations.push(e)
        self.presence.set(Annotation<T>::_bit_for(kind))
    }

    fn add_attribute(self, name: u32, range: SourceRange) {
        self.add_annotation(AnnotationKind::Attribute, name, range)
    }

    fn add_doc_comment(self, range: SourceRange) {
        self.add_annotation(AnnotationKind::DocComment, u32::MAX, range)
    }

    fn add_line_comment(self, range: SourceRange) {
        self.add_annotation(AnnotationKind::LineComment, u32::MAX, range)
    }

    fn add_block_comment(self, range: SourceRange) {
        self.add_annotation(AnnotationKind::BlockComment, u32::MAX, range)
    }

    /// # Private

    priv static fn _bit_for(kind: AnnotationKind) -> AnnotationPresence {
        match kind {
            case AnnotationKind::Attribute {
                return AnnotationPresence::HasAttribute
            } case AnnotationKind::DocComment {
                return AnnotationPresence::HasDocComment
            } case AnnotationKind::LineComment {
                return AnnotationPresence::HasLineComment
            } case AnnotationKind::BlockComment {
                return AnnotationPresence::HasBlockComment
            }
        }
    }
}
