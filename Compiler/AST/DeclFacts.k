/// --- The Kairo Project ------------------------------ AST/DeclFacts.k --- ///
///
///   \brief Reading the CRTP mixin slots off a `*Decl`.
///
///   \detail
///     TemplateParams, FFILinkage and Redeclarable are mixins: each decl kind
///     derives its own instantiation, so there is no base a `*Decl` can be
///     read through, and every consumer that needed `generic_params` off a
///     base pointer wrote the same eight-arm switch. Those switches lived in
///     TypeResolve, ChainBinding, TypeUtil, MemberLookup, TypeExport,
///     ForeignInstantiate, DeclImport and RedeclMerge, and disagreed on which
///     kinds they covered. This is the one copy.
///
///     Every accessor answers for EVERY kind that carries the slot, and the
///     empty / null / false answer for every kind that does not. A caller
///     that wants a narrower set filters on kind itself.
///
///   Layer: AST. Imports AST only.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "Native/Types.hh" // kairo::std::ice_fail
ffi "c++" import "vector"

import AST::ASTSupport::{
    FrozenList,
    create_empty_frozen_list,
}
import AST::Context::DeclContext::DeclContextKind
import AST::Mixin::TemplateParams::ForeignFill
import AST::Node::Base::{
    Decl,
    Expr,
    Type,
}
import AST::Node::CanonicalNodes::{
    RecordType,
    canon_unqual,
}
import AST::Node::Casting::{
    cast,
    dyn_cast,
    isa,
}
import AST::Node::Declarations
import AST::Node::Types::{
    CXXLValueRefType,
    CXXRValueRefType,
    GenericParamType,
}
import Token::Token::Token

/// # Namespace scopes

/// The declarations \p d stands for in a namespace scope, pushed on \p out
/// in source order: \p d itself, or, for a wrapper, what it holds -- a
/// `module` block's decls, a visibility group's members, an `eval` block's
/// body -- flattened through nested wrappers. A pass that walks the file's
/// top-level items for generic declarations calls this on each, so a
/// declaration inside `module m { }` is reached as one at file scope is
/// (RequiresDesugar, ConstraintExtraction: a bound there was dropped).
pub fn scope_decls(d: unsafe *Decl, @inout out: cxx::std::vector<unsafe *Decl>) {
    if d == &null {
        return
    }

    if isa<Declarations::ModuleDecl>(d) {
        var unsafe *m = cast<Declarations::ModuleDecl>(d)
        for var i: usize = 0; i < m->dc_decls.size(); i++ {
            scope_decls(*m->dc_decls.get(i), &out)
        }

        return
    }

    if isa<Declarations::VisibilityGroupDecl>(d) {
        var unsafe *g = cast<Declarations::VisibilityGroupDecl>(d)
        for var i: usize = 0; i < g->members.size(); i++ {
            scope_decls(*g->members.get(i), &out)
        }

        return
    }

    if isa<Declarations::EvalBlockDecl>(d) {
        var unsafe *b = cast<Declarations::EvalBlockDecl>(d)
        for var i: usize = 0; i < b->body.size(); i++ {
            scope_decls(*b->body.get(i), &out)
        }

        return
    }

    out.push_back(d)
}

/// # TemplateParams
///
/// Function, Struct, Class, Interface, Extension, Enum, Union, TypeAlias.

pub fn decl_generic_params(d: unsafe *Decl) -> FrozenList<unsafe *Declarations::GenericParamDecl> {
    if d == &null {
        return create_empty_frozen_list<unsafe *Declarations::GenericParamDecl>()
    }

    if isa<Declarations::ClassDecl>(d) {
        return cast<Declarations::ClassDecl>(d)->generic_params
    }

    if isa<Declarations::StructDecl>(d) {
        return cast<Declarations::StructDecl>(d)->generic_params
    }

    if isa<Declarations::UnionDecl>(d) {
        return cast<Declarations::UnionDecl>(d)->generic_params
    }

    if isa<Declarations::InterfaceDecl>(d) {
        return cast<Declarations::InterfaceDecl>(d)->generic_params
    }

    if isa<Declarations::EnumDecl>(d) {
        return cast<Declarations::EnumDecl>(d)->generic_params
    }

    if isa<Declarations::TypeAliasDecl>(d) {
        return cast<Declarations::TypeAliasDecl>(d)->generic_params
    }

    if isa<Declarations::FunctionDecl>(d) {
        return cast<Declarations::FunctionDecl>(d)->generic_params
    }

    if isa<Declarations::ExtensionDecl>(d) {
        return cast<Declarations::ExtensionDecl>(d)->generic_params
    }

    return create_empty_frozen_list<unsafe *Declarations::GenericParamDecl>()
}

/// The decl's `requires` clause (RequiresDesugar hoisted every inline
/// bound into it), or null.
pub fn decl_requires_clause(d: unsafe *Decl) -> unsafe *Expr {
    if d == &null {
        return &null
    }

    if isa<Declarations::ClassDecl>(d) {
        return cast<Declarations::ClassDecl>(d)->requires_clause
    }

    if isa<Declarations::StructDecl>(d) {
        return cast<Declarations::StructDecl>(d)->requires_clause
    }

    if isa<Declarations::UnionDecl>(d) {
        return cast<Declarations::UnionDecl>(d)->requires_clause
    }

    if isa<Declarations::InterfaceDecl>(d) {
        return cast<Declarations::InterfaceDecl>(d)->requires_clause
    }

    if isa<Declarations::EnumDecl>(d) {
        return cast<Declarations::EnumDecl>(d)->requires_clause
    }

    if isa<Declarations::TypeAliasDecl>(d) {
        return cast<Declarations::TypeAliasDecl>(d)->requires_clause
    }

    if isa<Declarations::FunctionDecl>(d) {
        return cast<Declarations::FunctionDecl>(d)->requires_clause
    }

    if isa<Declarations::ExtensionDecl>(d) {
        return cast<Declarations::ExtensionDecl>(d)->requires_clause
    }

    return &null
}

