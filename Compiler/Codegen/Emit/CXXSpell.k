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

    fn CXXSpell(self) { self._cg = &null; }
    fn CXXSpell(self, cg: *CodegenContext) { self._cg = cg; }

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
            ICE_IF(f->return_type == &null, "CXXSpell: `op as` with no target type");
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
            ICE_IF(m.size() == 0, f"CXXSpell: extension 'op {sym}' has no C++ non-member form; OperatorSignatureCheck should reject it");
            return m;
        }
        return "operator" + sym;
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
        if sym == ".*"    { return LowerTargets::op_dotstar(); }
        if sym == "await"  { return LowerTargets::op_await(); }
        if sym == "spawn"  { return LowerTargets::op_spawn(); }
        if sym == "thread" { return LowerTargets::op_thread(); }
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

    /// `[]`, `.*`, `->*` return a place. Codegen's copy of
    /// OperatorFacts::is_place, on this side of the import boundary. `[]` is
    /// two tokens; `.*` and `->*` are one each.
    static fn is_place_operator(f: *FunctionDecl) -> bool {
        if (f == &null) || (!f->is_operator) || (!f->is_method()) { return false; }
        var n = f->op_token.size();
        if n == 2 {
            return (f->op_token[0].kind == TokenKind::OpLSquare) && (f->op_token[1].kind == TokenKind::OpRSquare);
        }
        if n == 1 {
            var k = f->op_token[0].kind;
            return (k == TokenKind::OpDotStar) || (k == TokenKind::OpArrowStar);
        }
        return false;
    }

    /// The C++ return type of \p f: a place operator's `*T` / `*const T`
    /// becomes `T&` / `const T&`, so C++ code can write `v[i] = x` on a Kairo
    /// type and an imported `T&` and a Kairo place are one ABI. Everything
    /// else is the declared type. The pointee of `*const T` is the `const T`
    /// canonical, so _type already spells the const and `&` goes on the end.
    fn return_spelling(self, f: *FunctionDecl, subst: *InstanceEntry) -> string {
        if (f->return_type == &null) || (f->return_type->canonical == &null) { return self._type(f->return_type, subst); }
        if !CXXSpell::is_place_operator(f) { return self._type(f->return_type, subst); }
        var c = canon_unqual(f->return_type->canonical);
        ICE_IF((c == &null) || (!isa::<PointerType>(c)), "CXXSpell: place operator with a non-pointer result; OperatorSignatureCheck gate failure");
        return self._type(cast::<PointerType>(c)->pointee, subst) + "&";
    }

    /// The type an operator belongs to: its class, or its extension's target.
    fn operator_owner(self, f: *FunctionDecl) -> *Decl {
        var lex = reinterpret_cast::<*DeclContext>(f->lexical_dc);
        if (lex != &null) && (lex->dc_kind == DeclContextKind::Extension) {
            var x = cast::<ExtensionDecl>(lex->dc_owner);
            var c = x->target->canonical;
            ICE_IF((c == &null) || (c->kind != TypeKind::RecordType), "CXXSpell: extension operator on a non-record target");
            return CXXSpell::rep(cast::<RecordType>(c)->decl);
        }
        var dc = reinterpret_cast::<*DeclContext>(f->semantic_dc);
        ICE_IF((dc == &null) || (!dc->is_type_scope()), "CXXSpell: operator with no owning type");
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
            out.push_back(*p);
        }
        return out;
    }

    static fn is_entry_tu(tu: *TranslationUnit) -> bool {
        if (tu == &null) || (tu->ctx == &null) { return true; }
        return tu->ctx->module_base.segments.size() == 0;
    }

    /// The entry TU's namespace: its FILE STEM, sanitized to a C++
    /// identifier. An entry file declares no module, so before this its decls
    /// landed in one unnamed namespace and two entry TUs in a build could not
    /// both define `helper`. The stem is a name the source already has.
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
        var out = "";
        for var i: usize = start; i < end; ++i {
            var c = path[i];
            var ok = ((c >= 'a') && (c <= 'z')) || ((c >= 'A') && (c <= 'Z'))
                  || ((c >= '0') && (c <= '9')) || (c == '_');
            if ok { out += c; } else { out += "_"; }
        }
        if out.size() == 0 { return "_"; }
        if (out[0] >= '0') && (out[0] <= '9') { return "_" + out; }
        // `operator.k` would open `namespace operator`. A trailing `_` cannot
        // collide with another keyword stem, and the stem reaches the ABI
        // only through here (invariant 9a).
        if is_cxx_keyword(out) { return out + "_"; }
        return out;
    }

    /// A decl with no linkage outside its own file: `priv` or `internal` in
    /// the entry TU. It goes in an unnamed namespace NESTED in the file's,
    /// so `::<stem>::helper` still names it -- C++'s implicit using-directive
    /// reaches into the unnamed one -- and qual_name is unchanged.
    static fn is_anon(d: *Decl) -> bool {
        if d == &null { return false; }
        if !CXXSpell::is_entry_tu(CXXSpell::tu_of(d)) { return false; }
        var v = CXXSpell::vis_of(d);
        return (v == VIS_PRIV()) || (v == VIS_INTERNAL());
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
        ICE_IF(!isa::<RecordType>(c), "CXXSpell: extension of a non-record, non-builtin target; no scope naming rule for it yet");
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

    // --- Types -------------------------------------------------------------------

    /// C++ spelling of a canonical type. \p subst substitutes the primary's
    /// generic parameters with an instance's args (tier 3). Declarator
    /// shapes (arrays, function pointers) need a name to wrap; use decl().
    fn _type(self, t: *Type, subst: *InstanceEntry = &null) -> string {
        return self.decl(t, "", subst);
    }

    /// `type name` with the declarator folded in: `int x`, `int (*f)(int)`.
    /// Empty \p name gives the abstract form.
    fn decl(self, t_in: *Type, name: string, subst: *InstanceEntry = &null) -> string {
        if t_in == &null { return self._join("void", name); }
        var t = t_in->canonical;
        ICE_IF(t == &null, "CXXSpell: type with no canonical reached codegen (sema gate failure)");

        switch t->kind {
            case TypeKind::QualifiedType {
                var q = cast::<QualifiedType>(t);
                var pfx = "";
                if (q->quals & QUAL_CONST())    != 0 { pfx += "const "; }
                if (q->quals & QUAL_VOLATILE()) != 0 { pfx += "volatile "; }
                return pfx + self.decl(q->inner, name, subst);
            }
            case TypeKind::BuiltinType {
                var b = cast::<BuiltinType>(t);
                if b->builtin == BuiltinKind::Never { return self._join("void", name); }
                return self._join(b->cxx_emission(), name);
            }
            case TypeKind::RecordType {
                return self._join(self._record(cast::<RecordType>(t), subst), name);
            }
            case TypeKind::PointerType {
                return self.decl(cast::<PointerType>(t)->pointee, "*" + name, subst);
            }
            case TypeKind::CXXLValueRefType {
                return self.decl(cast::<CXXLValueRefType>(t)->referee, "&" + name, subst);
            }
            case TypeKind::CXXRValueRefType {
                return self.decl(cast::<CXXRValueRefType>(t)->referee, "&&" + name, subst);
            }
            case TypeKind::FixedArrayType {
                var a = cast::<FixedArrayType>(t);
                var ext = "";
                if !a->is_incomplete { ext = f"{a->size_bits}"; }
                // `[]` binds tighter than `*` and `&`: a pointer or reference
                // TO an array parenthesizes its declarator.
                var nm = name;
                if (nm.size() > 0) && ((nm[0] == '*') || (nm[0] == '&')) { nm = "(" + nm + ")"; }
                return self.decl(a->element, f"{nm}[{ext}]", subst);
            }
            case TypeKind::FunctionPointerType {
                var f = cast::<FunctionPointerType>(t);
                var ps = "";
                for var i: usize = 0; i < f->params.size(); ++i {
                    if i > 0 { ps += ", "; }
                    ps += self._param_type(f->params[i], f->modes[i], false, "", subst);
                }
                return self.decl(f->return_type, f"(*{name})({ps})", subst);
            }
            case TypeKind::GenericParamType {
                return self._join(self._gparam(cast::<GenericParamType>(t), subst), name);
            }
            case TypeKind::OpaqueFFIType {
                var o = cast::<OpaqueFFIType>(t);
                return self._join(self.imm_name(o->name, self._cg->tu->fid), name);
            }
            case TypeKind::NullableType { ICE_FAIL("CXXSpell: T? reached codegen; NullableTypeLowering must reduce it first"); }
            case TypeKind::TupleType  { ICE_FAIL("CXXSpell: tuple type reached codegen; no lowering exists yet"); }
            default {
                ICE_FAIL(f"CXXSpell: {to_string(t->kind)} is not a canonical kind");
            }
        }
        return "";
    }

    /// A parameter's C++ type from its mode (AST/ParamMode.k rules, as
    /// EmitIR documents them). \p is_const is the `const x: T` marker.
    fn param_type(self, p: *ParamDecl, subst: *InstanceEntry = &null) -> string {
        if p->is_pack {
            ICE_IF(p->pack_type == &null, "CXXSpell: pack parameter with no slice type; CallLowering stamps it");
            return (("const ") if (p->is_const) else ("")) + self._type(p->pack_type, subst);
        }
        return self._param_type(p->type_, p->mode, p->is_const, "", subst);
    }

    /// `type name` for a parameter, name folded into the declarator for
    /// EVERY type, never `param_type(p) + " " + name`: a function pointer
    /// spelled that way is `U(*)(T) f`, which clang reads as a cast-like
    /// expression ("expected ')'", "undeclared identifier 'f'"); the name
    /// belongs inside, `U (*f)(T)`. An array is still its own branch:
    /// `[T; N]` is passed by reference (`const T (&xs)[N]` / `T (&xs)[N]`),
    /// never by value (StmtTyping rejects that). Empty \p name is the
    /// abstract form.
    fn param_decl(self, p: *ParamDecl, name: string, subst: *InstanceEntry = &null) -> string {
        var c = (p->type_->canonical) if (p->type_ != &null) else (&null);
        if (!p->is_pack) && (c != &null) && (canon_unqual(c)->kind == TypeKind::FixedArrayType) {
            ICE_IF((p->mode == ParamMode::Value) && (!p->is_const),
                "CXXSpell: array parameter by value; StmtTyping must reject it");
            var s = self.decl(canon_unqual(c), "&" + name, subst);
            return (("const " + s) if (p->is_const) else (s));
        }
        if p->is_pack {
            var s = self.param_type(p, subst);
            if name.size() > 0 { s += " " + name; }
            return s;
        }
        return self._param_type(p->type_, p->mode, p->is_const, name, subst);
    }

    /// The mode's reference and the const marker folded into decl(), so a
    /// name lands inside the declarator: `@inout` on a function pointer is
    /// `U (*&f)(T)`, which decl() brackets as it does any `*`/`&` declarator.
    priv fn _param_type(self, t: *Type, mode: ParamMode, is_const: bool, name: string, subst: *InstanceEntry) -> string {
        if mode == ParamMode::Inout { return self.decl(t, self._ref_declarator("&", name), subst); }
        if mode == ParamMode::Move  { return self.decl(t, self._ref_declarator("&&", name), subst); }
        if is_const {
            // `const T&` iff a non-generic record; `const T` otherwise.
            var c = t->canonical;
            if (c != &null) && (c->kind == TypeKind::RecordType) && (!c->is_dependent()) {
                return "const " + self.decl(t, self._ref_declarator("&", name), subst);
            }
            return "const " + self.decl(t, name, subst);
        }
        return self.decl(t, name, subst);
    }

    /// `& name`, keeping the `T& x` spelling the printed C++ has always had
    /// (and that tests match); bare `&` for the abstract form.
    priv fn _ref_declarator(self, sigil: string, name: string) -> string {
        if name.size() == 0 { return sigil; }
        return sigil + " " + name;
    }

    /// `<a, b>` from an instance's args or a pattern's own params.
    fn args_str(self, args: *vec::<*Type>, subst: *InstanceEntry = &null) -> string {
        var s = "<";
        for var i: usize = 0; i < args->size(); ++i {
            if i > 0 { s += ", "; }
            s += self._type((*args)[i], subst);
        }
        s += ">";
        return s;
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
        s += "> ";
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

    priv fn _record(self, r: *RecordType, subst: *InstanceEntry) -> string {
        var d = r->decl;
        ICE_IF(d == &null, "CXXSpell: RecordType with no decl");
        ICE_IF(isa::<InterfaceDecl>(d), "CXXSpell: an interface has no C++ type; witnesses are not emitted yet");
        if decl_is_imported(d) { return decl_cxx_spelling(d); }

        // An instance shell names its PRIMARY plus the registry's args.
        if decl_is_instance(d) {
            var e = self._cg->instances->entry_of(d);
            ICE_IF(e == &null, "CXXSpell: instance shell with no registry entry");
            return self.qual_name(e->primary) + self.args_str(&(e->args), subst);
        }
        var s = self.qual_name(d);
        if r->args.size() > 0 {
            var v = vec::<*Type>();
            for var i: usize = 0; i < r->args.size(); ++i { v.push_back(r->args[i]); }
            s += self.args_str(&v, subst);
        }
        return s;
    }

    priv fn _gparam(self, g: *GenericParamType, subst: *InstanceEntry) -> string {
        ICE_IF(g->owner == &null, "CXXSpell: canonical generic param with no owner");
        var owner = CXXSpell::rep(g->owner);
        var t = self.subst_for(g, subst);
        if t != &null { return self._type(t, &null); }
        ICE_IF(g->is_pack, "CXXSpell: pack parameter in a non-expansion position");
        var gps = decl_generic_params(owner);
        ICE_IF(static_cast::<usize>(g->param_index) >= gps.size(), "CXXSpell: generic param index out of range");
        return self.imm_name(gps[static_cast::<usize>(g->param_index)]->name.imm, CXXSpell::fid_of(owner));
    }
}