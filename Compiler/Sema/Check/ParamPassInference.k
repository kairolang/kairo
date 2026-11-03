/// --- The Kairo Project ----------------- Sema/Check/ParamPassInference.k --- ///
///
///   \brief A by-value parameter its function never mutates is passed as
///          `const T&`, and warned to say `const` (P331).
///
///   \detail
///     `fn f(s: string)` was `f(::builtin::string::string s)`: every call
///     deep-copied an owned string, and the callee only ever read it. A
///     `const s: string` was already `const T&` (CXXSpell::_param_type), so
///     a parameter whose body could have been written with `const` is
///     treated as if it had been, and the warning says to write it:
///
///         fn f(s: string) -> usize { return s.length() }
///              ^ parameter 's' is never mutated; declare it 'const'
///
///     The decision is a function of the function's OWN declaration and
///     body, nothing else: every TU that spells the signature (the
///     definition, an importer's preamble, a header, `#include "foo.k"` in
///     another run) reads the same `ParamDecl::inferred_const`, so the
///     declaration and the definition cannot disagree. Who takes the
///     function's address does not enter into it; a `fn` value of such a
///     function goes through an adapter instead (EmitIR::_fn_ref_adapter).
///
///   \par Which parameters
///     Mode by value (not `@inout` / `@move`), not `self`, not already
///     `const`, not a pack, named, of a concrete RECORD type whose category
///     is COPY and which is not trivially copyable: a string, a vector, a
///     map, a class with a copy constructor. A MOVE record keeps its value
///     (taking ownership is the point of the parameter); a trivially
///     copyable record keeps it too (a register pair beats a pointer, and
///     Sema has no record layout yet for a size threshold); a scalar, a
///     pointer and a `fn` value are never records. CODEGEN.md 4 has the
///     rule as codegen sees it.
///
///   \par Which functions
///     A Kairo body this TU defines, written by the user (not implicit,
///     not lowering-minted), and none of:
///       - generic, or in a generic record / extension: an instance's
///         explicit instantiation and the pattern would have to agree on
///         a fact only the pattern's body decides;
///       - `virtual`, `override`, `= virtual`, or a method of a class that
///         derives from a polymorphic base: the signature is the base's,
///         and C++ would hide the slot instead of overriding it;
///       - an interface member (a requirement, or its default body);
///       - `ffi "c"` / `ffi "c++"` linkage, or a calling convention: the
///         C signature is the contract;
///       - a generator or `async` function: the frame outlives the call,
///         and a reference parameter would dangle in it;
///       - `-> !` and `@cold_path`: the cold edge, where the copy is paid
///         at most once and the caller-held temporary a reference needs
///         is one more cleanup on every crash path;
///       - a transfer constructor, a split constructor (CtorInitLowering's
///         slots carry the parameters), a `where` dispatch member, an
///         allocator operator, an ADT's generated member, `eval`, `main`.
///
///   \par "Never mutated"
///     Decided over the LOWERED tree, the one EmitIR renders, so every use
///     C++ will see is a use this pass saw: a lowering's `x as T&&` move, an
///     operator turned into a method call, an iterator call. The rule is a
///     whitelist: each reference to the parameter must be approved by the
///     node that consumes it, and one unapproved reference keeps the copy.
///     Approved (all of them reads):
///       - the receiver of a call to a `const self` method (or a static one);
///       - an argument to a by-value or `const` parameter, Kairo or C++ (a
///         C++ `const T&` too); never to `@inout`, `@move`, a C++ `T&` /
///         `T&&`, or a type pack's forwarding `T&&...`;
///       - an operand of a builtin operator (not `&`, `++`, `--`, `.*`);
///       - the right side of an assignment; an initializer of a local that
///         is not a reference (`place_ref`) or a raw slot;
///       - a condition, an `assert`, a cast to a non-reference type, an
///         element of an initializer list, tuple or variant payload;
///       - `return p.f` (a member: C++ copies it either way).
///     Reaching the parameter goes through parens, `.field` / `.0` steps
///     and fixed-array subscripts (all of them the parameter's own
///     storage); a step through a pointer (`p.ptr->x`) leaves it, so what
///     happens after that is to the pointee and the read of `p.ptr` is
///     approved. Not approved, so mutated: an assignment, `++`, `&p` /
///     `&p.f`, a call to a non-const method (a non-const `op []` included:
///     P338's mutable `[]` is the one picked for a non-const receiver),
///     `return p` (C++ moves a by-value parameter out; a `const&` would
///     copy), any use inside a closure, and any node not listed above.
///
///   \par Aliasing
///     A `const T&` parameter sees writes to the object it was passed from
///     for as long as the call runs, which a by-value copy did not:
///     `x.replace(x.data)` whose body clears `self.data` before reading the
///     argument now reads the cleared string. That is the documented
///     meaning of `const x: T` (functions.mdx, Parameters), and the warning
///     asks for exactly that spelling; the inference adds no case explicit
///     `const` does not already have.
///
///   \par Library code
///     Inferred in builtin and std like anywhere (the copy costs the same
///     there), but the warning is the user's: a library file is not one
///     the user can edit (FlagGates::_library_tu's test).
///
///   SC001W is the placeholder until the monthly sweep gives the lint a code.
///
///   Phase: LOWER, after StringLowering (the last lowering): reads the tree
///   EmitIR will render, writes ParamDecl::inferred_const, read only by
///   codegen (CXXSpell::_param_type, EmitIR::_fn_ref_adapter), which runs
///   after every TU's Sema.
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
import Sema::Check::ClassLifecycle::*;
import AST::Context::ASTContext::*;
import AST::Context::DeclContext::*;
import AST::Context::TranslationUnit::*;
import AST::ASTSupport::*;
import AST::DeclFacts::*;
import AST::ParamMode::*;
import AST::Mixin::FFILinkage::*;
import AST::Node::Base::*;
import AST::Node::Program::*;
import AST::Node::PrimaryExpressions::*;
import AST::Node::Expressions::*;
import AST::Node::Statements::*;
import AST::Node::Declarations::*;
import AST::Node::Types::*;
import AST::Node::CanonicalNodes::*;
import AST::Node::Casting::*;
import AST::Kind::TypeKind::*;
import AST::Visitor::RecursiveASTVisitor::*;
import Location::SourceRange::*;
import Token::Token::*;
import Token::TokenKind::*;
import Diagnostic::Registry::*;