/// The slot itself, for a writer (DeclImport fills it). Null for a kind
/// that has none.
pub fn decl_generic_params_slot(d: unsafe *Decl) -> unsafe *FrozenList<unsafe *Declarations::GenericParamDecl> {
    if d == &null {
        return &null
    }

    if isa<Declarations::ClassDecl>(d) {
        return unsafe &cast<Declarations::ClassDecl>(d)->generic_params
    }

    if isa<Declarations::StructDecl>(d) {
        return unsafe &cast<Declarations::StructDecl>(d)->generic_params
    }

    if isa<Declarations::UnionDecl>(d) {
        return unsafe &cast<Declarations::UnionDecl>(d)->generic_params
    }

    if isa<Declarations::InterfaceDecl>(d) {
        return unsafe &cast<Declarations::InterfaceDecl>(d)->generic_params
    }

    if isa<Declarations::EnumDecl>(d) {
        return unsafe &cast<Declarations::EnumDecl>(d)->generic_params
    }

    if isa<Declarations::TypeAliasDecl>(d) {
        return unsafe &cast<Declarations::TypeAliasDecl>(d)->generic_params
    }

    if isa<Declarations::FunctionDecl>(d) {
        return unsafe &cast<Declarations::FunctionDecl>(d)->generic_params
    }

    if isa<Declarations::ExtensionDecl>(d) {
        return unsafe &cast<Declarations::ExtensionDecl>(d)->generic_params
    }

    return &null
}

pub fn decl_spec_kind(d: unsafe *Decl) -> Declarations::SpecKind {
    if d == &null {
        return Declarations::SpecKind::None
    }

    if isa<Declarations::ClassDecl>(d) {
        return cast<Declarations::ClassDecl>(d)->spec_kind
    }

    if isa<Declarations::StructDecl>(d) {
        return cast<Declarations::StructDecl>(d)->spec_kind
    }

    if isa<Declarations::UnionDecl>(d) {
        return cast<Declarations::UnionDecl>(d)->spec_kind
    }

    if isa<Declarations::InterfaceDecl>(d) {
        return cast<Declarations::InterfaceDecl>(d)->spec_kind
    }

    if isa<Declarations::EnumDecl>(d) {
        return cast<Declarations::EnumDecl>(d)->spec_kind
    }

    if isa<Declarations::TypeAliasDecl>(d) {
        return cast<Declarations::TypeAliasDecl>(d)->spec_kind
    }

    if isa<Declarations::FunctionDecl>(d) {
        return cast<Declarations::FunctionDecl>(d)->spec_kind
    }

    if isa<Declarations::ExtensionDecl>(d) {
        return cast<Declarations::ExtensionDecl>(d)->spec_kind
    }

    return Declarations::SpecKind::None
}

pub fn decl_set_spec_kind(d: unsafe *Decl, k: Declarations::SpecKind) {
    if d == &null {
        return
    }

    if isa<Declarations::ClassDecl>(d) {
        cast<Declarations::ClassDecl>(d)->spec_kind = k
        return
    }

    if isa<Declarations::StructDecl>(d) {
        cast<Declarations::StructDecl>(d)->spec_kind = k
        return
    }

    if isa<Declarations::UnionDecl>(d) {
        cast<Declarations::UnionDecl>(d)->spec_kind = k
        return
    }

    if isa<Declarations::InterfaceDecl>(d) {
        cast<Declarations::InterfaceDecl>(d)->spec_kind = k
        return
    }

    if isa<Declarations::EnumDecl>(d) {
        cast<Declarations::EnumDecl>(d)->spec_kind = k
        return
    }

    if isa<Declarations::TypeAliasDecl>(d) {
        cast<Declarations::TypeAliasDecl>(d)->spec_kind = k
        return
    }

    if isa<Declarations::FunctionDecl>(d) {
        cast<Declarations::FunctionDecl>(d)->spec_kind = k
        return
    }

    if isa<Declarations::ExtensionDecl>(d) {
        cast<Declarations::ExtensionDecl>(d)->spec_kind = k
        return
    }
}

pub fn decl_spec_args(d: unsafe *Decl) -> FrozenList<unsafe *Type> {
    if d == &null {
        return create_empty_frozen_list<unsafe *Type>()
    }

    if isa<Declarations::ClassDecl>(d) {
        return cast<Declarations::ClassDecl>(d)->spec_args
    }

    if isa<Declarations::StructDecl>(d) {
        return cast<Declarations::StructDecl>(d)->spec_args
    }

    if isa<Declarations::UnionDecl>(d) {
        return cast<Declarations::UnionDecl>(d)->spec_args
    }

    if isa<Declarations::InterfaceDecl>(d) {
        return cast<Declarations::InterfaceDecl>(d)->spec_args
    }

    if isa<Declarations::EnumDecl>(d) {
        return cast<Declarations::EnumDecl>(d)->spec_args
    }

    if isa<Declarations::TypeAliasDecl>(d) {
        return cast<Declarations::TypeAliasDecl>(d)->spec_args
    }

    if isa<Declarations::FunctionDecl>(d) {
        return cast<Declarations::FunctionDecl>(d)->spec_args
    }

    if isa<Declarations::ExtensionDecl>(d) {
        return cast<Declarations::ExtensionDecl>(d)->spec_args
    }

    return create_empty_frozen_list<unsafe *Type>()
}

/// `instantiated_from`, or null: the primary for a spec, the pattern for an
/// implicit instance, null for a plain decl.
pub fn decl_instantiated_from(d: unsafe *Decl) -> unsafe *Decl {
    if d == &null {
        return &null
    }

    if isa<Declarations::ClassDecl>(d) {
        return cast<Declarations::ClassDecl>(d)->instantiated_from
    }

    if isa<Declarations::StructDecl>(d) {
        return cast<Declarations::StructDecl>(d)->instantiated_from
    }

    if isa<Declarations::UnionDecl>(d) {
        return cast<Declarations::UnionDecl>(d)->instantiated_from
    }

    if isa<Declarations::InterfaceDecl>(d) {
        return cast<Declarations::InterfaceDecl>(d)->instantiated_from
    }

    if isa<Declarations::EnumDecl>(d) {
        return cast<Declarations::EnumDecl>(d)->instantiated_from
    }

    if isa<Declarations::TypeAliasDecl>(d) {
        return cast<Declarations::TypeAliasDecl>(d)->instantiated_from
    }

    if isa<Declarations::FunctionDecl>(d) {
        return cast<Declarations::FunctionDecl>(d)->instantiated_from
    }

    if isa<Declarations::ExtensionDecl>(d) {
        return cast<Declarations::ExtensionDecl>(d)->instantiated_from
    }

    return &null
}

