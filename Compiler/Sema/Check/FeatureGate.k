/// --- The Kairo Project --------------------- Sema/Check/FeatureGate.k --- ///
///
/// Reports constructs that type-check but have no lowering yet,
/// as one error each: "<construct> is not yet supported" (SC116E).
///
///   \detail
///     A lowering pass has no diagnostics of its own: by the time it runs,
///     every rejection has been made, and what it cannot render it ICEs on.
///     That is right for an invariant and wrong for a feature that is
///     simply unfinished, because lowering also runs under
///     --type-check-only and a well-typed program then aborts the compiler.
///     This pass is where "unfinished" is said to the user. An error here
///     stops the schedule before the lowerings, so the ICE in the lowering
///     stays an invariant: reaching it means this gate has a hole.
///
///     Gated:
///       - `for x in e` where X classified `e` as Vector, Set, Map or
///         String (RangedForStmt::iter_kind). IterLowering renders the
///         other kinds.
///       - `label!` / `jump!` in user code: EmitIR renders them (they are the
///         lowerings' labels and gotos), but nothing yet proves a user jump
///         crosses no initialization, which C++ rejects and Kairo must
///         report first.
///       - a non-generic ADT enum one of whose lifecycle facts is Unknown (a
///         payload that is an instance of a generic record reads its
///         pattern's facts until they are computed per instance):
///         EnumLayoutLowering picks its special members from those facts.
///         Reported at the enum, with a note at the payload field that left
///         the fact open.
///       - an initializer on an eval array-typed field.
///         FieldInitLowering turns every other one into a C++ default member
///         initializer (or, for a static or eval field, the initializer of
///         its out-of-line definition), an array's one thunk per leaf
///         element; an eval field's constexpr definition is written after a
///         single consteval thunk, so an eval array keeps its initializer
///         and codegen would ICE on it.
///       - a generic record's field default that reads another field.
///         InitCheck reports it (SC116E too): it is the pass that walks what
///         a default reads.
///       - `var {a, b} = s`, destructuring a struct by field name.
///         TupleLowering renders the positional form only; a struct's
///         reaching EmitIR is its ICE.
///       - an attribute applied to an expression (`@align(16) x`,
///         AttributedExpr): it parses, but no attribute has an expression
///         meaning yet. X leaves the node and its operand untyped. The
///         exception is the allocation attributes (`@create`, `@free`,
///         ...), which AllocSugarDesugar rewrote to alloc.k calls before
///         N; one left here matches no overload (`@create x`, `@create
///         T(args).m`, `@alloc(size: 8)`), and is reported as that misuse
///         (SC364E for the operand, SC365E for the arguments), not as a
///         feature to come.
///       - an `eval for` directly in a module or class body
///         (EvalBlockDecl::stmt): it parses, but nothing unrolls it there.
///         (An `eval if` there is folded away by EvalIfFolding.)
///       - a requirement called through the interface itself (`p->m()`
///         with `p: *Iface`, virtual interface dispatch): ExtensionLowering
///         renders requirement calls through a dependent Self only.
///       - a generic closure, `fn <T>(x: T) -> T { ... }`. X types neither
///         its parameters (no canonical for `T`) nor a call of it, so there
///         is no signature for EmitIR to spell; a C++ generic lambda is the
///         target once both are typed.
///       - a `fn`, class, struct, union or enum declared in a body that
///         names a generic parameter of a declaration around it (the
///         function's `T`, or its class's). Codegen emits a local
///         declaration at namespace scope (Speller::is_hoisted_local),
///         where that parameter is not in scope; it would have to become a
///         template over it, and every use in the body pass it. One that
///         names no outer parameter -- generic in its own right or not --
///         is emitted, in a generic function as anywhere else.
///       - an `extend` in a body: nothing emits one there.
///       - a `spawn e` or `thread e` expression: no async lowering exists, and
///         EmitIR ICEs on both. (A `thread` variable is thread-local storage,
///         a declaration, and is compiled.)
///
///       - a context binding (`x as var r { }`), a
///         `test` block, an `ffi` block in a function body, and a pack
///         expansion over a pattern (`Box<T>...`): nothing lowers or emits
///         them.
///
///     Reads the same guard IterLowering does: a poisoned or untyped
///     iterable is already diagnosed or dependent, and is not reported.
///
///     A gate is removed together with the lowering it guards.
///
///   Phase: CHECKS (last; needs X's iter_kind)
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ----------------------------------------------------------------- ///

