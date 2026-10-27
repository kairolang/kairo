/// --- The Kairo Project -------------------- Codegen/Emit/CXXSpell.k ----- ///
///
///   \brief The ONE C++ speller: canonical type -> text, decl -> qualified
///          name, decl -> namespace path. Both emitters call it; there is
///          no second copy anywhere, because two spellers drift and the
///          drift is a silent link error.
///
///   \par Everything is derived, nothing is stored per use
///     A decl's namespace is its semantic DeclContext chain -- `module X`
///     names on the way up, then the owning TU's module_base at the root
///     (IMPORTS.md invariant 9). An alias never appears (invariant 10).
///
///   \par Input is CANONICAL
///     type() reads `t->canonical` and refuses a null one. A syntax node
///     with no canonical reaching codegen is a sema gate failure.
///
///   Import law: CodegenContext only.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

import Codegen::CodegenContext::*;
import Codegen::CodegenICE::*;
import AST::Context::ASTContext::*;
import AST::Context::DeclContext::*;
import AST::Context::TranslationUnit::*;
import AST::Context::InstantiationRegistry::*;
import AST::ASTSupport::*;
import AST::DeclFacts::*;
import AST::Node::Base::*;
import AST::Node::Types::*;
import AST::Node::CanonicalNodes::*;
import AST::Node::Declarations::*;
import AST::Node::Expressions::*;
import AST::Node::PrimaryExpressions::*;
import AST::Node::Casting::*;
import AST::Kind::DeclKind::*;
import AST::Kind::TypeKind::*;
import AST::ParamMode::*;
import AST::LangItems::*;
import AST::CxxReservedWords::*;
import Token::TokenKind::*;
import Location::SourceManager::*;
import Location::SourceRange::*;

/// VisibilityKind enumerator values (AST/Mixin/Annotation.k): None,
/// Private, Protected, Public, Internal. Read through vis_of() and nowhere
/// else. InheritEdge's comment claims 0 none / pub / prot / priv; that
/// order is wrong, and trusting it inverted the header's pub filter.
eval fn VIS_NONE() -> u8 { return 0; }
eval fn VIS_PRIV() -> u8 { return 1; }
eval fn VIS_PROT() -> u8 { return 2; }
eval fn VIS_PUB()  -> u8 { return 3; }
eval fn VIS_INTERNAL() -> u8 { return 4; }

class CXXSpell {
    priv var _cg: obs::<CodegenContext>;

    /// While EmitWitness spells a witness member: the interface whose bare
    /// `Self` (an argument-less record of it) is spelled \c self_spelling --
    /// `__kairo_Self` in the primary, the conformer in a specialization.
    /// Null everywhere else, where an interface type is still an ICE.
    pub var self_iface:    *Decl  = &null;
    pub var self_spelling: string = "";
    /// While InterfaceEmitter writes a pack-expanded variant's payload struct
    /// (a template over one element): the enum's pack parameter, which
    /// spells there as that element, LowerTargets::adt_pack_elem(). Null
    /// everywhere else.
    pub var pack_alias:    *GenericParamDecl = &null;
    /// While InterfaceEmitter writes the payload structs of an ADT whose
    /// layout holds a `void` argument as an empty struct (EnumDecl::
    /// adt_void_unit, the Panic lang item): that enum, whose own non-pack
    /// parameters spell as `::__kairo_nv<T>` there. Null everywhere else.
    pub var void_unit_owner: *Decl = &null;

    fn CXXSpell(self) { self._cg = &null; }
    fn CXXSpell(self, cg: *CodegenContext) { self._cg = cg; }

    /// ICE naming the Kairo source at \p at (CodegenICE). A canonical type
    /// carries no range; pass the written node or the owning decl's.
    priv fn _ice(self, at: SourceRange, msg: string) {
        codegen_ice(self._cg->ctx, at, msg);
    }

    // --- Decl facts ------------------------------------------------------------

    /// THE visibility read. One line to fix if the mixin spells it otherwise.
    static fn vis_of(d: *Decl) -> u8 {
        if d == &null { return VIS_NONE(); }
        return static_cast::<u8>(d->visibility);
    }

    /// The entity's representative (redecl canonical).
    static fn rep(d: *Decl) -> *Decl {
        if d == &null { return &null; }
        switch d->kind {
            case DeclKind::ClassDecl     { return static_cast::<*Decl>(cast::<ClassDecl>(d)->canonical_decl());     }
            case DeclKind::StructDecl    { return static_cast::<*Decl>(cast::<StructDecl>(d)->canonical_decl());    }
            case DeclKind::UnionDecl     { return static_cast::<*Decl>(cast::<UnionDecl>(d)->canonical_decl());     }
            case DeclKind::EnumDecl      { return static_cast::<*Decl>(cast::<EnumDecl>(d)->canonical_decl());      }
            case DeclKind::InterfaceDecl { return static_cast::<*Decl>(cast::<InterfaceDecl>(d)->canonical_decl()); }
            case DeclKind::FunctionDecl  { return static_cast::<*Decl>(cast::<FunctionDecl>(d)->canonical_decl());  }
            case DeclKind::ModuleDecl    { return static_cast::<*Decl>(cast::<ModuleDecl>(d)->canonical_decl());    }
            default { return d; }
        }
        return d;
    }

    /// The DeclContext a scope-owning decl IS, or null.
    static fn dc_of(d: *Decl) -> *DeclContext {
        if d == &null { return &null; }
        switch d->kind {
            case DeclKind::ClassDecl     { return static_cast::<*DeclContext>(cast::<ClassDecl>(d));     }
            case DeclKind::StructDecl    { return static_cast::<*DeclContext>(cast::<StructDecl>(d));    }
            case DeclKind::UnionDecl     { return static_cast::<*DeclContext>(cast::<UnionDecl>(d));     }
            case DeclKind::EnumDecl      { return static_cast::<*DeclContext>(cast::<EnumDecl>(d));      }
            case DeclKind::InterfaceDecl { return static_cast::<*DeclContext>(cast::<InterfaceDecl>(d)); }
            case DeclKind::FunctionDecl  { return static_cast::<*DeclContext>(cast::<FunctionDecl>(d));  }
            case DeclKind::ModuleDecl    { return static_cast::<*DeclContext>(cast::<ModuleDecl>(d));    }
            case DeclKind::ExtensionDecl { return static_cast::<*DeclContext>(cast::<ExtensionDecl>(d)); }
            default { return &null; }
        }
        return &null;
    }

    /// The TU a DeclContext chain bottoms out in.
    static fn tu_of_dc(dc: *DeclContext) -> *TranslationUnit {
        var c = dc;
        while c != &null {
            if c->dc_kind == DeclContextKind::TranslationUnit {
                return static_cast::<*TranslationUnit>(c);
            }
            c = c->dc_parent;
        }
        return &null;
    }

    static fn tu_of(d: *Decl) -> *TranslationUnit {
        if d == &null { return &null; }
        var dc = reinterpret_cast::<*DeclContext>(d->semantic_dc);
        if dc == &null { dc = reinterpret_cast::<*DeclContext>(d->lexical_dc); }
        if dc == &null {
            // A scope owner with no parent link (an ExtensionDecl has no
            // semantic_dc): use its own chain, or fid_of answers u32(-1)
            // and friend_scopes_of finds no same-file scope.
            var own = CXXSpell::dc_of(d);
            if own != &null { dc = own->dc_parent; }
        }
        return CXXSpell::tu_of_dc(dc);
    }

    static fn fid_of(d: *Decl) -> u32 {
        var tu = CXXSpell::tu_of(d);
        if tu == &null { return u32(-1); }
        return tu->fid;
    }

    /// Where a declaration's C++ tokens are anchored: its name token, or for
    /// an operator (whose `name` is a default Token) the span of its operator
    /// tokens, `[` through `]` for `op []`. op_token always has an element.
    static fn at(d: *Decl) -> SourceRange {
        var f = dyn_cast::<FunctionDecl>(d);
        if (f != &null) && f->is_operator {
            var r = f->op_token[0].range;
            for var j: usize = 1; j < f->op_token.size(); ++j { r = r | f->op_token[j].range; }
            return r;
        }
        var t = decl_name_tok(d);
        if t.range.is_valid() { return t.range; }
        return d->range;
    }

    /// A decl's name imm indexes ITS OWN TU's table (hard invariant #2).
    fn imm_name(self, imm: u32, fid: u32) -> string {
        if imm == u32(-1) { return "<?>"; }
        var tcm = self._cg->ctx->tcm;
        if tcm == &null { return "<?>"; }
        var tbl = tcm->get_imm_table_for_fid(fid);
        if tbl == &null { return "<?>"; }
        return tbl->get_ident(imm);
    }

    fn leaf(self, d: *Decl) -> string {
        var f = dyn_cast::<FunctionDecl>(d);
        if (f != &null) && f->is_operator { return self.operator_name(f); }
        var t = decl_name_tok(d);
        return self.imm_name(t.imm, CXXSpell::fid_of(d));
    }

