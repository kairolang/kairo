/// --- The Kairo Project -------------------- Codegen/Emit/SpellFacts.k --- ///
///
///   Speller, part: declaration facts. A declaration's C++ visibility and
///   access, its integer widths, whether it is a special member, the
///   representative a redeclaration chain is spelled from, the TU and file it
///   belongs to, the raw spelling of its name, and the attributes, linkage and
///   thread-local model its declaration carries.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "Native/Types.hh"
ffi "c++" import "vector"

import API::LinkABI::{
    CALL_CONV_PRESERVE_ALL,
    CALL_CONV_PRESERVE_MOST,
    CALL_CONV_PRESERVE_NONE,
}
import AST::AttrFacts::AttrFacts
import AST::Context::DeclContext::{
    DeclContext,
    DeclContextKind,
}
import AST::Context::TranslationUnit::TranslationUnit
import AST::DeclFacts
import AST::Kind::DeclKind::DeclKind
import AST::Kind::TypeKind::TypeKind
import AST::LangItems::{
    LowerTargets,
    builtin_root_name,
    std_root_name,
    std_root_spelling,
}
import AST::Node::Base::{
    Decl,
    Type,
}
import AST::Node::CanonicalNodes::{
    BuiltinKind, BuiltinType, QUAL_CONST, QualifiedType, RecordType, builtin_info, canon_unqual,
}
import AST::Node::Casting::{
    cast,
    dyn_cast,
    isa,
}
import AST::Node::Declarations
import AST::Node::Expressions::{
    ParenExpr,
    UnaryOperatorExpr,
}
import AST::Node::PrimaryExpressions::{
    BooleanLiteralExpr,
    CharacterLiteralExpr,
    FloatingLiteralExpr,
    IntegerLiteralExpr,
    NullLiteralExpr,
}
import AST::Node::Types::{
    CXXLValueRefType,
    CXXRValueRefType,
    PointerType,
}
import Codegen::Emit::Spell::{
    Speller,
    VIS_INTERNAL,
    VIS_NONE,
    VIS_PRIV,
    VIS_PROT,
    VIS_PUB,
}
import Codegen::Emit::SpellRecords
import Codegen::Emit::SpellScopes
import Codegen::Emit::SpellTypes
import Location::SourceRange::SourceRange
import Resolution::ModulePath::header_path_of
import Support::Ascii::is_ident_char
import Support::Escape::c_string_literal
import Token::Token::Token
import Token::TokenKind::TokenKind
import Token::TokenText::TokenText