import AST::DeclFacts::{
    decl_generic_params,
    decl_is_instance,
    decl_name_tok,
}
import AST::Kind::TypeKind::TypeKind
import AST::LangItems::LangAttrs
import AST::Node::Base::{
    Decl,
    Type,
}
import AST::Node::CanonicalNodes::RecordType
import AST::Node::CanonicalNodes::canon_unqual
import AST::Node::Casting::{
    cast,
    dyn_cast,
    isa,
}
import AST::Node::Declarations::{
    ClassDecl,    EnumDecl,         EvalBlockDecl, ExtensionDecl, FFIBlockDecl, FieldDecl,
    FunctionDecl, GenericParamDecl, InterfaceDecl, ParamDecl,     StructDecl,   TestDecl,
    UnionDecl,    VariableDecl,
}
import AST::Node::Expressions::{
    AlignOfExpr, AnonInitializerExpr, AttributedExpr, CallExpr, ClosureExpr, NamedInitializerExpr,
    SizeOfExpr,  SpawnExpr,           ThreadExpr,
}
import AST::Node::PrimaryExpressions::{
    ChainExpr,
    NamedIdentExpr,
}
import AST::Node::Statements::{
    ConditionalStmt,       ContextBindingStmt, DeclStmt, DestructureKind,
    DestructuringDeclStmt, EvalBlockStmt,      IterKind, JumpIntrinsicStmt,
    LabelIntrinsicStmt,    RangedForStmt,
}
import AST::Node::Types::{
    ChainType,
    FixedArrayType,
    GenericParamType,
    NullableType,
    PackExpansionType,
    PointerType,
}
import AST::Visitor::RecursiveASTVisitor::RecursiveASTVisitor
import Diagnostic::Code::DiagCode
import Diagnostic::Registry::DiagID
import Location::SourceRange::SourceRange
import Sema::Check::Attribute::AttributeCheck
import Sema::Check::CallConv::call_conv_of_attr
import Sema::Check::ClassLifecycle::{
    lifecycle_of,
    lifecycle_open,
}
import Sema::Expand::AllocAttrTable::{
    ALLOC_KW_IN,
    AllocAttr,
    AllocAttrTable,
    AllocAttrUse,
    AllocMismatch,
    AllocNode,
}
import Sema::Resolve::NameLookup::NameLookup
import Sema::SemaContext::SemaContext
import Sema::Type::TypeUtil::TypeUtil

/// The first generic parameter `local` names that belongs to a declaration
/// AROUND it, not to `local` or to anything declared in it. Types (a
/// written `T`, `*T`, `Box<T>`: every node the walk reaches, by its
/// canonical) and value parameters (a bare `N`) both count.
pub class OuterGenericScan derives RecursiveASTVisitor<OuterGenericScan> {
    pub var local: unsafe *Decl             = &null
    pub var hit:   unsafe *GenericParamDecl = &null

    fn OuterGenericScan(self) { }

    /// `owner` is `local` itself or declared somewhere inside it.
    priv fn _inside(self, owner: unsafe *Decl) -> bool {
        var unsafe *d = owner
        while d != &null {
            if d == self.local {
                return true
            }

            var unsafe *dc = d->semantic_dc
            if dc == &null {
                return false
            }

            d = dc->dc_owner
        }

        return false
    }

    priv fn _check(self, gp: unsafe *GenericParamDecl) {
        if gp == &null || self.hit != &null {
            return
        }

        if self._inside(gp->owner) {
            return
        }

        self.hit = gp
    }

    fn visit_type(self, t: unsafe *Type) -> bool {
        if t == &null || self.hit != &null {
            return true
        }

        var unsafe *c = if (t->canonical != &null) => (t->canonical) else => t
        var unsafe *g = dyn_cast<GenericParamType>(c)
        if g == &null || g->owner == &null {
            return true
        }

        var ps = decl_generic_params(g->owner)
        var i  = (g->param_index as usize)
        if i < ps.size() {
            self._check(ps[i])
        }

        return true
    }

    fn visit_named_ident_expr(self, n: unsafe *NamedIdentExpr) -> bool {
        if n != &null && n->resolved_decl != &null {
            self._check(dyn_cast<GenericParamDecl>(n->resolved_decl))
        }

        return true
    }
}

pub class FeatureGateCheck derives RecursiveASTVisitor<FeatureGateCheck> {
    pub var sc: unsafe *SemaContext
    /// Inside an interface's own declaration: its requirements' signatures
    /// name the interface as `Self`, the conformer.
    var _in_iface: u32 = 0

    fn FeatureGateCheck(self, sc: unsafe *SemaContext) {
        self.sc = sc
    }

    fn run(self) {
        var unsafe *tu = self.sc->tu
        if tu == &null {
            return
        }

        if tu->program == &null {
            return
        }

        self.run(tu)
    }

    fn visit_ranged_for_stmt(self, n: *RangedForStmt) -> bool {
        if n->iterable == &null {
            return true
        }

        if n->iterable->is_poisoned() || n->iterable->type_ == &null {
            return true
        }

        // IterLowering counts an array by its extent, which for `[T; N]` over
        // a generic value parameter is the parameter (Compiler/Spec/Eval.md#generic-value-parameters).
        var unsafe *at = canon_unqual(n->iterable->type_)
        if at != &null
            && isa<FixedArrayType>(at)
            && cast<FixedArrayType>(at)->extent_param != &null {
            self._gate(
                n->iterable->range,
                "iterating an array whose length is a generic value parameter",
            )

            return true
        }

        var what = ""
        match n->iter_kind {
            case IterKind::Vector {
                what = "iterating a vector"
            } case IterKind::Set {
                what = "iterating a set"
            } case IterKind::Map {
                what = "iterating a map"
            } case IterKind::String {
                what = "iterating a string"
            } default {
                return true
            }
        }

        var b = self.sc->diag->report(
            DiagID::SC116E,
            n->iterable->range.start,
            f"{what} is not yet supported",
        )

        b.first(n->iterable->range)
        b.emit()
        return true
    }

