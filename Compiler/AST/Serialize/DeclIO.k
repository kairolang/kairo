/// --- The Kairo Project ----------------------- AST/Serialize/DeclIO.k --- ///
///
///   The Decl family: one `io_` function per declaration class, the mixins
///   declarations are built from (DeclContext, Redeclarable, TemplateParams,
///   FFILinkage), and the entry points the archive's hooks call (decl_alloc,
///   decl_io, decl_dc).
///
///   Each `io_` function names every field of its class, in one of two
///   ways. A field the preprocessor or the parser writes goes through an
///   archive primitive and is stored. A field a later stage writes (the
///   node files say which pass: "One writer: ...") is listed in the
///   function's DEBUG block, where the writer checks it is still unset.
///   Scripts/check_ast_serializer.py holds this file to that: a field
///   named in neither place fails it.
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

import AST::ASTSupport::FrozenList
import AST::Context::DeclContext::{
    DeclContext,
    DeclContextKind,
}
import AST::Kind::DeclKind::DeclKind
import AST::Mixin::Annotation::VisibilityKind
import AST::Mixin::FFILinkage::LinkageKind
import AST::Node::Base::{
    Decl,
    Expr,
    Stmt,
    Type,
}
import AST::Node::Declarations
import AST::Node::Statements::CompoundStmt
import AST::ParamMode::ParamMode
import AST::Serialize::Archive::ASTArchive
import AST::Serialize::NodeCommon::io_annotations
import Location::SourceRange::SourceRange
import Token::Token::Token
import Token::TokenKind::TokenKind

//  allocation

fn <T: type> new_decl(ar: unsafe *ASTArchive) -> unsafe *Decl {
    var unsafe *n = ar->ctx->alloc<T>()
    n->init_annotations(unsafe &ar->ctx->ast_alloc)
    return unsafe (n as unsafe *Decl)
}

/// A scope declaration: its DeclContext is set up as its factory does, with
/// the node as its own owner. The parent is read with the node's fields.
fn <T: type> new_scope(ar: unsafe *ASTArchive, k: DeclContextKind) -> unsafe *Decl {
    var unsafe *n = ar->ctx->alloc<T>()
    n->init_annotations(unsafe &ar->ctx->ast_alloc)
    n->init_dc(k, ar->ctx, &null, unsafe (n as unsafe *Decl))
    return unsafe (n as unsafe *Decl)
}

/// A scope declaration that is also Redeclarable: alone in its ring, which
/// is all the parser ever builds (RedeclMerge and T link rings).
fn <T: type> new_redecl_scope(ar: unsafe *ASTArchive, k: DeclContextKind) -> unsafe *Decl {
    var unsafe *n = ar->ctx->alloc<T>()
    n->init_annotations(unsafe &ar->ctx->ast_alloc)
    n->init_dc(k, ar->ctx, &null, unsafe (n as unsafe *Decl))
    n->init_redecl()
    return unsafe (n as unsafe *Decl)
}

/// Reads a declaration's kind and allocates an object of its class.
pub fn decl_alloc(ar: unsafe *ASTArchive) -> unsafe *Decl {
    var kind = DeclKind::RecoveryDecl
    ar->en<DeclKind>(&kind)
    var cls = kind
    if kind == DeclKind::RecoveryDecl {
        ar->en<DeclKind>(&cls)
    }

    var d: unsafe *Decl = &null
    match cls {
        case DeclKind::FunctionDecl {
            d = new_redecl_scope<Declarations::FunctionDecl>(
                ar,
                DeclContextKind::Function,
            )
        } case DeclKind::VariableDecl {
            d = new_decl<Declarations::VariableDecl>(ar)
        } case DeclKind::FieldDecl {
            d = new_decl<Declarations::FieldDecl>(ar)
        } case DeclKind::ParamDecl {
            d = new_decl<Declarations::ParamDecl>(ar)
        } case DeclKind::GenericParamDecl {
            d = new_decl<Declarations::GenericParamDecl>(ar)
        } case DeclKind::StructDecl {
            d = new_redecl_scope<Declarations::StructDecl>(
                ar,
                DeclContextKind::Struct,
            )
        } case DeclKind::ClassDecl {
            d = new_redecl_scope<Declarations::ClassDecl>(
                ar,
                DeclContextKind::Class,
            )
        } case DeclKind::InterfaceDecl {
            d = new_redecl_scope<Declarations::InterfaceDecl>(
                ar,
                DeclContextKind::Interface,
            )
        } case DeclKind::ExtensionDecl {
            d = new_scope<Declarations::ExtensionDecl>(
                ar,
                DeclContextKind::Extension,
            )
        } case DeclKind::EnumDecl {
            d = new_redecl_scope<Declarations::EnumDecl>(
                ar,
                DeclContextKind::Enum,
            )
        } case DeclKind::EnumVariantDecl {
            d = new_decl<Declarations::EnumVariantDecl>(ar)
        } case DeclKind::UnionDecl {
            d = new_redecl_scope<Declarations::UnionDecl>(
                ar,
                DeclContextKind::Union,
            )
        } case DeclKind::TypeAliasDecl {
            d = new_decl<Declarations::TypeAliasDecl>(ar)
        } case DeclKind::ModuleDecl {
            d = new_redecl_scope<Declarations::ModuleDecl>(
                ar,
                DeclContextKind::Module,
            )
        } case DeclKind::ImportDecl {
            // PP-stage nodes live in pp_alloc (ImportDecl::create says why);
            // their factories are the one way to put them there.
            d = unsafe (Declarations::ImportDecl::create(
                ar->ctx,
                SourceRange::invalid(),
                Declarations::ImportKind::Native,
            ) as unsafe *Decl)
        } case DeclKind::VisibilityGroupDecl {
            d = new_decl<Declarations::VisibilityGroupDecl>(ar)
        } case DeclKind::FFIBlockDecl {
            d = new_decl<Declarations::FFIBlockDecl>(ar)
        } case DeclKind::EvalBlockDecl {
            d = new_decl<Declarations::EvalBlockDecl>(ar)
        } case DeclKind::TestDecl {
            d = new_scope<Declarations::TestDecl>(ar, DeclContextKind::Function)
        } case DeclKind::MacroDecl {
            d = unsafe (Declarations::MacroDecl::create(ar->ctx, SourceRange::invalid(), Token()) as unsafe *Decl)
        } case DeclKind::ProcedureMacroDecl {
            d = new_scope<Declarations::ProcedureMacroDecl>(
                ar,
                DeclContextKind::Function,
            )
        } default {
            return &null
        }
    }

    d->kind = kind
    if kind == DeclKind::RecoveryDecl {
        d->recovery_kind = cls
    }

    return d
}