pub fn decl_set_instantiated_from(d: unsafe *Decl, p: unsafe *Decl) {
    if d == &null {
        return
    }

    if isa<Declarations::ClassDecl>(d) {
        cast<Declarations::ClassDecl>(d)->instantiated_from = p
        return
    }

    if isa<Declarations::StructDecl>(d) {
        cast<Declarations::StructDecl>(d)->instantiated_from = p
        return
    }

    if isa<Declarations::UnionDecl>(d) {
        cast<Declarations::UnionDecl>(d)->instantiated_from = p
        return
    }

    if isa<Declarations::InterfaceDecl>(d) {
        cast<Declarations::InterfaceDecl>(d)->instantiated_from = p
        return
    }

    if isa<Declarations::EnumDecl>(d) {
        cast<Declarations::EnumDecl>(d)->instantiated_from = p
        return
    }

    if isa<Declarations::TypeAliasDecl>(d) {
        cast<Declarations::TypeAliasDecl>(d)->instantiated_from = p
        return
    }

    if isa<Declarations::FunctionDecl>(d) {
        cast<Declarations::FunctionDecl>(d)->instantiated_from = p
        return
    }

    if isa<Declarations::ExtensionDecl>(d) {
        cast<Declarations::ExtensionDecl>(d)->instantiated_from = p
        return
    }
}

/// The pattern a decl is an instance of, or the decl itself.
pub fn decl_pattern(d: unsafe *Decl) -> unsafe *Decl {
    var unsafe *p = decl_instantiated_from(d)
    return if (p != &null) => (p) else => d
}

pub fn decl_is_instance(d: unsafe *Decl) -> bool {
    return decl_spec_kind(d) == Declarations::SpecKind::Instantiated
}

/// The ForeignFill byte of \p d, or null for a kind that carries none a
/// fill could set (only the record kinds and Interface/Enum do).
fn _foreign_fill_slot(d: unsafe *Decl) -> unsafe *u8 {
    if d == &null {
        return &null
    }

    if isa<Declarations::ClassDecl>(d) {
        return unsafe &cast<Declarations::ClassDecl>(d)->foreign_fill
    }

    if isa<Declarations::StructDecl>(d) {
        return unsafe &cast<Declarations::StructDecl>(d)->foreign_fill
    }

    if isa<Declarations::UnionDecl>(d) {
        return unsafe &cast<Declarations::UnionDecl>(d)->foreign_fill
    }

    if isa<Declarations::InterfaceDecl>(d) {
        return unsafe &cast<Declarations::InterfaceDecl>(d)->foreign_fill
    }

    if isa<Declarations::EnumDecl>(d) {
        return unsafe &cast<Declarations::EnumDecl>(d)->foreign_fill
    }

    return &null
}

/// Where clang's fill of \p d stands. An ACQUIRE load: it is read on any
/// Sema thread with no lock while ForeignInstantiate::fill may be
/// publishing it, and a reader that sees Filled goes on to read the tables
/// the fill wrote before its release store (ForeignFill's header).
pub fn decl_foreign_fill(d: unsafe *Decl) -> ForeignFill {
    var unsafe *s = _foreign_fill_slot(d)
    if s == &null {
        return ForeignFill::Shell
    }

    return (__builtin_atomic_load(unsafe (s as *const u8), MemoryOrder::Acquire) as ForeignFill)
}

/// clang has filled \p d (ForeignFill::Filled): its own tables are the
/// answer, not its pattern's.
pub fn decl_instantiated(d: unsafe *Decl) -> bool {
    return decl_foreign_fill(d) == ForeignFill::Filled
}

/// True for a kind ForeignInstantiate cannot fill at all, so a caller
/// asking "did the fill fail" gets "yes, and do not try" for free.
pub fn decl_fill_failed(d: unsafe *Decl) -> bool {
    if d == &null {
        return true
    }

    if !isa<Declarations::ClassDecl>(d)
        && !isa<Declarations::StructDecl>(d)
        && !isa<Declarations::UnionDecl>(d) {
        return true
    }

    return decl_foreign_fill(d) == ForeignFill::FailedSticky
}

/// The one writer of a ForeignFill: \p d leaves Shell for \p f, Filled or
/// FailedSticky, both terminal. ForeignInstantiate calls it holding its
/// `_mu`, which serialises every writer, so a plain store would do for
/// them; it is a RELEASE store for the unlocked readers, and the last
/// write of the fill. Leaving a terminal state is a fill bug (two fills
/// of one shell, or a verdict over a filled one): an ICE in a debug build.
pub fn decl_publish_fill(d: unsafe *Decl, f: ForeignFill) {
    var unsafe *s = _foreign_fill_slot(d)
    if s == &null {
        return
    }

    eval if defined!(DEBUG) {
        var old = (__builtin_atomic_load(unsafe (s as *const u8), MemoryOrder::Relaxed) as ForeignFill)
        if old != ForeignFill::Shell || f == ForeignFill::Shell {
            kairo::std::ice_fail("decl_publish_fill: a ForeignFill leaves Shell once, for Filled or FailedSticky")
        }
    }

    __builtin_atomic_store(unsafe (s as *u8), f as u8, MemoryOrder::Release)
}

/// # FFILinkage
///
/// Function, Variable, Struct, Class, Interface, Enum, Union, TypeAlias,
/// Import.

pub fn decl_is_imported(d: unsafe *Decl) -> bool {
    if d == &null {
        return false
    }

    if isa<Declarations::ClassDecl>(d) {
        return cast<Declarations::ClassDecl>(d)->is_imported()
    }

    if isa<Declarations::StructDecl>(d) {
        return cast<Declarations::StructDecl>(d)->is_imported()
    }

    if isa<Declarations::UnionDecl>(d) {
        return cast<Declarations::UnionDecl>(d)->is_imported()
    }

    if isa<Declarations::InterfaceDecl>(d) {
        return cast<Declarations::InterfaceDecl>(d)->is_imported()
    }

    if isa<Declarations::EnumDecl>(d) {
        return cast<Declarations::EnumDecl>(d)->is_imported()
    }

    if isa<Declarations::TypeAliasDecl>(d) {
        return cast<Declarations::TypeAliasDecl>(d)->is_imported()
    }

    if isa<Declarations::FunctionDecl>(d) {
        return cast<Declarations::FunctionDecl>(d)->is_imported()
    }

    if isa<Declarations::VariableDecl>(d) {
        return cast<Declarations::VariableDecl>(d)->is_imported()
    }

    return false
}