    fn visit_destructuring_decl_stmt(self, n: *DestructuringDeclStmt) -> bool {
        if n->kind_ == DestructureKind::Struct {
            self._gate(n->range, "destructuring a struct by field name")
        }

        return true
    }

    /// `p->m(x)` with `p: *Iface`: a requirement called through the
    /// interface itself, which is runtime dispatch through a virtual
    /// interface's witness table (interfaces.mdx, "Virtual Interfaces").
    /// ExtensionLowering renders a requirement call only through a
    /// dependent Self (a bounded parameter or an associated type) and ICEs
    /// on this one; nothing builds the table yet. Reported at the
    /// member step; a `::` call keeps its own path.
    fn visit_call_expr(self, n: *CallExpr) -> bool {
        var        tu  = TypeUtil(self.sc)
        var unsafe *ch = dyn_cast<ChainExpr>(tu.strip_parens(n->callee))
        if ch == &null || ch->steps.size() == 0 {
            return true
        }

        var unsafe *st = ch->steps.get(ch->steps.size() - 1)
        if st->access_kind == ChainExpr::AccessKind::ColonColon {
            return true
        }

        var unsafe *f = dyn_cast<FunctionDecl>(st->resolved_decl)
        if f == &null || f->semantic_dc == &null {
            return true
        }

        var unsafe *home = (f->semantic_dc)->owner_decl()
        if home == &null || !isa<InterfaceDecl>(NameLookup::representative(home)) {
            return true
        }

        var rt: unsafe *Type = &null
        if ch->steps.size() == 1 {
            if ch->base != &null {
                rt = ch->base->type_
            }
        } else {
            rt = ch->steps.get(ch->steps.size() - 2)->resolved_type
        }

        if rt == &null {
            return true
        }

        rt = canon_unqual(rt)
        if st->access_kind == ChainExpr::AccessKind::Arrow {
            rt = tu.pointee(rt)
            if rt == &null {
                return true
            }

            rt = canon_unqual(rt)
        }

        if !isa<RecordType>(rt) {
            return true
        }

        var unsafe *rd = cast<RecordType>(rt)->decl
        if rd != &null && isa<InterfaceDecl>(NameLookup::representative(rd)) {
            self._gate(
                st->range,
                "a call through an interface pointer (virtual interface dispatch)",
            )
        }

        return true
    }

    fn visit_closure_expr(self, n: *ClosureExpr) -> bool {
        if n->generic_params.size() > 0 {
            self._gate(
                SourceRange::from_bounds(n->range.start, 2 as u32),
                "a generic closure",
            )
        }

        return true
    }

    fn visit_attributed_expr(self, n: *AttributedExpr) -> bool {
        var nm = self.sc->ctx->get_spelling(n->name)
        // AllocSugarDesugar rewrote every allocation attribute a row of
        // AllocAttrTable takes, so one still here is written wrong.
        if LangAttrs::is_alloc_attr(nm) {
            self._alloc_misuse(n, nm)
            return true
        }

        // A calling convention on a closure is an error of its own, with
        // its reason (CallConvCheck), not a feature still to come.
        if n->operand != &null && isa<ClosureExpr>(n->operand) && call_conv_of_attr(nm) != 0 {
            return true
        }

        self._gate(
            SourceRange::from_bounds(n->range.start, 1 as u32) | n->name.range,
            f"the expression attribute '@{nm}'",
        )

        return true
    }

    /// An `eval for` directly in a module or class body parses
    /// (EvalBlockDecl::stmt), but nothing unrolls it into declarations:
    /// nothing would emit it. Reported at `eval for`; the statement's
    /// contents are still resolved and typed. An `eval if` there never gets
    /// here: EvalIfFolding replaced its carrier by the taken declarations.
    fn visit_eval_block_decl(self, n: *EvalBlockDecl) -> bool {
        if n->stmt == &null {
            return true
        }

        var what = "an 'eval for'"
        if isa<ConditionalStmt>(n->stmt) {
            what = "an 'eval if'"
        }

        self._gate(
            SourceRange::from_bounds(n->range.start, 4 as u32),
            f"{what} in a module or class body",
        )

        return true
    }

    /// `eval { ... }` in a function body: no meaning is built for it (a
    /// module or class body's eval block holds declarations, which are
    /// emitted as any others).
    fn visit_eval_block_stmt(self, n: *EvalBlockStmt) -> bool {
        self._gate(
            SourceRange::from_bounds(n->range.start, 4 as u32),
            "an 'eval' block in a function body",
        )

        return true
    }

    /// `Box<T>...`: a pack expansion over a pattern. Only a bare pack
    /// (`T...`, `Box<T...>`) is expanded; no pass maps a pattern over the
    /// elements.
    fn visit_pack_expansion_type(self, n: *PackExpansionType) -> bool {
        var unsafe *c = dyn_cast<ChainType>(n->pattern)
        if c != &null && !c->is_simple() {
            self._gate(n->range, "a pack expansion over a pattern")
        }

        return true
    }

    /// `x as var r { ... }`: no lowering binds the context's enter/exit.
    fn visit_context_binding_stmt(self, n: *ContextBindingStmt) -> bool {
        self._gate(n->range, "a context binding ('as var')")
        return true
    }