    /// `operator+`, `operator[]`, `operator<=>`; `op as` -> `operator T`;
    /// `op delete` -> `~Owner`; operators C++ cannot spell -> LowerTargets.
    /// l/r on ++/-- is fixity, not part of the name (see op_is_postfix).
    fn operator_name(self, f: *FunctionDecl) -> string {
        var sym = self._op_symbol(f);
        if sym == "delete" { return "~" + self.leaf(self.operator_owner(f)); }
        if sym == "as" {
            if (f->return_type == &null) { self._ice(f->range, "CXXSpell: `op as` with no target type"); }
            return "operator " + self._type(f->return_type);
        }
        var named = CXXSpell::named_operator(sym, f);
        if named.size() > 0 { return named; }
        // An extension operator is a STATIC MEMBER of its scope, and a static
        // member cannot be an `operator+`: it gets a mnemonic, and
        // InterfaceEmitter writes the `operator+` forwarder beside the scope.
        // The member-only set never gets here from an extension;
        // OperatorSignatureCheck rejects it.
        if decl_extension_of(static_cast::<*Decl>(f)) != &null {
            var key = sym;
            if (sym == "++") || (sym == "--") { key = (("r") if (CXXSpell::op_is_postfix(f)) else ("l")) + sym; }
            var m = LowerTargets::ext_op(key);
            if (m.size() == 0) { self._ice(f->range, f"CXXSpell: extension 'op {sym}' has no C++ non-member form; OperatorSignatureCheck should reject it"); }
            return m;
        }
        return "operator" + sym;
    }

    /// A witness member's name for requirement \p f: its leaf, or for an
    /// operator the name an extension member of the same operator has --
    /// a witness member is static, so it cannot be an `operator==` either
    /// (CODEGEN.md §7b.3).
    fn witness_member_name(self, f: *FunctionDecl) -> string {
        if !f->is_operator { return self.leaf(static_cast::<*Decl>(f)); }
        var sym = self._op_symbol(f);
        var named = CXXSpell::named_operator(sym, f);
        if named.size() > 0 { return named; }
        if sym == "[]" { return LowerTargets::witness_subscript(); }
        var key = sym;
        if (sym == "++") || (sym == "--") { key = (("r") if (CXXSpell::op_is_postfix(f)) else ("l")) + sym; }
        var m = LowerTargets::ext_op(key);
        if (m.size() == 0) { self._ice(f->range, f"CXXSpell: requirement 'op {sym}' has no static-member name; OperatorSignatureCheck should reject it"); }
        return m;
    }

    /// The namespace-scope `operator<sym>` an extension operator is forwarded
    /// from, or "" when it has none: the operators named by LowerTargets
    /// (`in`, `^^`, ...) are not C++ operators, and are only static members.
    fn ext_forwarder_name(self, f: *FunctionDecl) -> string {
        var sym = self._op_symbol(f);
        if CXXSpell::named_operator(sym, f).size() > 0 { return ""; }
        return "operator" + sym;
    }

    /// The operator's symbol as C++ spells it: word operators mapped, and
    /// `l`/`r` dropped from `++`/`--` (fixity is op_is_postfix's).
    priv fn _op_symbol(self, f: *FunctionDecl) -> string {
        var ctx = CXXSpell::tu_of(static_cast::<*Decl>(f))->ctx;
        var marked = (f->op_token.size() == 2) && (f->op_token[0].kind == TokenKind::LitIdentifier)
                  && ((f->op_token[1].kind == TokenKind::OpPlusPlus) || (f->op_token[1].kind == TokenKind::OpMinusMinus));
        if marked { return ("++") if (f->op_token[1].kind == TokenKind::OpPlusPlus) else ("--"); }
        var sym = "";
        for var i: usize = 0; i < f->op_token.size(); ++i { sym += self._op_sym(f->op_token[i], ctx); }
        return sym;
    }

    static fn named_operator(sym: string, f: *FunctionDecl) -> string {
        if sym == "in"    { return (LowerTargets::op_contains()) if (f->params.size() > 1) else (LowerTargets::op_iter()); }
        if sym == "^^"    { return LowerTargets::op_pow(); }
        if sym == "await"  { return LowerTargets::op_await(); }
        if sym == "spawn"  { return LowerTargets::op_spawn(); }
        if sym == "thread" { return LowerTargets::op_thread(); }
        if sym == "panic"  { return LowerTargets::op_panic(); }
        return "";
    }

    /// `op r++` / `op r--`: the postfix form, which C++ declares with an
    /// `int` dummy parameter. By kind, as AST/OperatorFacts.k decides it.
    static fn op_is_postfix(f: *FunctionDecl) -> bool {
        if (!f->is_operator) || (f->op_token.size() != 2) { return false; }
        if f->op_token[0].kind != TokenKind::LitIdentifier { return false; }
        var k = f->op_token[1].kind;
        if (k != TokenKind::OpPlusPlus) && (k != TokenKind::OpMinusMinus) { return false; }
        var ctx = CXXSpell::tu_of(static_cast::<*Decl>(f))->ctx;
        var s = ctx->get_spelling(f->op_token[0]);
        return (s.size() > 0) && (s[0] == 'r');
    }

    /// `[]` returning a safe `*T` / `*const T`: a place.
    /// Codegen's copy of OperatorFacts::is_place, return-type test included,
    /// on this side of the import boundary. Any other return is a value
    /// operator and is spelled as declared. `[]` is two tokens.
    static fn is_place_operator(f: *FunctionDecl) -> bool {
        if (f == &null) || (!f->is_operator) || (!f->is_method()) { return false; }
        if f->op_token.size() != 2 { return false; }
        if (f->op_token[0].kind != TokenKind::OpLSquare) || (f->op_token[1].kind != TokenKind::OpRSquare) { return false; }
        if (f->return_type == &null) || (f->return_type->canonical == &null) { return false; }
        var c = canon_unqual(f->return_type->canonical);
        return (c != &null) && isa::<PointerType>(c) && (!cast::<PointerType>(c)->is_unsafe);
    }

    /// The C++ return type of \p f: a place operator's `*T` / `*const T`
    /// becomes `T&` / `const T&`, so C++ code can write `v[i] = x` on a Kairo
    /// type and an imported `T&` and a Kairo place are one ABI. Everything
    /// else, a value `op []` included, is the declared type. The pointee of `*const T` is the `const T`
    /// canonical, so _type already spells the const and `&` goes on the end.
    fn return_spelling(self, f: *FunctionDecl, subst: *InstanceEntry, scope: *Decl = &null) -> string {
        // A panicking function returns its Panic result (PANIC.md §4.1);
        // return_type stays the value type an importer's typing reads.
        if f->panic_result != &null { return self._type(f->panic_result, subst, scope); }
        if (f->return_type == &null) || (f->return_type->canonical == &null) { return self._type(f->return_type, subst, scope); }
        // An eval generator runs at compile time, where nothing suspends: it
        // returns the buffer its `yield`s push into (EVAL.md §5).
        if f->is_eval() && f->is_generator {
            var gr = dyn_cast::<RecordType>(canon_unqual(f->return_type->canonical));
            if (gr != &null) && (gr->args.size() > 0) {
                return "::" + LowerTargets::eval_buf() + "<" + self._type(gr->args[0], subst, scope) + ">";
            }
        }
        if !CXXSpell::is_place_operator(f) { return self._type(f->return_type, subst, scope); }
        var c = canon_unqual(f->return_type->canonical);
        if ((c == &null) || (!isa::<PointerType>(c))) { self._ice(f->range, "CXXSpell: is_place_operator accepted a non-pointer result"); }
        return self._type(cast::<PointerType>(c)->pointee, subst, scope) + "&";
    }

    /// The type an operator belongs to: its class, or its extension's target.
    fn operator_owner(self, f: *FunctionDecl) -> *Decl {
        var lex = reinterpret_cast::<*DeclContext>(f->lexical_dc);
        if (lex != &null) && (lex->dc_kind == DeclContextKind::Extension) {
            var x = cast::<ExtensionDecl>(lex->dc_owner);
            var c = x->target->canonical;
            if ((c == &null) || (c->kind != TypeKind::RecordType)) { self._ice(f->range, "CXXSpell: extension operator on a non-record target"); }
            return CXXSpell::rep(cast::<RecordType>(c)->decl);
        }
        var dc = reinterpret_cast::<*DeclContext>(f->semantic_dc);
        if ((dc == &null) || (!dc->is_type_scope())) { self._ice(f->range, "CXXSpell: operator with no owning type"); }
        return CXXSpell::rep(dc->dc_owner);
    }

    priv fn _op_sym(self, t: Token, ctx: *ASTContext) -> string {
        switch t.kind {
            case TokenKind::KwAnd    { return "&&"; }
            case TokenKind::KwOr     { return "||"; }
            case TokenKind::KwNot    { return "!";  }
            case TokenKind::KwXor    { return "^";  }
            case TokenKind::KwBitand { return "&";  }
            case TokenKind::KwBitor  { return "|";  }
            case TokenKind::KwCompl  { return "~";  }
            case TokenKind::KwNotEq  { return "!="; }
            case TokenKind::KwAndEq  { return "&="; }
            case TokenKind::KwOrEq   { return "|="; }
            case TokenKind::KwXorEq  { return "^="; }
            default { return ctx->get_spelling(t); }
        }
    }

    /// The module path of a TU as strings: root name + directories + file.
    fn module_segments(self, tu: *TranslationUnit) -> vec::<string> {
        var out = vec::<string>();
        if (tu == &null) || (tu->ctx == &null) { return out; }
        ICE_IF(self._cg->psym == &null, "CXXSpell: no PreprocessorSymbolTable on the CodegenContext");
        // Resolve the SymbolID directly: module_base segments are
        // synthesized and carry no token, so as_string() falls back to a
        // debug rendering that is not a C++ identifier.
        var mb = &(tu->ctx->module_base);
        for var i: usize = 0; i < mb->segments.size(); ++i {
            var p = self._cg->psym->resolve(mb->segments[i].name);
            ICE_IF(p == &null, "CXXSpell: module_base segment is not in the PP symbol table");
            // A segment is a FILE or directory name, not a Kairo identifier:
            // every input is a module now (decision C), and `operator.k` or
            // `01_basic.k` in the cwd is module `operator` / `01_basic`.
            out.push_back(CXXSpell::cxx_segment(*p));
        }
        return out;
    }

