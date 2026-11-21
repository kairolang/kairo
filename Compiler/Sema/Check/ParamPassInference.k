/// --- The Kairo Project -------------- Sema/Check/ParamPassInference.k --- ///
///
/// A by-value parameter its function never mutates is warned to say
/// `const`, and passed as `const T&` when the function stays in its TU.
///
///   \detail
///     `fn f(s: string)` was `f(::builtin::string::string s)`: every call
///     deep-copied an owned string, and the callee only ever read it. A
///     `const s: string` was already `const T&` (Speller::_param_type), so
///     a parameter whose body could have been written with `const` is
///     treated as if it had been, and the warning says to write it:
///
///         fn f(s: string) -> usize { return s.length() }
///              ^ parameter 's' is never mutated; declare it 'const'
///
///     Only a function that stays in its TU is inferred: one `priv`, by
///     itself or by an enclosing scope, written or by default, or local to
///     another function (VisibilityFacts::fn_crosses_tu). Anything else is
///     declared by other TUs from its written signature alone: a header, a
///     declaration-only redeclaration (`pub fn f(s: string);`) whose
///     definition is another file's, an import compiled in another run.
///     None of those has the body, so an inferred `const T&` would be a
///     signature they do not spell and the link would fail; and an exported
///     ABI must not change when a body is edited. Such a parameter keeps
///     its value and still gets the warning, since writing `const` is how
///     it is passed by reference.
///
///     Within its TU the decision is a function of the function's OWN
///     declaration and body, nothing else: every spelling of the signature
///     reads the same `ParamDecl::inferred_const`. Who takes the function's
///     address does not enter into it; a `fn` value of such a function goes
///     through an adapter instead (EmitIR::_fn_ref_adapter).
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
///       - an operand of a builtin operator (not `&`, `++`, `--`, `.*`),
///         and of `const &p`, a `*const T` nothing writes through;
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
///     The same rule in builtin and std, whose unmarked declarations are
///     public, so only their `priv` functions are inferred; the warning is
///     the user's: a library file is not one the user can edit
///     (SemaContext::in_library).
///
///   The warning is SC224W, on by default.
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
///     Off by default, so a tree is run through it once first.
///
///   Phase: LOWER, after StringLowering (the last lowering): reads the tree
///   EmitIR will render, writes ParamDecl::inferred_const, read only by
///   codegen (Speller::_param_type, EmitIR::_fn_ref_adapter), which runs
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
import AST::ExprFacts::callee_expr_decl
import AST::Kind::TypeKind::TypeKind
import AST::LangItems::{
    LangAttrs,
    entry_point_name,
}
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
    AbiKind,
    AdtRole,
    ClassDecl,
    ExtensionDecl,
    FieldDecl,
    FnBodyKind,
    FunctionDecl,
    InterfaceDecl,
    ModuleDecl,
    ParamDecl,
    PurityLevel,
    StorageClass,
    StructDecl,
    TransferKind,
    VariableDecl,
}
import AST::Node::Expressions
import AST::Node::PrimaryExpressions::{
    ChainExpr,
    NamedIdentExpr,
}
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
    PointerType,
}
import AST::ParamMode::ParamMode
import AST::VisibilityFacts::fn_crosses_tu
import AST::Visitor::RecursiveASTVisitor::RecursiveASTVisitor
import Config::ResourceLayout::ResourceLayout
import Diagnostic::Registry::DiagID
import Location::SourceRange::SourceRange
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

/// One candidate parameter of a function being walked.
pub struct PassCand {
    pub var param: unsafe *ParamDecl = &null
    pub var refs:  usize             = 0     ///< its references seen.
    pub var oks:   usize             = 0     ///< the references approved.
    pub var depth: usize             = 0     ///< the closure depth it was declared at.
    /// A use inside a closure already ruled it out.
    pub var bad: bool = false
    /// Its lint slot, or usize::MAX for a by-value one SC224W decides.
    pub var slot: usize = usize::MAX
}

/// A pointer parameter or local the -Wconst-self pointee half (SC360W)
/// watches: `levels` is how many of its pointee levels, from the first,
/// every use seen so far leaves unwritten.
pub struct PointeeCand {
    pub var decl:    unsafe *Decl = &null
    pub var written: unsafe *Type = &null ///< its written type, a pointer node.
    pub var depth:   u32          = 0     ///< pointer levels of its type.
    pub var levels:  u32          = 0
}

/// Where an expression sits relative to a PointeeCand `ref`: `k` derefs
/// from it (`*p` is 1, `**p` 2), then, when `member`, a field or element
/// of the level-`obj` object. `detached` once a path goes through a
/// pointer held in such a member: what it reaches is no level of `ref`.
pub struct PointeePath {
    pub var ref:      unsafe *NamedIdentExpr = &null
    pub var k:        u32                    = 0
    pub var member:   bool                   = false
    pub var obj:      u32                    = 0
    pub var detached: bool                   = false
}