    /// `test "name" { ... }`: no test runner collects or emits it.
    fn visit_test_decl(self, n: *TestDecl) -> bool {
        self._gate(n->range, "a 'test' block")
        return true
    }

    /// Reported at the keyword; the operand is still typed and checked.
    fn visit_spawn_expr(self, n: *SpawnExpr) -> bool {
        self._gate(
            SourceRange::from_bounds(n->range.start, 5 as u32),
            "a 'spawn' expression",
        )

        return true
    }

    fn visit_thread_expr(self, n: *ThreadExpr) -> bool {
        self._gate(
            SourceRange::from_bounds(n->range.start, 6 as u32),
            "a 'thread' expression",
        )

        return true
    }

    fn visit_label_intrinsic_stmt(self, n: *LabelIntrinsicStmt) -> bool {
        self._gate(n->range, "'label!'")
        return true
    }

    fn visit_jump_intrinsic_stmt(self, n: *JumpIntrinsicStmt) -> bool {
        self._gate(n->range, "'jump!'")
        return true
    }

    /// A non-generic ADT has no flags for clang to pick its special members
    /// by: EnumLayoutLowering picks one form of each from its lifecycle
    /// facts, and ICEs when one of them is Unknown. A generic ADT leaves the
    /// choice to clang and is never reported. Asked once per entity, as the
    /// lowering builds once: an instance shares its pattern's record, and a
    /// redeclaration is its representative's.
    fn visit_enum_decl(self, n: *EnumDecl) -> bool {
        if !n->is_adt && !n->is_poisoned() && n->generic_params.size() > 0 {
            self._generic_plain_enum(n)
            return true
        }

        if !n->is_adt || n->is_poisoned() || n->generic_params.size() > 0 {
            return true
        }

        var unsafe *d = unsafe (n as unsafe *Decl)
        if decl_is_instance(d) || NameLookup::representative(d) != d {
            return true
        }

        var unsafe *lc = lifecycle_of(self.sc)
        if !lifecycle_open(lc->facts_of(d)) {
            return true
        }

        var b = self.sc->diag->report(
            DiagID::SC116E,
            n->name.range.start,
            "an enum whose payload's lifecycle is not known until instantiation is not yet supported",
        )

        b.first(n->name.range)
        // The first payload field whose own facts are open: the generic
        // instance the enum's copy, move and destruction wait on.
        var tu    = TypeUtil(self.sc)
        var noted = false
        for var i: usize = 0; i < n->variants.size(); ++i {
            if noted {
                break
            }

            var unsafe *v = n->variants[i]
            if v == &null {
                continue
            }

            for var j: usize = 0; j < v->payload.size(); ++j {
                var unsafe *fd = v->payload[j]
                if fd == &null || fd->type_ == &null || fd->type_->canonical == &null {
                    continue
                }

                var pf = lc->facts_of_type(fd->type_->canonical)
                if !lifecycle_open(unsafe &pf) {
                    continue
                }

                var fname = self.sc->ctx->get_spelling(fd->name)
                var vname = self.sc->ctx->get_spelling(v->name)
                var tn    = tu.str(fd->type_->canonical)
                b.note(
                    DiagCode(DiagID::SC116N),
                    fd->range.start,
                    f"'{fname}' of variant '{vname}' has type '{tn}', whose copy, move and destruction are not known until instantiation",
                )->child_first(fd->range)
                noted = true
                break
            }
        }

        b.emit()
        return true
    }

    /// The initializers FieldInitLowering leaves on the field (its file
    /// header, Not lowered). Reported at the initializer, once: an instance
    /// shares its pattern's fields.
    fn visit_field_decl(self, n: unsafe *FieldDecl) -> bool {
        self._no_interface_type(unsafe (n as unsafe *Decl), n->type_)
        if n->init == &null || n->is_poisoned() || n->init->is_poisoned() || n->type_ == &null {
            return true
        }

        var unsafe *odc = n->semantic_dc
        var unsafe *owner = if (odc != &null) => (odc->owner_decl()) else => &null
        if owner != &null && decl_is_instance(owner) {
            return true
        }

        // An instance or static array field's list literal is lowered leaf
        // by leaf (FieldInitLowering, Arrays), nested lists included; one
        // that copies an array is the typer's SC083E. What stays is an eval
        // array field: its constexpr definition follows one consteval thunk.
        var unsafe *c = canon_unqual(n->type_->canonical)
        if c == &null || c->kind != TypeKind::FixedArrayType {
            return true
        }

        var tu = TypeUtil(self.sc)
        if tu.array_field_list(n) != &null {
            return true
        }

        if tu.array_init_poisoned(n->init) {
            return true
        }

        var what = "an initializer on an array-typed field that is not a list literal"
        if n->is_eval() {
            what = "an initializer on an eval array-typed field"
        }

        self._gate(n->init->range, what)
        return true
    }

    /// # interfaces are not types

    fn traverse_interface_decl(self, n: unsafe *InterfaceDecl) -> unsafe *InterfaceDecl {
        self._in_iface += 1
        var unsafe *out = RecursiveASTVisitor<FeatureGateCheck>::traverse_interface_decl(
            self,
            n,
        )

        self._in_iface -= 1
        return out
    }

