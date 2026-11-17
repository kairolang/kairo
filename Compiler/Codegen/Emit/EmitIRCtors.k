/// --- The Kairo Project ------------------- Codegen/Emit/EmitIRCtors.k --- ///
///
///   EmitIR, part: constructors. The four definitions of a constructor
///   CtorInitCheck split (the slot record, S_pre, the slot constructor and the
///   public one; EmitIR.k's header has the shape), the slots S_pre reads and
///   writes, and a constructor's mem-initializer list: base initializers first,
///   each naming the base edge it initializes.
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

import AST::ASTSupport::FrozenList
import AST::DeclFacts::{
    decl_fields,
    decl_pattern,
}
import AST::LangItems::LowerTargets
import AST::Node::Base::{
    Decl,
    Expr,
    Stmt,
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
import AST::Node::Declarations::{
    ClassDecl,
    FieldDecl,
    FunctionDecl,
    VariableDecl,
}
import AST::Node::Expressions::CallExpr
import AST::Node::PrimaryExpressions::ChainExpr
import AST::Node::Statements::{
    CompoundStmt,
    ExpressionStmt,
}
import Codegen::Emit::EmitIR::EmitIR
import Codegen::Emit::EmitIRCalls
import Codegen::Emit::EmitIRConvert
import Codegen::Emit::EmitIRDecls
import Codegen::Emit::EmitIRExprs
import Codegen::Emit::EmitIRStmts
import Codegen::Emit::Spell::Speller
import Location::SourceRange::SourceRange

extend EmitIR {
    /// The slot record's definition, the pre-function, the slot constructor
    /// and the public constructor that delegates to it, for `m`, whose body
    /// CtorInitLowering cut into `{ {S_pre} {S_post} }`.
    prot fn _split_ctor(self, m: unsafe *FunctionDecl, owner: unsafe *Decl) {
        var unsafe *b = m->body_block
        if !m->ci_cut || b == &null || b->body.size() != 2 {
            self._ice(
                m->range,
                "EmitIR: a constructor CtorInitCheck split reached codegen uncut; CtorInitLowering owns it",
            )
        }

        var unsafe *pre  = dyn_cast<CompoundStmt>(b->body[0])
        var unsafe *post = dyn_cast<CompoundStmt>(b->body[1])
        if pre == &null || post == &null {
            self._ice(
                m->range,
                "EmitIR: a split constructor's body is not its two blocks; CtorInitLowering owns it",
            )
        }

        var at   = Speller::at(unsafe (m as unsafe *Decl))
        var wrap = self._open_ns(owner, at)
        var oh   = self._spell.owner_template_head(owner)
        var q    = self._spell.owner_qual(owner)
        var inl = if (m->is_inline() || self._templated_inline(oh)) => ("inline ") else => ""
        // An eval constructor is `consteval` in the class (Compiler/Spec/Eval.md#eval-fn), and
        // so are its halves (InterfaceEmitter::_split_ctor_decls): every
        // definition repeats it, or clang reads a run-time redeclaration.
        // The slots then live inside one constant evaluation (the ctor
        // slot helpers' `if consteval` arm).
        if m->is_eval() {
            inl += "consteval "
        } else if m->is_constexpr() {
            inl += "constexpr "
        }

        var ci   = LowerTargets::ctor_slots(m->ci_index)
        var sa   = LowerTargets::ctor_slot_arg()
        var leaf = self._spell.leaf(owner)
        var ps   = self._lref_params(m)
        var args = self._param_names(m)

        // Before anything below: _slot_name and _slot_type read the slots
        // through _ci_fn, and the slot record is the first thing they spell.
        var unsafe *saved_fn  = self._cur_fn
        var unsafe *saved_ext = self._cur_ext
        var unsafe *saved_ci  = self._ci_fn
        var unsafe *saved_own = self._ci_owner
        var        saved_pre  = self._ci_pre
        self._cur_fn   = m
        self._cur_ext  = &null
        self._ci_fn    = m
        self._ci_owner = owner

        // The slot record. Its members' types are complete here, which they
        // need not be where only the class is (InterfaceEmitter declares it).
        var r = oh + "struct " + q + "::" + ci + " {"
        for var i: usize = 0; i < m->ci_slots.size(); ++i {
            r += " ::" + LowerTargets::ctor_slot() + "<" + self._slot_type(
                i,
                q,
            ) + "> " + self._slot_name(i) + ";"
        }

        r += " };"
        self._cg->sink->spell(at, r)
        self._cg->sink->brk()

        // S_pre, against the slots.
        self._cg->sink->spell(
            at,
            oh + inl + "auto " + q + "::" + LowerTargets::ctor_pre(
                m->ci_index,
            ) + "(" + ci + "&& " + sa + ps + ") -> " + ci + "&",
        )

        self._ci_pre = true
        self._cg->sink->synth_at_start(pre->range, clang::tok::l_brace)
        // The base initializers lead S_pre and belong to the slot
        // constructor's mem-initializers, below.
        var lead = self._lead_base_inits(pre->body)
        for var i: usize = lead; i < pre->body.size(); ++i {
            self.emit(pre->body[i])
        }

        // Cast, not `return __kairo_s;`: since C++23 a returned rvalue
        // reference parameter is an xvalue (P2266), which the `&` return
        // type cannot bind.
        self._cg->sink->spell(
            pre->range,
            "return static_cast<" + ci + "&>(" + sa + ");",
        )

        self._cg->sink->synth_at_end(pre->range, clang::tok::r_brace)
        self._ci_pre = false
        self._cg->sink->brk()

        // The object, built from the slots; then S_post in it. Its bases
        // first, as C++ builds them: from the leading `Base::Base(self,
        // ...)` calls, whose arguments are the parameters this constructor
        // takes by reference too -- so a base is built after S_pre ran,
        // and sees what S_pre did to a parameter.
        var h = oh + inl + q + "::" + leaf + "(" + ci + "& " + sa + ps + ")"
        self._cg->sink->spell(at, h)
        h = ""
        var first = !self._mem_inits(m, owner, unsafe &pre->body, false)
        for var i: usize = 0; i < m->ci_slots.size(); ++i {
            var unsafe *f = dyn_cast<FieldDecl>(m->ci_slots[i])
            if f == &null || !m->ci_dense[i] {
                continue
            }

            h += if (first) => (" : ") else => ", "
            first = false
            var take = sa + "." + self._slot_name(i) + "." + LowerTargets::ctor_slot_take() + "()"
            var ext = self._array_extent(f->type_)
            if ext == usize::MAX {
                h += self._spell.leaf(unsafe (f as unsafe *Decl)) + "(" + take + ")"
            } else {
                // A member array cannot be initialized from an array, only
                // from its elements, each moved out of the slot's.
                h += self._spell.leaf(unsafe (f as unsafe *Decl)) + "{"
                for var k: usize = 0; k < ext; ++k {
                    if k > 0 {
                        h += ", "
                    }

                    h += take + f"[{k}]"
                }

                h += "}"
            }
        }

        if h.size() > 0 {
            self._cg->sink->spell(at, h)
        }

        self._cg->sink->synth_at_start(post->range, clang::tok::l_brace)
        // A `var` field S_pre assigned on some paths only kept its default;
        // the slot's value replaces it where there is one.
        for var i: usize = 0; i < m->ci_slots.size(); ++i {
            var unsafe *f = dyn_cast<FieldDecl>(m->ci_slots[i])
            if f == &null || m->ci_dense[i] {
                continue
            }

            var nm = self._slot_name(i)
            self._cg->sink->spell(
                post->range,
                "if (" + sa + "." + nm + "." + LowerTargets::ctor_slot_set() + ") { this->" + self._spell.leaf(
                    unsafe (f as unsafe *Decl),
                ) + " = " + sa + "." + nm + "." + LowerTargets::ctor_slot_take() + "(); }",
            )
        }

        for var i: usize = 0; i < post->body.size(); ++i {
            self.emit(post->body[i])
        }

        self._cg->sink->synth_at_end(post->range, clang::tok::r_brace)
        self._cg->sink->brk()

        self._cur_fn   = saved_fn
        self._cur_ext  = saved_ext
        self._ci_fn    = saved_ci
        self._ci_owner = saved_own
        self._ci_pre   = saved_pre

        // The constructor Kairo declared: fill a fresh slot record, then
        // delegate. The temporary lives to the end of this mem-initializer.
        var pub_h = oh + inl + q + "::" + leaf + "(" + self._params_text(
            m,
            &null,
        ) + ")"
        if m->no_unwind {
            pub_h += " noexcept"
        }

        pub_h += " : " + leaf + "(" + LowerTargets::ctor_pre(
            m->ci_index,
        ) + "(" + ci + "()" + args + ")" + args + ") {"
        // A bounded generic record's bounds are asserted where a value is
        // made (Speller::ctor_bound_asserts): this is the constructor a
        // caller names, so the assertion sits in its body.
        // Spelled at the body, where a diagnostic on it points.
        self._cg->sink->spell(at, pub_h)
        var cba = self._spell.ctor_bound_asserts(m)
        for var i: usize = 0; i < cba.size(); ++i {
            self._cg->sink->spell(b->range, cba[i])
        }

        self._cg->sink->spell(at, "}")
        self._close_ns(m->range, wrap)
    }

    /// Index of `d` in the live split constructor's slots, or usize(-1). A
    /// field counts only when `fields`: after S_pre the object exists.
    prot fn _slot_of(self, d: unsafe *Decl, fields: bool) -> usize {
        if self._ci_fn == &null || d == &null {
            return usize::MAX
        }

        if isa<FieldDecl>(d) && !fields {
            return usize::MAX
        }

        var sl = self._ci_fn->ci_slots
        for var i: usize = 0; i < sl.size(); ++i {
            if sl[i] == d {
                return i
            }
        }

        return usize::MAX
    }

    /// A field's slot is named as the field; a carried local's by its
    /// position too (LowerTargets::ctor_local_slot).
    prot fn _slot_name(self, i: usize) -> string {
        var unsafe *d = self._ci_fn->ci_slots[i]
        if isa<FieldDecl>(d) {
            return self._spell.leaf(d)
        }

        var unsafe *v = cast<VariableDecl>(d)
        return LowerTargets::ctor_local_slot(
            i,
            self._spell.tok_name(v->name, self._owning_fid()),
        )
    }

    /// Slot `i`'s type. A field of a base of the owner (spelled `q`) is
    /// `decltype(Q::f)`: its declared type is written in the base's terms
    /// (a generic base's `T`), and C++ reads it through the derived class.
    priv fn _slot_type(self, i: usize, const q: string) -> string {
        var unsafe *d = self._ci_fn->ci_slots[i]
        if isa<FieldDecl>(d) {
            if self._inherited_field(cast<FieldDecl>(d)) {
                return "decltype(" + q + "::" + self._spell.leaf(d) + ")"
            }

            return self._spell._type(cast<FieldDecl>(d)->type_)
        }

        return self._spell._type(cast<VariableDecl>(d)->type_)
    }

    /// `f`, a field in a slot of the live split constructor, is not one of
    /// its record's own: it is a base's.
    prot fn _inherited_field(self, f: unsafe *FieldDecl) -> bool {
        var own = decl_fields(self._ci_owner)
        for var i: usize = 0; i < own.size(); ++i {
            if own[i] == f {
                return false
            }
        }

        return true
    }

    /// `var n = e` in S_pre, for a local S_post reads: its slot, built.
    /// `var n: T` alone is `T{}`, the default every local gets (_var_init).
    prot fn _slot_local_init(self, v: unsafe *VariableDecl) {
        var si = self._slot_of(v, false)
        self._cg->sink->spell(
            v->name.range,
            LowerTargets::ctor_slot_arg() + "." + self._slot_name(
                si,
            ) + "." + LowerTargets::ctor_slot_init() + "(",
        )

        if v->init == &null {
            self._cg->sink->spell(
                v->name.range,
                self._spell._type(v->type_) + "{}",
            )
        } else {
            self._value(v->init, v->type_)
        }

        self._cg->sink->spell(v->name.range, ")")
    }

    /// The field `e` names when it is exactly `self.f`, else null.
    prot fn _self_field(self, e: unsafe *Expr) -> unsafe *FieldDecl {
        var unsafe *c = dyn_cast<ChainExpr>(e)
        if c == &null || c->steps.size() != 1 || !self._base_is_self(c->base) {
            return &null
        }

        var unsafe *d = c->steps.get(0)->resolved_decl
        if d == &null || !isa<FieldDecl>(d) {
            return &null
        }

        return cast<FieldDecl>(d)
    }

    /// `, __kairo_lref<P> p` per parameter but `self`: the same text
    /// InterfaceEmitter::_lref_params declares, spelled for a definition.
    priv fn _lref_params(self, m: unsafe *FunctionDecl) -> string {
        var s = ""
        for var i: usize = 0; i < m->params.size(); ++i {
            var unsafe *p = m->params[i]
            if p == &null || p->is_self {
                continue
            }

            s += ", ::" + LowerTargets::lref() + "<" + self._spell.param_type(p) + "> "
            s += self._spell.tok_name(
                p->name,
                Speller::fid_of(unsafe (m as unsafe *Decl)),
            )
        }

        return s
    }

    /// `, p` per parameter but `self`: the public constructor's own, passed
    /// on as lvalues.
    priv fn _param_names(self, m: unsafe *FunctionDecl) -> string {
        var s = ""
        for var i: usize = 0; i < m->params.size(); ++i {
            var unsafe *p = m->params[i]
            if p == &null || p->is_self {
                continue
            }

            s += ", " + self._spell.tok_name(
                p->name,
                Speller::fid_of(unsafe (m as unsafe *Decl)),
            )
        }

        return s
    }

    /// The constructor a statement calls by qualified name to initialize a
    /// base -- `Animal::Animal(self, 4);` -- or null. BaseInitCheck admits
    /// such a call only as one of a constructor's leading statements, so
    /// the shape alone identifies it here.
    priv fn _base_init_ctor(self, s: unsafe *Stmt) -> unsafe *FunctionDecl {
        var unsafe *es = dyn_cast<ExpressionStmt>(s)
        if es == &null || es->expr == &null {
            return &null
        }

        var unsafe *n = dyn_cast<CallExpr>(es->expr)
        if n == &null || n->ctor_decl != &null {
            return &null
        }

        var unsafe *ch = dyn_cast<ChainExpr>(n->callee)
        if ch == &null || ch->steps.size() == 0 {
            return &null
        }

        var unsafe *last = ch->steps.get(ch->steps.size() - 1)
        if last->access_kind != ChainExpr::AccessKind::ColonColon {
            return &null
        }

        var unsafe *f = dyn_cast<FunctionDecl>(last->resolved_decl)
        if !self._is_ctor(f) {
            return &null
        }

        return f
    }

    /// How many of `stmts`, from the first, are base initializers.
    prot fn _lead_base_inits(self, const stmts: FrozenList<unsafe *Stmt>) -> usize {
        var k: usize = 0
        while k < stmts.size() && self._base_init_ctor((stmts)[k]) != &null {
            k += 1
        }

        return k
    }

    /// ` : Animal(4), ...` after constructor `m`'s head, from the base
    /// initializers leading `stmts`; true when there was one. C++ builds a
    /// base before the body runs and has no way to construct one from a
    /// statement, so the call becomes its mem-initializer, which is also
    /// what makes a virtual base's initializer in an intermediate class
    /// ignored (classes-inheritance.md, Diamond and virtual inheritance).
    prot fn _mem_inits(self,
                       m:     unsafe *FunctionDecl,
                       owner: unsafe *Decl,
                       stmts: unsafe *FrozenList<unsafe *Stmt>,
                       colon: bool) -> bool {
        var k = self._lead_base_inits(*stmts)
        if k == 0 {
            return false
        }

        var unsafe *saved_fn  = self._cur_fn
        var unsafe *saved_ext = self._cur_ext
        self._cur_fn  = m
        self._cur_ext = &null
        for var i: usize = 0; i < k; ++i {
            var unsafe *f = self._base_init_ctor((*stmts)[i])
            var unsafe *n = cast<CallExpr>(
                cast<ExpressionStmt>((*stmts)[i])->expr,
            )

            var lead = if (i > 0) => (", ") else => (if (colon) => (" : ") else => ": ")
            self._cg->sink->spell(
                n->range,
                lead + self._base_init_type(owner, f, n->range) + "(",
            )

            self._args(n, f, false, n->instance, true)
            self._cg->sink->spell(n->range, ")")
        }

        self._cur_fn  = saved_fn
        self._cur_ext = saved_ext
        return true
    }

    /// The instance of generic method `f`'s class that object `obj` is,
    /// or has as a base -- what `Box<i32>::get(obj)` names, which the bare
    /// callee spells as the template. Null when neither (clang then
    /// reports the template, as before).
    prot fn _qualifying_instance(self, obj: unsafe *Expr, f: unsafe *FunctionDecl) -> unsafe *Type {
        if obj == &null || obj->type_ == &null {
            return &null
        }

        var unsafe *want = Speller::rep(
            decl_pattern(Speller::rep((f->semantic_dc)->dc_owner)),
        )

        var unsafe *r = dyn_cast<RecordType>(canon_unqual(obj->type_))
        if r == &null || r->decl == &null {
            return &null
        }

        if Speller::rep(decl_pattern(Speller::rep(r->decl))) == want {
            return r
        }

        var seen = cxx::std::vector<unsafe *Decl>()
        return self._base_edge_to(
            Speller::rep(decl_pattern(Speller::rep(r->decl))),
            want,
            unsafe &seen,
            0,
        )
    }

    /// The base `f` constructs, spelled as `owner`'s base list names it
    /// (`GB<int>`, not the template); a virtual base further up is found
    /// through the bases in between.
    priv fn _base_init_type(self,
                            owner: unsafe *Decl,
                            f:     unsafe *FunctionDecl,
                            at:    SourceRange) -> string {
        var unsafe *dc = f->semantic_dc
        var unsafe *want = Speller::rep(
            decl_pattern(Speller::rep(dc->dc_owner)),
        )

        var seen = cxx::std::vector<unsafe *Decl>()
        var unsafe *t = self._base_edge_to(
            Speller::rep(owner),
            want,
            unsafe &seen,
            0,
        )

        if t == &null {
            self._ice(
                at,
                "EmitIR: a base initializer whose class is no base of the constructor's; BaseInitCheck admits only bases",
            )
        }

        return self._spell._type(t)
    }

    priv fn _base_edge_to(self,
                          d:     unsafe *Decl,
                          want:  unsafe *Decl,
                          seen:  unsafe *cxx::std::vector<unsafe *Decl>,
                          depth: u32) -> unsafe *Type {
        if d == &null || depth > 64 || !isa<ClassDecl>(d) {
            return &null
        }

        for var i: usize = 0; i < seen->size(); ++i {
            if (*seen)[i] == d {
                return &null
            }
        }

        seen->push_back(d)
        var unsafe *cd = cast<ClassDecl>(d)
        for var i: usize = 0; i < cd->derives_list.size(); ++i {
            var unsafe *e = cd->derives_list.get(i)
            if e == &null || e->base == &null || e->base->canonical == &null {
                continue
            }

            var unsafe *r = dyn_cast<RecordType>(
                canon_unqual(e->base->canonical),
            )

            if r == &null || r->decl == &null {
                continue
            }

            if Speller::rep(decl_pattern(Speller::rep(r->decl))) == want {
                return e->base
            }
        }

        for var i: usize = 0; i < cd->derives_list.size(); ++i {
            var unsafe *e = cd->derives_list.get(i)
            if e == &null || e->base == &null || e->base->canonical == &null {
                continue
            }

            var unsafe *r = dyn_cast<RecordType>(
                canon_unqual(e->base->canonical),
            )

            if r == &null || r->decl == &null {
                continue
            }

            var unsafe *t = self._base_edge_to(
                Speller::rep(decl_pattern(Speller::rep(r->decl))),
                want,
                seen,
                depth + 1,
            )

            if t != &null {
                return t
            }
        }

        return &null
    }
}