/// The class a declaration object is: its kind, or what a recovery node
/// was going to be.
fn decl_class(d: unsafe *Decl) -> DeclKind {
    if d->kind == DeclKind::RecoveryDecl {
        return d->recovery_kind
    }

    return d->kind
}

/// The DeclContext of a scope declaration; null for one that is not a scope.
pub fn decl_dc(d: unsafe *Decl) -> unsafe *DeclContext {
    if d == &null {
        return &null
    }

    match decl_class(d) {
        case DeclKind::FunctionDecl {
            return unsafe ((d as unsafe *Declarations::FunctionDecl) as unsafe *DeclContext)
        } case DeclKind::StructDecl {
            return unsafe ((d as unsafe *Declarations::StructDecl) as unsafe *DeclContext)
        } case DeclKind::ClassDecl {
            return unsafe ((d as unsafe *Declarations::ClassDecl) as unsafe *DeclContext)
        } case DeclKind::InterfaceDecl {
            return unsafe ((d as unsafe *Declarations::InterfaceDecl) as unsafe *DeclContext)
        } case DeclKind::ExtensionDecl {
            return unsafe ((d as unsafe *Declarations::ExtensionDecl) as unsafe *DeclContext)
        } case DeclKind::EnumDecl {
            return unsafe ((d as unsafe *Declarations::EnumDecl) as unsafe *DeclContext)
        } case DeclKind::UnionDecl {
            return unsafe ((d as unsafe *Declarations::UnionDecl) as unsafe *DeclContext)
        } case DeclKind::ModuleDecl {
            return unsafe ((d as unsafe *Declarations::ModuleDecl) as unsafe *DeclContext)
        } case DeclKind::TestDecl {
            return unsafe ((d as unsafe *Declarations::TestDecl) as unsafe *DeclContext)
        } case DeclKind::ProcedureMacroDecl {
            return unsafe ((d as unsafe *Declarations::ProcedureMacroDecl) as unsafe *DeclContext)
        } default {
            return &null
        }
    }
}

//  the family header and the mixins

/// The fields of the Decl base and its VisibilityAnnotation mixin.
fn io_decl_base(ar: unsafe *ASTArchive, d: unsafe *Decl) {
    if !ar->reading() {
        ar->en<DeclKind>(&d->kind)
        if d->kind == DeclKind::RecoveryDecl {
            ar->en<DeclKind>(&d->recovery_kind)
        }
    }

    ar->range(&d->range)

    var has_vis = d->visibility != VisibilityKind::None
        || d->_visibility_range.start.raw() != 0
        || d->_visibility_range.end.raw() != 0
    // lexical_dc / semantic_dc are the parser's for a local declaration
    // (StmtParse::_attach_local_decl) and _build_symbols' for a member;
    // both are stored, and the rebuild writes the second kind again.
    var has_dcs = d->lexical_dc != &null || d->semantic_dc != &null
    ar->flag(&has_vis)
    ar->flag(&has_dcs)
    ar->flag(&d->poisoned)
    ar->flag(&d->is_implicit)
    io_annotations<Decl>(ar, d)

    if has_vis {
        ar->en<VisibilityKind>(&d->visibility)
        ar->range(&d->_visibility_range)
    }

    if has_dcs {
        ar->dc(&d->lexical_dc)
        ar->dc(&d->semantic_dc)
    }

    eval if defined!(DEBUG) {
        if d->kind != DeclKind::RecoveryDecl {
            ar->sema_is(
                d->recovery_kind == DeclKind::RecoveryDecl,
                "Decl::recovery_kind",
            )
        }
    }
}

