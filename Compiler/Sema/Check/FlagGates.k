/// --- The Kairo Project ----------------------- Sema/Check/FlagGates.k --- ///
///
///   \brief Enforces the language gate flags and the declaration-size limits
///          the command line can set (--no-unsafe / -fno-unsafe, --no-fp,
///          --no-ffi, --no-cxx, --no-yield, --no-modules, --cmax-*), and the
///          one gate that is CLOSED by default: `<T: type>` needs
///          -fduck-generics.
///
///   \detail
///     Every rule here is a plain walk over the tree the user wrote: a gate
///     reports a construct, a limit reports a declaration that is too big.
///     Nothing is inferred and nothing is rewritten.
///
///     Scheduled after ExprTyper because --no-fp reads the type X gave each
///     expression, and before the lowerings so what is reported is the
///     user's construct and not a synthesized one (a lowering invents calls,
///     casts and, for `for`, whole loops).
///
///     Only the program's OWN files are checked. Sema runs once per file of
///     the build, the builtin root and the std library included, and std is
///     full of `ffi "c++"`, floats and `unsafe`: gating it would make every
///     flag unusable, since the user cannot edit the library to comply. The
///     library test is the one SemaDump already uses (builtin by fid, std by
///     the root the driver mounts it from).
///
///     Not covered, on purpose: a single `ffi "c" fn ...` written outside an
///     import or an `ffi { }` block, and a float type that appears only in a
///     return type. Those carry no expression and no import to report on.
///
///     Every gate is SC198E and every limit SC199E.
///
///   Phase: CHECKS
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ----------------------------------------------------------------- ///

ffi "c++" import "vector"

import AST::Kind::ExprKind::ExprKind
import AST::Node::Base::{
    Expr,
    Type,
}
import AST::Node::Casting::dyn_cast
import AST::Node::Declarations
import AST::Node::Expressions::{
    AwaitExpr,
    MatchExpr,
    UnsafeExpr,
}
import AST::Node::Program::TopLevelKind
import AST::Node::Statements::{
    FFILang,
    MatchStmt,
    UnsafeBlockStmt,
    YieldStmt,
    ffi_lang_of_literal,
}
import AST::Visitor::RecursiveASTVisitor::RecursiveASTVisitor
import Config::ResourceLayout::ResourceLayout
import Diagnostic::Registry::DiagID
import Location::SourceRange::SourceRange
import Sema::SemaContext::SemaContext
import Sema::Type::TypeUtil::TypeUtil

pub class FlagGates derives RecursiveASTVisitor<FlagGates> {
    pub var  sc:  unsafe *SemaContext
    priv var _tu: TypeUtil
    /// Canonical target of every `extend` block seen so far in this file, in
    /// order: the Nth block on one type is the one that crosses
    /// --cmax-extend-chain, and a count is all that needs remembering.
    priv var _ext_seen: cxx::std::vector<unsafe *Type>

    fn FlagGates(self, sc: unsafe *SemaContext) {
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

        if !self._anything_enabled() {
            return
        }

        if self._library_tu() {
            return
        }

        // Imports are not in program->items: the PP moved them into
        // tu->imports.
        for var i: usize = 0; i < tu->imports.size(); ++i {
            var unsafe **slot = tu->imports[i]
            if slot == &null {
                continue
            }

            var unsafe *id = dyn_cast<Declarations::ImportDecl>(*slot)
            if id == &null {
                continue
            }

            self._import(id)
        }

        var *items = &tu->program->items
        for var i: usize = 0; i < items->size(); i++ {
            var item = *items->get(i)
            match item.kind {
                case TopLevelKind::Decl {
                    self.dispatch_decl(item.as_decl())
                } case TopLevelKind::Stmt {
                    self.dispatch_stmt(item.as_stmt())
                } case TopLevelKind::Expr {
                    self.dispatch_expr(item.as_expr())
                }
            }
        }
    }

    /// # gates

    fn visit_unsafe_block_stmt(self, n: *UnsafeBlockStmt) -> bool {
        if self.sc->opts.no_unsafe {
            self._deny(
                n->range,
                "an unsafe block is not allowed when unsafe code is disabled",
                "unsafe block",
                "--no-unsafe / -fno-unsafe",
            )
        }

        return true
    }

    fn visit_unsafe_expr(self, n: *UnsafeExpr) -> bool {
        if self.sc->opts.no_unsafe {
            self._deny(
                n->range,
                "an unsafe expression is not allowed when unsafe code is disabled",
                "unsafe expression",
                "--no-unsafe / -fno-unsafe",
            )
        }

        return true
    }

    fn visit_yield_stmt(self, n: *YieldStmt) -> bool {
        if self.sc->opts.no_yield {
            self._deny(
                n->range,
                "'yield' is not allowed when yield and async are disabled",
                "yield statement",
                "--no-yield",
            )
        }

        return true
    }

