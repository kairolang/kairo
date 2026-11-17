/// --- The Kairo Project ------------------------ Codegen/Emit/EmitIR.k --- ///
///
/// The body emitter. Declarations are InterfaceEmitter's; this
/// writes what goes between the braces, plus the out-of-line
/// headers those braces hang off (`double Circle::area() {`).
///
///   \par Where its parts are
///     This file holds the class: its fields, construction, the TU entry
///     points (emit_tu, early, emit_bodies), the TU's trailing items (panic
///     sites, the ABI note, the global allocator) and the helpers every part
///     uses. The rest of its methods are `extend EmitIR` blocks, one file
///     per concern, reaching the fields as `prot` (Codegen/module.k makes
///     Codegen/ one module); a helper only its own part calls stays `priv`
///     there:
///       EmitIRDecls.k      function, method and foreign template bodies
///       EmitIRCtors.k      split constructors, mem-initializer lists
///       EmitIRLocals.k     locals, namespace-scope variables, union storage
///       EmitIRStmts.k      the statement dispatcher, return, yield, if, try
///       EmitIRLoops.k      for, while, switch dispatch, eval for, pack for
///       EmitIRExprs.k      the expression dispatcher, closures, small forms
///       EmitIRConvert.k    a value converted to its target type, casts
///       EmitIRNames.k      names and member chains
///       EmitIRCalls.k      calls and their arguments
///       EmitIRLiterals.k   literals and initializers
///       EmitIROperators.k  unary, binary and assignment operators
///       EmitIRForms.k      the checked arithmetic and binding forms
///
///   \par The core, and nothing else
///     This emitter knows the C++-shaped core: names, chains, calls,
///     literals, primitive operators, casts, if/while/for/return/break/
///     continue, locals, blocks, initializers, sizeof/alignof/delete. Every
///     other node ICEs NAMING THE LOWERING THAT OWNS IT. Lower/ reduces into
///     the core; the core never grows an arm for a node Lower/ removes.
///
///   \par No headroom
///     Sema decided everything. This file renders decisions and never lets
///     clang re-make one:
///       - every non-local name is spelled fully qualified from
///         `resolved_decl` (invariant 10: an alias never appears);
///       - `.` vs `->` comes from the base's canonical, not the source;
///       - a callee is the PROMOTED decl; a candidate_cell here is an X
///         gate failure;
///       - an argument whose type differs from the parameter's canonical is
///         cast to it, so every emitted call is Exact under C++'s ranking
///         and there is nothing left for overload resolution to choose;
///       - every compound expression is parenthesized, so Kairo's
///         precedence is the tree's and C++'s table never applies;
///       - a user operator is a CALL, and BinaryOperatorExpr carries no
///         callee. OperatorLowering rewrites it; a record operand here ICEs.
///
///   \par `self`
///     Bound to the `is_self` ParamDecl. Inside a method it is `this`; inside
///     an extension member it is the explicit first parameter and stays
///     `self`. Either way it is a pointer, so a step off it is `->`.
///
///   \par Where bodies land
///     Own functions and methods: this TU, inside the same namespace wrapper
///     InterfaceEmitter declared them in (an out-of-line definition names
///     the entity only if the scopes match). Template member bodies: this
///     TU if it owns the template, and every TU whose plan HOMES an instance
///     of it (Compiler/Spec/Generics.md#generics-across-modules). Extension
///         members: out-of-line definitions
///     of their scope's static members, in its namespace, receiver first.
///
///   \par Constructors that initialize a field in place
///     C++ wants a const member's value at the mem-initializer list, and a
///     member with no default constructor built there too, so a
///     constructor CtorInitCheck split (FunctionDecl::ci_split; the body is
///     `{ {S_pre} {S_post} }` after CtorInitLowering) becomes four
///     definitions (_split_ctor):
///
///       struct R::__kairo_ciK { ::__kairo_slot<T> x; ... };
///       auto R::__kairo_ctor_preK(__kairo_ciK&& __kairo_s, P& p) ->
///           __kairo_ciK& { S_pre; return static_cast<__kairo_ciK&>(__kairo_s);
///           }
///       R::R(__kairo_ciK& __kairo_s, P& p) : x(__kairo_s.x.take()) { S_post }
///       R::R(P p) : R(__kairo_ctor_preK(__kairo_ciK(), p), p) {}
///
///     S_pre runs before any object exists, so in it `self.x = e` fills a
///     slot (`__kairo_s.x.init(e)`, `.put(e)` for a `var` field) and `self.x`
///     reads one; CtorInitCheck allows `self` nowhere else there. A local of
///     S_pre that S_post reads is a slot in both halves. The slot record is
///     the public constructor's temporary, alive to the end of its
///     mem-initializer, which encloses the whole slot constructor; nothing
///     copies or moves it. A field S_pre assigns on every path is built from
///     its slot by mem-initializer, in declaration order; one it assigns on
///     some paths keeps its default and is assigned from the slot, if set,
///     before S_post. Parameters reach both halves by reference
///     (`__kairo_lref`), so what S_pre does to one S_post sees.
///
///   Import law: CodegenContext only. clang::tok is visible transitively.
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