/// DeclContext: the parent scope and the declaration list. dc_kind and
/// dc_owner are fixed by the class (decl_alloc); dc_scope and dc_symbols
/// are rebuilt from the tree (ASTParse::rebuild_derived).
fn <N: type> io_dc(ar: unsafe *ASTArchive, n: unsafe *N, k: DeclContextKind) {
    ar->dc(n->dc_parent)
    ar->decl_arena_list(n->dc_decls)
    eval if defined!(DEBUG) {
        ar->sema_is(n->dc_kind == k, "DeclContext::dc_kind")
        ar->sema_is(
            n->dc_owner == unsafe (n as unsafe *Decl),
            "DeclContext::dc_owner",
        )
    }
}

/// Redeclarable: whether this link is the definition. The ring itself
/// (_redecl_next, _redecl_canonical, _redecl_first) is the parser's
/// one-link ring on every node; RedeclMerge and T are what link more.
fn <N: type> io_redecl(ar: unsafe *ASTArchive, n: unsafe *N) {
    ar->flag(n->is_this_definition)
    eval if defined!(DEBUG) {
        ar->sema_is(n->canonical_decl() == n, "Redeclarable::_redecl_canonical")
        ar->sema_is(n->next_in_chain() == n, "Redeclarable::_redecl_next")
        ar->sema_is(n->first_decl() == n, "Redeclarable::_redecl_first")
    }
}

fn <N: type> io_template_params(ar: unsafe *ASTArchive, n: unsafe *N) {
    ar->decl_list<Declarations::GenericParamDecl>(n->generic_params)
    ar->expr<Expr>(n->requires_clause)
    ar->en<Declarations::SpecKind>(n->spec_kind)
    ar->type_list<Type>(n->spec_args)
    eval if defined!(DEBUG) {
        ar->sema_null<Decl>(
            n->instantiated_from,
            "TemplateParams::instantiated_from",
        )

        ar->sema_false(n->foreign_fill != 0, "TemplateParams::foreign_fill")
    }
}

/// FFILinkage: the `ffi "c"` stamp of a declaration written in Kairo. The
/// rest of the mixin describes a declaration IMPORTED from a header, which
/// Sema/Foreign builds and no parsed tree holds.
fn <N: type> io_ffi(ar: unsafe *ASTArchive, n: unsafe *N) {
    var has = n->ffi_linkage != LinkageKind::None
        || n->_ffi_linkage_range.start.raw() != 0
        || n->_ffi_linkage_range.end.raw() != 0
        || n->_ffi_lang_token.kind != TokenKind::TkUnknown
    ar->flag(has)
    if has {
        ar->en<LinkageKind>(n->ffi_linkage)
        ar->range(n->_ffi_linkage_range)
        ar->tok(n->_ffi_lang_token)
    }

    eval if defined!(DEBUG) {
        ar->sema_null<void>(n->clang_decl, "FFILinkage::clang_decl")
        ar->sema_zero(n->usr.size() as u64, "FFILinkage::usr")
        ar->sema_zero(n->cxx_spelling.size() as u64, "FFILinkage::cxx_spelling")
        ar->sema_null<void>(n->origin_set, "FFILinkage::origin_set")
        ar->sema_zero(n->origin_fid as u64, "FFILinkage::origin_fid")
        ar->sema_zero(
            n->cxx_param_spellings.size() as u64,
            "FFILinkage::cxx_param_spellings",
        )

        ar->sema_zero(
            n->cxx_return_spelling.size() as u64,
            "FFILinkage::cxx_return_spelling",
        )

        ar->sema_false(n->ffi_c_variadic, "FFILinkage::ffi_c_variadic")
        ar->sema_false(n->ffi_explicit, "FFILinkage::ffi_explicit")
        ar->sema_false(n->ffi_noexcept, "FFILinkage::ffi_noexcept")
        ar->sema_false(n->ffi_deleted, "FFILinkage::ffi_deleted")
        ar->sema_false(n->ffi_constexpr, "FFILinkage::ffi_constexpr")
        ar->sema_false(n->ffi_virtual, "FFILinkage::ffi_virtual")
        ar->sema_false(n->ffi_pure_virtual, "FFILinkage::ffi_pure_virtual")
        ar->sema_false(n->ffi_static_member, "FFILinkage::ffi_static_member")
        ar->sema_zero(
            n->ffi_ref_qualifier as u64,
            "FFILinkage::ffi_ref_qualifier",
        )

        ar->sema_false(n->ffi_conversion_op, "FFILinkage::ffi_conversion_op")
        ar->sema_false(n->layout.known, "FFILinkage::layout")
        ar->sema_false(n->ffi_is_union, "FFILinkage::ffi_is_union")
        ar->sema_false(n->ffi_is_final, "FFILinkage::ffi_is_final")
        ar->sema_zero(
            n->ffi_tag_keyword.size() as u64,
            "FFILinkage::ffi_tag_keyword",
        )

        ar->sema_null<void>(n->ffi_tag_target, "FFILinkage::ffi_tag_target")
        ar->sema_false(n->ffi_scoped_enum, "FFILinkage::ffi_scoped_enum")
        ar->sema_false(n->is_cxx_concept, "FFILinkage::is_cxx_concept")
    }
}

/// A `derives` / `impl` list: InheritEdge per base.
pub fn io_inherit_edges(ar: unsafe *ASTArchive, @inout l: FrozenList<Declarations::InheritEdge>) {
    var n = ar->list<Declarations::InheritEdge>(&l)
    for var i: usize = 0; i < n; ++i {
        var unsafe *e = l.get(i)
        ar->type_<Type>(&e->base)
        ar->num8(&e->visibility)
        ar->flag(&e->is_virtual)
        ar->range(&e->range)
    }
}