/// The record \p d is a member type of, or null: at namespace scope, in a
/// function, in an extension body (an extension opens no C++ class scope
/// a type could live in), or in an enum (its payload structs and layout
/// record ARE the enum's, laid out by EnumLayoutLowering, never member
/// types named through an instance).
pub fn decl_type_owner(d: unsafe *Decl) -> unsafe *Decl {
    if d == &null {
        return &null
    }

    var unsafe *lex = d->lexical_dc
    if lex != &null && lex->dc_kind == DeclContextKind::Extension {
        return &null
    }

    var unsafe *dc = d->semantic_dc
    if dc == &null || !dc->is_type_scope() {
        return &null
    }

    if dc->dc_kind == DeclContextKind::Extension || dc->dc_kind == DeclContextKind::Enum {
        return &null
    }

    return dc->owner_decl()
}

/// \p d is a record nested, at any depth, in a GENERIC record: its owners'
/// parameters are implicit in it (Type::TypeFlags::InGenericOwner).
pub fn decl_in_generic_owner(d: unsafe *Decl) -> bool {
    if d == &null
        || !(isa<Declarations::ClassDecl>(d)
            || isa<Declarations::StructDecl>(d)
            || isa<Declarations::UnionDecl>(d)
            || isa<Declarations::EnumDecl>(d)) {
        return false
    }

    // An imported template's member type is clang's: each instance's is its
    // own filled decl (TypeResolve::_foreign_instance_of), never a pattern
    // type seen through an instance.
    if decl_is_imported(d) {
        return false
    }

    var unsafe *o         = decl_type_owner(d)
    var        depth: u32 = 0
    while o != &null && depth < 64 {
        if decl_generic_params(o).size() > 0 {
            return true
        }

        o = decl_type_owner(o)
        depth += 1
    }

    return false
}

/// The clang decl behind an imported entity, as *void (this layer cannot
/// name clang). Null on a Kairo-authored decl and on kinds without the mixin.
pub fn decl_clang(d: unsafe *Decl) -> unsafe *void {
    if d == &null {
        return &null
    }

    if isa<Declarations::ClassDecl>(d) {
        return cast<Declarations::ClassDecl>(d)->clang_decl
    }

    if isa<Declarations::StructDecl>(d) {
        return cast<Declarations::StructDecl>(d)->clang_decl
    }

    if isa<Declarations::UnionDecl>(d) {
        return cast<Declarations::UnionDecl>(d)->clang_decl
    }

    if isa<Declarations::InterfaceDecl>(d) {
        return cast<Declarations::InterfaceDecl>(d)->clang_decl
    }

    if isa<Declarations::EnumDecl>(d) {
        return cast<Declarations::EnumDecl>(d)->clang_decl
    }

    if isa<Declarations::TypeAliasDecl>(d) {
        return cast<Declarations::TypeAliasDecl>(d)->clang_decl
    }

    if isa<Declarations::FunctionDecl>(d) {
        return cast<Declarations::FunctionDecl>(d)->clang_decl
    }

    if isa<Declarations::VariableDecl>(d) {
        return cast<Declarations::VariableDecl>(d)->clang_decl
    }

    return &null
}

pub fn decl_origin_set(d: unsafe *Decl) -> unsafe *void {
    if d == &null {
        return &null
    }

    if isa<Declarations::ClassDecl>(d) {
        return cast<Declarations::ClassDecl>(d)->origin_set
    }

    if isa<Declarations::StructDecl>(d) {
        return cast<Declarations::StructDecl>(d)->origin_set
    }

    if isa<Declarations::UnionDecl>(d) {
        return cast<Declarations::UnionDecl>(d)->origin_set
    }

    if isa<Declarations::InterfaceDecl>(d) {
        return cast<Declarations::InterfaceDecl>(d)->origin_set
    }

    if isa<Declarations::EnumDecl>(d) {
        return cast<Declarations::EnumDecl>(d)->origin_set
    }

    if isa<Declarations::TypeAliasDecl>(d) {
        return cast<Declarations::TypeAliasDecl>(d)->origin_set
    }

    if isa<Declarations::FunctionDecl>(d) {
        return cast<Declarations::FunctionDecl>(d)->origin_set
    }

    if isa<Declarations::VariableDecl>(d) {
        return cast<Declarations::VariableDecl>(d)->origin_set
    }

    return &null
}

pub fn decl_origin_fid(d: unsafe *Decl) -> u32 {
    if d == &null {
        return 0
    }

    if isa<Declarations::ClassDecl>(d) {
        return cast<Declarations::ClassDecl>(d)->origin_fid
    }

    if isa<Declarations::StructDecl>(d) {
        return cast<Declarations::StructDecl>(d)->origin_fid
    }

    if isa<Declarations::UnionDecl>(d) {
        return cast<Declarations::UnionDecl>(d)->origin_fid
    }

    if isa<Declarations::InterfaceDecl>(d) {
        return cast<Declarations::InterfaceDecl>(d)->origin_fid
    }

    if isa<Declarations::EnumDecl>(d) {
        return cast<Declarations::EnumDecl>(d)->origin_fid
    }

    if isa<Declarations::TypeAliasDecl>(d) {
        return cast<Declarations::TypeAliasDecl>(d)->origin_fid
    }

    if isa<Declarations::FunctionDecl>(d) {
        return cast<Declarations::FunctionDecl>(d)->origin_fid
    }

    if isa<Declarations::VariableDecl>(d) {
        return cast<Declarations::VariableDecl>(d)->origin_fid
    }

    return 0
}

pub fn decl_cxx_spelling(d: unsafe *Decl) -> string {
    if d == &null {
        return ""
    }

    if isa<Declarations::ClassDecl>(d) {
        return cast<Declarations::ClassDecl>(d)->cxx_spelling
    }

    if isa<Declarations::StructDecl>(d) {
        return cast<Declarations::StructDecl>(d)->cxx_spelling
    }

    if isa<Declarations::UnionDecl>(d) {
        return cast<Declarations::UnionDecl>(d)->cxx_spelling
    }

    if isa<Declarations::InterfaceDecl>(d) {
        return cast<Declarations::InterfaceDecl>(d)->cxx_spelling
    }

    if isa<Declarations::EnumDecl>(d) {
        return cast<Declarations::EnumDecl>(d)->cxx_spelling
    }

    if isa<Declarations::TypeAliasDecl>(d) {
        return cast<Declarations::TypeAliasDecl>(d)->cxx_spelling
    }

    if isa<Declarations::FunctionDecl>(d) {
        return cast<Declarations::FunctionDecl>(d)->cxx_spelling
    }

    if isa<Declarations::VariableDecl>(d) {
        return cast<Declarations::VariableDecl>(d)->cxx_spelling
    }

    return ""
}