///
/// \class ParamPassInference
/// \brief The pass. Writes ParamDecl::inferred_const; warns SC001W.
///
class ParamPassInference derives RecursiveASTVisitor::<ParamPassInference> {
    pub var sc: *SemaContext;
    priv var _tu: TypeUtil;
    /// Candidates of every function being walked (a local `fn` nests one
    /// walk inside another), and per candidate: its references seen, the
    /// references approved, the closure depth it was declared at, and
    /// whether a use inside a closure already ruled it out.
    priv var _cand:  vec::<*ParamDecl>;
    priv var _refs:  vec::<usize>;
    priv var _oks:   vec::<usize>;
    priv var _depth: vec::<usize>;
    priv var _bad:   vec::<bool>;
    /// ParamDecl -> its index in _cand, plus one.
    priv var _index: llvm::DenseMap::<u64, usize>;
    /// The references an approving node has claimed: one approval each.
    priv var _approved: llvm::DenseSet::<u64>;
    /// Return types of the functions being walked, innermost last.
    priv var _ret: vec::<*Type>;
    priv var _closures: usize = 0;
    priv var _library: bool = false;
    pub var n_inferred: usize = 0;

    fn ParamPassInference(self, sc: *SemaContext) {
        self.sc  = sc;
        self._tu = TypeUtil(sc);
    }

    fn run(self) {
        var tu = self.sc->tu;
        if tu == &null { return; }
        if tu->program == &null { return; }
        self._library = self._library_tu();

        var items = &(tu->program->items);
        for var i: usize = 0; i < items->size(); ++i {
            if self.stop { break; }
            var item = *(items->get(i));
            switch item.get_kind() {
                case TopLevelKind::Decl { self.dyn()->dispatch_decl(item.as_decl()); }
                case TopLevelKind::Stmt { self.dyn()->dispatch_stmt(item.as_stmt()); }
                case TopLevelKind::Expr { self.dyn()->dispatch_expr(item.as_expr()); }
            }
        }
    }