//  the classes

fn io_generic_param_decl(ar: unsafe *ASTArchive, n: unsafe *Declarations::GenericParamDecl) {
    ar->tok(&n->name)
    ar->decl<Decl>(&n->owner)
    ar->en<Declarations::GenericParamKindBound>(&n->kind_bound)
    ar->range(&n->kind_bound_range)
    io_inherit_edges(ar, &n->impl_bounds)
    io_inherit_edges(ar, &n->derives_bounds)
    ar->flag(&n->is_pack)
    ar->flag(&n->is_const_param)
    ar->type_<Type>(&n->value_type)
    ar->type_<Type>(&n->default_type)
    ar->num32(&n->index)
    eval if defined!(DEBUG) {
        ar->sema_false(n->ffi_has_default, "GenericParamDecl::ffi_has_default")
    }
}

fn io_param_decl(ar: unsafe *ASTArchive, n: unsafe *Declarations::ParamDecl) {
    ar->tok(&n->name)
    ar->flag(&n->is_self)
    ar->flag(&n->is_const)
    ar->flag(&n->unname)
    ar->flag(&n->is_pack)
    ar->flag(&n->keyword_only)
    ar->type_<Type>(&n->type_)
    ar->expr<Expr>(&n->default_val)
    ar->num32(&n->index)
    ar->en<ParamMode>(&n->mode)
    ar->range(&n->mode_range)
    eval if defined!(DEBUG) {
        ar->sema_false(n->has_default, "ParamDecl::has_default")
        ar->sema_false(n->cxx_int_alias, "ParamDecl::cxx_int_alias")
        ar->sema_false(n->cxx_alias_ptr, "ParamDecl::cxx_alias_ptr")
        ar->sema_null<Decl>(n->default_thunk, "ParamDecl::default_thunk")
        ar->sema_false(n->default_thunk_home, "ParamDecl::default_thunk_home")
        ar->sema_false(
            n->default_thunk_placed,
            "ParamDecl::default_thunk_placed",
        )

        ar->sema_null<Type>(n->pack_type, "ParamDecl::pack_type")
        ar->sema_false(n->inferred_const, "ParamDecl::inferred_const")
    }
}

fn io_function_decl(ar: unsafe *ASTArchive, n: unsafe *Declarations::FunctionDecl) {
    io_dc<Declarations::FunctionDecl>(ar, n, DeclContextKind::Function)
    io_redecl<Declarations::FunctionDecl>(ar, n)
    io_template_params<Declarations::FunctionDecl>(ar, n)
    io_ffi<Declarations::FunctionDecl>(ar, n)

    ar->tok(&n->name)
    ar->flag(&n->is_operator)
    ar->flag(&n->is_variadic)
    ar->flag(&n->is_noreturn)
    ar->flag(&n->hot_path)
    ar->flag(&n->no_inline)
    ar->flag(&n->cold_path)
    ar->flag(&n->is_pure)
    ar->flag(&n->is_const_fn)
    ar->decl_list<Declarations::ParamDecl>(&n->params)
    ar->type_<Type>(&n->return_type)
    ar->en<Declarations::AbiKind>(&n->abi)
    ar->en<Declarations::FnModifier>(&n->modifiers)
    ar->type_list<Type>(&n->panic_set)
    ar->range(&n->panic_range)
    ar->range(&n->params_end)
    ar->en<Declarations::FnBodyKind>(&n->body_kind)
    ar->stmt<CompoundStmt>(&n->body_block)
    ar->expr<Expr>(&n->body_expr)
    ar->tok_list(&n->op_token)
    ar->en<Declarations::TransferKind>(&n->transfer)
    ar->expr<Expr>(&n->qualifier)
    ar->expr<Expr>(&n->where_clause)
    ar->num8(&n->class_alloc_op)
    ar->range(&n->old_dtor_at)
    ar->num8(&n->call_conv)
    ar->range(&n->purity_at)

    eval if defined!(DEBUG) {
        ar->sema_zero(n->panic_eff.size() as u64, "FunctionDecl::panic_eff")
        ar->sema_is(
            n->panic_state == Declarations::PanicSetState::None,
            "FunctionDecl::panic_state",
        )

        ar->sema_null<Type>(n->panic_result, "FunctionDecl::panic_result")
        ar->sema_zero(n->panic_deps.size() as u64, "FunctionDecl::panic_deps")
        ar->sema_zero(n->panic_arms.size() as u64, "FunctionDecl::panic_arms")
        ar->sema_zero(
            n->panic_arm_at.size() as u64,
            "FunctionDecl::panic_arm_at",
        )

        ar->sema_zero(
            n->move_reuse_site.size() as u64,
            "FunctionDecl::move_reuse_site",
        )

        ar->sema_zero(
            n->move_reuse_read.size() as u64,
            "FunctionDecl::move_reuse_read",
        )

        ar->sema_false(n->cxx_ref_return, "FunctionDecl::cxx_ref_return")
        ar->sema_false(n->overrides_virtual, "FunctionDecl::overrides_virtual")
        ar->sema_false(n->is_generator, "FunctionDecl::is_generator")
        ar->sema_false(n->has_yield, "FunctionDecl::has_yield")
        ar->sema_false(n->no_unwind, "FunctionDecl::no_unwind")
        // The driver drops a recovered body after the post-parse gate
        // (CompilerRecovery::admit_past_syntax_errors); the serializer runs
        // before it (FrontendAction::_ast_serialize), so a written tree
        // never has one.
        ar->sema_false(n->body_recovered, "FunctionDecl::body_recovered")
        ar->sema_null<Declarations::FunctionDecl>(
            n->where_lead,
            "FunctionDecl::where_lead",
        )

        ar->sema_zero(n->where_group.size() as u64, "FunctionDecl::where_group")
        ar->sema_zero(n->ffi_builtin_id as u64, "FunctionDecl::ffi_builtin_id")
        ar->sema_zero(n->ffi_ice_mask as u64, "FunctionDecl::ffi_ice_mask")
        ar->sema_false(n->lowers_to_expect, "FunctionDecl::lowers_to_expect")
        ar->sema_false(n->lowers_to_assume, "FunctionDecl::lowers_to_assume")
        ar->sema_zero(n->dynamic_layout as u64, "FunctionDecl::dynamic_layout")
        ar->sema_zero(
            n->inferred_purity as u64,
            "FunctionDecl::inferred_purity",
        )

        ar->sema_is(
            n->adt_role == Declarations::AdtRole::None,
            "FunctionDecl::adt_role",
        )

        ar->sema_is(
            n->adt_form == Declarations::AdtForm::Trivial,
            "FunctionDecl::adt_form",
        )

        ar->sema_zero(n->adt_variant as u64, "FunctionDecl::adt_variant")
        ar->sema_zero(n->ci_split as u64, "FunctionDecl::ci_split")
        ar->sema_zero(n->ci_index as u64, "FunctionDecl::ci_index")
        ar->sema_zero(n->ci_slots.size() as u64, "FunctionDecl::ci_slots")
        ar->sema_zero(n->ci_dense.size() as u64, "FunctionDecl::ci_dense")
        ar->sema_false(n->ci_cut, "FunctionDecl::ci_cut")
    }
}