import API::LinkABI::{
    ABI_ALLOC_INLINES_SYSTEM,
    ABI_ALLOC_SETS_GLOBAL,
    ABI_NOTE_KIND_ALLOC,
    ABI_NOTE_KIND_CONV,
    abi_note_magic,
    call_conv_note_bit,
}
import AST::Context::DeclContext::DeclContextKind
import AST::Context::TranslationUnit::TranslationUnit
import AST::DeclFacts::{
    decl_extension_of,
    decl_fields,
}
import AST::Kind::DeclKind::to_string
import AST::Kind::ExprKind::to_string
import AST::Kind::StmtKind::to_string
import AST::Kind::TypeKind::{
    TypeKind,
    to_string,
}
import AST::LangItems::{
    AllocNames,
    GlobalAllocFn,
    LowerTargets,
    to_string,
}
import AST::Node::Base::{
    Decl,
    Expr,
    Stmt,
    Type,
}
import AST::Node::CanonicalNodes::{
    BuiltinKind,
    BuiltinType,
    canon_unqual,
}
import AST::Node::Casting::{
    cast,
    dyn_cast,
    isa,
}
import AST::Node::Declarations::{
    ClassDecl, EnumDecl,   ExtensionDecl, FieldFold, FunctionDecl, GenericParamDecl,
    ParamDecl, StructDecl, TypeAliasDecl, UnionDecl, VariableDecl,
}
import AST::Node::Expressions::{
    ClosureExpr,
    ParenExpr,
}
import AST::Node::PrimaryExpressions::{
    ChainExpr,
    NamedIdentExpr,
}
import AST::Node::Program::TopLevelKind
import AST::Node::Statements::DeclStmt
import AST::Node::Types::{
    CXXLValueRefType,
    CXXRValueRefType,
    FixedArrayType,
    PointerType,
}
import Codegen::CodegenContext::{
    CodegenContext,
    CodegenPhase,
}
import Codegen::CodegenICE::codegen_ice
import Codegen::Emit::EmitIRDecls
import Codegen::Emit::EmitIRExprs
import Codegen::Emit::EmitIRLocals
import Codegen::Emit::EmitIRStmts
import Codegen::Emit::Spell::Speller
import Codegen::EmitPlan::EmitPlan
import Codegen::PlanVisitors::EarlyNeeds
import Codegen::PlanVisitors::HoistedLocals
import Config::Target::ObjectFormat
import Diagnostic::Registry::DiagID
import Location::SourceRange::SourceRange

/// Which of emit_tu's passes is running (Compiler/Spec/Eval.md#eval-fn):
/// the eval pass writes only compile-time bodies, eval free functions first
/// and records' compile-time methods second, and the runtime pass the rest.
pub enum EmitPass derives u8 {
    Runtime = 0,
    EvalFree,
    EvalRecords,
}

/// What this emitter already wrote of a decl, ahead of where the program
/// walk reaches it. Bits, not one state: an eval binding InterfaceEmitter
/// defined early can be one emit_tu hoists too.
pub enum BodyMark derives u8 {
    Done     = 1 << 0, ///< a compile-time body: the eval pass or an early item wrote it
    EarlyVar = 1 << 1, ///< an eval binding InterfaceEmitter defined (early)
    Hoisted  = 1 << 2, ///< an eval binding emit_tu defines ahead of the walk
}