    /// The test FlagGates uses: builtin by fid, std by its directory.
    priv fn _library_tu(self) -> bool {
        var fid = self.sc->ctx->fid;
        if (self.sc->g != &null) && self.sc->g->is_builtin_fid(fid) { return true; }
        var ci = self.sc->ctx->ci;
        if (ci == &null) || (self.sc->ctx->sm == &null) { return false; }
        var root = ci->pp.std_dir;
        if root.empty() && (!ci->target.resource_dir.empty()) { root = ci->target.resource_dir + "/std"; }
        if root.empty() { return false; }
        if !root.ends_with("/") { root += "/"; }
        return self.sc->ctx->sm->get_filename(fid).starts_with(root);
    }

    // === functions ===========================================================

    fn traverse_function_decl(self, n: *FunctionDecl) -> *FunctionDecl {
        if n == &null { return n; }
        var first = self._cand.size();
        var eligible = self._eligible_fn(n);
        if eligible {
            for var i: usize = 0; i < n->params.size(); ++i {
                var p = n->params[i];
                if !self._eligible_param(p) { continue; }
                self._cand.push_back(p);
                self._refs.push_back(0);
                self._oks.push_back(0);
                self._depth.push_back(self._closures);
                self._bad.push_back(false);
                self._index[reinterpret_cast::<u64>(p)] = self._cand.size();
            }
        }
        self._ret.push_back(n->return_type);
        var out = RecursiveASTVisitor::<ParamPassInference>::traverse_function_decl(n);
        self._ret.pop_back();
        // Decide this function's candidates, then drop them: a reference to
        // one can only be in its own body.
        while self._cand.size() > first {
            var k = self._cand.size() - 1;
            var p = self._cand[k];
            var unmutated = (!self._bad[k]) && (self._oks[k] == self._refs[k]);
            if unmutated { self._infer(n, p); }
            self._index.erase(reinterpret_cast::<u64>(p));
            self._cand.pop_back();
            self._refs.pop_back();
            self._oks.pop_back();
            self._depth.pop_back();
            self._bad.pop_back();
        }
        return out;
    }

    fn traverse_closure_expr(self, n: *ClosureExpr) -> *ClosureExpr {
        self._closures += 1;
        var out = RecursiveASTVisitor::<ParamPassInference>::traverse_closure_expr(n);
        self._closures -= 1;
        return out;
    }

    /// Stamp \p p, and the same parameter of every other link of \p f's
    /// redeclaration chain (an out-of-line definition's declaration spells
    /// the signature in the class), then warn.
    priv fn _infer(self, f: *FunctionDecl, p: *ParamDecl) {
        var idx = usize(p->index);
        var head = f->first_decl();
        var cur = head;
        var guard: usize = 0;
        while (cur != &null) && (guard < 64) {
            if idx < cur->params.size() {
                var q = cur->params[idx];
                if q != &null { q->inferred_const = true; }
            }
            cur = cur->next_in_chain();
            guard += 1;
            if cur == head { break; }
        }
        p->inferred_const = true;
        self.n_inferred += 1;
        if self._library { return; }
        var nm = self.sc->ctx->get_spelling(p->name);
        var b = self.sc->diag->report(DiagID::SC001W, p->name.range.start, f"parameter '{nm}' is never mutated; declare it 'const\x27");
        b.first(p->name.range);
        b.insert(p->name.range.start, "const ", f"make '{nm}' const");
        b.emit();
    }