/// The elaborated keyword of an imported tag whose name is hidden by an
/// ordinary name (FFILinkage::ffi_tag_keyword), or "".
pub fn decl_ffi_tag_keyword(d: unsafe *Decl) -> string {
    if d == &null {
        return ""
    }

    if isa<Declarations::ClassDecl>(d) {
        return cast<Declarations::ClassDecl>(d)->ffi_tag_keyword
    }

    if isa<Declarations::StructDecl>(d) {
        return cast<Declarations::StructDecl>(d)->ffi_tag_keyword
    }

    if isa<Declarations::UnionDecl>(d) {
        return cast<Declarations::UnionDecl>(d)->ffi_tag_keyword
    }

    if isa<Declarations::EnumDecl>(d) {
        return cast<Declarations::EnumDecl>(d)->ffi_tag_keyword
    }

    return ""
}

pub fn decl_set_ffi_tag_keyword(d: unsafe *Decl, const kw: string) {
    if d == &null {
        return
    }

    if isa<Declarations::ClassDecl>(d) {
        cast<Declarations::ClassDecl>(d)->ffi_tag_keyword = kw
        return
    }

    if isa<Declarations::StructDecl>(d) {
        cast<Declarations::StructDecl>(d)->ffi_tag_keyword = kw
        return
    }

    if isa<Declarations::UnionDecl>(d) {
        cast<Declarations::UnionDecl>(d)->ffi_tag_keyword = kw
        return
    }

    if isa<Declarations::EnumDecl>(d) {
        cast<Declarations::EnumDecl>(d)->ffi_tag_keyword = kw
        return
    }
}

/// The header tag a bodiless `ffi` record declaration names
/// (FFILinkage::ffi_tag_target), or null.
pub fn decl_ffi_tag_target(d: unsafe *Decl) -> unsafe *Decl {
    if d == &null {
        return &null
    }

    if isa<Declarations::ClassDecl>(d) {
        return unsafe (cast<Declarations::ClassDecl>(d)->ffi_tag_target as unsafe *Decl)
    }

    if isa<Declarations::StructDecl>(d) {
        return unsafe (cast<Declarations::StructDecl>(d)->ffi_tag_target as unsafe *Decl)
    }

    if isa<Declarations::UnionDecl>(d) {
        return unsafe (cast<Declarations::UnionDecl>(d)->ffi_tag_target as unsafe *Decl)
    }

    return &null
}

pub fn decl_set_ffi_tag_target(d: unsafe *Decl, t: unsafe *Decl) {
    if d == &null {
        return
    }

    var unsafe *v = unsafe (t as unsafe *void)
    if isa<Declarations::ClassDecl>(d) {
        cast<Declarations::ClassDecl>(d)->ffi_tag_target = v
        return
    }

    if isa<Declarations::StructDecl>(d) {
        cast<Declarations::StructDecl>(d)->ffi_tag_target = v
        return
    }

    if isa<Declarations::UnionDecl>(d) {
        cast<Declarations::UnionDecl>(d)->ffi_tag_target = v
        return
    }
}

/// # C/C++ name hiding
///
/// C and C++ keep tags (struct/class/union/enum names) apart from ordinary
/// names (variables, functions, typedefs, enumerators): `struct timezone`
/// and `extern long timezone` coexist, and the ORDINARY name is what a plain
/// `timezone` means ([basic.scope.hiding], [class.name]). Kairo has one
/// namespace per scope, so every place that sees both under one key applies
/// that rule, and only between IMPORTED decls -- a Kairo decl never hides
/// or is hidden this way.

/// Imported from a header: the FFILinkage kinds, plus an enumerator of an
/// imported enum (EnumVariantDecl carries no mixin of its own).
pub fn decl_is_ffi(d: unsafe *Decl) -> bool {
    if d == &null {
        return false
    }

    if isa<Declarations::EnumVariantDecl>(d) {
        if d->semantic_dc == &null {
            return false
        }

        var unsafe *dc = d->semantic_dc
        return decl_is_imported(dc->owner_decl())
    }

    return decl_is_imported(d)
}

/// An imported C/C++ tag: clang's IDNS_Tag.
pub fn decl_is_ffi_tag(d: unsafe *Decl) -> bool {
    if !decl_is_imported(d) {
        return false
    }

    return isa<Declarations::StructDecl>(d)
        || isa<Declarations::ClassDecl>(d)
        || isa<Declarations::UnionDecl>(d)
        || isa<Declarations::EnumDecl>(d)
}

/// An imported typedef that names exactly \p tag: `typedef struct X X`
/// is one entity under one name, not a typedef hiding its own tag.
pub fn decl_is_ffi_typedef_of(d: unsafe *Decl, tag: unsafe *Decl) -> bool {
    if d == &null || tag == &null {
        return false
    }

    if !isa<Declarations::TypeAliasDecl>(d) || !decl_is_imported(d) {
        return false
    }

    var unsafe *t = cast<Declarations::TypeAliasDecl>(d)->aliased
    if t == &null || !isa<RecordType>(t) {
        return false
    }

    return cast<RecordType>(t)->decl == tag
}

/// An imported decl in the ORDINARY namespace that hides \p tag: anything
/// imported that is not itself a tag and not a typedef of that very tag.
pub fn decl_ffi_hides_tag(d: unsafe *Decl, tag: unsafe *Decl) -> bool {
    if !decl_is_ffi(d) || decl_is_ffi_tag(d) {
        return false
    }

    if isa<Declarations::ModuleDecl>(d) { // a namespace is not an ordinary name.
        return false
    }

    if decl_is_ffi_typedef_of(d, tag) {
        return false
    }

    // Hiding is between declarations of ONE scope. Two headers' global
    // scopes are two Kairo tables but one C++ scope, so the scope is read
    // off the qualified C++ spelling: `::timezone` and `::timezone` share
    // one, `::tz` and an inline namespace's `::a::tz` do not -- C++ calls
    // that pair ambiguous, and so do we.
    var ds = decl_cxx_spelling(d)
    var ts = decl_cxx_spelling(tag)
    if ds.size() > 0 && ts.size() > 0 && ds != ts {
        return false
    }

    return true
}