pub class EmitIR {
    /// The bodies and eval bindings the interface PCH this TU loads already
    /// defines (IncludedDecls::body_set, by decl address), or null: each is
    /// left out here, as a kcc include leaves out what an earlier one wrote.
    /// Shared and read-only during the fan-out.
    pub var  pch_bodies: unsafe *llvm::DenseSet<u64> = &null
    prot var _cg:        unsafe *CodegenContext
    prot var _spell:     Speller
    /// The function whose body is being emitted. Decides what `self` means.
    prot var _cur_fn: unsafe *FunctionDecl = &null
    /// _agree's answer to plan_under_duck for the function it last asked
    /// about: every call of one body asks the same question.
    prot var _agree_fn:   unsafe *FunctionDecl = &null
    prot var _agree_duck: bool                 = false
    /// The callee step of the call being emitted whose overload only an
    /// instance can pick because an argument is dependent (_dependent_arg_member).
    prot var _arg_dep_step: unsafe *ChainExpr::Step = &null
    prot var _cur_ext:      unsafe *ExtensionDecl   = &null ///< non-null inside an extension member.
    /// The method _body writes went out with its `requires` as a trailing
    /// clause (Speller::member_requires): no static_asserts for it.
    prot var _req_in_head: bool = false
    /// A split constructor whose slots are live (file header), its record,
    /// and whether this is its S_pre, where there is no object and `self.x`
    /// is a slot.
    prot var _ci_fn:    unsafe *FunctionDecl = &null
    prot var _ci_owner: unsafe *Decl         = &null
    prot var _ci_pre:   bool                 = false
    /// The closure whose body is being emitted, innermost: a `return` in it
    /// returns from the lambda, with the closure's type. `_cur_fn` stays
    /// the enclosing function, which still decides what `self` is.
    prot var _closure: unsafe *ClosureExpr = &null
    /// emit_tu's pass (EmitPass); the runtime pass skips what the eval pass
    /// wrote (BodyMark::Done).
    prot var _pass: EmitPass = EmitPass::Runtime
    /// `eval for` copies the current statement is inside (Compiler/Spec/Eval.md#eval-for), and
    /// the runtime loops opened inside the innermost copy: a `break` /
    /// `continue` with none is the eval for's own (the copy's `return`).
    prot var _ef_depth: u32 = 0
    /// Nesting depth of the binding operator forms (a division, a compound
    /// assignment to a place, a postfix's old value), for temporaries no
    /// inner form shadows: saved and restored around each, as _ef_depth is.
    prot var _bind_depth: u32 = 0
    /// The expression that is a whole statement (an ExpressionStmt's, a C
    /// for's update): a binding form there leaves its trailing value out,
    /// which clang warns is unused.
    prot var _stmt_node: unsafe *Expr = &null
    /// A namespace-scope initializer is being emitted in place: no statement
    /// expression is allowed there, so a binding form is the body of a
    /// lambda called on the spot instead (no capture: nothing at namespace
    /// scope needs one).
    prot var _ns_init:  bool = false
    prot var _ef_loops: u32  = 0
    /// The type packs whose `for x in xs` bodies are open, innermost last,
    /// with each one's binding name: a pack element's witness Self
    /// (_witness_member).
    prot var _pe_gp:   cxx::std::vector<unsafe *Type>
    prot var _pe_name: cxx::std::vector<string>
    /// Eval generator iterables in the function, for unique names.
    prot var _ef_gens: usize = 0
    /// BodyMark bits by decl address (never a reserved key): the compile-time
    /// bodies already written, the eval bindings InterfaceEmitter defined as
    /// early items (EmitPlan::early, Compiler/Spec/Eval.md#value-nodes), and
    /// the ones emit_tu defines ahead of the program walk. A map, not lists
    /// scanned per decl: an eval-heavy TU asked once per body.
    priv var _marks: llvm::DenseMap<u64, u8>
    /// The namespace-scope variable whose initializer is being emitted.
    prot var _cur_global: unsafe *VariableDecl = &null
    /// The calling conventions this TU defines or calls a function with
    /// (bit cc-1 of FunctionDecl::call_conv), for the object's ABI note
    /// (_abi_note). Collected while the bodies are written, so a convention
    /// only an unused declaration names sets nothing.
    prot var _cc_bits: u32 = 0
    /// The union-stored locals (VariableDecl::dtor_mode is not Scope;
    /// Compiler/Spec/Lowering.md#union-storage-locals) whose declarations
    /// are out in the bodies being written, innermost body last: _body
    /// drops its own on the way out. Parallel: the storage (`__k_s_x`), the
    /// object as a use reads it (`__k_s_x.v`, `__k_s_x.s.v` when flagged),
    /// the sites written that end it; `_ul_row` finds the row by decl.
    prot var _ul_decl:  cxx::std::vector<unsafe *VariableDecl>
    prot var _ul_store: cxx::std::vector<string>
    prot var _ul_obj:   cxx::std::vector<string>
    prot var _ul_ends:  cxx::std::vector<usize>
    prot var _ul_row:   llvm::DenseMap<u64, u64>
    /// The value of the `return` being written when it is a union-stored
    /// local's name: spelled as a move, since C++ moves only a returned
    /// NAME on its own and the object is a member here.
    prot var _ret_move: unsafe *Expr = &null
    /// The declaration being written is a C-style `for`'s init, where one
    /// declaration is all the syntax holds (_for).
    prot var _in_for_init: bool = false
    /// The condition of the `if` being written, when it is a call: a call of
    /// the Unpredictable lang item there is spelled bare (EmitIR::_call),
    /// since clang drops the hint when anything wraps it.
    prot var _if_cond: unsafe *Expr = &null

    fn EmitIR(self, cg: unsafe *CodegenContext) {
        self._cg    = cg
        self._spell = Speller(cg)
    }

    /// # Entry