    fn visit_await_expr(self, n: *AwaitExpr) -> bool {
        if self.sc->opts.no_yield {
            self._deny(
                n->range,
                "'await' is not allowed when yield and async are disabled",
                "await expression",
                "--no-yield",
            )
        }

        return true
    }

    fn visit_function_decl(self, n: *Declarations::FunctionDecl) -> bool {
        if n->is_poisoned() {
            return true
        }

        if self.sc->opts.no_yield {
            if n->is_generator {
                self._deny(
                    n->range,
                    "a generator ('-> yield T') is not allowed when yield and async are disabled",
                    "generator function",
                    "--no-yield",
                )
            } else if (n->modifiers & Declarations::FnModifier::IsAsync) != Declarations::FnModifier::None {
                self._deny(
                    n->range,
                    "an async function is not allowed when yield and async are disabled",
                    "async function",
                    "--no-yield",
                )
            }
        }

        var cap = self.sc->opts.max_function_params
        if cap > 0 {
            // `self` is the receiver, not a parameter the user wrote.
            var count: usize = 0
            for var i: usize = 0; i < n->params.size(); ++i {
                var unsafe *p = n->params[i]
                if p == &null || p->is_self {
                    continue
                }

                count += 1
            }

            if count > (cap as usize) {
                self._limit(
                    n->range,
                    "function has too many parameters",
                    count,
                    cap,
                    "--cmax-function-params",
                )
            }
        }

        return true
    }

    fn visit_ffi_block_decl(self, n: *Declarations::FFIBlockDecl) -> bool {
        if self.sc->opts.no_ffi {
            self._deny(
                n->range,
                "an ffi block is not allowed when ffi is disabled",
                "ffi block",
                "--no-ffi",
            )
        } else if self.sc->opts.no_cxx {
            // C++ by the parser's table: "cpp", "C++", "hpp" too, not only
            // a spelling that ends in "c++".
            var lang = self.sc->ctx->get_spelling(n->lang_token)
            if ffi_lang_of_literal(lang) == FFILang::Cpp {
                self._deny(
                    n->range,
                    "an ffi \"c++\" block is not allowed when C++ interop is disabled",
                    "ffi \"c++\" block",
                    "--no-cxx",
                )
            }
        }

        return true
    }

    /// # `: type` (Compiler/Spec/Generics.md#duck-regime)

    /// `<T: type>` is the transitional C++-checked regime: its body is typed
    /// as written and clang checks each instance, which is the opposite of
    /// the language's rule (checked once, against the bounds). It exists for
    /// the self-host corpus until the mixin migration gives every such
    /// parameter a real bound. The gate is shut by default (decided 2026-11-08):
    /// -fduck-generics is internal, passed by build.py for the compiler's own
    /// targets (SemaContext::duck_generics); without it every `: type` in a
    /// program file is this error.
    ///
    /// The regime itself is unchanged when the gate fires (ChainBinding still
    /// defers every member step), so the one error is all the user sees.
    /// The fix-it deletes `: type` only when no member step went through the
    /// parameter: then the opaque `<T>` it leaves accepts the same body. With
    /// a member use, deleting it would trade this error for R051E and naming
    /// an interface would invent one, so the way out is a note instead.
    fn visit_generic_param_decl(self, n: unsafe *Declarations::GenericParamDecl) -> bool {
        if self.sc->opts.duck_generics {
            return true
        }

        if n->kind_bound != Declarations::GenericParamKindBound::Duck {
            return true
        }

        var name = self.sc->ctx->get_spelling(n->name)
        var at   = n->kind_bound_range
        if !at.is_valid() {
            at = n->range
        }

        var b = self.sc->diag->report(
            DiagID::SC198E,
            at.start,
            f"'{name}: type' needs -fduck-generics: a generic body is checked against its bounds, not per instance",
        )

        b.first(at, "C++-checked `: type` bound")

        var use_at = SourceRange::invalid()
        for var i: usize = 0; i < self.sc->duck_member_params.size(); ++i {
            if self.sc->duck_member_params[i] == n {
                use_at = self.sc->duck_member_at[i]
                break
            }
        }

        if use_at.is_valid() {
            b.note(
                use_at.start,
                f"the body uses a member of '{name}' here; declare an interface with the members it needs and bound the parameter '{name} impl <Interface>'",
            )
        } else {
            b.remove(
                at,
                f"remove ': type'; the body uses no member of '{name}', so an unbounded '{name}' accepts it",
            )
        }

        b.note(
            "`: type` is the transitional regime clang checks per instance; -fduck-generics enables it",
        )

        b.emit()
        return true
    }

    /// # floating point