    /// \p tu has no module path: a file outside every search dir (or one
    /// whose path a named library owns, ImportResolver::input_module_path),
    /// the driver's virtual library entry, or a tool's bare parse. Not
    /// "a command-line input": since decision C an input takes the module
    /// path an import gives it, and only these keep the pathless rules
    /// below (stem namespace, priv decls in the unnamed namespace, no header).
    static fn is_entry_tu(tu: *TranslationUnit) -> bool {
        if (tu == &null) || (tu->ctx == &null) { return true; }
        return tu->ctx->module_base.segments.size() == 0;
    }

    /// \p d is the program's `main`: a free function named `main` at file
    /// scope, in ANY TU. Emitted as the global `int main`, never in a
    /// namespace and never in a header. It was "the entry TU's main" while
    /// inputs were entries; now that an input is a module (decision C) a
    /// `main` is the program's wherever its file sits. One in a `module foo
    /// { }` block is `foo::main`, an ordinary function.
    fn is_main(self, d: *Decl) -> bool {
        if (d == &null) || (!isa::<FunctionDecl>(d)) { return false; }
        if cast::<FunctionDecl>(d)->is_method() { return false; }
        var dc = reinterpret_cast::<*DeclContext>(d->semantic_dc);
        if (dc == &null) || (!dc->is_translation_unit()) { return false; }
        return self.leaf(d) == "main";
    }

    /// \p s as one C++ identifier: anything else becomes `_`, a leading
    /// digit gets a `_` before it, and a C++ keyword one after it
    /// (`operator` -> `operator_`; a trailing `_` cannot collide with another
    /// keyword). For names that come from FILES -- module path segments and
    /// a pathless TU's stem -- which reach the ABI only through here
    /// (invariant 9a).
    static fn cxx_segment(s: string) -> string {
        var out = "";
        for var i: usize = 0; i < s.size(); ++i {
            var c = s[i];
            var ok = ((c >= 'a') && (c <= 'z')) || ((c >= 'A') && (c <= 'Z'))
                  || ((c >= '0') && (c <= '9')) || (c == '_');
            if ok { out += c; } else { out += "_"; }
        }
        if out.size() == 0 { return "_"; }
        if (out[0] >= '0') && (out[0] <= '9') { return "_" + out; }
        if is_cxx_keyword(out) { return out + "_"; }
        return out;
    }

    /// A pathless TU's namespace: its FILE STEM, sanitized to a C++
    /// identifier. Before this its decls landed in one unnamed namespace and
    /// two such TUs in a build could not both define `helper`. The stem is a
    /// name the source already has.
    static fn entry_stem(tu: *TranslationUnit) -> string {
        if (tu == &null) || (tu->ctx == &null) || (tu->ctx->sm == &null) { return "_"; }
        var path = tu->ctx->sm->get_filename(tu->fid);
        // basename, then drop the extension.
        var start: usize = 0;
        for var i: usize = 0; i < path.size(); ++i {
            if (path[i] == '/') || (path[i] == '\\') { start = i + 1; }
        }
        var end = path.size();
        for var i: usize = start; i < path.size(); ++i {
            if path[i] == '.' { end = i; break; }
        }
        return CXXSpell::cxx_segment(string(path.raw() + start, end - start));
    }

    /// A decl with no linkage outside its own file: `priv` or `internal` in
    /// the entry TU. It goes in an unnamed namespace NESTED in the file's,
    /// so `::<stem>::helper` still names it -- C++'s implicit using-directive
    /// reaches into the unnamed one -- and qual_name is unchanged.
    ///
    /// Not when an inline or template body of the file names it
    /// (TranslationUnit::cxx_escaping): that body is compiled in every C++
    /// TU that includes the file, and calls it by external linkage.
    static fn is_anon(d: *Decl) -> bool {
        if d == &null { return false; }
        var tu = CXXSpell::tu_of(d);
        if !CXXSpell::is_entry_tu(tu) { return false; }
        var v = CXXSpell::vis_of(d);
        if (v != VIS_PRIV()) && (v != VIS_INTERNAL()) { return false; }
        if tu != &null {
            var r = CXXSpell::rep(d);
            for var i: usize = 0; i < tu->cxx_escaping.size(); ++i {
                if (tu->cxx_escaping[i] == d) || (tu->cxx_escaping[i] == r) { return false; }
            }
        }
        return true;
    }

    /// \p d is declared inside a function body: its semantic scope, or one
    /// enclosing it, is a function, block or lambda (FinallyLowering's guard
    /// record, its members and its local). Such a decl has no namespace: it
    /// is named by leaf, emitted inside the body, and never planned.
    static fn in_function_scope(d: *Decl) -> bool {
        if d == &null { return false; }
        var dc = reinterpret_cast::<*DeclContext>(d->semantic_dc);
        while dc != &null {
            if dc->is_function() || (dc->dc_kind == DeclContextKind::Block) || (dc->dc_kind == DeclContextKind::Lambda) { return true; }
            if dc->is_translation_unit() || (dc->dc_kind == DeclContextKind::Module) || (dc->dc_kind == DeclContextKind::Extension) { return false; }
            dc = dc->dc_parent;
        }
        return false;
    }

    /// The scope a decl's NAMESPACE is read from: for an extension member
    /// the extension's parent (its scope struct lives in the enclosing
    /// module; owner_types supplies the struct), otherwise the decl's
    /// semantic scope.
    priv fn _home_dc(self, d: *Decl) -> *DeclContext {
        var lex = reinterpret_cast::<*DeclContext>(d->lexical_dc);
        if (lex != &null) && (lex->dc_kind == DeclContextKind::Extension) { return lex->dc_parent; }
        return reinterpret_cast::<*DeclContext>(d->semantic_dc);
    }

    /// Namespace segments (modules only) enclosing \p d, outermost first.
    fn ns_segments(self, d: *Decl) -> vec::<string> {
        return self._ns_from(self._home_dc(d));
    }

    /// The namespace N of \p x's scope struct: the scope its members are
    /// qualified from (_home_dc), read off the extension itself, so a scope
    /// has a namespace even before a member is picked.
    fn scope_ns(self, x: *ExtensionDecl) -> vec::<string> {
        var dc = CXXSpell::dc_of(static_cast::<*Decl>(x));
        return self._ns_from((dc->dc_parent) if (dc != &null) else (&null));
    }

    priv fn _ns_from(self, home: *DeclContext) -> vec::<string> {
        var mods = vec::<string>();
        var dc = home;
        while dc != &null {
            if dc->dc_kind == DeclContextKind::TranslationUnit { break; }
            if dc->dc_kind == DeclContextKind::Module {
                var m = cast::<ModuleDecl>(dc->dc_owner);
                if (m != &null) && (!m->is_anonymous) {
                    mods.push_back(self.imm_name(m->name.imm, CXXSpell::fid_of(static_cast::<*Decl>(m))));
                }
            }
            dc = dc->dc_parent;
        }
        var tu  = CXXSpell::tu_of_dc(home);
        var out = self.module_segments(tu);
        // An entry TU declares no module, so module_segments gives nothing;
        // its file stem is the namespace instead.
        if out.size() == 0 { out.push_back(CXXSpell::entry_stem(tu)); }
        for var i: usize = 0; i < mods.size(); ++i { out.push_back(mods[mods.size() - 1 - i]); }
        return out;
    }

    /// `__kairo_ext_<X>`: the struct whose static members are \p x's (and
    /// every other extend of X in the same namespace N). X is the target's
    /// leaf when the target is declared in N itself, nested owners joined
    /// with `__` (`__kairo_ext_Outer__Inner`); otherwise its FULL path joined
    /// with `__` (`__kairo_ext_a__Point`), because an `impl` extend in an
    /// interface's file can target two modules' `Point`s, and one struct per
    /// leaf would hold both or be defined twice. A generic record is named
    /// by its primary, a builtin by its Kairo spelling (`__kairo_ext_i32`).
    /// Deterministic, and a function of the source tree alone (invariant 9a).
    fn ext_scope_name(self, x: *ExtensionDecl) -> string {
        ICE_IF((x == &null) || (x->target == &null) || (x->target->canonical == &null),
            "CXXSpell: extension with an unresolved target reached codegen");
        var c = canon_unqual(x->target->canonical);
        var s = LowerTargets::ext_scope_prefix();
        if isa::<BuiltinType>(c) { return s + builtin_info(cast::<BuiltinType>(c)->builtin)->spelling; }
        if (!isa::<RecordType>(c)) { self._ice(x->range, "CXXSpell: extension of a non-record, non-builtin target; no scope naming rule for it yet"); }
        var prim = CXXSpell::rep(decl_pattern(CXXSpell::rep(cast::<RecordType>(c)->decl)));
        if decl_is_imported(prim) { return s + CXXSpell::_path_ident(decl_cxx_spelling(prim)); }
        var tns = self.ns_segments(prim);
        var sns = self.scope_ns(x);
        var same = tns.size() == sns.size();
        for var i: usize = 0; same && (i < tns.size()); ++i { if tns[i] != sns[i] { same = false; } }
        if !same {
            for var i: usize = 0; i < tns.size(); ++i { s += tns[i]; s += "__"; }
        }
        var ow = self.owner_types(prim);
        for var i: usize = 0; i < ow.size(); ++i { s += ow[i]; s += "__"; }
        return s + self.leaf(prim);
    }

