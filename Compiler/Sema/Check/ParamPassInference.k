/// --- The Kairo Project -------------- Sema/Check/ParamPassInference.k --- ///
///
///   \brief A by-value parameter its function never mutates is passed as
///          `const T&`, and warned to say `const`.
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
///     pointer and a `fn` value are never records. Compiler/Spec/Codegen.md#cxxspell has the
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
///       - a const function, written or inferred (`[[gnu::const]]`
///         is memory(none), and a reference parameter is memory);
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
///     the mutable `[]` is the one picked for a non-const receiver),
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
///   \par -Wconst-self (opt-in; SC273W, SC274W)
///     The same "never mutated" walk, as a lint only (nothing is inferred,
///     codegen never sees it): a method's `self` that is not `const`, and an
///     `@inout` parameter, of a function eligible above. A method is skipped
///     further when its signature is not its own to change: a constructor,
///     `op delete` or an assignment operator, an out-of-line definition (the
///     declaration in the class would disagree), a method of a record or
///     extension that implements an interface (a requirement fixes it), and
///     anything outside a class, struct or extension. One more approved use:
///     a call to a method that is itself a candidate, on a receiver rooted at
///     a candidate (`self.m()`, `self.f.m()`). Those are edges, decided once
///     the whole TU is walked as a greatest fixpoint: every candidate whose
///     own uses were all approved starts const-able, and one with an edge to
///     a method that is not (a candidate that failed, or no candidate at
///     all: another TU, a generic) stops being so, until nothing changes.
///     Off by default (decided 2026-11-07), so a tree is run through it once first.
///
///   Phase: LOWER, after StringLowering (the last lowering): reads the tree
///   EmitIR will render, writes ParamDecl::inferred_const, read only by
///   codegen (CXXSpell::_param_type, EmitIR::_fn_ref_adapter), which runs
///   after every TU's Sema.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "vector"
ffi "c++" import "llvm/ADT/DenseMap.h"
ffi "c++" import "llvm/ADT/DenseSet.h"

import AST::DeclFacts::{
    decl_bases,
    decl_extension_of,
    decl_generic_params,
    decl_is_imported,
    decl_is_requirement,
    param_is_type_pack,
}
import AST::Kind::TypeKind::TypeKind
import AST::LangItems::LangAttrs
import AST::Mixin::FFILinkage::LinkageKind
import AST::Node::Base::{
    Decl,
    Expr,
    Type,
}
import AST::Node::CanonicalNodes::{
    canon_has_const,
    canon_unqual,
}
import AST::Node::Casting::{
    cast,
    dyn_cast,
    isa,
}
import AST::Node::Declarations::{
    AbiKind,       AdtRole,    ClassDecl, ExtensionDecl, FieldDecl,    FnBodyKind,   FunctionDecl,
    InterfaceDecl, ModuleDecl, ParamDecl, StructDecl,    TransferKind, VariableDecl,
}
import AST::Node::Expressions
import AST::Node::PrimaryExpressions::{
    ChainExpr,
    NamedIdentExpr,
}
import AST::Node::Program::TopLevelKind
import AST::Node::Statements::{
    ConditionalStmt,
    ReturnStmt,
    RuntimeAssertStmt,
    WhileLoopStmt,
}
import AST::Node::Types::{
    CXXLValueRefType,
    CXXRValueRefType,
    FunctionPointerType,
}
import AST::ParamMode::ParamMode
import AST::Visitor::RecursiveASTVisitor::RecursiveASTVisitor
import Diagnostic::Registry::DiagID
import Sema::Check::ClassLifecycle::{
    LifecycleCategory,
    LifecycleTri,
    lifecycle_of,
}
import Sema::SemaContext::SemaContext
import Sema::Type::TypeUtil::TypeUtil
import Token::TokenKind::{
    TokenKind,
    is_assignment_operator,
}

///
/// \class ParamPassInference
/// \brief The pass. Writes ParamDecl::inferred_const; warns SC001W.
///
pub class ParamPassInference derives RecursiveASTVisitor<ParamPassInference> {
    pub var  sc:  unsafe *SemaContext
    priv var _tu: TypeUtil
    /// Candidates of every function being walked (a local `fn` nests one
    /// walk inside another), and per candidate: its references seen, the
    /// references approved, the closure depth it was declared at, and
    /// whether a use inside a closure already ruled it out.
    priv var _cand:  cxx::std::vector<unsafe *ParamDecl>
    priv var _refs:  cxx::std::vector<usize>
    priv var _oks:   cxx::std::vector<usize>
    priv var _depth: cxx::std::vector<usize>
    priv var _bad:   cxx::std::vector<u8>
    /// ParamDecl -> its index in _cand, plus one.
    priv var _index: llvm::DenseMap<u64, u64>
    /// The references an approving node has claimed: one approval each.
    priv var _approved: llvm::DenseSet<u64>
    /// Return types of the functions being walked, innermost last.
    priv var _ret:       cxx::std::vector<unsafe *Type>
    priv var _closures:  usize                          = 0
    priv var _library:   bool                           = false
    pub var  n_inferred: usize                          = 0