    priv fn _eligible_fn(self, f: *FunctionDecl) -> bool {
        if f->is_implicit || f->is_poisoned() { return false; }
        if f->body_kind != FnBodyKind::Block { return false; }
        if f->body_block == &null { return false; }
        if f->is_imported() || (f->ffi_linkage != LinkageKind::None) { return false; }
        if (f->abi == AbiKind::Virtual) || (f->abi == AbiKind::Override) { return false; }
        if f->call_conv != 0 { return false; }
        // A `-> !` or `@cold_path` function is the cold edge: its argument's
        // copy is paid at most once, and a `const T&` would make the caller
        // hold the temporary across the call, one more cleanup on every
        // crash path for nothing (crash_with is called from hot loops).
        if f->is_noreturn || f->cold_path { return false; }
        if f->is_generator || f->has_yield || f->is_async() || f->is_eval() { return false; }
        if f->transfer != TransferKind::NotTransfer { return false; }
        if (f->ci_split != 0) || (f->class_alloc_op != 0) || (f->dynamic_layout != 0) { return false; }
        if f->adt_role != AdtRole::None { return false; }
        if f->has_where() || (f->where_lead != &null) || (f->where_group.size() > 0) { return false; }
        if f->generic_params.size() > 0 { return false; }
        if decl_is_requirement(static_cast::<*Decl>(f)) { return false; }
        if self._in_generic(static_cast::<*Decl>(f)) { return false; }
        if self._is_main(f) { return false; }
        if self._overrides_maybe(f) { return false; }
        return true;
    }

    /// \p d sits in a generic record or a generic extension, at any depth.
    priv fn _in_generic(self, d: *Decl) -> bool {
        var ext = decl_extension_of(d);
        if (ext != &null) && (decl_generic_params(static_cast::<*Decl>(ext)).size() > 0) { return true; }
        var dc = reinterpret_cast::<*DeclContext>(d->semantic_dc);
        var depth: u32 = 0;
        while (dc != &null) && (depth < 64) {
            var o = dc->owner_decl();
            if o == &null { break; }
            if decl_generic_params(o).size() > 0 { return true; }
            if isa::<ExtensionDecl>(o) {
                var t = cast::<ExtensionDecl>(o)->target;
                if (t != &null) && (t->canonical != &null) && t->canonical->is_dependent() { return true; }
            }
            dc = reinterpret_cast::<*DeclContext>(o->semantic_dc);
            depth += 1;
        }
        return false;
    }

    /// The program's entry point: its signature is the C runtime's.
    priv fn _is_main(self, f: *FunctionDecl) -> bool {
        if f->is_operator || f->is_method() { return false; }
        var dc = reinterpret_cast::<*DeclContext>(f->semantic_dc);
        if (dc != &null) && (dc->owner_decl() != &null) && (!isa::<ModuleDecl>(dc->owner_decl())) { return false; }
        return self.sc->ctx->get_spelling(f->name) == "main";
    }

    /// A method of a class with a polymorphic base: C++ may take it as an
    /// override of a base virtual (a C++ base's, or a Kairo one the class
    /// redeclares), and a `const T&` parameter would make it a new function
    /// that hides the slot.
    priv fn _overrides_maybe(self, f: *FunctionDecl) -> bool {
        if !f->is_method() { return false; }
        var dc = reinterpret_cast::<*DeclContext>(f->semantic_dc);
        if dc == &null { return false; }
        var o = dc->owner_decl();
        if (o == &null) || (!isa::<ClassDecl>(o)) { return false; }
        if decl_bases(o).size() == 0 { return false; }
        var facts = lifecycle_of(self.sc)->facts_of(o);
        return (facts == &null) || (facts->polymorphic != LifecycleTri::No);
    }

    priv fn _eligible_param(self, p: *ParamDecl) -> bool {
        if (p == &null) || p->is_self || p->is_const || p->is_pack || p->unname { return false; }
        if p->mode != ParamMode::Value { return false; }
        if p->is_poisoned() || (!p->name.range.is_valid()) { return false; }
        if param_is_type_pack(p) { return false; }
        if (p->type_ == &null) || (p->type_->canonical == &null) { return false; }
        var c = canon_unqual(p->type_->canonical);
        if (c == &null) || (c->kind != TypeKind::RecordType) || c->is_dependent() || c->is_instantiation_dependent() { return false; }
        var rd = self._tu.record_decl(c);
        if (rd == &null) || isa::<InterfaceDecl>(rd) || decl_is_imported(rd) { return false; }
        var facts = lifecycle_of(self.sc)->facts_of_type(c);
        if facts.category != LifecycleCategory::Copy { return false; }
        if facts.copyable != LifecycleTri::Yes { return false; }
        return facts.trivially_copyable == LifecycleTri::No;
    }

    // === references ==========================================================