    /// `::ns::Point` as `ns__Point`: `::` becomes `__`, the leading one is
    /// dropped, and anything else that is not an identifier byte is `_`.
    static fn _path_ident(sp: string) -> string {
        var out = "";
        var i: usize = 0;
        if (sp.size() >= 2) && (sp[0] == ':') && (sp[1] == ':') { i = 2; }
        while i < sp.size() {
            var ch = sp[i];
            if (ch == ':') && ((i + 1) < sp.size()) && (sp[i + 1] == ':') { out += "__"; i += 2; continue; }
            var ok = ((ch >= 'a') && (ch <= 'z')) || ((ch >= 'A') && (ch <= 'Z'))
                  || ((ch >= '0') && (ch <= '9')) || (ch == '_');
            if ok { out += ch; } else { out += "_"; }
            i += 1;
        }
        return out;
    }

    /// Enclosing TYPE names for a nested decl, outermost first. An extension
    /// member's one owner is its scope struct.
    fn owner_types(self, d: *Decl) -> vec::<string> {
        var x = decl_extension_of(d);
        if x != &null {
            var one = vec::<string>();
            one.push_back(self.ext_scope_name(x));
            return one;
        }
        var rev = vec::<string>();
        var dc = self._home_dc(d);
        while (dc != &null) && dc->is_type_scope() {
            if dc->dc_kind != DeclContextKind::Extension {
                rev.push_back(self.leaf(CXXSpell::rep(dc->dc_owner)));
            }
            dc = dc->dc_parent;
        }
        var out = vec::<string>();
        for var i: usize = 0; i < rev.size(); ++i { out.push_back(rev[rev.size() - 1 - i]); }
        return out;
    }

    /// `::ns::Outer::Inner`. An entry-TU decl's segment is its file stem, so
    /// `::stem::Name` is the same name whether the decl is `pub` or `priv`:
    /// C++'s implicit using-directive reaches into the nested unnamed
    /// namespace `priv` puts it in, and qual_name never has to know.
    fn qual_name(self, d: *Decl) -> string {
        if CXXSpell::in_function_scope(d) { return self.leaf(d); }
        var r = CXXSpell::rep(d);
        if decl_is_imported(r) { return decl_cxx_spelling(r); }
        var s = "";
        var ns = self.ns_segments(r);
        for var i: usize = 0; i < ns.size(); ++i { s += "::"; s += ns[i]; }
        var ow = self.owner_types(r);
        for var i: usize = 0; i < ow.size(); ++i { s += "::"; s += ow[i]; }
        s += "::";
        s += self.leaf(r);
        return s;
    }

    /// `ns::a::b {` as `namespace a::b`, or "" for the entry TU.
    fn ns_join(self, segs: ref!(vec::<string>)) -> string {
        var s = "";
        for var i: usize = 0; i < segs.size(); ++i {
            if i > 0 { s += "::"; }
            s += segs[i];
        }
        return s;
    }

    /// `geo/vec.hh` for the TU's module path.
    fn header_path(self, tu: *TranslationUnit) -> string {
        var segs = self.module_segments(tu);
        var s = "";
        for var i: usize = 0; i < segs.size(); ++i {
            if i > 0 { s += "/"; }
            s += segs[i];
        }
        s += ".hh";
        return s;
    }

    /// `extern "C" ` for a Kairo-authored `ffi "c"` free function, else "".
    /// It leads the declaration AND the definition: the symbol must be the
    /// bare name (a linker script's `Reset_Handler`, a C caller's), never
    /// the namespace-mangled one. Either redecl may carry the prefix, so the
    /// chain's canonical is asked too.
    static fn c_linkage(f: *FunctionDecl) -> string {
        if f == &null { return ""; }
        var c = f->canonical_decl();
        if f->is_ffi_c() || ((c != &null) && c->is_ffi_c()) { return "extern \x22" + "C\x22 "; }   // split: Stage 0 reads `\x22C` as one escape.
        return "";
    }

    /// `[thread_local] T const name` for a namespace-scope variable: the one
    /// spelling the interface's `extern` declaration and EmitIR's definition
    /// both use, because C++ rejects a redeclaration whose type differs.
    /// Never `static` -- at namespace scope that is internal linkage, and
    /// every object there already has static storage duration. The binding's
    /// `const` goes in the declarator so it qualifies the variable itself:
    /// `int *const p`, not `const int *p`. `eval` is `const` here too; the
    /// definition adds `constexpr` (`extern constexpr` is ill-formed).
    fn global_var(self, v: *VariableDecl) -> string {
        var nm = self.leaf(static_cast::<*Decl>(v));
        var c = (v->type_->canonical) if (v->type_ != &null) else (&null);
        var already = (c != &null) && (c->kind == TypeKind::QualifiedType)
                   && ((cast::<QualifiedType>(c)->quals & QUAL_CONST()) != 0);
        if (v->is_const() || v->is_eval()) && (!already) { nm = "const " + nm; }
        var s = ("thread_local ") if (v->is_thread) else ("");
        return s + self.decl(v->type_, nm);
    }

    // --- Types -------------------------------------------------------------------

    /// C++ spelling of a canonical type. \p subst substitutes the primary's
    /// generic parameters with an instance's args (tier 3). Declarator
    /// shapes (arrays, function pointers) need a name to wrap; use decl().
    ///
    /// \p scope is the record whose class body the text is written in, or
    /// null. Inside it, its own nested types are named by leaf: the
    /// qualified form of a type nested in a class template needs the
    /// template's arguments, which a nested decl's canonical does not carry.
    /// It is the decl being emitted, never ambient state, so the text stays a
    /// function of that decl (InterfaceEmitter's ODR argument).
    fn _type(self, t: *Type, subst: *InstanceEntry = &null, scope: *Decl = &null) -> string {
        return self.decl(t, "", subst, scope);
    }

    /// `type name` with the declarator folded in: `int x`, `int (*f)(int)`.
    /// Empty \p name gives the abstract form. \p scope as for _type.
    fn decl(self, t_in: *Type, name: string, subst: *InstanceEntry = &null, scope: *Decl = &null) -> string {
        if t_in == &null { return self._join("void", name); }
        var t = t_in->canonical;
        if (t == &null) { self._ice(t_in->range, "CXXSpell: type with no canonical reached codegen (sema gate failure)"); }

        switch t->kind {
            case TypeKind::QualifiedType {
                var q = cast::<QualifiedType>(t);
                var pfx = "";
                if (q->quals & QUAL_CONST())    != 0 { pfx += "const "; }
                if (q->quals & QUAL_VOLATILE()) != 0 { pfx += "volatile "; }
                return pfx + self.decl(q->inner, name, subst, scope);
            }
            case TypeKind::BuiltinType {
                var b = cast::<BuiltinType>(t);
                if b->builtin == BuiltinKind::Never { return self._join("void", name); }
                return self._join(b->cxx_emission(), name);
            }
            case TypeKind::RecordType {
                return self._join(self._record(cast::<RecordType>(t), subst, scope), name);
            }
            case TypeKind::PointerType {
                return self.decl(cast::<PointerType>(t)->pointee, "*" + name, subst, scope);
            }
            case TypeKind::CXXLValueRefType {
                return self.decl(cast::<CXXLValueRefType>(t)->referee, "&" + name, subst, scope);
            }
            case TypeKind::CXXRValueRefType {
                return self.decl(cast::<CXXRValueRefType>(t)->referee, "&&" + name, subst, scope);
            }
            case TypeKind::FixedArrayType {
                var a = cast::<FixedArrayType>(t);
                var ext = "";
                if !a->is_incomplete { ext = f"{a->size_bits}"; }
                // `[T; N]` for a generic value parameter: the parameter, or
                // its instance's value (EVAL.md 3).
                if a->extent_param != &null { ext = self._type(a->extent_param, subst, scope); }
                // `[]` binds tighter than `*` and `&`: a pointer or reference
                // TO an array parenthesizes its declarator.
                var nm = name;
                if (nm.size() > 0) && ((nm[0] == '*') || (nm[0] == '&')) { nm = "(" + nm + ")"; }
                return self.decl(a->element, f"{nm}[{ext}]", subst, scope);
            }
            // A Kairo `fn(A) -> R` holds a capturing closure as well as a
            // function (closures.md: "no separate closure type"), so it is
            // the `::__kairo_fn<R(A...)>` value type, never a raw pointer:
            // a lambda with captures has no `R(*)(A...)`. It converts from a
            // function and back to one (for a C callee) on its own. Only a C
            // no-prototype pointer stays raw: no Kairo value has that type.
            case TypeKind::FunctionPointerType {
                var f = cast::<FunctionPointerType>(t);
                if f->is_unprototyped { return self.decl(f->return_type, f"(*{name})()", subst, scope); }
                return self._join("::" + LowerTargets::fn_value() + "<" + self.fn_signature(f, subst, scope) + ">", name);
            }
            case TypeKind::GenericParamType {
                return self._join(self._gparam(cast::<GenericParamType>(t), subst), name);
            }
            // A generic VALUE argument (`4` of `Buf<4>`): the integer.
            case TypeKind::TypeExpr {
                var v = cast::<TypeExpr>(t);
                if !v->is_value { self._ice(t_in->range, "CXXSpell: an unfolded generic value argument reached codegen; TypeResolve folds every one"); return ""; }
                return self._join(self.value(v, subst, scope), name);
            }
            case TypeKind::OpaqueFFIType {
                var o = cast::<OpaqueFFIType>(t);
                return self._join(self.imm_name(o->name, self._cg->tu->fid), name);
            }
            // `T?` is spelled as the record NullableTypeLowering gave it; with
            // none, that pass never saw this canonical.
            case TypeKind::NullableType {
                var lw = cast::<NullableType>(t)->lowered;
                if lw == &null { self._ice(t_in->range, "CXXSpell: T? reached codegen with no lowered record; NullableTypeLowering must run first"); return ""; }
                return self.decl(lw, name, subst, scope);
            }
            case TypeKind::TupleType  { self._ice(t_in->range, "CXXSpell: TupleType canonical reached codegen; TypeResolve canonicalizes every tuple to its TupleN record"); return ""; }
            default {
                self._ice(t_in->range, f"CXXSpell: {to_string(t->kind)} is not a canonical kind");
                return "";
            }
        }
        return "";
    }