    /// -Wconst-self, in a TU that is not library code.
    priv var _lint: bool = false
    /// Per candidate (parallel to _cand): its lint slot, or usize::MAX for a
    /// by-value one SC224W decides.
    priv var _slot: cxx::std::vector<usize>
    /// Lint slots, for the whole TU: the parameter (`self` or an `@inout`
    /// one), its function, and whether it is still const-able.
    priv var _s_param: cxx::std::vector<unsafe *ParamDecl>
    priv var _s_fn:    cxx::std::vector<unsafe *FunctionDecl>
    priv var _s_ok:    cxx::std::vector<u8>
    /// A method's first declaration -> its `self` slot, plus one.
    priv var _s_self: llvm::DenseMap<u64, u64>
    /// Fixpoint edges: slot _e_from[i] stays const-able only if the method
    /// _e_to[i] (a first declaration) does.
    priv var _e_from:       cxx::std::vector<usize>
    priv var _e_to:         cxx::std::vector<unsafe *FunctionDecl>
    pub var  n_const_self:  usize                                  = 0
    pub var  n_const_inout: usize                                  = 0

    fn ParamPassInference(self, sc: unsafe *SemaContext) {
        self.sc  = sc
        self._tu = TypeUtil(sc)
    }

    fn run(self) {
        var unsafe *tu = self.sc->tu
        if tu == &null {
            return
        }

        if tu->program == &null {
            return
        }

        self._library = self._library_tu()
        var unsafe *ci = self.sc->ctx->ci
        self._lint = ci != &null && ci->diag.Wconst_self && !self._library

        var *items = &tu->program->items
        for var i: usize = 0; i < items->size(); ++i {
            if self.stop {
                break
            }

            var item = *items->get(i)
            match item.get_kind() {
                case TopLevelKind::Decl {
                    self.dyn()->dispatch_decl(item.as_decl())
                } case TopLevelKind::Stmt {
                    self.dyn()->dispatch_stmt(item.as_stmt())
                } case TopLevelKind::Expr {
                    self.dyn()->dispatch_expr(item.as_expr())
                }
            }
        }

        if self._lint {
            self._decide_lint()
        }
    }

    /// The test FlagGates uses: builtin by fid, std by its directory.
    priv fn _library_tu(self) -> bool {
        var fid = self.sc->ctx->fid
        if self.sc->g != &null && self.sc->g->is_builtin_fid(fid) {
            return true
        }

        var unsafe *ci = self.sc->ctx->ci
        if ci == &null || self.sc->ctx->sm == &null {
            return false
        }

        var root = ci->pp.std_dir
        if root.empty() && !ci->target.resource_dir.empty() {
            root = ci->target.resource_dir + "/std"
        }

        if root.empty() {
            return false
        }

        if !root.ends_with("/") {
            root += "/"
        }

        return self.sc->ctx->sm->get_filename(fid).starts_with(root)
    }

    /// # functions

    fn traverse_function_decl(self, n: unsafe *FunctionDecl) -> unsafe *FunctionDecl {
        if n == &null {
            return n
        }

        var first    = self._cand.size()
        var eligible = self._eligible_fn(n)
        if eligible {
            for var i: usize = 0; i < n->params.size(); ++i {
                var unsafe *p = n->params[i]
                if !self._eligible_param(p) {
                    continue
                }

                self._push_cand(p, usize::MAX)
            }

            if self._lint {
                self._lint_cands(n)
            }
        }

        self._ret.push_back(n->return_type)
        var unsafe *out = RecursiveASTVisitor<ParamPassInference>::traverse_function_decl(self, n)
        self._ret.pop_back()
        // Decide this function's candidates, then drop them: a reference to
        // one can only be in its own body.
        while self._cand.size() > first {
            var        k         = self._cand.size() - 1
            var unsafe *p        = self._cand[k]
            var        unmutated = self._bad[k] == 0 && self._oks[k] == self._refs[k]
            var        slot      = self._slot[k]
            if slot != usize::MAX {
                if !unmutated {
                    self._s_ok[slot] = 0
                }
            } else if unmutated {
                self._infer(n, p)
            }

            self._index.erase(p as usize as u64)
            self._cand.pop_back()
            self._refs.pop_back()
            self._oks.pop_back()
            self._depth.pop_back()
            self._bad.pop_back()
            self._slot.pop_back()
        }

        return out
    }