    /// Every body this TU defines: its own decls in source order, then every
    /// foreign template and `inline` body visible here.
    fn emit_tu(self, plan: unsafe *EmitPlan) {
        self._cg->require_phase(CodegenPhase::Planned)
        var unsafe *tu = self._cg->tu
        if tu == &null {
            kairo::std::ice_fail("EmitIR: no TU")
        }

        var *items = &tu->program->items

        // Every consteval body first, foreign then own: a constant
        // expression may call a consteval function only where it is already
        // DEFINED, and Kairo declarations have no order (Compiler/Spec/Eval.md#eval-fn). A
        // consteval body only names other consteval bodies and declarations,
        // so it can always go first.
        // A constexpr body (the string literal constructor, an eval class's
        // field default, Compiler/Spec/Eval.md#strings-at-compile-time / 7b) goes with them: a constant
        // expression needs it defined as much.
        var hoisted = plan->include_eval_vars()
        for var i: usize = 0; i < hoisted.size(); ++i {
            self._mark(unsafe (hoisted[i] as unsafe *Decl), BodyMark::Hoisted)
        }

        // An eval field's thunk is evaluated by the field's definition right
        // after its body, so the foreign ones wait for every other body
        // (_thunk_reads_first).
        var vis = plan->visible_bodies()
        for var i: usize = 0; i < vis.size(); ++i {
            if self._compile_time(vis[i]) && !self._done(vis[i]) && !self._eval_thunk(vis[i]) {
                self._visible_body(vis[i])
            }
        }

        // Free functions first, then records' compile-time methods: an eval
        // field's definition follows its thunk's body and is evaluated right
        // there, so what the thunk calls must already be defined, and the
        // eval bindings it reads (_thunk_reads_first).
        for var round: u32 = 0; round < 2; ++round {
            self._pass = if (round == 1) => (EmitPass::EvalRecords) else => EmitPass::EvalFree
            if round == 1 {
                for var i: usize = 0; i < vis.size(); ++i {
                    if self._compile_time(vis[i])
                        && !self._done(vis[i])
                        && self._eval_thunk(vis[i]) {
                        self._thunk_reads_first(vis[i], &hoisted)
                        self._visible_body(vis[i])
                    }
                }
            }

            for var i: usize = 0; i < items->size(); ++i {
                var item = *items->get(i)
                if item.kind == TopLevelKind::Decl {
                    if round == 1 {
                        var fields = decl_fields(item.as_decl())
                        for var k: usize = 0; k < fields.size(); ++k {
                            var unsafe *fd = fields[k]
                            if fd != &null
                                && fd->is_eval()
                                && fd->init_fold == FieldFold::Thunk
                                && isa<FunctionDecl>(fd->init_thunk) {
                                self._thunk_reads_first(
                                    cast<FunctionDecl>(fd->init_thunk),
                                    &hoisted,
                                )
                            }
                        }
                    }

                    self.emit(item.as_decl())
                }
            }
        }

        self._pass = EmitPass::Runtime
        // Then every eval binding's definition, foreign (Compiler/Spec/Eval.md#eval-bindings) and
        // own, dependencies first: each reads those bodies, and one may read
        // another declared below it or in another file. The own ones are
        // skipped where the program walk below reaches them.

        self._eval_vars(hoisted)

        for var i: usize = 0; i < items->size(); ++i {
            var item = *items->get(i)
            match item.kind {
                case TopLevelKind::Decl {
                    self.emit(item.as_decl())
                } case TopLevelKind::Stmt {
                    // File-scope `var`/`const`/`static`/`eval` parse as a
                    // DeclStmt (ASTParse::_build_symbols); the decl is the
                    // namespace-scope variable. Nothing else at file scope
                    // has a C++ form: ScriptLowering moves a script's
                    // statements into its `main`, and Sema rejects them in
                    // any other file, so reaching here means it did not run.
                    var unsafe *s  = item.as_stmt()
                    var unsafe *ds = dyn_cast<DeclStmt>(s)
                    if ds == &null || ds->decl == &null || !isa<VariableDecl>(ds->decl) {
                        self._ice(
                            s->range,
                            f"EmitIR: a top-level {to_string(s->kind)} reached codegen; ScriptLowering should have moved it into the script's 'main' (only variable declarations stay at file scope)",
                        )
                    }

                    self.emit(ds->decl)
                } default {
                    self._ice(
                        item.as_expr()->range,
                        "EmitIR: a top-level expression reached codegen; ScriptLowering should have moved it into the script's 'main'",
                    )
                }
            }
        }

        // The bodies of what the program's functions declare locally,
        // hoisted to namespace scope (Speller::is_hoisted_local); the plan
        // declared each, so order among them does not matter.
        var hl = HoistedLocals()
        hl.run(tu)
        for var i: usize = 0; i < hl.found.size(); ++i {
            self.emit(hl.found[i])
        }

        for var i: usize = 0; i < vis.size(); ++i {
            if !self._compile_time(vis[i]) {
                self._visible_body(vis[i])
            }
        }

        self._panic_sites(tu)
        self._abi_note(tu)
        self._global_allocator(tu)
    }