    /// A canonical value (EVAL.md 0.2, 3) as the C++ expression that
    /// computes it: the integer, or the expression Sema kept (`(N + 1)`,
    /// `::m::f(3)`, `::m::K`), each operand spelled as a type argument is
    /// (a value parameter, or its instance's value under \p subst). Every
    /// operator application is parenthesized, so the text means the same as
    /// an array bound and as a template argument, where a bare `>>` would
    /// close the list.
    fn value(self, v: *TypeExpr, subst: *InstanceEntry = &null, scope: *Decl = &null) -> string {
        if v->is_exact() { return (f"-{v->vmag}") if (v->vneg) else (f"{v->vmag}"); }
        switch v->vop {
            case ValueOp::Decl {
                // An `eval for` binding is a local with no scope home: its
                // name, read from the table of the file it is written in.
                var vd = dyn_cast::<VariableDecl>(v->vdecl);
                if (vd != &null) && ((vd->semantic_dc == &null) || CXXSpell::in_function_scope(v->vdecl)) {
                    return self.imm_name(vd->name.imm, self._cg->ctx->sm->get_fid(vd->name.range));
                }
                return self.qual_name(v->vdecl);
            }
            case ValueOp::Call {
                var s = self.qual_name(v->vdecl) + "(";
                for var i: usize = 0; i < v->vops.size(); ++i {
                    if i > 0 { s += ", "; }
                    s += self._type(v->vops[i], subst, scope);
                }
                return s + ")";
            }
            case ValueOp::Unary {
                var sym = ("~") if (v->vtok == TokenKind::OpTilde) else ("-");
                return "(" + sym + self._type(v->vops[0], subst, scope) + ")";
            }
            case ValueOp::Binary {
                return "(" + self._type(v->vops[0], subst, scope) + " " + CXXSpell::value_op(v->vtok) + " " + self._type(v->vops[1], subst, scope) + ")";
            }
            case ValueOp::Cast {
                return "static_cast<" + self._type(v->vty, subst, scope) + ">(" + self._type(v->vops[0], subst, scope) + ")";
            }
            default { return ""; }
        }
        return "";
    }

    /// The C++ operator for a computed value's binary operator; Kairo's
    /// keyword forms were normalized to these by TypeResolve.
    static fn value_op(k: TokenKind) -> string {
        switch k {
            case TokenKind::OpPlus           { return "+"; }
            case TokenKind::OpMinus          { return "-"; }
            case TokenKind::OpStar           { return "*"; }
            case TokenKind::OpSlash          { return "/"; }
            case TokenKind::OpPercent        { return "%"; }
            case TokenKind::OpPipe           { return "|"; }
            case TokenKind::OpAmp            { return "&"; }
            case TokenKind::OpCaret          { return "^"; }
            case TokenKind::OpLessLess       { return "<<"; }
            case TokenKind::OpGreaterGreater { return ">>"; }
            default                          { return "?"; }
        }
        return "?";
    }

    /// `R(A...)`, the function type a `fn(A) -> R` value wraps: each
    /// parameter in its mode's abstract spelling, `!` as `void`.
    fn fn_signature(self, f: *FunctionPointerType, subst: *InstanceEntry = &null, scope: *Decl = &null) -> string {
        var ps = "";
        for var i: usize = 0; i < f->params.size(); ++i {
            if i > 0 { ps += ", "; }
            ps += self._param_type(f->params[i], f->modes[i], false, "", subst, scope);
        }
        // A panicking `fn` type's value returns its panic result (§4.1).
        var canon = (cast::<FunctionPointerType>(canon_unqual(f->canonical))) if ((f->canonical != &null) && isa::<FunctionPointerType>(canon_unqual(f->canonical))) else (f);
        if canon->panic_result != &null { return self.decl(canon->panic_result, f"({ps})", subst, scope); }
        return self.decl(f->return_type, f"({ps})", subst, scope);
    }

    /// A parameter's C++ type from its mode (AST/ParamMode.k rules, as
    /// EmitIR documents them). \p is_const is the `const x: T` marker.
    fn param_type(self, p: *ParamDecl, subst: *InstanceEntry = &null, scope: *Decl = &null) -> string {
        // A type pack is `T...` (the C++ parameter pack); under an instance it
        // is that instance's elements, one parameter each.
        if param_is_type_pack(p) {
            var g = cast::<GenericParamType>(canon_unqual(p->type_->canonical));
            var cq = ("const ") if (p->is_const) else ("");
            var els = vec::<*Type>();
            if self.subst_pack(g, subst, &els) {
                var ps = "";
                for var i: usize = 0; i < els.size(); ++i {
                    if i > 0 { ps += ", "; }
                    ps += cq + self._type(els[i], &null, scope);
                }
                return ps;
            }
            return cq + self._gparam(g, &null);
        }
        if p->is_pack {
            if (p->pack_type == &null) { self._ice(p->range, "CXXSpell: pack parameter with no slice type; CallLowering stamps it"); }
            return (("const ") if (p->is_const) else ("")) + self._type(p->pack_type, subst, scope);
        }
        return self._param_type(p->type_, p->mode, p->is_const, "", subst, scope);
    }

    /// `type name` for a parameter, name folded into the declarator for
    /// EVERY type, never `param_type(p) + " " + name`: a function pointer
    /// spelled that way is `U(*)(T) f`, which clang reads as a cast-like
    /// expression ("expected ')\x27", "undeclared identifier 'f\x27"); the name
    /// belongs inside, `U (*f)(T)`. An array is still its own branch:
    /// `[T; N]` is passed by reference (`const T (&xs)[N]` / `T (&xs)[N]`),
    /// never by value (StmtTyping rejects that). Empty \p name is the
    /// abstract form. \p scope as for _type.
    fn param_decl(self, p: *ParamDecl, name: string, subst: *InstanceEntry = &null, scope: *Decl = &null) -> string {
        var c = (p->type_->canonical) if (p->type_ != &null) else (&null);
        if (!p->is_pack) && (c != &null) && (canon_unqual(c)->kind == TypeKind::FixedArrayType) {
            if ((p->mode == ParamMode::Value) && (!p->is_const)) { self._ice(p->range, "CXXSpell: array parameter by value; StmtTyping must reject it"); }
            var s = self.decl(canon_unqual(c), "&" + name, subst, scope);
            return (("const " + s) if (p->is_const) else (s));
        }
        if p->is_pack {
            var s = self.param_type(p, subst, scope);
            if name.size() > 0 { s += " " + name; }
            return s;
        }
        return self._param_type(p->type_, p->mode, p->is_const, name, subst, scope);
    }

    /// The mode's reference and the const marker folded into decl(), so a
    /// name lands inside the declarator: `@inout` on a function pointer is
    /// `U (*&f)(T)`, which decl() brackets as it does any `*`/`&` declarator.
    /// A `fn` type's parameter \p t in mode \p mode, declared as \p name
    /// (a wrapper lambda's parameter, EmitIR::_fn_effect_value).
    fn param_named(self, t: *Type, mode: ParamMode, name: string) -> string {
        return self._param_type(t, mode, false, name, &null, &null);
    }

    priv fn _param_type(self, t: *Type, mode: ParamMode, is_const: bool, name: string, subst: *InstanceEntry, scope: *Decl) -> string {
        // `const T&` only from a stamped `@copy fn X(self, const other: Self)`
        // (ClassLifecycle); nothing else sets Inout together with `const`.
        if mode == ParamMode::Inout {
            var s = self.decl(t, self._ref_declarator("&", name), subst, scope);
            return ("const " + s) if (is_const) else (s);
        }
        if mode == ParamMode::Move  { return self.decl(t, self._ref_declarator("&&", name), subst, scope); }
        if is_const {
            // `const T&` iff a non-generic record; `const T` otherwise.
            var c = t->canonical;
            if (c != &null) && (c->kind == TypeKind::RecordType) && (!c->is_dependent()) {
                return "const " + self.decl(t, self._ref_declarator("&", name), subst, scope);
            }
            return "const " + self.decl(t, name, subst, scope);
        }
        return self.decl(t, name, subst, scope);
    }

    /// `& name`, keeping the `T& x` spelling the printed C++ has always had
    /// (and that tests match); bare `&` for the abstract form.
    priv fn _ref_declarator(self, sigil: string, name: string) -> string {
        if name.size() == 0 { return sigil; }
        return sigil + " " + name;
    }