    fn traverse_closure_expr(self,
                             n: unsafe *Expressions::ClosureExpr) -> unsafe *Expressions::ClosureExpr {
        self._closures += 1
        var unsafe *out = RecursiveASTVisitor<ParamPassInference>::traverse_closure_expr(self, n)
        self._closures -= 1
        return out
    }

    /// Stamp \p p, and the same parameter of every other link of \p f's
    /// redeclaration chain (an out-of-line definition's declaration spells
    /// the signature in the class), then warn.
    priv fn _infer(self, f: unsafe *FunctionDecl, p: unsafe *ParamDecl) {
        var        idx          = (p->index as usize)
        var unsafe *head        = f->first_decl()
        var unsafe *cur         = head
        var        guard: usize = 0
        var        links        = cxx::std::vector<unsafe *ParamDecl>()
        while cur != &null && guard < 64 {
            if idx < cur->params.size() {
                var unsafe *q = cur->params[idx]
                if q != &null {
                    q->inferred_const = true
                    // A link that already spells `const` needs no edit.
                    if q != p && (!q->is_const) {
                        links.push_back(q)
                    }
                }
            }

            cur = cur->next_in_chain()
            guard += 1
            if cur == head {
                break
            }
        }

        p->inferred_const = true
        self.n_inferred += 1
        if self._library {
            return
        }

        var nm = self.sc->ctx->get_spelling(p->name)
        var b = self.sc->diag->report(
            DiagID::SC224W,
            p->name.range.start,
            f"parameter '{nm}' is never mutated; declare it 'const'",
        )

        b.first(p->name.range)
        b.insert(p->name.range.start, "const ", f"make '{nm}' const")
        // The other links spell the same parameter (an out-of-line
        // definition's in-class declaration): `const` at the definition
        // alone is a signature the declaration does not match, which C++
        // rejects as an out-of-line definition of nothing (P446).
        for var i: usize = 0; i < links.size(); ++i {
            var unsafe *q  = links[i]
            var        at = q->name.range.start
            if at == p->name.range.start {
                continue
            }

            b.insert(at, "const ", f"make '{nm}' const at its declaration too")
            b.note(at, f"'{nm}' is also declared here")
        }

        b.emit()
    }

    priv fn _eligible_fn(self, f: unsafe *FunctionDecl) -> bool {
        if f->is_implicit || f->is_poisoned() {
            return false
        }

        if f->body_kind != FnBodyKind::Block {
            return false
        }

        if f->body_block == &null {
            return false
        }

        if f->is_imported() || f->ffi_linkage != LinkageKind::None {
            return false
        }

        if f->abi == AbiKind::Virtual || f->abi == AbiKind::Override {
            return false
        }

        if f->call_conv != 0 {
            return false
        }

        // A `-> !` or `@cold_path` function is the cold edge: its argument's
        // copy is paid at most once, and a `const T&` would make the caller
        // hold the temporary across the call, one more cleanup on every
        // crash path for nothing (crash_with is called from hot loops).
        if f->is_noreturn || f->cold_path {
            return false
        }

        // A const function (written, or inferred by -finfer-purity, which
        // runs just before this pass) is `[[gnu::const]]`, memory(none): a
        // `const T&` would be a read of the caller's memory that clang may
        // move across a store to it. By value, C++ passes the record
        // as a fresh caller copy, which clang lets the callee read.
        var unsafe *canon = f->canonical_decl()
        if f->is_const_fn || f->inferred_purity == 1 {
            return false
        }

        if canon != &null && (canon->is_const_fn || canon->inferred_purity == 1) {
            return false
        }

        if f->is_generator || f->has_yield || f->is_async() || f->is_eval() {
            return false
        }

        if f->transfer != TransferKind::NotTransfer {
            return false
        }

        if f->ci_split != 0 || f->class_alloc_op != 0 || f->dynamic_layout != 0 {
            return false
        }

        if f->adt_role != AdtRole::None {
            return false
        }

        if f->has_where() || f->where_lead != &null || f->where_group.size() > 0 {
            return false
        }

        if f->generic_params.size() > 0 {
            return false
        }

        if decl_is_requirement(f) {
            return false
        }

        if self._in_generic(f) {
            return false
        }

        if self._is_main(f) {
            return false
        }

        if self._overrides_maybe(f) {
            return false
        }

        return true
    }

