/// --- The Kairo Project ------------------- Codegen/Emit/EmitIRDecls.k --- ///
///
///   EmitIR, part: definitions. A declaration's body and the out-of-line
///   head it hangs off: free functions and extension members, methods in their
///   record's scope, foreign template and `inline` bodies, the forwarders of a
///   split subscript, eval field thunks, and the namespace wrappers each sits in.
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
import AST::Context::DeclContext::DeclContext
import AST::DeclFacts::{
    decl_cxx_spelling,
    decl_extension_of,
    decl_fold_pin,
    decl_generic_params,
    decl_methods,
}
import AST::Kind::DeclKind::{
    DeclKind,
    to_string,
}
import AST::Kind::ExprKind::to_string
import AST::Kind::StmtKind::to_string
import AST::Kind::TypeKind::to_string
import AST::LangItems::{
    LowerTargets,
    to_string,
}
import AST::Node::Base::{
    Decl,
    Expr,
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
    ClassDecl,     EnumDecl,     ExtensionDecl, FFIBlockDecl,        FieldDecl, FieldFold,
    FnBodyKind,    FunctionDecl, InterfaceDecl, ModuleDecl,          SpecKind,  StructDecl,
    TypeAliasDecl, UnionDecl,    VariableDecl,  VisibilityGroupDecl,
}
import AST::Node::Statements::CompoundStmt
import Codegen::Emit::EmitIR::{
    BodyMark,
    EmitIR,
    EmitPass,
}
import Codegen::Emit::EmitIRCtors
import Codegen::Emit::EmitIRExprs
import Codegen::Emit::EmitIRLocals
import Codegen::Emit::EmitIRStmts
import Codegen::Emit::Spell::Speller
import Diagnostic::Code::DiagCode
import Diagnostic::Registry::DiagID
import Location::SourceRange::SourceRange
import Token::TokenKind::TokenKind