    /// `<a, b>` from an instance's args or a pattern's own params.
    fn args_str(self, args: *vec::<*Type>, subst: *InstanceEntry = &null, scope: *Decl = &null) -> string {
        var s = "<";
        for var i: usize = 0; i < args->size(); ++i {
            if i > 0 { s += ", "; }
            s += self._type((*args)[i], subst, scope);
        }
        s += ">";
        return s;
    }

    // --- Dependent-qualified names ---------------------------------------------

    /// `Q::leaf`, a member type named through the record type \p record:
    /// `typename Q::leaf` when Q is dependent, and with \p args
    /// `typename Q::template leaf<args>`. This is the one place a member of
    /// a dependent type is spelled; a nested type of a generic record, an
    /// associated type (`T::Bar`), a generic associated type
    /// (`T::Bar<U>`) and a member-template call (`x.template f<U>()`) are
    /// all the same C++ rule -- inside a template, a name qualified by a
    /// dependent type is assumed to be neither a type nor a template unless
    /// it says so -- and spelling it twice is how the two copies drift.
    ///
    /// A non-dependent Q drops both keywords. C++ allows them there, but Q is
    /// then a concrete class whose members are looked up at once, so they
    /// say nothing. \p subst and \p scope are passed through to Q's spelling
    /// and to \p args. Q's top-level cv is dropped: it qualifies the object,
    /// not the scope a member is named from.
    fn dependent_member_type(self, record: *Type, leaf: string, args: *vec::<*Type> = &null,
                             subst: *InstanceEntry = &null, scope: *Decl = &null) -> string {
        ICE_IF((record == &null) || (record->canonical == &null), "CXXSpell: dependent_member_type with no canonical qualifier");
        var q = canon_unqual(record->canonical);
        var targs = "";
        if (args != &null) && (args->size() > 0) { targs = self.args_str(args, subst, scope); }
        return CXXSpell::_member_type(self._type(q, subst, scope), q->is_dependent(), leaf, targs);
    }

    /// The text of dependent_member_type from an already-spelled qualifier.
    static fn _member_type(q: string, dependent: bool, leaf: string, targs: string) -> string {
        if !dependent { return q + "::" + leaf + targs; }
        if targs.size() == 0 { return "typename " + q + "::" + leaf; }
        return "typename " + q + "::template " + leaf + targs;
    }

    /// \p d's C++ template parameters: an extension member's extension's,
    /// then its own. One list; a non-member function takes one.
    static fn template_params(d: *Decl) -> vec::<*GenericParamDecl> {
        var out = vec::<*GenericParamDecl>();
        var ext = decl_extension_of(d);
        if ext != &null {
            var eps = decl_generic_params(static_cast::<*Decl>(ext));
            for var i: usize = 0; i < eps.size(); ++i { out.push_back(eps[i]); }
        }
        var gps = decl_generic_params(d);
        for var i: usize = 0; i < gps.size(); ++i { out.push_back(gps[i]); }
        return out;
    }

    /// The instance argument \p g stands for in \p subst, or null. Keyed on
    /// the GenericParamDecl's identity in the primary's template_params, so
    /// an extension's T, a member's own U and a default thunk's borrowed
    /// list (the callee's GenericParamDecls) all resolve the same way.
    /// A pack parameter's elements under \p subst, appended to \p out: every
    /// instance argument from the pack's position on (InstanceEntry::args
    /// keeps packs flat, so the pack is the tail). False when \p subst does
    /// not bind \p g.
    fn subst_pack(self, g: *GenericParamType, subst: *InstanceEntry, out: *vec::<*Type>) -> bool {
        if (g == &null) || (g->owner == &null) || (subst == &null) || (!g->is_pack) { return false; }
        var own = decl_generic_params(CXXSpell::rep(g->owner));
        var idx = static_cast::<usize>(g->param_index);
        if idx >= own.size() { return false; }
        var gp = own[idx];
        var tps = CXXSpell::template_params(CXXSpell::rep(subst->primary));
        for var k: usize = 0; k < tps.size(); ++k {
            if tps[k] != gp { continue; }
            for var j: usize = k; j < subst->args.size(); ++j { out->push_back(subst->args[j]); }
            return true;
        }
        return false;
    }

    fn subst_for(self, g: *GenericParamType, subst: *InstanceEntry) -> *Type {
        if (g == &null) || (g->owner == &null) || (subst == &null) { return &null; }
        var own = decl_generic_params(CXXSpell::rep(g->owner));
        var idx = static_cast::<usize>(g->param_index);
        if idx >= own.size() { return &null; }
        var gp = own[idx];
        var tps = CXXSpell::template_params(CXXSpell::rep(subst->primary));
        for var k: usize = 0; k < tps.size(); ++k {
            if tps[k] != gp { continue; }
            ICE_IF(k >= subst->args.size(), "CXXSpell: instance args shorter than the primary's template parameters");
            return subst->args[k];
        }
        return &null;
    }

    /// An extension member's receiver parameter, unnamed: `[const ]X*`, or
    /// `[const ]X&` for an operator ([over.oper]/7 wants a class type).
    fn ext_receiver(self, f: *FunctionDecl, x: *ExtensionDecl, subst: *InstanceEntry = &null) -> string {
        var s = "";
        if f->is_const() { s += "const "; }
        s += self._type(x->target, subst);
        s += ("&") if (f->is_operator) else ("*");
        return s;
    }

    // --- Witnesses (CODEGEN.md §7b) ----------------------------------------------

    /// `::ns::I_witness`: the class template a bound call goes through.
    fn witness_name(self, iface: *Decl) -> string {
        return self._iface_qual(iface) + LowerTargets::witness_suffix();
    }

    /// `::ns::I_c`: the concept an interface bound renders as.
    fn concept_name(self, iface: *Decl) -> string {
        return self._iface_qual(iface) + LowerTargets::concept_suffix();
    }

    /// `::ns::I`, the prefix both names share. An interface nested in a
    /// type would put its witness inside a class, where a specialization
    /// cannot be declared; none reaches here yet.
    priv fn _iface_qual(self, iface: *Decl) -> string {
        var r = CXXSpell::rep(iface);
        if (self.owner_types(r).size() > 0) { self._ice(r->range, "CXXSpell: a witness for an interface nested in a type; no naming rule for it yet"); }
        var s = "";
        var ns = self.ns_segments(r);
        for var i: usize = 0; i < ns.size(); ++i { s += "::"; s += ns[i]; }
        return s + "::" + self.leaf(r);
    }

    /// `<Self, A...>`: a witness's or concept's arguments for interface
    /// instance \p iface, Self already spelled as \p self_s.
    fn witness_args(self, self_s: string, iface: *Type, subst: *InstanceEntry = &null) -> string {
        var s = "<" + self_s;
        var v = self.iface_args(iface);
        for var i: usize = 0; i < v.size(); ++i { s += ", "; s += self._type(v[i], subst); }
        return s + ">";
    }

    /// The arguments of interface instance \p iface, in parameter order.
    fn iface_args(self, iface: *Type) -> vec::<*Type> {
        var v = vec::<*Type>();
        var c = canon_unqual(iface);
        if (c == &null) || (!isa::<RecordType>(c)) { return v; }
        var r = cast::<RecordType>(c);
        var d = r->decl;
        if decl_is_instance(d) {
            var e = self._cg->instances->entry_of(d);
            if (e == &null) { self._ice(d->range, "CXXSpell: interface instance with no registry entry"); }
            for var i: usize = 0; i < e->args.size(); ++i { v.push_back(e->args[i]); }
            return v;
        }
        for var i: usize = 0; i < r->args.size(); ++i { v.push_back(r->args[i]); }
        return v;
    }