    /// An interface is a set of requirements, not a type of values
    /// (interfaces.mdx): none is spelled in C++ except as a witness's Self,
    /// so one written where a value's type goes is reported here, before
    /// codegen would have to spell it. Through a pointer it is virtual
    /// interface dispatch, which is not compiled yet.
    fn visit_variable_decl(self, n: unsafe *VariableDecl) -> bool {
        self._no_interface_type(unsafe (n as unsafe *Decl), n->type_)
        return true
    }

    fn visit_param_decl(self, n: unsafe *ParamDecl) -> bool {
        if !n->is_self {
            self._no_interface_type(unsafe (n as unsafe *Decl), n->type_)
        }

        return true
    }

    fn visit_function_decl(self, n: unsafe *FunctionDecl) -> bool {
        self._no_interface_type(unsafe (n as unsafe *Decl), n->return_type)
        return true
    }

    fn visit_size_of_expr(self, n: *SizeOfExpr) -> bool {
        self._no_interface_type(&null, n->type_arg)
        return true
    }

    fn visit_align_of_expr(self, n: *AlignOfExpr) -> bool {
        self._no_interface_type(&null, n->type_arg)
        return true
    }

    /// `f<Iface>()`, `__builtin_is_trivially_copyable<Iface>()`: a generic
    /// argument is a type its instance is spelled with.
    fn visit_named_ident_expr(self, n: *NamedIdentExpr) -> bool {
        for var i: usize = 0; i < n->generic_args.size(); ++i {
            self._no_interface_type(&null, n->generic_args.get(i)->ty)
        }

        return true
    }

    fn visit_chain_expr(self, n: *ChainExpr) -> bool {
        for var i: usize = 0; i < n->steps.size(); ++i {
            var unsafe *st = n->steps.get(i)
            for var j: usize = 0; j < st->generic_args.size(); ++j {
                self._no_interface_type(&null, st->generic_args.get(j)->ty)
            }
        }

        return true
    }

    /// Reports `t` when it names an interface as a value type. `d` is the
    /// declaration `t` is written on, or null for an expression's type
    /// argument.
    priv fn _no_interface_type(self, d: unsafe *Decl, t: unsafe *Type) {
        if t == &null || t->is_poisoned() || t->canonical == &null || !t->range.is_valid() {
            return
        }

        if self._in_iface > 0 || d != &null && (d->is_poisoned() || d->is_implicit) {
            return
        }

        var via_ptr = false
        var unsafe *iface = self._interface_in(t->canonical, 0, unsafe &via_ptr)
        if iface == &null {
            return
        }

        var tu = TypeUtil(self.sc)
        var nm = tu.decl_name(unsafe (iface as unsafe *Decl))
        // Only a `virtual interface` has a pointer: dispatch through it is
        // not compiled yet. A plain interface has none at all.
        if via_ptr && iface->is_virtual {
            self._gate(
                t->range,
                f"a pointer to the interface '{nm}' (virtual interface dispatch)",
            )

            return
        }

        var msg = f"'{nm}' is an interface, not a type; it can only bound a generic parameter (`T impl {nm}`)"
        if via_ptr {
            msg = f"'{nm}' is an interface, not a type, and a plain interface has no pointer; bound a generic parameter (`T impl {nm}`), or declare it `virtual interface` for dispatch through a pointer"
        }

        var b = self.sc->diag->report(
            DiagID::SC332E,
            t->range.start,
            msg.copy(),
        )

        b.first(t->range)
        b.emit()
    }

    /// The interface `c` names as a value type, looking through pointers
    /// (`via_ptr` set), nullables, arrays and generic arguments.
    priv fn _interface_in(self,
                          c0:      unsafe *Type,
                          depth:   u32,
                          via_ptr: unsafe *bool) -> unsafe *InterfaceDecl {
        var unsafe *c = canon_unqual(c0)
        if c == &null || depth > 16 {
            return &null
        }

        var unsafe *p = dyn_cast<PointerType>(c)
        if p != &null {
            var unsafe *r = self._interface_in(p->pointee, depth + 1, via_ptr)
            if r != &null {
                *via_ptr = true
            }

            return r
        }

        var unsafe *n = dyn_cast<NullableType>(c)
        if n != &null {
            return self._interface_in(n->inner, depth + 1, via_ptr)
        }

        var unsafe *a = dyn_cast<FixedArrayType>(c)
        if a != &null {
            return self._interface_in(a->element, depth + 1, via_ptr)
        }

        var unsafe *rt = dyn_cast<RecordType>(c)
        if rt == &null || rt->decl == &null {
            return &null
        }

        var unsafe *rd = NameLookup::representative(rt->decl)
        if isa<InterfaceDecl>(rd) {
            return cast<InterfaceDecl>(rd)
        }

        for var i: usize = 0; i < rt->args.size(); ++i {
            var unsafe *r = self._interface_in(rt->args[i], depth + 1, via_ptr)
            if r != &null {
                return r
            }
        }

        return &null
    }

    /// # local declarations