    /// Returning false after a report stops the walk below this node, so a
    /// float-typed expression is reported once at its outermost float-typed
    /// ancestor rather than once per operand.
    fn visit_expr(self, n: *Expr) -> bool {
        if !self.sc->opts.no_fp {
            return true
        }

        if n->kind == ExprKind::FloatingLiteralExpr {
            self._deny(
                n->range,
                "a floating-point literal is not allowed when floating point is disabled",
                "floating-point literal",
                "--no-fp",
            )

            return false
        }

        if n->is_poisoned() || !self._is_fp(n->type_) {
            return true
        }

        self._deny(
            n->range,
            "a floating-point expression is not allowed when floating point is disabled",
            "floating-point expression",
            "--no-fp",
        )

        return false
    }

    /// A float-typed parameter, field or uninitialized variable has no
    /// expression of its own to report on.
    fn visit_param_decl(self, n: *Declarations::ParamDecl) -> bool {
        if !self.sc->opts.no_fp || n->is_poisoned() {
            return true
        }

        if self._is_fp(n->type_) {
            self._deny(
                n->range,
                "a floating-point parameter is not allowed when floating point is disabled",
                "floating-point parameter",
                "--no-fp",
            )
        }

        return true
    }

    fn visit_variable_decl(self, n: *Declarations::VariableDecl) -> bool {
        if !self.sc->opts.no_fp || n->is_poisoned() {
            return true
        }

        // With an initializer the initializer is what gets reported.
        if n->init == &null && self._is_fp(n->type_) {
            self._deny(
                n->range,
                "a floating-point variable is not allowed when floating point is disabled",
                "floating-point variable",
                "--no-fp",
            )
        }

        return true
    }

    fn visit_field_decl(self, n: *Declarations::FieldDecl) -> bool {
        if !self.sc->opts.no_fp || n->is_poisoned() {
            return true
        }

        if self._is_fp(n->type_) {
            self._deny(
                n->range,
                "a floating-point field is not allowed when floating point is disabled",
                "floating-point field",
                "--no-fp",
            )
        }

        return true
    }

    /// # declaration limits

    fn visit_struct_decl(self, n: *Declarations::StructDecl) -> bool {
        if n->is_poisoned() || n->is_adt_payload {
            return true
        }

        var cap = self.sc->opts.max_struct_fields
        if cap > 0 && n->fields.size() > (cap as usize) {
            self._limit(
                n->name.range,
                "struct has too many fields",
                n->fields.size(),
                cap,
                "--cmax-struct-fields",
            )
        }

        var icap = self.sc->opts.max_interface_impls
        if icap > 0 && n->implements.size() > (icap as usize) {
            self._limit(
                n->name.range,
                "struct implements too many interfaces",
                n->implements.size(),
                icap,
                "--cmax-interface-impls",
            )
        }

        return true
    }

    fn visit_class_decl(self, n: *Declarations::ClassDecl) -> bool {
        if n->is_poisoned() {
            return true
        }

        var cap = self.sc->opts.max_struct_fields
        if cap > 0 && n->fields.size() > (cap as usize) {
            self._limit(
                n->name.range,
                "class has too many fields",
                n->fields.size(),
                cap,
                "--cmax-struct-fields",
            )
        }

        var icap = self.sc->opts.max_interface_impls
        if icap > 0 && n->implements.size() > (icap as usize) {
            self._limit(
                n->name.range,
                "class implements too many interfaces",
                n->implements.size(),
                icap,
                "--cmax-interface-impls",
            )
        }

        return true
    }

    fn visit_enum_decl(self, n: *Declarations::EnumDecl) -> bool {
        if n->is_poisoned() {
            return true
        }

        var cap = self.sc->opts.max_enum_variants
        if cap > 0 && n->variants.size() > (cap as usize) {
            self._limit(
                n->name.range,
                "enum has too many variants",
                n->variants.size(),
                cap,
                "--cmax-enum-variants",
            )
        }

        return true
    }

    fn visit_union_decl(self, n: *Declarations::UnionDecl) -> bool {
        // An anonymous union is the storage EnumLayoutLowering synthesizes;
        // the user cannot write one, so it has no declaration to blame.
        if n->is_poisoned() || n->is_anonymous {
            return true
        }

        var cap = self.sc->opts.max_union_width
        if cap > 0 && n->fields.size() > (cap as usize) {
            self._limit(
                n->name.range,
                "union has too many members",
                n->fields.size(),
                cap,
                "--cmax-union-width",
            )
        }

        return true
    }

    fn visit_match_stmt(self, n: *MatchStmt) -> bool {
        var cap = self.sc->opts.max_match_arms
        if cap > 0 && n->cases.size() > (cap as usize) {
            self._limit(
                n->range,
                "match has too many arms",
                n->cases.size(),
                cap,
                "--cmax-match-arms",
            )
        }

        return true
    }