    /// `@set_global_allocator(A)` (TranslationUnit::global_alloc): the five
    /// symbols the builtin's Global calls, defined here as forwarders to A's
    /// static functions. Strong definitions; the runtime's are weak and
    /// forward to System (Lib/rt/global_alloc.c), so this file's win the
    /// link and a second file's are a duplicate-symbol error kld names both
    /// objects in. Signatures are the ABI rt/global_alloc.h declares, which
    /// is in every TU through the builtin's alloc.h: they must agree to the
    /// noexcept. Global scope, after everything: A is complete here.
    priv fn _global_allocator(self, tu: unsafe *TranslationUnit) {
        if tu->global_alloc == &null {
            return
        }

        var unsafe *ta = dyn_cast<TypeAliasDecl>(tu->global_alloc)
        if ta == &null || ta->aliased == &null || ta->aliased->canonical == &null {
            return
        }

        var a   = self._spell._type(ta->aliased->canonical)
        var at  = tu->global_alloc_at
        var pre = "extern \"C\" "
        var sz  = LowerTargets::cxx_size_t()
        var p   = "unsigned char * "
        // Each forwarder: the C symbol, and A's function of the same row.
        var s_alloc = LowerTargets::global_alloc_symbol(GlobalAllocFn::Alloc)
        var m_alloc = a + "::" + AllocNames::global_alloc_member(
            GlobalAllocFn::Alloc,
        )

        var s_free = LowerTargets::global_alloc_symbol(GlobalAllocFn::Free)
        var m_free = a + "::" + AllocNames::global_alloc_member(
            GlobalAllocFn::Free,
        )

        var s_rsz = LowerTargets::global_alloc_symbol(GlobalAllocFn::Resize)
        var m_rsz = a + "::" + AllocNames::global_alloc_member(
            GlobalAllocFn::Resize,
        )

        var s_real = LowerTargets::global_alloc_symbol(GlobalAllocFn::Realloc)
        var m_real = a + "::" + AllocNames::global_alloc_member(
            GlobalAllocFn::Realloc,
        )

        var s_zero = LowerTargets::global_alloc_symbol(
            GlobalAllocFn::AllocZeroed,
        )

        var m_zero = a + "::" + AllocNames::global_alloc_member(
            GlobalAllocFn::AllocZeroed,
        )

        self._cg->sink->spell(
            at,
            pre + p + s_alloc + "(" + sz + " size, " + sz + " align) noexcept { return " + m_alloc + "(size, align); }",
        )

        self._cg->sink->brk()
        self._cg->sink->spell(
            at,
            pre + "void " + s_free + "(" + p + "ptr, " + sz + " size, " + sz + " align) noexcept { " + m_free + "(ptr, size, align); }",
        )

        self._cg->sink->brk()
        self._cg->sink->spell(
            at,
            pre + "bool " + s_rsz + "(" + p + "ptr, " + sz + " old_size, " + sz + " new_size, " + sz + " align) noexcept { return " + m_rsz + "(ptr, old_size, new_size, align); }",
        )

        self._cg->sink->brk()
        self._cg->sink->spell(
            at,
            pre + p + s_real + "(" + p + "ptr, " + sz + " old_size, " + sz + " new_size, " + sz + " align) noexcept { return " + m_real + "(ptr, old_size, new_size, align); }",
        )

        self._cg->sink->brk()
        self._cg->sink->spell(
            at,
            pre + p + s_zero + "(" + sz + " size, " + sz + " align) noexcept { return " + m_zero + "(size, align); }",
        )

        self._cg->sink->brk()
    }

    /// Records `f`'s calling convention, if it has one, for the ABI note.
    prot fn _cc_mark(self, f: unsafe *FunctionDecl) {
        if f == &null {
            return
        }

        var        cc = f->call_conv
        var unsafe *c = f->canonical_decl()
        if cc == 0 && c != &null {
            cc = c->call_conv
        }

        if cc != 0 {
            self._cc_bits |= call_conv_note_bit(cc)
        }
    }

    /// The object's ABI note (c-cpp-abi.mdx): a used, internal byte record in
    /// its own section, which kld reads back from every input object
    /// (Linker::API::LinkABI). Written only when the TU defines or calls a
    /// function with a calling convention, so every other object is as it
    /// was. Its bytes: the magic `\x7f K A B I`, the format version, the
    /// convention bitset (1 preserve_most, 2 preserve_all, 4 preserve_none)
    /// and the LLVM major the code was generated by -- these conventions are
    /// not stable across LLVM releases, so kld refuses to mix majors. The
    /// major is the LLVM this compiler links: its clang IS the code
    /// generator. (Not `__clang_major__`: the C++ goes to clang as tokens,
    /// and no preprocessor expands a macro among them.)
    ///
    /// Beside it, in the same section, the global-allocator record: the
    /// magic, kind 2, and a flags byte -- 1 when this TU was compiled
    /// without __KAIRO_GLOBAL_ALLOCATOR_SET (its Global is System, inlined),
    /// 2 when it sets the global allocator (_global_allocator: the strong
    /// kairo_global_* definitions). kld refuses a link holding both bits,
    /// in one object or two: the first object's allocations would bypass
    /// the allocator the second installs. Every TU writes one, so an object
    /// that predates it is the only Kairo object without.
    priv fn _abi_note(self, tu: unsafe *TranslationUnit) {
        var        at  = self._cg->ctx->sm->get_range(tu->fid, 0, 1)
        var        sec = LowerTargets::abi_note_section()
        var unsafe *ci = self._cg->ctx->ci
        if ci != &null && ci->target.object_format_kind == ObjectFormat::MachO {
            sec = LowerTargets::abi_note_section_macho()
        }

        var flags: u32 = 0
        if ci != &null && !ci->pp.global_allocator_set {
            flags |= ABI_ALLOC_INLINES_SYSTEM
        }

        if tu->global_alloc != &null {
            flags |= ABI_ALLOC_SETS_GLOBAL
        }

        var magic = self._abi_magic_cxx()
        if flags != 0 {
            self._cg->sink->spell(
                at,
                "[[gnu::used, gnu::section(\"" + sec + "\")]] static const unsigned char " + LowerTargets::abi_alloc_note_symbol() + "[] = { " + magic + f"{ABI_NOTE_KIND_ALLOC}" + ", " + f"{flags}" + " };",
            )

            self._cg->sink->brk()
        }

        if self._cc_bits == 0 {
            return
        }

        var major: u32 = (kairo::llvm_version_major() as u32)
        self._cg->sink->spell(
            at,
            "[[gnu::used, gnu::section(\"" + sec + "\")]] static const unsigned char " + LowerTargets::abi_note_symbol() + "[] = { " + magic + f"{ABI_NOTE_KIND_CONV}" + ", " + f"{self._cc_bits}" + ", " + f"{major}" + " };",
        )

        self._cg->sink->brk()
    }