    priv fn _push_cand(self, p: unsafe *ParamDecl, slot: usize) {
        self._cand.push_back(p)
        self._refs.push_back(0)
        self._oks.push_back(0)
        self._depth.push_back(self._closures)
        self._bad.push_back(0)
        self._slot.push_back(slot)
        self._index[p as usize as u64] = (self._cand.size() as u64)
    }

    /// -Wconst-self: \p f's `self` and `@inout` parameters become lint
    /// candidates, each with a slot. \p f already passed _eligible_fn.
    priv fn _lint_cands(self, f: unsafe *FunctionDecl) {
        var method = f->is_method()
        if method && !self._lint_method_ok(f) {
            return
        }

        for var i: usize = 0; i < f->params.size(); ++i {
            var unsafe *p = f->params[i]
            if p == &null || p->is_const || p->is_pack || p->is_poisoned() {
                continue
            }

            if !p->name.range.is_valid() {
                continue
            }

            if p->is_self {
                if p->index != 0 {
                    continue
                }
            } else {
                if p->mode != ParamMode::Inout || p->unname || param_is_type_pack(p) {
                    continue
                }

                if !p->mode_range.is_valid() {
                    continue
                }
            }

            var slot = self._s_param.size()
            self._s_param.push_back(p)
            self._s_fn.push_back(f)
            self._s_ok.push_back(1)
            if p->is_self {
                self._s_self[f->first_decl() as usize as u64] = (slot as u64) + 1
            }

            self._push_cand(p, slot)
        }
    }

    /// A method whose signature is its own to change: see the header's
    /// -Wconst-self paragraph for each exclusion.
    priv fn _lint_method_ok(self, f: unsafe *FunctionDecl) -> bool {
        if f->is_out_of_line() || f->first_decl() != f {
            return false
        }

        if f->is_operator && f->op_token.size() > 0 {
            var k = f->op_token.get(0)->kind
            if k == TokenKind::KwFinally || is_assignment_operator(k) {
                return false
            }
        }

        var unsafe *ext = decl_extension_of(f)
        if ext != &null {
            return ext->implements.size() == 0
        }

        var unsafe *dc = f->semantic_dc
        if dc == &null {
            return false
        }

        var unsafe *o = dc->owner_decl()
        if o == &null {
            return false
        }

        if isa<ClassDecl>(o) {
            if cast<ClassDecl>(o)->implements.size() > 0 {
                return false
            }
        } else if isa<StructDecl>(o) {
            if cast<StructDecl>(o)->implements.size() > 0 {
                return false
            }
        } else {
            return false
        }

        // A constructor: named after its record. Its `self` is the object
        // being built, never a read-only view. decl_name, not the name
        // token: an operator has none to spell, and the token is the
        // declaring file's.
        if f->is_operator {
            return true
        }

        return self._tu.decl_name(f) != self._tu.decl_name(o)
    }

    /// The candidate reference \p r is the receiver of a call to method
    /// \p m that is not `const self`: for a lint candidate, an edge to m
    /// (m's own verdict decides), and the reference is approved. Nothing for
    /// SC224W's candidates, whose rule has no edges.
    priv fn _defer(self, r: unsafe *NamedIdentExpr, m: unsafe *FunctionDecl) {
        var k = self._cand_of(r->resolved_decl)
        if k == usize::MAX || self._slot[k] == usize::MAX {
            return
        }

        self._e_from.push_back(self._slot[k])
        self._e_to.push_back(m->first_decl())
        self._claim(r)
    }

