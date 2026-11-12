/// --- The Kairo Project ---------------------- Codegen/Emit/CXXSpell.k --- ///
///
///   \brief The ONE C++ speller: canonical type -> text, decl -> qualified
///          name, decl -> namespace path. Both emitters call it; there is
///          no second copy anywhere, because two spellers drift and the
///          drift is a silent link error.
///
///   \par Everything is derived, nothing is stored per use
///     A decl's namespace is its semantic DeclContext chain -- `module X`
///     names on the way up, then the owning TU's module_base at the root
///     (Compiler/Spec/Imports.md invariant 9). An alias never appears
///         (invariant 10).
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
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "Native/Types.hh"
ffi "c++" import "vector"

import AST::AttrFacts::AttrFacts
import AST::Context::ASTContext::ASTContext
import AST::Context::DeclContext::{
    DeclContext,
    DeclContextKind,
}
import AST::Context::InstantiationRegistry::InstanceEntry
import AST::Context::SymbolTable::DeclName
import AST::Context::TranslationUnit::TranslationUnit
import AST::CxxReservedWords::is_cxx_keyword
import AST::DeclFacts
import AST::Kind::DeclKind::{
    DeclKind,
    to_string,
}
import AST::Kind::TypeKind::{
    TypeKind,
    to_string,
}
import AST::LangItems::{
    LowerTargets,
    builtin_root_name,
    entry_point_name,
    std_root_name,
    std_root_spelling,
    to_string,
}
import AST::Node::Base::{
    Decl,
    Expr,
    Type,
}
import AST::Node::CanonicalNodes::{
    AssocType,    BuiltinKind,  BuiltinType, QUAL_CONST, QUAL_VOLATILE, QualifiedType, RecordType,
    builtin_info, canon_unqual,
}
import AST::Node::Casting::{
    cast,
    dyn_cast,
    isa,
}
import AST::Node::Declarations
import AST::Node::Expressions::{
    AlignOfExpr,   BinaryOperatorExpr, CallExpr,       ConstraintExpr, ParenExpr, SizeOfExpr,
    TypeTraitExpr, UnaryOperatorExpr,  type_trait_cxx,
}
import AST::Node::PrimaryExpressions::{
    BooleanLiteralExpr,
    CharacterLiteralExpr,
    FloatingLiteralExpr,
    IntegerLiteralExpr,
    NamedIdentExpr,
    NullLiteralExpr,
}
import AST::Node::Statements::ReturnStmt
import AST::Node::Types::{
    CXXLValueRefType, CXXRValueRefType, ChainType,     FixedArrayType, FunctionPointerType,
    GenericParamType, NullableType,     OpaqueFFIType, PointerType,    TypeExpr,
    ValueOp,
}
import AST::OperatorFacts::OperatorFacts
import AST::ParamMode::ParamMode
import Codegen::CodegenContext::CodegenContext
import Codegen::CodegenICE::codegen_ice
import Location::SourceRange::SourceRange
import Resolution::ModulePath::header_path_of
import Token::Token::Token
import Token::TokenKind::TokenKind
import Token::TokenText::TokenText

/// VisibilityKind enumerator values (AST/Mixin/Annotation.k): None,
/// Private, Protected, Public, Internal. Read through vis_of() and nowhere
/// else. InheritEdge's comment claims 0 none / pub / prot / priv; that
/// order is wrong, and trusting it inverted the header's pub filter.
pub eval fn VIS_NONE() -> u8 {
    return 0
}

pub eval fn VIS_PRIV() -> u8 {
    return 1
}

pub eval fn VIS_PROT() -> u8 {
    return 2
}

pub eval fn VIS_PUB()  -> u8 {
    return 3
}

pub eval fn VIS_INTERNAL() -> u8 {
    return 4
}

/// # Top-level namespace spellings
///
/// A module's FIRST namespace segment sits at C++ global scope, where the
/// TU also holds whatever its headers declare there (`::malloc`, `::exit`)
/// and the program's `int main`. `namespace malloc {` beside `void
/// *malloc(size_t)` is "redefinition of 'malloc' as different kind of
/// symbol". Such a segment is renamed by ONE fixed rule, the same shape the
/// keyword rule in cxx_segment already has: append `_` (`malloc` ->
/// `malloc_`), and keep appending while the result is still taken
/// (`malloc__`). Taken means: an entry-point name (is_entry_point_name), a
/// non-namespace global some header of the build declares (a namespace is
/// only reopened, never a clash), or another module's own top segment.
/// Only the C++ spelling moves; Kairo source still writes `main::x`
/// (Compiler/Spec/Codegen.md, Top-level namespace collisions).
///
/// Decided ONCE per build, on the driver thread at the header join
/// (FrontendAction::_sema -> decide_tops), from the build's header sets,
/// before any stand-in or TU is spelled; recorded here so that every TU,
/// every CXXSpell (TypeExport's sink-less ones too) and every later input of
/// the same run read the same answer -- a name that differed between two
/// TUs would be a link error. A segment decided once is never re-decided.
/// Process-wide because a kairo/kcc process is one build.
///
/// is_entry_point_name: the names an emitted TU may hold at global scope
/// besides its headers' declarations: the program's entry point and every
/// other platform's (Windows' wide, GUI and DLL entries; the ELF
/// `_start`). Fixed, not asked of clang: `int main` is the TU's own
/// definition, so no header declares it, and the others must not depend on
/// which target a module happened to be built for.
pub fn is_entry_point_name(const s: string) -> bool {
    return s == entry_point_name()
        || s == "wmain"
        || s == "WinMain"
        || s == "wWinMain"
        || s == "DllMain"
        || s == "_start"
}

class CxxNsTops {
    priv var _mu: kairo::std::Mutex
    /// _from.size(): read without the lock, so a build with no renames (the
    /// common case) never takes it on the hot path (_ns_from runs per name).
    priv var _n:       kairo::std::Atomic<u32>  = kairo::std::Atomic<u32>(0)
    priv var _from:    cxx::std::vector<string> ///< renamed top segments, as cxx_segment spells them.
    priv var _to:      cxx::std::vector<string> ///< parallel: their C++ spelling.
    priv var _decided: cxx::std::vector<string> ///< every segment decided, renamed or not.

    fn CxxNsTops(self) { }

    /// \p s's C++ spelling: the recorded one, else the entry-point rule
    /// alone (no build decided it: a tool's bare parse, or a TU outside the
    /// graph), which is also what the build's decision gives such a name
    /// whenever no header claims its `_` forms.
    fn spelling(self, const s: string) -> string {
        if self._n.load() != 0 {
            var lock = kairo::std::LockGuard(self._mu)
            for var i: usize = 0; i < self._from.size(); ++i {
                if self._from[i] == s {
                    return self._to[i]
                }
            }
        }

        if !is_entry_point_name(s) {
            return s
        }

        var c = s + "_"
        while is_entry_point_name(c) {
            c += "_"
        }

        return c
    }

    /// The Kairo top segment whose C++ spelling is \p c (identity if none).
    fn kairo_of(self, const c: string) -> string {
        if self._n.load() != 0 {
            var lock = kairo::std::LockGuard(self._mu)
            for var i: usize = 0; i < self._to.size(); ++i {
                if self._to[i] == c {
                    return self._from[i]
                }
            }
        }

        return c
    }

    fn decided(self, const s: string) -> bool {
        var lock = kairo::std::LockGuard(self._mu)
        for var i: usize = 0; i < self._decided.size(); ++i {
            if self._decided[i] == s {
                return true
            }
        }

        return false
    }

    /// \p c is already some OTHER segment's renamed spelling.
    fn is_target(self, const c: string) -> bool {
        var lock = kairo::std::LockGuard(self._mu)
        for var i: usize = 0; i < self._to.size(); ++i {
            if self._to[i] == c {
                return true
            }
        }

        return false
    }

    fn record(self, const s: string, const c: string) {
        var lock = kairo::std::LockGuard(self._mu)
        self._decided.push_back(s)
        if c == s {
            return
        }

        self._from.push_back(s)
        self._to.push_back(c)
        self._n.store((self._from.size() as u32))
    }
}

/// The one instance (see CxxNsTops).
var _NS_TOPS: CxxNsTops = CxxNsTops()

pub class CXXSpell {
    priv var _cg: unsafe *CodegenContext

    /// While EmitWitness spells a witness member: the interface whose bare
    /// `Self` (an argument-less record of it) is spelled \c self_spelling --
    /// `__kairo_Self` in the primary, the conformer in a specialization.
    /// Null everywhere else, where an interface type is still an ICE.
    pub var self_iface: unsafe *Decl = &null
    /// While EmitWitness writes a CONCEPT: the witness an associated type
    /// over Self is a member of, spelled (`::ns::I_witness<__kairo_Self>`).
    /// Empty inside a specialization, whose own `using Node = ...;` the
    /// bare name finds.
    pub var assoc_self_qual: string = ""
    pub var self_spelling:   string = ""
    /// While InterfaceEmitter writes a pack-expanded variant's payload struct
    /// (a template over one element): the enum's pack parameter, which
    /// spells there as that element, LowerTargets::adt_pack_elem(). Null
    /// everywhere else.
    pub var pack_alias: unsafe *Declarations::GenericParamDecl = &null
    /// While InterfaceEmitter writes the payload structs of an ADT whose
    /// layout holds a `void` argument as an empty struct (EnumDecl::
    /// adt_void_unit, the Panic lang item): that enum, whose own non-pack
    /// parameters spell as `::__kairo_nv<T>` there. Null everywhere else.
    pub var void_unit_owner: unsafe *Decl = &null
    /// While set (EmitPlan's instance key): `usize` / `isize` spell
    /// as the fixed-width builtin they ARE in C++ on this target
    /// (size_fold), so two Kairo instances that are one C++ entity spell
    /// alike. sizes_folded counts the spellings that changed. Never set
    /// while emitting: the emitted spelling stays `decltype(sizeof(0))`,
    /// which is right on every target.
    /// A local's declarator is being spelled (EmitIR::_var_decl): a record
    /// that C++ would refuse to name here is written `auto` instead.
    pub var auto_hidden:  bool = false
    pub var fold_sizes:   bool = false
    pub var sizes_folded: u32  = 0
    /// While set, the template parameters of this decl are spelled
    /// `__kairo_ft<i>` (LowerTargets::friend_tparam), head, signature and
    /// requires-clause alike: a friend declaration of a generic function or
    /// record inside a class template must not redeclare the class's own
    /// parameter names ([temp.local]/6), and a redeclaration's parameters
    /// may be named anything (InterfaceEmitter::_friends).
    pub var rename_tparams: unsafe *Decl = &null
    /// rename_tparams's parameters (template_params), filled on first use:
    /// a parameter is matched by entity, so a default-argument thunk spelling
    /// its function's parameters is renamed with them.
    priv var _renamed:     cxx::std::vector<unsafe *Declarations::GenericParamDecl>
    priv var _renamed_for: unsafe *Decl                                             = &null
    /// While set (EmitPlan::dump): a top namespace segment is spelled as
    /// the Kairo module names it, not as its renamed C++ form (CxxNsTops),
    /// so a dump shows `::main::f` for the module the source calls `main`.
    /// Never set while emitting.
    pub var kairo_top: bool = false

    fn CXXSpell(self) {
        self._cg = &null
    }

    pub fn CXXSpell(self, cg: unsafe *CodegenContext) {
        self._cg = cg
    }

    /// ICE naming the Kairo source at \p at (CodegenICE). A canonical type
    /// carries no range; pass the written node or the owning decl's.
    priv fn _ice(self, at: SourceRange, const msg: string) {
        codegen_ice(self._cg->ctx, at, msg)
    }

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
    ///     payloads, `Nullable<T>`, `__kairo_fn`, `__kairo_destroy_at`) and
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

        var v = CXXSpell::vis_of(d)
        if d->is_implicit {
            return v
        }

        var unsafe *r = CXXSpell::rep(d)
        if v == VIS_NONE() && r != &null && r != d {
            v = CXXSpell::vis_of(r)
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

    /// \p t is a record whose C++ spelling names, in itself or in a template
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
            cands.push_back(CXXSpell::rep(d))
            cands.push_back(
                CXXSpell::rep(DeclFacts::decl_pattern(CXXSpell::rep(d))),
            )

            for var i: usize = 0; i < cands.size(); ++i {
                var unsafe *cd = cands[i]
                if cd == &null {
                    continue
                }

                var v = CXXSpell::vis_of(cd)
                if (v == VIS_PRIV() || v == VIS_PROT())
                    && self._record_owner(CXXSpell::rep(cd)) != &null {
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

    /// \p t canonical and unqualified, through a C++ reference to its
    /// referee: an imported `operator[]` returning `int&` is an int to the
    /// arithmetic on it.
    static fn strip_ref(t: unsafe *Type) -> unsafe *Type {
        if t == &null || t->canonical == &null {
            return &null
        }

        var unsafe *c = canon_unqual(t->canonical)
        if c != &null && isa<CXXLValueRefType>(c) {
            c = canon_unqual(cast<CXXLValueRefType>(c)->referee->canonical)
        }

        if c != &null && isa<CXXRValueRefType>(c) {
            c = canon_unqual(cast<CXXRValueRefType>(c)->referee->canonical)
        }

        return c
    }

    /// Bits of integer \p t (through a reference); the target's for
    /// usize / isize.
    static fn int_width(t: unsafe *Type) -> u32 {
        var unsafe *c = CXXSpell::strip_ref(t)
        if c == &null {
            return 0
        }

        return c->size_bits as u32
    }

    /// The unsigned type EmitIR does integer \p t's arithmetic in (the wrap
    /// forms): never narrower than `unsigned int`, or `unsigned short *
    /// unsigned short` promotes to int and overflows there.
    fn wrap_carrier(self, t: unsafe *Type) -> string {
        var w = CXXSpell::int_width(t)
        if w <= (32 as u32) {
            return builtin_info(BuiltinKind::U32)->cxx
        }

        if w <= (64 as u32) {
            return builtin_info(BuiltinKind::U64)->cxx
        }

        if w <= (128 as u32) {
            return builtin_info(BuiltinKind::U128)->cxx
        }

        // `_BitInt` widths: their own unsigned twin. `unsigned __int128`
        // here truncated a u256 / u512 sum to its low 128 bits.
        if w <= (256 as u32) {
            return builtin_info(BuiltinKind::U256)->cxx
        }

        return builtin_info(BuiltinKind::U512)->cxx
    }

    /// R, the register width a shift on integer \p t is computed in: 32 for
    /// up to 32 bits, 64 up to 64, 128 up to 128, a wider `_BitInt`'s own
    /// width -- wrap_carrier's thresholds, so
    /// the count mask `R - 1` is what the carrier's own shift instruction
    /// already applies on every target that masks (x86, AArch64, RISC-V).
    static fn reg_width(t: unsafe *Type) -> u32 {
        var w = CXXSpell::int_width(t)
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

    /// R_T, the signed integer of width reg_width(\p t): a signed `>>`
    /// sign-extends its left operand to it, so a narrow `i8 >> 9` fills
    /// with the sign rather than shifting zeros in from bit 8.
    fn reg_signed(self, t: unsafe *Type) -> string {
        var r = CXXSpell::reg_width(t)
        if r == (32 as u32) {
            return "int"
        }

        if r == (64 as u32) {
            return builtin_info(BuiltinKind::I64)->cxx
        }

        if r == (128 as u32) {
            return builtin_info(BuiltinKind::I128)->cxx
        }

        if r == (256 as u32) {
            return builtin_info(BuiltinKind::I256)->cxx
        }

        return builtin_info(BuiltinKind::I512)->cxx
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

    /// A transfer constructor or the destructor of \p owner.
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

        return CXXSpell::rep(
            DeclFacts::decl_pattern(CXXSpell::rep(cast<RecordType>(c)->decl)),
        ) == CXXSpell::rep(DeclFacts::decl_pattern(CXXSpell::rep(owner)))
    }

    /// \p f is a constructor of \p owner: a method named after it.
    fn is_ctor_of(self, f: unsafe *Declarations::FunctionDecl, owner: unsafe *Decl) -> bool {
        if f->is_operator || !f->is_method() || owner == &null {
            return false
        }

        return self.leaf(unsafe (f as unsafe *Decl)) == self.leaf(owner)
    }

    /// \p d emits no constructor: a C++ aggregate (a struct or union always
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

                if of != &null && CXXSpell::defines_foreign(of) && of->lexical_dc != &null {
                    c = of->lexical_dc
                    continue
                }
            }

            c = c->dc_parent
        }

        return &null
    }

    /// \p f is a Kairo definition of a function C++ declares: an
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
        if of != &null && CXXSpell::defines_foreign(of) && d->lexical_dc != &null {
            return CXXSpell::tu_of_dc(d->lexical_dc)
        }

        var unsafe *dc = d->semantic_dc
        if dc == &null {
            dc = d->lexical_dc
        }

        if dc == &null {
            // A scope owner with no parent link (an ExtensionDecl has no
            // semantic_dc): use its own chain, or fid_of answers u32(-1)
            // and friend_scopes_of finds no same-file scope.
            var unsafe *own = CXXSpell::dc_of(d)
            if own != &null {
                dc = own->dc_parent
            }
        }

        return CXXSpell::tu_of_dc(dc)
    }

    pub static fn fid_of(d: unsafe *Decl) -> u32 {
        var unsafe *tu = CXXSpell::tu_of(d)
        if tu == &null {
            return u32::MAX
        }

        return tu->fid
    }

