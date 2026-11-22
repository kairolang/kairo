/// --- The Kairo Project -------------------------- Codegen/Emit/Push.k --- ///
///
///   EmitIR, part: a `for` over a generator, written with no coroutine.
///
///   \detail
///     IterLowering renders `for x in g(a) { BODY }` as
///
///         { Yield<T> it = g(a);
///           while (it.resume()) { T x = *it.current(); BODY } }
///
///     where `g` is a C++ coroutine: a frame, and a resume per value that
///     the optimizer may or may not fold back into a loop. Where `g` has a
///     PUSH FORM (generator_push_form) the same block is written as
///
///         { auto body = [&](auto& cur) noexcept -> bool {
///               __kairo_at<T> it{&cur};
///               T x = *it.current(); BODY
///               return true; };
///           g(a, ::__kairo_each<T>{&th<decltype(body)>, &body}); }
///
///     The push form is a second C++ function written beside the coroutine
///     from the same body (_push_twin): `bool g(params, __kairo_each<T> f)`,
///     in which `yield v` is `if (!f(v)) return false;` and `return` is
///     `return true;`. It is always inlined and calls the body through a
///     constant pointer, so the loop compiles to the generator's own loop
///     with BODY at each `yield`: no frame, no state machine.
///
///   \par What does not change
///     The arguments are evaluated once, before the first value. BODY runs
///     between two steps of the generator and reads the generator's own
///     value through `cur`, as it does through `current()`. Leaving the
///     loop ends BODY's locals, then the generator's (innermost first),
///     then the header temporaries declared ahead in the block: the order
///     destroying the coroutine at the block's end gives. `it` is declared
///     inside the body under its own name, so the binders IterLowering
///     wrote are emitted as they are.
///
///   \par Leaving the body
///     The body is a lambda, so, as in an `eval for` copy
///     (Emit/Loops.k), `continue` is `return true` and `break` is
///     `return false`, which the push form answers by returning. A
///     `return e` sets the function's flag and value (`__kairo_pfr`,
///     `__kairo_pfv`, declared by the outermost push loop) and stops the
///     same way; the code after the outermost loop returns the value, an
///     inner one stops its enclosing body. Inside a push form a `yield` in
///     a body calls the enclosing form's own sink, and a `false` from it
///     leaves through the flag as a `return` does.
///
///   \par When the loop keeps the coroutine  (_push_ok)
///     - the callee is not a generator with a push form, or its body is
///       not written in every TU that writes this one (_push_visible);
///     - the function can unwind, or is `async` or `eval`;
///     - the body yields and this is the coroutine itself (a `co_yield`
///       cannot sit in a lambda), jumps to a label outside itself, holds an
///       `await`, an `eval for`, a pack `for` or a C++ `try`;
///     - the body returns a value that is not a number or a pointer (the
///       value would be moved one more time on its way out), or returns
///       from a closure.
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

import AST::DeclFacts::decl_extension_of
import AST::LangItems::LowerTargets
import AST::Node::Base::{
    Decl,
    Expr,
    Stmt,
    Type,
}
import AST::Node::CanonicalNodes::{
    BuiltinKind,
    BuiltinType,
    RecordType,
    canon_unqual,
}
import AST::Node::Casting::{
    cast,
    dyn_cast,
    isa,
}
import AST::Node::Declarations::{
    ExtensionDecl,
    FunctionDecl,
    VariableDecl,
}
import AST::Node::Expressions::{
    CallExpr,
    FinalizeKind,
}
import AST::Node::PrimaryExpressions::{
    ChainExpr,
    NamedIdentExpr,
}
import AST::Node::Statements::{
    CompoundStmt,
    DeclStmt,
    ReturnStmt,
    WhileLoopStmt,
}
import AST::Node::Types::PointerType
import Codegen::Emit::Calls
import Codegen::Emit::Convert
import Codegen::Emit::Decls
import Codegen::Emit::EmitIR::EmitIR
import Codegen::Emit::Exprs
import Codegen::Emit::Locals
import Codegen::Emit::Names
import Codegen::Emit::Stmts
import Codegen::Plan::Visitors::{
    PushBodyScan,
    generator_elem,
    generator_push_form,
}
import Codegen::Spell::Spell::Speller
import Location::SourceRange::SourceRange