    /// The greatest fixpoint over the edges, then one warning per slot that
    /// is still const-able.
    priv fn _decide_lint(self) {
        var changed = true
        while changed {
            changed = false
            for var i: usize = 0; i < self._e_from.size(); ++i {
                var from = self._e_from[i]
                if self._s_ok[from] == 0 {
                    continue
                }

                var it = self._s_self.find(self._e_to[i] as usize as u64)
                var ok = it != self._s_self.end() && self._s_ok[(it->second - 1) as usize] != 0
                if !ok {
                    self._s_ok[from] = 0
                    changed          = true
                }
            }
        }

        for var s: usize = 0; s < self._s_param.size(); ++s {
            if self._s_ok[s] == 0 {
                continue
            }

            var unsafe *p = self._s_param[s]
            var unsafe *f = self._s_fn[s]
            if p->is_self {
                self.n_const_self += 1
                var fname = self._tu.decl_name(f)
                var b = self.sc->diag->report(
                    DiagID::SC273W,
                    p->name.range.start,
                    f"method '{fname}' never mutates 'self'; declare it 'const self'",
                )

                b.first(p->name.range)
                b.insert(p->name.range.start, "const ", "make 'self' const")
                b.emit()
            } else {
                self.n_const_inout += 1
                var nm = self.sc->ctx->get_spelling(p->name)
                var b = self.sc->diag->report(
                    DiagID::SC274W,
                    p->name.range.start,
                    f"{LangAttrs::quoted(LangAttrs::param_inout())} parameter '{nm}' is never mutated; declare it 'const'",
                )

                b.first(p->name.range)
                b.fix(p->mode_range, "const", f"make '{nm}' const")
                b.emit()
            }
        }
    }

    /// \p d sits in a generic record or a generic extension, at any depth.
    priv fn _in_generic(self, d: unsafe *Decl) -> bool {
        var unsafe *ext = decl_extension_of(d)
        if ext != &null && decl_generic_params(unsafe (ext as unsafe *Decl)).size() > 0 {
            return true
        }

        var unsafe *dc        = d->semantic_dc
        var        depth: u32 = 0
        while dc != &null && depth < 64 {
            var unsafe *o = dc->owner_decl()
            if o == &null {
                break
            }

            if decl_generic_params(o).size() > 0 {
                return true
            }

            if isa<ExtensionDecl>(o) {
                var unsafe *t = cast<ExtensionDecl>(o)->target
                if t != &null && t->canonical != &null && t->canonical->is_dependent() {
                    return true
                }
            }

            dc = o->semantic_dc
            depth += 1
        }

        return false
    }

    /// The program's entry point: its signature is the C runtime's.
    priv fn _is_main(self, f: unsafe *FunctionDecl) -> bool {
        if f->is_operator || f->is_method() {
            return false
        }

        var unsafe *dc = f->semantic_dc
        if dc != &null && dc->owner_decl() != &null && !isa<ModuleDecl>(dc->owner_decl()) {
            return false
        }

        return self.sc->ctx->get_spelling(f->name) == "main"
    }

    /// A method of a class with a polymorphic base: C++ may take it as an
    /// override of a base virtual (a C++ base's, or a Kairo one the class
    /// redeclares), and a `const T&` parameter would make it a new function
    /// that hides the slot.
    priv fn _overrides_maybe(self, f: unsafe *FunctionDecl) -> bool {
        if !f->is_method() {
            return false
        }

        var unsafe *dc = f->semantic_dc
        if dc == &null {
            return false
        }

        var unsafe *o = dc->owner_decl()
        if o == &null || !isa<ClassDecl>(o) {
            return false
        }

        if decl_bases(o).size() == 0 {
            return false
        }

        var unsafe *facts = lifecycle_of(self.sc)->facts_of(o)
        return facts == &null || facts->polymorphic != LifecycleTri::No
    }

    priv fn _eligible_param(self, p: unsafe *ParamDecl) -> bool {
        if p == &null || p->is_self || p->is_const || p->is_pack || p->unname {
            return false
        }

        if p->mode != ParamMode::Value {
            return false
        }

        if p->is_poisoned() || !p->name.range.is_valid() {
            return false
        }

        if param_is_type_pack(p) {
            return false
        }

        if p->type_ == &null || p->type_->canonical == &null {
            return false
        }

        var unsafe *c = canon_unqual(p->type_->canonical)
        if c == &null
            || c->kind != TypeKind::RecordType
            || c->is_dependent()
            || c->is_instantiation_dependent() {
            return false
        }

        var unsafe *rd = self._tu.record_decl(c)
        if rd == &null || isa<InterfaceDecl>(rd) || decl_is_imported(rd) {
            return false
        }

        var facts = lifecycle_of(self.sc)->facts_of_type(c)
        if facts.category != LifecycleCategory::Copy {
            return false
        }

        if facts.copyable != LifecycleTri::Yes {
            return false
        }

        return facts.trivially_copyable == LifecycleTri::No
    }

    /// # references

    priv fn _cand_of(self, d: unsafe *Decl) -> usize {
        if d == &null || !isa<ParamDecl>(d) {
            return usize::MAX
        }

        var it = self._index.find(d as usize as u64)
        if it == self._index.end() {
            return usize::MAX
        }

        return (it->second - 1) as usize
    }