    /// LinkABI's magic as the head of a C++ initializer, each byte in
    /// lowercase hex with its separator: `0x7f, 0x4b, 0x41, 0x42, 0x49, `.
    priv fn _abi_magic_cxx(self) -> string {
        var digits = "0123456789abcdef"
        var m      = abi_note_magic()
        var out    = ""
        for var k: usize = 0; k < m.size(); ++k {
            var b = ((m[k]) as u32) & (255 as u32)
            out += "0x"
            out.push_back(digits[(b >> (4 as u32)) as usize])
            out.push_back(digits[(b & (15 as u32)) as usize])
            out += ", "
        }

        return out
    }

    /// The TU's panic site table (Compiler/Spec/Panic.md#site-ids; TranslationUnit::
    /// panic_sites): one `__kairo_panic_site {id, line, col, file}` per site
    /// in the linker-collected `__kairo_panic_sites` section, which the
    /// lookup searches by id. Internal and `used`: every TU keeps its own
    /// records, so a `.k` that kcc includes into several TUs has its sites
    /// written once per TU, as identical records -- the lookup treats equal
    /// records as one site, and only differing records with one id as the
    /// ambiguity it prints in full.
    priv fn _panic_sites(self, tu: unsafe *TranslationUnit) {
        if tu->panic_sites.size() == 0 {
            return
        }

        var        at  = self._cg->ctx->sm->get_range(tu->fid, 0, 1) // a TU with a site has a byte 0.
        var        st  = LowerTargets::panic_site_type() // InterfaceEmitter defines it.
        var        sec = LowerTargets::panic_sites_section()
        var unsafe *ci = self._cg->ctx->ci
        if ci != &null && ci->target.object_format_kind == ObjectFormat::MachO {
            sec = LowerTargets::panic_sites_section_macho()
        }

        var unsafe *sm = self._cg->ctx->sm
        for var i: usize = 0; i < tu->panic_sites.size(); ++i {
            var r   = tu->panic_sites[i]
            var lc  = sm->get_line_col(r.at)
            var lit = Speller::c_string(sm->get_filename(r.at))
            self._cg->sink->spell(
                at,
                "[[gnu::used, gnu::section(\"" + sec + "\")]] static const ::" + st + " " + LowerTargets::panic_site_record(
                    r.key,
                ) + " = { " + f"{r.id}" + "u, " + f"{lc.line}" + "u, " + f"{lc.column}" + "u, " + lit + " };",
            )
        }

        self._cg->sink->brk()
    }

    /// Whether the interface PCH this TU loads already defines `d`'s body.
    prot fn _in_pch(self, d: unsafe *Decl) -> bool {
        return self.pch_bodies != &null && self.pch_bodies->contains(d as usize as u64)
    }

    /// A body a constant expression may run: `consteval` or `constexpr`.
    prot fn _compile_time(self, f: unsafe *FunctionDecl) -> bool {
        return f->is_eval() || f->is_constexpr()
    }

    /// `f` is an eval field's initializer thunk (FieldInitLowering): a
    /// compiler-made consteval function the field's definition calls.
    priv fn _eval_thunk(self, f: unsafe *FunctionDecl) -> bool {
        return f->is_eval() && f->is_implicit
    }

    /// An eval field's thunk `f` (`eval H: usize = HDR` in a class) is
    /// called by the field's definition right after its body
    /// (EmitIR::_eval_field_def), a constant expression evaluated there: the
    /// eval bindings it reads are defined first, with every binding before
    /// them in `vars` (the plan's order puts a binding's own dependencies
    /// ahead of it). Any other compile-time body is evaluated only later.
    priv fn _thunk_reads_first(self,
                               f:    unsafe *FunctionDecl,
                               vars: *cxx::std::vector<unsafe *VariableDecl>) {
        if !self._eval_thunk(f) || vars->size() == 0 {
            return
        }

        var n = EarlyNeeds()
        n.dispatch_decl(unsafe (f as unsafe *Decl))
        var last = usize::MAX
        for var i: usize = 0; i < vars->size(); ++i {
            for var k: usize = 0; k < n.items.size(); ++k {
                if n.items[k] == unsafe ((*vars)[i] as unsafe *Decl) {
                    last = i
                }
            }
        }

        if last == usize::MAX {
            return
        }

        for var i: usize = 0; i <= last; ++i {
            self.early(unsafe ((*vars)[i] as unsafe *Decl))
        }
    }