fn io_variable_decl(ar: unsafe *ASTArchive, n: unsafe *Declarations::VariableDecl) {
    io_ffi<Declarations::VariableDecl>(ar, n)
    ar->tok(&n->name)
    ar->flag(&n->is_thread)
    ar->flag(&n->const_binding)
    ar->flag(&n->nullable_shorthand)
    ar->flag(&n->pointer_unsafe)
    ar->en<Declarations::StorageClass>(&n->storage)
    ar->type_<Type>(&n->type_)
    ar->expr<Expr>(&n->init)
    ar->num32(&n->pointer_depth)
    ar->range(&n->pointer_range)
    ar->range(&n->storage_kw)
    eval if defined!(DEBUG) {
        ar->sema_false(n->raw_slot, "VariableDecl::raw_slot")
        ar->sema_false(n->place_ref, "VariableDecl::place_ref")
        ar->sema_false(n->auto_copy, "VariableDecl::auto_copy")
        ar->sema_zero(n->fold_pin as u64, "VariableDecl::fold_pin")
        ar->sema_false(n->fold_pin_neg, "VariableDecl::fold_pin_neg")
        ar->sema_zero(n->fold_pin_mag, "VariableDecl::fold_pin_mag")
    }
}

fn io_field_decl(ar: unsafe *ASTArchive, n: unsafe *Declarations::FieldDecl) {
    ar->tok(&n->name)
    ar->flag(&n->is_mutable)
    ar->flag(&n->is_thread)
    ar->flag(&n->const_binding)
    ar->en<Declarations::StorageClass>(&n->storage)
    ar->type_<Type>(&n->type_)
    ar->expr<Expr>(&n->init)
    ar->num32(&n->index)
    eval if defined!(DEBUG) {
        ar->sema_zero(n->fold_pin as u64, "FieldDecl::fold_pin")
        ar->sema_false(n->fold_pin_neg, "FieldDecl::fold_pin_neg")
        ar->sema_zero(n->fold_pin_mag, "FieldDecl::fold_pin_mag")
        ar->sema_false(n->is_bitfield, "FieldDecl::is_bitfield")
        ar->sema_false(n->is_anonymous_union, "FieldDecl::is_anonymous_union")
        ar->sema_is(
            n->init_fold == Declarations::FieldFold::None,
            "FieldDecl::init_fold",
        )

        ar->sema_false(n->init_neg, "FieldDecl::init_neg")
        ar->sema_zero(n->init_mag, "FieldDecl::init_mag")
        ar->sema_null<Decl>(n->init_thunk, "FieldDecl::init_thunk")
        ar->sema_zero(n->init_elems.size() as u64, "FieldDecl::init_elems")
    }
}