    fn visit_named_ident_expr(self, n: *NamedIdentExpr) -> bool {
        var k = self._cand_of(n->resolved_decl)
        if k == usize::MAX {
            return true
        }

        self._refs[k] += 1
        // Inside a closure: the capture decides the C++ (a `[&]` of a
        // `const T&` is a const view the body may write through), and the
        // closure may outlive the call. Ruled out.
        if (self._closures as u64) > (self._depth[k] as u64) {
            self._bad[k] = 1
        }

        return true
    }

    /// The candidate reference \p e reads in place, or null: through parens,
    /// `unsafe`, `.field` / `.0` steps and fixed-array subscripts, the
    /// parameter's own storage. \p thru is set when the path then steps
    /// through a pointer: what follows is the pointee, not the parameter.
    priv fn _root(self, e: unsafe *Expr, thru: unsafe *bool) -> unsafe *NamedIdentExpr {
        var unsafe *x           = e
        var        guard: usize = 0
        while x != &null && guard < 256 {
            guard += 1
            if isa<Expressions::ParenExpr>(x) {
                x = cast<Expressions::ParenExpr>(x)->inner
                continue
            }

            if isa<Expressions::UnsafeExpr>(x) {
                x = cast<Expressions::UnsafeExpr>(x)->operand
                continue
            }

            if isa<NamedIdentExpr>(x) {
                var unsafe *ni = cast<NamedIdentExpr>(x)
                if self._cand_of(ni->resolved_decl) == usize::MAX {
                    return &null
                }

                return ni
            }

            if isa<ChainExpr>(x) {
                var unsafe *ce = cast<ChainExpr>(x)
                return self._root_chain(ce, ce->steps.size(), thru)
            }

            if isa<Expressions::SubscriptExpr>(x) {
                var unsafe *se = cast<Expressions::SubscriptExpr>(x)
                if se->resolved_op != &null {
                    return &null
                }

                var unsafe *bt = if (se->base != &null
                                     && se->base->type_ != &null) => (canon_unqual(se->base->type_))
                                 else => &null
                if bt == &null {
                    return &null
                }

                if bt->kind == TypeKind::FixedArrayType {
                    x = se->base
                    continue
                }

                if bt->kind == TypeKind::PointerType {
                    var unsafe *r = self._root(se->base, thru)
                    if r != &null {
                        *thru = true
                    }

                    return r
                }

                return &null
            }

            return &null
        }

        return &null
    }

    /// _root of \p ce cut to its first \p nsteps steps.
    priv fn _root_chain(self,
                        ce:     unsafe *ChainExpr,
                        nsteps: usize,
                        thru:   unsafe *bool) -> unsafe *NamedIdentExpr {
        if ce->base == &null {
            return &null
        }

        var unsafe *r = self._root(ce->base, thru)
        if r == &null {
            return &null
        }

        var unsafe *prev = ce->base->type_
        for var i: usize = 0; i < nsteps; ++i {
            var unsafe *st = ce->steps.get(i)
            if st->access_kind == ChainExpr::AccessKind::Arrow {
                var unsafe *pt = if (prev != &null) => (canon_unqual(prev)) else => &null
                if pt == &null || pt->kind != TypeKind::PointerType {
                    return &null
                }

                *thru = true
                return r
            }

            if st->access_kind != ChainExpr::AccessKind::Dot {
                return &null
            }

            if st->target == ChainExpr::StepTarget::TupleIndex {
                prev = st->resolved_type
                continue
            }

            if st->target != ChainExpr::StepTarget::Name {
                return &null
            }

            if st->resolved_decl == &null || !isa<FieldDecl>(st->resolved_decl) {
                return &null
            }

            prev = st->resolved_type
        }

        return r
    }

    /// Claim \p e's candidate reference, if it has one, as a read.
    priv fn _approve(self, e: unsafe *Expr) {
        if e == &null {
            return
        }

        var        thru = false
        var unsafe *r   = self._root(e, unsafe &thru)
        if r == &null {
            return
        }

        self._claim(r)
    }

    priv fn _claim(self, r: unsafe *NamedIdentExpr) {
        var key = (r as usize as u64)
        if self._approved.count(key) != 0 {
            return
        }

        self._approved.insert(key)
        var k = self._cand_of(r->resolved_decl)
        if k != usize::MAX {
            self._oks[k] += 1
        }
    }