/// Apply C++'s tag hiding to a candidate set, in place, keeping order:
/// a `typedef struct X X` collapses into its tag, and an imported tag
/// beside an imported ordinary name drops out. Returns true when anything
/// was removed. Kairo decls are never touched.
pub fn ffi_hide_tags(cands: unsafe *cxx::std::vector<unsafe *Decl>) -> bool {
    var n = cands->size()
    if n < 2 {
        return false
    }

    // Every drop needs an imported TAG on one side of the pair (the dropped
    // one, or the one it is a typedef of), so classify once and pair only
    // against tags. A `cxx::std::` step has hundreds of candidates (libc++
    // reopens std per header) and no tag: the all-pairs scan was the top of
    // the serial Sema profile. Same keep set, same order.
    var tags   = cxx::std::vector<usize>()
    var is_tag = cxx::std::vector<u8>()
    for var i: usize = 0; i < n; ++i {
        var t = decl_is_ffi_tag((*cands)[i])
        is_tag.push_back(t as u8)
        if t {
            tags.push_back(i)
        }
    }

    if tags.size() == 0 {
        return false
    }

    var keep = cxx::std::vector<unsafe *Decl>()
    for var i: usize = 0; i < n; ++i {
        var unsafe *d   = (*cands)[i]
        var        drop = false
        if is_tag[i] != 0 {
            for var j: usize = 0; j < n && !drop; ++j {
                if i == j {
                    continue
                }

                var unsafe *o = (*cands)[j]
                if o == d {
                    continue
                }

                if decl_ffi_hides_tag(o, d) {
                    drop = true
                } else if is_tag[j] != 0 && decl_is_ffi_typedef_of(d, o) {
                    drop = true
                }
            }
        } else {
            for var k: usize = 0; k < tags.size() && !drop; ++k {
                var j = tags[k]
                if i == j {
                    continue
                }

                var unsafe *o = (*cands)[j]
                if o == d {
                    continue
                }

                if decl_is_ffi_typedef_of(d, o) {
                    drop = true
                }
            }
        }

        if !drop {
            keep.push_back(d)
        }
    }

    if keep.size() == n {
        return false
    }

    *cands = keep
    return true
}

/// The clang builtin a decl stands for, or 0.
pub fn decl_builtin_id(d: unsafe *Decl) -> u32 {
    if d == &null || !isa<Declarations::FunctionDecl>(d) {
        return 0
    }

    return cast<Declarations::FunctionDecl>(d)->ffi_builtin_id
}

pub fn decl_set_imported(d:         unsafe *Decl,
                         cd:        unsafe *void,
                         const usr: string,
                         const sp:  string,
                         hs:        unsafe *void,
                         fid:       u32) {
    if d == &null {
        return
    }

    if isa<Declarations::ClassDecl>(d) {
        cast<Declarations::ClassDecl>(d)->set_imported(cd, usr, sp, hs, fid)
        return
    }

    if isa<Declarations::StructDecl>(d) {
        cast<Declarations::StructDecl>(d)->set_imported(cd, usr, sp, hs, fid)
        return
    }

    if isa<Declarations::UnionDecl>(d) {
        cast<Declarations::UnionDecl>(d)->set_imported(cd, usr, sp, hs, fid)
        return
    }

    if isa<Declarations::InterfaceDecl>(d) {
        cast<Declarations::InterfaceDecl>(d)->set_imported(cd, usr, sp, hs, fid)
        return
    }

    if isa<Declarations::EnumDecl>(d) {
        cast<Declarations::EnumDecl>(d)->set_imported(cd, usr, sp, hs, fid)
        return
    }

    if isa<Declarations::TypeAliasDecl>(d) {
        cast<Declarations::TypeAliasDecl>(d)->set_imported(cd, usr, sp, hs, fid)
        return
    }

    if isa<Declarations::FunctionDecl>(d) {
        cast<Declarations::FunctionDecl>(d)->set_imported(cd, usr, sp, hs, fid)
        return
    }

    if isa<Declarations::VariableDecl>(d) {
        cast<Declarations::VariableDecl>(d)->set_imported(cd, usr, sp, hs, fid)
        return
    }
}

/// # Names and bases

/// The name token of a named decl. `Token{}` (kind TkUnknown) for the
/// unnamed kinds; callers test the kind, never the imm.
pub fn decl_name_tok(d: unsafe *Decl) -> Token {
    if d == &null {
        return Token()
    }

    if isa<Declarations::ClassDecl>(d) {
        return cast<Declarations::ClassDecl>(d)->name
    }

    if isa<Declarations::StructDecl>(d) {
        return cast<Declarations::StructDecl>(d)->name
    }

    if isa<Declarations::UnionDecl>(d) {
        return cast<Declarations::UnionDecl>(d)->name
    }

    if isa<Declarations::InterfaceDecl>(d) {
        return cast<Declarations::InterfaceDecl>(d)->name
    }

    if isa<Declarations::EnumDecl>(d) {
        return cast<Declarations::EnumDecl>(d)->name
    }

    if isa<Declarations::TypeAliasDecl>(d) {
        return cast<Declarations::TypeAliasDecl>(d)->name
    }

    if isa<Declarations::ModuleDecl>(d) {
        return cast<Declarations::ModuleDecl>(d)->name
    }

    if isa<Declarations::FunctionDecl>(d) {
        return cast<Declarations::FunctionDecl>(d)->name
    }

    if isa<Declarations::ParamDecl>(d) {
        return cast<Declarations::ParamDecl>(d)->name
    }

    if isa<Declarations::VariableDecl>(d) {
        return cast<Declarations::VariableDecl>(d)->name
    }

    if isa<Declarations::FieldDecl>(d) {
        return cast<Declarations::FieldDecl>(d)->name
    }

    if isa<Declarations::EnumVariantDecl>(d) {
        return cast<Declarations::EnumVariantDecl>(d)->name
    }

    if isa<Declarations::GenericParamDecl>(d) {
        return cast<Declarations::GenericParamDecl>(d)->name
    }

    return Token()
}