    /// A local declaration that needs a generic parameter of a declaration
    /// around it: the first one it names is reported, at the local's name,
    /// with a note at that parameter.
    fn visit_decl_stmt(self, n: unsafe *DeclStmt) -> bool {
        if n == &null || n->decl == &null || n->decl->is_poisoned() || n->decl->is_implicit {
            return true
        }

        var unsafe *d = n->decl
        if isa<ExtensionDecl>(d) {
            self._gate(d->range, "an 'extend' in a function body")
            return true
        }

        if isa<FFIBlockDecl>(d) {
            self._gate(d->range, "an 'ffi' block in a function body")
            return true
        }

        if (!isa<FunctionDecl>(d))
            && (!isa<ClassDecl>(d))
            && (!isa<StructDecl>(d))
            && (!isa<UnionDecl>(d))
            && !isa<EnumDecl>(d) {
            return true
        }

        var scan = OuterGenericScan()
        scan.local = d
        scan.dispatch_decl(d)
        if scan.hit == &null {
            return true
        }

        var unsafe *gp = scan.hit
        var        tu  = TypeUtil(self.sc)
        var        gn  = self.sc->ctx->get_spelling(gp->name)
        var own = if (gp->owner == &null) => ("the declaration around it")
                  else => f"'{tu.decl_name(gp->owner)}'"
        var at = decl_name_tok(d).range
        if !at.is_valid() {
            at = d->range
        }

        var b = self.sc->diag->report(
            DiagID::SC116E,
            at.start,
            f"'{tu.decl_name(d)}' is declared in a body and uses '{gn}', a generic parameter of {own}; that is not yet supported",
        )

        b.first(at)
        b.note(
            gp->range.start,
            f"'{gn}' is declared here; a local declaration is emitted outside the generic function, where '{gn}' is not in scope -- declare it at file scope with its own '<{gn}>'",
        )

        b.emit()
        return true
    }

    /// `enum <T> Plain { A, B }`: enums-plain.mdx says a plain enum cannot be
    /// generic -- no variant carries a payload for T to type. Not a gate but
    /// the rule, reported here because nothing earlier rejects it: the parser
    /// takes generic parameters on any enum, and without this the C++ was a
    /// `template` head on an `enum class`, which clang refuses (six CL001E
    /// in generated code). Once per declaration: an instance shares its
    /// pattern's, and a redeclaration is its representative's.
    priv fn _generic_plain_enum(self, n: *EnumDecl) {
        var unsafe *d = unsafe (n as unsafe *Decl)
        if decl_is_instance(d) || NameLookup::representative(d) != d {
            return
        }

        var unsafe *first = n->generic_params[0]
        var unsafe *last  = n->generic_params[n->generic_params.size() - 1]
        if first == &null || last == &null {
            return
        }

        var params = SourceRange(first->range.start, last->range.end)
        var nm     = self.sc->ctx->get_spelling(n->name)
        var b = self.sc->diag->report(
            DiagID::SC197E,
            params.start,
            f"plain enum '{nm}' cannot be generic: no variant carries a payload for a type parameter to type",
        )

        b.first(params)
        b.note(
            DiagCode(DiagID::SC197N),
            n->name.range.start,
            "give a variant a payload to make it an ADT enum, or remove the generic parameters",
        )->child_first(n->name.range)
        b.emit()
    }

    /// The forms `attr` is written in, for a message.
    priv fn _alloc_forms(self, attr: AllocAttr) -> string {
        match attr {
            case AllocAttr::Create {
                return "'@create T(args)' or '@create T { field: value }'"
            } case AllocAttr::TryCreate {
                return "'@try_create T(args)' or '@try_create T { field: value }'"
            } case AllocAttr::Destroy {
                return "'@destroy p'"
            } case AllocAttr::Alloc {
                return "'@alloc T', '@alloc(count: n) T' or '@alloc(size: n, align: a)'"
            } case AllocAttr::AllocZeroed {
                return "'@alloc_zeroed(size: n, align: a)'"
            } case AllocAttr::Free {
                return "'@free p' or '@free(size: n, align: a) p'"
            } case AllocAttr::Resize {
                return "'@resize(size: old, new_size: n, align: a) p'"
            } case AllocAttr::TryResize {
                return "'@try_resize(size: old, new_size: n, align: a) p'"
            } case AllocAttr::COUNT {
                return ""
            }
        }
    }

    /// The keywords in `set`, each as `'name:'`, joined for a message.
    priv fn _alloc_kw_list(self, set: u8) -> string {
        var out  = ""
        var left = set
        while left != 0 {
            var b = AllocAttrTable::first_kw(left)
            if b == 0 {
                break
            }

            left = left & ~b
            if out.size() > 0 {
                out += if (left == 0) => (" and ") else => ", "
            }

            out += "'" + AllocAttrTable::kw_word(b) + ":'"
        }

        return out
    }

