/// --- The Kairo Project ------------------- AST/Mixin/TemplateParams.k --- ///
///
///   CRTP mixin for declarations that introduce generic parameters:
///   functions, classes, structs, enums, interfaces, extensions, unions,
///   type aliases. Holds a frozen list of GenericParamDecl plus an optional
///   `where`/`requires` constraint expression.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

import AST::ASTSupport::FrozenList
import AST::Node::Base::{
    Decl,
    Expr,
    Type,
}
import AST::Node::Declarations::{
    GenericParamDecl,
    SpecKind,
}

/// Where clang's fill of an instance of an imported class template stands
/// (ForeignInstantiate::fill). One state, so "filled and failed" cannot be
/// written down.
///
///   Shell         nothing filled: the node's tables and base list are EMPTY
///                 and lookup walks `instantiated_from`. Also the state of a
///                 fill that only could not SPELL an argument in the sets it
///                 tried: that is the demanding TU's gap, retried per set
///                 (ForeignInstantiate::_unspelled), never written here.
///   Filled        clang's instantiation is imported into the node. Terminal.
///   FailedSticky  clang rejected or could not complete the specialization.
///                 Terminal, so a failed instance costs one attempt per build,
///                 not one per member lookup; lookup keeps walking the pattern.
///
/// Threading: written only by ForeignInstantiate, holding its build-wide
/// `_mu`, as the LAST write of a fill (a release store, after the tables it
/// publishes are frozen); read by any Sema thread with no lock, as an
/// acquire load, so a reader that sees Filled sees the whole fill.
/// An instance of a Kairo template never leaves Shell: M2 does not write
/// this, and its members are read through the pattern (SemaContext::body_of).
pub enum ForeignFill derives u8 {
    Shell        = 0,
    Filled       = 1,
    FailedSticky = 2,
}

/// CRTP mixin: a decl `T` derives TemplateParams::<T> to carry generic
/// parameters. Non-generic decls leave `params` empty (count 0) and
/// `requires_clause` null; is_generic() is the cheap gate.
pub class <T> TemplateParams {
    @move
    fn TemplateParams(self, other: Self) = default
    fn TemplateParams(self) = default
    pub var generic_params:  FrozenList<unsafe *GenericParamDecl>
    pub var requires_clause: unsafe *Expr                         = &null ///< `requires <expr>`; null if none.

    /// Specialization classification. `spec_kind == None` for ordinary decls.
    pub var spec_kind: SpecKind = SpecKind::None
    /// The post-name `<...>` argument pattern for a specialization
    /// (`<i32>`, `<[T]>`). Empty for None/Primary-via-`<T>` forms.
    pub var spec_args: FrozenList<unsafe *Type>

    ///   Instantiated   the primary, always: "an instance of which template".
    ///                  A partial spec whose pattern the args select is the
    ///                  BODY, kept on the registry entry (InstanceEntry::
    ///                  pattern; SemaContext::body_of), never here. Written
    ///                  by the registry.
    ///   Explicit/Partial  the primary. Written by T at registration.
    ///   None/Primary   null.
    pub var instantiated_from: unsafe *Decl = &null
    /// A ForeignFill, held as its byte so it can be read and written with
    /// the atomic builtins (a mixin field cannot be an Atomic<T>: the decl
    /// is moved, and an atomic is not). Instance of an IMPORTED template
    /// only; every other decl stays Shell. Never touch it directly: the
    /// DeclFacts accessors (decl_instantiated, decl_fill_failed,
    /// decl_publish_fill) are the atomic loads and the one store.
    pub var foreign_fill: u8 = 0

    pub fn is_specialization(self) -> bool {
        return self.spec_kind == SpecKind::Explicit
            || self.spec_kind == SpecKind::Partial
            || self.spec_kind == SpecKind::Instantiated
    }

    fn is_instance(self) -> bool {
        return self.spec_kind == SpecKind::Instantiated
    }

    /// True if this decl has explicit `<T>` type parameters.
    fn has_type_params(self) -> bool {
        return !self.generic_params.is_empty()
    }

    /// Parser-disambiguation gate: does this decl make its *name* a generic
    /// use-site (`name<...>` parses as generic application)?
    ///
    /// A name is generic iff it carries type parameters OR is a Primary
    /// template. Explicit/Partial specializations do NOT mark the name
    /// generic on their own the primary owns that fact.
    pub fn is_generic(self) -> bool {
        return self.has_type_params() || self.spec_kind == SpecKind::Primary
    }

    fn generic_param_count(self) -> usize {
        return self.generic_params.size()
    }

    fn has_requires(self) -> bool {
        return self.requires_clause != &null
    }
}