    priv fn _cand_of(self, d: *Decl) -> usize {
        if (d == &null) || (!isa::<ParamDecl>(d)) { return usize(-1); }
        var it = self._index.find(reinterpret_cast::<u64>(d));
        if it == self._index.end() { return usize(-1); }
        return it->second - 1;
    }

    fn visit_named_ident_expr(self, n: *NamedIdentExpr) -> bool {
        var k = self._cand_of(n->resolved_decl);
        if k == usize(-1) { return true; }
        self._refs[k] += 1;
        // Inside a closure: the capture decides the C++ (a `[&]` of a
        // `const T&` is a const view the body may write through), and the
        // closure may outlive the call. Ruled out.
        if self._closures > self._depth[k] { self._bad[k] = true; }
        return true;
    }

    /// The candidate reference \p e reads in place, or null: through parens,
    /// `unsafe`, `.field` / `.0` steps and fixed-array subscripts, the
    /// parameter's own storage. \p thru is set when the path then steps
    /// through a pointer: what follows is the pointee, not the parameter.
    priv fn _root(self, e: *Expr, thru: *bool) -> *NamedIdentExpr {
        var x = e;
        var guard: usize = 0;
        while (x != &null) && (guard < 256) {
            guard += 1;
            if isa::<ParenExpr>(x)  { x = cast::<ParenExpr>(x)->inner; continue; }
            if isa::<UnsafeExpr>(x) { x = cast::<UnsafeExpr>(x)->operand; continue; }
            if isa::<NamedIdentExpr>(x) {
                var ni = cast::<NamedIdentExpr>(x);
                if self._cand_of(ni->resolved_decl) == usize(-1) { return &null; }
                return ni;
            }
            if isa::<ChainExpr>(x) {
                var ce = cast::<ChainExpr>(x);
                return self._root_chain(ce, ce->steps.size(), thru);
            }
            if isa::<SubscriptExpr>(x) {
                var se = cast::<SubscriptExpr>(x);
                if se->resolved_op != &null { return &null; }
                var bt = (canon_unqual(se->base->type_)) if ((se->base != &null) && (se->base->type_ != &null)) else (&null);
                if bt == &null { return &null; }
                if bt->kind == TypeKind::FixedArrayType { x = se->base; continue; }
                if bt->kind == TypeKind::PointerType {
                    var r = self._root(se->base, thru);
                    if r != &null { (*thru) = true; }
                    return r;
                }
                return &null;
            }
            return &null;
        }
        return &null;
    }

    /// _root of \p ce cut to its first \p nsteps steps.
    priv fn _root_chain(self, ce: *ChainExpr, nsteps: usize, thru: *bool) -> *NamedIdentExpr {
        if ce->base == &null { return &null; }
        var r = self._root(ce->base, thru);
        if r == &null { return &null; }
        var prev = ce->base->type_;
        for var i: usize = 0; i < nsteps; ++i {
            var st = ce->steps.get(i);
            if st->access_kind == ChainExpr::AccessKind::Arrow {
                var pt = (canon_unqual(prev)) if (prev != &null) else (&null);
                if (pt == &null) || (pt->kind != TypeKind::PointerType) { return &null; }
                (*thru) = true;
                return r;
            }
            if st->access_kind != ChainExpr::AccessKind::Dot { return &null; }
            if st->target == ChainExpr::StepTarget::TupleIndex { prev = st->resolved_type; continue; }
            if st->target != ChainExpr::StepTarget::Name { return &null; }
            if (st->resolved_decl == &null) || (!isa::<FieldDecl>(st->resolved_decl)) { return &null; }
            prev = st->resolved_type;
        }
        return r;
    }

    /// Claim \p e's candidate reference, if it has one, as a read.
    priv fn _approve(self, e: *Expr) {
        if e == &null { return; }
        var thru = false;
        var r = self._root(e, &thru);
        if r == &null { return; }
        self._claim(r);
    }

    priv fn _claim(self, r: *NamedIdentExpr) {
        var key = reinterpret_cast::<u64>(r);
        if self._approved.count(key) != 0 { return; }
        self._approved.insert(key);
        var k = self._cand_of(r->resolved_decl);
        if k != usize(-1) { self._oks[k] += 1; }
    }