    /// \p s as a C++ narrow string literal, quotes included: printable ASCII
    /// as it is, a quote and a backslash escaped, every other byte octal (three digits,
    /// so a following digit is never read into it).
    static fn c_string(const s: string) -> string {
        var lit = "\""
        for var j: usize = 0; j < s.size(); ++j {
            var b = (s[j])
            if b == 0x22 {
                lit += "\\\""
                continue
            }

            if b == 0x5c {
                lit += "\\\\"
                continue
            }

            if b >= 0x20 && b < 0x7f {
                lit.push_back(b)
                continue
            }

            lit += "\\"
            lit.push_back(('0' as u8) + (b >> 6 & 7))
            lit.push_back(('0' as u8) + (b >> 3 & 7))
            lit.push_back(('0' as u8) + (b & 7))
        }

        lit += "\""
        return lit
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

    /// A name token's spelling, read in \p fid's table (imm_name), or
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
            return CXXSpell::ident_safe(*txt.get_text())
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

        return CXXSpell::ident_safe(tbl->get_ident(imm))
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
            var c = s[i]
            var ok = c >= ('a' as u8) && c <= ('z' as u8)
                || c >= ('A' as u8) && c <= ('Z' as u8)
                || c >= ('0' as u8) && c <= ('9' as u8)
                || c == ('_' as u8)
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
            var c = s[i]
            var ok = c >= ('a' as u8) && c <= ('z' as u8)
                || c >= ('A' as u8) && c <= ('Z' as u8)
                || c >= ('0' as u8) && c <= ('9' as u8)
                || c == ('_' as u8)
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

    pub fn leaf(self, d: unsafe *Decl) -> string {
        var unsafe *f = dyn_cast<Declarations::FunctionDecl>(d)
        if f != &null && f->is_operator {
            return self.operator_name(f)
        }

        var t = DeclFacts::decl_name_tok(d)
        // The table the name was interned in is chosen BEFORE it is read: an
        // index read through the wrong table is not merely the wrong name but
        // can lie past that table's end (Stage 1.5 SIGSEGV'd building
        // itself on `__fwd/memory.h`'s table, 31 names, asked for #44).
        var nfid = CXXSpell::fid_of(d)
        // An imported enumerator's name was interned in the table of the
        // file its range lies in (DeclImport::_tok), which is not the TU of
        // the scope it lives in when a class and its nested enum sit in
        // different headers of one fill: reading the scope's table gave a
        // different identifier at that index (`Triple::UnknownVendor` came
        // out as `VendorType::mips64`). The range names the right table.
        if isa<Declarations::EnumVariantDecl>(d)
            && self._cg->ctx->sm != &null
            && t.range.is_valid() {
            nfid = self._cg->ctx->sm->get_fid(t.range)
        } else if DeclFacts::decl_is_imported(d)
            && self._cg->ctx->sm != &null
            && self._cg->ctx->tcm != &null
            && t.range.is_valid() {
            // Any imported member, for the same reason: a class template
            // forward-declared in one header and defined in another (libc++'s
            // `<__fwd/string.h>` and `<string>`) has its members' names in
            // the defining header's table, so `basic_string<char>::npos` read
            // from the scope's came out as `cend`. A range in a file
            // with no table of its own was interned in the scope's, as
            // DeclImport::_tok falls back.
            var rf = self._cg->ctx->sm->get_fid(t.range)
            if self._cg->ctx->tcm->get_imm_table_for_fid(rf) != &null {
                nfid = rf
            }
        }

        var nm = self.tok_name(t, nfid)
        // An ADT's layout record IS the enum to C++, and takes its name.
        var unsafe *lay   = dyn_cast<Declarations::StructDecl>(d)
        var unsafe *named = d
        if lay != &null && lay->adt_of != &null {
            named = lay->adt_of
        }

        if CXXSpell::is_hoisted_local(named) {
            return self._local_leaf(named, nm)
        }

        return nm
    }

    /// A hoisted local's namespace-scope name (LowerTargets::local_decl),
    /// from the position of its own name: the same in every TU, since it is
    /// a fact about the source alone.
    priv fn _local_leaf(self, d: unsafe *Decl, const nm: string) -> string {
        var unsafe *r  = CXXSpell::rep(d)
        var        at  = DeclFacts::decl_name_tok(r).range.start
        var unsafe *sm = self._cg->ctx->sm
        if sm == &null || !at.is_valid() {
            self._ice(
                r->range,
                "CXXSpell: a local declaration with no source position to name it by",
            )
        }

        var lc = sm->get_line_col(at)
        return LowerTargets::local_decl(nm, lc.line as u32, (lc.column as u32))
    }

    /// `operator+`, `operator[]`, `operator<=>`; `op as` -> `operator T`;
    /// `op finally` -> `~Owner`; operators C++ cannot spell -> LowerTargets.
    /// l/r on ++/-- is fixity, not part of the name (see op_is_postfix).
    fn operator_name(self, f: unsafe *Declarations::FunctionDecl) -> string {
        var sym = self._op_symbol(f)
        var k   = OperatorFacts::single_kind(f)
        if k == TokenKind::KwFinally {
            return "~" + self.leaf(self.operator_owner(f))
        }

        if k == TokenKind::KwAs {
            if f->return_type == &null {
                self._ice(f->range, "CXXSpell: `op as` with no target type")
            }

            return "operator " + self._type(f->return_type)
        }

        // A split subscript (its type declares `op []=`): each form is
        // a named member, called by that name, so the form Sema chose is the
        // one that runs (clang would pick `operator[]` by the object's
        // constness, the non-const one -- the place form -- for every read
        // of a mutable object). C++ users reach them through `operator[]`
        // forwarders (InterfaceEmitter::_subscript_forwarders).
        if OperatorFacts::in_split_subscript(f) {
            return if (OperatorFacts::is_subscript_set(f)) => (LowerTargets::subscript_set())
                   else => LowerTargets::subscript_get()
        }

        var named = CXXSpell::named_operator(f)
        if named.size() > 0 {
            return named
        }

        // An extension operator is a STATIC MEMBER of its scope, and a static
        // member cannot be an `operator+`: it gets a mnemonic, and
        // InterfaceEmitter writes the `operator+` forwarder beside the scope.
        // The member-only set never gets here from an extension;
        // OperatorSignatureCheck rejects it.
        if DeclFacts::decl_extension_of(f) != &null {
            var key = sym
            if k == TokenKind::OpPlusPlus || k == TokenKind::OpMinusMinus {
                key = (if (CXXSpell::op_is_postfix(f)) => ("r") else => "l") + sym
            }

            var m = LowerTargets::ext_op(key)
            if m.size() == 0 {
                self._ice(
                    f->range,
                    f"CXXSpell: extension 'op {sym}' has no C++ non-member form; OperatorSignatureCheck should reject it",
                )
            }

            return m
        }

        return "operator" + sym
    }

    /// A witness member's name for requirement \p f: its leaf, or for an
    /// operator the name an extension member of the same operator has --
    /// a witness member is static, so it cannot be an `operator==` either
    /// (Compiler/Spec/Witnesses.md#the-c-shape).
    fn witness_member_name(self, f: unsafe *Declarations::FunctionDecl) -> string {
        if !f->is_operator {
            return self.leaf(unsafe (f as unsafe *Decl))
        }

        var sym   = self._op_symbol(f)
        var k     = OperatorFacts::single_kind(f)
        var named = CXXSpell::named_operator(f)
        if named.size() > 0 {
            return named
        }

        if OperatorFacts::is_subscript(f) {
            return LowerTargets::witness_subscript()
        }

        if OperatorFacts::is_subscript_set(f) {
            return LowerTargets::witness_subscript_set()
        }

        if k == TokenKind::KwAs {
            var rt = "void"
            if f->return_type != &null && f->return_type->canonical != &null {
                rt = self._type(f->return_type->canonical)
            }

            return LowerTargets::witness_conversion(CXXSpell::cxx_segment(rt))
        }

        var key = sym
        if k == TokenKind::OpPlusPlus || k == TokenKind::OpMinusMinus {
            key = (if (CXXSpell::op_is_postfix(f)) => ("r") else => "l") + sym
        }

        var m = LowerTargets::ext_op(key)
        if m.size() == 0 {
            self._ice(
                f->range,
                f"CXXSpell: requirement 'op {sym}' has no static-member name; OperatorSignatureCheck should reject it",
            )
        }

        return m
    }

    /// The namespace-scope `operator<sym>` an extension operator is forwarded
    /// from, or "" when it has none: the operators named by LowerTargets
    /// (`in`, `^^`, ...) are not C++ operators, and are only static members.
    fn ext_forwarder_name(self, f: unsafe *Declarations::FunctionDecl) -> string {
        var sym = self._op_symbol(f)
        if CXXSpell::named_operator(f).size() > 0 {
            return ""
        }

        return "operator" + sym
    }

    /// The operator's symbol as C++ spells it: word operators mapped, and
    /// `l`/`r` dropped from `++`/`--` (fixity is op_is_postfix's).
    priv fn _op_symbol(self, f: unsafe *Declarations::FunctionDecl) -> string {
        var unsafe *ctx = CXXSpell::tu_of(unsafe (f as unsafe *Decl))->ctx
        var marked = f->op_token.size() == 2
            && f->op_token[0].kind == TokenKind::LitIdentifier
            && (f->op_token[1].kind == TokenKind::OpPlusPlus
                || f->op_token[1].kind == TokenKind::OpMinusMinus)
        if marked {
            return if (f->op_token[1].kind == TokenKind::OpPlusPlus) => ("++") else => "--"
        }

        var sym = ""
        for var i: usize = 0; i < f->op_token.size(); ++i {
            sym += self._op_sym(f->op_token[i], ctx)
        }

        return sym
    }

    /// The LowerTargets name of an operator C++ has no `operator` for, or "".
    static fn named_operator(f: unsafe *Declarations::FunctionDecl) -> string {
        var k = OperatorFacts::single_kind(f)
        if k == TokenKind::KwIn {
            return if (f->params.size() > 1) => (LowerTargets::op_contains())
                   else => LowerTargets::op_iter()
        }

        if k == TokenKind::OpCaretCaret {
            return LowerTargets::op_pow()
        }

        if k == TokenKind::KwAwait {
            return LowerTargets::op_await()
        }

        if k == TokenKind::KwSpawn {
            return LowerTargets::op_spawn()
        }

        if k == TokenKind::KwThread {
            return LowerTargets::op_thread()
        }

        if k == TokenKind::KwPanic {
            return LowerTargets::op_panic()
        }

        return ""
    }

    /// \p f, a form of a split subscript (OperatorFacts::in_split_subscript),
    /// gets a C++ `operator[]` forwarder to its named member, so C++
    /// code subscripts the type as it always did: the place form's on a
    /// mutable object, a read form's (`const` when it takes `const self`)
    /// on a const one. InterfaceEmitter declares it, EmitIR defines it
    /// beside the form's own definition. None for a member template or an
    /// unnamed operand (nothing to forward without spelling arguments), and
    /// none for a read form C++ would see as the same overload as a place
    /// form of its type (one constness, one operand type): the place form
    /// takes `operator[]`, since C++ writes through it, and the read form is
    /// reached by its name.
    fn subscript_forwarded(self, f: unsafe *Declarations::FunctionDecl) -> bool {
        if f == &null || f->is_poisoned() || !OperatorFacts::in_split_subscript(f) {
            return false
        }

        if self.template_head(unsafe (f as unsafe *Decl)).size() > 0 {
            return false
        }

        for var i: usize = 0; i < f->params.size(); ++i {
            var unsafe *p = f->params[i]
            if p != &null && !p->is_self && (p->unname || p->is_pack) {
                return false
            }
        }

        if OperatorFacts::is_subscript_set(f) {
            return true
        }

        var unsafe *dc = f->semantic_dc
        if dc == &null || !dc->is_type_scope() {
            dc = f->lexical_dc
        }

        var unsafe *sets = if (dc != &null) => (dc->lookup_symbol(
                               DeclName::subscript_set_name(),
                           ))
                           else => &null
        if sets == &null {
            return true
        }

        var unsafe *mine = CXXSpell::_operand_of(f)
        for var i: usize = 0; i < sets->size(); ++i {
            var unsafe *g = dyn_cast<Declarations::FunctionDecl>(sets->get(i))
            if g == &null || g->is_poisoned() || g->is_const() != f->is_const() {
                continue
            }

            var unsafe *theirs = CXXSpell::_operand_of(g)
            if mine != &null && mine == theirs {
                return false
            }
        }

        return true
    }

    /// The first operand's type after the receiver, unqualified.
    priv static fn _operand_of(f: unsafe *Declarations::FunctionDecl) -> unsafe *Type {
        for var i: usize = 0; i < f->params.size(); ++i {
            var unsafe *p = f->params[i]
            if p == &null || p->is_self {
                continue
            }

            if p->type_ == &null {
                return &null
            }

            return canon_unqual(p->type_->canonical)
        }

        return &null
    }

    /// `op r++` / `op r--`: the postfix form, which C++ declares with an
    /// `int` dummy parameter. By kind, as AST/OperatorFacts.k decides it.
    static fn op_is_postfix(f: unsafe *Declarations::FunctionDecl) -> bool {
        if !f->is_operator || f->op_token.size() != 2 {
            return false
        }

        if f->op_token[0].kind != TokenKind::LitIdentifier {
            return false
        }

        var k = f->op_token[1].kind
        if k != TokenKind::OpPlusPlus && k != TokenKind::OpMinusMinus {
            return false
        }

        var unsafe *ctx = CXXSpell::tu_of(unsafe (f as unsafe *Decl))->ctx
        var        s    = ctx->get_spelling(f->op_token[0])
        return s.size() > 0 && s[0] == ('r' as u8)
    }

    /// `[]` or `[]=` returning a safe `*T` / `*const T`: a place.
    /// Codegen's copy of OperatorFacts::is_place, return-type test included,
    /// on this side of the import boundary. Any other return is a value
    /// operator and is spelled as declared. `[]` is two tokens, `[]=` three.
    static fn is_place_operator(f: unsafe *Declarations::FunctionDecl) -> bool {
        if f == &null || !f->is_operator || !f->is_method() {
            return false
        }

        if f->op_token.size() != 2 && f->op_token.size() != 3 {
            return false
        }

        if f->op_token[0].kind != TokenKind::OpLSquare
            || f->op_token[1].kind != TokenKind::OpRSquare {
            return false
        }

        if f->op_token.size() == 3 && f->op_token[2].kind != TokenKind::OpEqual {
            return false
        }

        if f->return_type == &null || f->return_type->canonical == &null {
            return false
        }

        var unsafe *c = canon_unqual(f->return_type->canonical)
        return c != &null && isa<PointerType>(c) && !cast<PointerType>(c)->is_unsafe
    }

    /// The C++ return type of \p f: a place operator's `*T` / `*const T`
    /// becomes `T&` / `const T&`, so C++ code can write `v[i] = x` on a Kairo
    /// type and an imported `T&` and a Kairo place are one ABI. Everything
    /// else, a value `op []` included, is the declared type. The pointee of `*const T` is the `const T`
    /// canonical, so _type already spells the const and `&` goes on the end.
    fn return_spelling(self,
                       f:     unsafe *Declarations::FunctionDecl,
                       subst: unsafe *InstanceEntry,
                       scope: unsafe *Decl = &null) -> string {
        // A panicking function returns its Panic result (Compiler/Spec/Panic.md#paniclowering);
        // return_type stays the value type an importer's typing reads.
        if f->panic_result != &null {
            return self._type(f->panic_result, subst, scope)
        }

        if f->return_type == &null || f->return_type->canonical == &null {
            return self._type(f->return_type, subst, scope)
        }

        // An eval generator runs at compile time, where nothing suspends: it
        // returns the buffer its `yield`s push into (Compiler/Spec/Eval.md#eval-for).
        if f->is_eval() && f->is_generator {
            var unsafe *gr = dyn_cast<RecordType>(
                canon_unqual(f->return_type->canonical),
            )

            if gr != &null && gr->args.size() > 0 {
                return "::" + LowerTargets::eval_buf() + "<" + self._type(
                    gr->args[0],
                    subst,
                    scope,
                ) + ">"
            }
        }

        if !CXXSpell::is_place_operator(f) && !f->cxx_ref_return {
            return self._type(f->return_type, subst, scope)
        }

        var unsafe *c = canon_unqual(f->return_type->canonical)
        if c == &null || !isa<PointerType>(c) {
            self._ice(
                f->range,
                "CXXSpell: is_place_operator accepted a non-pointer result",
            )
        }

        return self._type(cast<PointerType>(c)->pointee, subst, scope) + "&"
    }

    /// The type an operator belongs to: its class, or its extension's target.
    fn operator_owner(self, f: unsafe *Declarations::FunctionDecl) -> unsafe *Decl {
        var unsafe *lex = f->lexical_dc
        if lex != &null && lex->dc_kind == DeclContextKind::Extension {
            var unsafe *x = cast<Declarations::ExtensionDecl>(lex->dc_owner)
            var unsafe *c = x->target->canonical
            if c == &null || c->kind != TypeKind::RecordType {
                self._ice(
                    f->range,
                    "CXXSpell: extension operator on a non-record target",
                )
            }

            return CXXSpell::rep(cast<RecordType>(c)->decl)
        }

        var unsafe *dc = f->semantic_dc
        if dc == &null || !dc->is_type_scope() {
            self._ice(f->range, "CXXSpell: operator with no owning type")
        }

        return CXXSpell::rep(dc->dc_owner)
    }

    priv fn _op_sym(self, t: Token, ctx: unsafe *ASTContext) -> string {
        match t.kind {
            case TokenKind::KwAnd {
                return "&&"
            } case TokenKind::KwOr {
                return "||"
            } case TokenKind::KwNot {
                return "!"
            } case TokenKind::KwXor {
                return "^"
            } case TokenKind::KwBitand {
                return "&"
            } case TokenKind::KwBitor {
                return "|"
            } case TokenKind::KwCompl {
                return "~"
            } case TokenKind::KwNotEq {
                return "!="
            } case TokenKind::KwAndEq {
                return "&="
            } case TokenKind::KwOrEq {
                return "|="
            } case TokenKind::KwXorEq {
                return "^="
            } default {
                return ctx->get_spelling(t)
            }
        }
    }

    /// The module path of a TU as strings: root name + directories + file.
    pub fn module_segments(self, tu: unsafe *TranslationUnit) -> cxx::std::vector<string> {
        var out = cxx::std::vector<string>()
        if tu == &null || tu->ctx == &null {
            return out
        }

        if self._cg->psym == &null {
            kairo::std::ice_fail(
                "CXXSpell: no PreprocessorSymbolTable on the CodegenContext",
            )
        }

        // Resolve the SymbolID directly: module_base segments are
        // synthesized and carry no token, so as_string() falls back to a
        // debug rendering that is not a C++ identifier.
        var *mb = &tu->ctx->module_base
        for var i: usize = 0; i < mb->segments.size(); ++i {
            var unsafe *p = self._cg->psym->resolve(mb->segments[i].name)
            if p == &null {
                kairo::std::ice_fail(
                    "CXXSpell: module_base segment is not in the PP symbol table",
                )
            }

            // A segment is a FILE or directory name, not a Kairo identifier:
            // every input is a module, and `operator.k` or
            // `01_basic.k` in the cwd is module `operator` / `01_basic`.
            out.push_back(CXXSpell::cxx_segment(*p))
        }

        return out
    }

    /// \p tu has no module path: a file outside every search dir (or one
    /// whose path a named library owns, ImportResolver::input_module_path),
    /// the driver's virtual library entry, or a tool's bare parse. Not
    /// "a command-line input": an input takes the module path an import
    /// gives it, and only these keep the pathless rules
    /// below (stem namespace, priv decls in the unnamed namespace, no header).
    pub static fn is_entry_tu(tu: unsafe *TranslationUnit) -> bool {
        if tu == &null || tu->ctx == &null {
            return true
        }

        return tu->ctx->module_base.segments.size() == 0
    }

    /// \p d is the program's `main`: a free function named `main` at file
    /// scope, in ANY TU. Emitted as the global `int main`, never in a
    /// namespace and never in a header. A `main` is the program's wherever its
    /// file sits, because every input is a module. One in a `module foo
    /// { }` block is `foo::main`, an ordinary function.
    fn is_main(self, d: unsafe *Decl) -> bool {
        if d == &null || !isa<Declarations::FunctionDecl>(d) {
            return false
        }

        if cast<Declarations::FunctionDecl>(d)->is_method() {
            return false
        }

        var unsafe *dc = d->semantic_dc
        if dc == &null || !dc->is_translation_unit() {
            return false
        }

        return self.leaf(d) == entry_point_name()
    }

    /// \p s as one C++ identifier: anything else becomes `_`, a leading
    /// digit gets a `_` before it, and a C++ keyword one after it
    /// (`operator` -> `operator_`; a trailing `_` cannot collide with another
    /// keyword). For names that come from FILES -- module path segments and
    /// a pathless TU's stem -- which reach the ABI only through here
    /// (invariant 9a).
    static fn cxx_segment(const s: string) -> string {
        var out = ""
        for var i: usize = 0; i < s.size(); ++i {
            var c = s[i]
            var ok = c >= ('a' as u8) && c <= ('z' as u8)
                || c >= ('A' as u8) && c <= ('Z' as u8)
                || c >= ('0' as u8) && c <= ('9' as u8)
                || c == ('_' as u8)
            if ok {
                out.push_back(c)
            } else {
                out += "_"
            }
        }

        if out.size() == 0 {
            return "_"
        }

        if out[0] >= ('0' as u8) && out[0] <= ('9' as u8) {
            return "_" + out
        }

        if is_cxx_keyword(out) {
            return out + "_"
        }

        return out
    }

    /// \p tu's first namespace segment as the module path spells it, before
    /// any rename: the module root, or a pathless TU's stem.
    pub fn top_segment(self, tu: unsafe *TranslationUnit) -> string {
        var segs = self.module_segments(tu)
        if segs.size() > 0 {
            return segs[0]
        }

        return CXXSpell::entry_stem(tu)
    }

    /// The Kairo top segment a C++ one was renamed from (identity if none).
    static fn kairo_top_of(const c: string) -> string {
        return _NS_TOPS.kairo_of(c)
    }

    /// Decides the C++ spelling of every top segment in \p tops (one
    /// build's modules) that is not decided yet, and records it (CxxNsTops).
    /// \p header_global answers whether a header of the build declares
    /// `::name` as anything but a namespace. A segment keeps its spelling
    /// unless taken; a taken one gets `_` appended until it is free. Taken:
    /// an entry-point name, \p header_global, another module's own top
    /// segment in \p tops, or another segment's recorded rename. The roots
    /// the toolchain's prebuilt objects live under (builtin, std, kairo) are
    /// never renamed: --kairo-lib builds those once for every later link.
    /// Sorted first, so the answer depends on the set of names, not on the
    /// order the graph listed them.
    pub static fn decide_tops(@inout tops:   cxx::std::vector<string>,
                              header_global: fn(string) -> bool) {
        // Insertion sort: a build has a handful of roots.
        for var i: usize = 1; i < tops.size(); ++i {
            var j = i
            while j > 0 && tops[j] < tops[j - 1] {
                var tmp = tops[j]
                tops[j]     = tops[j - 1]
                tops[j - 1] = tmp
                j -= 1
            }
        }

        for var i: usize = 0; i < tops.size(); ++i {
            var t = tops[i]
            if i > 0 && tops[i - 1] == t {
                continue
            }

            if t == builtin_root_name() || t == std_root_spelling() || t == "kairo" {
                continue
            }

            if _NS_TOPS.decided(t) {
                continue
            }

            var c = t
            while true {
                var taken = is_entry_point_name(c) || header_global(c)
                if !taken && c != t {
                    for var j: usize = 0; j < tops.size(); ++j {
                        if tops[j] == c {
                            taken = true
                            break
                        }
                    }

                    if !taken && _NS_TOPS.is_target(c) {
                        taken = true
                    }
                }

                if !taken {
                    break
                }

                c += "_"
            }

            _NS_TOPS.record(t, c)
        }
    }

    /// A pathless TU's namespace: its FILE STEM, sanitized to a C++
    /// identifier. Before this its decls landed in one unnamed namespace and
    /// two such TUs in a build could not both define `helper`. The stem is a
    /// name the source already has.
    static fn entry_stem(tu: unsafe *TranslationUnit) -> string {
        if tu == &null || tu->ctx == &null || tu->ctx->sm == &null {
            return "_"
        }

        var path = tu->ctx->sm->get_filename(tu->fid)
        // basename, then drop the extension.
        var start: usize = 0
        for var i: usize = 0; i < path.size(); ++i {
            if path[i] == ('/' as u8) || path[i] == ('\\' as u8) {
                start = i + 1
            }
        }

        var end = path.size()
        for var i: usize = start; i < path.size(); ++i {
            if path[i] == ('.' as u8) {
                end = i
                break
            }
        }

        return CXXSpell::cxx_segment(
            string(
                unsafe (((path.raw() as unsafe *const u8) + start) as *const u8),
                end - start,
            ),
        )
    }

    /// A decl with no linkage outside its own file: `priv` or `internal` in
    /// the entry TU. It goes in an unnamed namespace NESTED in the file's,
    /// so `::<stem>::helper` still names it -- C++'s implicit using-directive
    /// reaches into the unnamed one -- and qual_name is unchanged.
    ///
    /// Not when an inline or template body of the file names it
    /// (TranslationUnit::cxx_escaping): that body is compiled in every C++
    /// TU that includes the file, and calls it by external linkage.
    ///
    /// Never a function or a record: a record befriends its file's functions
    /// and records (EmitPlan::file_friends), and a friend declaration cannot
    /// reach into an unnamed namespace -- an unqualified one declares a NEW
    /// `stem::f`, a qualified one matches nothing. So those keep the stem
    /// namespace and external linkage; nothing imports a pathless file, and
    /// two of them share a namespace only when their stems do, where their
    /// `pub` decls already collide.
    static fn is_anon(d: unsafe *Decl) -> bool {
        if d == &null {
            return false
        }

        if isa<Declarations::FunctionDecl>(d)
            || isa<Declarations::ClassDecl>(d)
            || isa<Declarations::StructDecl>(d)
            || isa<Declarations::UnionDecl>(d) {
            return false
        }

        var unsafe *tu = CXXSpell::tu_of(d)
        if !CXXSpell::is_entry_tu(tu) {
            return false
        }

        var v = CXXSpell::vis_of(d)
        if v != VIS_PRIV() && v != VIS_INTERNAL() {
            return false
        }

        if tu != &null {
            var unsafe *r = CXXSpell::rep(d)
            for var i: usize = 0; i < tu->cxx_escaping.size(); ++i {
                if tu->cxx_escaping[i] == d || tu->cxx_escaping[i] == r {
                    return false
                }
            }
        }

        return true
    }

    /// \p d is declared inside a function body: its semantic scope, or one
    /// enclosing it, is a function, block or lambda (FinallyLowering's guard
    /// record, its members and its local). Such a decl has no namespace: it
    /// is named by leaf, emitted inside the body, and never planned.
    ///
    /// A HOISTED local (is_hoisted_local) is the exception, and so is
    /// everything declared in one: it is emitted at namespace scope, so
    /// the walk stops at it as at a namespace. A local of one of its
    /// functions still meets that function's scope first.
    static fn in_function_scope(d: unsafe *Decl) -> bool {
        if d == &null {
            return false
        }

        if CXXSpell::is_hoisted_local(d) {
            return false
        }

        var unsafe *dc = d->semantic_dc
        while dc != &null {
            if dc->is_function()
                || dc->dc_kind == DeclContextKind::Block
                || dc->dc_kind == DeclContextKind::Lambda {
                return true
            }

            if dc->is_translation_unit()
                || dc->dc_kind == DeclContextKind::Module
                || dc->dc_kind == DeclContextKind::Extension {
                return false
            }

            if dc->is_type_scope()
                && dc->dc_owner != &null
                && CXXSpell::is_hoisted_local(dc->dc_owner) {
                return false
            }

            dc = dc->dc_parent
        }

        return false
    }

    /// \p d is a `fn`, class, struct, union or enum the user wrote in a
    /// function body. C++ has no local functions, and a local class can have
    /// no member template, no static data member and no out-of-line member,
    /// so each is emitted at NAMESPACE scope instead -- the scope of the
    /// function it is written in -- under a name that carries its position
    /// (LowerTargets::local_decl), and planned and emitted as any other own
    /// declaration (Compiler/Spec/Codegen.md#emitir, Local declarations). It cannot reach the
    /// function's locals (ClosureCaptures rejects that), so nothing it needs
    /// is lost by the move. A lowering's record (FinallyLowering's guard) is
    /// implicit and stays in the body.
    static fn is_hoisted_local(d: unsafe *Decl) -> bool {
        if d == &null || d->is_implicit {
            return false
        }

        if (!isa<Declarations::FunctionDecl>(d))
            && (!isa<Declarations::ClassDecl>(d))
            && (!isa<Declarations::StructDecl>(d))
            && (!isa<Declarations::UnionDecl>(d))
            && !isa<Declarations::EnumDecl>(d) {
            return false
        }

        var unsafe *dc = d->semantic_dc
        if dc == &null {
            return false
        }

        return dc->is_function()
            || dc->dc_kind == DeclContextKind::Block
            || dc->dc_kind == DeclContextKind::Lambda
    }

    /// The scope a decl's NAMESPACE is read from: for an extension member
    /// the extension's parent (its scope struct lives in the enclosing
    /// module; owner_types supplies the struct), otherwise the decl's
    /// semantic scope.
    priv fn _home_dc(self, d: unsafe *Decl) -> unsafe *DeclContext {
        var unsafe *lex = d->lexical_dc
        if lex != &null && lex->dc_kind == DeclContextKind::Extension {
            return lex->dc_parent
        }

        return d->semantic_dc
    }

    /// Namespace segments (modules only) enclosing \p d, outermost first.
    pub fn ns_segments(self, d: unsafe *Decl) -> cxx::std::vector<string> {
        return self._ns_from(self._home_dc(d))
    }

    /// The namespace N of \p x's scope struct: the scope its members are
    /// qualified from (_home_dc), read off the extension itself, so a scope
    /// has a namespace even before a member is picked.
    fn scope_ns(self, x: unsafe *Declarations::ExtensionDecl) -> cxx::std::vector<string> {
        var unsafe *dc = CXXSpell::dc_of(unsafe (x as unsafe *Decl))
        return self._ns_from(if (dc != &null) => (dc->dc_parent) else => &null)
    }

    priv fn _ns_from(self, home: unsafe *DeclContext) -> cxx::std::vector<string> {
        var        mods = cxx::std::vector<string>()
        var unsafe *dc  = home
        while dc != &null {
            if dc->dc_kind == DeclContextKind::TranslationUnit {
                break
            }

            if dc->dc_kind == DeclContextKind::Module {
                var unsafe *m = cast<Declarations::ModuleDecl>(dc->dc_owner)
                if m != &null && !m->is_anonymous {
                    mods.push_back(self.tok_name(m->name, CXXSpell::fid_of(m)))
                }
            }

            dc = dc->dc_parent
        }

        var unsafe *tu = CXXSpell::tu_of_dc(home)
        var        out = self.module_segments(tu)
        // An entry TU declares no module, so module_segments gives nothing;
        // its file stem is the namespace instead.
        if out.size() == 0 {
            out.push_back(CXXSpell::entry_stem(tu))
        }

        // Only the first segment is at global scope, so only it can meet a
        // header's `::malloc` or the program's `int main`.
        if !self.kairo_top {
            out[0] = _NS_TOPS.spelling(out[0])
        }

        for var i: usize = 0; i < mods.size(); ++i {
            out.push_back(mods[mods.size() - 1 - i])
        }

        return out
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
    fn ext_scope_name(self, x: unsafe *Declarations::ExtensionDecl) -> string {
        if x == &null || x->target == &null || x->target->canonical == &null {
            kairo::std::ice_fail(
                "CXXSpell: extension with an unresolved target reached codegen",
            )
        }

        var unsafe *c = canon_unqual(x->target->canonical)
        var        s  = LowerTargets::ext_scope_prefix()
        if isa<BuiltinType>(c) {
            return s + builtin_info(cast<BuiltinType>(c)->builtin)->spelling
        }

        // `extend [i32; 2]`: a fixed array is neither a record nor a
        // builtin; its scope is named from its C++ spelling, which is a
        // function of the type and the target (an `isize` element is `long`
        // or `long long`), never of the build order. A scope struct never
        // crosses targets, so that is as stable as it needs to be.
        if isa<FixedArrayType>(c) && !c->is_dependent() {
            return s + "arr__" + CXXSpell::_path_ident(self._type(c))
        }

        // `extend i32?`, `extend <T> [T]?`: a nullable is its
        // `::builtin::Nullable<T>` record to C++, but EmitPlan keys a
        // non-record target's scope by the exact canonical (_same_scope), so
        // each nullable gets its own struct, named from its C++ spelling as
        // a fixed array's is: a function of the type and the target alone.
        if isa<NullableType>(c) {
            return s + "nul__" + CXXSpell::_path_ident(self._type(c))
        }

        if !isa<RecordType>(c) {
            self._ice(
                x->range,
                "CXXSpell: extension of a non-record, non-builtin target; no scope naming rule for it yet",
            )
        }

        var unsafe *prim = CXXSpell::rep(
            DeclFacts::decl_pattern(CXXSpell::rep(cast<RecordType>(c)->decl)),
        )

        if DeclFacts::decl_is_imported(prim) {
            return s + CXXSpell::_path_ident(DeclFacts::decl_cxx_spelling(prim))
        }

        var tns  = self.ns_segments(prim)
        var sns  = self.scope_ns(x)
        var same = tns.size() == sns.size()
        for var i: usize = 0; same && i < tns.size(); ++i {
            if tns[i] != sns[i] {
                same = false
            }
        }

        if !same {
            for var i: usize = 0; i < tns.size(); ++i {
                s += tns[i]
                s += "__"
            }
        }

        var ow = self.owner_types(prim)
        for var i: usize = 0; i < ow.size(); ++i {
            s += ow[i]
            s += "__"
        }

        return s + self.leaf(prim)
    }

    /// `::ns::Point` as `ns__Point`: `::` becomes `__`, the leading one is
    /// dropped, and anything else that is not an identifier byte is `_`.
    static fn _path_ident(const sp: string) -> string {
        var out       = ""
        var i:  usize = 0
        if sp.size() >= 2 && sp[0] == (':' as u8) && sp[1] == (':' as u8) {
            i = 2
        }

        while i < sp.size() {
            var ch = sp[i]
            if ch == (':' as u8) && i + 1 < sp.size() && sp[i + 1] == (':' as u8) {
                out += "__"
                i += 2
                continue
            }

            var ok = ch >= ('a' as u8) && ch <= ('z' as u8)
                || ch >= ('A' as u8) && ch <= ('Z' as u8)
                || ch >= ('0' as u8) && ch <= ('9' as u8)
                || ch == ('_' as u8)
            if ok {
                out.push_back(ch)
            } else {
                out += "_"
            }

            i += 1
        }

        return out
    }

    /// Enclosing TYPE names for a nested decl, outermost first. An extension
    /// member's one owner is its scope struct.
    pub fn owner_types(self, d: unsafe *Decl) -> cxx::std::vector<string> {
        var unsafe *x = DeclFacts::decl_extension_of(d)
        if x != &null {
            var one = cxx::std::vector<string>()
            one.push_back(self.ext_scope_name(x))
            return one
        }

        var        rev = cxx::std::vector<string>()
        var unsafe *dc = self._home_dc(d)
        while dc != &null && dc->is_type_scope() {
            if dc->dc_kind != DeclContextKind::Extension {
                rev.push_back(self.leaf(CXXSpell::rep(dc->dc_owner)))
            }

            dc = dc->dc_parent
        }

        var out = cxx::std::vector<string>()
        for var i: usize = 0; i < rev.size(); ++i {
            out.push_back(rev[rev.size() - 1 - i])
        }

        return out
    }

    /// `::ns::Outer::Inner`. An entry-TU decl's segment is its file stem, so
    /// `::stem::Name` is the same name whether the decl is `pub` or `priv`:
    /// C++'s implicit using-directive reaches into the nested unnamed
    /// namespace `priv` puts it in, and qual_name never has to know.
    /// \p q, an imported enum's C++ name, cut before an unnamed segment:
    /// clang prints `enum { a };` as `::ns::(unnamed enum at f.h:2:16)`,
    /// which is no C++ name. An unnamed enum is never scoped, so its
    /// enumerators are its enclosing scope's (`::clang::diag::err_x`);
    /// `::` alone is the global scope.
    static fn _unnamed_scope_cut(q: string) -> string {
        var out = ""
        for var i: usize = 0; i < q.size(); ++i {
            if q[i] == ('(' as u8) && i >= 2 && q[i - 1] == (':' as u8) && q[i - 2] == (':' as u8) {
                // `out` ends in the `::` before the segment; drop it.
                var cut = ""
                for var j: usize = 0; j + 2 < out.size(); ++j {
                    cut.push_back(out[j])
                }

                return cut
            }

            out.push_back(q[i])
        }

        return q
    }

    pub fn qual_name(self, d: unsafe *Decl) -> string {
        if CXXSpell::in_function_scope(d) {
            return self.leaf(d)
        }

        var unsafe *r = CXXSpell::rep(d)
        if DeclFacts::decl_is_imported(r) {
            return DeclFacts::decl_cxx_spelling(r)
        }

        // A Kairo definition of a C++-declared function is called by
        // the C++ name, not under the module it is written in.
        var unsafe *rf = dyn_cast<Declarations::FunctionDecl>(r)
        if rf != &null && CXXSpell::defines_foreign(rf) {
            return DeclFacts::decl_cxx_spelling(
                unsafe (rf->first_decl() as unsafe *Decl),
            )
        }

        // An imported enum's enumerator carries no import facts of its own
        // (DeclImport makes a bare EnumVariantDecl), so it fell through to
        // the Kairo path below and was spelled under its HEADER's module
        // (`::memory_order::std::memory_order::relaxed`), which names
        // nothing in C++. Its enum's C++ name is its scope: `E::b` is
        // legal C++11 for a scoped and an unscoped enum alike.
        if isa<Declarations::EnumVariantDecl>(r) {
            var unsafe *hdc = self._home_dc(r)
            if hdc != &null && hdc->is_type_scope() && hdc->owner_decl() != &null {
                var unsafe *en = CXXSpell::rep(hdc->owner_decl())
                if DeclFacts::decl_is_imported(en) {
                    return CXXSpell::_unnamed_scope_cut(
                        DeclFacts::decl_cxx_spelling(en),
                    ) + "::" + self.leaf(r)
                }
            }
        }

        // An enumerator of an enum nested in a class template: the plain
        // `::ns::G::E::B` names the template without arguments, which C++
        // rejects. Spell the owner chain over its own parameters, as the
        // template body sees it (the same path a nested type takes).
        if isa<Declarations::EnumVariantDecl>(r) {
            var gq = self._generic_owner_qual(r)
            if gq.size() > 0 {
                return gq + "::" + self.leaf(r)
            }
        }

        var s  = ""
        var ns = self.ns_segments(r)
        for var i: usize = 0; i < ns.size(); ++i {
            s += "::"
            s += ns[i]
        }

        var ow = self.owner_types(r)
        for var i: usize = 0; i < ow.size(); ++i {
            s += "::"
            s += ow[i]
        }

        s += "::"
        s += self.leaf(r)
        return s
    }

    /// `ns::a::b {` as `namespace a::b`, or "" for the entry TU.
    fn ns_join(self, @inout segs: cxx::std::vector<string>) -> string {
        var s = ""
        for var i: usize = 0; i < segs.size(); ++i {
            if i > 0 {
                s += "::"
            }

            s += segs[i]
        }

        return s
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

        // -finfer-purity's verdict (FnPurityCheck::infer) is spelled like a
        // written promise; it is stamped on every link, so each head agrees.
        var inferred = f->inferred_purity
        if inferred == 0 && c != &null {
            inferred = c->inferred_purity
        }

        if f->is_const_fn || c != &null && c->is_const_fn || inferred == 1 {
            s += LowerTargets::attr_const()
        } else if f->is_pure || c != &null && c->is_pure || inferred == 2 {
            s += LowerTargets::attr_pure()
        }

        // The convention, from whichever link wrote it: RedeclMerge holds
        // the chain to one value, so either answers.
        var cc = f->call_conv
        if cc == 0 && c != &null {
            cc = c->call_conv
        }

        s += CXXSpell::call_conv_attr(cc)
        return s
    }

    /// The C++ attribute of a FunctionDecl::call_conv / FunctionPointerType::
    /// call_conv value, with its trailing space, or "" for the default.
    pub static fn call_conv_attr(cc: u8) -> string {
        if cc == 1 {
            return LowerTargets::attr_preserve_most()
        }

        if cc == 2 {
            return LowerTargets::attr_preserve_all()
        }

        if cc == 3 {
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
    /// `T __kairo_ginit_x()`: the thunk that initializes \p v when its
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

    /// Which interface PCH \p tu may share (Compiler/Spec/Codegen.md#the-interface-pch):
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

        if !self._cg->opts.tls_model.empty() {
            return LowerTargets::attr_tls_model(self._cg->opts.tls_model)
        }

        if self._cg->opts.exe_link {
            return LowerTargets::attr_tls_model("local-exec")
        }

        if self._toolchain_tu(CXXSpell::tu_of(unsafe (v as unsafe *Decl))) {
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
        if CXXSpell::thread_constinit(v) {
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

    /// # Types

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
    fn _type(self,
             t:     unsafe *Type,
             subst: unsafe *InstanceEntry = &null,
             scope: unsafe *Decl = &null) -> string {
        return self.decl(t, "", subst, scope)
    }

    /// \p t as ONE type-specifier that text may follow: `_type`, except that
    /// a C array (`signed int[2]`), whose declarator wraps whatever follows
    /// it (`int (*p)[2]`), is `__typeof__(signed int[2])`. Every spelling
    /// that appends `*`, `&`, ` const &` or a name to a type it got as a
    /// string goes through here: an extension's receiver, a
    /// witness's Self, a generic parameter an instance binds to an array.
    fn type_specifier(self,
                      t:     unsafe *Type,
                      subst: unsafe *InstanceEntry = &null,
                      scope: unsafe *Decl = &null) -> string {
        var        s  = self._type(t, subst, scope)
        var unsafe *c = if (t != &null && t->canonical != &null) => (t->canonical) else => t
        if c != &null && isa<FixedArrayType>(canon_unqual(c)) {
            return "__typeof__(" + s + ")"
        }

        return s
    }

    /// The C++ spelling of an unresolved member type of a generic parameter
    /// (`T::Guard`, `T::A::B`) as `typename T::Guard`, or "" for any other
    /// type: a type unresolved for any other reason is still a Sema gate
    /// failure, and must keep ICEing.
    fn dependent_member(self, t: unsafe *Type) -> string {
        if t == &null || t->kind != TypeKind::ChainType {
            return ""
        }

        var unsafe *ch = cast<ChainType>(t)
        if ch->segments.size() < 2 {
            return ""
        }

        var unsafe *s0 = ch->segments.get(0)
        var        out = ""
        if s0->resolved_type != &null
            && s0->resolved_type->canonical != &null
            && isa<GenericParamType>(s0->resolved_type->canonical) {
            out = "typename " + self._type(s0->resolved_type)
        } else if s0->resolved_decl != &null
            && isa<Declarations::GenericParamDecl>(s0->resolved_decl)
            && s0->name != &null {
            out = "typename " + *TokenText::from_range(
                s0->name->range,
                self._cg->ctx->sm,
            ).get_text()
        } else {
            return ""
        }

        for var i: usize = 1; i < ch->segments.size(); ++i {
            var unsafe *sg = ch->segments.get(i)
            if sg->name == &null || sg->generic_args.size() > 0 {
                return ""
            }

            out += "::" + *TokenText::from_range(
                sg->name->range,
                self._cg->ctx->sm,
            ).get_text()
        }

        return out
    }

    /// `type name` with the declarator folded in: `int x`, `int (*f)(int)`.
    /// Empty \p name gives the abstract form. \p scope as for _type.
    fn decl(self,
            t_in:       unsafe *Type,
            const name: string,
            subst:      unsafe *InstanceEntry = &null,
            scope:      unsafe *Decl = &null) -> string {
        if t_in == &null {
            return self._join("void", name)
        }

        var unsafe *t = t_in->canonical
        if t == &null {
            // `T::Guard` under a duck `<T: type>`: no canonical until an
            // instance names T, so C++ resolves it (`typename T::Guard`).
            var dm = self.dependent_member(t_in)
            if dm.size() > 0 {
                return self._join(dm, name)
            }

            self._ice(
                t_in->range,
                "CXXSpell: type with no canonical reached codegen (sema gate failure)",
            )
        }

        match t->kind {
            case TypeKind::QualifiedType {
                var unsafe *q  = cast<QualifiedType>(t)
                var        pfx = ""
                if (q->quals & QUAL_CONST) != 0 {
                    pfx += "const "
                }

                if (q->quals & QUAL_VOLATILE) != 0 {
                    pfx += "volatile "
                }

                // A qualifier on a pointer belongs to the pointer, after the
                // `*` (`S *const &`); a prefix would make it the pointee's
                // (`const S *&`), a reference clang refuses to bind to a
                // `S *` element (vector<S *>::push_back's `const value_type&`).
                var unsafe *ic = q->inner->canonical
                if ic != &null && ic->kind == TypeKind::PointerType {
                    var after = ""
                    if (q->quals & QUAL_CONST) != 0 {
                        after += "const"
                    }

                    if (q->quals & QUAL_VOLATILE) != 0 {
                        after += if (after.size() > 0) => (" volatile") else => "volatile"
                    }

                    return self.decl(
                        q->inner,
                        if (name.size() > 0) => (after + " " + name) else => after,
                        subst,
                        scope,
                    )
                }

                return pfx + self.decl(q->inner, name, subst, scope)
            } case TypeKind::BuiltinType {
                var unsafe *b = cast<BuiltinType>(t)
                if b->builtin == BuiltinKind::Never {
                    return self._join("void", name)
                }

                if self.fold_sizes {
                    var fk = self.size_fold(b->builtin)
                    if fk != b->builtin {
                        self.sizes_folded += 1
                        return self._join(builtin_info(fk)->cxx, name)
                    }
                }

                return self._join(b->cxx_emission(), name)
            } case TypeKind::RecordType {
                if self.auto_hidden && self.names_hidden_member(t) {
                    return self._join("auto", name)
                }

                return self._join(
                    self._record(cast<RecordType>(t), subst, scope),
                    name,
                )
            } case TypeKind::PointerType {
                return self.decl(
                    cast<PointerType>(t)->pointee,
                    "*" + name,
                    subst,
                    scope,
                )
            } case TypeKind::CXXLValueRefType {
                return self.decl(
                    cast<CXXLValueRefType>(t)->referee,
                    "&" + name,
                    subst,
                    scope,
                )
            } case TypeKind::CXXRValueRefType {
                return self.decl(
                    cast<CXXRValueRefType>(t)->referee,
                    "&&" + name,
                    subst,
                    scope,
                )
            } case TypeKind::FixedArrayType {
                var unsafe *a  = cast<FixedArrayType>(t)
                var        ext = ""
                if !a->is_incomplete {
                    ext = f"{a->size_bits}"
                }

                // `[T; N]` for a generic value parameter: the parameter, or
                // its instance's value (Compiler/Spec/Eval.md#generic-value-parameters).
                if a->extent_param != &null {
                    ext = self._type(a->extent_param, subst, scope)
                }

                // `[]` binds tighter than `*` and `&`: a pointer or reference
                // TO an array parenthesizes its declarator.
                var nm = name
                if nm.size() > 0 && (nm[0] == ('*' as u8) || nm[0] == ('&' as u8)) {
                    nm = "(" + nm + ")"
                }

                return self.decl(a->element, f"{nm}[{ext}]", subst, scope)
            }

            // A Kairo `fn(A) -> R` holds a capturing closure as well as a
            // function (closures.md: "no separate closure type"), so it is
            // the `::__kairo_fn<R(A...)>` value type, never a raw pointer:
            // a lambda with captures has no `R(*)(A...)`. It converts from a
            // function and back to one (for a C callee) on its own. Only a C
            // no-prototype pointer stays raw: no Kairo value has that type.
            case TypeKind::FunctionPointerType {
                var unsafe *f = cast<FunctionPointerType>(t)
                if f->is_unprototyped {
                    return self.decl(
                        f->return_type,
                        f"(*{name})()",
                        subst,
                        scope,
                    )
                }

                // `unsafe fn(A) -> R` is the plain `R(*)(A)`: one word,
                // called directly, what a C callee or field holds.
                // A convention leads the signature: inside a type-id clang takes
                // `__attribute__((preserve_most)) R(A)`, not a trailing one.
                // `noexcept` unless -funwind: every Kairo function is, so the
                // indirect call (`f->alloc(...)`) is a call, not an invoke
                // whose landing pad calls __clang_call_terminate. An imported
                // C++ function that is not noexcept does not convert to it.
                if f->is_raw {
                    var nx = ""
                    if self._cg == &null || !self._cg->opts.unwind {
                        nx = " noexcept"
                    }

                    return self._join(
                        "::" + LowerTargets::raw_fn() + "<" + CXXSpell::call_conv_attr(
                            f->call_conv,
                        ) + self.fn_signature(f, subst, scope) + nx + ">",
                        name,
                    )
                }

                return self._join(
                    "::" + LowerTargets::fn_value() + "<" + self.fn_signature(
                        f,
                        subst,
                        scope,
                    ) + ">",
                    name,
                )
            } case TypeKind::GenericParamType {
                return self._join(
                    self._gparam(cast<GenericParamType>(t), subst),
                    name,
                )
            }

            // `T::Node` is the witness's member type: `typename
            // ::ns::Graph_witness<T>::Node`. One template body, every
            // instance: each conformance's specialization declares it
            // (EmitWitness), so C++ selects the type per instance (Compiler/Spec/Generics.md
            // D2). Inside a witness, a base that is the interface's Self is
            // spelled as Self is there. `typename` always: it is allowed on
            // a qualified name that turns out not to be dependent.
            case TypeKind::AssocType {
                return self._join(
                    self.assoc_spelling(cast<AssocType>(t), subst, scope),
                    name,
                )
            }

            // A generic VALUE argument (`4` of `Buf<4>`): the integer.
            case TypeKind::TypeExpr {
                var unsafe *v = cast<TypeExpr>(t)
                if !v->is_value {
                    self._ice(
                        t_in->range,
                        "CXXSpell: an unfolded generic value argument reached codegen; TypeResolve folds every one",
                    )

                    return ""
                }

                return self._join(self.value(v, subst, scope), name)
            } case TypeKind::OpaqueFFIType {
                var unsafe *o = cast<OpaqueFFIType>(t)
                return self._join(o->text(), name)
            }

            // `T?` is spelled as the record NullableTypeLowering gave it; with
            // none, that pass never saw this canonical.
            case TypeKind::NullableType {
                var unsafe *lw = cast<NullableType>(t)->lowered
                if lw == &null {
                    self._ice(
                        t_in->range,
                        "CXXSpell: T? reached codegen with no lowered record; NullableTypeLowering must run first",
                    )

                    return ""
                }

                return self.decl(lw, name, subst, scope)
            } case TypeKind::TupleType {
                self._ice(
                    t_in->range,
                    "CXXSpell: TupleType canonical reached codegen; TypeResolve canonicalizes every tuple to its TupleN record",
                )

                return ""
            } default {
                self._ice(
                    t_in->range,
                    f"CXXSpell: {to_string(t->kind)} is not a canonical kind",
                )

                return ""
            }
        }
    }

    /// A canonical value (Compiler/Spec/Eval.md#value-nodes, 3) as the C++ expression that
    /// computes it: the integer, or the expression Sema kept (`(N + 1)`,
    /// `::m::f(3)`, `::m::K`), each operand spelled as a type argument is
    /// (a value parameter, or its instance's value under \p subst). Every
    /// operator application is parenthesized, so the text means the same as
    /// an array bound and as a template argument, where a bare `>>` would
    /// close the list.
    fn value(self,
             v:     unsafe *TypeExpr,
             subst: unsafe *InstanceEntry = &null,
             scope: unsafe *Decl = &null) -> string {
        if v->is_exact() {
            return if (v->vneg) => (f"-{v->vmag}") else => f"{v->vmag}"
        }

        match v->vop {
            case ValueOp::Decl {
                // An `eval for` binding is a local with no scope home: its
                // name, read from the table of the file it is written in.
                var unsafe *vd = dyn_cast<Declarations::VariableDecl>(v->vdecl)
                if vd != &null
                    && (vd->semantic_dc == &null || CXXSpell::in_function_scope(v->vdecl)) {
                    return self.tok_name(
                        vd->name,
                        self._cg->ctx->sm->get_fid(vd->name.range),
                    )
                }

                return self.qual_name(v->vdecl)
            } case ValueOp::Call {
                // An eval class's constructor (Compiler/Spec/Eval.md#eval-classes) is named by its
                // class; with no arguments, braced, or `X()` reads as a type.
                var isrec = isa<Declarations::ClassDecl>(v->vdecl)
                    || isa<Declarations::StructDecl>(v->vdecl)
                if isrec && v->vops.size() == 0 {
                    return self.qual_name(v->vdecl) + "{}"
                }

                var s = self.qual_name(v->vdecl) + "("
                for var i: usize = 0; i < v->vops.size(); ++i {
                    if i > 0 {
                        s += ", "
                    }

                    s += self._type(v->vops[i], subst, scope)
                }

                return s + ")"
            } case ValueOp::Unary {
                var sym = if (v->vtok == TokenKind::OpTilde) => ("~") else => "-"
                return "(" + sym + self._type(v->vops[0], subst, scope) + ")"
            } case ValueOp::Binary {
                return "(" + self._type(v->vops[0], subst, scope) + " " + CXXSpell::value_op(
                    v->vtok,
                ) + " " + self._type(v->vops[1], subst, scope) + ")"
            } case ValueOp::Cast {
                return "static_cast<" + self._type(v->vty, subst, scope) + ">(" + self._type(
                    v->vops[0],
                    subst,
                    scope,
                ) + ")"
            } case ValueOp::Str {
                // The literal constructor over the bytes, as a compile-time
                // literal is built in a body (Compiler/Spec/Eval.md#strings-at-compile-time): `__kairo_estr<...>`
                // or, past the inline limit, the named array EmitPlan
                // collected (note_eval_str). One object per content, so two
                // spellings of one value are template-argument-equivalent.
                var n    = (v->vmag as usize)
                var data = ""
                if n > LowerTargets::eval_str_inline_max() {
                    data = "::" + LowerTargets::eval_str_hashed(
                        LowerTargets::eval_str_hash(v->vbytes, n),
                        n,
                    )
                } else {
                    data = "::" + LowerTargets::eval_str() + "<"
                    for var i: usize = 0; i < n; ++i {
                        if i > 0 {
                            data += ", "
                        }

                        data += f"{(v->vbytes[i] as u32)}"
                    }

                    data += ">"
                }

                var cp: usize = 0
                for var i: usize = 0; i < n; ++i {
                    if (v->vbytes[i] & (0xC0 as u8)) != (0x80 as u8) {
                        cp += 1
                    }
                }

                return self._type(
                    v->vty,
                    subst,
                    scope,
                ) + "(" + data + ", " + f"{n}" + ", " + f"{cp}" + ")"
            } default {
                return ""
            }
        }
    }

    /// The C++ operator for a computed value's binary operator; Kairo's
    /// keyword forms were normalized to these by TypeResolve.
    static fn value_op(k: TokenKind) -> string {
        match k {
            case TokenKind::OpPlus {
                return "+"
            } case TokenKind::OpMinus {
                return "-"
            } case TokenKind::OpStar {
                return "*"
            } case TokenKind::OpSlash {
                return "/"
            } case TokenKind::OpPercent {
                return "%"
            } case TokenKind::OpPipe {
                return "|"
            } case TokenKind::OpAmp {
                return "&"
            } case TokenKind::OpCaret {
                return "^"
            } case TokenKind::OpLessLess {
                return "<<"
            } case TokenKind::OpGreaterGreater {
                return ">>"
            } default {
                return "?"
            }
        }
    }

    /// `R(A...)`, the function type a `fn(A) -> R` value wraps: each
    /// parameter in its mode's abstract spelling, `!` as `void`.
    fn fn_signature(self,
                    f:     unsafe *FunctionPointerType,
                    subst: unsafe *InstanceEntry = &null,
                    scope: unsafe *Decl = &null) -> string {
        var ps = ""
        for var i: usize = 0; i < f->params.size(); ++i {
            if i > 0 {
                ps += ", "
            }

            ps += self._param_type(
                f->params[i],
                f->modes[i],
                false,
                "",
                subst,
                scope,
            )
        }

        // A panicking `fn` type's value returns its panic result (§4.1).
        var unsafe *canon = if (f->canonical != &null
                                && isa<FunctionPointerType>(
                                    canon_unqual(f->canonical),
                                )) => (cast<FunctionPointerType>(
                                canon_unqual(f->canonical),
                            ))
                            else => f
        if canon->panic_result != &null {
            return self.decl(canon->panic_result, f"({ps})", subst, scope)
        }

        return self.decl(f->return_type, f"({ps})", subst, scope)
    }

    /// A parameter's C++ type from its mode (AST/ParamMode.k rules, as
    /// EmitIR documents them). \p is_const is the `const x: T` marker.
    fn param_type(self,
                  p:     unsafe *Declarations::ParamDecl,
                  subst: unsafe *InstanceEntry = &null,
                  scope: unsafe *Decl = &null) -> string {
        // A type pack is `T...` (the C++ parameter pack); under an instance it
        // is that instance's elements, one parameter each.
        if DeclFacts::param_is_type_pack(p) {
            var unsafe *g = DeclFacts::param_type_pack_param(p)
            var        cq = if (p->is_const) => ("const ") else => ""
            // A by-value (or `@move`) pack is `T&&... xs`: each layer
            // binds its caller's object instead of copying it, and an
            // expansion forwards it on (EmitIR::_pack_expansion). The
            // instance's elements are value types, so under one each is
            // `E&&` and the caller hands it an rvalue (EmitIR::_args).
            var rr  = if (CXXSpell::forwarding_pack(p)) => ("&&") else => ""
            var els = cxx::std::vector<unsafe *Type>()
            if self.subst_pack(g, subst, &els) {
                var ps = ""
                for var i: usize = 0; i < els.size(); ++i {
                    if i > 0 {
                        ps += ", "
                    }

                    var unsafe *e = canon_unqual(els[i])
                    var        er = rr
                    if e != &null && (isa<CXXLValueRefType>(e) || isa<CXXRValueRefType>(e)) {
                        er = ""
                    }

                    ps += cq + self._type(els[i], &null, scope) + er
                }

                return ps
            }

            return cq + self._gparam(g, &null, rr)
        }

        if p->is_pack {
            if p->pack_type == &null {
                self._ice(
                    p->range,
                    "CXXSpell: pack parameter with no slice type; CallLowering stamps it",
                )
            }

            return (if (p->is_const) => ("const ") else => "") + self._type(
                p->pack_type,
                subst,
                scope,
            )
        }

        return self._param_type(
            p->type_,
            p->mode,
            CXXSpell::const_param(p),
            "",
            subst,
            scope,
        )
    }

    /// The parameter is spelled as a `const` one: written `const x: T`, or a
    /// by-value COPY record its function never mutates
    /// (ParamPassInference). Only a record is ever inferred, so an inferred
    /// one always takes _param_type's `const T&` arm; a written `const` on a
    /// scalar stays `const T`.
    static fn const_param(p: unsafe *Declarations::ParamDecl) -> bool {
        return p != &null && (p->is_const || p->inferred_const)
    }

    /// A by-value parameter of \p f that C++ declares as a reference,
    /// `const T&` (a concrete record, `const` or inferred): its `fn` type's
    /// by-value parameter is a different C++ type, so a `fn` value of \p f
    /// goes through an adapter (EmitIR::_fn_ref_adapter).
    static fn by_ref_value_param(p: unsafe *Declarations::ParamDecl) -> bool {
        if p == &null || p->is_self || p->is_pack || p->mode != ParamMode::Value {
            return false
        }

        if !CXXSpell::const_param(p) {
            return false
        }

        if p->type_ == &null || p->type_->canonical == &null {
            return false
        }

        var unsafe *c = p->type_->canonical
        return c->kind == TypeKind::RecordType && !c->is_dependent()
    }

    /// `type name` for a parameter, name folded into the declarator for
    /// EVERY type, never `param_type(p) + " " + name`: a function pointer
    /// spelled that way is `U(*)(T) f`, which clang reads as a cast-like
    /// expression ("expected ')'", "undeclared identifier 'f'"); the name
    /// belongs inside, `U (*f)(T)`. An array is still its own branch:
    /// `[T; N]` is passed by reference (`const T (&xs)[N]` / `T (&xs)[N]`),
    /// never by value (StmtTyping rejects that). Empty \p name is the
    /// abstract form. \p scope as for _type.
    fn param_decl(self,
                  p:          unsafe *Declarations::ParamDecl,
                  const name: string,
                  subst:      unsafe *InstanceEntry = &null,
                  scope:      unsafe *Decl = &null) -> string {
        var unsafe *c = if (p->type_ != &null) => (p->type_->canonical) else => &null
        if !p->is_pack && c != &null && canon_unqual(c)->kind == TypeKind::FixedArrayType {
            if p->mode == ParamMode::Value && !p->is_const {
                self._ice(
                    p->range,
                    "CXXSpell: array parameter by value; StmtTyping must reject it",
                )
            }

            var s = self.decl(canon_unqual(c), "&" + name, subst, scope)
            return (if (p->is_const) => ("const " + s) else => s)
        }

        if p->is_pack {
            var s = self.param_type(p, subst, scope)
            if name.size() > 0 {
                s += " " + name
            }

            return s
        }

        return self._param_type(
            p->type_,
            p->mode,
            CXXSpell::const_param(p),
            name,
            subst,
            scope,
        )
    }

    /// The mode's reference and the const marker folded into decl(), so a
    /// name lands inside the declarator: `@inout` on a function pointer is
    /// `U (*&f)(T)`, which decl() brackets as it does any `*`/`&` declarator.
    /// A `fn` type's parameter \p t in mode \p mode, declared as \p name
    /// (a wrapper lambda's parameter, EmitIR::_fn_effect_value).
    fn param_named(self, t: unsafe *Type, mode: ParamMode, const name: string) -> string {
        return self._param_type(t, mode, false, name, &null, &null)
    }

    priv fn _param_type(self,
                        t:          unsafe *Type,
                        mode:       ParamMode,
                        is_const:   bool,
                        const name: string,
                        subst:      unsafe *InstanceEntry,
                        scope:      unsafe *Decl) -> string {
        // `const T&` only from a stamped `@copy fn X(self, const other: Self)`
        // (ClassLifecycle); nothing else sets Inout together with `const`.
        if mode == ParamMode::Inout {
            var s = self.decl(t, self._ref_declarator("&", name), subst, scope)
            return if (is_const) => ("const " + s) else => s
        }

        if mode == ParamMode::Move {
            return self.decl(t, self._ref_declarator("&&", name), subst, scope)
        }

        if is_const {
            // `T const&` for a bare type parameter (it may be a record: a
            // `const k: K` lookup in a `{K: V}` must not copy a string key
            // per call), `const T&` for a record, `const T` otherwise.
            var unsafe *c = t->canonical
            // East const for the parameter: an instance's explicit
            // instantiation spells T as text (`int *`), and `const int *&`
            // would be a reference to a pointer to const, not `T const&`.
            if c != &null
                && c->kind == TypeKind::GenericParamType
                && !cast<GenericParamType>(c)->is_pack {
                return self.decl(
                    t,
                    self._ref_declarator("const&", name),
                    subst,
                    scope,
                )
            }

            // A generic record's own instance type (`const other: Q<T>`) is a
            // record in every instance, so it is `const Q<T>&` as well: by
            // value, a move-only Q (an ArenaList field) could not be passed
            // at all.
            if c != &null && c->kind == TypeKind::RecordType {
                return "const " + self.decl(
                    t,
                    self._ref_declarator("&", name),
                    subst,
                    scope,
                )
            }

            return "const " + self.decl(t, name, subst, scope)
        }

        return self.decl(t, name, subst, scope)
    }

    /// `& name`, keeping the `T& x` spelling the printed C++ has always had
    /// (and that tests match); bare `&` for the abstract form.
    priv fn _ref_declarator(self, sigil: string, const name: string) -> string {
        if name.size() == 0 {
            return sigil
        }

        return sigil + " " + name
    }

    /// `<a, b>` from an instance's args or a pattern's own params.
    /// The fixed-width builtin \p k IS in C++ on this target: `usize` /
    /// `isize` become the integer of the pointer width where the target
    /// says size_t / ptrdiff_t is it (target.usize_is_fixed, as RedeclMerge
    /// and PanicTypeIds read it); \p k itself otherwise, and on Darwin,
    /// where they are C++ types of their own. An unfilled invocation is the
    /// 64-bit host.
    fn size_fold(self, k: BuiltinKind) -> BuiltinKind {
        if k != BuiltinKind::USize && k != BuiltinKind::ISize {
            return k
        }

        var        sgn         = k == BuiltinKind::ISize
        var        fixed       = true
        var        pw:   usize = 64
        var unsafe *ci         = self._cg->ctx->ci
        if ci != &null {
            fixed = if (sgn) => (ci->target.isize_is_fixed) else => ci->target.usize_is_fixed
            if ci->target.pointer_width != (0 as usize) {
                pw = ci->target.pointer_width
            }
        }

        if !fixed {
            return k
        }

        if pw == (16 as usize) {
            return if (sgn) => (BuiltinKind::I16) else => BuiltinKind::U16
        }

        if pw == (32 as usize) {
            return if (sgn) => (BuiltinKind::I32) else => BuiltinKind::U32
        }

        if pw == (64 as usize) {
            return if (sgn) => (BuiltinKind::I64) else => BuiltinKind::U64
        }

        return k
    }

    fn args_str(self,
                const args: cxx::std::vector<unsafe *Type>,
                subst:      unsafe *InstanceEntry = &null,
                scope:      unsafe *Decl = &null) -> string {
        var s = "<"
        for var i: usize = 0; i < args.size(); ++i {
            if i > 0 {
                s += ", "
            }

            s += self._type((args)[i], subst, scope)
        }

        s += ">"
        return s
    }

    /// # Dependent-qualified names

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
    fn dependent_member_type(self,
                             record:     unsafe *Type,
                             const leaf: string,
                             args:       unsafe *cxx::std::vector<unsafe *Type> = &null,
                             subst:      unsafe *InstanceEntry = &null,
                             scope:      unsafe *Decl = &null) -> string {
        if record == &null || record->canonical == &null {
            kairo::std::ice_fail(
                "CXXSpell: dependent_member_type with no canonical qualifier",
            )
        }

        var unsafe *q    = canon_unqual(record->canonical)
        var        targs = ""
        if args != &null && args->size() > 0 {
            targs = self.args_str(*args, subst, scope)
        }

        return CXXSpell::_member_type(
            self._type(q, subst, scope),
            q->is_dependent(),
            leaf,
            targs,
        )
    }

    /// \p t names an associated type anywhere inside it (`Self::Node`,
    /// `[Self::Node]`): a witness member whose signature does is served by
    /// the specializations alone (EmitWitness).
    static fn mentions_assoc(t: unsafe *Type) -> bool {
        if t == &null {
            return false
        }

        var unsafe *c = t->canonical
        if c == &null {
            c = t
        }

        match c->kind {
            case TypeKind::AssocType {
                return true
            } case TypeKind::QualifiedType {
                return CXXSpell::mentions_assoc(cast<QualifiedType>(c)->inner)
            } case TypeKind::PointerType {
                return CXXSpell::mentions_assoc(cast<PointerType>(c)->pointee)
            } case TypeKind::NullableType {
                return CXXSpell::mentions_assoc(cast<NullableType>(c)->inner)
            } case TypeKind::FixedArrayType {
                return CXXSpell::mentions_assoc(
                    cast<FixedArrayType>(c)->element,
                )
            } case TypeKind::CXXLValueRefType {
                return CXXSpell::mentions_assoc(
                    cast<CXXLValueRefType>(c)->referee,
                )
            } case TypeKind::CXXRValueRefType {
                return CXXSpell::mentions_assoc(
                    cast<CXXRValueRefType>(c)->referee,
                )
            } case TypeKind::RecordType {
                var unsafe *r = cast<RecordType>(c)
                for var i: usize = 0; i < r->args.size(); ++i {
                    if CXXSpell::mentions_assoc(*r->args.get(i)) {
                        return true
                    }
                }

                return false
            } case TypeKind::FunctionPointerType {
                var unsafe *f = cast<FunctionPointerType>(c)
                for var i: usize = 0; i < f->params.size(); ++i {
                    if CXXSpell::mentions_assoc(*f->params.get(i)) {
                        return true
                    }
                }

                return CXXSpell::mentions_assoc(f->return_type)
            } default {
                return false
            }
        }
    }

    /// The text of dependent_member_type from an already-spelled qualifier.
    static fn _member_type(const q:     string,
                           dependent:   bool,
                           const leaf:  string,
                           const targs: string) -> string {
        if !dependent {
            return q + "::" + leaf + targs
        }

        if targs.size() == 0 {
            return "typename " + q + "::" + leaf
        }

        return "typename " + q + "::template " + leaf + targs
    }

    /// \p d's C++ template parameters: an extension member's extension's,
    /// then its own. One list; a non-member function takes one.
    static fn template_params(d: unsafe *Decl) -> cxx::std::vector<unsafe *Declarations::GenericParamDecl> {
        var out = cxx::std::vector<unsafe *Declarations::GenericParamDecl>()
        var unsafe *ext = DeclFacts::decl_extension_of(d)
        if ext != &null {
            var eps = DeclFacts::decl_generic_params(
                unsafe (ext as unsafe *Decl),
            )

            for var i: usize = 0; i < eps.size(); ++i {
                out.push_back(eps[i])
            }
        }

        var gps = DeclFacts::decl_generic_params(d)
        for var i: usize = 0; i < gps.size(); ++i {
            out.push_back(gps[i])
        }

        return out
    }

    /// The instance argument \p g stands for in \p subst, or null. Keyed on
    /// the GenericParamDecl's identity in the primary's template_params, so
    /// an extension's T, a member's own U and a default thunk's borrowed
    /// list (the callee's GenericParamDecls) all resolve the same way.
    /// A pack parameter's elements under \p subst, appended to \p out: every
    /// instance argument from the pack's position on (InstanceEntry::args
    /// keeps packs flat, so the pack is the tail). False when \p subst does
    /// not bind \p g.
    fn subst_pack(self,
                  g:          unsafe *GenericParamType,
                  subst:      unsafe *InstanceEntry,
                  @inout out: cxx::std::vector<unsafe *Type>) -> bool {
        if g == &null || g->owner == &null || subst == &null || !g->is_pack {
            return false
        }

        var own = DeclFacts::decl_generic_params(CXXSpell::rep(g->owner))
        var idx = (g->param_index as usize)
        if idx >= own.size() {
            return false
        }

        var unsafe *gp = own[idx]
        var tps = CXXSpell::template_params(CXXSpell::rep(subst->primary))
        for var k: usize = 0; k < tps.size(); ++k {
            if tps[k] != gp {
                continue
            }

            for var j: usize = k; j < subst->args.size(); ++j {
                out.push_back(subst->args[j])
            }

            return true
        }

        return false
    }

    fn subst_for(self, g: unsafe *GenericParamType, subst: unsafe *InstanceEntry) -> unsafe *Type {
        if g == &null || g->owner == &null || subst == &null {
            return &null
        }

        var own = DeclFacts::decl_generic_params(CXXSpell::rep(g->owner))
        var idx = (g->param_index as usize)
        if idx >= own.size() {
            return &null
        }

        var unsafe *gp = own[idx]
        var tps = CXXSpell::template_params(CXXSpell::rep(subst->primary))
        for var k: usize = 0; k < tps.size(); ++k {
            if tps[k] != gp {
                continue
            }

            if k >= subst->args.size() {
                kairo::std::ice_fail(
                    "CXXSpell: instance args shorter than the primary's template parameters",
                )
            }

            return subst->args[k]
        }

        return &null
    }

    /// An extension member's receiver parameter, unnamed: `[const ]X*`, or
    /// `[const ]X&` for an operator ([over.oper]/7 wants a class type).
    fn ext_receiver(self,
                    f:     unsafe *Declarations::FunctionDecl,
                    x:     unsafe *Declarations::ExtensionDecl,
                    subst: unsafe *InstanceEntry = &null) -> string {
        var s = ""
        if f->is_const() {
            s += "const "
        }

        // A C array's declarator wraps the name (`int (*self)[2]`), and every
        // caller appends the name after this text (`extend [i32; 2]`).
        s += self.type_specifier(x->target, subst)
        s += if (f->is_operator) => ("&") else => "*"
        return s
    }

    /// # Witnesses (Compiler/Spec/Witnesses.md)

    /// `namespace std`'s segments: where a std::hash adapter is written
    /// (EmitWitness::_std_hash_decl).
    static fn std_ns() -> cxx::std::vector<string> {
        var v = cxx::std::vector<string>()
        v.push_back("std")
        return v
    }

    /// `::ns::I_witness`: the class template a bound call goes through.
    fn witness_name(self, iface: unsafe *Decl) -> string {
        return self._iface_qual(iface) + LowerTargets::witness_suffix()
    }

    /// `::ns::I_c`: the concept an interface bound renders as.
    /// An imported C++ concept is its own C++ name (`::Addable`): the bound
    /// IS that concept, and the `I_c` stand-in is written only beside the
    /// Kairo file's own pieces, under the header's module namespace, which
    /// a kcc header layout of the file does not contain ("no member
    /// named 'my_code' in the global namespace").
    fn concept_name(self, iface: unsafe *Decl) -> string {
        var unsafe *r = CXXSpell::rep(iface)
        if DeclFacts::decl_is_imported(r) {
            return DeclFacts::decl_cxx_spelling(r)
        }

        return self._iface_qual(iface) + LowerTargets::concept_suffix()
    }

    /// `::ns::I`, the prefix both names share. An interface nested in a
    /// type would put its witness inside a class, where a specialization
    /// cannot be declared; none reaches here yet.
    priv fn _iface_qual(self, iface: unsafe *Decl) -> string {
        var unsafe *r = CXXSpell::rep(iface)
        if self.owner_types(r).size() > 0 {
            self._ice(
                r->range,
                "CXXSpell: a witness for an interface nested in a type; no naming rule for it yet",
            )
        }

        var s  = ""
        var ns = self.ns_segments(r)
        for var i: usize = 0; i < ns.size(); ++i {
            s += "::"
            s += ns[i]
        }

        return s + "::" + self.leaf(r)
    }

    /// `typename ::ns::I_witness<B, A...>::Node` for associated type \p a.
    ///
    /// The witness is the BOUND's (`G impl Big`, Big derives Graph:
    /// `Big_witness<G>::Node`), since rows -- and so specializations -- exist
    /// for the bound, not for the interface that declares the requirement.
    /// A base that is an interface's Self is only ever spelled inside a
    /// witness: there the bare member name (a specialization) or
    /// assoc_self_qual (a concept).
    fn assoc_spelling(self,
                      a:     unsafe *AssocType,
                      subst: unsafe *InstanceEntry = &null,
                      scope: unsafe *Decl = &null) -> string {
        var leaf = self.leaf(a->assoc)
        // A generic associated type is the witness's member alias template
        // (`template <class K> using Map = ...`), named with its arguments.
        var targs = ""
        if a->args.size() > 0 {
            targs = "<"
            for var i: usize = 0; i < a->args.size(); ++i {
                if i > 0 {
                    targs += ", "
                }

                targs += self._type(a->args[i], subst, scope)
            }

            targs += ">"
        }

        var unsafe *b = canon_unqual(a->base)
        if isa<RecordType>(b)
            && isa<Declarations::InterfaceDecl>(
                CXXSpell::rep(
                    DeclFacts::decl_pattern(
                        CXXSpell::rep(cast<RecordType>(b)->decl),
                    ),
                ),
            ) {
            if self.assoc_self_qual.size() == 0 {
                return leaf + targs
            }

            if targs.size() > 0 {
                return "typename " + self.assoc_self_qual + "::template " + leaf + targs
            }

            return "typename " + self.assoc_self_qual + "::" + leaf
        }

        var unsafe *via = a->iface
        var unsafe *g   = dyn_cast<GenericParamType>(b)
        if g != &null {
            var unsafe *bt = self._assoc_bound(g, a)
            if bt != &null {
                via = bt
            }
        }

        // Reached through another associated type (`T::Item::Inner`): the
        // bound of THAT type that requires this one, as Sema read it
        // (AssocType::bounds) -- rows, and so specializations, exist for the
        // bound, not for the interface that declares the requirement.
        var unsafe *ab = dyn_cast<AssocType>(b)
        if ab != &null {
            var unsafe *bt2 = self._assoc_bound_of(ab, a)
            if bt2 != &null {
                via = bt2
            }
        }

        var unsafe *ic = canon_unqual(via)
        if ic == &null || !isa<RecordType>(ic) {
            self._ice(
                a->range,
                "CXXSpell: an associated type through a non-interface",
            )

            return ""
        }

        var unsafe *idecl = CXXSpell::rep(
            DeclFacts::decl_pattern(CXXSpell::rep(cast<RecordType>(ic)->decl)),
        )

        var q = self.witness_name(idecl) + self.witness_args(
            self._type(a->base, subst, scope),
            via,
            subst,
        )

        return CXXSpell::_member_type(q, true, leaf, targs)
    }

    /// The bound of associated type \p base (its cached, substituted
    /// bounds) whose interface requires \p a's associated type, or null.
    priv fn _assoc_bound_of(self, base: unsafe *AssocType, a: unsafe *AssocType) -> unsafe *Type {
        if base->bounds_state != 2 {
            return &null
        }

        var unsafe *want = CXXSpell::rep(a->assoc)
        for var i: usize = 0; i < base->bounds.size(); ++i {
            var unsafe *bt = canon_unqual(base->bounds[i])
            if bt == &null || !isa<RecordType>(bt) {
                continue
            }

            var unsafe *idecl = dyn_cast<Declarations::InterfaceDecl>(
                CXXSpell::rep(
                    DeclFacts::decl_pattern(
                        CXXSpell::rep(cast<RecordType>(bt)->decl),
                    ),
                ),
            )

            if idecl == &null || idecl->compose_state != 2 {
                continue
            }

            for var j: usize = 0; j < idecl->requirements.size(); ++j {
                if CXXSpell::rep(idecl->requirements.get(j)->decl) == want {
                    return bt
                }
            }
        }

        return &null
    }

    /// The bound of \p g whose interface requires \p a's associated type
    /// (itself or through what it derives), or null.
    priv fn _assoc_bound(self, g: unsafe *GenericParamType, a: unsafe *AssocType) -> unsafe *Type {
        if g->owner == &null {
            return &null
        }

        var cs = cxx::std::vector<unsafe *ConstraintExpr>()
        CXXSpell::impl_bounds(
            DeclFacts::decl_requires_clause(CXXSpell::rep(g->owner)),
            unsafe &cs,
        )

        var unsafe *want = CXXSpell::rep(a->assoc)
        for var i: usize = 0; i < cs.size(); ++i {
            var unsafe *c  = cs[i]
            var unsafe *id = dyn_cast<NamedIdentExpr>(c->lhs)
            if id == &null {
                continue
            }

            var unsafe *gp = dyn_cast<Declarations::GenericParamDecl>(
                id->resolved_decl,
            )

            if gp == &null || gp->index != g->param_index {
                continue
            }

            if c->rhs == &null || c->rhs->canonical == &null {
                continue
            }

            var unsafe *bt = canon_unqual(c->rhs->canonical)
            if !isa<RecordType>(bt) {
                continue
            }

            var unsafe *idecl = dyn_cast<Declarations::InterfaceDecl>(
                CXXSpell::rep(
                    DeclFacts::decl_pattern(
                        CXXSpell::rep(cast<RecordType>(bt)->decl),
                    ),
                ),
            )

            if idecl == &null || idecl->compose_state != 2 {
                continue
            }

            for var j: usize = 0; j < idecl->requirements.size(); ++j {
                if CXXSpell::rep(idecl->requirements.get(j)->decl) == want {
                    return bt
                }
            }
        }

        return &null
    }

    /// `<Self, A...>`: a witness's or concept's arguments for interface
    /// instance \p iface, Self already spelled as \p self_s.
    fn witness_args(self,
                    const self_s: string,
                    iface:        unsafe *Type,
                    subst:        unsafe *InstanceEntry = &null) -> string {
        var s = "<" + self_s
        var v = self.iface_args(iface)
        for var i: usize = 0; i < v.size(); ++i {
            s += ", "
            s += self._type(v[i], subst)
        }

        return s + ">"
    }

    /// The arguments of interface instance \p iface, in parameter order.
    fn iface_args(self, iface: unsafe *Type) -> cxx::std::vector<unsafe *Type> {
        var        v  = cxx::std::vector<unsafe *Type>()
        var unsafe *c = canon_unqual(iface)
        if c == &null || !isa<RecordType>(c) {
            return v
        }

        var unsafe *r = cast<RecordType>(c)
        var unsafe *d = r->decl
        if DeclFacts::decl_is_instance(d) {
            var unsafe *e = self._cg->instances->entry_of(d)
            if e == &null {
                self._ice(
                    d->range,
                    "CXXSpell: interface instance with no registry entry",
                )
            }

            for var i: usize = 0; i < e->args.size(); ++i {
                v.push_back(e->args[i])
            }

            return v
        }

        for var i: usize = 0; i < r->args.size(); ++i {
            v.push_back(r->args[i])
        }

        return v
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
    fn requires_clause(self, d: unsafe *Decl) -> string {
        var tps = CXXSpell::template_params(d)
        if tps.size() == 0 {
            return ""
        }

        var        cs = cxx::std::vector<unsafe *ConstraintExpr>()
        var unsafe *x = DeclFacts::decl_extension_of(d)
        if x != &null {
            CXXSpell::impl_bounds(
                DeclFacts::decl_requires_clause(unsafe (x as unsafe *Decl)),
                unsafe &cs,
            )
        }

        CXXSpell::impl_bounds(DeclFacts::decl_requires_clause(d), unsafe &cs)
        // A primary record's head carries none of its interface bounds
        // (bound_asserts): C++ checks a class template's constraints where
        // the template-id is NAMED, and a class names an instance over
        // itself while it is still incomplete -- the CRTP base-specifier
        // `class Seven : Mixin<Seven>`, a field `*Holder<Node>` in Node --
        // where no concept on it can hold yet. The bound is Kairo's anyway
        // (D0: ConformanceChecking proved it at the use); the instance's
        // home pins it once the class is complete.
        var deferred = CXXSpell::defers_bounds(d)
        var s        = ""
        for var i: usize = 0; i < cs.size(); ++i {
            var unsafe *c = cs[i]
            if c->rhs == &null || c->rhs->canonical == &null {
                continue
            }

            var unsafe *gp = CXXSpell::_bound_param(c)
            if gp == &null {
                continue
            }

            if deferred && gp->owner != &null && CXXSpell::rep(gp->owner) == CXXSpell::rep(d) {
                continue
            }

            var mine = false
            for var k: usize = 0; k < tps.size(); ++k {
                if tps[k] == gp {
                    mine = true
                    break
                }
            }

            if !mine {
                continue
            }

            var unsafe *rhs = canon_unqual(c->rhs->canonical)
            if !isa<RecordType>(rhs) {
                continue
            }

            var unsafe *idecl = CXXSpell::rep(
                DeclFacts::decl_pattern(
                    CXXSpell::rep(cast<RecordType>(rhs)->decl),
                ),
            )

            if !isa<Declarations::InterfaceDecl>(idecl) {
                continue
            }

            s += if (s.size() == 0) => (" requires (") else => " && "
            var conj = self.concept_name(idecl) + self.witness_args(
                self.tparam_name(gp, CXXSpell::rep(gp->owner)),
                rhs,
            )

            // A pack's bound holds of every element: a fold, since a
            // constraint naming the pack unexpanded is ill-formed.
            if gp->is_pack {
                conj = "(" + conj + " && ...)"
            }

            s += conj
        }

        // A record's VALUE predicates (`class <T> B requires sizeof T <= 128`)
        // as C++ constraints, so clang rejects a bad instance where it is
        // named (Compiler/Spec/Eval.md#evaluation-model, E10). Only one that names nothing but the
        // record's own parameters, literals and sizeof / alignof is
        // spelled: the head is written before every other declaration, and
        // a constant or function it named would not be declared yet. The
        // rest are static_asserts in the record's body (body_predicates). A
        // function's predicates are its body's static_asserts (EmitIR::_body).
        // An enum's are its ADT record's: the record is written under
        // the enum's own head (InterfaceEmitter::_adt_def).
        if isa<Declarations::ClassDecl>(d)
            || isa<Declarations::StructDecl>(d)
            || isa<Declarations::UnionDecl>(d)
            || isa<Declarations::EnumDecl>(d) {
            var vps = cxx::std::vector<unsafe *Expr>()
            CXXSpell::value_predicates(
                DeclFacts::decl_requires_clause(d),
                unsafe &vps,
            )

            for var i: usize = 0; i < vps.size(); ++i {
                var t = self._pred_text(vps[i])
                if t.size() == 0 {
                    continue
                }

                s += if (s.size() == 0) => (" requires (") else => " && "
                s += "(" + t + ")"
            }
        }

        // Parenthesized: what follows the head is often a return type that
        // starts with `::` (`::builtin::Tuple2<...> f(...)`), and C++ reads a
        // `::` after `I_c<T>` as continuing the concept's qualified name --
        // no spacing separates them, only the closing paren.
        if s.size() > 0 {
            s += ")"
        }

        return s
    }

    /// \p d is a generic record PRIMARY, whose interface bounds stay off its
    /// template head (requires_clause). A partial specialization keeps its
    /// clause: there it selects, and dropping it would let C++ pick the
    /// partial where Kairo did not. Functions keep theirs (their concept is
    /// in the mangled name, Compiler/Spec/Witnesses.md#the-concept).
    static fn defers_bounds(d0: unsafe *Decl) -> bool {
        if d0 == &null {
            return false
        }

        var unsafe *d = CXXSpell::rep(d0)
        if !(isa<Declarations::ClassDecl>(d)
            || isa<Declarations::StructDecl>(d)
            || isa<Declarations::UnionDecl>(d)
            || isa<Declarations::EnumDecl>(d)) {
            return false
        }

        var k = DeclFacts::decl_spec_kind(d)
        return k == Declarations::SpecKind::Primary || k == Declarations::SpecKind::None
    }

    /// Kairo class \p d0 has a virtual destructor: its own `virtual` /
    /// `override fn op finally`, or a Kairo base's (C++ makes the derived one
    /// virtual then, written or not). Such a class carries the hidden
    /// `__kairo_layout()` (InterfaceEmitter::_layout_virtual) that
    /// `__builtin_dynamic_size` / `_align` read. An imported base is not
    /// looked into: it has no `__kairo_layout()` to override, and the
    /// intrinsic's body refuses a polymorphic T without one.
    static fn has_virtual_dtor(d0: unsafe *Decl, depth: u32 = 0) -> bool {
        if d0 == &null || depth > 64 {
            return false
        }

        var unsafe *cd = dyn_cast<Declarations::ClassDecl>(
            CXXSpell::rep(DeclFacts::decl_pattern(CXXSpell::rep(d0))),
        )

        if cd == &null || DeclFacts::decl_is_imported(cd) {
            return false
        }

        for var i: usize = 0; i < cd->methods.size(); ++i {
            var unsafe *m = cd->methods[i]
            if m == &null || !m->is_operator || m->op_token.size() == 0 {
                continue
            }

            if m->op_token[0].kind != TokenKind::KwFinally {
                continue
            }

            if m->abi == Declarations::AbiKind::Virtual
                || m->abi == Declarations::AbiKind::Override {
                return true
            }
        }

        for var i: usize = 0; i < cd->derives_list.size(); ++i {
            var unsafe *e = cd->derives_list.get(i)
            if e == &null || e->base == &null || e->base->canonical == &null {
                continue
            }

            var unsafe *bc = canon_unqual(e->base->canonical)
            if !isa<RecordType>(bc) {
                continue
            }

            if CXXSpell::has_virtual_dtor(cast<RecordType>(bc)->decl, depth + 1) {
                return true
            }
        }

        return false
    }

    /// A Kairo base of \p d0 has a virtual destructor, so \p d0's
    /// `__kairo_layout()` overrides that base's and says so.
    static fn layout_overrides(d0: unsafe *Decl) -> bool {
        if d0 == &null {
            return false
        }

        var unsafe *cd = dyn_cast<Declarations::ClassDecl>(
            CXXSpell::rep(DeclFacts::decl_pattern(CXXSpell::rep(d0))),
        )

        if cd == &null {
            return false
        }

        for var i: usize = 0; i < cd->derives_list.size(); ++i {
            var unsafe *e = cd->derives_list.get(i)
            if e == &null || e->base == &null || e->base->canonical == &null {
                continue
            }

            var unsafe *bc = canon_unqual(e->base->canonical)
            if isa<RecordType>(bc) && CXXSpell::has_virtual_dtor(cast<RecordType>(bc)->decl, 1) {
                return true
            }
        }

        return false
    }

    /// `static_assert(::ns::I_c<A, ...>, "...");` for each interface bound
    /// requires_clause kept off primary record \p d's head, at instance
    /// \p ie: written beside the home's explicit instantiation, where the
    /// arguments are complete, so a C++ disagreement with Kairo's check is
    /// still an error there. A pack parameter's bound is not pinned (no one
    /// argument to spell).
    fn bound_asserts(self,
                     d0: unsafe *Decl,
                     ie: unsafe *InstanceEntry) -> cxx::std::vector<string> {
        var out = cxx::std::vector<string>()
        if ie == &null || !CXXSpell::defers_bounds(d0) {
            return out
        }

        var unsafe *d = CXXSpell::rep(d0)
        var        cs = cxx::std::vector<unsafe *ConstraintExpr>()
        CXXSpell::impl_bounds(DeclFacts::decl_requires_clause(d), unsafe &cs)
        for var i: usize = 0; i < cs.size(); ++i {
            var unsafe *c = cs[i]
            if c->rhs == &null || c->rhs->canonical == &null {
                continue
            }

            var unsafe *gp = CXXSpell::_bound_param(c)
            if gp == &null || gp->is_pack || gp->owner == &null || CXXSpell::rep(gp->owner) != d {
                continue
            }

            var at = (gp->index as usize)
            if at >= ie->args.size() {
                continue
            }

            var unsafe *rhs = canon_unqual(c->rhs->canonical)
            if !isa<RecordType>(rhs) {
                continue
            }

            var unsafe *idecl = CXXSpell::rep(
                DeclFacts::decl_pattern(
                    CXXSpell::rep(cast<RecordType>(rhs)->decl),
                ),
            )

            if !isa<Declarations::InterfaceDecl>(idecl) {
                continue
            }

            var subj = self._type(ie->args[at], &null)
            out.push_back(
                "static_assert(" + self.concept_name(idecl) + self.witness_args(
                    subj,
                    rhs,
                    ie,
                ) + ", \"Kairo checked this bound at the instance; C++ disagrees\");",
            )
        }

        return out
    }

    /// `static_assert(::ns::I_c<T>, "...");` for each interface bound of the
    /// generic record primary whose constructor \p f is, spelled over the
    /// record's own parameters: the record's C++ head carries none of them
    /// (defers_bounds: a head clause is checked where the template-id is
    /// named, over a CRTP base or a `*Holder<Node>` inside Node while the
    /// argument is still incomplete, and clang rejects those). A
    /// constructor's body is instantiated only when a value is made, when
    /// the argument is complete, so a C++ user making `Holder<Bad>` is told
    /// which bound failed instead of failing inside a witness call.
    /// Empty for anything else, and for a pack's bound (no one argument).
    fn ctor_bound_asserts(self, f: unsafe *Declarations::FunctionDecl) -> cxx::std::vector<string> {
        var out = cxx::std::vector<string>()
        if f == &null || f->semantic_dc == &null || !f->semantic_dc->is_type_scope() {
            return out
        }

        var unsafe *d = CXXSpell::rep(f->semantic_dc->dc_owner)
        if d == &null
            || !CXXSpell::defers_bounds(d)
            || DeclFacts::decl_generic_params(d).size() == 0 {
            return out
        }

        var cs = cxx::std::vector<unsafe *ConstraintExpr>()
        CXXSpell::impl_bounds(DeclFacts::decl_requires_clause(d), unsafe &cs)
        for var i: usize = 0; i < cs.size(); ++i {
            var unsafe *c = cs[i]
            if c->rhs == &null || c->rhs->canonical == &null {
                continue
            }

            var unsafe *gp = CXXSpell::_bound_param(c)
            if gp == &null || gp->is_pack || gp->owner == &null || CXXSpell::rep(gp->owner) != d {
                continue
            }

            var unsafe *rhs = canon_unqual(c->rhs->canonical)
            if !isa<RecordType>(rhs) {
                continue
            }

            var unsafe *idecl = CXXSpell::rep(
                DeclFacts::decl_pattern(
                    CXXSpell::rep(cast<RecordType>(rhs)->decl),
                ),
            )

            if !isa<Declarations::InterfaceDecl>(idecl) {
                continue
            }

            var tn = self.tparam_name(gp, d)
            var msg = "\x27" + self.leaf(
                d,
            ) + "\x27 requires \x27" + tn + "\x27 to implement \x27" + self.leaf(
                idecl,
            ) + "\x27"
            out.push_back(
                "static_assert(" + self.concept_name(idecl) + self.witness_args(
                    tn,
                    rhs,
                ) + ", \"" + msg + "\");",
            )
        }

        return out
    }

    /// Every VALUE predicate of requires clause \p e (conjuncts that are not
    /// `T impl I` / `T derives B`), in clause order.
    static fn value_predicates(e: unsafe *Expr, out: unsafe *cxx::std::vector<unsafe *Expr>) {
        if e == &null {
            return
        }

        var unsafe *b = dyn_cast<BinaryOperatorExpr>(e)
        if b != &null
            && (b->op_token.kind == TokenKind::OpAmpAmp || b->op_token.kind == TokenKind::KwAnd) {
            CXXSpell::value_predicates(b->lhs, out)
            CXXSpell::value_predicates(b->rhs, out)
            return
        }

        if isa<ConstraintExpr>(e) {
            return
        }

        out->push_back(e)
    }

    /// The value predicates of generic record \p d's `requires` that its
    /// template head cannot carry (_pred_text is "": one naming an eval
    /// constant or fn, which the head -- written in tier 0, before any of
    /// them is declared -- cannot name). They are static_asserts in the
    /// record's body instead (InterfaceEmitter::_record_def; an ADT enum's
    /// in its record, _adt_def), evaluated per
    /// instance once the items are defined (EmitPlan::_decl_type_items puts
    /// them ahead of the record). Not on a specialization: its clause
    /// selects, and an assert would turn a non-match into an error.
    fn body_predicates(self, d: unsafe *Decl) -> cxx::std::vector<unsafe *Expr> {
        var out = cxx::std::vector<unsafe *Expr>()
        if !(isa<Declarations::ClassDecl>(d)
            || isa<Declarations::StructDecl>(d)
            || isa<Declarations::UnionDecl>(d)
            || isa<Declarations::EnumDecl>(d)) {
            return out
        }

        if CXXSpell::template_params(d).size() == 0 || CXXSpell::is_record_spec(d) {
            return out
        }

        var vps = cxx::std::vector<unsafe *Expr>()
        CXXSpell::value_predicates(
            DeclFacts::decl_requires_clause(d),
            unsafe &vps,
        )

        for var i: usize = 0; i < vps.size(); ++i {
            if self._pred_text(vps[i]).size() == 0 {
                out.push_back(vps[i])
            }
        }

        return out
    }

    /// The value predicates of method \p m's `requires` as a C++20 trailing
    /// requires-clause (` requires (...)`), or "" when they stay its body's
    /// static_asserts (EmitIR::_body). Every home of a generic record writes
    /// its explicit instantiation (`template class B<X>;`), which
    /// instantiates every member body: an assert there failed each X the
    /// predicate rejects, whether or not anything called the member.
    /// As a clause, C++ leaves the member out for that X, and only a call is
    /// an error (ConformanceChecking reports it first, in Kairo's words).
    /// Only a non-template, non-virtual member of a generic record -- a
    /// member template is never instantiated by the record's, and a virtual
    /// function cannot be constrained -- and only when every predicate
    /// spells (_pred_text): the declaration and the out-of-line definition
    /// must carry the same clause, so it is all or none.
    fn member_requires(self, m: unsafe *Declarations::FunctionDecl, owner: unsafe *Decl) -> string {
        if m == &null || owner == &null || m->requires_clause == &null {
            return ""
        }

        if m->generic_params.size() > 0 {
            return ""
        }

        if m->abi == Declarations::AbiKind::Virtual
            || m->abi == Declarations::AbiKind::Override
            || m->body_kind == Declarations::FnBodyKind::Virtual {
            return ""
        }

        if DeclFacts::decl_generic_params(CXXSpell::rep(owner)).size() == 0 {
            return ""
        }

        var vps = cxx::std::vector<unsafe *Expr>()
        CXXSpell::value_predicates(m->requires_clause, unsafe &vps)
        if vps.size() == 0 {
            return ""
        }

        var s = ""
        for var i: usize = 0; i < vps.size(); ++i {
            var t = self._pred_text(vps[i])
            if t.size() == 0 {
                return ""
            }

            s += if (s.size() == 0) => (" requires (") else => " && "
            s += "(" + t + ")"
        }

        return s + ")"
    }

    /// A call of an `eval fn` whose whole body is `return f<P...>()` with f
    /// imported (`__builtin_is_trivially_copyable<T>()`, whose body is
    /// `return kairo_rt_is_trivially_copyable<T>()`): f at the call's
    /// written arguments, or "". The eval fn is declared after every record,
    /// so a clause inside one cannot name it; the runtime header declaring f
    /// comes before all of them.
    priv fn _pred_call(self, c: unsafe *CallExpr) -> string {
        if c == &null || c->args.size() != 0 || c->callee == &null {
            return ""
        }

        var unsafe *ce = c->callee
        while ce != &null && isa<ParenExpr>(ce) {
            ce = cast<ParenExpr>(ce)->inner
        }

        var unsafe *ni = dyn_cast<NamedIdentExpr>(ce)
        if ni == &null || ni->resolved_decl == &null {
            return ""
        }

        var unsafe *f = dyn_cast<Declarations::FunctionDecl>(
            CXXSpell::rep(ni->resolved_decl),
        )

        if f == &null || !f->is_eval() || f->generic_params.size() == 0 {
            return ""
        }

        if ni->generic_args.size() != f->generic_params.size() {
            return ""
        }

        var unsafe *b = f->body_block
        if b == &null || b->body.size() != 1 {
            return ""
        }

        var unsafe *rs = dyn_cast<ReturnStmt>(b->body[0])
        if rs == &null || rs->value == &null {
            return ""
        }

        var unsafe *ie = rs->value
        while ie != &null && isa<ParenExpr>(ie) {
            ie = cast<ParenExpr>(ie)->inner
        }

        var unsafe *ic = dyn_cast<CallExpr>(ie)
        if ic == &null || ic->args.size() != 0 || ic->callee == &null {
            return ""
        }

        var unsafe *ini = dyn_cast<NamedIdentExpr>(ic->callee)
        if ini == &null || ini->resolved_decl == &null {
            return ""
        }

        var unsafe *target = CXXSpell::rep(ini->resolved_decl)
        if !DeclFacts::decl_is_imported(target) {
            return ""
        }

        var s = ""
        for var i: usize = 0; i < ini->generic_args.size(); ++i {
            var unsafe *ga = ini->generic_args.get(i)
            if ga->ty == &null || ga->ty->canonical == &null {
                return ""
            }

            var unsafe *c0 = ga->ty->canonical
            while isa<QualifiedType>(c0) {
                c0 = cast<QualifiedType>(c0)->inner
            }

            var arg = ""
            if isa<GenericParamType>(c0) {
                // The eval fn's own parameter: the call's argument for it.
                var unsafe *g = cast<GenericParamType>(c0)
                if g->owner == &null || CXXSpell::rep(g->owner) != f {
                    return ""
                }

                var k = (g->param_index as usize)
                if k >= ni->generic_args.size() {
                    return ""
                }

                var unsafe *wa = ni->generic_args.get(k)
                if wa->ty == &null || wa->ty->canonical == &null {
                    return ""
                }

                arg = self._type(wa->ty)
            } else {
                if c0->is_dependent() {
                    return ""
                }

                arg = self._type(ga->ty)
            }

            if arg.size() == 0 {
                return ""
            }

            s += if (i == 0) => (arg) else => ", " + arg
        }

        return self.qual_name(target) + "<" + s + ">()"
    }

    /// C++ text of a self-contained predicate (requires_clause), or "".
    priv fn _pred_text(self, e0: unsafe *Expr) -> string {
        if e0 == &null {
            return ""
        }

        var unsafe *e = e0
        while e != &null && isa<ParenExpr>(e) {
            e = cast<ParenExpr>(e)->inner
        }

        if e == &null {
            return ""
        }

        if isa<IntegerLiteralExpr>(e) {
            var unsafe *lit = cast<IntegerLiteralExpr>(e)
            if lit->imm == &null || lit->get_value_hi() != (0 as u64) {
                return ""
            }

            return f"{lit->get_value_lo()}"
        }

        if isa<BooleanLiteralExpr>(e) {
            return (if (cast<BooleanLiteralExpr>(e)->value) => ("true") else => "false")
        }

        if isa<CallExpr>(e) {
            return self._pred_call(cast<CallExpr>(e))
        }

        if isa<TypeTraitExpr>(e) {
            var unsafe *tt = cast<TypeTraitExpr>(e)
            var        bi  = type_trait_cxx(tt->fact)
            if bi.size() == 0 || tt->type_arg == &null || tt->type_arg->canonical == &null {
                return ""
            }

            return bi + "(" + self._type(tt->type_arg) + ")"
        }

        if isa<SizeOfExpr>(e) {
            var unsafe *t = cast<SizeOfExpr>(e)->type_arg
            if t == &null || t->canonical == &null {
                return ""
            }

            return "sizeof(" + self._type(t) + ")"
        }

        if isa<AlignOfExpr>(e) {
            var unsafe *t = cast<AlignOfExpr>(e)->type_arg
            if t == &null || t->canonical == &null {
                return ""
            }

            return "alignof(" + self._type(t) + ")"
        }

        if isa<NamedIdentExpr>(e) {
            var unsafe *gp = dyn_cast<Declarations::GenericParamDecl>(
                cast<NamedIdentExpr>(e)->resolved_decl,
            )

            if gp == &null || !gp->is_const_param || gp->owner == &null {
                return ""
            }

            return self.tparam_name(gp, CXXSpell::rep(gp->owner))
        }

        if isa<UnaryOperatorExpr>(e) {
            var unsafe *u = cast<UnaryOperatorExpr>(e)
            if u->resolved_op != &null {
                return ""
            }

            var k = u->op_token.kind
            var o = ""
            if k == TokenKind::OpExclaim || k == TokenKind::KwNot {
                o = "!"
            } else if k == TokenKind::OpMinus {
                o = "-"
            } else if k == TokenKind::OpTilde {
                o = "~"
            } else {
                return ""
            }

            var x = self._pred_text(u->operand)
            if x.size() == 0 {
                return ""
            }

            return o + "(" + x + ")"
        }

        if isa<BinaryOperatorExpr>(e) {
            var unsafe *b = cast<BinaryOperatorExpr>(e)
            if b->resolved_op != &null {
                return ""
            }

            var o = CXXSpell::_pred_op(b->op_token.kind)
            if o.size() == 0 {
                return ""
            }

            var l = self._pred_text(b->lhs)
            var r = self._pred_text(b->rhs)
            if l.size() == 0 || r.size() == 0 {
                return ""
            }

            return "(" + l + ") " + o + " (" + r + ")"
        }

        return ""
    }

    static fn _pred_op(k: TokenKind) -> string {
        if k == TokenKind::OpPlus {
            return "+"
        }

        if k == TokenKind::OpMinus {
            return "-"
        }

        if k == TokenKind::OpStar {
            return "*"
        }

        if k == TokenKind::OpSlash {
            return "/"
        }

        if k == TokenKind::OpPercent {
            return "%"
        }

        if k == TokenKind::OpLess {
            return "<"
        }

        if k == TokenKind::OpLessEqual {
            return "<="
        }

        if k == TokenKind::OpGreater {
            return ">"
        }

        if k == TokenKind::OpGreaterEqual {
            return ">="
        }

        if k == TokenKind::OpEqualEqual {
            return "=="
        }

        if k == TokenKind::OpExclaimEqual {
            return "!="
        }

        if k == TokenKind::OpAmpAmp || k == TokenKind::KwAnd {
            return "&&"
        }

        if k == TokenKind::OpPipePipe || k == TokenKind::KwOr {
            return "||"
        }

        if k == TokenKind::OpAmp || k == TokenKind::KwBitand {
            return "&"
        }

        if k == TokenKind::OpPipe || k == TokenKind::KwBitor {
            return "|"
        }

        if k == TokenKind::OpCaret || k == TokenKind::KwXor {
            return "^"
        }

        if k == TokenKind::OpLessLess {
            return "<<"
        }

        if k == TokenKind::OpGreaterGreater {
            return ">>"
        }

        return ""
    }

    /// The generic parameter a conjunct constrains, or null.
    static fn _bound_param(c: unsafe *ConstraintExpr) -> unsafe *Declarations::GenericParamDecl {
        var unsafe *id = dyn_cast<NamedIdentExpr>(c->lhs)
        if id == &null {
            return &null
        }

        return dyn_cast<Declarations::GenericParamDecl>(id->resolved_decl)
    }

    /// Every `impl` conjunct of requires clause \p e, in clause order.
    static fn impl_bounds(e: unsafe *Expr, out: unsafe *cxx::std::vector<unsafe *ConstraintExpr>) {
        if e == &null {
            return
        }

        var unsafe *b = dyn_cast<BinaryOperatorExpr>(e)
        if b != &null
            && (b->op_token.kind == TokenKind::OpAmpAmp || b->op_token.kind == TokenKind::KwAnd) {
            CXXSpell::impl_bounds(b->lhs, out)
            CXXSpell::impl_bounds(b->rhs, out)
            return
        }

        var unsafe *c = dyn_cast<ConstraintExpr>(e)
        if c != &null && !c->is_derives() {
            out->push_back(c)
        }
    }

    /// Generic parameter \p gp of \p owner by name (rename_tparams).
    fn tparam_name(self,
                   gp:    unsafe *Declarations::GenericParamDecl,
                   owner: unsafe *Decl) -> string {
        if self.rename_tparams != &null {
            if self._renamed_for != self.rename_tparams {
                self._renamed_for = self.rename_tparams
                self._renamed = CXXSpell::template_params(self.rename_tparams)
            }

            for var i: usize = 0; i < self._renamed.size(); ++i {
                if self._renamed[i] == gp {
                    return LowerTargets::friend_tparam(i)
                }
            }
        }

        return self.tok_name(gp->name, CXXSpell::fid_of(owner))
    }

    /// `template <class T, class... Ts, int N>` for a generic decl; "" otherwise.
    fn template_head(self, d_in: unsafe *Decl) -> string {
        var unsafe *d = d_in
        // A generic function declared and then defined is one entity whose
        // links may name their parameters differently (`fn <U> m` in the
        // class, `fn <W> C::m` out of line). Every canonical `U` / `W` is
        // spelled through the representative (_gparam), so every link's head
        // is the representative's too: one set of names, one requires.
        if isa<Declarations::FunctionDecl>(d) {
            var unsafe *r = CXXSpell::rep(d)
            if r != &null
                && r != d
                && DeclFacts::decl_generic_params(r).size() == DeclFacts::decl_generic_params(
                    d,
                ).size() {
                d = r
            }
        }

        var gps = CXXSpell::template_params(d)
        if gps.size() == 0 {
            return ""
        }

        var s = "template <"
        for var i: usize = 0; i < gps.size(); ++i {
            var unsafe *gp = gps[i]
            if i > 0 {
                s += ", "
            }

            if gp->is_const_param {
                s += self._type(gp->value_type)
            } else {
                s += "class"
            }

            if gp->is_pack {
                s += "..."
            }

            s += " "
            s += self.tparam_name(gp, d)
        }

        s += ">"
        s += self.requires_clause(d)
        s += " "
        return s
    }

    /// # Specializations of a generic record

    /// \p d is a registered explicit or partial specialization of a record
    /// (TypeResolve sets `instantiated_from` to the primary). A function
    /// spec is OverloadResolution's and never a C++ specialization here.
    static fn is_record_spec(d: unsafe *Decl) -> bool {
        if d == &null
            || !(isa<Declarations::ClassDecl>(d)
                || isa<Declarations::StructDecl>(d)
                || isa<Declarations::UnionDecl>(d)) {
            return false
        }

        var k = DeclFacts::decl_spec_kind(d)
        if k != Declarations::SpecKind::Explicit && k != Declarations::SpecKind::Partial {
            return false
        }

        return DeclFacts::decl_instantiated_from(d) != &null
    }

    /// The head of a record's own declaration and definition: an explicit
    /// specialization's `template <>`, else template_head. Not for an
    /// out-of-line MEMBER of one: [temp.expl.spec]/5 writes those with no
    /// `template <>` at all, and _owner_template_head's template_head gives
    /// exactly that, since an explicit spec has no parameters.
    fn record_head(self, d: unsafe *Decl) -> string {
        if CXXSpell::is_record_spec(d)
            && DeclFacts::decl_spec_kind(d) == Declarations::SpecKind::Explicit {
            return "template <> " + self.requires_clause(d)
        }

        return self.template_head(d)
    }

    /// `<P*>` / `<bool>`: a specialization's pattern, the arguments it
    /// specializes the primary at, with a partial's own parameters by name.
    /// "" for anything that is not a record spec. Appended to the leaf
    /// wherever the spec itself is named -- its declarations and the
    /// qualifier of its out-of-line members -- because C++ has no other way
    /// to say which specialization of `Store` is meant.
    fn spec_suffix(self, d: unsafe *Decl) -> string {
        if !CXXSpell::is_record_spec(d) {
            return ""
        }

        var sargs = DeclFacts::decl_spec_args(d)
        var args  = cxx::std::vector<unsafe *Type>()
        for var i: usize = 0; i < sargs.size(); ++i {
            if sargs[i] == &null || sargs[i]->canonical == &null {
                kairo::std::ice_fail(
                    "CXXSpell: a specialization's pattern reached codegen unresolved",
                )
            }

            args.push_back(sargs[i]->canonical)
        }

        return self.args_str(args)
    }

    /// One segment of an out-of-line member's qualifier: the leaf, then a
    /// specialization's pattern or a generic owner's own parameters as its
    /// arguments (`Store<P*>`, `Store<bool>`, `Box<T>`).
    fn owner_segment(self, d: unsafe *Decl) -> string {
        var s = self.leaf(d)
        if CXXSpell::is_record_spec(d) {
            return s + self.spec_suffix(d)
        }

        var gps = DeclFacts::decl_generic_params(d)
        if gps.size() == 0 {
            return s
        }

        s += "<"
        for var j: usize = 0; j < gps.size(); ++j {
            if j > 0 {
                s += ", "
            }

            s += self.tok_name(gps[j]->name, CXXSpell::fid_of(d))
            if gps[j]->is_pack {
                s += "..."
            }
        }

        s += ">"
        return s
    }

    /// # internals

    priv fn _join(self, ty: string, const name: string) -> string {
        if name.size() == 0 {
            return ty
        }

        // A declarator that starts with `*`/`&`/`(` binds without a space.
        var c = name[0]
        if c == ('*' as u8) || c == ('&' as u8) || c == ('(' as u8) || c == ('[' as u8) {
            return ty + name
        }

        return ty + " " + name
    }

    /// \p r's arguments are exactly \p iface's own parameters, in order.
    priv fn _own_args(self, r: unsafe *RecordType, iface: unsafe *Decl) -> bool {
        var gps = DeclFacts::decl_generic_params(iface)
        if gps.size() != r->args.size() {
            return false
        }

        for var i: usize = 0; i < r->args.size(); ++i {
            var unsafe *g = dyn_cast<GenericParamType>(canon_unqual(r->args[i]))
            if g == &null || g->param_index != (i as u32) {
                return false
            }

            if CXXSpell::rep(g->owner) != iface {
                return false
            }
        }

        return true
    }

    priv fn _record(self,
                    r:     unsafe *RecordType,
                    subst: unsafe *InstanceEntry,
                    scope: unsafe *Decl) -> string {
        var unsafe *d = r->decl
        if d == &null {
            kairo::std::ice_fail("CXXSpell: RecordType with no decl")
        }

        if isa<Declarations::InterfaceDecl>(d) {
            var mine = self.self_iface != &null
                && CXXSpell::rep(DeclFacts::decl_pattern(CXXSpell::rep(d))) == self.self_iface
            // Self is `I` bare, or in a GENERIC interface `I<T...>` over its
            // own parameters (TypeResolve::_self_record) -- unsubstituted
            // here, the member's substitution applying only below it.
            if mine && (r->args.size() == 0 || self._own_args(r, self.self_iface)) {
                return self.self_spelling
            }

            self._ice(
                d->range,
                "CXXSpell: an interface has no C++ type; only its Self inside a witness is spelled",
            )
        }

        if DeclFacts::decl_is_imported(d) {
            // A tag hidden by an ordinary name (`struct timezone` beside
            // `extern long timezone`): bare `::timezone` is the variable in
            // C++, so the type is only reachable elaborated.
            var kw = DeclFacts::decl_ffi_tag_keyword(d)
            if kw.size() > 0 {
                return kw + " " + DeclFacts::decl_cxx_spelling(d)
            }

            // The PRIMARY over arguments -- `array<T, 4>` in a generic
            // signature, dependent so never filled -- is the template's name
            // and the arguments as Kairo spells them; the name alone was
            // `::std::array`, a template used without arguments. A filled
            // instance's spelling already carries its own.
            if r->args.size() > 0 && !DeclFacts::decl_is_instance(d) {
                // A defaulted parameter whose default names a param still
                // unplaced (`vector<T>`'s `allocator<T>` in a generic
                // body) is held by the primary's OWN param as a stand-in
                // (GenericArgs). That param is clang's and has no Kairo
                // name; every param after it is defaulted too, so stop
                // there and let C++ apply its defaults itself.
                var v = cxx::std::vector<unsafe *Type>()
                for var i: usize = 0; i < r->args.size(); ++i {
                    var unsafe *g = dyn_cast<GenericParamType>(
                        canon_unqual(r->args[i]),
                    )

                    if g != &null
                        && g->owner != &null
                        && CXXSpell::rep(g->owner) == CXXSpell::rep(d) {
                        break
                    }

                    // A parameter of a generic ALIAS (`BoxA(x)` over
                    // `template <class T> using BoxA = Box<T>`, no explicit
                    // arguments) is the alias's pattern, never in scope in
                    // an emitted body: spelling it gave `Box<T>` with an
                    // undeclared T (the self-host's `LockGuard(self._mu)`).
                    // The name alone leaves the arguments to clang's
                    // deduction, as for the template itself.
                    if g != &null
                        && g->owner != &null
                        && isa<Declarations::TypeAliasDecl>(
                            CXXSpell::rep(g->owner),
                        ) {
                        v.clear()
                        break
                    }

                    v.push_back(r->args[i])
                }

                if v.size() == 0 {
                    return DeclFacts::decl_cxx_spelling(d)
                }

                return DeclFacts::decl_cxx_spelling(d) + self.args_str(
                    v,
                    subst,
                    scope,
                )
            }

            return DeclFacts::decl_cxx_spelling(d)
        }

        // A panic result whose set names a type parameter (a generic body,
        // Compiler/Spec/Panic.md#generic-bodies): C++ orders the set at each instance through the
        // sorting alias, so the template's result and a concrete caller's
        // `Panic<T, A, B>` are one type however the parameters land.
        if self._dependent_panic_set(r) {
            var s = "::" + LowerTargets::panic_set_alias() + "<" + self.qual_name(
                CXXSpell::rep(d),
            )

            for var i: usize = 0; i < r->args.size(); ++i {
                s += ", " + self._type(r->args[i], subst, scope)
            }

            return s + ">"
        }

        // An instance shell names its PRIMARY plus the registry's args.
        if DeclFacts::decl_is_instance(d) {
            var unsafe *e = self._cg->instances->entry_of(d)
            if e == &null {
                self._ice(
                    d->range,
                    "CXXSpell: instance shell with no registry entry",
                )
            }

            return self._record_name(
                e->primary,
                self.args_str(e->args, subst, scope),
                scope,
            )
        }

        var targs = ""
        if r->args.size() > 0 {
            var v = cxx::std::vector<unsafe *Type>()
            for var i: usize = 0; i < r->args.size(); ++i {
                v.push_back(r->args[i])
            }

            targs = self.args_str(v, subst, scope)
        }

        // `L<i32>::P`: the member of the enclosing instance, spelled
        // through it -- `::ns::L<int>::P`, or `typename ::ns::L<T>::P` while
        // the instance is dependent.
        if r->outer != &null {
            var oq = self._type(r->outer, subst, scope)
            var dep = r->outer->is_dependent() || r->outer->is_instantiation_dependent()
            return CXXSpell::_member_type(oq, dep, self.leaf(d), targs)
        }

        return self._record_name(d, targs, scope)
    }

    /// \p r is the Panic lang item (a type-id-tagged ADT) with an element
    /// past its value type that names a type parameter.
    priv fn _dependent_panic_set(self, r: unsafe *RecordType) -> bool {
        if r->args.size() < 2 {
            return false
        }

        var unsafe *en = dyn_cast<Declarations::EnumDecl>(
            CXXSpell::rep(r->decl),
        )

        if en == &null || !en->adt_explicit_tags || DeclFacts::adt_pack_param(en) == usize::MAX {
            return false
        }

        for var i: usize = 1; i < r->args.size(); ++i {
            var unsafe *a = r->args[i]
            if a != &null && (a->is_dependent() || a->is_instantiation_dependent()) {
                return true
            }
        }

        return false
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
    priv fn _record_name(self,
                         d_in:        unsafe *Decl,
                         const targs: string,
                         scope:       unsafe *Decl) -> string {
        if CXXSpell::in_function_scope(d_in) {
            return self.leaf(d_in) + targs
        }

        var unsafe *d   = CXXSpell::rep(d_in)
        var unsafe *own = self._record_owner(d)
        if own == &null {
            return self.qual_name(d) + targs
        }

        if scope != &null {
            var unsafe *sc = CXXSpell::rep(scope)
            if sc == own || sc == d {
                return self.leaf(d) + targs
            }
        }

        var q = self._generic_owner_qual(d)
        if q.size() == 0 {
            return self.qual_name(d) + targs
        }

        return CXXSpell::_member_type(q, true, self.leaf(d), targs)
    }

    /// The record \p d is a member of, or null at namespace scope. An
    /// extension is not an owner here: it opens no C++ class scope a nested
    /// type could live in.
    priv fn _record_owner(self, d: unsafe *Decl) -> unsafe *Decl {
        var unsafe *dc = self._home_dc(d)
        if dc == &null || !dc->is_type_scope() || dc->dc_kind == DeclContextKind::Extension {
            return &null
        }

        return CXXSpell::rep(dc->dc_owner)
    }

    /// `::ns::L<K>::Q`: \p d's owners, each generic one spelled with its own
    /// parameters, i.e. the owner chain as its own template body sees it;
    /// "" when no owner is generic, because then qual_name is already a
    /// complete name. A generic owner past the first is a member template of
    /// a dependent type and takes `template`, as dependent_member_type
    /// spells it.
    priv fn _generic_owner_qual(self, d: unsafe *Decl) -> string {
        var        rev = cxx::std::vector<unsafe *Decl>()
        var unsafe *dc = self._home_dc(d)
        while dc != &null && dc->is_type_scope() {
            if dc->dc_kind != DeclContextKind::Extension {
                rev.push_back(CXXSpell::rep(dc->dc_owner))
            }

            dc = dc->dc_parent
        }

        var s  = ""
        var ns = self.ns_segments(d)
        for var i: usize = 0; i < ns.size(); ++i {
            s += "::"
            s += ns[i]
        }

        var dependent = false
        for var i: usize = 0; i < rev.size(); ++i {
            var unsafe *o  = rev[rev.size() - 1 - i]
            var        gps = DeclFacts::decl_generic_params(o)
            s += "::"
            if dependent && gps.size() > 0 {
                s += "template "
            }

            s += self.leaf(o)
            if gps.size() == 0 {
                continue
            }

            dependent = true
            var fid = CXXSpell::fid_of(o)
            s += "<"
            for var j: usize = 0; j < gps.size(); ++j {
                if j > 0 {
                    s += ", "
                }

                s += self.tok_name(gps[j]->name, fid)
                if gps[j]->is_pack {
                    s += "..."
                }
            }

            s += ">"
        }

        return if (dependent) => (s) else => ""
    }

    /// A Kairo type pack parameter that lowers to `T&&... xs` (param_type):
    /// by value or `@move`, not `const` (`const T&&` binds no lvalue, so a
    /// const pack stays `const T... xs`), not `@inout` (its elements are the
    /// pointers the call passes). An imported C++ pack is spelled by clang's
    /// own pattern, never here: its type is a reference to the pack.
    static fn forwarding_pack(p: unsafe *Declarations::ParamDecl) -> bool {
        if p == &null || p->is_const || p->mode == ParamMode::Inout {
            return false
        }

        if !DeclFacts::param_is_type_pack(p) || p->type_ == &null || p->type_->canonical == &null {
            return false
        }

        return isa<GenericParamType>(canon_unqual(p->type_->canonical))
    }

    /// The C++ name of type pack \p g's template parameter, without the
    /// `...` _gparam appends: `static_cast<T&&>(xs)...`.
    fn pack_param_name(self, g: unsafe *GenericParamType) -> string {
        var unsafe *owner = CXXSpell::rep(g->owner)
        var        gps    = DeclFacts::decl_generic_params(owner)
        if (g->param_index as usize) >= gps.size() {
            self._ice(
                owner->range,
                "CXXSpell: generic param index out of range",
            )
        }

        return self.tparam_name(gps[g->param_index as usize], owner)
    }

    /// \p sigil goes between an unsubstituted pack's name and its `...`
    /// (`T&&...`, param_type).
    priv fn _gparam(self,
                    g:           unsafe *GenericParamType,
                    subst:       unsafe *InstanceEntry,
                    const sigil: string = "") -> string {
        if g->owner == &null {
            kairo::std::ice_fail(
                "CXXSpell: canonical generic param with no owner",
            )
        }

        var unsafe *owner = CXXSpell::rep(g->owner)
        // A pack is only ever spelled expanded: a canonical pack parameter
        // stands for its expansion (`R<i32, E...>`'s argument, `...xs: T`'s
        // type), so it is `E...`, or under an instance its elements.
        if g->is_pack && self.pack_alias != &null {
            var ags = DeclFacts::decl_generic_params(owner)
            if (g->param_index as usize) < ags.size()
                && ags[g->param_index as usize] == self.pack_alias {
                return LowerTargets::adt_pack_elem()
            }
        }

        if g->is_pack {
            var els = cxx::std::vector<unsafe *Type>()
            if self.subst_pack(g, subst, &els) {
                var ps = ""
                for var i: usize = 0; i < els.size(); ++i {
                    if i > 0 {
                        ps += ", "
                    }

                    ps += self._type(els[i], &null)
                }

                return ps
            }
        } else {
            // An instance's array argument is followed by the parameter's
            // `const &` or `*` (`template int f<int[2]>(int[2] const &)` is an
            // array of references): one type-specifier.
            var unsafe *t = self.subst_for(g, subst)
            if t != &null {
                return self.type_specifier(t, &null)
            }
        }

        var gps = DeclFacts::decl_generic_params(owner)
        if (g->param_index as usize) >= gps.size() {
            self._ice(
                owner->range,
                "CXXSpell: generic param index out of range",
            )
        }

        var nm = self.tparam_name(gps[g->param_index as usize], owner)
        if !g->is_pack
            && self.void_unit_owner != &null
            && CXXSpell::rep(self.void_unit_owner) == owner {
            return "::" + LowerTargets::void_unit() + "<" + nm + ">"
        }

        return if (g->is_pack) => (nm + sigil + "...") else => nm
    }
}