/// The pass. Writes ParamDecl::inferred_const; warns SC224W.
pub class ParamPassInference derives RecursiveASTVisitor<ParamPassInference> {
    pub var  sc:  unsafe *SemaContext
    priv var _tu: TypeUtil
    /// Candidates of every function being walked (a local `fn` nests one
    /// walk inside another), innermost function's last.
    priv var _cand: [PassCand]
    /// ParamDecl -> its index in _cand, plus one.
    priv var _index: llvm::DenseMap<u64, u64>
    /// The references an approving node has claimed: one approval each.
    priv var _approved: llvm::DenseSet<u64>
    /// Return types of the functions being walked, innermost last.
    priv var _ret:       [unsafe *Type]
    priv var _closures:  usize          = 0
    priv var _library:   bool           = false
    pub var  n_inferred: usize          = 0

    /// -Wconst-self, in a TU that is not library code.
    priv var _lint: bool = false
    /// Lint slots, for the whole TU: the parameter (`self` or an `@inout`
    /// one), its function, and whether it is still const-able.
    priv var _s_param: [unsafe *ParamDecl]
    priv var _s_fn:    [unsafe *FunctionDecl]
    priv var _s_ok:    [u8]
    /// A method's first declaration -> its `self` slot, plus one.
    priv var _s_self: llvm::DenseMap<u64, u64>
    /// Fixpoint edges: slot _e_from[i] stays const-able only if the method
    /// _e_to[i] (a first declaration) does.
    priv var _e_from:       [usize]
    priv var _e_to:         [unsafe *FunctionDecl]
    pub var  n_const_self:  usize                  = 0
    pub var  n_const_inout: usize                  = 0
    /// -Wconst-self's pointee half: the candidates of the functions being
    /// walked (innermost last), their index plus one by declaration, and
    /// for each reference a parent use claimed, the levels that use leaves
    /// unwritten. A function's own entry in _pl_fns says whether its
    /// locals may be candidates.
    priv var _pl:        [PointeeCand]
    priv var _pl_index:  llvm::DenseMap<u64, u64>
    priv var _pl_claims: llvm::DenseMap<u64, u32>
    priv var _pl_fns:    [u8]
    pub var  n_pointee:  usize                    = 0

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

        self._library = self.sc->in_library()
        var unsafe *ci = self.sc->ctx->ci
        self._lint = ci != &null && ci->diag.Wconst_self && !self._library

        self.run(tu)