    /// \p t is a C++ reference type (`T&` / `T&&`).
    priv fn _is_ref(self, t: unsafe *Type) -> bool {
        if t == &null {
            return false
        }

        var unsafe *c = canon_unqual(if (t->canonical != &null) => (t->canonical) else => t)
        return c != &null && (isa<CXXLValueRefType>(c) || isa<CXXRValueRefType>(c))
    }

    /// A value passed to \p p is only read: by value (a copy), `const`, or
    /// a C++ `const T&`.
    priv fn _reads_param(self, p: unsafe *ParamDecl) -> bool {
        if p == &null {
            return false
        }

        if p->is_pack || param_is_type_pack(p) {
            return false
        }

        if p->is_self {
            return p->is_const
        }

        if p->mode == ParamMode::Move {
            return false
        }

        if p->is_const {
            return true
        }

        if p->mode != ParamMode::Value {
            return false
        }

        if p->type_ == &null {
            return false
        }

        var unsafe *c = canon_unqual(
            if (p->type_->canonical != &null) => (p->type_->canonical) else => p->type_,
        )

        if c == &null {
            return false
        }

        if isa<CXXRValueRefType>(c) {
            return false
        }

        if isa<CXXLValueRefType>(c) {
            var unsafe *ref = cast<CXXLValueRefType>(c)->referee
            return ref != &null
                && canon_has_const(if (ref->canonical != &null) => (ref->canonical) else => ref)
        }

        return true
    }

    priv fn _callee_decl(self, c: unsafe *Expr) -> unsafe *FunctionDecl {
        var unsafe *x = self._tu.strip_parens(c)
        if x == &null {
            return &null
        }

        if isa<NamedIdentExpr>(x) {
            return dyn_cast<FunctionDecl>(cast<NamedIdentExpr>(x)->resolved_decl)
        }

        if isa<ChainExpr>(x) {
            var unsafe *ce = cast<ChainExpr>(x)
            if ce->steps.size() == 0 {
                return &null
            }

            return dyn_cast<FunctionDecl>(ce->steps.get(ce->steps.size() - 1)->resolved_decl)
        }

        return &null
    }

    /// # approving nodes

    fn visit_call_expr(self, n: *Expressions::CallExpr) -> bool {
        var unsafe *f      = self._callee_decl(n->callee)
        var        is_ctor = n->ctor_decl != &null && isa<FunctionDecl>(n->ctor_decl)
        if is_ctor {
            f = cast<FunctionDecl>(n->ctor_decl)
        }

        var unsafe *callee = self._tu.strip_parens(n->callee)
        var        bound   = false
        if !is_ctor && f != &null && callee != &null && isa<ChainExpr>(callee) {
            var unsafe *ce   = cast<ChainExpr>(callee)
            var unsafe *last = ce->steps.get(ce->steps.size() - 1)
            var dotted = last->access_kind == ChainExpr::AccessKind::Dot
                || last->access_kind == ChainExpr::AccessKind::Arrow
            if dotted && f->is_method() {
                bound = true
                // The receiver: `p.m()` / `p.f.m()`, read when m is const
                // (or reached through a pointer, so it is the pointee m runs on).
                var thru                        = false
                var r:   unsafe *NamedIdentExpr = &null
                if last->access_kind == ChainExpr::AccessKind::Arrow {
                    r = self._root_chain(ce, ce->steps.size() - 1, unsafe &thru)
                    if r != &null {
                        thru = true
                    }
                } else {
                    r = self._root_chain(ce, ce->steps.size() - 1, unsafe &thru)
                }

                if r != &null && (thru || f->is_const()) {
                    self._claim(r)
                } else if r != &null && self._lint {
                    self._defer(r, f)
                }
            }
        }

        if f != &null {
            var view = cxx::std::vector<unsafe *ParamDecl>()
            for var i: usize = 0; i < f->params.size(); ++i {
                var unsafe *p = f->params[i]
                if p == &null {
                    continue
                }

                if p->is_self && (bound || is_ctor) {
                    continue
                }

                view.push_back(p)
            }

            for var i: usize = 0; i < n->args.size(); ++i {
                var unsafe *a = n->args[i]
                if a == &null {
                    continue
                }

                if i < view.size() {
                    if self._reads_param(view[i]) {
                        self._approve(a)
                    }
                } else if f->is_variadic || f->ffi_c_variadic {
                    self._approve(a) // a C `...` tail takes scalars by value.
                }
            }

            return true
        }

        // Through a `fn` value: the type's parameters.
        if n->callee != &null && n->callee->type_ != &null {
            var unsafe *t = canon_unqual(self._tu.strip_nullable(n->callee->type_))
            if t != &null && isa<FunctionPointerType>(t) {
                var unsafe *fp = cast<FunctionPointerType>(t)
                for var i: usize = 0; i < n->args.size(); ++i {
                    if i >= fp->params.size() || i >= fp->modes.size() {
                        break
                    }

                    if fp->modes[i] != ParamMode::Value {
                        continue
                    }

                    if self._is_ref(fp->params[i]) {
                        continue
                    }

                    self._approve(n->args[i])
                }
            }
        }

        return true
    }