    /// \p t is a C++ reference type (`T&` / `T&&`).
    priv fn _is_ref(self, t: *Type) -> bool {
        if t == &null { return false; }
        var c = canon_unqual((t->canonical) if (t->canonical != &null) else (t));
        return (c != &null) && (isa::<CXXLValueRefType>(c) || isa::<CXXRValueRefType>(c));
    }

    /// A value passed to \p p is only read: by value (a copy), `const`, or
    /// a C++ `const T&`.
    priv fn _reads_param(self, p: *ParamDecl) -> bool {
        if p == &null { return false; }
        if p->is_pack || param_is_type_pack(p) { return false; }
        if p->is_self { return p->is_const; }
        if p->mode == ParamMode::Move { return false; }
        if p->is_const { return true; }
        if p->mode != ParamMode::Value { return false; }
        if p->type_ == &null { return false; }
        var c = canon_unqual((p->type_->canonical) if (p->type_->canonical != &null) else (p->type_));
        if c == &null { return false; }
        if isa::<CXXRValueRefType>(c) { return false; }
        if isa::<CXXLValueRefType>(c) {
            var ref = cast::<CXXLValueRefType>(c)->referee;
            return (ref != &null) && canon_has_const((ref->canonical) if (ref->canonical != &null) else (ref));
        }
        return true;
    }

    priv fn _callee_decl(self, c: *Expr) -> *FunctionDecl {
        var x = self._tu.strip_parens(c);
        if x == &null { return &null; }
        if isa::<NamedIdentExpr>(x) { return dyn_cast::<FunctionDecl>(cast::<NamedIdentExpr>(x)->resolved_decl); }
        if isa::<ChainExpr>(x) {
            var ce = cast::<ChainExpr>(x);
            if ce->steps.size() == 0 { return &null; }
            return dyn_cast::<FunctionDecl>(ce->steps.get(ce->steps.size() - 1)->resolved_decl);
        }
        return &null;
    }

    // === approving nodes =====================================================

    fn visit_call_expr(self, n: *CallExpr) -> bool {
        var f = self._callee_decl(n->callee);
        var is_ctor = (n->ctor_decl != &null) && isa::<FunctionDecl>(n->ctor_decl);
        if is_ctor { f = cast::<FunctionDecl>(n->ctor_decl); }
        var callee = self._tu.strip_parens(n->callee);
        var bound = false;
        if (!is_ctor) && (f != &null) && (callee != &null) && isa::<ChainExpr>(callee) {
            var ce = cast::<ChainExpr>(callee);
            var last = ce->steps.get(ce->steps.size() - 1);
            var dotted = (last->access_kind == ChainExpr::AccessKind::Dot) || (last->access_kind == ChainExpr::AccessKind::Arrow);
            if dotted && f->is_method() {
                bound = true;
                // The receiver: `p.m()` / `p.f.m()`, read when m is const
                // (or reached through a pointer, so it is the pointee m runs on).
                var thru = false;
                var r: *NamedIdentExpr = &null;
                if last->access_kind == ChainExpr::AccessKind::Arrow {
                    r = self._root_chain(ce, ce->steps.size() - 1, &thru);
                    if r != &null { thru = true; }
                } else {
                    r = self._root_chain(ce, ce->steps.size() - 1, &thru);
                }
                if (r != &null) && (thru || f->is_const()) { self._claim(r); }
            }
        }

        if f != &null {
            var view = vec::<*ParamDecl>();
            for var i: usize = 0; i < f->params.size(); ++i {
                var p = f->params[i];
                if p == &null { continue; }
                if p->is_self && (bound || is_ctor) { continue; }
                view.push_back(p);
            }
            for var i: usize = 0; i < n->args.size(); ++i {
                var a = n->args[i];
                if a == &null { continue; }
                if i < view.size() {
                    if self._reads_param(view[i]) { self._approve(a); }
                } else if f->is_variadic || f->ffi_c_variadic {
                    self._approve(a);                     // a C `...` tail takes scalars by value.
                }
            }
            return true;
        }

        // Through a `fn` value: the type's parameters.
        if (n->callee != &null) && (n->callee->type_ != &null) {
            var t = canon_unqual(self._tu.strip_nullable(n->callee->type_));
            if (t != &null) && isa::<FunctionPointerType>(t) {
                var fp = cast::<FunctionPointerType>(t);
                for var i: usize = 0; i < n->args.size(); ++i {
                    if (i >= fp->params.size()) || (i >= fp->modes.size()) { break; }
                    if fp->modes[i] != ParamMode::Value { continue; }
                    if self._is_ref(fp->params[i]) { continue; }
                    self._approve(n->args[i]);
                }
            }
        }
        return true;
    }