    /// ` requires (::ns::I_c<T> && ...)` for \p d's interface bounds, one
    /// conjunct per `P impl I<A...>` in clause order, or "". Only bounds on
    /// \p d's OWN template parameters (template_params: an extension
    /// member's extension's, then its own), read off \p d's clause and, for
    /// an extension member, its extension's: a class's bound is the class
    /// head's, never repeated on a member that adds no parameter. Every
    /// declaration of the entity -- forward declaration, definition, an
    /// out-of-line member's owner head -- comes through template_head, so
    /// the heads agree, as [temp.over.link] and the mangled constraint need.
    /// Concepts are tier 0 (EmitPlan), ahead of every head that names one.
    fn requires_clause(self, d: *Decl) -> string {
        var tps = CXXSpell::template_params(d);
        if tps.size() == 0 { return ""; }
        var cs = vec::<*ConstraintExpr>();
        var x = decl_extension_of(d);
        if x != &null { CXXSpell::impl_bounds(decl_requires_clause(static_cast::<*Decl>(x)), &cs); }
        CXXSpell::impl_bounds(decl_requires_clause(d), &cs);
        var s = "";
        for var i: usize = 0; i < cs.size(); ++i {
            var c = cs[i];
            if (c->rhs == &null) || (c->rhs->canonical == &null) { continue; }
            var gp = CXXSpell::_bound_param(c);
            if gp == &null { continue; }
            var mine = false;
            for var k: usize = 0; k < tps.size(); ++k { if tps[k] == gp { mine = true; break; } }
            if !mine { continue; }
            var rhs = canon_unqual(c->rhs->canonical);
            if !isa::<RecordType>(rhs) { continue; }
            var idecl = CXXSpell::rep(decl_pattern(CXXSpell::rep(cast::<RecordType>(rhs)->decl)));
            if !isa::<InterfaceDecl>(idecl) { continue; }
            s += (" requires (") if (s.size() == 0) else (" && ");
            s += self.concept_name(idecl) + self.witness_args(self.imm_name(gp->name.imm, CXXSpell::fid_of(CXXSpell::rep(gp->owner))), rhs);
        }
        // A record's VALUE predicates (`class <T> B requires sizeof T <= 128`)
        // as C++ constraints, so clang rejects a bad instance where it is
        // named (EVAL.md §8, E10). Only one that names nothing but the
        // record's own parameters, literals and sizeof / alignof is
        // spelled: the head is written before every other declaration, and
        // a constant or function it named would not be declared yet. The
        // rest stay unchecked until M2 (ticketed). A function's predicates
        // are its body's static_asserts instead (EmitIR::_body).
        if isa::<ClassDecl>(d) || isa::<StructDecl>(d) || isa::<UnionDecl>(d) {
            var vps = vec::<*Expr>();
            CXXSpell::value_predicates(decl_requires_clause(d), &vps);
            for var i: usize = 0; i < vps.size(); ++i {
                var t = self._pred_text(vps[i]);
                if t.size() == 0 { continue; }
                s += (" requires (") if (s.size() == 0) else (" && ");
                s += "(" + t + ")";
            }
        }
        // Parenthesized: what follows the head is often a return type that
        // starts with `::` (`::builtin::Tuple2<...> f(...)`), and C++ reads a
        // `::` after `I_c<T>` as continuing the concept's qualified name --
        // no spacing separates them, only the closing paren.
        if s.size() > 0 { s += ")"; }
        return s;
    }

    /// Every VALUE predicate of requires clause \p e (conjuncts that are not
    /// `T impl I` / `T derives B`), in clause order.
    static fn value_predicates(e: *Expr, out: *vec::<*Expr>) {
        if e == &null { return; }
        var b = dyn_cast::<BinaryOperatorExpr>(e);
        if (b != &null) && ((b->op_token.kind == TokenKind::OpAmpAmp) || (b->op_token.kind == TokenKind::KwAnd)) {
            CXXSpell::value_predicates(b->lhs, out);
            CXXSpell::value_predicates(b->rhs, out);
            return;
        }
        if isa::<ConstraintExpr>(e) { return; }
        out->push_back(e);
    }

    /// C++ text of a self-contained predicate (requires_clause), or "".
    priv fn _pred_text(self, e0: *Expr) -> string {
        if e0 == &null { return ""; }
        var e = e0;
        while (e != &null) && isa::<ParenExpr>(e) { e = cast::<ParenExpr>(e)->inner; }
        if e == &null { return ""; }
        if isa::<IntegerLiteralExpr>(e) {
            var lit = cast::<IntegerLiteralExpr>(e);
            if (lit->imm == &null) || (lit->get_value_hi() != u64(0)) { return ""; }
            return f"{lit->get_value_lo()}";
        }
        if isa::<BooleanLiteralExpr>(e) { return (("true") if (cast::<BooleanLiteralExpr>(e)->value) else ("false")); }
        if isa::<SizeOfExpr>(e) {
            var t = cast::<SizeOfExpr>(e)->type_arg;
            if (t == &null) || (t->canonical == &null) { return ""; }
            return "sizeof(" + self._type(t) + ")";
        }
        if isa::<AlignOfExpr>(e) {
            var t = cast::<AlignOfExpr>(e)->type_arg;
            if (t == &null) || (t->canonical == &null) { return ""; }
            return "alignof(" + self._type(t) + ")";
        }
        if isa::<NamedIdentExpr>(e) {
            var gp = dyn_cast::<GenericParamDecl>(cast::<NamedIdentExpr>(e)->resolved_decl);
            if (gp == &null) || (!gp->is_const_param) || (gp->owner == &null) { return ""; }
            return self.imm_name(gp->name.imm, CXXSpell::fid_of(CXXSpell::rep(gp->owner)));
        }
        if isa::<UnaryOperatorExpr>(e) {
            var u = cast::<UnaryOperatorExpr>(e);
            if u->resolved_op != &null { return ""; }
            var k = u->op_token.kind;
            var o = "";
            if (k == TokenKind::OpExclaim) || (k == TokenKind::KwNot) { o = "!"; }
            else if k == TokenKind::OpMinus { o = "-"; }
            else if k == TokenKind::OpTilde { o = "~"; }
            else { return ""; }
            var x = self._pred_text(u->operand);
            if x.size() == 0 { return ""; }
            return o + "(" + x + ")";
        }
        if isa::<BinaryOperatorExpr>(e) {
            var b = cast::<BinaryOperatorExpr>(e);
            if b->resolved_op != &null { return ""; }
            var o = CXXSpell::_pred_op(b->op_token.kind);
            if o.size() == 0 { return ""; }
            var l = self._pred_text(b->lhs);
            var r = self._pred_text(b->rhs);
            if (l.size() == 0) || (r.size() == 0) { return ""; }
            return "(" + l + ") " + o + " (" + r + ")";
        }
        return "";
    }

    static fn _pred_op(k: TokenKind) -> string {
        if k == TokenKind::OpPlus { return "+"; }
        if k == TokenKind::OpMinus { return "-"; }
        if k == TokenKind::OpStar { return "*"; }
        if k == TokenKind::OpSlash { return "/"; }
        if k == TokenKind::OpPercent { return "%"; }
        if k == TokenKind::OpLess { return "<"; }
        if k == TokenKind::OpLessEqual { return "<="; }
        if k == TokenKind::OpGreater { return ">"; }
        if k == TokenKind::OpGreaterEqual { return ">="; }
        if k == TokenKind::OpEqualEqual { return "=="; }
        if k == TokenKind::OpExclaimEqual { return "!="; }
        if (k == TokenKind::OpAmpAmp) || (k == TokenKind::KwAnd) { return "&&"; }
        if (k == TokenKind::OpPipePipe) || (k == TokenKind::KwOr) { return "||"; }
        if (k == TokenKind::OpAmp) || (k == TokenKind::KwBitand) { return "&"; }
        if (k == TokenKind::OpPipe) || (k == TokenKind::KwBitor) { return "|"; }
        if (k == TokenKind::OpCaret) || (k == TokenKind::KwXor) { return "^"; }
        if k == TokenKind::OpLessLess { return "<<"; }
        if k == TokenKind::OpGreaterGreater { return ">>"; }
        return "";
    }

    /// The generic parameter a conjunct constrains, or null.
    static fn _bound_param(c: *ConstraintExpr) -> *GenericParamDecl {
        var id = dyn_cast::<NamedIdentExpr>(c->lhs);
        if id == &null { return &null; }
        return dyn_cast::<GenericParamDecl>(id->resolved_decl);
    }

    /// Every `impl` conjunct of requires clause \p e, in clause order.
    static fn impl_bounds(e: *Expr, out: *vec::<*ConstraintExpr>) {
        if e == &null { return; }
        var b = dyn_cast::<BinaryOperatorExpr>(e);
        if (b != &null) && ((b->op_token.kind == TokenKind::OpAmpAmp) || (b->op_token.kind == TokenKind::KwAnd)) {
            CXXSpell::impl_bounds(b->lhs, out);
            CXXSpell::impl_bounds(b->rhs, out);
            return;
        }
        var c = dyn_cast::<ConstraintExpr>(e);
        if (c != &null) && (!c->is_derives()) { out->push_back(c); }
    }

    /// `template <class T, class... Ts, int N>` for a generic decl; "" otherwise.
    fn template_head(self, d: *Decl) -> string {
        var gps = CXXSpell::template_params(d);
        if gps.size() == 0 { return ""; }
        var s = "template <";
        for var i: usize = 0; i < gps.size(); ++i {
            var gp = gps[i];
            if i > 0 { s += ", "; }
            if gp->is_const_param {
                s += self._type(gp->value_type);
            } else {
                s += "class";
            }
            if gp->is_pack { s += "..."; }
            s += " ";
            s += self.imm_name(gp->name.imm, CXXSpell::fid_of(d));
        }
        s += ">";
        s += self.requires_clause(d);
        s += " ";
        return s;
    }

    // --- Specializations of a generic record ----------------------------------

    /// \p d is a registered explicit or partial specialization of a record
    /// (TypeResolve sets `instantiated_from` to the primary). A function
    /// spec is OverloadResolution's and never a C++ specialization here.
    static fn is_record_spec(d: *Decl) -> bool {
        if (d == &null) || (!(isa::<ClassDecl>(d) || isa::<StructDecl>(d) || isa::<UnionDecl>(d))) { return false; }
        var k = decl_spec_kind(d);
        if (k != SpecKind::Explicit) && (k != SpecKind::Partial) { return false; }
        return decl_instantiated_from(d) != &null;
    }

    /// The head of a record's own declaration and definition: an explicit
    /// specialization's `template <>`, else template_head. Not for an
    /// out-of-line MEMBER of one: [temp.expl.spec]/5 writes those with no
    /// `template <>` at all, and _owner_template_head's template_head gives
    /// exactly that, since an explicit spec has no parameters.
    fn record_head(self, d: *Decl) -> string {
        if CXXSpell::is_record_spec(d) && (decl_spec_kind(d) == SpecKind::Explicit) {
            return "template <> " + self.requires_clause(d);
        }
        return self.template_head(d);
    }