extend EmitIR {
    /// # Declarations

    fn emit(self, d: unsafe *Decl) {
        if d == &null {
            kairo::std::ice_fail("EmitIR: null decl reached codegen")
        }

        if d->kind == DeclKind::RecoveryDecl {
            self._ice(
                d->range,
                "EmitIR: poisoned decl reached codegen; sema gate failure",
            )
        }

        if d->is_poisoned() {
            return
        }

        // The eval pass reaches free functions and records' compile-time
        // methods (_record_bodies), through modules and visibility groups
        // (emit_tu): the eval bindings defined after it call them.
        if self._pass != EmitPass::Runtime {
            if d->kind == DeclKind::FunctionDecl {
                if cast<FunctionDecl>(d)->is_eval()
                    && self._pass != EmitPass::EvalRecords
                    && !self._done(cast<FunctionDecl>(d)) {
                    self._free_fn(cast<FunctionDecl>(d), &null)
                    self._mark_done(cast<FunctionDecl>(d))
                }

                return
            }

            var rec = d->kind == DeclKind::ClassDecl
                || d->kind == DeclKind::StructDecl
                || d->kind == DeclKind::UnionDecl
            if d->kind != DeclKind::ModuleDecl
                && d->kind != DeclKind::VisibilityGroupDecl
                && d->kind != DeclKind::FFIBlockDecl
                && !rec {
                return
            }

            if rec && self._pass != EmitPass::EvalRecords {
                return
            }
        } else if d->kind == DeclKind::FunctionDecl
            && cast<FunctionDecl>(d)->is_eval()
            && self._done(cast<FunctionDecl>(d)) {
            return
        }

        match d->kind {
            case DeclKind::FunctionDecl {
                if Speller::defines_foreign(cast<FunctionDecl>(d)) {
                    self._foreign_def(cast<FunctionDecl>(d))
                    return
                }

                self._free_fn(cast<FunctionDecl>(d), &null)
            } case DeclKind::ClassDecl {
                self._record_bodies(d)
            } case DeclKind::StructDecl {
                self._record_bodies(d)
            } case DeclKind::UnionDecl {
                self._record_bodies(d)
            } case DeclKind::EnumDecl {
                return
            } case DeclKind::TypeAliasDecl {
                return
            } case DeclKind::InterfaceDecl {
                return
            } case DeclKind::ModuleDecl {
                var unsafe *dc = unsafe (cast<ModuleDecl>(d) as unsafe *DeclContext)
                for var i: usize = 0; i < dc->dc_decls.size(); ++i {
                    self.emit(*dc->dc_decls.get(i))
                }
            } case DeclKind::VisibilityGroupDecl {
                var unsafe *g = cast<VisibilityGroupDecl>(d)
                for var i: usize = 0; i < g->members.size(); ++i {
                    self.emit(g->members[i])
                }
            } case DeclKind::FFIBlockDecl {
                // `ffi "c" { ... }` groups top-level declarations, each stamped
                // with the block's linkage (imports.mdx): emitted as if each
                // had been written with its own `ffi "c"`.
                var unsafe *fb = cast<FFIBlockDecl>(d)
                for var i: usize = 0; i < fb->body.size(); ++i {
                    if fb->body[i] != &null {
                        self.emit(fb->body[i])
                    }
                }
            } case DeclKind::ExtensionDecl {
                var unsafe *x = cast<ExtensionDecl>(d)
                // A conditional block's bodies are emitted where a use
                // brought its scope into the plan (EmitPlan::visible_bodies),
                // this file included; never because the block is written here.
                if x->gate != &null {
                    return
                }

                for var i: usize = 0; i < x->methods.size(); ++i {
                    var unsafe *m = x->methods[i]
                    if m != &null {
                        self._free_fn(m, x)
                    }
                }
            } case DeclKind::VariableDecl {
                if self._marked(d, BodyMark::Hoisted) { // emit_tu wrote it, in dependency order.
                    return
                }

                self._global_var(cast<VariableDecl>(d))
            } default {
                self._ice(
                    d->range,
                    f"EmitIR: decl kind {to_string(d->kind)} has no body to emit",
                )
            }
        }
    }

    /// The methods of a record, out of line, then its nested records'.
    priv fn _record_bodies(self, d: unsafe *Decl) {
        var methods = decl_methods(d)
        for var i: usize = 0; i < methods.size(); ++i {
            var unsafe *m = methods[i]
            if m == &null {
                continue
            }

            // An out-of-line definition is in no member list: the in-class
            // declaration is, and the chain leads to the body.
            if !m->has_body() {
                var unsafe *def = m->definition()
                if def != &null && !def->is_poisoned() {
                    m = def
                }
            }

            // The eval pass writes the compile-time ones; the second pass
            // the rest (emit).
            if self._done(m) {
                continue
            }

            if self._pass != EmitPass::Runtime {
                if !self._compile_time(m) {
                    continue
                }

                self._mark_done(m)
            }

            self._method(m, d)
        }

        var unsafe *dc = Speller::dc_of(d)
        if dc == &null {
            return
        }

        for var i: usize = 0; i < dc->dc_decls.size(); ++i {
            var unsafe *nd = *dc->dc_decls.get(i)
            if nd == &null {
                continue
            }

            if isa<ClassDecl>(nd) || isa<StructDecl>(nd) || isa<UnionDecl>(nd) {
                self._record_bodies(nd)
            }
        }
    }

    /// One foreign template or inline body, in its owner's wrapper. The tokens live in
    /// the template's file; the sink maps every registered fid. A member
    /// goes out of line on its record (\p f is already the defining link);
    /// an extension member still needs its extension (the receiver
    /// parameter and the extension's template parameters).
    prot fn _visible_body(self, f: unsafe *FunctionDecl) {
        var unsafe *x = decl_extension_of(f)
        if x != &null {
            self._free_fn(f, x)
            return
        }

        var unsafe *dc = f->semantic_dc
        if dc != &null && dc->is_type_scope() && dc->dc_owner != &null {
            self._method(f, Speller::rep(dc->dc_owner))
            return
        }

        self._free_fn(f, &null)
    }

    /// Open the wrapper InterfaceEmitter declared \p d in.
    /// The named namespace, plus an unnamed one nested in it for a decl with
    /// no linkage outside its file -- never for an extension member, whose
    /// scope struct lives in the named one whatever its visibility. Returns
    /// how many braces to close.
    prot fn _open_ns(self, d: unsafe *Decl, at: SourceRange) -> u32 {
        var n: u32 = 0
        var ns     = self._spell.ns_segments(d)
        if ns.size() > 0 {
            self._cg->sink->spell(
                at,
                "namespace " + self._spell.ns_join(&ns) + " {",
            )

            n += 1
        }

        if Speller::is_anon(d) && decl_extension_of(d) == &null {
            self._cg->sink->spell(at, "namespace {")
            n += 1
        }

        return n
    }

    prot fn _close_ns(self, at: SourceRange, n: u32) {
        for var i: u32 = 0; i < n; ++i {
            self._cg->sink->spell(at, "}")
        }

        if n > 0 {
            self._cg->sink->brk()
        }
    }

    /// A free function, or an extension member (\p ext non-null): the
    /// out-of-line definition of its scope's static member, receiver first
    /// (`void __kairo_ext_Vec::push(Vec* self, ...)`; no `static` out of line).
    priv fn _free_fn(self, n: unsafe *FunctionDecl, ext: unsafe *ExtensionDecl) {
        if !n->has_body() {
            return
        }

        if self._in_pch(n) {
            return
        }

        if n->body_kind != FnBodyKind::Block {
            self._unsupported_body(n)
            return
        }

        if n->is_method() && ext == &null { // a method reached the free path; its owner emits it.
            return
        }

        var at          = Speller::at(unsafe (n as unsafe *Decl))
        var is_main     = ext == &null && self._spell.is_main(n)
        var wrap:   u32 = 0
        if !is_main {
            wrap = self._open_ns(n, at)
        }

        // One merged list: the extension's parameters, then the member's.
        var head = self._spell.template_head(n)
        // Spelled on the definition too, not left to the interface's
        // declaration: the definition alone must say what symbol it is.
        if ext == &null && !is_main {
            head += Speller::c_linkage(n)
        }

        // As the interface's declaration (a definition with no earlier
        // declaration is the function's first).
        if !is_main {
            head += Speller::fn_attrs(n)
            self._cc_mark(n)
        }

        // `inline` puts the body in the interface (EmitPlan::visible_bodies):
        // every TU that declares it defines it, its own TU included, with the
        // same text, and the linker keeps one.
        if n->is_inline() && !is_main {
            head += "inline "
        }

        // Compiler/Spec/Eval.md#eval-fn: the definition repeats the interface's `consteval`.
        if n->is_eval() && !is_main {
            head += "consteval "
        }

        head += (if (is_main) => ("int") else => self._spell.declared_return(n))
        head += " "
        if ext != &null {
            head += self._spell.ext_scope_name(ext) + "::"
        }

        head += self._spell.leaf(n)
        head += self._spell.spec_suffix(n) // `p<int>`: the specialization defined.
        head += "("
        head += self._params_text(n, ext)
        head += ")"
        if n->no_unwind {
            head += " noexcept"
        }

        self._cg->sink->spell(at, head)

        self._body(n, ext)
        self._close_ns(n->range, wrap)
    }

    /// `RET Owner::name(params) [const|noexcept] { body }`, inside the owner's wrapper.
    priv fn _method(self, m: unsafe *FunctionDecl, owner: unsafe *Decl) {
        if !m->has_body() {
            return
        }

        // With its eval field's definition (_eval_field_def), as the PCH's
        // stream wrote them.
        if self._in_pch(m) {
            return
        }

        if m->body_kind != FnBodyKind::Block {
            self._unsupported_body(m)
            return
        }

        if m->ci_split > 0 {
            self._split_ctor(m, owner)
            return
        }

        var at   = Speller::at(unsafe (m as unsafe *Decl))
        var wrap = self._open_ns(owner, at)

        var head = self._spell.owner_template_head(owner)
        head += self._spell.template_head(m)
        head += Speller::fn_attrs(m)
        self._cc_mark(m)
        // Out of line, so the class definition stays the same bytes in every
        // TU (invariant 11); see _free_fn.
        if m->is_inline() {
            head += "inline "
        }

        if m->is_eval() {
            head += "consteval "
        } // Compiler/Spec/Eval.md#eval-fn
        else if m->is_constexpr() {
            head += "constexpr "
        } // an eval class's field default (7b).

        var is_ctor = self._spell.leaf(m) == self._spell.leaf(owner)
        var nm      = self._spell.leaf(m)
        // `op as` spells `operator T`; C++ gives a conversion no return type.
        // An extension's is a named static member with an ordinary one.
        var is_conv = m->is_operator
            && m->op_token[0].kind == TokenKind::KwAs
            && decl_extension_of(m) == &null
        var qual = self._spell.owner_qual(owner)
        if is_ctor {
            // The qualifier spells the class's name, which is the
            // constructor's too: on the name it would take the byte the
            // constructor's own name is anchored on (TokenSink::_claim, one
            // exact token per byte), so the head up to it goes on the decl's
            // first byte, as the in-class declaration does
            // (InterfaceEmitter::_record_def). Clang's "constructor for 'X'
            // must explicitly initialize" lands on the name.
            head += qual + "::"
            var hat = at
            if m->range.is_valid() {
                hat = SourceRange::from_bounds(m->range.start, 1 as u32)
            }

            self._cg->sink->spell(hat, head)
            head = self._spell.leaf(owner)
        } else if nm[0] == ('~' as u8) || is_conv {
            // A destructor or conversion definition takes no return type, and
            // leaf() has already spelled the `~` / `operator T`.
            head += qual + "::" + nm
        } else {
            head += self._spell.declared_return(m)
            head += " "
            head += qual + "::" + nm + self._spell.spec_suffix(m)
        }

        head += "("
        head += self._params_text(m, &null)
        head += ")"
        if m->is_method() && m->is_const() {
            head += " const"
        }

        if m->no_unwind {
            head += " noexcept"
        }

        // The same clause as the in-class declaration's (InterfaceEmitter::
        // _method_decl), which C++ requires of an out-of-line definition.
        var mreq = self._spell.member_requires(m, owner)
        head += mreq
        self._cg->sink->spell(at, head)
        if is_ctor {
            self._mem_inits(m, owner, unsafe &m->body_block->body, true)
        }

        self._req_in_head = mreq.size() > 0
        self._body(m, &null)
        self._req_in_head = false
        self._eval_field_def(m, owner, at)
        self._subscript_forwarder_def(m, owner, at)
        self._close_ns(m->range, wrap)
    }

    /// The member specializations of class method \p f
    /// (Compiler/Spec/Generics.md#member-specializations), ahead of its own
    /// body: `if constexpr (<its arguments>) { return <its function>(this,
    /// args...); }` each, the ones that fix both the class's and the
    /// method's arguments first. C++ cannot specialize a member template of
    /// a class template for every instance, so the method itself picks the
    /// body per instance; a C++ caller of `g.m<int>()` gets the same one.
    /// Two that both apply where neither fixes both (one fixes the method's
    /// arguments, the other the class's) are SC333E in the method's own TU.
    priv fn _member_spec_dispatch(self, f: unsafe *FunctionDecl, at: SourceRange) {
        var specs = cxx::std::vector<unsafe *Decl>()
        Speller::member_specs_of(
            unsafe (f as unsafe *Decl),
            unsafe &specs,
            self._cg->instances,
        )

        if specs.empty() || f->semantic_dc == &null || f->semantic_dc->dc_owner == &null {
            return
        }

        var unsafe *cls   = Speller::rep(f->semantic_dc->dc_owner)
        var        cgs    = decl_generic_params(cls)
        var        fgs    = f->generic_params
        var        cond_t = cxx::std::vector<string>()
        var        cond_u = cxx::std::vector<string>()
        var        calls  = cxx::std::vector<string>()
        for var i: usize = 0; i < specs.size(); ++i {
            var unsafe *s   = cast<FunctionDecl>(specs[i])
            var unsafe *ext = decl_extension_of(specs[i])
            var unsafe *rt = if (ext != &null
                                 && ext->target != &null
                                 && ext->target->canonical != &null) => (dyn_cast<RecordType>(
                                 canon_unqual(ext->target->canonical),
                             ))
                             else => (unsafe (&null as unsafe *RecordType))
            if rt == &null {
                self._ice(
                    s->range,
                    "EmitIR: a member specialization whose extension has no record target",
                )
            }

            var fixed_t = decl_generic_params(unsafe (ext as unsafe *Decl)).size() == 0
            var ct = ""
            for var k: usize = 0; fixed_t && k < cgs.size() && k < rt->args.size(); ++k {
                if ct.size() > 0 {
                    ct += " && "
                }

                ct += "__is_same(" + self._spell.tparam_name(
                    cgs[k],
                    cls,
                ) + ", " + self._spell._type(rt->args[k]) + ")"
            }

            var cu = ""
            if s->spec_kind == SpecKind::Explicit {
                for var k: usize = 0; k < fgs.size() && k < s->spec_args.size(); ++k {
                    if cu.size() > 0 {
                        cu += " && "
                    }

                    cu += "__is_same(" + self._spell.tparam_name(
                        fgs[k],
                        unsafe (f as unsafe *Decl),
                    ) + ", " + self._spell._type(s->spec_args[k]->canonical) + ")"
                }
            }

            // Its template arguments: the extension's parameters are the
            // class's (`extend <T> G<T>`), its own the method's.
            var ta  = ""
            var tps = Speller::template_params(specs[i])
            if tps.size() > 0 {
                var names = cxx::std::vector<string>()
                if !fixed_t {
                    for var k: usize = 0; k < cgs.size(); ++k {
                        names.push_back(self._spell.tparam_name(cgs[k], cls))
                    }
                }

                if s->spec_kind != SpecKind::Explicit {
                    for var k: usize = 0; k < fgs.size(); ++k {
                        names.push_back(
                            self._spell.tparam_name(
                                fgs[k],
                                unsafe (f as unsafe *Decl),
                            ),
                        )
                    }
                }

                ta = "<"
                for var k: usize = 0; k < names.size(); ++k {
                    if k > 0 {
                        ta += ", "
                    }

                    ta += names[k]
                }

                ta += ">"
            }

            var args = ""
            if f->is_method() {
                args = "this"
            }

            var fid = Speller::fid_of(unsafe (f as unsafe *Decl))
            for var k: usize = 0; k < f->params.size(); ++k {
                var unsafe *p = f->params[k]
                if p == &null || p->is_self {
                    continue
                }

                var nm = self._spell.tok_name(p->name, fid)
                if args.size() > 0 {
                    args += ", "
                }

                args += "static_cast<decltype(" + nm + ")&&>(" + nm + ")"
            }

            cond_t.push_back(ct)
            cond_u.push_back(cu)
            calls.push_back(
                self._spell.qual_name(specs[i]) + ta + "(" + args + ")",
            )
        }

        // Overlap: one fixing only the method's arguments beside one fixing
        // only the class's, with none fixing both of theirs; or two alike.
        var home = Speller::fid_of(unsafe (f as unsafe *Decl)) == self._cg->ctx->fid
        for var i: usize = 0; home && i < specs.size(); ++i {
            for var j: usize = 0; j < specs.size(); ++j {
                if i == j {
                    continue
                }

                var same = j > i && cond_t[i] == cond_t[j] && cond_u[i] == cond_u[j]
                var cross = cond_t[i].size() == 0
                    && cond_u[i].size() > 0
                    && cond_t[j].size() > 0
                    && cond_u[j].size() == 0
                if cross {
                    for var k: usize = 0; k < specs.size(); ++k {
                        if cond_t[k] == cond_t[j] && cond_u[k] == cond_u[i] {
                            cross = false
                        }
                    }
                }

                if !same && !cross {
                    continue
                }

                var nm = self._spell.tok_name(
                    f->name,
                    Speller::fid_of(unsafe (f as unsafe *Decl)),
                )

                self._cg->ctx->diag_sink.report(
                    DiagCode(DiagID::SC333E),
                    specs[j]->range.start,
                    f"two specializations of '{nm}' both apply to one instance and argument list, and neither fixes both: specialize that combination itself, with `fn <> {nm}<...>` in an extension of the instance",
                ).first(specs[j]->range)->note(
                    DiagCode(DiagID::SC333N),
                    specs[i]->range.start,
                    "the other specialization is here",
                )->child_first(specs[i]->range)->emit()
            }
        }

        for var pass: usize = 0; pass < 2; ++pass {
            for var i: usize = 0; i < specs.size(); ++i {
                var full = cond_t[i].size() > 0 && cond_u[i].size() > 0
                if full != (pass == 0) {
                    continue
                }

                var cond = cond_t[i]
                if cond_u[i].size() > 0 {
                    cond = if (cond.size() > 0) => (cond + " && " + cond_u[i]) else => cond_u[i]
                }

                self._cg->sink->spell(
                    at,
                    "if constexpr (" + cond + ") { return " + calls[i] + "; }",
                )
            }
        }
    }

    /// The `operator[]` forwarder to split subscript form \p m's named member
    /// (Speller::subscript_forwarded; InterfaceEmitter declares it), here,
    /// beside \p m's own definition: out of the class, where a by-value
    /// result or operand (`Slice<T>`, `Range<usize>`) is complete, and with
    /// \p m's own inline-ness and owner template head, so it is wherever
    /// \p m's definition is.
    priv fn _subscript_forwarder_def(self,
                                     m:     unsafe *FunctionDecl,
                                     owner: unsafe *Decl,
                                     at:    SourceRange) {
        if !self._spell.subscript_forwarded(m) {
            return
        }

        var head = self._spell.owner_template_head(owner)
        if m->is_inline() {
            head += "inline "
        }

        if m->is_constexpr() {
            head += "constexpr "
        }

        head += self._spell.declared_return(m) + " " + self._spell.owner_qual(
            owner,
        ) + "::operator[]("
        head += self._params_text(m, &null)
        head += ")"
        if m->is_const() {
            head += " const"
        }

        if m->no_unwind {
            head += " noexcept"
        }

        head += self._spell.member_requires(m, owner)
        var args = ""
        var fid  = Speller::fid_of(unsafe (m as unsafe *Decl))
        for var i: usize = 0; i < m->params.size(); ++i {
            var unsafe *p = m->params[i]
            if p == &null || p->is_self {
                continue
            }

            var nm = self._spell.tok_name(p->name, fid)
            if args.size() > 0 {
                args += ", "
            }

            args += "static_cast<decltype(" + nm + ")&&>(" + nm + ")"
        }

        self._cg->sink->spell(
            at,
            head + " { return " + self._spell.leaf(
                unsafe (m as unsafe *Decl),
            ) + "(" + args + "); }",
        )
    }

    /// A Kairo definition of a function C++ declares (`fn W::at`, `fn
    /// ns::f`; Speller::defines_foreign), at global scope in the C++
    /// declaration's own signature: its return, its parameter types (a
    /// `const T&` the Kairo side reads as `x: T` stays `const T&`), its
    /// `const`, and `noexcept` only when C++ says so. Anything else would
    /// declare a second function beside the one C++ calls, and the C++
    /// declaration would stay undefined. The names are the definition's
    /// own, so the body reads them as written.
    priv fn _foreign_def(self, f: unsafe *FunctionDecl) {
        if !f->has_body() || self._in_pch(f) {
            return
        }

        if f->body_kind != FnBodyKind::Block {
            self._unsupported_body(f)
            return
        }

        var unsafe *cxx = f->first_decl()
        var        at   = Speller::at(unsafe (f as unsafe *Decl))
        // The C++ name as imported; qual_name would go through Speller::rep,
        // which is this Kairo definition, and spell it under the module.
        var nm = decl_cxx_spelling(unsafe (cxx as unsafe *Decl))
        if nm.starts_with("::") {
            nm = nm.subslice(2, nm.size())
        }

        // Not emitted yet: a constructor or destructor
        // (no return type, member initializers) and a template's member.
        // They stay unemitted.
        var last = nm
        var prev = ""
        var cut  = nm.rfind("::")
        if cut != usize::MAX {
            last = nm.subslice(cut + 2, nm.size())
            var outer = nm.subslice(0, cut)
            var cut2  = outer.rfind("::")
            prev = if (cut2 != usize::MAX) => (outer.subslice(cut2 + 2, outer.size())) else => outer
        }

        if last.starts_with("~")
            || last == prev
            || decl_generic_params(unsafe (f as unsafe *Decl)).size() > 0
            || nm.rfind("<") != usize::MAX {
            return
        }

        // The declarator-id is parenthesized (as InterfaceEmitter's explicit
        // instances): after a class return type, `W ::W::at` would lex as
        // one nested-name-specifier.
        var head        = self._spell.declared_return(f) + " (" + nm + ")("
        var fp:   usize = 0
        var first       = true
        for var i: usize = 0; i < f->params.size(); ++i {
            var unsafe *p = f->params[i]
            if p == &null || p->is_self {
                continue
            }

            while fp < cxx->params.size()
                && (cxx->params[fp] == &null || cxx->params[fp]->is_self) {
                fp += 1
            }

            if fp >= cxx->params.size() {
                self._ice(
                    f->range,
                    "EmitIR: a definition of a C++ function has more parameters than its declaration",
                )
            }

            if !first {
                head += ", "
            }

            first = false
            head += self._spell.decl(
                cxx->params[fp]->type_,
                self._spell.tok_name(
                    p->name,
                    Speller::fid_of(unsafe (f as unsafe *Decl)),
                ),
            )

            fp += 1
        }

        head += ")"
        if f->is_method() && f->is_const() {
            head += " const"
        }

        if cxx->ffi_noexcept {
            head += " noexcept"
        }

        self._cg->sink->spell(at, head)
        self._body(f, &null)
        self._cg->sink->brk()
    }

    /// `inline constexpr T const R::k = R::__kairo_init_k();` for the eval
    /// field whose consteval thunk \p m is, right after the thunk's body: a
    /// constant expression may call a consteval function only once it is
    /// defined, so InterfaceEmitter, which writes the other statics after
    /// the class, leaves this one here. The thunk is an eval fn, so its body
    /// (and with it this definition) is in every TU that sees the class.
    priv fn _eval_field_def(self, m: unsafe *FunctionDecl, owner: unsafe *Decl, at: SourceRange) {
        if !m->is_eval() || !m->is_implicit {
            return
        }

        var fields: unsafe *FrozenList<unsafe *FieldDecl> = &null
        if isa<ClassDecl>(owner) {
            fields = unsafe &cast<ClassDecl>(owner)->fields
        } else if isa<StructDecl>(owner) {
            fields = unsafe &cast<StructDecl>(owner)->fields
        }

        if fields == &null {
            return
        }

        for var i: usize = 0; i < fields->size(); ++i {
            var unsafe *f = (*fields)[i]
            if f == &null || !f->is_eval() || f->init_fold != FieldFold::Thunk {
                continue
            }

            if f->init_thunk != m {
                continue
            }

            var q  = self._spell.owner_qual(owner)
            var nm = q + "::" + self._spell.leaf(unsafe (f as unsafe *Decl))
            var s = self._spell.owner_template_head(owner) + "inline constexpr const "
            s += self._spell.decl(f->type_, nm)
            s += " = " + q + "::" + self._spell.leaf(m) + "();"
            self._cg->sink->spell(at, s)
            // Compiler/Spec/Eval.md#deferred-conditions: the value an `eval if` was decided on (_global_var).
            var pin = decl_fold_pin(f)
            if pin.size() > 0 {
                self._cg->sink->spell(
                    at,
                    "static_assert(" + nm + " == " + pin + ", \"EVAL.md 4.2b: an eval if was decided on this constant; Kairo's type facts and clang disagree on its value\");",
                )
            }

            return
        }
    }

    /// Parameter text for a DEFINITION: names always, `self` only for an
    /// extension member (as the receiver pointer).
    prot fn _params_text(self, f: unsafe *FunctionDecl, ext: unsafe *ExtensionDecl) -> string {
        var s     = ""
        var first = true
        for var i: usize = 0; i < f->params.size(); ++i {
            var unsafe *p = f->params[i]
            if p == &null {
                continue
            }

            if p->is_self {
                if ext == &null {
                    continue
                }

                if !first {
                    s += ", "
                }

                first = false
                // An extension operator takes its receiver by reference (see
                // InterfaceEmitter::_params); _body rebinds `self` from it.
                s += self._spell.ext_receiver(f, ext)
                s += if (f->is_operator) => (" " + LowerTargets::ext_self())
                     else => " " + LowerTargets::ext_receiver_name()
                continue
            }

            if !first {
                s += ", "
            }

            first = false
            s += self._spell.param_decl(
                p,
                self._spell.tok_name(
                    p->name,
                    Speller::fid_of(unsafe (f as unsafe *Decl)),
                ),
            )
        }

        // The postfix `int` dummy, same rule as the declaration side.
        if Speller::op_is_postfix(f) {
            if !first {
                s += ", "
            }

            s += "int"
        }

        return s
    }

    prot fn _body(self, f: unsafe *FunctionDecl, ext: unsafe *ExtensionDecl) {
        var unsafe *saved_fn  = self._cur_fn
        var unsafe *saved_ext = self._cur_ext
        var        ul_mark    = self._ul_decl.size()
        self._cur_fn  = f
        self._cur_ext = ext
        // Opened here rather than through emit_block: an extension operator's
        // body starts with `X* self = &__kairo_self;`, so everything below it
        // -- `self->v`, the receiver passed on -- is the pointer form every
        // other extension member uses, and the body emits unchanged.
        var unsafe *b = f->body_block
        if b == &null {
            self._ice(f->range, "EmitIR: null block reached codegen")
        }

        self._cg->sink->synth_at_start(b->range, clang::tok::l_brace)
        if ext != &null && f->is_operator {
            var pro = if (f->is_const()) => ("const ") else => ""
            // `[i32; 2]`'s pointer is `int (*self)[2]`: one type-specifier.
            pro += self._spell.type_specifier(
                ext->target,
            ) + "* " + LowerTargets::ext_receiver_name() + " = &" + LowerTargets::ext_self() + ";"
            self._cg->sink->spell(b->range, pro)
        }

        // The value predicates of the function's `requires` (Compiler/Spec/Eval.md#evaluation-model,
        // E10): asserted where C++ can evaluate them, per instance in a
        // template. EvalUsageChecking already refused a run-time one.
        var vps = cxx::std::vector<unsafe *Expr>()
        if !self._req_in_head && !self._spell.fn_preds_in_head(f) {
            Speller::value_predicates(f->requires_clause, unsafe &vps)
        }

        for var i: usize = 0; i < vps.size(); ++i {
            self._cg->sink->spell(vps[i]->range, "static_assert(")
            self.emit(vps[i])
            self._cg->sink->spell(
                vps[i]->range,
                ", \"requires clause of '" + self._spell.leaf(f) + "' not satisfied\");",
            )
        }

        // A bounded generic record's bounds, which its head cannot carry,
        // asserted where a value is made (Speller::ctor_bound_asserts).
        if self._is_ctor(f) {
            var cba = self._spell.ctor_bound_asserts(f)
            for var i: usize = 0; i < cba.size(); ++i {
                self._cg->sink->spell(b->range, cba[i])
            }
        }

        if ext == &null {
            self._member_spec_dispatch(f, b->range)
        }

        var egen       = f->is_generator && f->is_eval()
        var saved_gens = self._ef_gens
        self._ef_gens = 0
        if egen {
            var unsafe *et = self._yield_elem(f)
            if et == &null {
                self._ice(
                    f->range,
                    "EmitIR: an eval generator with no element type",
                )
            }

            self._cg->sink->spell(
                b->range,
                "::" + LowerTargets::eval_buf() + "<" + self._spell._type(
                    et,
                ) + "> " + LowerTargets::eval_yield_buf() + ";",
            )
        }

        // A constructor's leading `Base::Base(self, ...)` calls went out as
        // its mem-initializers (_mem_inits).
        var from: usize = 0
        if self._is_ctor(f) {
            from = self._lead_base_inits(b->body)
        }

        var dl = self._dynamic_layout_of(f)
        if dl != 0 {
            self._dynamic_layout_body(f, dl, b)
            from = b->body.size()
        }

        for var i: usize = from; i < b->body.size(); ++i {
            self.emit(b->body[i])
        }

        // A function is a coroutine only when its body holds a coroutine
        // keyword, and a generator with no `yield` (or only a bare `return`
        // the emitter already spelled `co_return`) may have none. X's
        // has_yield says which; EmitIR does not walk the body to find out.
        if egen {
            self._cg->sink->spell(
                b->range,
                "return " + LowerTargets::eval_yield_buf() + ";",
            )
        } else if f->is_generator && !f->has_yield {
            self._cg->sink->spell(b->range, "co_return;")
        }

        self._ef_gens = saved_gens
        self._cg->sink->synth_at_end(b->range, clang::tok::r_brace)
        self._ul_leave(ul_mark)
        self._cur_fn  = saved_fn
        self._cur_ext = saved_ext
    }

    /// 1 for the DynamicSize lang item, 2 for DynamicAlign, else 0
    /// (FunctionDecl::dynamic_layout, on the decl or its representative).
    priv fn _dynamic_layout_of(self, f: unsafe *FunctionDecl) -> u8 {
        if f == &null {
            return 0
        }

        if f->dynamic_layout != 0 {
            return f->dynamic_layout
        }

        var unsafe *xf = dyn_cast<FunctionDecl>(Speller::rep(f))
        if xf != &null {
            return xf->dynamic_layout
        }

        return 0
    }

    /// `__builtin_dynamic_size<T>(p)` / `_align`'s body, in place of the
    /// library's `sizeof T` / `alignof T`: the dynamic type's {size, align}
    /// through T's hidden `__kairo_layout()` when it has one (a Kairo class
    /// with a virtual destructor, InterfaceEmitter::_layout_virtual), else
    /// T's own. A polymorphic T without one would answer for the base, as a
    /// delete through it already destroys only the base: refused, here as
    /// in ConformanceChecking.
    priv fn _dynamic_layout_body(self,
                                 f:     unsafe *FunctionDecl,
                                 which: u8,
                                 b:     unsafe *CompoundStmt) {
        if f->params.size() != 1 || f->generic_params.size() != 1 || f->params[0] == &null {
            self._ice(
                f->range,
                "EmitIR: a dynamic-layout intrinsic is not fn <T>(p: *T)",
            )
        }

        var p = self._spell.tok_name(
            f->params[0]->name,
            Speller::fid_of(unsafe (f as unsafe *Decl)),
        )

        var t = self._spell.tparam_name(
            f->generic_params[0],
            Speller::rep(unsafe (f as unsafe *Decl)),
        )

        var lv = LowerTargets::layout_virtual()
        var k  = if (which == 1) => ("0") else => "1"
        var kw = if (which == 1) => ("sizeof") else => "alignof"
        var nm = self._spell.leaf(unsafe (f as unsafe *Decl))
        self._cg->sink->spell(
            b->range,
            "if constexpr (requires { " + p + "->" + lv + "(); }) { return " + p + "->" + lv + "()[" + k + "]; }" + " else { static_assert(!__is_polymorphic(" + t + "), \"" + nm + ": T is polymorphic but has no virtual destructor, so the size of what p points at is unknown\");" + " return " + kw + "(" + t + "); }",
        )
    }

    priv fn _unsupported_body(self, f: unsafe *FunctionDecl) {
        match f->body_kind {
            case FnBodyKind::Expr {
                self._ice(
                    f->range,
                    "EmitIR: expression-bodied function; Lower/ must wrap it in a return block",
                )
            } case FnBodyKind::Default { // declared `= default`; nothing to define.
                return
            } case FnBodyKind::Delete {
                return
            } case FnBodyKind::Virtual {
                return
            } default {
                return
            }
        }
    }
}
