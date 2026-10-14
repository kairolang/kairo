/// --- The Kairo Project -------------- Sema/Lower/FieldInitLowering.k --- ///
///
///   \brief A field's initializer becomes its C++ default member initializer:
///          a constant spelled in the class, or a call of a member function
///          whose body is the initializer.
///
///   \detail
///       class A { var n: i32 = 5   var d: i32 = add(tick(1), tick(2)) }
///     ->
///       class A {
///           var n: i32                                  init_fold: Int 5
///           var d: i32                                  init_thunk: __kairo_init_d
///           fn __kairo_init_d(self) -> i32 { return add(tick(1), tick(2)) }
///       }
///
///     InterfaceEmitter writes `signed int n = 5;` and
///     `signed int d = __kairo_init_d();`. C++ runs a default member
///     initializer in exactly the constructors that do not initialize the
///     field themselves: the implicit one, a declaration with no
///     initializer, a user constructor that leaves the field alone, a
///     designated struct literal that omits it. A defaulted copy or move does
///     not run it. That is Kairo's default.
///
///   \par Constants
///     An integer field whose initializer ConstEval folds, a bool field
///     initialized with `true` or `false`, and a raw pointer field
///     initialized with `&null` keep no code at all: the value is recorded on
///     the field (FieldDecl::init_fold) and the emitter spells it. Nothing
///     about it differs between TUs, it names no function, and it is the
///     common case.
///
///   \par Everything else
///     Becomes the body of a member function. Written into the class, the
///     expression would break three things: a class definition is the same
///     bytes in every TU and carries no user-written body (IMPORTS.md
///     invariant 12), while an initializer may call a function that tier 2
///     declares only after every class, or one private to its own file; its
///     identifiers index its own file's tables; and the passes after this
///     one rewrite it into statement expressions, which clang rejects at
///     class scope. As a member's body it goes out of line, after every
///     declaration, by the path every method takes (a generic record's
///     through visible_bodies).
///
///     A method, not a static: a field default keeps the type body's scope
///     (RESOLUTION.md, the explicit-qualifier rule), so it may name another
///     member bare, and EmitIR's spelling of that member is read through
///     `this`. C++ runs default member initializers in declaration order,
///     so a member named this way is already built when it is read
///     provided it is declared earlier; InitCheck rejects any other. `self`
///     itself is not in scope in an initializer (R020E), so the body never
///     names the minted one.
///
///     The expression MOVES: `init` is null afterwards, one node with one
///     parent, so no later pass rewrites it twice, not even for a field in
///     a visibility group, which a walk reaches through the group as well.
///
///   \par Not lowered
///     A static or eval field, and an array-typed one, keep `init`.
///     FeatureGateCheck rejects their initializers (SC116E) before this pass
///     runs, so reaching one here is a hole in the gate, and InterfaceEmitter
///     ICEs on it.
///
///   Phase: LOWER, after ExprBodyDesugar and before every other pass that
///   rewrites a body, so each of them meets the initializer as an ordinary
///   `return`.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

import Sema::SemaContext::*;
import Sema::Type::TypeUtil::*;
import Sema::Check::ConstEval::*;
import Sema::Lower::LowerSynth::*;
import AST::Visitor::ASTWriter::*;
import AST::ASTSupport::*;
import AST::LangItems::*;
import AST::Mixin::Annotation::*;
import AST::Context::DeclContext::*;
import AST::Node::Base::*;
import AST::Node::Types::*;
import AST::Node::Expressions::*;
import AST::Node::PrimaryExpressions::*;
import AST::Node::Statements::*;
import AST::Node::Declarations::*;
import AST::Node::CanonicalNodes::*;
import AST::Node::Casting::*;
import AST::Kind::DeclKind::*;
import AST::Kind::TypeKind::*;
import Token::Token::*;
import Location::SourceRange::*;