fn io_struct_decl(ar: unsafe *ASTArchive, n: unsafe *Declarations::StructDecl) {
    io_dc<Declarations::StructDecl>(ar, n, DeclContextKind::Struct)
    io_redecl<Declarations::StructDecl>(ar, n)
    io_template_params<Declarations::StructDecl>(ar, n)
    io_ffi<Declarations::StructDecl>(ar, n)
    ar->tok(&n->name)
    ar->decl_list<Declarations::FieldDecl>(&n->fields)
    ar->decl_list<Declarations::FunctionDecl>(&n->methods)
    io_inherit_edges(ar, &n->implements)
    eval if defined!(DEBUG) {
        ar->sema_false(n->is_adt_payload, "StructDecl::is_adt_payload")
        ar->sema_null<Declarations::GenericParamDecl>(
            n->adt_pack_param,
            "StructDecl::adt_pack_param",
        )

        ar->sema_null<Decl>(n->adt_of, "StructDecl::adt_of")
        ar->sema_null<Declarations::FunctionDecl>(
            n->assign_from,
            "StructDecl::assign_from",
        )

        ar->sema_is(
            n->assign_form == Declarations::AssignForm::Implicit,
            "StructDecl::assign_form",
        )

        ar->sema_zero(n->tuple_arity as u64, "StructDecl::tuple_arity")
        ar->sema_false(n->is_null_type, "StructDecl::is_null_type")
    }
}

fn io_class_decl(ar: unsafe *ASTArchive, n: unsafe *Declarations::ClassDecl) {
    io_dc<Declarations::ClassDecl>(ar, n, DeclContextKind::Class)
    io_redecl<Declarations::ClassDecl>(ar, n)
    io_template_params<Declarations::ClassDecl>(ar, n)
    io_ffi<Declarations::ClassDecl>(ar, n)
    ar->tok(&n->name)
    ar->flag(&n->is_final)
    ar->flag(&n->is_abstract)
    ar->decl_list<Declarations::FieldDecl>(&n->fields)
    ar->decl_list<Declarations::FunctionDecl>(&n->methods)
    io_inherit_edges(ar, &n->derives_list)
    io_inherit_edges(ar, &n->implements)
    eval if defined!(DEBUG) {
        ar->sema_null<Declarations::FunctionDecl>(
            n->assign_from,
            "ClassDecl::assign_from",
        )

        ar->sema_is(
            n->assign_form == Declarations::AssignForm::Implicit,
            "ClassDecl::assign_form",
        )

        ar->sema_zero(n->ffi_usings.size() as u64, "ClassDecl::ffi_usings")
    }
}

fn io_interface_decl(ar: unsafe *ASTArchive, n: unsafe *Declarations::InterfaceDecl) {
    io_dc<Declarations::InterfaceDecl>(ar, n, DeclContextKind::Interface)
    io_redecl<Declarations::InterfaceDecl>(ar, n)
    io_template_params<Declarations::InterfaceDecl>(ar, n)
    io_ffi<Declarations::InterfaceDecl>(ar, n)
    ar->tok(&n->name)
    ar->flag(&n->derives_composed)
    ar->decl_list<Declarations::FunctionDecl>(&n->methods)
    io_inherit_edges(ar, &n->derives_list)
    ar->expr<Expr>(&n->derives_expr)
    ar->range(&n->derives_end)
    eval if defined!(DEBUG) {
        ar->sema_zero(
            n->requirements.size() as u64,
            "InterfaceDecl::requirements",
        )

        ar->sema_zero(n->compose_state as u64, "InterfaceDecl::compose_state")
    }
}

fn io_extension_decl(ar: unsafe *ASTArchive, n: unsafe *Declarations::ExtensionDecl) {
    io_dc<Declarations::ExtensionDecl>(ar, n, DeclContextKind::Extension)
    io_template_params<Declarations::ExtensionDecl>(ar, n)
    ar->type_<Type>(&n->target)
    ar->decl_list<Declarations::FunctionDecl>(&n->methods)
    io_inherit_edges(ar, &n->implements)
}

fn io_enum_variant_decl(ar: unsafe *ASTArchive, n: unsafe *Declarations::EnumVariantDecl) {
    ar->tok(&n->name)
    ar->flag(&n->is_pack_expansion)
    ar->expr<Expr>(&n->discriminant)
    ar->decl_list<Declarations::FieldDecl>(&n->payload)
    ar->num32(&n->index)
    // The parser's: a variant's tag starts as its position.
    ar->num64(&n->adt_tag_value)
    ar->range(&n->pack_range)
    eval if defined!(DEBUG) {
        ar->sema_null<Declarations::FieldDecl>(
            n->adt_member,
            "EnumVariantDecl::adt_member",
        )

        ar->sema_is(
            n->adt_ctor == Declarations::AdtCtorForm::Lambda,
            "EnumVariantDecl::adt_ctor",
        )

        ar->sema_false(n->value.ok, "EnumVariantDecl::value")
        ar->sema_false(n->value.neg, "EnumVariantDecl::value")
        ar->sema_zero(n->value.mag, "EnumVariantDecl::value")
        ar->sema_false(n->value.overflow, "EnumVariantDecl::value")
    }
}