    /// `<P*>` / `<bool>`: a specialization's pattern, the arguments it
    /// specializes the primary at, with a partial's own parameters by name.
    /// "" for anything that is not a record spec. Appended to the leaf
    /// wherever the spec itself is named -- its declarations and the
    /// qualifier of its out-of-line members -- because C++ has no other way
    /// to say which specialization of `Store` is meant.
    fn spec_suffix(self, d: *Decl) -> string {
        if !CXXSpell::is_record_spec(d) { return ""; }
        var sargs = decl_spec_args(d);
        var args  = vec::<*Type>();
        for var i: usize = 0; i < sargs.size(); ++i {
            ICE_IF((sargs[i] == &null) || (sargs[i]->canonical == &null),
                "CXXSpell: a specialization's pattern reached codegen unresolved");
            args.push_back(sargs[i]->canonical);
        }
        return self.args_str(&args);
    }

    /// One segment of an out-of-line member's qualifier: the leaf, then a
    /// specialization's pattern or a generic owner's own parameters as its
    /// arguments (`Store<P*>`, `Store<bool>`, `Box<T>`).
    fn owner_segment(self, d: *Decl) -> string {
        var s = self.leaf(d);
        if CXXSpell::is_record_spec(d) { return s + self.spec_suffix(d); }
        var gps = decl_generic_params(d);
        if gps.size() == 0 { return s; }
        s += "<";
        for var j: usize = 0; j < gps.size(); ++j {
            if j > 0 { s += ", "; }
            s += self.imm_name(gps[j]->name.imm, CXXSpell::fid_of(d));
            if gps[j]->is_pack { s += "..."; }
        }
        s += ">";
        return s;
    }

    // --- internals ---------------------------------------------------------------

    priv fn _join(self, ty: string, name: string) -> string {
        if name.size() == 0 { return ty; }
        // A declarator that starts with `*`/`&`/`(` binds without a space.
        var c = name[0];
        if (c == '*') || (c == '&') || (c == '(') || (c == '[') { return ty + name; }
        return ty + " " + name;
    }

    /// \p r's arguments are exactly \p iface's own parameters, in order.
    priv fn _own_args(self, r: *RecordType, iface: *Decl) -> bool {
        var gps = decl_generic_params(iface);
        if gps.size() != r->args.size() { return false; }
        for var i: usize = 0; i < r->args.size(); ++i {
            var g = dyn_cast::<GenericParamType>(canon_unqual(r->args[i]));
            if (g == &null) || (g->param_index != static_cast::<u32>(i)) { return false; }
            if CXXSpell::rep(g->owner) != iface { return false; }
        }
        return true;
    }

    priv fn _record(self, r: *RecordType, subst: *InstanceEntry, scope: *Decl) -> string {
        var d = r->decl;
        ICE_IF(d == &null, "CXXSpell: RecordType with no decl");
        if isa::<InterfaceDecl>(d) {
            var mine = (self.self_iface != &null) && (CXXSpell::rep(decl_pattern(CXXSpell::rep(d))) == self.self_iface);
            // Self is `I` bare, or in a GENERIC interface `I<T...>` over its
            // own parameters (TypeResolve::_self_record) -- unsubstituted
            // here, the member's substitution applying only below it.
            if mine && ((r->args.size() == 0) || self._own_args(r, self.self_iface)) { return self.self_spelling; }
            self._ice(d->range, "CXXSpell: an interface has no C++ type; only its Self inside a witness is spelled");
        }
        if decl_is_imported(d) { return decl_cxx_spelling(d); }

        // An instance shell names its PRIMARY plus the registry's args.
        if decl_is_instance(d) {
            var e = self._cg->instances->entry_of(d);
            if (e == &null) { self._ice(d->range, "CXXSpell: instance shell with no registry entry"); }
            return self._record_name(e->primary, self.args_str(&(e->args), subst, scope), scope);
        }
        var targs = "";
        if r->args.size() > 0 {
            var v = vec::<*Type>();
            for var i: usize = 0; i < r->args.size(); ++i { v.push_back(r->args[i]); }
            targs = self.args_str(&v, subst, scope);
        }
        return self._record_name(d, targs, scope);
    }

    /// A record's name with its own template arguments \p targs ("" for
    /// none). A type nested in a class template cannot be qualified the way
    /// qual_name does it: `::ns::L::P` names the template `L` without
    /// arguments, which C++ rejects. So, in order:
    ///   - inside the owner's own body (\p scope), the leaf: the owner's
    ///     scope is in force there, and its injected class name stands for
    ///     the current instantiation;
    ///   - any other place under a generic owner, the member of the owner
    ///     spelled with its own parameters, `typename ::ns::L<K>::P` -- what
    ///     an out-of-line member's return type and body need, and valid
    ///     anywhere inside the owner's template;
    ///   - everything else, the plain qualified name.
    /// Outside the owner's template the second form names parameters that
    /// are not in scope. That is unreachable from correct input only once
    /// Sema keeps the owner's arguments on a nested type (`L<i32>::P`
    /// canonicalizes to the pattern's `P` today), and the qualified form
    /// would be just as wrong there.
    priv fn _record_name(self, d_in: *Decl, targs: string, scope: *Decl) -> string {
        if CXXSpell::in_function_scope(d_in) { return self.leaf(d_in) + targs; }
        var d   = CXXSpell::rep(d_in);
        var own = self._record_owner(d);
        if own == &null { return self.qual_name(d) + targs; }
        if scope != &null {
            var sc = CXXSpell::rep(scope);
            if (sc == own) || (sc == d) { return self.leaf(d) + targs; }
        }
        var q = self._generic_owner_qual(d);
        if q.size() == 0 { return self.qual_name(d) + targs; }
        return CXXSpell::_member_type(q, true, self.leaf(d), targs);
    }

    /// The record \p d is a member of, or null at namespace scope. An
    /// extension is not an owner here: it opens no C++ class scope a nested
    /// type could live in.
    priv fn _record_owner(self, d: *Decl) -> *Decl {
        var dc = self._home_dc(d);
        if (dc == &null) || (!dc->is_type_scope()) || (dc->dc_kind == DeclContextKind::Extension) { return &null; }
        return CXXSpell::rep(dc->dc_owner);
    }

    /// `::ns::L<K>::Q`: \p d's owners, each generic one spelled with its own
    /// parameters, i.e. the owner chain as its own template body sees it;
    /// "" when no owner is generic, because then qual_name is already a
    /// complete name. A generic owner past the first is a member template of
    /// a dependent type and takes `template`, as dependent_member_type
    /// spells it.
    priv fn _generic_owner_qual(self, d: *Decl) -> string {
        var rev = vec::<*Decl>();
        var dc = self._home_dc(d);
        while (dc != &null) && dc->is_type_scope() {
            if dc->dc_kind != DeclContextKind::Extension { rev.push_back(CXXSpell::rep(dc->dc_owner)); }
            dc = dc->dc_parent;
        }
        var s = "";
        var ns = self.ns_segments(d);
        for var i: usize = 0; i < ns.size(); ++i { s += "::"; s += ns[i]; }
        var dependent = false;
        for var i: usize = 0; i < rev.size(); ++i {
            var o   = rev[rev.size() - 1 - i];
            var gps = decl_generic_params(o);
            s += "::";
            if dependent && (gps.size() > 0) { s += "template "; }
            s += self.leaf(o);
            if gps.size() == 0 { continue; }
            dependent = true;
            var fid = CXXSpell::fid_of(o);
            s += "<";
            for var j: usize = 0; j < gps.size(); ++j {
                if j > 0 { s += ", "; }
                s += self.imm_name(gps[j]->name.imm, fid);
                if gps[j]->is_pack { s += "..."; }
            }
            s += ">";
        }
        return (s) if (dependent) else ("");
    }

    priv fn _gparam(self, g: *GenericParamType, subst: *InstanceEntry) -> string {
        ICE_IF(g->owner == &null, "CXXSpell: canonical generic param with no owner");
        var owner = CXXSpell::rep(g->owner);
        // A pack is only ever spelled expanded: a canonical pack parameter
        // stands for its expansion (`R<i32, E...>`'s argument, `...xs: T`'s
        // type), so it is `E...`, or under an instance its elements.
        if g->is_pack && (self.pack_alias != &null) {
            var ags = decl_generic_params(owner);
            if (usize(g->param_index) < ags.size()) && (ags[usize(g->param_index)] == self.pack_alias) { return LowerTargets::adt_pack_elem(); }
        }
        if g->is_pack {
            var els = vec::<*Type>();
            if self.subst_pack(g, subst, &els) {
                var ps = "";
                for var i: usize = 0; i < els.size(); ++i {
                    if i > 0 { ps += ", "; }
                    ps += self._type(els[i], &null);
                }
                return ps;
            }
        } else {
            var t = self.subst_for(g, subst);
            if t != &null { return self._type(t, &null); }
        }
        var gps = decl_generic_params(owner);
        if (static_cast::<usize>(g->param_index) >= gps.size()) { self._ice(owner->range, "CXXSpell: generic param index out of range"); }
        var nm = self.imm_name(gps[static_cast::<usize>(g->param_index)]->name.imm, CXXSpell::fid_of(owner));
        if (!g->is_pack) && (self.void_unit_owner != &null) && (CXXSpell::rep(self.void_unit_owner) == owner) {
            return "::" + LowerTargets::void_unit() + "<" + nm + ">";
        }
        return (nm + "...") if (g->is_pack) else (nm);
    }
}