/// The parameter carrying the `...`, or null when there is none. This is the
/// one walk that answers WHICH parameter is the pack; `is_variadic` is exactly
/// `decl_pack_param(d) != null` and says only that one exists.
pub fn decl_pack_param(d: unsafe *Decl) -> unsafe *Declarations::ParamDecl {
    if d == &null {
        return &null
    }

    if !isa<Declarations::FunctionDecl>(d) {
        return &null
    }

    var unsafe *f = cast<Declarations::FunctionDecl>(d)
    for var i: usize = 0; i < f->params.size(); ++i {
        var unsafe *p = f->params[i]
        if p != &null && p->is_pack {
            return p
        }
    }

    return &null
}

/// The type pack \p p expands (param_is_type_pack, below), through the one
/// C++ reference an imported pattern may add; null when it is not one.
pub fn param_type_pack_param(p: unsafe *Declarations::ParamDecl) -> unsafe *GenericParamType {
    if p == &null || !p->is_pack || p->type_ == &null || p->type_->canonical == &null {
        return &null
    }

    var unsafe *t = canon_unqual(p->type_->canonical)
    if isa<CXXLValueRefType>(t) {
        t = canon_unqual(cast<CXXLValueRefType>(t)->referee)
    } else if isa<CXXRValueRefType>(t) {
        t = canon_unqual(cast<CXXRValueRefType>(t)->referee)
    }

    var unsafe *g = dyn_cast<GenericParamType>(t)
    if g == &null || !g->is_pack {
        return &null
    }

    return g
}

/// `...xs: T` with T a TYPE pack (`fn <...T> f(...xs: T)`): a C++
/// parameter pack, `T... xs`, one argument per element. A pack over one
/// type (`...xs: i32`, or a non-pack `U`) is a `Slice<E>` instead
/// (ParamDecl::pack_type); the two never mix, so every reader that builds,
/// spells or passes a pack asks this first.
///
/// An imported C++ pack's element is its expansion's PATTERN, and the
/// pattern can be a reference to the pack (`Args&&... args`, `const Ts&...`):
/// still a C++ parameter pack, one argument per element. Only an import has
/// such a parameter; Kairo spells no C++ reference.
pub fn param_is_type_pack(p: unsafe *Declarations::ParamDecl) -> bool {
    return param_type_pack_param(p) != &null
}

/// The pack-expanded variant of ADT \p en (`Err { e: E }...`), or null.
pub fn adt_pack_variant(en: unsafe *Declarations::EnumDecl) -> unsafe *Declarations::EnumVariantDecl {
    if en == &null {
        return &null
    }

    for var i: usize = 0; i < en->variants.size(); ++i {
        var unsafe *v = en->variants[i]
        if v != &null && v->is_pack_expansion {
            return v
        }
    }

    return &null
}

/// The position in \p en's generic parameters of the type pack its
/// pack-expanded variant expands, or usize(-1) when it has none. An
/// instance's arguments from here on are the pack's elements
/// (InstanceEntry::args keeps packs flat, at the tail).
pub fn adt_pack_param(en: unsafe *Declarations::EnumDecl) -> usize {
    if adt_pack_variant(en) == &null {
        return usize::MAX
    }

    for var i: usize = 0; i < en->generic_params.size(); ++i {
        var unsafe *gp = en->generic_params[i]
        if gp != &null && gp->is_pack {
            return i
        }
    }

    return usize::MAX
}

/// The position of variant \p v in \p en, or usize(-1).
pub fn adt_variant_pos(en: unsafe *Declarations::EnumDecl,
                       v:  unsafe *Declarations::EnumVariantDecl) -> usize {
    if en == &null || v == &null {
        return usize::MAX
    }

    for var i: usize = 0; i < en->variants.size(); ++i {
        if en->variants[i] == v {
            return i
        }
    }

    return usize::MAX
}

/// An ADT's EXPANDED index: its constructors in tag order, which every
/// pattern and layout question indexes by. An ordinary variant's is its
/// position; element k of the pack-expanded variant (always the last, at
/// position p) is p + k, so for an enum without one the two are the same.
/// The variant expanded index \p i belongs to, or null past the last.
pub fn adt_variant_at(en: unsafe *Declarations::EnumDecl,
                      i:  usize) -> unsafe *Declarations::EnumVariantDecl {
    if en == &null {
        return &null
    }

    var n = en->variants.size()
    if n == 0 {
        return &null
    }

    if i < n {
        var unsafe *v = en->variants[i]
        return v
    }

    var unsafe *last = en->variants[n - 1]
    if last != &null && last->is_pack_expansion {
        return last
    }

    return &null
}

/// The pack element expanded index \p i stands for, or -1 for an ordinary
/// variant (adt_variant_at).
pub fn adt_expansion_at(en: unsafe *Declarations::EnumDecl, i: usize) -> i32 {
    var unsafe *v = adt_variant_at(en, i)
    if v == &null || !v->is_pack_expansion {
        return -1
    }

    return (i - (en->variants.size() - 1)) as i32
}

/// Where \p d's arguments become a set (decl_dedup_pack_args): the pack
/// position of an enum with a pack-expanded variant, \p d being it or an
/// instance of it; usize(-1) for every other decl.
pub fn decl_pack_set_at(d: unsafe *Decl) -> usize {
    if d == &null {
        return usize::MAX
    }

    var unsafe *p = decl_instantiated_from(d)
    if p == &null {
        p = d
    }

    var unsafe *en = dyn_cast<Declarations::EnumDecl>(p)
    if en == &null || !en->is_adt {
        return usize::MAX
    }

    return adt_pack_param(en)
}

/// How a lang item orders its expanded pack, a set (decl_dedup_pack_args):
/// the Panic item sorts by type id (Sema's PanicTypeIds), which the AST
/// layer cannot compute, so the build's CanonicalTypeStore and
/// InstantiationRegistry hold one, installed by the driver. The default
/// keeps first-occurrence order. Must be stateless and lock-free: it runs
/// inside type formation.
pub class PackSetOrder {
    fn PackSetOrder(self) { }
    virtual fn order(self, d: unsafe *Decl, args: unsafe *cxx::std::vector<unsafe *Type>) { }
}