    fn visit_binary_operator_expr(self, n: *BinaryOperatorExpr) -> bool {
        if n->resolved_op != &null { return true; }
        var k = n->op_token.kind;
        if (k == TokenKind::OpDotStar) || (k == TokenKind::OpArrowStar) || (k == TokenKind::OpQuestionDotStar) || (k == TokenKind::OpQuestionArrowStar) { return true; }
        self._approve(n->lhs);
        self._approve(n->rhs);
        return true;
    }

    fn visit_unary_operator_expr(self, n: *UnaryOperatorExpr) -> bool {
        if n->resolved_op != &null { return true; }
        var k = n->op_token.kind;
        var reads = (k == TokenKind::OpMinus) || (k == TokenKind::OpPlus) || (k == TokenKind::OpExclaim)
                 || (k == TokenKind::OpTilde) || (k == TokenKind::OpStar) || (k == TokenKind::KwNot);
        if reads { self._approve(n->operand); }
        return true;
    }

    fn visit_assign_operator_expr(self, n: *AssignOperatorExpr) -> bool {
        if n->resolved_op != &null { return true; }
        self._approve(n->rhs);
        return true;
    }

    fn visit_subscript_expr(self, n: *SubscriptExpr) -> bool {
        self._approve(n->index);
        return true;
    }

    fn visit_type_cast_expr(self, n: *TypeCastExpr) -> bool {
        if (n->resolved_op != &null) || (n->resolved_ctor != &null) { return true; }
        if self._is_ref(n->target) { return true; }
        self._approve(n->operand);
        return true;
    }

    fn visit_init_list_expr(self, n: *InitListExpr) -> bool {
        for var i: usize = 0; i < n->elements.size(); ++i { self._approve(n->elements[i]); }
        return true;
    }

    fn visit_tuple_literal_expr(self, n: *TupleLiteralExpr) -> bool {
        for var i: usize = 0; i < n->elements.size(); ++i { self._approve(n->elements[i]); }
        return true;
    }

    fn visit_variant_init_expr(self, n: *VariantInitExpr) -> bool {
        for var i: usize = 0; i < n->fields.size(); ++i { self._approve(n->fields[i]); }
        return true;
    }

    fn visit_if_expr(self, n: *IfExpr) -> bool {
        self._approve(n->condition);
        for var i: usize = 0; i < n->else_ifs.size(); ++i { self._approve(n->else_ifs.get(i)->condition); }
        return true;
    }

    fn visit_size_of_expr(self, n: *SizeOfExpr) -> bool { return true; }

    fn visit_variable_decl(self, n: *VariableDecl) -> bool {
        if (n->init == &null) || n->place_ref || n->raw_slot { return true; }
        if self._is_ref(n->type_) { return true; }
        self._approve(n->init);
        return true;
    }

    fn visit_return_stmt(self, n: *ReturnStmt) -> bool {
        if n->value == &null { return true; }
        // `return p` moves a by-value parameter out (C++ treats it as an
        // rvalue); a `const T&` one would be copied, for a caller that
        // passed a temporary a copy it never paid before.
        if isa::<NamedIdentExpr>(self._tu.strip_parens(n->value)) { return true; }
        if (self._ret.size() > 0) && self._is_ref(self._ret[self._ret.size() - 1]) { return true; }
        self._approve(n->value);
        return true;
    }

    fn visit_conditional_stmt(self, n: *ConditionalStmt) -> bool { self._approve(n->cond); return true; }
    fn visit_while_loop_stmt(self, n: *WhileLoopStmt) -> bool { self._approve(n->cond); return true; }
    fn visit_runtime_assert_stmt(self, n: *RuntimeAssertStmt) -> bool {
        self._approve(n->condition);
        self._approve(n->message);
        return true;
    }
}