    fn visit_match_expr(self, n: *MatchExpr) -> bool {
        var cap = self.sc->opts.max_match_arms
        if cap > 0 && n->cases.size() > (cap as usize) {
            self._limit(
                n->range,
                "match has too many arms",
                n->cases.size(),
                cap,
                "--cmax-match-arms",
            )
        }

        return true
    }

    /// The limit is on how many `extend` blocks one type gathers in this
    /// file; the block that makes it one more than the cap is the one
    /// reported, once.
    fn visit_extension_decl(self, n: *Declarations::ExtensionDecl) -> bool {
        if n->is_poisoned() || n->target == &null {
            return true
        }

        var cap = self.sc->opts.max_extend_chain
        if cap <= 0 {
            return true
        }

        var unsafe *key = n->target->canonical
        if key == &null {
            key = n->target
        }

        var before: usize = 0
        for var i: usize = 0; i < self._ext_seen.size(); ++i {
            if self._ext_seen[i] == key {
                before += 1
            }
        }

        self._ext_seen.push_back(key)
        if before + 1 == (cap as usize) + 1 {
            self._limit(
                n->range,
                "type has too many extend blocks",
                before + 1,
                cap,
                "--cmax-extend-chain",
            )
        }

        var icap = self.sc->opts.max_interface_impls
        if icap > 0 && n->implements.size() > (icap as usize) {
            self._limit(
                n->range,
                "extend block implements too many interfaces",
                n->implements.size(),
                icap,
                "--cmax-interface-impls",
            )
        }

        return true
    }

    /// # helpers

    priv fn _import(self, id: unsafe *Declarations::ImportDecl) {
        // The injected `import builtin::*` is not in the source.
        if id->is_prelude {
            return
        }

        if id->has_ffi_linkage() {
            if self.sc->opts.no_ffi {
                self._deny(
                    id->range,
                    "an ffi import is not allowed when ffi is disabled",
                    "ffi import",
                    "--no-ffi",
                )
            } else if self.sc->opts.no_cxx && id->is_ffi_cpp() {
                self._deny(
                    id->range,
                    "an ffi \"c++\" import is not allowed when C++ interop is disabled",
                    "ffi \"c++\" import",
                    "--no-cxx",
                )
            }

            return
        }

        if self.sc->opts.no_modules {
            self._deny(
                id->range,
                "an import is not allowed when the module system is disabled",
                "import",
                "--no-modules",
            )
        }
    }

    priv fn _is_fp(self, t: unsafe *Type) -> bool {
        if t == &null {
            return false
        }

        var unsafe *c = t->canonical
        if c == &null {
            c = t
        }

        return self._tu.is_float(c)
    }

    priv fn _anything_enabled(self) -> bool {
        var *o = &self.sc->opts
        // Shut (the default; open only under -fduck-generics): every
        // program file is then walked for `: type`.
        if !o->duck_generics {
            return true
        }

        if o->no_unsafe || o->no_fp || o->no_ffi || o->no_cxx || o->no_yield || o->no_modules {
            return true
        }

        if o->max_struct_fields > 0 || o->max_function_params > 0 || o->max_enum_variants > 0 {
            return true
        }

        if o->max_match_arms > 0 || o->max_union_width > 0 || o->max_interface_impls > 0 {
            return true
        }

        return o->max_extend_chain > 0
    }

    /// The builtin root by fid; std by path, against the root the driver
    /// mounts it from (--std-dir, else <resource-dir>/std). Same test as
    /// SemaDump::_library_tu.
    priv fn _library_tu(self) -> bool {
        var fid = self.sc->ctx->fid
        if self.sc->g != &null && self.sc->g->is_builtin_fid(fid) {
            return true
        }

        var unsafe *ci = self.sc->ctx->ci
        if ci == &null || self.sc->ctx->sm == &null {
            return false
        }

        return ResourceLayout::is_std_file(ci, self.sc->ctx->sm->get_filename(fid))
    }

    priv fn _deny(self,
                  at:          SourceRange,
                  const msg:   string,
                  const label: string,
                  const flag:  string) {
        var b = self.sc->diag->report(DiagID::SC198E, at.start, msg)
        b.first(at, label)
        b.note(f"disabled by {flag}")
        b.emit()
    }

    priv fn _limit(self,
                   at:         SourceRange,
                   const what: string,
                   got:        usize,
                   cap:        i32,
                   const flag: string) {
        var b = self.sc->diag->report(DiagID::SC199E, at.start, f"{what} ({got}, limit {cap})")
        b.first(at, "over the limit")
        b.note(f"limit set by {flag}; 0 removes it")
        b.emit()
    }
}