    /// Eval bindings' `inline constexpr` definitions, in the plan's order
    /// (dependencies first), each in its namespace (Compiler/Spec/Eval.md#eval-bindings).
    priv fn _eval_vars(self, const list: cxx::std::vector<unsafe *VariableDecl>) {
        for var i: usize = 0; i < list.size(); ++i {
            if !self._marked(
                unsafe (list[i] as unsafe *Decl),
                BodyMark::EarlyVar,
            ) {
                self._global_var(list[i])
            }
        }
    }

    /// Whether `d` carries mark `m` (_marks).
    prot fn _marked(self, d: unsafe *Decl, m: BodyMark) -> bool {
        var it = self._marks.find(d as usize as u64)
        if it == self._marks.end() {
            return false
        }

        return (it->second & (m as u8)) != 0
    }

    priv fn _mark(self, d: unsafe *Decl, m: BodyMark) {
        var unsafe *slot = unsafe &self._marks[d as usize as u64]
        (*slot) = (*slot) | (m as u8)
    }

    /// Whether compile-time body `f` is already written (the eval pass, or
    /// an early item).
    prot fn _done(self, f: unsafe *FunctionDecl) -> bool {
        return self._marked(unsafe (f as unsafe *Decl), BodyMark::Done)
    }

    prot fn _mark_done(self, f: unsafe *FunctionDecl) {
        self._mark(unsafe (f as unsafe *Decl), BodyMark::Done)
    }

    /// One early item (EmitPlan::early, Compiler/Spec/Eval.md#value-nodes), defined where
    /// InterfaceEmitter's tier 1 stands: a compile-time body (in its
    /// owner's wrapper, a method out of line, an eval field's definition
    /// after its thunk), or an eval binding's `inline constexpr`
    /// definition. Recorded, so emit_tu / emit_bodies do not write it again.
    fn early(self, d: unsafe *Decl) {
        var unsafe *f = dyn_cast<FunctionDecl>(d)
        if f != &null {
            if self._done(f) {
                return
            }

            self._mark_done(f)
            self._visible_body(f)
            return
        }

        var unsafe *v = dyn_cast<VariableDecl>(d)
        if v == &null {
            return
        }

        if self._marked(d, BodyMark::EarlyVar) {
            return
        }

        self._mark(d, BodyMark::EarlyVar)
        self._global_var(v)
    }

    /// Every template and inline definition visible here (EmitPlan::
    /// visible_bodies): FOREIGN ones in a preamble, the module's own in a
    /// header. A template's definition must be visible in every TU that can
    /// instantiate it, and clang instantiates some Kairo never names; an
    /// inline body is part of the interface by declaration. The list is the
    /// plan's, the same one it walked for dependencies, so nothing emitted
    /// here goes unplanned, and each body comes once.
    fn emit_visible(self, plan: unsafe *EmitPlan) {
        self.emit_bodies(plan->visible_bodies(), plan->visible_eval_vars())
    }

    /// Bodies and eval bindings from lists the plan made (EmitPlan::
    /// include_bodies / include_eval_vars, pruned by the caller), each
    /// emitted as emit_visible emits one: the compile-time bodies, then the
    /// eval bindings that read them, then the rest (as emit_tu orders them).
    fn emit_bodies(self,
                   const list: cxx::std::vector<unsafe *FunctionDecl>,
                   vars:       cxx::std::vector<unsafe *VariableDecl>) {
        self._cg->require_phase(CodegenPhase::Planned)
        for var i: usize = 0; i < list.size(); ++i {
            if self._compile_time(list[i]) && !self._done(list[i]) && !self._eval_thunk(list[i]) {
                self._visible_body(list[i])
            }
        }

        for var i: usize = 0; i < list.size(); ++i {
            if self._compile_time(list[i]) && !self._done(list[i]) && self._eval_thunk(list[i]) {
                self._thunk_reads_first(list[i], &vars)
                self._visible_body(list[i])
            }
        }

        self._eval_vars(vars)
        for var i: usize = 0; i < list.size(); ++i {
            if !self._compile_time(list[i]) {
                self._visible_body(list[i])
            }
        }
    }

    /// ## Namespace wrapper

    /// ## Functions

    /// ## Constructors that initialize a field in place (file header)

    /// The length of `t` when it is a fixed array of known length (the one
    /// kind of field whose slot hands its value over element by element),
    /// else usize(-1). CtorInitCheck gated a generic length.
    prot fn _array_extent(self, t: unsafe *Type) -> usize {
        if t == &null || t->canonical == &null {
            return usize::MAX
        }

        var unsafe *c = canon_unqual(t->canonical)
        if c == &null || !isa<FixedArrayType>(c) {
            return usize::MAX
        }

        var unsafe *a = cast<FixedArrayType>(c)
        if a->is_incomplete || a->extent_param != &null {
            return usize::MAX
        }

        return a->size_bits
    }

    prot fn tu_is_void(self, t: unsafe *Type) -> bool {
        var unsafe *c = canon_unqual(t)
        if c == &null || !isa<BuiltinType>(c) {
            return false
        }

        var k = cast<BuiltinType>(c)->builtin
        return k == BuiltinKind::Void || k == BuiltinKind::Never
    }

    /// ## Names

    prot fn _is_self_decl(self, d: unsafe *Decl) -> bool {
        var unsafe *p = dyn_cast<ParamDecl>(d)
        return p != &null && p->is_self
    }