fn io_enum_decl(ar: unsafe *ASTArchive, n: unsafe *Declarations::EnumDecl) {
    io_dc<Declarations::EnumDecl>(ar, n, DeclContextKind::Enum)
    io_redecl<Declarations::EnumDecl>(ar, n)
    io_template_params<Declarations::EnumDecl>(ar, n)
    io_ffi<Declarations::EnumDecl>(ar, n)
    ar->tok(&n->name)
    ar->flag(&n->is_adt)
    ar->flag(&n->is_open)
    ar->type_<Type>(&n->underlying)
    ar->decl_list<Declarations::EnumVariantDecl>(&n->variants)
    eval if defined!(DEBUG) {
        ar->sema_null<Decl>(n->adt_layout, "EnumDecl::adt_layout")
        ar->sema_null<Declarations::FieldDecl>(
            n->adt_tag_field,
            "EnumDecl::adt_tag_field",
        )

        ar->sema_false(n->adt_niche_shape, "EnumDecl::adt_niche_shape")
        ar->sema_false(n->adt_niche, "EnumDecl::adt_niche")
        ar->sema_null<Declarations::FunctionDecl>(
            n->adt_which,
            "EnumDecl::adt_which",
        )

        ar->sema_false(n->adt_explicit_tags, "EnumDecl::adt_explicit_tags")
        ar->sema_zero(n->adt_union_align as u64, "EnumDecl::adt_union_align")
        ar->sema_null<Declarations::FieldDecl>(
            n->adt_site_field,
            "EnumDecl::adt_site_field",
        )

        ar->sema_null<Declarations::FieldDecl>(
            n->adt_payload_offset,
            "EnumDecl::adt_payload_offset",
        )

        ar->sema_false(n->adt_void_unit, "EnumDecl::adt_void_unit")
        ar->sema_null<Declarations::FieldDecl>(
            n->adt_tag_member,
            "EnumDecl::adt_tag_member",
        )

        ar->sema_null<Declarations::FieldDecl>(
            n->adt_prefix_tag,
            "EnumDecl::adt_prefix_tag",
        )
    }
}

fn io_union_decl(ar: unsafe *ASTArchive, n: unsafe *Declarations::UnionDecl) {
    io_dc<Declarations::UnionDecl>(ar, n, DeclContextKind::Union)
    io_redecl<Declarations::UnionDecl>(ar, n)
    io_template_params<Declarations::UnionDecl>(ar, n)
    io_ffi<Declarations::UnionDecl>(ar, n)
    ar->tok(&n->name)
    ar->decl_list<Declarations::FieldDecl>(&n->fields)
    ar->decl_list<Declarations::FunctionDecl>(&n->methods)
    eval if defined!(DEBUG) {
        ar->sema_false(n->is_anonymous, "UnionDecl::is_anonymous")
    }
}

fn io_type_alias_decl(ar: unsafe *ASTArchive, n: unsafe *Declarations::TypeAliasDecl) {
    io_template_params<Declarations::TypeAliasDecl>(ar, n)
    io_ffi<Declarations::TypeAliasDecl>(ar, n)
    ar->tok(&n->name)
    ar->flag(&n->is_associated)
    ar->type_<Type>(&n->aliased)
}

fn io_ffi_block_decl(ar: unsafe *ASTArchive, n: unsafe *Declarations::FFIBlockDecl) {
    ar->tok(&n->lang_token)
    ar->decl_list<Decl>(&n->body)
}

fn io_module_decl(ar: unsafe *ASTArchive, n: unsafe *Declarations::ModuleDecl) {
    io_dc<Declarations::ModuleDecl>(ar, n, DeclContextKind::Module)
    io_redecl<Declarations::ModuleDecl>(ar, n)
    ar->tok(&n->name)
    ar->flag(&n->is_inline)
    ar->flag(&n->is_anonymous)
    eval if defined!(DEBUG) {
        // Set only on the file's own synthesized module, which is rebuilt
        // (TranslationUnit::module_self), never written.
        ar->sema_zero(
            n->module_path.segments.size() as u64,
            "ModuleDecl::module_path",
        )
    }
}

fn io_import_decl(ar: unsafe *ASTArchive, n: unsafe *Declarations::ImportDecl) {
    io_ffi<Declarations::ImportDecl>(ar, n)
    ar->en<Declarations::ImportKind>(&n->import_kind)
    ar->flag(&n->has_alias)
    ar->flag(&n->is_wildcard)
    ar->flag(&n->has_items)
    ar->flag(&n->last_seg_is_macro)
    ar->flag(&n->is_prelude)
    ar->tok_list(&n->path_segments)

    var count = ar->list<Declarations::ImportItem>(&n->items)
    for var i: usize = 0; i < count; ++i {
        var unsafe *it = n->items.get(i)
        ar->tok_list(&it->sub_path)
        ar->tok(&it->alias)
        ar->range(&it->range)
        ar->flag(&it->has_alias)
        ar->flag(&it->is_wildcard)
        ar->flag(&it->is_macro)
    }

    ar->tok(&n->header)
    ar->tok(&n->alias)

    // The file the path resolved to (FileImportIndex). "Resolved" is
    // file_seg_count, not a non-zero fid: fid 0 is a real file.
    ar->num32(&n->file_seg_count)
    if n->file_seg_count > 0 {
        var fref: u32 = 0
        if !ar->reading() {
            fref = ar->file_ref(n->resolved_fid)
        }

        ar->num32(&fref)
        if ar->reading() {
            n->resolved_fid = ar->file_fid(fref)
        }
    }

    eval if defined!(DEBUG) {
        if n->file_seg_count == 0 {
            // An ffi import's header fid is the driver's, written in _sema.
            ar->sema_zero(n->resolved_fid as u64, "ImportDecl::resolved_fid")
        }

        ar->sema_zero(
            n->ffi_closure_fids.size() as u64,
            "ImportDecl::ffi_closure_fids",
        )
    }
}