extend EmitIR {
    /// The statements of block `b` from `from` on. The hidden local of a
    /// generator loop (VariableDecl::gen_iter) and the loop it drives are
    /// written together when the loop takes the push form: the local is
    /// not declared, and the loop is _push_for.
    prot fn _stmts(self, b: unsafe *CompoundStmt, from: usize) {
        var pend:    unsafe *Stmt         = &null
        var pend_it: unsafe *VariableDecl = &null
        for var i: usize = from; i < b->body.size(); ++i {
            var unsafe *s = b->body[i]
            if pend != &null && s == pend {
                self._push_for(pend_it, cast<WhileLoopStmt>(s))
                pend = &null
                continue
            }

            if pend == &null {
                var unsafe *vd = self._gen_iter_of(s)
                if vd != &null {
                    var unsafe *w = self._push_loop_of(b, i, vd)
                    if w != &null && self._push_ok(vd, w) {
                        pend    = unsafe (w as unsafe *Stmt)
                        pend_it = vd
                        continue
                    }
                }
            }

            self.emit(s)
        }
    }

    /// The generator local `s` declares (VariableDecl::gen_iter), or null.
    priv fn _gen_iter_of(self, s: unsafe *Stmt) -> unsafe *VariableDecl {
        var unsafe *ds = dyn_cast<DeclStmt>(s)
        if ds == &null || ds->decl == &null {
            return &null
        }

        var unsafe *vd = dyn_cast<VariableDecl>(ds->decl)
        if vd == &null || !vd->gen_iter || vd->init == &null {
            return &null
        }

        return vd
    }

    /// The loop of block `b`, after statement `i`, that resumes generator
    /// local `vd`: `while (vd.resume())`. Null when no such loop is there.
    priv fn _push_loop_of(self,
                          b:  unsafe *CompoundStmt,
                          i:  usize,
                          vd: unsafe *VariableDecl) -> unsafe *WhileLoopStmt {
        for var j: usize = i + 1; j < b->body.size(); ++j {
            var unsafe *w = dyn_cast<WhileLoopStmt>(b->body[j])
            if w == &null || w->cond == &null || w->body == &null {
                continue
            }

            var unsafe *c = dyn_cast<CallExpr>(self._strip(w->cond))
            if c == &null || c->callee == &null {
                continue
            }

            var unsafe *ch = dyn_cast<ChainExpr>(c->callee)
            if ch == &null || ch->base == &null {
                continue
            }

            var unsafe *ni = dyn_cast<NamedIdentExpr>(self._strip(ch->base))
            if ni != &null && ni->resolved_decl == unsafe (vd as unsafe *Decl) {
                return w
            }
        }

        return &null
    }

    /// Whether the loop `w` over generator local `vd` is written in push
    /// form here (file header, "When the loop keeps the coroutine").
    priv fn _push_ok(self, vd: unsafe *VariableDecl, w: unsafe *WhileLoopStmt) -> bool {
        var unsafe *cf = self._cur_fn
        if cf == &null || !cf->no_unwind || cf->is_eval() || cf->is_async() {
            return false
        }

        // A namespace-scope initializer and a split constructor have their
        // own forms around a statement, and an `eval for` copy its own
        // protocol for leaving one.
        if self._cg->opts.unwind
            || self._ns_init
            || self._ci_fn != &null
            || self._ef_depth != self._pf_depth {
            return false
        }

        var unsafe *c = dyn_cast<CallExpr>(self._strip(vd->init))
        if c == &null
            || c->callee == &null
            || c->finalize != FinalizeKind::None
            || c->fmt_dyn
            || c->ctor_decl != &null
            || c->functor_op != &null
            || c->witness_iface != &null {
            return false
        }

        var unsafe *g = dyn_cast<FunctionDecl>(self._callee_decl(c->callee))
        if g == &null {
            return false
        }

        var unsafe *def = g
        if !def->has_body() {
            def = def->definition()
        }

        if def == &null
            || !generator_push_form(def, self._cg->instances)
            || !self._push_visible(def) {
            return false
        }

        // The push form declares no default argument: every parameter has
        // its argument here, the receiver written or bound.
        var np: usize = 0
        var ns: usize = 0
        for var i: usize = 0; i < def->params.size(); ++i {
            var unsafe *p = def->params[i]
            if p == &null {
                continue
            }

            if p->is_self {
                ns += 1
            } else {
                np += 1
            }
        }

        if c->args.size() != np && c->args.size() != np + ns {
            return false
        }

        var scan = PushBodyScan(self._cg->ctx)
        scan.run(unsafe (w->body as unsafe *Stmt))
        if scan.blocked || !scan.jumps_stay() {
            return false
        }

        if scan.has_yield && !self._twin {
            return false
        }

        if scan.has_return {
            if self._closure != &null {
                return false
            }

            if !self._twin && !self._push_return_ok(cf) {
                return false
            }
        }

        return true
    }

    /// The body of `f` is written in every TU that writes its callers: a
    /// template or an `inline` function.
    priv fn _push_shared(self, f: unsafe *FunctionDecl) -> bool {
        if f->is_inline() || self._spell.template_head(unsafe (f as unsafe *Decl)).size() > 0 {
            return true
        }

        var unsafe *dc = f->semantic_dc
        if dc != &null && dc->is_type_scope() && dc->dc_owner != &null {
            return self._spell.owner_template_head(Speller::rep(dc->dc_owner)).size() > 0
        }

        return false
    }

    /// The push form of generator `def` is defined in this TU wherever the
    /// body being written is: `def` is a template or `inline`, or both it
    /// and the function being written are this file's own and that
    /// function is written nowhere else. The second case never holds for
    /// an `inline` caller, whose text must be the same in every TU.
    priv fn _push_visible(self, def: unsafe *FunctionDecl) -> bool {
        if self._push_shared(def) {
            return true
        }

        var fid = self._cg->tu->fid
        return Speller::fid_of(unsafe (def as unsafe *Decl)) == fid
            && Speller::fid_of(unsafe (self._cur_fn as unsafe *Decl)) == fid
            && !self._push_shared(self._cur_fn)
    }

    /// A `return` in a push-form body of function `f` can carry its value
    /// out through a plain local: `f` returns nothing, a number or a
    /// pointer. A record would be moved once more than the `return` it
    /// was written as, and a panicking function returns its Panic record.
    priv fn _push_return_ok(self, f: unsafe *FunctionDecl) -> bool {
        if f->panic_result != &null || f->is_noreturn || f->is_generator {
            return false
        }

        var unsafe *rt = f->return_type
        if rt == &null || rt->canonical == &null {
            return true
        }

        var unsafe *c = canon_unqual(rt->canonical)
        return c != &null && (isa<BuiltinType>(c) || isa<PointerType>(c))
    }

    /// The function being written returns a value (not `void`, not `!`).
    priv fn _push_has_value(self) -> bool {
        var unsafe *f = self._cur_fn
        if f == &null || f->is_noreturn || f->return_type == &null {
            return false
        }

        var unsafe *rt = f->return_type
        return rt->canonical != &null && !self.tu_is_void(rt->canonical)
    }

    /// The loop `w` over generator local `vd`, in push form (file header).
    priv fn _push_for(self, vd: unsafe *VariableDecl, w: unsafe *WhileLoopStmt) {
        var        at = w->range
        var        s  = self._cg->sink
        var unsafe *c = cast<CallExpr>(self._strip(vd->init))
        var unsafe *yt = dyn_cast<RecordType>(
            canon_unqual(vd->type_->canonical),
        )

        if yt == &null || yt->args.size() == 0 {
            self._ice(
                at,
                "EmitIR: a generator local whose type is not Yield<T>",
            )
        }

        var et   = self._spell._type(yt->args[0])
        var k    = self._pf_seq
        var pb   = LowerTargets::gen_body(k)
        var cur  = LowerTargets::gen_cur(k)
        var flag = LowerTargets::gen_ret_flag()
        var val  = LowerTargets::gen_ret_val()
        self._pf_seq += 1

        var scan = PushBodyScan(self._cg->ctx)
        scan.run(unsafe (w->body as unsafe *Stmt))
        var leaves = scan.has_return || scan.has_yield
        var outer  = self._pf_depth == 0
        var valued = self._twin || self._push_has_value()
        if leaves && outer {
            s->spell(at, "bool " + flag + " = false;")
            if self._twin {
                s->spell(at, "bool " + val + " = true;")
            } else if valued {
                s->spell(
                    at,
                    self._spell._type(self._cur_fn->return_type) + " " + val + ";",
                )
            }
        }

        s->spell(
            at,
            "auto " + pb + " = [&](auto& " + cur + ") noexcept -> bool {",
        )

        s->spell(
            at,
            "[[maybe_unused]] ::" + LowerTargets::gen_at() + "<" + et + "> " + self._local_name(
                unsafe (vd as unsafe *Decl),
            ) + "{" + LowerTargets::clang_addressof() + "(" + cur + ")};",
        )

        var sd = self._ef_depth
        var sl = self._ef_loops
        self._ef_depth += 1
        self._pf_depth += 1
        self._ef_loops = 0
        self._stmts(w->body, 0)
        self._ef_depth = sd
        self._pf_depth -= 1
        self._ef_loops = sl
        s->spell(at, "return true; };")

        self._push_call = c
        var ge = "::" + LowerTargets::gen_each() + "<" + et + ">"
        self._push_arg = "" + ge + "{&" + ge + "::template th<decltype(" + pb + ")>, " + LowerTargets::clang_addressof() + "(" + pb + ")}"
        self.emit(vd->init)
        if self._push_call != &null {
            self._ice(
                at,
                "EmitIR: a push-form call whose arguments _args did not write",
            )
        }

        s->spell(at, ";")
        if !leaves {
            return
        }

        if !outer {
            s->spell(at, "if (" + flag + ") { return false; }")
        } else if valued {
            s->spell(at, "if (" + flag + ") { return " + val + "; }")
        } else {
            s->spell(at, "if (" + flag + ") { " + self._bare_return() + " }")
        }
    }

    /// A `return` in a push-form body: the function's flag and value, then
    /// stop the generator. In a push form itself the value is "the
    /// sequence ended" (true).
    prot fn _push_return(self, n: unsafe *ReturnStmt) {
        var s = self._cg->sink
        s->spell(n->range, "{ " + LowerTargets::gen_ret_flag() + " = true;")
        if self._twin {
            s->spell(n->range, LowerTargets::gen_ret_val() + " = true;")
        } else if n->value != &null {
            s->spell(n->range, LowerTargets::gen_ret_val() + " = (")
            self._value(n->value, self._cur_fn->return_type)
            s->spell(n->range, ");")
        }

        s->spell(n->range, "return false; }")
    }

    /// What follows `if (!sink(v))` for a `yield` in a push form: the
    /// consumer stopped, so the form returns false, through the flag when
    /// the `yield` sits in a push-form body of its own.
    prot fn _push_stop(self) -> string {
        if self._pf_depth > 0 {
            return "{ " + LowerTargets::gen_ret_flag() + " = true; " + LowerTargets::gen_ret_val() + " = false; return false; }"
        }

        return "{ return false; }"
    }

    /// The push form's last parameter, `::__kairo_each<T> __kairo_f`.
    priv fn _push_sink(self, f: unsafe *FunctionDecl) -> string {
        return "::" + LowerTargets::gen_each() + "<" + self._spell._type(
            generator_elem(f),
        ) + "> " + LowerTargets::gen_sink()
    }

    /// The push form of free generator `n` (or an extension's, `ext`),
    /// defined after the coroutine from the same body:
    /// `bool n(params, ::__kairo_each<T> __kairo_f) noexcept { ... }`.
    prot fn _push_twin_free(self,
                            n:   unsafe *FunctionDecl,
                            ext: unsafe *ExtensionDecl,
                            at:  SourceRange) {
        if !generator_push_form(n, self._cg->instances) {
            return
        }

        var head = self._spell.template_head(
            n,
        ) + LowerTargets::attr_always_inline() + "inline bool "
        if ext != &null {
            head += self._spell.ext_scope_name(ext) + "::"
        }

        head += self._spell.leaf(n) + "("
        var ps = self._params_text(n, ext)
        if ps.size() > 0 {
            ps += ", "
        }

        head += ps + self._push_sink(n) + ") noexcept"
        self._cg->sink->spell(at, head)
        self._push_twin_body(n, ext)
    }

    /// The push form of generator method `m`, defined out of line after
    /// the coroutine. `tail` is what follows the parameter list of the
    /// method's own definition (` const`, ` noexcept`, its `requires`).
    prot fn _push_twin_method(self,
                              m:          unsafe *FunctionDecl,
                              owner:      unsafe *Decl,
                              at:         SourceRange,
                              const qual: string,
                              const tail: string) {
        if !generator_push_form(m, self._cg->instances) {
            return
        }

        var head = self._spell.owner_template_head(owner) + self._spell.template_head(
            m,
        )

        head += LowerTargets::attr_always_inline() + "inline bool " + qual + "::" + self._spell.leaf(
            m,
        ) + "("

        var ps = self._params_text(m, &null)
        if ps.size() > 0 {
            ps += ", "
        }

        head += ps + self._push_sink(m) + ")" + tail
        self._cg->sink->spell(at, head)
        self._push_twin_body(m, &null)
    }

    /// The body of `f` once more, as its push form: `_twin` turns each
    /// `yield` and `return` (EmitIR::_yield, _return) and the end of the
    /// body (_body).
    priv fn _push_twin_body(self, f: unsafe *FunctionDecl, ext: unsafe *ExtensionDecl) {
        var        st  = self._twin
        var        sp  = self._pf_depth
        var        sd  = self._ef_depth
        var        sl  = self._ef_loops
        var unsafe *sc = self._closure
        self._twin     = true
        self._pf_depth = 0
        self._ef_depth = 0
        self._ef_loops = 0
        self._closure  = &null
        self._body(f, ext)
        self._twin     = st
        self._pf_depth = sp
        self._ef_depth = sd
        self._ef_loops = sl
        self._closure  = sc
    }
}