    /// An allocation attribute no row of AllocAttrTable takes: SC365E for
    /// its argument list (a positional argument, an unknown or repeated
    /// keyword, a set of keywords no form has), SC364E for the node it is
    /// applied to. The attribute applies to one unary expression, postfix
    /// chain included, so `@create T(args).m` allocates `T(args).m`; that
    /// one gets the parenthesized spelling as its fix-it.
    priv fn _alloc_misuse(self, n: *AttributedExpr, const nm: string) {
        var at = SourceRange::from_bounds(n->range.start, 1 as u32) | n->name.range
        var q = LangAttrs::quoted(nm)
        var u = AllocAttrTable::classify(
            self.sc->ctx,
            unsafe (n as unsafe *AttributedExpr),
        )

        match u.why {
            case AllocMismatch::Positional {
                self._alloc_positional(n, at, q, u)
            } case AllocMismatch::UnknownKw {
                self._alloc_unknown_kw(at, q, u)
            } case AllocMismatch::RepeatedKw {
                var kw = self.sc->ctx->get_spelling(u.repeated->name)
                var b = self.sc->diag->report(
                    DiagID::SC365E,
                    u.repeated->range.start,
                    q.copy() + " is given '" + kw + ":' twice",
                )

                b.first(u.repeated->range)
                if u.repeated_first != &null {
                    b.note(
                        DiagCode(DiagID::SC365N),
                        u.repeated_first->range.start,
                        "first given here",
                    )->child_first(u.repeated_first->range)
                }

                b.emit()
            } case AllocMismatch::InNotType {
                var vr = if (u.kw_in->value != &null) => (u.kw_in->value->range)
                         else => u.kw_in->range
                var b = self.sc->diag->report(
                    DiagID::SC365E,
                    vr.start,
                    "'in:' names the allocator, a type: " + q.copy() + " with 'in: A' allocates from, or frees to, A instead of the allocator in effect",
                )

                b.first(vr)
                b.emit()
            } case AllocMismatch::MissingKw {
                var have = u.kws & ~ALLOC_KW_IN
                var msg = q.copy() + " with " + self._alloc_kw_list(
                    have,
                ) + " also needs " + self._alloc_kw_list(u.missing)

                if have == 0 {
                    msg = q.copy() + " needs " + self._alloc_kw_list(u.missing)
                }

                var b = self.sc->diag->report(DiagID::SC365E, at.start, msg)
                b.first(at)
                b.note(
                    DiagCode(DiagID::SC365N),
                    at.start,
                    "it is written " + self._alloc_forms(u.attr),
                )

                b.emit()
            } case AllocMismatch::ExtraKw {
                var b = self.sc->diag->report(
                    DiagID::SC365E,
                    at.start,
                    q.copy() + " has no form that takes " + self._alloc_kw_list(
                        u.extra,
                    ) + " together",
                )

                b.first(at)
                b.note(
                    DiagCode(DiagID::SC365N),
                    at.start,
                    "it is written " + self._alloc_forms(u.attr),
                )

                b.emit()
            } case AllocMismatch::Node {
                self._alloc_node(n, at, q, nm, u)
            } case AllocMismatch::Ok {
                // A row takes it, so AllocSugarDesugar would have
                // rewritten it: only a tree it never walked gets here.
                self._gate(at, "this allocation attribute here")
            }
        }
    }

    /// An argument written without its keyword. `@create(A) T()` and
    /// `@destroy(A) p` keep the message they had before `in:` existed, with
    /// the keyword as a note; the fix-it names the allocator when the
    /// argument is a type.
    priv fn _alloc_positional(self,
                              n:       *AttributedExpr,
                              at:      SourceRange,
                              const q: string,
                              const u: AllocAttrUse) {
        var unsafe *arg = u.positional
        var        tu   = TypeUtil(self.sc)
        var unsafe *id  = dyn_cast<NamedIdentExpr>(arg)
        var is_type = n->args.size() == 1
            && id != &null
            && id->is_bound()
            && tu.is_type_decl(id->resolved_decl)
        if u.attr == AllocAttr::Create || u.attr == AllocAttr::Destroy {
            var text = q.copy() + " takes one pointer: '@destroy p' or '@destroy(p)'"
            if u.attr == AllocAttr::Create {
                text = q.copy() + " takes no attribute arguments: the type and its constructor arguments follow it, '@create T(args)' or '@create T { field: value }'"
            }

            var b = self.sc->diag->report(DiagID::SC364E, at.start, text)
            b.first(at)
            b.note(
                DiagCode(DiagID::SC364N),
                arg->range.start,
                "the one argument it takes is the allocator, by keyword: " + q.copy() + " with 'in: A'",
            )->child_first(arg->range)
            if is_type {
                b.insert(
                    arg->range.start,
                    "in: ",
                    "name the allocator with 'in:'",
                )
            }

            b.emit()
            return
        }

        var b = self.sc->diag->report(
            DiagID::SC365E,
            arg->range.start,
            q.copy() + " takes keyword arguments only: it is written " + self._alloc_forms(
                u.attr,
            ),
        )

        b.first(arg->range)
        if is_type {
            b.insert(arg->range.start, "in: ", "name the allocator with 'in:'")
        }

        b.emit()
    }