__inline_cpp("
#define ASTWriter_FieldInitLowering ASTWriter<FieldInitLowering>
");

class FieldInitLowering derives ASTWriter::<FieldInitLowering> {
    pub var sc: *SemaContext;
    priv var tu:    TypeUtil;
    priv var synth: LowerSynth;
    priv var ce:    ConstEval;

    fn FieldInitLowering(self, sc: *SemaContext) {
        self.sc    = sc;
        self.ctx   = sc->ctx;
        self.tu    = TypeUtil(sc);
        self.synth = LowerSynth(sc);
        self.ce    = ConstEval(sc);
    }

    fn run(self) {
        self.sc->require_phase(SemaPhase::Checked);
        if self.sc->tu == &null { return; }
        ASTWriter_FieldInitLowering::run(self.sc->tu);
    }

    // --- the records that carry defaults ------------------------------------------

    fn transform_class_decl(self, n: *ClassDecl) -> vec::<*Decl> {
        var out = ASTWriter_FieldInitLowering::transform_class_decl(n);
        self._lower_fields(static_cast::<*Decl>(n), n->fields, &(n->methods));
        return out;
    }

    fn transform_struct_decl(self, n: *StructDecl) -> vec::<*Decl> {
        var out = ASTWriter_FieldInitLowering::transform_struct_decl(n);
        self._lower_fields(static_cast::<*Decl>(n), n->fields, &(n->methods));
        return out;
    }

    /// Each initializer folded or turned into a thunk, the thunks appended
    /// to \p methods in field order. A record reached a second time (a
    /// nested one written inside a visibility group) finds every
    /// initializer already consumed and changes nothing.
    priv fn _lower_fields(self, owner: *Decl, fields: FrozenList::<*FieldDecl>, methods: *FrozenList::<*FunctionDecl>) {
        if owner->is_poisoned() { return; }
        var rw = self.rewriter::<*FunctionDecl>(methods);
        for var i: usize = 0; i < fields.size(); ++i {
            var f = fields[i];
            if (f == &null) || (f->init == &null) { continue; }
            if self._kept(f) { continue; }
            if self._fold(f) { continue; }
            rw.append(self._mint(f));
        }
        rw.apply();
    }

    /// The initializers that stay on the field (file header, Not lowered),
    /// and a poisoned one, which is not this pass's to judge.
    priv fn _kept(self, f: *FieldDecl) -> bool {
        if f->is_poisoned() || f->init->is_poisoned() || (f->type_ == &null) { return true; }
        if f->is_static() || (f->storage == StorageClass::Eval) { return true; }
        var c = canon_unqual(f->type_->canonical);
        return (c != &null) && (c->kind == TypeKind::FixedArrayType);
    }

    /// A constant the emitter can spell (file header, Constants), recorded
    /// on the field. An integer that does not fit the field's type is left
    /// to the thunk, where C++ converts it as the typer allowed.
    priv fn _fold(self, f: *FieldDecl) -> bool {
        var t = f->type_->canonical;
        var e = f->init;
        if self.tu.is_integer(t) {
            var c = self.ce.eval_int(e);
            if (!c.ok) || c.overflow || (!self.ce.fits(c, t)) { return false; }
            f->init_fold = FieldFold::Int;
            f->init_neg  = c.neg;
            f->init_mag  = c.mag;
        } else if self.tu.is_bool(t) && isa::<BooleanLiteralExpr>(e) {
            f->init_fold = (FieldFold::True) if (cast::<BooleanLiteralExpr>(e)->value) else (FieldFold::False);
        } else if self.tu.is_unsafe_ptr(t) && isa::<NullLiteralExpr>(e) && cast::<NullLiteralExpr>(e)->is_ref {
            f->init_fold = FieldFold::Null;
        } else {
            return false;
        }
        f->init = &null;
        return true;
    }

    /// `fn __kairo_init_<f>(self) -> T { return <init> }`, a member of the
    /// field's record, stamped on the field. No generic parameters of its
    /// own: a generic record's are the template head its out-of-line
    /// definition is written under.
    priv fn _mint(self, f: *FieldDecl) -> *FunctionDecl {
        var e    = f->init;
        var at   = e->range;
        var name = LowerTargets::field_init_thunk(self.tu.decl_name(static_cast::<*Decl>(f)));
        var th   = self._new_fn(at, self.synth.ident(at, name), reinterpret_cast::<*DeclContext>(f->semantic_dc));
        th->semantic_dc = f->semantic_dc;
        th->lexical_dc  = f->semantic_dc;
        th->visibility  = VisibilityKind::Public;
        th->is_implicit = true;
        th->return_type = f->type_;

        var ps = self.list_builder::<*ParamDecl>();
        ps.push(ParamDecl::create_self(self.ctx, at, self.synth.ident(at, "self")));
        ps.freeze_into(&(th->params));

        var ret  = ReturnStmt::create(self.ctx, at, e);
        var body = CompoundStmt::create(self.ctx, at);
        var b = self.list_builder::<*Stmt>();
        b.push(static_cast::<*Stmt>(ret));
        b.freeze_into(&(body->body));
        th->body_block = body;

        f->init       = &null;                          // moved: one node, one parent.
        f->init_fold  = FieldFold::Thunk;
        f->init_thunk = static_cast::<*Decl>(th);
        return th;
    }

    /// A FunctionDecl with every field set, as CallLowering's thunks are.
    priv fn _new_fn(self, at: SourceRange, name: Token, parent: *DeclContext) -> *FunctionDecl {
        var n = self.ctx->alloc::<FunctionDecl>();
        libcxx::memset(static_cast::<*void>(n), 0, sizeof(FunctionDecl));
        n->kind  = DeclKind::FunctionDecl;
        n->range = at;
        n->name  = name;
        n->init_annotations(&(self.ctx->ast_alloc));
        n->init_dc(DeclContextKind::Function, self.ctx, parent, static_cast::<*Decl>(n));
        n->init_redecl();
        n->params          = create_empty_frozen_list::<*ParamDecl>();
        n->generic_params  = create_empty_frozen_list::<*GenericParamDecl>();
        n->op_token        = create_empty_frozen_list::<Token>();
        n->spec_args       = create_empty_frozen_list::<*Type>();
        n->abi             = AbiKind::None;
        n->modifiers       = FnModifier::None;
        n->body_kind       = FnBodyKind::Block;
        n->spec_kind       = SpecKind::None;
        n->requires_clause = &null;
        n->where_clause    = &null;
        n->qualifier       = &null;
        return n;
    }
}

__inline_cpp("
#undef ASTWriter_FieldInitLowering
");