        if self._lint {
            self._decide_lint()
        }
    }

    /// # functions

    fn traverse_function_decl(self, n: unsafe *FunctionDecl) -> unsafe *FunctionDecl {
        if n == &null {
            return n
        }

        var first    = self._cand.size()
        var pl_first = self._pl.size()
        var eligible = self._eligible_fn(n)
        // Only a function that stays in its TU may change how it is called.
        var stamp = eligible && !fn_crosses_tu(n)
        var pl_on = false
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

        // The pointee half asks only that the signature be the function's
        // own: a cold or const function reads through its pointers too.
        if self._lint && self._signature_ours(n) {
            pl_on = !n->is_method() || self._lint_method_ok(n)
        }

        if pl_on {
            for var i: usize = 0; i < n->params.size(); ++i {
                var unsafe *p = n->params[i]
                if p != &null
                    && !p->is_self
                    && !p->is_pack
                    && p->mode == ParamMode::Value
                    && !param_is_type_pack(p)
                    && p->name.range.is_valid() {
                    self._pl_add(unsafe (p as unsafe *Decl), p->type_)
                }
            }
        }

        self._pl_fns.push(if (pl_on) => (1 as u8) else => (0 as u8))

        self._ret.push(n->return_type)
        var unsafe *out = RecursiveASTVisitor<ParamPassInference>::traverse_function_decl(
            self,
            n,
        )

        self._ret.pop()
        // Decide this function's candidates, then drop them: a reference to
        // one can only be in its own body.
        while self._cand.size() > first {
            var        k         = self._cand.size() - 1
            var unsafe *p        = self._cand[k].param
            var        unmutated = (!self._cand[k].bad) && self._cand[k].oks == self._cand[k].refs
            var        slot      = self._cand[k].slot
            if slot != usize::MAX {
                if !unmutated {
                    self._s_ok[slot] = 0
                }
            } else if unmutated {
                self._infer(n, p, stamp)
            }

            self._index.erase(p as usize as u64)
            self._cand.pop()
        }

        self._pl_fns.pop()
        while self._pl.size() > pl_first {
            self._pl_decide(self._pl.size() - 1)
            self._pl_index.erase(
                self._pl[self._pl.size() - 1].decl as usize as u64,
            )

            self._pl.pop()
        }

        return out
    }

    fn traverse_closure_expr(self,
                             n: unsafe *Expressions::ClosureExpr) -> unsafe *Expressions::ClosureExpr {
        self._closures += 1
        var unsafe *out = RecursiveASTVisitor<ParamPassInference>::traverse_closure_expr(
            self,
            n,
        )

        self._closures -= 1
        return out
    }

    /// Stamp `p`, and the same parameter of every other link of `f`'s
    /// redeclaration chain (an out-of-line definition's declaration spells
    /// the signature in the class), when `stamp`; then warn either way.
    priv fn _infer(self, f: unsafe *FunctionDecl, p: unsafe *ParamDecl, stamp: bool) {
        var        idx                        = (p->index as usize)
        var unsafe *head                      = f->first_decl()
        var unsafe *cur                       = head
        var        guard: usize               = 0
        var        links: [unsafe *ParamDecl]
        while cur != &null && guard < 64 {
            if idx < cur->params.size() {
                var unsafe *q = cur->params[idx]
                if q != &null {
                    q->inferred_const = stamp
                    // A link that already spells `const` needs no edit.
                    if q != p && (!q->is_const) {
                        links.push(q)
                    }
                }
            }

            cur = cur->next_in_chain()
            guard += 1
            if cur == head {
                break
            }
        }

        p->inferred_const = stamp
        if stamp {
            self.n_inferred += 1
        }

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
        // rejects as an out-of-line definition of nothing.
        for var i: usize = 0; i < links.size(); ++i {
            var unsafe *q = links[i]
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
        if !self._signature_ours(f) {
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
        if f->is_const_fn || f->inferred_purity == (PurityLevel::Const as u8) {
            return false
        }

        if canon != &null
            && (canon->is_const_fn || canon->inferred_purity == (PurityLevel::Const as u8)) {
            return false
        }

        return true
    }

    /// `f`'s signature is its own to change: a Kairo function with a body,
    /// not a transfer, requirement, override or entry point, and not part
    /// of a generic.
    priv fn _signature_ours(self, f: unsafe *FunctionDecl) -> bool {
        if f->is_implicit || f->is_poisoned() || f->body_kind != FnBodyKind::Block {
            return false
        }

        if f->body_block == &null || f->is_imported() || f->ffi_linkage != LinkageKind::None {
            return false
        }

        if f->abi == AbiKind::Virtual || f->abi == AbiKind::Override || f->call_conv != 0 {
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
        var c = PassCand{}
        c.param = p
        c.depth = self._closures
        c.slot  = slot
        self._cand.push(c)
        self._index[p as usize as u64] = (self._cand.size() as u64)
    }

    /// -Wconst-self: `f`'s `self` and `@inout` parameters become lint
    /// candidates, each with a slot. `f` already passed _eligible_fn.
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
            self._s_param.push(p)
            self._s_fn.push(f)
            self._s_ok.push(1)
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

    /// The candidate reference `r` is the receiver of a call to method
    /// `m` that is not `const self`: for a lint candidate, an edge to m
    /// (m's own verdict decides), and the reference is approved. Nothing for
    /// SC224W's candidates, whose rule has no edges.
    priv fn _defer(self, r: unsafe *NamedIdentExpr, m: unsafe *FunctionDecl) {
        var k = self._cand_of(r->resolved_decl)
        if k == usize::MAX || self._cand[k].slot == usize::MAX {
            return
        }

        self._e_from.push(self._cand[k].slot)
        self._e_to.push(m->first_decl())
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

    /// `d` sits in a generic record or a generic extension, at any depth.
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

        return self.sc->ctx->get_spelling(f->name) == entry_point_name()
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
        self._pl_ref(n)
        var k = self._cand_of(n->resolved_decl)
        if k == usize::MAX {
            return true
        }

        self._cand[k].refs += 1
        // Inside a closure: the capture decides the C++ (a `[&]` of a
        // `const T&` is a const view the body may write through), and the
        // closure may outlive the call. Ruled out.
        if (self._closures as u64) > (self._cand[k].depth as u64) {
            self._cand[k].bad = true
        }

        return true
    }

    /// The candidate reference `e` reads in place, or null: through parens,
    /// `unsafe`, `.field` / `.0` steps and fixed-array subscripts, the
    /// parameter's own storage. `thru` is set when the path then steps
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
                                     && se->base->type_ != &null) => (canon_unqual(
                                     se->base->type_,
                                 ))
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

    /// _root of `ce` cut to its first `nsteps` steps.
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

    /// Claim `e`'s candidate reference, if it has one, as a read.
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
            self._cand[k].oks += 1
        }
    }

    /// `t` is a C++ reference type (`T&` / `T&&`).
    priv fn _is_ref(self, t: unsafe *Type) -> bool {
        if t == &null {
            return false
        }

        var unsafe *c = canon_unqual(
            if (t->canonical != &null) => (t->canonical) else => t,
        )

        return c != &null && (isa<CXXLValueRefType>(c) || isa<CXXRValueRefType>(c))
    }

    /// A value passed to `p` is only read: by value (a copy), `const`, or
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
                && canon_has_const(
                    if (ref->canonical != &null) => (ref->canonical) else => ref,
                )
        }

        return true
    }

    /// # approving nodes

    fn visit_call_expr(self, n: *Expressions::CallExpr) -> bool {
        if self._pl.size() > 0 {
            self._pl_call(n)
        }

        var unsafe *f = dyn_cast<FunctionDecl>(callee_expr_decl(n->callee))
        var is_ctor = n->ctor_decl != &null && isa<FunctionDecl>(n->ctor_decl)
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

                // A loop's `op in (self)` with `recv_reads` reads `self` for
                // -Wconst-self only: for any other parameter a read here
                // would make it a `const T&` in C++, whose call then picks
                // `op in (const self)` with another yield type.
                var loop_read = n->recv_reads && self._is_self_ref(r)
                if r != &null && (thru || f->is_const() || loop_read) {
                    self._claim(r)
                } else if r != &null && self._lint {
                    self._defer(r, f)
                }
            }
        }

        if f != &null {
            var view: [unsafe *ParamDecl]
            for var i: usize = 0; i < f->params.size(); ++i {
                var unsafe *p = f->params[i]
                if p == &null {
                    continue
                }

                if p->is_self && (bound || is_ctor) {
                    continue
                }

                view.push(p)
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
            var unsafe *t = canon_unqual(
                self._tu.strip_nullable(n->callee->type_),
            )

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
            // Comparing two pointers through an operator declaration
            // compares the addresses: nothing is written through them.
            if self._pl.size() > 0
                && self._pl_is_pointer(n->lhs->type_)
                && !self._pl_is_pointer(n->type_) {
                self._pl_read(n->lhs, &null)
                self._pl_read(n->rhs, &null)
            }

            return true
        }

        // A builtin operator reads its operands; one that makes a pointer
        // (`p + 1`) hands the levels on, which nothing here follows.
        if self._pl.size() > 0 && !self._pl_is_pointer(n->type_) {
            self._pl_read(n->lhs, &null)
            self._pl_read(n->rhs, &null)
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
            || k == TokenKind::OpAmp && n->const_addr // `const &p`: a `*const T`, read through only.
        if reads {
            self._approve(n->operand)
        }

        if self._pl.size() > 0 {
            if k == TokenKind::OpAmp {
                if n->const_addr {
                    self._pl_claim(
                        n->operand,
                        self._pl_const_addr(self._pl_path(n->operand)),
                    )
                } else {
                    self._pl_write(n->operand, false)
                }
            } else if k == TokenKind::OpPlusPlus || k == TokenKind::OpMinusMinus {
                self._pl_write(n->operand, true)
            } else if k != TokenKind::OpStar {
                self._pl_read(n->operand, &null)
            }
        }

        return true
    }

    fn visit_assign_operator_expr(self, n: *Expressions::AssignOperatorExpr) -> bool {
        if n->resolved_op != &null {
            return true
        }

        self._approve(n->rhs)
        if self._pl.size() > 0 {
            self._pl_write(n->lhs, true)
            self._pl_read(
                n->rhs,
                if (n->lhs != &null) => (n->lhs->type_) else => &null,
            )
        }

        return true
    }

    fn visit_subscript_expr(self, n: *Expressions::SubscriptExpr) -> bool {
        self._approve(n->index)
        if self._pl.size() > 0 {
            self._pl_read(n->index, &null)
        }

        return true
    }

    fn visit_type_cast_expr(self, n: *Expressions::TypeCastExpr) -> bool {
        if n->resolved_op != &null || n->resolved_ctor != &null {
            return true
        }

        if self._is_ref(n->target) {
            return true
        }

        if self._pl.size() > 0 {
            self._pl_read(n->operand, n->target)
        }

        // `&x as *const T` (IterLowering's call of `op in (const self)` on
        // a mutable object): the address is taken only to read through it.
        var unsafe *amp = self._tu.strip_parens(n->operand)
        if amp != &null
            && isa<Expressions::UnaryOperatorExpr>(amp)
            && cast<Expressions::UnaryOperatorExpr>(amp)->resolved_op == &null
            && cast<Expressions::UnaryOperatorExpr>(amp)->op_token.kind == TokenKind::OpAmp
            && self._ptr_to_const(n->target) {
            self._approve(cast<Expressions::UnaryOperatorExpr>(amp)->operand)
            return true
        }

        self._approve(n->operand)
        return true
    }

    /// `r` names a method's `self`.
    priv fn _is_self_ref(self, r: unsafe *NamedIdentExpr) -> bool {
        if r == &null {
            return false
        }

        var unsafe *p = dyn_cast<ParamDecl>(r->resolved_decl)
        return p != &null && p->is_self
    }

    /// `t` is a pointer to const (`*const T`).
    priv fn _ptr_to_const(self, t: unsafe *Type) -> bool {
        if t == &null {
            return false
        }

        var unsafe *c = canon_unqual(
            if (t->canonical != &null) => (t->canonical) else => t,
        )

        return c != &null
            && c->kind == TypeKind::PointerType
            && canon_has_const(cast<PointerType>(c)->pointee)
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
        if self._pl.size() > 0 {
            self._pl_read(n->condition, &null)
            for var i: usize = 0; i < n->else_ifs.size(); ++i {
                self._pl_read(n->else_ifs.get(i)->condition, &null)
            }
        }

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
        if self._pl_fns.size() > 0
            && self._pl_fns[self._pl_fns.size() - 1] != 0
            && !n->place_ref
            && !n->raw_slot
            && n->name.range.is_valid()
            && (n->storage == StorageClass::Var || n->storage == StorageClass::Const) {
            self._pl_add(unsafe (n as unsafe *Decl), n->type_)
        }

        if self._pl.size() > 0 && n->init != &null && !n->place_ref && !n->raw_slot {
            if self._is_ref(n->type_) {
                self._pl_write(n->init, false)
            } else {
                self._pl_read(n->init, n->type_)
            }
        }

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

        // A closure's `return` leaves with the closure's type, which _ret
        // does not hold: a pointer it returns is taken as kept as it is.
        if self._pl.size() > 0 && self._closures > 0 {
            self._pl_read(n->value, n->value->type_)
        } else if self._pl.size() > 0 && self._ret.size() > 0 {
            var unsafe *rt = self._ret[self._ret.size() - 1]
            if self._is_ref(rt) {
                self._pl_write(n->value, false)
            } else {
                self._pl_read(n->value, rt)
            }
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
        if self._pl.size() > 0 {
            self._pl_read(n->cond, &null)
        }

        return true
    }

    fn visit_while_loop_stmt(self, n: *WhileLoopStmt) -> bool {
        self._approve(n->cond)
        if self._pl.size() > 0 {
            self._pl_read(n->cond, &null)
        }

        return true
    }

    fn visit_runtime_assert_stmt(self, n: *RuntimeAssertStmt) -> bool {
        self._approve(n->condition)
        self._approve(n->message)
        if self._pl.size() > 0 {
            self._pl_read(n->condition, &null)
        }

        return true
    }

    /// # -Wconst-self: pointee levels (SC360W)

    /// No use limits a level: more than any pointer has.
    static fn _pl_all() -> u32 {
        return 1000
    }

    /// `t` is a pointer (C++ references looked through).
    priv fn _pl_is_pointer(self, t: unsafe *Type) -> bool {
        var unsafe *c = self._pl_value(t)
        return c != &null && c->kind == TypeKind::PointerType
    }

    /// `t`'s canonical, unqualified, with a C++ reference looked through.
    priv fn _pl_value(self, t: unsafe *Type) -> unsafe *Type {
        if t == &null {
            return &null
        }

        var unsafe *c = canon_unqual(
            if (t->canonical != &null) => (t->canonical) else => t,
        )

        if c != &null && isa<CXXLValueRefType>(c) {
            c = canon_unqual(cast<CXXLValueRefType>(c)->referee)
        } else if c != &null && isa<CXXRValueRefType>(c) {
            c = canon_unqual(cast<CXXRValueRefType>(c)->referee)
        }

        return c
    }

    /// How many leading pointee levels of `t` are const: `*const *T` is 1,
    /// `*const *const T` 2. Not a pointer: every level (a value converted
    /// to it, such as a `bool`, carries no way to write).
    priv fn _pl_const_prefix(self, t: unsafe *Type) -> u32 {
        var unsafe *c = self._pl_value(t)
        if c == &null {
            return 0
        }

        if c->kind != TypeKind::PointerType {
            return ParamPassInference::_pl_all()
        }

        var n: u32 = 0
        while c != &null && c->kind == TypeKind::PointerType {
            var unsafe *pe = cast<PointerType>(c)->pointee
            if !canon_has_const(pe) {
                return n
            }

            n += 1
            c = canon_unqual(pe)
        }

        return n
    }

    /// Watch `d`, a parameter or local whose written type `w` is a pointer
    /// with a pointee level that is not const. A type behind an alias, a
    /// dependent one or one with no source has nowhere for the fix-it.
    priv fn _pl_add(self, d: unsafe *Decl, w: unsafe *Type) {
        if w == &null || w->canonical == &null || !w->range.is_valid() {
            return
        }

        if !isa<PointerType>(w) || w->canonical->is_dependent() {
            return
        }

        var unsafe *c    = canon_unqual(w->canonical)
        var        depth = 0 as u32
        var        open  = false
        while c != &null && c->kind == TypeKind::PointerType {
            depth += 1
            var unsafe *pe = cast<PointerType>(c)->pointee
            if !canon_has_const(pe) {
                open = true
            }

            c = canon_unqual(pe)
        }

        if !open {
            return
        }

        var pc = PointeeCand{}
        pc.decl    = d
        pc.written = w
        pc.depth   = depth
        pc.levels  = depth
        self._pl.push(pc)
        self._pl_index[d as usize as u64] = (self._pl.size() as u64)
    }

    priv fn _pl_of(self, d: unsafe *Decl) -> usize {
        if d == &null {
            return usize::MAX
        }

        var it = self._pl_index.find(d as usize as u64)
        return if (it == self._pl_index.end()) => (usize::MAX) else => ((it->second - 1) as usize)
    }

    /// A reference to a candidate: the levels the use that claimed it
    /// leaves unwritten, and none when no use claimed it.
    priv fn _pl_ref(self, n: *NamedIdentExpr) {
        var k = self._pl_of(n->resolved_decl)
        if k == usize::MAX {
            return
        }

        var got = 0 as u32
        var it  = self._pl_claims.find(n as usize as u64)
        if it != self._pl_claims.end() {
            got = it->second
        }

        if got < self._pl[k].levels {
            self._pl[k].levels = got
        }
    }

    /// The path from a candidate reference to `e`, or one with no `ref`.
    priv fn _pl_path(self, e: unsafe *Expr) -> PointeePath {
        var        none = PointeePath{}
        var unsafe *x   = e
        if x == &null {
            return none
        }

        if isa<Expressions::ParenExpr>(x) {
            return self._pl_path(cast<Expressions::ParenExpr>(x)->inner)
        }

        if isa<Expressions::UnsafeExpr>(x) {
            return self._pl_path(cast<Expressions::UnsafeExpr>(x)->operand)
        }

        if isa<NamedIdentExpr>(x) {
            var unsafe *ni = cast<NamedIdentExpr>(x)
            if self._pl_of(ni->resolved_decl) == usize::MAX {
                return none
            }

            var r = PointeePath{}
            r.ref = ni
            return r
        }

        if isa<Expressions::UnaryOperatorExpr>(x) {
            var unsafe *u = cast<Expressions::UnaryOperatorExpr>(x)
            if u->resolved_op != &null || u->op_token.kind != TokenKind::OpStar {
                return none
            }

            var r = self._pl_path(u->operand)
            return self._pl_deref(r)
        }

        if isa<ChainExpr>(x) {
            var unsafe *ce = cast<ChainExpr>(x)
            return self._pl_chain(ce, ce->steps.size())
        }

        if isa<Expressions::SubscriptExpr>(x) {
            var unsafe *se = cast<Expressions::SubscriptExpr>(x)
            if se->resolved_op != &null {
                return none
            }

            var unsafe *bt = if (se->base != &null) => (self._pl_value(
                                 se->base->type_,
                             ))
                             else => &null
            if bt == &null {
                return none
            }

            var r = self._pl_path(se->base)
            if r.ref == &null {
                return none
            }

            if bt->kind == TypeKind::PointerType {
                return self._pl_deref(r)
            }

            if bt->kind == TypeKind::FixedArrayType {
                return self._pl_member(r)
            }

            return none
        }

        return none
    }

    /// One more deref of the place `r` names.
    priv fn _pl_deref(self, r: PointeePath) -> PointeePath {
        var o = r
        if o.ref == &null {
            return o
        }

        if o.member {
            o.detached = true
        } else {
            o.k += 1
        }

        return o
    }

    /// A field or element of the object `r` names.
    priv fn _pl_member(self, r: PointeePath) -> PointeePath {
        var o = r
        if o.ref == &null || o.member {
            return o
        }

        if o.k == 0 {
            // The candidate itself is a pointer, with no fields.
            return PointeePath{}
        }

        o.member = true
        o.obj    = o.k
        return o
    }

    /// _pl_path of `ce` cut to its first `nsteps` steps.
    priv fn _pl_chain(self, ce: unsafe *ChainExpr, nsteps: usize) -> PointeePath {
        var none = PointeePath{}
        var r    = self._pl_path(ce->base)
        if r.ref == &null {
            return none
        }

        for var i: usize = 0; i < nsteps; ++i {
            var unsafe *st = ce->steps.get(i)
            var field = st->target == ChainExpr::StepTarget::TupleIndex
                || st->target == ChainExpr::StepTarget::Name
                    && st->resolved_decl != &null
                    && isa<FieldDecl>(st->resolved_decl)
            if !field {
                return none
            }

            if st->access_kind == ChainExpr::AccessKind::Arrow {
                r = self._pl_member(self._pl_deref(r))
            } else if st->access_kind == ChainExpr::AccessKind::Dot {
                r = self._pl_member(r)
            } else {
                return none
            }

            if r.ref == &null {
                return none
            }
        }

        return r
    }

    /// Record that the use at `e`'s reference leaves `levels` unwritten.
    /// The outermost use claims first: a parent is visited before its
    /// operands.
    priv fn _pl_claim(self, e: unsafe *Expr, levels: u32) {
        var r = self._pl_path(e)
        self._pl_claim_path(r, levels)
    }

    priv fn _pl_claim_path(self, r: PointeePath, levels: u32) {
        if r.ref == &null {
            return
        }

        var key = r.ref as usize as u64
        if self._pl_claims.count(key) != 0 {
            return
        }

        self._pl_claims[key] = levels
    }

    /// `e`'s value is read, and when it is a pointer it is copied into a
    /// place of type `dest` (null: compared or tested, never kept).
    priv fn _pl_read(self, e: unsafe *Expr, dest: unsafe *Type) {
        var r = self._pl_path(e)
        if r.ref == &null {
            return
        }

        var k = self._pl_of(r.ref->resolved_decl)
        if r.member || r.k >= self._pl[k].depth || dest == &null {
            self._pl_claim_path(r, ParamPassInference::_pl_all())
            return
        }

        self._pl_claim_path(r, r.k + self._pl_const_prefix(dest))
    }

    /// `e` is written, or its address escapes as a mutable one (`rebind`:
    /// written by an assignment or `++`, where the candidate itself is
    /// only repointed).
    priv fn _pl_write(self, e: unsafe *Expr, rebind: bool) {
        var r = self._pl_path(e)
        if r.ref == &null {
            return
        }

        if r.member {
            self._pl_claim_path(
                r,
                if (r.detached) => (ParamPassInference::_pl_all()) else => r.obj - 1,
            )

            return
        }

        if r.k == 0 {
            self._pl_claim_path(
                r,
                if (rebind) => (ParamPassInference::_pl_all()) else => 0,
            )

            return
        }

        self._pl_claim_path(r, r.k - 1)
    }

    /// `const &e`: what `e` holds stays unwritten, what it points at does not.
    priv fn _pl_const_addr(self, r: PointeePath) -> u32 {
        if r.ref == &null {
            return 0
        }

        var k = self._pl_of(r.ref->resolved_decl)
        if r.member || r.k >= self._pl[k].depth {
            return ParamPassInference::_pl_all()
        }

        return r.k
    }

    /// A call: its receiver object, written unless the method is `const`,
    /// and each argument as its parameter takes it.
    priv fn _pl_call(self, n: *Expressions::CallExpr) {
        var unsafe *f = dyn_cast<FunctionDecl>(callee_expr_decl(n->callee))
        if n->ctor_decl != &null && isa<FunctionDecl>(n->ctor_decl) {
            f = cast<FunctionDecl>(n->ctor_decl)
        }

        var unsafe *callee = self._tu.strip_parens(n->callee)
        var        bound   = false
        if f != &null && f->is_method() && callee != &null && isa<ChainExpr>(callee) {
            var unsafe *ce   = cast<ChainExpr>(callee)
            var unsafe *last = ce->steps.get(ce->steps.size() - 1)
            var        arrow = last->access_kind == ChainExpr::AccessKind::Arrow
            if arrow || last->access_kind == ChainExpr::AccessKind::Dot {
                bound = true
                var r = self._pl_chain(ce, ce->steps.size() - 1)
                if arrow {
                    r = self._pl_deref(r)
                }

                if r.ref != &null && !r.member && r.k == 0 {
                    r = PointeePath{}
                }

                var obj = if (r.member) => (r.obj) else => r.k
                if r.ref != &null {
                    if f->is_const() || r.detached {
                        self._pl_claim_path(r, ParamPassInference::_pl_all())
                    } else {
                        self._pl_claim_path(r, obj - 1)
                    }
                }
            }
        }

        if f != &null {
            var view: [unsafe *ParamDecl]
            for var i: usize = 0; i < f->params.size(); ++i {
                var unsafe *p = f->params[i]
                if p == &null || p->is_self && (bound || n->ctor_decl != &null) {
                    continue
                }

                view.push(p)
            }

            for var i: usize = 0; i < n->args.size(); ++i {
                var unsafe *a = n->args[i]
                if a == &null {
                    continue
                }

                if i >= view.size() {
                    self._pl_read(a, a->type_)
                    continue
                }

                var unsafe *p = view[i]
                // An extension member's receiver, an argument once lowered:
                // read only through `const self`.
                if p->is_self {
                    if p->is_const {
                        self._pl_claim(a, ParamPassInference::_pl_all())
                    } else {
                        self._pl_write(a, false)
                    }
                } else if p->mode == ParamMode::Inout {
                    self._pl_write(a, false)
                } else if p->type_ != &null && self._pl_mutable_ref(p->type_) {
                    self._pl_write(a, false)
                } else {
                    self._pl_read(a, p->type_)
                }
            }

            return
        }

        // Through a `fn` value: the type's parameters.
        var unsafe *t = if (n->callee != &null && n->callee->type_ != &null) => (canon_unqual(
                            self._tu.strip_nullable(n->callee->type_),
                        ))
                        else => &null
        var unsafe *fp = if (t != &null
                             && isa<FunctionPointerType>(t)) => (cast<FunctionPointerType>(
                             t,
                         ))
                         else => &null
        for var i: usize = 0; i < n->args.size(); ++i {
            var unsafe *a = n->args[i]
            if fp == &null || i >= fp->params.size() || i >= fp->modes.size() {
                self._pl_read(a, if (a != &null) => (a->type_) else => &null)
                continue
            }

            if fp->modes[i] == ParamMode::Inout || self._pl_mutable_ref(fp->params[i]) {
                self._pl_write(a, false)
            } else {
                self._pl_read(a, fp->params[i])
            }
        }
    }

    /// `t` is a C++ `T&` or `T&&` to a non-const `T`.
    priv fn _pl_mutable_ref(self, t: unsafe *Type) -> bool {
        var unsafe *c = canon_unqual(
            if (t->canonical != &null) => (t->canonical) else => t,
        )

        if c != &null && isa<CXXLValueRefType>(c) {
            return !canon_has_const(cast<CXXLValueRefType>(c)->referee)
        }

        if c != &null && isa<CXXRValueRefType>(c) {
            return !canon_has_const(cast<CXXRValueRefType>(c)->referee)
        }

        return false
    }

    /// Candidate `k`'s verdict: when its first levels can all be const and
    /// one of them is not, SC360W with a fix-it inserting each `const`. A
    /// level is suggested only with every level above it: `**T` to
    /// `**const T` is no implicit conversion, so callers would break.
    priv fn _pl_decide(self, k: usize) {
        var        c                   = self._pl[k]
        var        upto                = if (c.levels < c.depth) => (c.levels) else => c.depth
        var unsafe *node               = c.written
        var        at:   [SourceRange]
        for var lv: u32 = 1; lv <= upto; ++lv {
            if node == &null || !isa<PointerType>(node) {
                return
            }

            var unsafe *pe = cast<PointerType>(node)->pointee
            if pe == &null || !pe->range.is_valid() {
                return
            }

            if !canon_has_const(
                if (pe->canonical != &null) => (pe->canonical) else => pe,
            ) {
                at.push(pe->range)
            }

            node = pe
        }

        if at.size() == 0 {
            return
        }

        // The type as the fix-it leaves it: `*const *const T`.
        var        want = ""
        var unsafe *t   = canon_unqual(c.written->canonical)
        for var lv: u32 = 1; lv <= c.depth; ++lv {
            var unsafe *pt = cast<PointerType>(t)
            want += if (pt->is_unsafe) => ("unsafe *") else => "*"
            if lv <= upto || canon_has_const(pt->pointee) {
                want += "const "
            }

            t = canon_unqual(pt->pointee)
        }

        want += self._tu.str(t)
        self.n_pointee += 1
        var unsafe *d = c.decl
        var        nm = self._tu.decl_name(d)
        var what = if (isa<ParamDecl>(d)) => ("parameter") else => "variable"
        var b = self.sc->diag->report(
            DiagID::SC360W,
            c.written->range.start,
            f"{what} '{nm}' is never written through; declare it '{want}'",
        )

        b.first(c.written->range)
        for var i: usize = 0; i < at.size(); ++i {
            b.insert(at[i].start, "const ", "point to const")
        }

        b.emit()
    }
}