    /// A keyword no form of the attribute takes, with the closest one it
    /// does take as the fix-it.
    priv fn _alloc_unknown_kw(self, at: SourceRange, const q: string, const u: AllocAttrUse) {
        var kw      = self.sc->ctx->get_spelling(u.unknown->name)
        var allowed = AllocAttrTable::kws_of(u.attr) | ALLOC_KW_IN
        var b = self.sc->diag->report(
            DiagID::SC365E,
            u.unknown->name.range.start,
            q.copy() + " has no keyword argument '" + kw + ":'",
        )

        b.first(u.unknown->name.range)
        b.note(
            DiagCode(DiagID::SC365N),
            at.start,
            "it takes " + self._alloc_kw_list(allowed),
        )

        var best          = ""
        var best_d: usize = 0
        var left          = allowed
        while left != 0 {
            var bit = AllocAttrTable::first_kw(left)
            if bit == 0 {
                break
            }

            left = left & ~bit
            var w = AllocAttrTable::kw_word(bit)

            // An abbreviation (`sz`, `algn`) is its keyword with letters
            // left out, which an edit distance counts as far away.
            var d = if (self._is_subsequence(kw, w)) => (0 as usize)
                    else => AttributeCheck::edit_distance(kw, w)

            if best.size() == 0 || d < best_d {
                best   = w.copy()
                best_d = d
            }
        }

        if best.size() > 0 && best_d <= 2 && best_d < kw.size() {
            b.fix(u.unknown->name.range, best, "did you mean '" + best + ":'?")
        }

        b.emit()
    }

    /// True when `a`, at least two letters, is `b` with letters left out.
    priv fn _is_subsequence(self, const a: string, const b: string) -> bool {
        if a.size() < 2 || a.size() >= b.size() {
            return false
        }

        var i: usize = 0
        for var j: usize = 0; j < b.size() && i < a.size(); ++j {
            if a.data()[i] == b.data()[j] {
                i += 1
            }
        }

        return i == a.size()
    }

    /// The keywords pick a form, and the node it is applied to is of
    /// another kind.
    priv fn _alloc_node(self,
                        n:        *AttributedExpr,
                        at:       SourceRange,
                        const q:  string,
                        const nm: string,
                        const u:  AllocAttrUse) {
        var unsafe *opd = n->operand
        var        row  = AllocAttrTable::row(u.row as usize)
        if row.node == AllocNode::Type {
            var b = self.sc->diag->report(
                DiagID::SC364E,
                at.start,
                q.copy() + " allocates storage for a type and constructs nothing: its operand is the type, '@alloc T' or '@alloc(count: n) T'",
            )

            b.first(at)
            if opd != &null {
                b.note(
                    DiagCode(DiagID::SC364N),
                    opd->range.start,
                    "this is the operand; a type that is not a name is given one with 'type'",
                )->child_first(opd->range)

                // `@alloc T(args)`: the construction is `@create`'s.
                if AllocAttrTable::constructed_type(self.sc->ctx, opd) != &null {
                    b.fix(
                        n->name.range,
                        LangAttrs::create(),
                        "to construct the object as well, write " + LangAttrs::quoted(
                            LangAttrs::create(),
                        ),
                    )
                }
            }

            b.emit()
            return
        }

        if row.node != AllocNode::Construction {
            // A Value node takes any expression and a None node is never
            // given one by the parser.
            var b = self.sc->diag->report(
                DiagID::SC364E,
                at.start,
                q.copy() + " is written " + self._alloc_forms(u.attr),
            )

            b.first(at)
            b.emit()
            return
        }

        var unsafe *ch = if (opd != &null && isa<ChainExpr>(opd)) => (cast<ChainExpr>(
                             opd,
                         ))
                         else => &null
        if ch != &null
            && ch->base != &null
            && (isa<CallExpr>(ch->base) || isa<NamedInitializerExpr>(ch->base))
            && ch->steps.size() > 0 {
            var unsafe *st = ch->steps.get(0)
            var        dot = st->access_kind == ChainExpr::AccessKind::Dot
            if dot || st->access_kind == ChainExpr::AccessKind::Arrow {
                var b = self.sc->diag->report(
                    DiagID::SC364E,
                    at.start,
                    q.copy() + " applies to the whole member access after it; a member of the object it creates is reached through parentheses: '(@" + nm + " T(args))->member'",
                )

                b.first(at)
                b.note(
                    DiagCode(DiagID::SC364N),
                    st->range.start,
                    "this member access is part of the operand",
                )->child_first(st->range)
                b.insert(n->range.start, "(", "parenthesize the allocation")
                b.insert(
                    ch->base->range.end,
                    ")",
                    "parenthesize the allocation",
                )

                if dot {
                    b.fix(
                        SourceRange::from_bounds(st->range.start, 1 as u32),
                        "->",
                        "the result is a pointer: reach its member with '->'",
                    )
                }

                b.emit()
                return
            }
        }

        var headless = opd != &null
            && (isa<AnonInitializerExpr>(opd)
                || (isa<NamedInitializerExpr>(opd)
                    && cast<NamedInitializerExpr>(opd)->type_expr == &null))
        var msg = q.copy() + " allocates and constructs one object: its operand is a construction, 'T(args)' or 'T { field: value }'"
        if headless {
            msg = q.copy() + " needs the type it allocates: write '@" + nm + " T { field: value }'"
        }

        var b = self.sc->diag->report(DiagID::SC364E, at.start, msg)
        b.first(at)
        if opd != &null {
            b.note(
                DiagCode(DiagID::SC364N),
                opd->range.start,
                "this is the operand",
            )->child_first(opd->range)
        }

        b.emit()
    }

    priv fn _gate(self, at: SourceRange, const what: string) {
        var b = self.sc->diag->report(
            DiagID::SC116E,
            at.start,
            f"{what} is not yet supported",
        )

        b.first(at)
        b.emit()
    }
}