extend Speller {
    /// # Decl facts

    /// THE visibility read. One line to fix if the mixin spells it otherwise.
    static fn vis_of(d: unsafe *Decl) -> u8 {
        if d == &null {
            return VIS_NONE()
        }

        return d->visibility as u8
    }

    /// The C++ access a record member is written at: Kairo's own, `priv` as
    /// `private:` and `prot` as `protected:` -- the record befriends its
    /// file's entities (EmitPlan::file_friends), which is how C++ says
    /// "this file" -- with VIS_NONE left for InterfaceEmitter::_access to
    /// default (a class's variables private, the rest public). Public
    /// whatever the Kairo visibility:
    ///
    ///   - the special members (a transfer constructor, the destructor):
    ///     compiler-made aggregates and prelude templates in other
    ///     namespaces copy, move and destroy user values (tuple structs, ADT
    ///     payloads, `Null<T>`, `__kairo_fn`, `__kairo_destroy_at`) and
    ///     cannot all be befriended; private, the probes they use
    ///     (`__is_constructible`, a `requires` on the copy) turn false
    ///     silently. AccessCheck still enforces them in Kairo.
    ///   - an instance field of a struct, a union, or a class that emits no
    ///     constructor: such a record is a C++ aggregate, built from a named
    ///     initializer as designated initializers, which a private field
    ///     forbids even inside a friend; and a struct is the C ABI's shape,
    ///     which MSVC returns through a hidden pointer once a field is
    ///     private.
    ///   - `internal`, which is module-wide like `pub` to C++.
    ///
    /// A member the compiler made keeps the access it was made with.
    fn cxx_vis(self, d: unsafe *Decl) -> u8 {
        if d == &null {
            return VIS_NONE()
        }

        var v = Speller::vis_of(d)
        if d->is_implicit {
            return v
        }

        var unsafe *r = Speller::rep(d)
        if v == VIS_NONE() && r != &null && r != d {
            v = Speller::vis_of(r)
        }

        if v == VIS_INTERNAL() {
            return VIS_PUB()
        }

        var unsafe *dc    = d->semantic_dc
        var unsafe *owner = if (dc != &null) => (dc->owner_decl()) else => &null
        if owner == &null {
            return v
        }

        var unsafe *f = dyn_cast<Declarations::FunctionDecl>(d)
        if f != &null && self.is_special_member(f, owner) {
            return VIS_PUB()
        }

        var unsafe *fd = dyn_cast<Declarations::FieldDecl>(d)
        if fd != &null && !fd->is_static() && self.is_aggregate_record(owner) {
            return VIS_PUB()
        }

        return v
    }

    /// `t` is a record whose C++ spelling names, in itself or in a template
    /// argument, a private or protected member type of a C++ class (an
    /// iterator `begin()` returns, a `SpecIterator` a range is over). C++
    /// code reaches such a type only through `auto`; Kairo's AccessCheck
    /// rightly accepts the inferred local, since its author never wrote the
    /// name, so a spelling of it would make clang refuse what Kairo accepted
    /// (I003E). Kairo records never qualify: their access is a friend away.
    fn names_hidden_member(self, t: unsafe *Type) -> bool {
        if t == &null || t->canonical == &null {
            return false
        }

        var unsafe *c = canon_unqual(t->canonical)
        if c == &null {
            return false
        }

        if isa<PointerType>(c) {
            return self.names_hidden_member(cast<PointerType>(c)->pointee)
        }

        if isa<CXXLValueRefType>(c) {
            return self.names_hidden_member(cast<CXXLValueRefType>(c)->referee)
        }

        if isa<CXXRValueRefType>(c) {
            return self.names_hidden_member(cast<CXXRValueRefType>(c)->referee)
        }

        if !isa<RecordType>(c) {
            return false
        }

        var unsafe *r = cast<RecordType>(c)
        var unsafe *d = r->decl
        if d != &null && DeclFacts::decl_is_imported(d) {
            var cands = cxx::std::vector<unsafe *Decl>()
            cands.push_back(d)
            cands.push_back(Speller::rep(d))
            cands.push_back(
                Speller::rep(DeclFacts::decl_pattern(Speller::rep(d))),
            )

            for var i: usize = 0; i < cands.size(); ++i {
                var unsafe *cd = cands[i]
                if cd == &null {
                    continue
                }

                var v = Speller::vis_of(cd)
                if (v == VIS_PRIV() || v == VIS_PROT())
                    && self._record_owner(Speller::rep(cd)) != &null {
                    return true
                }
            }
        }

        for var i: usize = 0; i < r->args.size(); ++i {
            if self.names_hidden_member(r->args[i]) {
                return true
            }
        }

        if r->outer != &null && self.names_hidden_member(r->outer) {
            return true
        }

        return false
    }

    /// `t` canonical and unqualified, through a C++ reference to its
    /// referee: an imported `operator[]` returning `int&` is an int to the
    /// arithmetic on it.
    static fn strip_ref(t: unsafe *Type) -> unsafe *Type {
        if t == &null || t->canonical == &null {
            return &null
        }

        var unsafe *c = canon_unqual(t->canonical)
        var unsafe *r = DeclFacts::peel_ref(c)
        if r != c {
            c = canon_unqual(r->canonical)
        }

        return c
    }

    /// Bits of integer `t` (through a reference); the target's for
    /// usize / isize.
    static fn int_width(t: unsafe *Type) -> u32 {
        var unsafe *c = Speller::strip_ref(t)
        if c == &null {
            return 0
        }

        return c->size_bits as u32
    }

    /// The unsigned type EmitIR does integer `t`'s arithmetic in (the wrap
    /// forms): never narrower than `unsigned int`, or `unsigned short *
    /// unsigned short` promotes to int and overflows there.
    fn wrap_carrier(self, t: unsafe *Type) -> string {
        var w = Speller::int_width(t)
        if w <= (32 as u32) {
            return builtin_info(BuiltinKind::U32)->cxx.copy()
        }

        if w <= (64 as u32) {
            return builtin_info(BuiltinKind::U64)->cxx.copy()
        }

        if w <= (128 as u32) {
            return builtin_info(BuiltinKind::U128)->cxx.copy()
        }

        // `_BitInt` widths: their own unsigned twin. `unsigned __int128`
        // here truncated a u256 / u512 sum to its low 128 bits.
        if w <= (256 as u32) {
            return builtin_info(BuiltinKind::U256)->cxx.copy()
        }

        return builtin_info(BuiltinKind::U512)->cxx.copy()
    }

    /// R, the register width a shift on integer `t` is computed in: 32 for
    /// up to 32 bits, 64 up to 64, 128 up to 128, a wider `_BitInt`'s own
    /// width -- wrap_carrier's thresholds, so
    /// the count mask `R - 1` is what the carrier's own shift instruction
    /// already applies on every target that masks (x86, AArch64, RISC-V).
    static fn reg_width(t: unsafe *Type) -> u32 {
        var w = Speller::int_width(t)
        if w <= (32 as u32) {
            return 32
        }

        if w <= (64 as u32) {
            return 64
        }

        if w <= (128 as u32) {
            return 128
        }

        return w // a `_BitInt` is shifted in its own width.
    }

    /// R_T, the signed integer of width reg_width(`t`): a signed `>>`
    /// sign-extends its left operand to it, so a narrow `i8 >> 9` fills
    /// with the sign rather than shifting zeros in from bit 8.
    fn reg_signed(self, t: unsafe *Type) -> string {
        var r = Speller::reg_width(t)
        if r == (32 as u32) {
            return "int"
        }

        if r == (64 as u32) {
            return builtin_info(BuiltinKind::I64)->cxx.copy()
        }

        if r == (128 as u32) {
            return builtin_info(BuiltinKind::I128)->cxx.copy()
        }

        if r == (256 as u32) {
            return builtin_info(BuiltinKind::I256)->cxx.copy()
        }

        return builtin_info(BuiltinKind::I512)->cxx.copy()
    }

    /// cxx_vis with the default applied: what C++ will see.
    fn cxx_access(self, d: unsafe *Decl) -> u8 {
        var v = self.cxx_vis(d)
        if v != VIS_NONE() {
            return v
        }

        var unsafe *dc    = d->semantic_dc
        var unsafe *owner = if (dc != &null) => (dc->owner_decl()) else => &null
        var is_var = isa<Declarations::FieldDecl>(d) || isa<Declarations::VariableDecl>(d)
        if is_var && owner != &null && isa<Declarations::ClassDecl>(owner) {
            return VIS_PRIV()
        }

        return VIS_PUB()
    }

    /// A transfer constructor or the destructor of `owner`.
    fn is_special_member(self, f: unsafe *Declarations::FunctionDecl, owner: unsafe *Decl) -> bool {
        if f->is_operator {
            return f->op_token.size() > 0 && f->op_token[0].kind == TokenKind::KwFinally
        }

        if f->transfer != Declarations::TransferKind::NotTransfer {
            return true
        }

        if !self.is_ctor_of(f, owner) {
            return false
        }

        // An unmarked one: a single other parameter of the record's own type.
        var other: unsafe *Declarations::ParamDecl = &null
        var n:     usize                           = 0
        for var i: usize = 0; i < f->params.size(); ++i {
            var unsafe *p = f->params[i]
            if p == &null || p->is_self {
                continue
            }

            other = p
            n += 1
        }

        if n != 1 || other->type_ == &null || other->type_->canonical == &null {
            return false
        }

        var unsafe *c = canon_unqual(other->type_->canonical)
        if !isa<RecordType>(c) {
            return false
        }

        return Speller::rep(
            DeclFacts::decl_pattern(Speller::rep(cast<RecordType>(c)->decl)),
        ) == Speller::rep(DeclFacts::decl_pattern(Speller::rep(owner)))
    }

    /// `f` is a constructor of `owner`: a method named after it.
    fn is_ctor_of(self, f: unsafe *Declarations::FunctionDecl, owner: unsafe *Decl) -> bool {
        if f->is_operator || !f->is_method() || owner == &null {
            return false
        }

        return self.leaf(unsafe (f as unsafe *Decl)) == self.leaf(owner)
    }

    /// `d` emits no constructor: a C++ aggregate (a struct or union always
    /// is one to Kairo; a class only with no constructor of any kind).
    fn is_aggregate_record(self, d: unsafe *Decl) -> bool {
        if isa<Declarations::StructDecl>(d) || isa<Declarations::UnionDecl>(d) {
            return true
        }

        if !isa<Declarations::ClassDecl>(d) {
            return false
        }

        var unsafe *c = cast<Declarations::ClassDecl>(d)
        for var i: usize = 0; i < c->methods.size(); ++i {
            var unsafe *m = c->methods[i]
            if m != &null && self.is_ctor_of(m, d) {
                return false
            }
        }

        return true
    }

    /// The entity's representative (redecl canonical).
    static fn rep(d: unsafe *Decl) -> unsafe *Decl {
        if d == &null {
            return &null
        }

        match d->kind {
            case DeclKind::ClassDecl {
                return (cast<Declarations::ClassDecl>(d)->canonical_decl())
            } case DeclKind::StructDecl {
                return (cast<Declarations::StructDecl>(d)->canonical_decl())
            } case DeclKind::UnionDecl {
                return (cast<Declarations::UnionDecl>(d)->canonical_decl())
            } case DeclKind::EnumDecl {
                return (cast<Declarations::EnumDecl>(d)->canonical_decl())
            } case DeclKind::InterfaceDecl {
                return (cast<Declarations::InterfaceDecl>(d)->canonical_decl())
            } case DeclKind::FunctionDecl {
                return (cast<Declarations::FunctionDecl>(d)->canonical_decl())
            } case DeclKind::ModuleDecl {
                return (cast<Declarations::ModuleDecl>(d)->canonical_decl())
            } default {
                return d
            }
        }
    }

    /// The DeclContext a scope-owning decl IS, or null.
    static fn dc_of(d: unsafe *Decl) -> unsafe *DeclContext {
        if d == &null {
            return &null
        }

        match d->kind {
            case DeclKind::ClassDecl {
                return (cast<Declarations::ClassDecl>(d))
            } case DeclKind::StructDecl {
                return (cast<Declarations::StructDecl>(d))
            } case DeclKind::UnionDecl {
                return (cast<Declarations::UnionDecl>(d))
            } case DeclKind::EnumDecl {
                return (cast<Declarations::EnumDecl>(d))
            } case DeclKind::InterfaceDecl {
                return (cast<Declarations::InterfaceDecl>(d))
            } case DeclKind::FunctionDecl {
                return (cast<Declarations::FunctionDecl>(d))
            } case DeclKind::ModuleDecl {
                return (cast<Declarations::ModuleDecl>(d))
            } case DeclKind::ExtensionDecl {
                return (cast<Declarations::ExtensionDecl>(d))
            } default {
                return &null
            }
        }
    }

    /// The TU a DeclContext chain bottoms out in.
    static fn tu_of_dc(dc: unsafe *DeclContext) -> unsafe *TranslationUnit {
        var unsafe *c = dc
        while c != &null {
            if c->dc_kind == DeclContextKind::TranslationUnit {
                return unsafe (c as unsafe *TranslationUnit)
            }

            // Inside a definition of a C++-declared function (a parameter, a
            // local): the file it is written in, as tu_of says.
            if c->dc_kind == DeclContextKind::Function && c->dc_owner != &null {
                var unsafe *of = dyn_cast<Declarations::FunctionDecl>(
                    c->dc_owner,
                )

                if of != &null && Speller::defines_foreign(of) && of->lexical_dc != &null {
                    c = of->lexical_dc
                    continue
                }
            }

            c = c->dc_parent
        }

        return &null
    }

    /// `f` is a Kairo definition of a function C++ declares: an
    /// out-of-line `fn W::at` / `fn ns::f` whose chain starts at an imported
    /// declaration. C++ already has the declaration, so nothing
    /// declares it again; EmitIR::_foreign_def writes the definition in the
    /// C++ declaration's own signature.
    pub static fn defines_foreign(f: unsafe *Declarations::FunctionDecl) -> bool {
        if f == &null || (!f->is_out_of_line()) {
            return false
        }

        var unsafe *first = f->first_decl()
        return first != &null
            && first != f
            && DeclFacts::decl_is_imported(unsafe (first as unsafe *Decl))
    }

    pub static fn tu_of(d: unsafe *Decl) -> unsafe *TranslationUnit {
        if d == &null {
            return &null
        }

        // A Kairo definition of a C++-declared function belongs, for lookup,
        // to the C++ class or namespace; its tokens are this file's. Every
        // name in it (its own, its parameters', its locals') was interned
        // here, so the table is the file's it is written in, not the header's.
        var unsafe *of = dyn_cast<Declarations::FunctionDecl>(d)
        if of != &null && Speller::defines_foreign(of) && d->lexical_dc != &null {
            return Speller::tu_of_dc(d->lexical_dc)
        }

        var unsafe *dc = d->semantic_dc
        if dc == &null {
            dc = d->lexical_dc
        }

        if dc == &null {
            // A scope owner with no parent link (an ExtensionDecl has no
            // semantic_dc): use its own chain, or fid_of answers u32(-1)
            // and friend_scopes_of finds no same-file scope.
            var unsafe *own = Speller::dc_of(d)
            if own != &null {
                dc = own->dc_parent
            }
        }

        return Speller::tu_of_dc(dc)
    }

    pub static fn fid_of(d: unsafe *Decl) -> u32 {
        var unsafe *tu = Speller::tu_of(d)
        if tu == &null {
            return u32::MAX
        }

        return tu->fid
    }

    /// `s` as a C++ narrow string literal, quotes included: printable ASCII
    /// as it is, a quote and a backslash escaped, every other byte octal (three digits,
    /// so a following digit is never read into it).
    static fn c_string(const s: string) -> string {
        return c_string_literal(s)
    }

    /// Where a declaration's C++ tokens are anchored: its name token, or for
    /// an operator (whose `name` is a default Token) the span of its operator
    /// tokens, `[` through `]` for `op []`. op_token always has an element.
    static fn at(d: unsafe *Decl) -> SourceRange {
        var unsafe *f = dyn_cast<Declarations::FunctionDecl>(d)
        if f != &null && f->is_operator {
            var r = f->op_token[0].range
            for var j: usize = 1; j < f->op_token.size(); ++j {
                r = r | f->op_token[j].range
            }

            return r
        }

        var t = DeclFacts::decl_name_tok(d)
        if t.range.is_valid() {
            return t.range
        }

        return d->range
    }

    /// A name token's spelling, read in `fid`'s table (imm_name), or
    /// through the expansion when a macro body wrote it: a wrapped token's
    /// imm is its MacroExpansionInfo record, not an identifier, and read as
    /// one it named whatever identifier sat at that index (`fn get(o: i32)`
    /// declared by `mm!()` in a class came out as `mm(signed int main)`, so
    /// the member was missing and its body's `o` undeclared). A free
    /// function survived only because its uses were spelled the same wrong
    /// way. Every codegen read of a declared name goes through here.
    pub fn tok_name(self, t: Token, fid: u32) -> string {
        if t.kind == TokenKind::TkMacroExpand && self._cg->ctx->tcm != &null {
            var txt = TokenText::resolve(t, self._cg->ctx->tcm)
            return Speller::ident_safe(*txt.get_text())
        }

        return self.imm_name(t.imm, fid)
    }

    /// A decl's name imm indexes ITS OWN TU's table (hard invariant #2).
    pub fn imm_name(self, imm: u32, fid: u32) -> string {
        if imm == u32::MAX {
            return "<?>"
        }

        var unsafe *tcm = self._cg->ctx->tcm
        if tcm == &null {
            return "<?>"
        }

        var unsafe *tbl = tcm->get_imm_table_for_fid(fid)
        if tbl == &null {
            return "<?>"
        }

        return Speller::ident_safe(tbl->get_ident(imm))
    }

    /// A Kairo name as one C++ identifier. Kairo names may carry `#` or
    /// non-ASCII bytes (`#type`, `a#b`, `gr\xC3\xB6\xC3\x9Fe`), which no C++ token can
    /// hold: EmitSink::spell ICEs on them. Each such byte becomes `__xHH`, so
    /// the declaration and every use (both read the name through here) agree
    /// and distinct Kairo names stay distinct (`#op` vs `op#`). Plain
    /// names come back untouched, keeping the no-mangling ABI for them.
    static fn ident_safe(s: string) -> string {
        var clean = true
        for var i: usize = 0; i < s.size(); ++i {
            var c  = s[i]
            var ok = is_ident_char(c)
            if !ok {
                clean = false
                break
            }
        }

        if clean {
            return s
        }

        var hex = "0123456789ABCDEF"
        var out = ""
        for var i: usize = 0; i < s.size(); ++i {
            var c  = s[i]
            var ok = is_ident_char(c)
            if ok {
                out.push_back(c)
                continue
            }

            var b = ((c) as u32)
            out += "__x"
            out.push_back(hex[(b >> 4) as usize])
            out.push_back(hex[(b & 15) as usize])
        }

        return out
    }

    /// `geo/vec.hh` for the TU's module path.
    fn header_path(self, tu: unsafe *TranslationUnit) -> string {
        return header_path_of(self.module_segments(tu))
    }

    /// `extern "C" ` for a Kairo-authored `ffi "c"` free function, else "".
    /// It leads the declaration AND the definition: the symbol must be the
    /// bare name (a linker script's `Reset_Handler`, a C caller's), never
    /// the namespace-mangled one. Either redecl may carry the prefix, so the
    /// chain's canonical is asked too.
    static fn c_linkage(f: unsafe *Declarations::FunctionDecl) -> string {
        if f == &null {
            return ""
        }

        var unsafe *c = f->canonical_decl()
        if f->is_ffi_c() || c != &null && c->is_ffi_c() {
            return "extern \"C\" "
        }

        return ""
    }

    /// The C++ attributes of `@hot_path` / `@cold_path` / `@pure` / `const fn`
    /// and the calling convention, each with a trailing space, or "". The declaration (InterfaceEmitter)
    /// and the definition (EmitIR) both call this, so the two heads agree.
    /// Either redecl may carry the Kairo attribute, so the chain's canonical
    /// is asked too, as c_linkage does. `const` implies the weaker `pure`.
    static fn fn_attrs(f: unsafe *Declarations::FunctionDecl) -> string {
        if f == &null {
            return ""
        }

        var unsafe *c = f->canonical_decl()
        var        s  = ""
        if f->hot_path || c != &null && c->hot_path {
            s += LowerTargets::attr_hot()
        }

        if f->no_inline || c != &null && c->no_inline {
            s += LowerTargets::attr_noinline()
        }

        if f->cold_path || c != &null && c->cold_path {
            s += LowerTargets::attr_cold()
        }

        // -finfer-purity's verdict (FnPurityCheck::settle) is spelled like a
        // written promise; it is stamped on every link, so each head agrees.
        // Either attribute is `willreturn` to clang, so it is spelled only
        // on a function whose termination is proven.
        var inferred = f->inferred_purity
        if inferred == (Declarations::PurityLevel::None as u8) && c != &null {
            inferred = c->inferred_purity
        }

        var proven = f->purity_proof == (Declarations::PurityProof::Proven as u8)
            || c != &null && c->purity_proof == (Declarations::PurityProof::Proven as u8)
        var is_const = f->is_const_fn
            || c != &null && c->is_const_fn
            || inferred == (Declarations::PurityLevel::Const as u8)
        var is_pure = f->is_pure
            || c != &null && c->is_pure
            || inferred == (Declarations::PurityLevel::Pure as u8)
        if proven && is_const {
            s += LowerTargets::attr_const()
        } else if proven && is_pure {
            s += LowerTargets::attr_pure()
        }

        // The convention, from whichever link wrote it: RedeclMerge holds
        // the chain to one value, so either answers.
        var cc = f->call_conv
        if cc == 0 && c != &null {
            cc = c->call_conv
        }

        s += Speller::call_conv_attr(cc)
        return s
    }

    /// The C++ attribute of a FunctionDecl::call_conv / FunctionPointerType::
    /// call_conv value, with its trailing space, or "" for the default.
    pub static fn call_conv_attr(cc: u8) -> string {
        if cc == CALL_CONV_PRESERVE_MOST {
            return LowerTargets::attr_preserve_most()
        }

        if cc == CALL_CONV_PRESERVE_ALL {
            return LowerTargets::attr_preserve_all()
        }

        if cc == CALL_CONV_PRESERVE_NONE {
            return LowerTargets::attr_preserve_none()
        }

        return ""
    }

    /// `[thread_local] T const name` for a namespace-scope variable: the one
    /// spelling the interface's `extern` declaration and EmitIR's definition
    /// both use, because C++ rejects a redeclaration whose type differs.
    /// Never `static` -- at namespace scope that is internal linkage, and
    /// every object there already has static storage duration. The binding's
    /// `const` goes in the declarator so it qualifies the variable itself:
    /// `int *const p`, not `const int *p`. `eval` is `const` here too; the
    /// definition adds `constexpr` (`extern constexpr` is ill-formed).
    /// `T __kairo_ginit_x()`: the thunk that initializes `v` when its
    /// initializer reaches a private member (EmitIR::_global_var); its
    /// definition and the friend line (InterfaceEmitter::_friends) share it.
    fn ginit_decl(self, v: unsafe *Declarations::VariableDecl) -> string {
        return self.decl(
            v->type_,
            LowerTargets::global_init_thunk(
                self.leaf(unsafe (v as unsafe *Decl)),
            ) + "()",
        )
    }

    /// A `thread` global whose initializer is a literal of a scalar type.
    /// Without `constinit` an importer's `extern thread_local`
    /// cannot know the definition needs no dynamic initialization, so clang
    /// reaches every access through the TLS wrapper, which tests the weak
    /// `_ZTH` init function (cmp, je, call). C++ wants `constinit` on the
    /// initializing declaration whenever any declaration has it, so the
    /// answer is a function of the decl alone and global_var spells it on
    /// both. Literal-only on purpose: a false yes is a clang error, and
    /// anything EmitIR spells as a wrap form or a thunk call stays dynamic.
    /// Never `eval`, whose definition is already `inline constexpr`.
    static fn thread_constinit(v: unsafe *Declarations::VariableDecl) -> bool {
        if v == &null || !v->is_thread || v->is_eval() {
            return false
        }

        if v->type_ == &null || v->type_->canonical == &null || v->init == &null {
            return false
        }

        var unsafe *t = canon_unqual(v->type_->canonical)
        var unsafe *e = v->init
        while e != &null && isa<ParenExpr>(e) {
            e = cast<ParenExpr>(e)->inner
        }

        if e == &null {
            return false
        }

        if isa<PointerType>(t) {
            return isa<NullLiteralExpr>(e) && cast<NullLiteralExpr>(e)->is_ref
        }

        if !isa<BuiltinType>(t) {
            return false
        }

        var unsafe *u = dyn_cast<UnaryOperatorExpr>(e)
        if u != &null && u->op_token.kind == TokenKind::OpMinus {
            e = u->operand
            while e != &null && isa<ParenExpr>(e) {
                e = cast<ParenExpr>(e)->inner
            }

            return e != &null && (isa<IntegerLiteralExpr>(e) || isa<FloatingLiteralExpr>(e))
        }

        return isa<IntegerLiteralExpr>(e)
            || isa<FloatingLiteralExpr>(e)
            || isa<BooleanLiteralExpr>(e)
            || isa<CharacterLiteralExpr>(e)
    }

    /// Which interface PCH `tu` may share (Compiler/Spec/Codegen.md#the-interface-pch):
    /// TUs of one flavour spell every declaration with the same text, so
    /// one stream serves them all. This is the ONE place a declaration's
    /// spelling depends on the TU writing it rather than on the decl and the
    /// build's options -- tls_model below, toolchain TU or not -- and a new
    /// such dependence must be folded in here, or a TU would load a
    /// declaration spelled for another.
    pub fn interface_flavour(self, tu: unsafe *TranslationUnit) -> u8 {
        return if (self._toolchain_tu(tu)) => (1 as u8) else => (0 as u8)
    }

    /// The TU is builtin's or std's: the toolchain's own objects, which
    /// --kairo-lib builds once and every later link reuses.
    fn _toolchain_tu(self, tu: unsafe *TranslationUnit) -> bool {
        if tu == &null {
            return false
        }

        var segs = self.module_segments(tu)
        if segs.size() == 0 {
            return false
        }

        if segs[0] == builtin_root_name() || segs[0] == std_root_name() {
            return true
        }

        return segs.size() > 1 && segs[0] == "kairo" && segs[1] == std_root_spelling()
    }

    /// The TLS model attribute of a `thread` global, or "". Every object is
    /// compiled PIC, which on its own makes each access general-dynamic: a
    /// `__tls_get_addr` call, so a leaf like `scope_top`'s reader saves and
    /// restores registers around it even after the linker relaxes the call
    /// away. Decided by the TU being written, not only the decl:
    ///   - a builtin / std TU: initial-exec, for its own globals and every
    ///     one it declares. --kairo-lib builds these objects once for every
    ///     later link, a --shared one included, and initial-exec is valid in
    ///     any image they land in (relaxed to a constant in an executable).
    ///     Never --tls-model: the cache key does not carry it.
    ///   - a user TU linked into an executable (static or PIE): local-exec,
    ///     for its own globals AND the toolchain's it declares extern. Every
    ///     object of that link, the Kairo library's included, is linked
    ///     statically (the library is objects or an archive, never a shared
    ///     object), so every offset is a link-time constant. This is the one
    ///     that matters: create<T> / destroy<T> are instantiated in the user's
    ///     TU, and initial-exec there costs a `mov $off,%rax` before each
    ///     `%fs:(%rax)` access that local-exec folds into the operand. The
    ///     definition staying initial-exec is fine: the model is the access
    ///     sequence of the TU that writes it, and the linker resolves both
    ///     against the same TLS block.
    ///   - a user TU otherwise (--shared, -c): initial-exec for the
    ///     toolchain's (as their own TU spells them), none for the user's, so
    ///     general-dynamic. A dlopen'd library's TLS has no static offset, and
    ///     an object built with -c may end up in one.
    /// An explicit --tls-model wins over both user-TU defaults.
    /// x32: local-exec wherever the rules above say initial-exec. lld
    /// relaxes initial-exec to local-exec only in its REX.W movq / addq
    /// form, and x32's access is a REX-less movl, so a static link of the
    /// library failed. The cost: the library's objects cannot go into
    /// an x32 shared object.
    /// ELF only: elsewhere the attribute either means nothing (Mach-O,
    /// wasm) or is not the mechanism (COFF).
    fn tls_model(self, v: unsafe *Declarations::VariableDecl) -> string {
        if v == &null || !v->is_thread || self._cg == &null || !self._cg->opts.elf {
            return ""
        }

        var ie = if (self._cg->opts.x32) => ("local-exec") else => "initial-exec"
        if self._toolchain_tu(self._cg->tu) {
            return LowerTargets::attr_tls_model(ie)
        }

        if !self._cg->opts.tls_model.is_empty() {
            return LowerTargets::attr_tls_model(self._cg->opts.tls_model)
        }

        if self._cg->opts.exe_link {
            return LowerTargets::attr_tls_model("local-exec")
        }

        if self._toolchain_tu(Speller::tu_of(unsafe (v as unsafe *Decl))) {
            return LowerTargets::attr_tls_model(ie)
        }

        return ""
    }

    fn global_var(self, v: unsafe *Declarations::VariableDecl) -> string {
        var        nm = self.leaf(unsafe (v as unsafe *Decl))
        var unsafe *c = if (v->type_ != &null) => (v->type_->canonical) else => &null
        var already = c != &null
            && c->kind == TypeKind::QualifiedType
            && (cast<QualifiedType>(c)->quals & QUAL_CONST) != 0
        if (v->is_const() || v->is_eval()) && !already {
            nm = "const " + nm
        }

        var s = if (v->is_thread) => ("thread_local ") else => ""
        if Speller::thread_constinit(v) {
            s = "constinit " + s
        }

        // `@align(N)`: on the `extern` declaration and the definition alike,
        // which C++ requires to agree.
        s = AttrFacts::decl_align_attr(v) + s
        // The TLS model goes after the declarator, so it binds to the
        // variable whatever the type's shape (pointer, array), before an
        // `= init` either way.
        return s + self.decl(v->type_, nm) + self.tls_model(v)
    }
}