    fn visit_binary_operator_expr(self, n: *Expressions::BinaryOperatorExpr) -> bool {
        if n->resolved_op != &null {
            return true
        }

        var k = n->op_token.kind
        if k == TokenKind::OpDotStar
            || k == TokenKind::OpArrowStar
            || k == TokenKind::OpQuestionDotStar
            || k == TokenKind::OpQuestionArrowStar {
            return true
        }

        self._approve(n->lhs)
        self._approve(n->rhs)
        return true
    }

    fn visit_unary_operator_expr(self, n: *Expressions::UnaryOperatorExpr) -> bool {
        if n->resolved_op != &null {
            return true
        }

        var k = n->op_token.kind
        var reads = k == TokenKind::OpMinus
            || k == TokenKind::OpPlus
            || k == TokenKind::OpExclaim
            || k == TokenKind::OpTilde
            || k == TokenKind::OpStar
            || k == TokenKind::KwNot
        if reads {
            self._approve(n->operand)
        }

        return true
    }

    fn visit_assign_operator_expr(self, n: *Expressions::AssignOperatorExpr) -> bool {
        if n->resolved_op != &null {
            return true
        }

        self._approve(n->rhs)
        return true
    }

    fn visit_subscript_expr(self, n: *Expressions::SubscriptExpr) -> bool {
        self._approve(n->index)
        return true
    }

    fn visit_type_cast_expr(self, n: *Expressions::TypeCastExpr) -> bool {
        if n->resolved_op != &null || n->resolved_ctor != &null {
            return true
        }

        if self._is_ref(n->target) {
            return true
        }

        self._approve(n->operand)
        return true
    }

    fn visit_init_list_expr(self, n: *Expressions::InitListExpr) -> bool {
        for var i: usize = 0; i < n->elements.size(); ++i {
            self._approve(n->elements[i])
        }

        return true
    }

    fn visit_tuple_literal_expr(self, n: *Expressions::TupleLiteralExpr) -> bool {
        for var i: usize = 0; i < n->elements.size(); ++i {
            self._approve(n->elements[i])
        }

        return true
    }

    fn visit_variant_init_expr(self, n: *Expressions::VariantInitExpr) -> bool {
        for var i: usize = 0; i < n->fields.size(); ++i {
            self._approve(n->fields[i])
        }

        return true
    }

    fn visit_if_expr(self, n: *Expressions::IfExpr) -> bool {
        self._approve(n->condition)
        for var i: usize = 0; i < n->else_ifs.size(); ++i {
            self._approve(n->else_ifs.get(i)->condition)
        }

        return true
    }

    fn visit_size_of_expr(self, n: *Expressions::SizeOfExpr) -> bool {
        return true
    }

    fn visit_variable_decl(self, n: *VariableDecl) -> bool {
        if n->init == &null || n->place_ref || n->raw_slot {
            return true
        }

        if self._is_ref(n->type_) {
            return true
        }

        self._approve(n->init)
        return true
    }

    fn visit_return_stmt(self, n: *ReturnStmt) -> bool {
        if n->value == &null {
            return true
        }

        // `return p` moves a by-value parameter out (C++ treats it as an
        // rvalue); a `const T&` one would be copied, for a caller that
        // passed a temporary a copy it never paid before.
        if isa<NamedIdentExpr>(self._tu.strip_parens(n->value)) {
            return true
        }

        if self._ret.size() > 0 && self._is_ref(self._ret[self._ret.size() - 1]) {
            return true
        }

        self._approve(n->value)
        return true
    }

    fn visit_conditional_stmt(self, n: *ConditionalStmt) -> bool {
        self._approve(n->cond)
        return true
    }

    fn visit_while_loop_stmt(self, n: *WhileLoopStmt) -> bool {
        self._approve(n->cond)
        return true
    }

    fn visit_runtime_assert_stmt(self, n: *RuntimeAssertStmt) -> bool {
        self._approve(n->condition)
        self._approve(n->message)
        return true
    }
}