fn io_visibility_group_decl(ar: unsafe *ASTArchive, n: unsafe *Declarations::VisibilityGroupDecl) {
    ar->num8(&n->group_visibility)
    ar->decl_list<Decl>(&n->members)
}

fn io_eval_block_decl(ar: unsafe *ASTArchive, n: unsafe *Declarations::EvalBlockDecl) {
    ar->decl_list<Decl>(&n->body)
    ar->stmt<Stmt>(&n->stmt)
}

fn io_test_decl(ar: unsafe *ASTArchive, n: unsafe *Declarations::TestDecl) {
    io_dc<Declarations::TestDecl>(ar, n, DeclContextKind::Function)
    ar->expr<Expr>(&n->label)
    ar->stmt<CompoundStmt>(&n->body)
}

fn io_macro_decl(ar: unsafe *ASTArchive, n: unsafe *Declarations::MacroDecl) {
    ar->tok(&n->name)
    ar->flag(&n->is_variadic)
    ar->flag(&n->accepts_params)

    var count = ar->list<Declarations::MacroParamSpec>(&n->params_spec)
    for var i: usize = 0; i < count; ++i {
        var unsafe *p = n->params_spec.get(i)
        ar->tok(&p->name)
        ar->num8(&p->variadic)
        ar->flag(&p->has_default)
        // Positions in the macro's own token run, not in any table.
        ar->num32(&p->default_off)
        ar->num32(&p->default_len)
    }

    ar->range(&n->body_span)
}

fn io_procedure_macro_decl(ar: unsafe *ASTArchive, n: unsafe *Declarations::ProcedureMacroDecl) {
    io_dc<Declarations::ProcedureMacroDecl>(ar, n, DeclContextKind::Function)
    ar->tok(&n->name)
    ar->decl_list<Declarations::ParamDecl>(&n->params)
    ar->stmt<CompoundStmt>(&n->body)
}

/// Writes or reads one declaration: the family header, then its class.
pub fn decl_io(ar: unsafe *ASTArchive, d: unsafe *Decl) {
    io_decl_base(ar, d)

    match decl_class(d) {
        case DeclKind::FunctionDecl {
            io_function_decl(
                ar,
                unsafe (d as unsafe *Declarations::FunctionDecl),
            )
        } case DeclKind::VariableDecl {
            io_variable_decl(
                ar,
                unsafe (d as unsafe *Declarations::VariableDecl),
            )
        } case DeclKind::FieldDecl {
            io_field_decl(ar, unsafe (d as unsafe *Declarations::FieldDecl))
        } case DeclKind::ParamDecl {
            io_param_decl(ar, unsafe (d as unsafe *Declarations::ParamDecl))
        } case DeclKind::GenericParamDecl {
            io_generic_param_decl(
                ar,
                unsafe (d as unsafe *Declarations::GenericParamDecl),
            )
        } case DeclKind::StructDecl {
            io_struct_decl(ar, unsafe (d as unsafe *Declarations::StructDecl))
        } case DeclKind::ClassDecl {
            io_class_decl(ar, unsafe (d as unsafe *Declarations::ClassDecl))
        } case DeclKind::InterfaceDecl {
            io_interface_decl(
                ar,
                unsafe (d as unsafe *Declarations::InterfaceDecl),
            )
        } case DeclKind::ExtensionDecl {
            io_extension_decl(
                ar,
                unsafe (d as unsafe *Declarations::ExtensionDecl),
            )
        } case DeclKind::EnumDecl {
            io_enum_decl(ar, unsafe (d as unsafe *Declarations::EnumDecl))
        } case DeclKind::EnumVariantDecl {
            io_enum_variant_decl(
                ar,
                unsafe (d as unsafe *Declarations::EnumVariantDecl),
            )
        } case DeclKind::UnionDecl {
            io_union_decl(ar, unsafe (d as unsafe *Declarations::UnionDecl))
        } case DeclKind::TypeAliasDecl {
            io_type_alias_decl(
                ar,
                unsafe (d as unsafe *Declarations::TypeAliasDecl),
            )
        } case DeclKind::ModuleDecl {
            io_module_decl(ar, unsafe (d as unsafe *Declarations::ModuleDecl))
        } case DeclKind::ImportDecl {
            io_import_decl(ar, unsafe (d as unsafe *Declarations::ImportDecl))
        } case DeclKind::VisibilityGroupDecl {
            io_visibility_group_decl(
                ar,
                unsafe (d as unsafe *Declarations::VisibilityGroupDecl),
            )
        } case DeclKind::FFIBlockDecl {
            io_ffi_block_decl(
                ar,
                unsafe (d as unsafe *Declarations::FFIBlockDecl),
            )
        } case DeclKind::EvalBlockDecl {
            io_eval_block_decl(
                ar,
                unsafe (d as unsafe *Declarations::EvalBlockDecl),
            )
        } case DeclKind::TestDecl {
            io_test_decl(ar, unsafe (d as unsafe *Declarations::TestDecl))
        } case DeclKind::MacroDecl {
            io_macro_decl(ar, unsafe (d as unsafe *Declarations::MacroDecl))
        } case DeclKind::ProcedureMacroDecl {
            io_procedure_macro_decl(
                ar,
                unsafe (d as unsafe *Declarations::ProcedureMacroDecl),
            )
        } default {
            ar->fail("declaration of an unknown kind")
        }
    }
}