/// `R<i32, string, string>` IS `R<i32, string>` when R's pack is expanded
/// into variants (Compiler/Spec/Panic.md#the-result-type: equal types are one variant). The pack is a
/// set, kept in first-occurrence order, so the dedup happens where a type is
/// formed (CanonicalTypes::record, InstantiationRegistry) and every reader
/// after it -- the instance's args, the expansions' tags, C++'s template
/// arguments -- sees one list. \p d is the primary or an instance of it.
pub fn decl_dedup_pack_args(d:    unsafe *Decl,
                            args: unsafe *cxx::std::vector<unsafe *Type>,
                            ord:  unsafe *PackSetOrder = &null) {
    if d == &null || args == &null {
        return
    }

    var at = decl_pack_set_at(d)
    if at == usize::MAX || args->size() <= at + 1 {
        return
    }

    var out = cxx::std::vector<unsafe *Type>()
    for var i: usize = 0; i < args->size(); ++i {
        var unsafe *a  = (*args)[i]
        var        dup = false
        if i > at {
            for var j: usize = at; j < out.size(); ++j {
                if out[j] == a {
                    dup = true
                    break
                }
            }
        }

        if !dup {
            out.push_back(a)
        }
    }

    if out.size() != args->size() {
        args->clear()
        for var i: usize = 0; i < out.size(); ++i {
            args->push_back(out[i])
        }
    }

    // A lang item may also fix the set's ORDER (PackSetOrder: the Panic
    // item sorts by type id, Compiler/Spec/Panic.md#canonical-sets), once the duplicates are gone.
    if ord != &null {
        ord->order(d, args)
    }
}

/// `derives_list`: the kinds with nominal bases.
pub fn decl_bases(d: unsafe *Decl) -> FrozenList<Declarations::InheritEdge> {
    if d == &null {
        return create_empty_frozen_list<Declarations::InheritEdge>()
    }

    if isa<Declarations::ClassDecl>(d) {
        return cast<Declarations::ClassDecl>(d)->derives_list
    }

    if isa<Declarations::InterfaceDecl>(d) {
        return cast<Declarations::InterfaceDecl>(d)->derives_list
    }

    return create_empty_frozen_list<Declarations::InheritEdge>()
}

/// # Extension membership

/// The extension \p d was written in, or null. Lexical: an extension
/// member's C++ home and template parameters are its extension's.
pub fn decl_extension_of(d: unsafe *Decl) -> unsafe *Declarations::ExtensionDecl {
    if d == &null || !isa<Declarations::FunctionDecl>(d) {
        return &null
    }

    var unsafe *lex = d->lexical_dc
    if lex == &null || lex->dc_kind != DeclContextKind::Extension {
        return &null
    }

    return dyn_cast<Declarations::ExtensionDecl>(lex->dc_owner)
}

/// # Interface requirements

/// \p m is a CONSTRUCTOR requirement: a method of an interface named after
/// that interface (`interface Defaultable { fn Defaultable(self) }`). A
/// conformer meets it with its own constructor, named after ITSELF, so a
/// lookup by the requirement's name can never find the witness; Sema and
/// Codegen both branch on this. The owner is the semantic one, the
/// interface that wrote it, so a requirement composed into a derived
/// interface is still one. Names are interned per file and a method shares
/// its interface's file, so the imms compare.
pub fn decl_is_ctor_requirement(m: unsafe *Declarations::FunctionDecl) -> bool {
    if m == &null || m->is_operator || m->semantic_dc == &null {
        return false
    }

    var unsafe *owner = (m->semantic_dc)->owner_decl()
    if owner == &null || !isa<Declarations::InterfaceDecl>(owner) {
        return false
    }

    var a = decl_name_tok(m)
    var b = decl_name_tok(owner)
    if !a.has_imm() || !b.has_imm() {
        return false
    }

    return a.imm == b.imm
}

/// \p d is a member of an interface: a requirement. As a conformance row's
/// WITNESS it means the conformer meets the requirement with no decl of its
/// own -- a builtin's or an imported record's native `==`
/// (ConformanceChecking::_native_implementation), a lifecycle slot -- so
/// EmitWitness spells the native operation instead of a forwarding call.
pub fn decl_is_requirement(d: unsafe *Decl) -> bool {
    if d == &null || d->semantic_dc == &null {
        return false
    }

    var unsafe *owner = (d->semantic_dc)->owner_decl()
    return owner != &null && isa<Declarations::InterfaceDecl>(owner)
}

/// # Forward declarations

/// A Kairo class, struct or union no link of whose chain has a body: it was
/// only ever forward-declared (`struct Node`), so its size and members are
/// unknown and it can be used through a pointer only. False for a header's
/// record (clang owns completeness) and for an `ffi` forward declaration
/// that names a header tag, which IS that tag.
pub fn decl_only_forward(d: unsafe *Decl) -> bool {
    if d == &null {
        return false
    }

    var unsafe *p = decl_pattern(d)
    if decl_is_imported(p) || decl_ffi_tag_target(p) != &null {
        return false
    }

    if isa<Declarations::ClassDecl>(p) {
        return !cast<Declarations::ClassDecl>(p)->has_definition()
    }

    if isa<Declarations::StructDecl>(p) {
        return !cast<Declarations::StructDecl>(p)->has_definition()
    }

    if isa<Declarations::UnionDecl>(p) {
        return !cast<Declarations::UnionDecl>(p)->has_definition()
    }

    return false
}

/// The C++ literal EvalIfLateFolding pinned an `eval` constant to
/// (VariableDecl / FieldDecl::fold_pin), or "" when it pinned none.
pub fn decl_fold_pin(d: unsafe *Decl) -> string {
    if d == &null {
        return ""
    }

    var k:   u8  = (0)
    var neg      = false
    var mag: u64 = (0)
    if isa<Declarations::VariableDecl>(d) {
        var unsafe *v = cast<Declarations::VariableDecl>(d)
        k   = v->fold_pin
        neg = v->fold_pin_neg
        mag = v->fold_pin_mag
    } else if isa<Declarations::FieldDecl>(d) {
        var unsafe *f = cast<Declarations::FieldDecl>(d)
        k   = f->fold_pin
        neg = f->fold_pin_neg
        mag = f->fold_pin_mag
    }

    if k == (1 as u8) {
        return "false"
    }

    if k == (2 as u8) {
        return "true"
    }

    if k == (3 as u8) {
        if neg {
            return f"-{mag}"
        }

        return f"{mag}"
    }

    return ""
}