    /// Params, body locals, binders, generic params, and statement-scope
    /// decls: everything with no symbol-table home.
    prot fn _is_local(self, d: unsafe *Decl) -> bool {
        if isa<ParamDecl>(d) || isa<GenericParamDecl>(d) {
            return true
        }

        var unsafe *v = dyn_cast<VariableDecl>(d)
        if v != &null {
            var unsafe *dc = d->semantic_dc
            if dc == &null {
                return true
            }

            return dc->is_function()
                || dc->dc_kind == DeclContextKind::Block
                || dc->dc_kind == DeclContextKind::Lambda
        }

        return false
    }

    /// ## Chains

    prot fn _base_is_self(self, e: unsafe *Expr) -> bool {
        var unsafe *ni = dyn_cast<NamedIdentExpr>(e)
        if ni == &null {
            return false
        }

        return self._is_self_decl(ni->resolved_decl)
    }

    prot fn _type_is_pointer(self, t: unsafe *Type) -> bool {
        if t == &null {
            return false
        }

        var unsafe *c = t->canonical
        if c == &null {
            c = t
        }

        c = canon_unqual(c)
        // A C++ reference to a pointer is that pointer: `ptrs[0]->id` on a
        // `vector<*Node>` steps through `reference` (`Node*&`), and `.` there
        // is clang's "is a pointer; did you mean '->'" (CL001E).
        if isa<CXXLValueRefType>(c) {
            c = canon_unqual(cast<CXXLValueRefType>(c)->referee)
        } else if isa<CXXRValueRefType>(c) {
            c = canon_unqual(cast<CXXRValueRefType>(c)->referee)
        }

        return c != &null && c->kind == TypeKind::PointerType
    }

    /// ## Calls

    /// ## Closures

    prot fn _is_extension_member(self, d: unsafe *Decl) -> bool {
        return decl_extension_of(d) != &null
    }

    prot fn _is_type_decl(self, d: unsafe *Decl) -> bool {
        return isa<ClassDecl>(d) || isa<StructDecl>(d) || isa<UnionDecl>(d) || isa<EnumDecl>(d)
    }

    /// An untyped `e` reached codegen: I011W at its source (CodegenICE).
    prot fn _ice_untyped(self, e: unsafe *Expr, const msg: string) {
        codegen_ice(
            self._cg->ctx,
            DiagID::I011W,
            e->range,
            f"{msg} ({to_string(e->kind)})",
        )
    }

    /// ICE naming the Kairo source at `at` (CodegenICE).
    prot fn _ice(self, at: SourceRange, const msg: string) {
        codegen_ice(self._cg->ctx, at, msg)
    }

    /// The file whose tables the body being emitted indexes: its function's,
    /// which for a foreign template or inline body is not this TU's; or the
    /// namespace-scope variable's whose initializer is emitted (a foreign
    /// eval binding's, Compiler/Spec/Eval.md#eval-bindings).
    prot fn _owning_fid(self) -> u32 {
        if self._cur_fn != &null {
            return Speller::fid_of(self._cur_fn)
        }

        if self._cur_global != &null {
            return Speller::fid_of(self._cur_global)
        }

        return self._cg->tu->fid
    }

    /// ## Base initializers

    prot fn _is_ctor(self, f: unsafe *FunctionDecl) -> bool {
        if f == &null || !f->is_method() {
            return false
        }

        var unsafe *dc = f->semantic_dc
        if dc == &null || !dc->is_type_scope() {
            return false
        }

        return self._spell.leaf(f) == self._spell.leaf(
            Speller::rep(dc->dc_owner),
        )
    }

    /// ## Operators

    /// ## Integer arithmetic: the wrap forms
    ///
    /// Kairo's integer `+ - *`, unary `-` and `~`, `++`/`--`, shifts and the
    /// matching compound assignments compute modulo 2^width of the node's
    /// type, and no C++ promotion is observable. Each is spelled inline in an
    /// unsigned carrier never narrower than `unsigned int` (Speller::
    /// wrap_carrier), which clang compiles to the instructions of the plain
    /// operator wherever that one has no UB. Division and remainder check a
    /// zero divisor (a crash) and `MIN / -1`. A form that needs an operand
    /// twice, or must evaluate a place once, binds it in a statement
    /// expression. Imported C++ keeps C++ semantics; floats, pointers, enums
    /// and records are untouched. `no_wrap` (proven not to overflow) prints
    /// C++'s operator.

    /// `e`, parens aside.
    prot fn _strip(self, e: unsafe *Expr) -> unsafe *Expr {
        var unsafe *x = e
        while x != &null && isa<ParenExpr>(x) {
            x = cast<ParenExpr>(x)->inner
        }

        return x
    }

    /// ## dependent operands (a duck `<T: type>` body)
    ///
    /// Whether T is an integer is decided at instantiation: the operands are
    /// bound, and a lambda chooses with `if constexpr` between the wrap form
    /// on T's carrier (`__make_unsigned(T)` promoted to at least `unsigned`)
    /// and T's own operator. Clang folds the choice away; the lambda is local
    /// and unnamed, so no helper symbol exists.

    /// ## Initializers
}
