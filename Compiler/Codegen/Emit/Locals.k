/// --- The Kairo Project ------------------------ Codegen/Emit/Locals.k --- ///
///
///   EmitIR, part: locals and storage. Local declarations and their
///   initializers, local records, namespace-scope variables, the names a local
///   is spelled by, and the union-stored locals
///   (Compiler/Spec/Lowering.md#union-storage-locals): their storage, the uses
///   that read it, the `finally()` and disarm sites that end it, and the
///   assignment that builds one again after `finally()`.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "llvm/ADT/DenseMap.h"
ffi "c++" import "llvm/ADT/DenseSet.h"
ffi "c++" import "Native/Types.hh"
ffi "c++" import "Native/Shims.hh"
ffi "c++" import "clang/Basic/TokenKinds.h"
ffi "c++" import "vector"

import AST::AttrFacts::AttrFacts
import AST::DeclFacts::{
    decl_fold_pin,
    decl_name_tok,
    decl_pattern,
}
import AST::Kind::DeclKind::{
    DeclKind,
    to_string,
}
import AST::Kind::ExprKind::to_string
import AST::Kind::StmtKind::to_string
import AST::Kind::TypeKind::{
    TypeKind,
    to_string,
}
import AST::LangItems::{
    LowerTargets,
    to_string,
}
import AST::Node::Base::{
    Decl,
    Type,
}
import AST::Node::CanonicalNodes::{
    RecordType,
    canon_has_const,
    canon_unqual,
}
import AST::Node::Casting::{
    cast,
    dyn_cast,
    isa,
}
import AST::Node::Declarations::{
    ClassDecl,    FieldDecl,  FnBodyKind,    FunctionDecl, LocalDtor, ParamDecl, ParamOwner,
    StorageClass, StructDecl, TypeAliasDecl, VariableDecl,
}
import AST::Node::Expressions::{
    AssignOperatorExpr, CallExpr,     FinalizeKind, InitListExpr, REMAKE_DEAD, REMAKE_LIVE,
    REMAKE_MAYBE,       TypeCastExpr,
}
import AST::Node::PrimaryExpressions::{
    ChainExpr,
    NamedIdentExpr,
}
import AST::Node::Statements::DeclStmt
import AST::Node::Types::{
    FixedArrayType,
    PointerType,
}
import Codegen::Emit::Convert
import Codegen::Emit::Ctors
import Codegen::Emit::Decls
import Codegen::Emit::EmitIR::EmitIR
import Codegen::Emit::Exprs
import Codegen::Emit::Literals
import Codegen::Emit::Names
import Codegen::Emit::Stmts
import Codegen::Plan::Visitors::GlobalInitReach
import Codegen::Spell::Spell::Speller
import Diagnostic::Code::DiagCode
import Diagnostic::Registry::DiagID
import Location::SourceRange::SourceRange
import Token::Token::Token
import Token::TokenKind::TokenKind

extend EmitIR {
    /// The body that declared the union-stored locals from row `mark` on
    /// is written. An Elided or Flagged local no written site ended would
    /// never be destroyed: its mode and its sites came from one provider
    /// (Sema/Check/LocalDisposition.k), so a mismatch is an ICE, never a
    /// silent leak.
    prot fn _ul_leave(self, mark: usize) {
        for var i: usize = mark; i < self._ul_decl.size(); ++i {
            var unsafe *v = self._ul_decl[i]
            // Storage that starts empty is ended by its flag alone.
            if v->dtor_mode != LocalDtor::Cleanup && self._ul_ends[i] == 0 && !v->starts_empty {
                self._ice(
                    v->range,
                    "EmitIR: a local whose destructor is elided or flagged has no site that ends it; its mode and its sites disagree",
                )
            }

            self._ul_row.erase(v as usize as u64)
        }

        while self._ul_decl.size() > mark {
            self._ul_decl.pop_back()
            self._ul_store.pop_back()
            self._ul_obj.pop_back()
            self._ul_ends.pop_back()
        }
    }

    /// `d`'s row when it is a union-stored local a use here spells through
    /// its storage, else usize(-1). Inside a closure that captures it, the
    /// name is the closure's own copy (_capture_list), spelled bare.
    prot fn _ul_use(self, d: unsafe *Decl) -> usize {
        if d == &null || self._ul_decl.empty() {
            return usize::MAX
        }

        var it = self._ul_row.find(d as usize as u64)
        if it == self._ul_row.end() {
            return usize::MAX
        }

        if self._closure != &null {
            for var i: usize = 0; i < self._closure->held.size(); ++i {
                if self._closure->held[i].decl == d {
                    return usize::MAX
                }
            }
        }

        return it->second as usize
    }

    /// The declaration of the union-stored local `n`, in place of
    /// `T x = init` (no trailing `;`; _decl writes it):
    ///   Cleanup  `::__kairo_ul<T> __k_s_x{init}; <hook>`
    ///   Elided   `::__kairo_ul<T> __k_s_x{init}`
    ///   Flagged  `::__kairo_ulf<T> __k_s_x{{init}, true}; <hook>`
    /// where the hook is `__attribute__((cleanup(__kairo_ul_run)))
    /// ::__kairo_ulh __k_h_x{&__k_s_x, &<storage type>::__drop}`, declared
    /// after the object so a path that leaves while the initializer runs
    /// destroys nothing. A Cleanup local with moved parts
    /// (VariableDecl::moved_parts) has a hook of its own instead, which
    /// destroys what is left (_residual).
    /// `{}` for `var x: T` value-initializes as `T x{}`
    /// does. False when this declaration cannot take the storage: only a
    /// Cleanup local, which is then the plain `T x` it is equivalent to.
    priv fn _union_local_decl(self, n: unsafe *VariableDecl, in_for_init: bool) -> bool {
        var m   = n->dtor_mode
        var why = ""
        if in_for_init {
            why = "a C-style for's variable"
        } else if n->type_ == &null || n->type_->canonical == &null {
            why = "a local with no type"
        } else if self._spell.names_hidden_member(n->type_) {
            why = "a local whose type is a hidden member type"
        } else if AttrFacts::decl_align_attr(
            n,
            self._cg->ctx->tcm->get_imm_table_for_fid(self._owning_fid()),
        ).size() > 0 {
            why = "an '@align' local"
        }

        if why.size() > 0 {
            if m == LocalDtor::Cleanup {
                return false
            }

            self._ice(
                n->range,
                "EmitIR: union storage for " + why + "; LocalDisposition gives only Cleanup to one",
            )
        }

        var ty = self._spell._type(n->type_)
        if n->is_const() {
            ty = self._spell.const_decl(n->type_, "")
        }

        // From the local's own C++ name: a shadowing local (its rebind)
        // has storage and a hook of its own beside the binding it hides.
        var nm    = self._local_name(unsafe (n as unsafe *Decl))
        var store = LowerTargets::union_local_store(nm)
        var ul    = "::" + LowerTargets::union_local() + "<" + ty + ">"
        var st = if (m == LocalDtor::Flagged) => ("::" + LowerTargets::union_local_flagged() + "<" + ty + ">")
                 else => ul
        var at = n->name.range
        if n->starts_empty {
            if m != LocalDtor::Flagged || n->init != &null {
                self._ice(
                    n->range,
                    "EmitIR: storage that starts empty must be flagged and have no initializer",
                )
            }

            self._cg->sink->spell(
                at,
                st.copy() + " " + store + "{{." + LowerTargets::union_local_none() + " = 0}, false}",
            )
        } else {
            self._cg->sink->spell(at, st.copy() + " " + store + "{")
            if m == LocalDtor::Flagged {
                self._cg->sink->spell(at, "{")
            }

            if n->init == &null {
                self._cg->sink->spell(at, "{}")
            } else {
                self._value(n->init, n->type_)
            }

            if m == LocalDtor::Flagged {
                self._cg->sink->spell(at, "}, true")
            }

            self._cg->sink->spell(at, "}")
        }

        if m != LocalDtor::Elided {
            var drop = "&" + st + "::" + LowerTargets::union_local_drop()
            if n->moved_parts.size() > 0 {
                if m != LocalDtor::Cleanup {
                    self._ice(
                        n->range,
                        "EmitIR: moved parts on a local whose storage is not Cleanup; LocalDisposition writes them only with Cleanup",
                    )
                }

                drop = "+[](void* q) noexcept { auto& " + LowerTargets::union_local_obj() + " = static_cast<" + st + "*>(q)->" + LowerTargets::union_local_obj() + "; " + self._residual(
                    n,
                ) + "}"
            }

            self._cg->sink->spell(
                at,
                "; __attribute__((cleanup(" + LowerTargets::union_local_run() + "))) ::" + LowerTargets::union_local_hook() + " " + LowerTargets::union_local_hook_var(
                    nm,
                ) + "{&" + store + ", " + drop + "}",
            )
        }

        var obj = if (m == LocalDtor::Flagged) => (store.copy() + ".s." + LowerTargets::union_local_obj())
                  else => store.copy() + "." + LowerTargets::union_local_obj()
        self._ul_row[n as usize as u64] = self._ul_decl.size() as u64
        self._ul_decl.push_back(n)
        self._ul_store.push_back(store)
        self._ul_obj.push_back(obj)
        self._ul_ends.push_back(0)
        return true
    }

    /// The destruction of what is left of `n` once its moved parts are
    /// out (VariableDecl::moved_parts): each remaining by-value field of
    /// its class in reverse declaration order, as the implicit destructor
    /// would run them, a field with a moved part of its own taken apart
    /// the same way. The object is the hook's `v` (_union_local_decl).
    priv fn _residual(self, n: unsafe *VariableDecl) -> string {
        var unsafe *r = dyn_cast<RecordType>(canon_unqual(n->type_->canonical))
        if r == &null || r->decl == &null || !isa<ClassDecl>(decl_pattern(r->decl)) {
            self._ice(
                n->range,
                "EmitIR: moved parts on a local that is not a class; LocalDisposition gives them only to one",
            )
        }

        var starts: [usize]
        var at:     usize   = 0
        while at < n->moved_parts.size() {
            starts.push(at)
            while n->moved_parts[at] != &null {
                at += 1
            }

            at += 1
        }

        return self._residual_of(
            cast<ClassDecl>(decl_pattern(r->decl)),
            LowerTargets::union_local_obj(),
            n,
            starts,
            0,
        )
    }

    /// _residual for the class `c` at `obj`, the paths of `n`'s moved parts
    /// that start at `starts` all running through it, `depth` fields in.
    /// `c` is a pattern, never an instance, which has no fields of its
    /// own. Every path must name one of `c`'s fields: one that names none
    /// would leave a field undestroyed, so it is an ICE.
    priv fn _residual_of(self,
                         c:            unsafe *ClassDecl,
                         const obj:    string,
                         n:            unsafe *VariableDecl,
                         const starts: [usize],
                         depth:        usize) -> string {
        var s              = ""
        var matched: usize = 0
        var i              = c->fields.size()
        while i > 0 {
            i -= 1
            var unsafe *fd = c->fields[i]
            if fd == &null || fd->is_static() {
                continue
            }

            var nm = self._spell.tok_name(
                fd->name,
                Speller::fid_of(unsafe (fd as unsafe *Decl)),
            )

            // By name: an instance's fields and the pattern's that a
            // moved part's path may hold are different declarations, and
            // a class's field names are its own.
            var whole         = false
            var sub:  [usize]
            for var k: usize = 0; k < starts.size(); ++k {
                var unsafe *pf = n->moved_parts[starts[k] + depth]
                if pf == &null
                    || self._spell.tok_name(
                        pf->name,
                        Speller::fid_of(unsafe (pf as unsafe *Decl)),
                    ) != nm {
                    continue
                }

                matched += 1
                if n->moved_parts[starts[k] + depth + 1] == &null {
                    whole = true
                } else {
                    sub.push(starts[k])
                }
            }

            var at = obj.copy() + "." + nm

            if whole {
                if sub.size() > 0 {
                    self._ice(
                        n->range,
                        "EmitIR: a moved part inside another; LocalDisposition refuses overlapping parts",
                    )
                }

                continue
            }

            if sub.size() == 0 {
                s += "::" + LowerTargets::union_local_destroy() + "(" + at + "); "
                continue
            }

            var unsafe *next                   = n->moved_parts[sub[0] + depth + 1]
            var        nc:   unsafe *ClassDecl = &null
            if next->semantic_dc != &null && next->semantic_dc->dc_owner != &null {
                nc = dyn_cast<ClassDecl>(next->semantic_dc->dc_owner)
            }

            if nc == &null {
                self._ice(
                    n->range,
                    "EmitIR: a moved part's field outside a class; LocalDisposition gives them only to one",
                )
            }

            s += self._residual_of(nc, at, n, sub, depth + 1)
        }

        if matched != starts.size() {
            self._ice(
                n->range,
                "EmitIR: a moved part that names no field of its class; the rest of the local would not be destroyed",
            )
        }

        return s
    }

    /// `x.finally()` (CallExpr::finalize, decided by MoveCheck): the
    /// storage's `__end()`, which runs the destructor and, flagged, clears
    /// `live` first; nothing for a trivially destroyed local.
    prot fn _finally_site(self, n: unsafe *CallExpr) {
        if n->finalize == FinalizeKind::NoEffect {
            self._cg->sink->spell(n->range, "(void)0")
            return
        }

        if n->finalize != FinalizeKind::Ends {
            self._ice(
                n->range,
                "EmitIR: a finally() call MoveCheck did not decide",
            )
        }

        var unsafe *ce = dyn_cast<ChainExpr>(n->callee)
        var unsafe *ni = if (ce != &null) => (dyn_cast<NamedIdentExpr>(ce->base)) else => &null
        var r = if (ni != &null) => (self._ul_use(ni->resolved_decl)) else => usize::MAX
        if r == usize::MAX || self._ul_decl[r]->dtor_mode == LocalDtor::Cleanup {
            self._ice(
                n->range,
                "EmitIR: finally() on a local that is not elided or flagged; its mode and its sites disagree",
            )
        }

        self._cg->sink->spell(
            n->range,
            self._ul_store[r].copy() + "." + LowerTargets::union_local_end() + "()",
        )

        self._ul_ends[r] += 1
    }

    /// A move a provider disarmed (TypeCastExpr::disarms): the move, and
    /// what `finally()` does minus the destructor call. Flagged, `live` is
    /// cleared as the moved object is named, before the move constructor
    /// runs: nothing reads the flag but the hook at the scope's end, and a
    /// real transfer's constructor is a Kairo one, which cannot throw.
    /// Elided, nothing is left to run.
    prot fn _disarm_site(self, n: unsafe *TypeCastExpr) {
        // A move out of a parameter its body consumes: the guard's flag
        // is cleared with the move, as a flagged local's is.
        var unsafe *pd = dyn_cast<ParamDecl>(n->disarms)
        if pd != &null {
            if !self._param_guarded(self._cur_fn, pd) {
                self._cast(n)
                return
            }

            self._cg->sink->spell(
                n->range,
                "(" + LowerTargets::value_param_guard_var(
                    self._spell.tok_name(pd->name, self._owning_fid()),
                ) + ".live = false, ",
            )

            self._cast(n)
            self._cg->sink->spell(n->range, ")")
            return
        }

        var r = self._ul_use(n->disarms)
        if r == usize::MAX || self._ul_decl[r]->dtor_mode == LocalDtor::Cleanup {
            self._ice(
                n->range,
                "EmitIR: a disarmed move of a local that is not elided or flagged; its mode and its sites disagree",
            )
        }

        self._ul_ends[r] += 1
        if self._ul_decl[r]->dtor_mode != LocalDtor::Flagged {
            self._cast(n)
            return
        }

        self._cg->sink->spell(
            n->range,
            "(" + self._ul_store[r] + ".live = false, ",
        )

        self._cast(n)
        self._cg->sink->spell(n->range, ")")
    }

    /// `p`, a parameter of `f`, has a guard in `f`'s body: the body
    /// consumes it (ParamOwner::Consumed) and C++ passes it as `T&&`.
    prot fn _param_guarded(self, f: unsafe *FunctionDecl, p: unsafe *ParamDecl) -> bool {
        return f != &null
            && p != &null
            && p->owner == ParamOwner::Consumed
            && Speller::value_param_passed_rref(f, p)
    }

    /// The guards of the parameters `f`'s body consumes, first in the body
    /// (`::__kairo_pc<T> __k_g_p{&p, true};`): at every exit where no move
    /// cleared `live`, the guard moves the value into a temporary and
    /// destroys that, so the caller's object is moved-from on every path
    /// out of the body (Compiler/Spec/Ownership.md#by-value-parameters).
    prot fn _param_guards(self, f: unsafe *FunctionDecl, at: SourceRange) {
        for var i: usize = 0; i < f->params.size(); ++i {
            var unsafe *p = f->params[i]
            if !self._param_guarded(f, p) {
                continue
            }

            var nm = self._spell.tok_name(
                p->name,
                Speller::fid_of(unsafe (f as unsafe *Decl)),
            )

            self._cg->sink->spell(
                at,
                "::" + LowerTargets::value_param_guard() + "<" + self._spell._type(
                    p->type_,
                ) + "> " + LowerTargets::value_param_guard_var(
                    nm,
                ) + "{" + LowerTargets::clang_addressof() + "(" + nm + "), true};",
            )
        }
    }

    /// `x = e` that constructs a finalized local again
    /// (AssignOperatorExpr::remake): `e` built in place in the storage, as
    /// `T x = e` would build it, and `live` set when flagged. Maybe dead,
    /// the object a flagged `live` says is there is destroyed first.
    prot fn _remake(self, n: unsafe *AssignOperatorExpr) {
        var unsafe *ni = dyn_cast<NamedIdentExpr>(n->lhs)
        var r = if (ni != &null) => (self._ul_use(ni->resolved_decl)) else => usize::MAX
        var b     = n->remake
        var maybe = (b & REMAKE_MAYBE) != 0 || (b & REMAKE_DEAD) != 0 && (b & REMAKE_LIVE) != 0
        if r == usize::MAX
            || self._ul_decl[r]->dtor_mode == LocalDtor::Cleanup
            || maybe && self._ul_decl[r]->dtor_mode != LocalDtor::Flagged {
            self._ice(
                n->range,
                "EmitIR: a construction after finally() on a local whose mode cannot take it; its mode and its sites disagree",
            )
        }

        var obj = self._ul_obj[r].copy()
        var st  = self._ul_store[r].copy()
        var s   = "("
        if maybe {
            s += st.copy() + "." + LowerTargets::union_local_kill() + "(), "
        }

        s += "::new (static_cast<void*>(&" + obj + "), ::" + LowerTargets::union_local_place() + "{}) decltype(" + obj + ")("
        self._cg->sink->spell(n->range, s)
        self._value(n->rhs, n->lhs->type_)
        var t = ")"
        if self._ul_decl[r]->dtor_mode == LocalDtor::Flagged {
            t += ", " + st + ".live = true"
        }

        self._cg->sink->spell(n->range, t + ", void())")
    }

    prot fn _decl(self, n: unsafe *DeclStmt) {
        if n->decl == &null {
            self._ice(n->range, "EmitIR: DeclStmt with no decl")
        }

        match n->decl->kind {
            case DeclKind::VariableDecl {
                // A local S_post reads is its slot's first assignment.
                if self._slot_of(n->decl, false) != usize::MAX {
                    var dm = cast<VariableDecl>(n->decl)->dtor_mode
                    if dm == LocalDtor::Elided || dm == LocalDtor::Flagged {
                        self._ice(
                            n->range,
                            "EmitIR: a split constructor's carried local cannot take union storage; LocalDisposition gave it an ending mode",
                        )
                    }

                    self._slot_local_init(cast<VariableDecl>(n->decl))
                } else {
                    self._var_decl(cast<VariableDecl>(n->decl))
                }
            }

            // A `fn`, class or enum the user wrote here was hoisted to
            // namespace scope (Speller::is_hoisted_local): emit_tu defines
            // it there, and nothing of it stays in the body.
            default {
                if Speller::is_hoisted_local(n->decl) {
                    return
                }

                // An alias has no C++ entity: every use is spelled through
                // its canonical, as a file-scope one's is (emit()).
                if n->decl->kind == DeclKind::TypeAliasDecl {
                    return
                }

                if n->decl->kind == DeclKind::StructDecl {
                    self._local_record(cast<StructDecl>(n->decl))
                } else {
                    var unsafe *sdc = n->decl->semantic_dc
                    var scope_s = if (sdc == &null) => ("no semantic scope")
                                  else => f"semantic scope kind {((sdc->dc_kind as u8) as u32)}"
                    self._ice(
                        n->range,
                        f"EmitIR: a statement-scope {to_string(n->decl->kind)} that is neither hoisted nor a lowering's record ({scope_s}, implicit={n->decl->is_implicit})",
                    )
                }
            }
        }

        self._cg->sink->synth_at_end(n->range, clang::tok::semi)
    }

    /// `[const|static|constexpr] TYPE name [= init]`; no trailing `;`.
    /// After X `type_` is never null on a checked tree; `auto` is the
    /// pre-X fallback and is a bug if it ever prints for real code.
    prot fn _var_decl(self, n: unsafe *VariableDecl) {
        if n->kind == DeclKind::RecoveryDecl {
            self._ice(n->range, "EmitIR: poisoned VariableDecl reached codegen")
        }

        // A `try`'s raw slot (PanicLowering): storage only, built by a
        // SlotPut and read once by a SlotTake. No initializer: nothing is
        // built until a failing site builds it.
        if n->raw_slot {
            if n->type_ == &null || n->init != &null {
                self._ice(
                    n->range,
                    "EmitIR: a raw slot with no type or with an initializer; PanicLowering mints neither",
                )
            }

            self._cg->sink->spell(
                n->name.range,
                "::" + LowerTargets::raw_slot() + "<" + self._spell._type(
                    n->type_,
                ) + ">",
            )

            self._local_ref(unsafe (n as unsafe *Decl), n->name)
            return
        }

        // SequenceLowering's bound place (a forwarding reference to it) or
        // deduced copy.
        if n->place_ref || n->auto_copy {
            if n->init == &null {
                self._ice(
                    n->range,
                    "EmitIR: a bound place with no initializer; SequenceLowering always gives one",
                )
            }

            self._cg->sink->spell(
                n->name.range,
                if (n->place_ref) => ("auto&&") else => "auto",
            )

            self._local_ref(unsafe (n as unsafe *Decl), n->name)
            self._cg->sink->spell(n->name.range, " = (")
            self.emit(n->init)
            self._cg->sink->spell(n->name.range, ")")
            return
        }

        // A binder whose mode its instance decides (VariableDecl::
        // borrow_inst): a copy or a reference to const, per instance.
        if n->borrow_inst && n->init != &null && n->type_ != &null {
            self._cg->sink->spell(
                n->name.range,
                "::" + LowerTargets::binder_type() + "<" + self._spell._type(
                    n->type_,
                ) + ">",
            )

            self._local_ref(unsafe (n as unsafe *Decl), n->name)
            self._cg->sink->spell(n->name.range, " = (")
            self.emit(n->init)
            self._cg->sink->spell(n->name.range, ")")
            return
        }

        if n->dtor_mode != LocalDtor::Scope && self._union_local_decl(n, self._in_for_init) {
            return
        }

        if n->dtor_mode == LocalDtor::Scope && self._direct_closure(n) {
            return
        }

        // `@align(N)` on a local: GNU `aligned` leads the declaration.
        var la = AttrFacts::decl_align_attr(
            n,
            self._cg->ctx->tcm->get_imm_table_for_fid(self._owning_fid()),
        )

        if la.size() > 0 {
            self._cg->sink->spell(n->name.range, la)
        }

        // `const p: *T` freezes the pointer: its `const` follows the `*`
        // (after the type, below); a leading one would be the pointee's.
        var ptr_const = n->storage == StorageClass::Const && Speller::is_pointer(n->type_)
        match n->storage {
            case StorageClass::Const {
                if !ptr_const {
                    self._cg->sink->kw_const(n->name)
                }
            } case StorageClass::Static {
                self._cg->sink->kw_static(n->name)
            } case StorageClass::Eval {
                self._cg->sink->kw_constexpr(n->name)
            } default { }
        }

        // A function-local `thread` is `static thread_local`: one instance
        // per thread that keeps its value across calls (variables.mdx).
        // Left as plain `static`, every thread would share it.
        if n->is_thread {
            self._cg->sink->kw_thread_local(n->name)
        }

        // `static const x` (either order): the const is the binding's, so
        // C++ gets `static const T x`, which is what a const local would add.
        if n->const_binding {
            self._cg->sink->kw_const(n->name)
        }

        var c: unsafe *Type = &null
        if n->type_ != &null && n->type_->canonical != &null {
            c = canon_unqual(n->type_->canonical)
        }

        // A pointer to an array is `T (*name)[N]` (SequenceLowering binds an
        // array place by address): the name is inside that declarator too.
        var ptr_to_array = c != &null
            && c->kind == TypeKind::PointerType
            && canon_unqual(cast<PointerType>(c)->pointee) != &null
            && canon_unqual(cast<PointerType>(c)->pointee)->kind == TypeKind::FixedArrayType
        if c != &null && (c->kind == TypeKind::FixedArrayType || ptr_to_array) {
            // `T name[N]`: the name sits inside the declarator.
            var nm = self._local_name(unsafe (n as unsafe *Decl))
            var ds = if (ptr_const) => (self._spell.const_decl(n->type_, nm))
                     else => self._spell.decl(n->type_, nm)
            self._cg->sink->spell(n->name.range, ds)
        } else {
            // Deduced from a duck chain: `auto` is the type, the instance's.
            if n->type_ == &null && n->init != &null && self._duck_rooted_expr(n->init) {
                self._cg->sink->kw_auto(n->name)
            } else if n->type_ == &null {
                var nm = self._cg->ctx->get_spelling(n->name)
                self._cg->ctx->diag_sink.report(
                    DiagCode(DiagID::I011W),
                    n->name.range.start,
                    f"internal: '{nm}' reached codegen with no inferred type; This is a compiler bug; please report it with the source that triggered it",
                ).first(n->name.range)->emit()
                self._cg->sink->kw_auto(n->name)
            } else if n->type_->range.is_valid() && !self._spell.names_hidden_member(n->type_) {
                self.emit(n->type_)
            } else {
                // An inferred or written type that names a C++ class's
                // private/protected member type is spelled `auto` there.
                self._spell.auto_hidden = true
                var ts = self._spell._type(n->type_)
                self._spell.auto_hidden = false
                self._cg->sink->spell(n->name.range, ts)
            }

            if ptr_const {
                self._cg->sink->kw_const(n->name)
            }

            self._local_ref(unsafe (n as unsafe *Decl), n->name)
        }

        self._var_init(n, c)
    }

    /// A record declared in a function body: FinallyLowering's scope guard.
    /// `struct N { T* a; ~N() { body } }`, the destructor's body IN the
    /// class: a local class's members can be defined nowhere else
    /// ([class.local]), so invariant 12 does not reach here -- the whole
    /// struct is body text already. Nothing is planned for it (EmitPlan
    /// skips function-scope records), Speller names it by leaf, and every
    /// member is public: Kairo visibility is AccessCheck's. Only the shape
    /// the lowering mints is accepted: plain fields and one `op delete`.
    priv fn _local_record(self, n: unsafe *StructDecl) {
        var unsafe *d = unsafe (n as unsafe *Decl)
        var        at = Speller::at(d)
        var        nm = self._spell.leaf(d)
        self._cg->sink->spell(at, "struct " + nm + " {")
        for var i: usize = 0; i < n->fields.size(); ++i {
            var unsafe *f = n->fields[i]
            if f == &null {
                continue
            }

            if f->is_static() || f->init != &null {
                self._ice(
                    f->range,
                    "EmitIR: a function-scope record with a static or initialized field; FinallyLowering mints neither",
                )
            }

            self._cg->sink->spell(
                f->name.range,
                self._spell.decl(f->type_, self._spell.leaf(f)) + ";",
            )
        }

        for var i: usize = 0; i < n->methods.size(); ++i {
            var unsafe *m = n->methods[i]
            if m == &null {
                continue
            }

            if !m->is_operator
                || m->op_token.size() == 0
                || m->op_token[0].kind != TokenKind::KwFinally
                || m->body_kind != FnBodyKind::Block {
                self._ice(
                    m->range,
                    "EmitIR: a function-scope record with a member that is not a destructor with a body; FinallyLowering mints only that",
                )
            }

            self._cg->sink->spell(Speller::at(m), "~" + nm + "()")
            self._body(m, &null)
        }

        self._cg->sink->spell(at, "}")
    }

    /// `= init` for a variable whose declarator is already out; `c` is its
    /// unqualified canonical, or null.
    priv fn _var_init(self, n: unsafe *VariableDecl, c: unsafe *Type) {
        // `var x: T` is default-constructed (InitCheck proved T has one):
        // `T x{}` value-initializes -- a number or pointer to zero, an array
        // element-wise, a record through its default constructor. A bare
        // `T x;` would leave a local scalar indeterminate.
        if n->init == &null {
            self._cg->sink->synth_at_end(n->name.range, clang::tok::l_brace)
            self._cg->sink->synth_at_end(n->name.range, clang::tok::r_brace)
            return
        }

        self._cg->sink->synth_at_end(n->name.range, clang::tok::equal)
        var unsafe *il = dyn_cast<InitListExpr>(n->init)
        if il != &null && c != &null && c->kind == TypeKind::FixedArrayType {
            self._init_list(il, true) // a declarator's initializer: the one place bare braces are legal.
        } else {
            self._value(n->init, n->type_)
        }
    }

    /// A namespace-scope variable's definition, in its module's wrapper:
    /// `[constexpr] T const x = init;`. The declarator is Speller::global_var,
    /// the same text the interface's `extern` declaration used, so the two
    /// agree and a `const` keeps the external linkage that prior `extern`
    /// gave it. Definitions come in source order, which is C++'s dynamic
    /// initialization order within a TU: `B = A + 1` after `A` sees it set.
    prot fn _global_var(self, n: unsafe *VariableDecl) {
        if self._in_pch(unsafe (n as unsafe *Decl)) { // an eval binding the PCH defines.
            return
        }

        if n->type_ == &null {
            self._ice(
                n->range,
                "EmitIR: namespace-scope variable with no type reached codegen; X gate failure",
            )
        }

        var unsafe *d   = unsafe (n as unsafe *Decl)
        var        at   = Speller::at(d)
        var        wrap = self._open_ns(d, at)
        // `inline` (Compiler/Spec/Eval.md#eval-bindings): every TU that reads an eval binding
        // writes this same definition (EmitPlan::visible_eval_vars), since
        // an `extern const` is no constant expression to an importer.
        var head = if (n->is_eval()) => ("inline constexpr ") else => ""
        var c: unsafe *Type = &null
        if n->type_->canonical != &null {
            c = canon_unqual(n->type_->canonical)
        }

        var unsafe *saved = self._cur_global
        self._cur_global = n
        // An initializer that reaches a private member is checked by C++ in
        // the variable's context, which no record can befriend: it becomes
        // the body of a thunk its file's records do befriend
        // (GlobalInitReach, FileFriends::globals), and the variable calls it.
        if GlobalInitReach::needs_thunk(unsafe &self._spell, n) {
            self._cg->sink->spell(at, self._spell.ginit_decl(n) + " { return")
            self._value(n->init, n->type_)
            self._cg->sink->spell(at, "; }")
            self._cg->sink->brk()
            self._cg->sink->spell(
                at,
                head + self._spell.global_var(n) + " = " + LowerTargets::global_init_thunk(
                    self._spell.leaf(d),
                ) + "()",
            )

            self._cur_global = saved
            self._cg->sink->synth_at_end(n->range, clang::tok::semi)
            self._close_ns(n->range, wrap)
            return
        }

        self._cg->sink->spell(at, head + self._spell.global_var(n))
        var saved_ns = self._ns_init
        self._ns_init = true
        self._var_init(n, c)
        self._ns_init    = saved_ns
        self._cur_global = saved
        self._cg->sink->synth_at_end(n->range, clang::tok::semi)
        // Compiler/Spec/Eval.md#deferred-conditions: an `eval if` was decided on this constant's value as
        // Sema read it; clang computing another fails here, not silently.
        var pin = decl_fold_pin(d)
        if pin.size() > 0 {
            self._cg->sink->spell(
                at,
                "static_assert(" + self._spell.leaf(
                    d,
                ) + " == " + pin + ", \"EVAL.md 4.2b: an eval if was decided on this constant; Kairo's type facts and clang disagree on its value\");",
            )
        }

        self._close_ns(n->range, wrap)
    }

    /// A local's C++ name: its own, or for one that shadows a visible local
    /// of the same name (VariableDecl::rebind) a name of its own, so C++
    /// neither sees a redefinition nor reads the new binding in the
    /// initializer that still names the old one.
    prot fn _local_name(self, d: unsafe *Decl) -> string {
        var nm = self._spell.tok_name(decl_name_tok(d), self._owning_fid())
        var unsafe *v = dyn_cast<VariableDecl>(d)
        if v != &null && v->rebind > 0 {
            return LowerTargets::rebound_local(nm, v->rebind)
        }

        return nm
    }

    /// `t`, a declaration or use of local `d`, spelled as _local_name.
    prot fn _local_ref(self, d: unsafe *Decl, t: Token) {
        var unsafe *v = dyn_cast<VariableDecl>(d)
        if v == &null || v->rebind == 0 {
            self._name(t)
            return
        }

        self._cg->sink->create_ident(t.range, self._local_name(d))
    }
}
