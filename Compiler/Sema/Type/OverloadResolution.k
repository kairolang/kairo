/// --- The Kairo Project --------------- Sema/Type/OverloadResolution.k --- ///
///
/// Pick one function from a candidate set for a call, given the
/// argument types. A component; ExprTyper calls it, nothing else.
///
///   \detail
///     Viability: arity after defaults and packs, every positional and named
///     argument lands on exactly one parameter, and every landed argument
///     reaches its parameter at rank Exact or Converted. A generic candidate
///     is viable when deduction succeeds and binds every non-pack parameter.
///     An imported C `...` function takes any number of trailing positional
///     arguments, each at rank Converted with no parameter to check against.
///
///     Ranking (lattice §7): a candidate's rank is the WORST of its argument
///     ranks. Two ranks, no ordering inside rank 2. Tiebreaks among the
///     best-ranked, in C++'s order; only `integer` orders conversions, and
///     only where Kairo's width mapping hid one:
///
///       reference kind  on an argument where both bound a C++ reference at
///                       Exact, an rvalue prefers `T&&` to `const T&` and a
///                       non-const lvalue prefers `T&` to `const T&`
///                       (_ref_better). Needs the argument's VALUE CATEGORY,
///                       which ExprTyper assigns and ArgInfo carries.
///       integer         on an argument where both bound a typed integer at
///                       Exact, the C type the target spells that width
///                       with beats a same-width alias: i32 prefers `int` to
///                       LLP64's `long` (_int_better). C maps by width, so
///                       both are Exact here; to C++ one is a conversion.
///       float literal   on an argument that is an untyped float literal
///                       bound at Exact to a non-dependent float, f64 beats
///                       every other float (_flit_better): the literal is
///                       C++'s double, identity to `double` and a floating
///                       conversion to `float`, so `std::sqrt(16.0)` is the
///                       double overload, as in C++. A lone f32
///                       parameter still takes the literal (§5).
///       generic         a non-generic candidate beats a generic one,
///                       otherwise `fn f(i32)` next to `fn <T> f(T)` is
///                       ambiguous on every call.
///       specialization  among generic ones still tied, the one more
///                       specialized than every other ([temp.func.order],
///                       _partial_order): libc++ declares `==` on its
///                       iterators as `(W<I>, W<I>)` beside `(W<I1>, W<I2>)`,
///                       and every call matches both exactly.
///
///     Everything else that ties is ambiguous and errors, even when one
///     conversion looks "narrower".
///
///     Before any of it, hiding (_hide): a base's method that a derived
///     class's method of the same parameters and `self` constness overrides
///     or hides is no candidate. Member lookup merges the two sets, which is
///     C++'s lookup under the `using Base::m;` the emitted class carries,
///     and that is C++'s rule there ([namespace.udecl]/14).
///
///     Untyped literals rank Exact against any parameter they fit (§5: the
///     literal TAKES the type, it is not converted). After selection the
///     typer types the literal with the parameter type, so the literal's own
///     fit diagnostic still fires at the literal.
///
///     Diagnostics owned here: no viable candidate, ambiguous call, a name
///     that is not callable. The candidate notes are capped so a 40-overload
///     set does not print 40 lines.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "Native/Types.hh" // kairo::std::ice_fail
ffi "c++" import "vector"

import AST::Context::DeclContext::DeclContextKind
import AST::Context::InstantiationRegistry::InstanceEntry
import AST::Context::SymbolTable::DeclName
import AST::DeclFacts::{
    decl_extension_of,
    decl_generic_params,
    decl_is_imported,
    decl_spec_kind,
    param_is_type_pack,
    param_type_pack_param,
}
import AST::LangItems::{
    LangAttrs,
    WellKnownType,
}
import AST::Node::Base::{
    Decl,
    Expr,
    Type,
}
import AST::Node::CanonicalNodes::{
    AssocType,
    BuiltinKind,
    QUAL_CONST,
    QUAL_VOLATILE,
    RecordType,
    builtin_info,
    canon_has_const,
    canon_quals,
    canon_unqual,
}
import AST::Node::Casting::{
    cast,
    dyn_cast,
    isa,
}
import AST::Node::Declarations::{
    ClassDecl,
    EnumDecl,
    FunctionDecl,
    ParamDecl,
    SpecKind,
    TransferKind,
    VariableDecl,
}
import AST::Node::Expressions::{
    AssignOperatorExpr,
    BinaryOperatorExpr,
    ClosureExpr,
    RangeExpr,
    SubscriptExpr,
    UnaryOperatorExpr,
}
import AST::Node::Types::{
    CXXLValueRefType,
    CXXRValueRefType,
    FixedArrayType,
    FunctionPointerType,
    GenericParamType,
    NullableType,
    OpaqueFFIType,
    PointerType,
    TypeExpr,
}
import AST::OperatorFacts::OperatorFacts
import AST::ParamMode::ParamMode
import Diagnostic::Code::DiagCode
import Diagnostic::NoteText::declared_here
import Diagnostic::Registry::DiagID
import Location::SourceLocation::SourceLocation
import Location::SourceRange::SourceRange
import Native::ClangEnableIf::EnableIfState
import Sema::Check::Conformance::{
    ClauseFalse,
    ConformanceChecking,
}
import Sema::Foreign::ForeignInstantiate::ForeignInstantiate
import Sema::Lower::LowerSynth::LowerSynth
import Sema::Resolve::NameLookup::NameLookup
import Sema::SemaContext::SemaContext
import Sema::Type::ArgumentDeduction::Deduction
import Sema::Type::BinderBorrow::{
    borrowed_binder_of,
    note_borrowed_binder,
}
import Sema::Type::Conversion::{
    Conversion,
    ImplicitRank,
    RefRel,
    literal_fits_int,
}
import Sema::Type::Substitution::Substitution
import Sema::Type::TypeUtil::TypeUtil
import Support::Tuning::DERIVES_WALK_DEPTH_MAX
import Token::TokenKind::TokenKind

/// An argument that is an untyped literal carries its shape so the
/// resolver can rank it without a type.
pub enum LitKind derives u8 {
    None = 0,
    Int,     ///< lo/hi/big/negative meaningful.
    Float,   ///< fits any float.
    Null,    ///< `null`: fits any nullable.
    NullPtr, ///< `&null`: fits any pointer or nullable pointer.
    List,    ///< `[...]`: ranked by shape through ArgInfo::elems.
    Variant, ///< `.V`: fits a parameter whose enum has a variant named lit_name.
    /// `a..b` over untyped integer literals: fits the range record of its
    /// form at any integer its bounds fit (LiteralTyping::range_literal_shape).
    Range,
}

/// LitKind::Range: the bounds a range literal writes, in ArgInfo::lit_bits.
pub const RANGE_HAS_BEGIN: u32 = 1
pub const RANGE_HAS_END:   u32 = 2

/// A C++ non-const `T&` parameter IS `@inout x: T` (c-cpp-calling.mdx,
/// functions-parameter-modes.mdx; decided 2026-11-08): the argument is marked
/// `&x`, binds by reference (an lvalue of T, or of a class derived from T),
/// is never moved, and a bare variable is SC097E as for a Kairo `@inout`.
/// Imported parameters keep the reference in their TYPE with mode Value
/// (DeclImport), so every reader of the mode asks this too. A bare template
/// `T&` is @inout only when the argument is marked: unmarked, C++'s own
/// deduction (T may become `const U`) still decides, as it did before.
pub fn cxx_lref_inout(f: unsafe *FunctionDecl, p: unsafe *ParamDecl, marked: bool) -> bool {
    if f == &null || p == &null || p->is_self || p->is_pack || p->mode != ParamMode::Value {
        return false
    }

    if !f->is_imported() || p->type_ == &null || p->type_->canonical == &null {
        return false
    }

    var unsafe *c = canon_unqual(p->type_->canonical)
    if c == &null || !isa<CXXLValueRefType>(c) {
        return false
    }

    var unsafe *r = cast<CXXLValueRefType>(c)->referee
    if r == &null || canon_has_const(r) {
        return false
    }

    if isa<GenericParamType>(canon_unqual(r)) {
        return marked
    }

    return true
}

/// `t` is an imported opaque type, or a C++ reference, pointer or
/// qualified type over one: `std::move`'s `remove_reference_t<T>&&` imports
/// as a reference to an opaque alias. Such a return type has no Kairo shape
/// even after Kairo's deduction (substitution leaves the opaque referee
/// alone), so clang's specialization supplies it (_clang_substitute).
pub fn has_opaque_ffi(t: unsafe *Type) -> bool {
    var unsafe *c = canon_unqual(t)
    if c == &null {
        return false
    }

    if isa<OpaqueFFIType>(c) {
        return true
    }

    if isa<CXXLValueRefType>(c) {
        return has_opaque_ffi(cast<CXXLValueRefType>(c)->referee)
    }

    if isa<CXXRValueRefType>(c) {
        return has_opaque_ffi(cast<CXXRValueRefType>(c)->referee)
    }

    if isa<PointerType>(c) {
        return has_opaque_ffi(cast<PointerType>(c)->pointee)
    }

    return false
}

/// One element of a list literal, ranked by SHAPE. Flat on purpose: ArgInfo
/// is a value passed and copied everywhere, and a container of ArgInfo inside
/// ArgInfo is a type that contains itself -- its copies do not survive, and
/// what breaks is every OTHER field, silently, on calls that have no list
/// literal in them at all. Children live in the same pool, named by index.
pub class ListShape {
    pub var lit:      LitKind      = LitKind::None
    pub var lit_lo:   u64          = 0
    pub var lit_hi:   u64          = 0
    pub var lit_big:  bool         = false
    pub var lit_bits: u32          = 0 ///< Big_bits of a literal wider than 128 bits.
    pub var lit_neg:  bool         = false
    pub var lit_name: string       = "" ///< LitKind::Variant: the name after the dot.
    pub var ty:       unsafe *Type = &null ///< set when the element is not an untyped literal.
    pub var kids_lo:  usize        = 0 ///< a nested list literal's own elements.
    pub var kids_n:   usize        = 0
    fn ListShape(self) { }

    fn copy(const self) -> ListShape {
        var r = ListShape()
        r.lit      = self.lit
        r.lit_lo   = self.lit_lo
        r.lit_hi   = self.lit_hi
        r.lit_big  = self.lit_big
        r.lit_bits = self.lit_bits
        r.lit_neg  = self.lit_neg
        r.lit_name = self.lit_name.copy()
        r.ty       = self.ty
        r.kids_lo  = self.kids_lo
        r.kids_n   = self.kids_n
        return r
    }
}

pub class ArgInfo {
    pub var expr: unsafe *Expr = &null
    /// The node as it sits in `CallExpr::args`. Differs from `expr` only for
    /// a named argument, where the parser wraps the value (see
    /// CallTyping::arg_info); everything but the dump wants `expr`.
    pub var carrier:    unsafe *Expr = &null
    pub var ty:         unsafe *Type = &null ///< canonical, null for an untyped literal / unknown.
    pub var range:      SourceRange
    pub var name:       string       = "" ///< named argument spelling; "" for positional.
    pub var name_range: SourceRange
    pub var lit:        LitKind      = LitKind::None
    pub var lit_lo:     u64          = 0
    pub var lit_hi:     u64          = 0
    pub var lit_big:    bool         = false
    pub var lit_bits:   u32          = 0 ///< Big_bits of a literal wider than 128 bits.
    pub var lit_neg:    bool         = false
    /// LitKind::Variant only: the name written after the dot. Written by
    /// ControlTyping::dotted_variant_shape.
    pub var lit_name: string = ""
    /// LitKind::List only: the element shapes, as a range in
    /// OverloadResolution::list_shapes. Written by
    /// LiteralTyping::list_literal_shape.
    pub var elems_lo:  usize = 0
    pub var elems_n:   usize = 0
    pub var dependent: bool  = false ///< type unknowable here; poisons nothing.
    /// The argument's value category (a literal is a prvalue), and for an
    /// lvalue whether it is const. Only reference parameters read them:
    /// they decide which of `T&` / `const T&` / `T&&` the argument binds.
    pub var cat:      Expr::ValueCategory = Expr::ValueCategory::RValue
    pub var is_const: bool                = false
    /// `cat` is XValue only because a MOVE-type lvalue moves when passed
    /// (CallTyping::arg_info): the expression itself is an lvalue, which is
    /// what an `@inout` parameter borrows -- an `@inout` argument is never
    /// moved from.
    pub var pass_moves: bool = false
    /// `cat` is LValue only because the argument is an `if` expression of
    /// lvalues, which C++ reads as one lvalue (CallTyping::if_of_lvalues).
    /// To Kairo it is a value: an `@inout` parameter does not borrow it.
    pub var if_lvalue: bool = false
    /// The `&` MARKER (AST/ParamMode.k). `marked` when the argument as
    /// written is `&e`. `expr` is the whole `&e`, typed as the address-of it
    /// may still turn out to be (against `x: *T` that is what it means);
    /// `inner_*` are the OPERAND's view, which is what an `@inout` parameter
    /// is judged against. Only the `@inout` path reads `inner_*`; every
    /// other parameter reads `ty` / `cat` / `is_const` and sees address-of.
    pub var marked:      bool                = false
    pub var inner_ty:    unsafe *Type        = &null
    pub var inner_cat:   Expr::ValueCategory = Expr::ValueCategory::RValue
    pub var inner_const: bool                = false
    fn ArgInfo(self) { }

    fn copy(const self) -> ArgInfo {
        var r = ArgInfo()
        r.expr        = self.expr
        r.carrier     = self.carrier
        r.ty          = self.ty
        r.range       = self.range
        r.name        = self.name.copy()
        r.name_range  = self.name_range
        r.lit         = self.lit
        r.lit_lo      = self.lit_lo
        r.lit_hi      = self.lit_hi
        r.lit_big     = self.lit_big
        r.lit_bits    = self.lit_bits
        r.lit_neg     = self.lit_neg
        r.lit_name    = self.lit_name.copy()
        r.elems_lo    = self.elems_lo
        r.elems_n     = self.elems_n
        r.dependent   = self.dependent
        r.cat         = self.cat
        r.is_const    = self.is_const
        r.pass_moves  = self.pass_moves
        r.if_lvalue   = self.if_lvalue
        r.marked      = self.marked
        r.inner_ty    = self.inner_ty
        r.inner_cat   = self.inner_cat
        r.inner_const = self.inner_const
        return r
    }
}

/// An independent copy of `v`.
pub fn copy_args(const v: [ArgInfo]) -> [ArgInfo] {
    var out: [ArgInfo]
    for var i: usize = 0; i < v.size(); ++i {
        out.push(v[i].copy())
    }

    return out
}

pub enum OvlOutcome derives u8 {
    Selected = 0,
    Ambiguous,
    NoViable,
    Dependent, ///< an argument is dependent: decide at M2, no diagnostic.
    /// defer mode only: the best candidates tie only because a dependent
    /// parameter or argument was assumed viable. Undecidable here, so no
    /// diagnostic and no decl; the instance's C++ picks.
    Deferred,
    Empty, ///< nothing callable under that name.
}

/// Candidate::arg_to_param (and OvlResult's copy): the two entries that are
/// no parameter index. Read past the end of the vector, an argument is the
/// pack tail, as every reader treats it.
pub const ARG_PACK_TAIL: usize = usize::MAX     ///< the Kairo pack parameter's tail.
pub const ARG_C_VARARG:  usize = usize::MAX - 1 ///< a C `...` tail: no parameter at all.

/// Candidate::rank: the candidate's worst argument binding, lower wins. Its
/// own scale, not ImplicitRank's: a user conversion ranks below Converted,
/// where ImplicitRank's third value means "no conversion".
pub const CAND_EXACT:     u8 = 0
pub const CAND_CONVERTED: u8 = 1
pub const CAND_USER_CONV: u8 = 2
/// Where the best-rank scan starts: above every rank, so a scan that ends
/// on it found nothing viable.
pub const CAND_NO_VIABLE: u8 = 255

/// How an argument, or the implicit object, bound a reference parameter,
/// for the reference tiebreak (_ref_prefers). The Temp kinds are the same
/// three bound to a converted TEMPORARY (`push_back(x)` with x: i32 into
/// `vector<i64>`): kept apart from the Exact ones, so only two of them are
/// ever compared with each other.
pub enum RefBind derives u8 {
    None = 0,      ///< a value parameter, or not ranked Exact.
    ConstLRef,     ///< `const T&`.
    RRef,          ///< `T&&`.
    LRef,          ///< `T&` (an `@inout` binding is one).
    TempConstLRef, ///< `const T&`, to a converted temporary.
    TempRRef,      ///< `T&&`, to a converted temporary.
    TempLRef,      ///< `T&`, to a converted temporary.
}

/// How an argument ranked Exact looks to C++, where Kairo's rank does not
/// tell two parameters apart (ArgJudgment::int_kind, flit_kind). Natural
/// beats Alias in the tiebreak that reads it; Unjudged takes no part.
pub enum ExactFit derives u8 {
    Unjudged = 0,
    Natural, ///< the identity to C++: the natural C type, the literal's own type.
    Alias,   ///< a same-width alias of it, or a conversion to C++.
}

/// `k` bound to a converted temporary instead (None stays None).
fn ref_bind_on_temp(k: RefBind) -> RefBind {
    if k == RefBind::ConstLRef {
        return RefBind::TempConstLRef
    }

    if k == RefBind::RRef {
        return RefBind::TempRRef
    }

    if k == RefBind::LRef {
        return RefBind::TempLRef
    }

    return k
}

/// How one argument of a candidate was judged, for the tiebreaks and the
/// ambiguity diagnostic (Candidate::judged). All four are written while the
/// argument is ranked (_judge) and read only after every candidate is.
pub struct ArgJudgment {
    /// The reference kind it bound AT EXACT, or (a Temp kind) to a
    /// converted temporary. Read only by the reference tiebreak.
    pub var bind: RefBind = RefBind::None
    /// How a TYPED integer argument bound AT EXACT -- Unjudged (not an
    /// integer, not Exact, an untyped literal), Natural its natural C type,
    /// Alias a same-width C alias (ParamDecl::cxx_int_alias) -- and how a
    /// string literal bound a C string parameter: Natural `const char *`,
    /// Alias a byte pointer. Read only by the integer tiebreak.
    pub var int_kind: ExactFit = ExactFit::Unjudged
    /// How an untyped FLOAT LITERAL bound at Exact to a non-dependent float
    /// parameter -- Natural f64 (C++'s double, the literal's own type),
    /// Alias any other float (a floating conversion to C++) -- and an
    /// untyped int literal to an imported parameter (_ilit_code). Read only
    /// by the float-literal tiebreak.
    pub var flit_kind: ExactFit = ExactFit::Unjudged
    /// The parameter type it was ranked against, null where nothing was
    /// ranked (a C `...` tail, an assumed argument). Read only by the
    /// ambiguity diagnostic: which enum a `.V` argument took is known only
    /// here, after `self` is skipped and `Self` is read through the receiver.
    pub var target: unsafe *Type = &null
}

/// What a candidate's judgment concluded. A rejected candidate keeps no
/// other verdict: every reader of the three viable-but kinds asks a winner,
/// which is viable. The three are exclusive by construction (an assumed
/// candidate is not shown to clang, and clang's dependent-argument answer
/// returns before the soft rejection is decided), which `note` checks.
pub enum Verdict derives u8 {
    Viable = 0,
    /// defer mode: some argument was ASSUMED viable, not ranked. `rank` is
    /// then a lower bound -- the instance can only make it worse.
    Assumed,
    /// An imported template clang could not judge because an argument is a
    /// generic body's dependent type: its SFINAE verdict is the instance's.
    SfinaeDeferred,
    /// Clang removed this imported template, but over a Kairo record's
    /// stand-in, which has the record's fields and none of its methods: the
    /// removal may be the stand-in's. Viable, and loses any tie to a
    /// candidate clang kept (resolve_mixed).
    SoftRejected,
    /// Not viable; `reason` / `reason_code` say why.
    Rejected,
}

pub class Candidate {
    pub var  f:        unsafe *FunctionDecl = &null
    priv var _verdict: Verdict              = Verdict::Viable
    pub var  rank:     u8                   = CAND_EXACT ///< CAND_EXACT / CAND_CONVERTED / CAND_USER_CONV.
    pub var  generic:  bool                 = false
    pub var  free:     bool                 = false ///< from resolve_mixed's free list: judged with no receiver.
    /// Rejected because the object or an `@inout` argument is const.
    pub var const_reject: bool = false
    /// Judged in defer mode: a dependent parameter or argument is viable and
    /// unranked instead of unified. Set before _judge, read by it.
    pub var defer:  bool   = false
    pub var reason: string = ""
    /// An edit that would make this candidate viable, inserted at `fix_at`;
    /// "" for none. Set for a C string parameter: the reinterpretation of
    /// a byte pointer, or `.c_str()` on a string that is no literal.
    pub var fix_text: string         = ""
    pub var fix_at:   SourceLocation
    /// fix_text closes a parenthesis opened at `fix_open` (an argument
    /// that binds looser than the `as` appended to it).
    pub var fix_paren: bool           = false
    pub var fix_open:  SourceLocation
    /// Which placement rule rejected this candidate, or SC001E (never emitted from here; a pure "no specific rule" sentinel) for anything
    /// else. `_report_no_viable` promotes it to the real diagnostic when there
    /// is exactly ONE candidate; with an overload set the specific rule is a
    /// property of one candidate, not of the call, so it stays a note.
    pub var reason_code: DiagID = DiagID::SC001E
    /// per arg: param index, ARG_PACK_TAIL for the Kairo pack tail,
    /// ARG_C_VARARG for a C `...` tail (no parameter at all;
    /// finish_call_args finds none and types a literal there with its
    /// default, which is C's promotion).
    pub var arg_to_param: [usize]
    /// per arg: how it was judged (ArgJudgment), one entry per argument.
    pub var judged: [ArgJudgment]
    /// The implicit object parameter, judged like one more reference
    /// argument: ConstLRef `const self`, LRef plain `self`, RRef a `q() &&`,
    /// None not judged (no receiver object known). recv_const is the
    /// OBJECT's constness.
    pub var recv_bind:  RefBind = RefBind::None
    pub var recv_const: bool    = false
    /// The implicit object parameter's own cv (QUAL_CONST / QUAL_VOLATILE),
    /// for the [over.ics.rank]/3.2.6 tie-break; set with recv_bind.
    pub var recv_quals: u8 = 0
    /// Arguments that reached an `@inout` parameter WITHOUT the marker.
    /// Viable (migration tolerance); CallTyping warns after selection. The
    /// two are parallel: arg index, the parameter it landed on.
    pub var inout_unmarked: [usize]
    pub var inout_params:   [unsafe *ParamDecl]
    /// Arguments a C++ callee takes through ONE implicit user-defined
    /// conversion (-fcxx-implicit-conv): ranked below every standard
    /// conversion (rank 2), emitted as written for C++ to convert.
    pub var user_convs: [usize]
    /// The subset of user_convs whose parameter Kairo cannot read before
    /// clang substitutes it (`fmt::format_string<T...>`: an alias over the
    /// pack, a non-deduced context): clang checks the conversion against
    /// the specialization's own parameter (_clang_substitute).
    pub var clang_convs: [usize]
    /// Without the flag: the record a C++ user-defined conversion would
    /// have reached ("" none), and how, for the note on the argument.
    pub var uconv_to:  string    = ""
    pub var uconv_via: string    = ""
    pub var ded:       Deduction
    /// An imported template's return type as clang's specialization has it,
    /// when Kairo's import of the declared one is opaque; else null.
    /// Written by _clang_substitute.
    pub var cxx_ret: unsafe *Type = &null
    /// An imported template's clang specialization and its HeaderSet, as
    /// _clang_substitute's deduction found them; null when it was not asked.
    pub var cxx_spec:     unsafe *void = &null
    pub var cxx_spec_set: unsafe *void = &null
    /// SfinaeDeferred, and the dependent argument is a dereference (`*slot`
    /// on `slot: *T`): see OvlResult::deref_dep.
    pub var deref_dep: bool = false
    /// An imported function's enable_if state (EnableIfState): Failed is
    /// rejected in _collect, Satisfied beats None in _enable_if_tiebreak.
    pub var enable_if: u8 = 0
    fn Candidate(self) { }

    pub fn verdict(const self) -> Verdict {
        return self._verdict
    }

    pub fn viable(const self) -> bool {
        return self._verdict != Verdict::Rejected
    }

    /// Out, whatever it was: the one transition from every verdict.
    pub fn reject(self) {
        self._verdict = Verdict::Rejected
    }

    /// One of the viable-but kinds. A rejected candidate stays rejected
    /// (what it would have noted is read only on a viable one); repeating
    /// the same kind is fine (several assumed arguments).
    pub fn note(self, v: Verdict) {
        if self._verdict == Verdict::Rejected {
            return
        }

        eval if defined!(DEBUG) {
            if self._verdict != Verdict::Viable && self._verdict != v {
                kairo::std::ice_fail(
                    r"OverloadResolution: a candidate given two viable-but verdicts",
                )
            }
        }

        self._verdict = v
    }
}

pub class OvlResult {
    pub var outcome:      OvlOutcome           = OvlOutcome::Empty
    pub var decl:         unsafe *FunctionDecl = &null
    pub var arg_to_param: [usize]
    pub var via_free:     bool                 = false ///< winner came from the free list: arg_to_param indexes fargs.
    /// The receiver was bound to the winner's `self`, which then matched no
    /// argument: arg_to_param indexes the params AFTER `self`.
    /// finish_call_args reads this rather than guessing.
    pub var receiver_bound: bool = false
    /// The call had more than one candidate. A cast on an argument may be what
    /// picked the winner, so the redundant-cast lint (SC031W) stays quiet.
    pub var overloaded: bool      = false
    pub var ded:        Deduction
    /// The type the call was made THROUGH, stripped of nullable and pointer:
    /// `obj.m(x)`'s `obj`. Filled by the caller after resolution, alongside
    /// `ded.bind_from_record`, because it answers a question deduction cannot:
    /// an interface member's `Self` is the receiver, and through a bound
    /// `T impl I` the receiver is `T` rather than any record. Null when the
    /// call had no receiver.
    pub var receiver: unsafe *Type = &null
    /// Copied off the winner; see Candidate.
    pub var inout_unmarked: [usize]
    pub var inout_params:   [unsafe *ParamDecl]
    pub var user_convs:     [usize]
    /// The instance a GENERIC winner was registered as (call_result_type),
    /// null for a non-generic one or a dependent call.
    pub var instance: unsafe *InstanceEntry = &null
    /// A generic winner's arguments when some are still DEPENDENT (a call
    /// from inside a generic body: `inner(Wrap<T>{...})` deduces
    /// [Wrap<T>]), in instance order; empty when `instance` is set.
    pub var dep_args: cxx::std::vector<unsafe *Type>
    /// Copied off the winner (Candidate::cxx_ret): call_result_type's answer
    /// where the declared return type has no Kairo shape.
    pub var cxx_ret: unsafe *Type = &null
    /// Copied off the winner (Candidate::cxx_spec / cxx_spec_set).
    pub var cxx_spec:     unsafe *void = &null
    pub var cxx_spec_set: unsafe *void = &null
    /// Copied off the winner (Candidate::deref_dep): clang was not asked,
    /// because an argument is a dereference of a pointer to the enclosing
    /// generic's parameter, so an opaque declared return type is the
    /// instance's to learn (call_result_type).
    pub var deref_dep: bool = false
    fn OvlResult(self) { }
}

/// The ambient context one resolution reads -- call_syntax,
/// explicit_args, recv_cat, which CallTyping sets for one call --
/// put back as it was when the scope ends, however it ends. Every
/// field, not the ones a site remembered to save: typing an argument
/// is a call of its own, and one that read the outer call's explicit
/// arguments said "it takes 0 generic argument(s), and 1 were
/// written" (CallTyping::_call_candidates).
pub class OvlCallScope {
    priv var _ovl:         unsafe *OverloadResolution
    priv var _call_syntax: bool
    priv var _explicit:    cxx::std::vector<unsafe *Type>
    priv var _recv_cat:    Expr::ValueCategory

    fn OvlCallScope(self, ovl: unsafe *OverloadResolution) {
        self._ovl         = ovl
        self._call_syntax = ovl->call_syntax
        self._explicit    = ovl->explicit_args
        self._recv_cat    = ovl->recv_cat
    }

    @copy fn OvlCallScope(self, const other: Self) = delete

    fn op finally (self) {
        self._ovl->call_syntax   = self._call_syntax
        self._ovl->explicit_args = self._explicit
        self._ovl->recv_cat      = self._recv_cat
    }
}

pub class OverloadResolution {
    /// The arguments are a call's, written `f(...)`, where a `&x` marker can
    /// be written: only then is a C++ `T&` parameter `@inout`
    /// (cxx_lref_inout). An operator's operands (`os << x`, whose
    /// `operator<<` takes `raw_ostream&`) and a receiver have no marker to
    /// write and bind a `T&` as C++ does. Set by CallTyping around its
    /// resolution only.
    pub var call_syntax: bool = false
    /// The callee of the call being resolved (`x.bump` of `x.bump()`), so a
    /// failure on a borrowing binder's constness can say why it is const
    /// (BinderBorrow). Set by CallTyping around its resolution only.
    pub var call_callee: unsafe *Expr        = &null
    pub var sc:          unsafe *SemaContext
    pub var conv:        unsafe *Conversion
    pub var tu:          TypeUtil

    /// Every list literal's element shapes, for this TU. Append-only, and
    /// indices into it are stable for exactly that reason: an ArgInfo names
    /// its elements by range, so nothing has to hold a container of itself.
    pub var list_shapes: cxx::std::vector<ListShape>
    /// The call's explicit generic arguments (`f<3>()`, `f<i32>(x)`), as
    /// canonicals, in order; empty when none were written. Bound into each
    /// generic candidate's deduction before its arguments are judged, so a
    /// parameter no argument mentions (`fn <eval N: usize> width()`) has a
    /// value. CallTyping sets and clears it around one resolve.
    pub var explicit_args: cxx::std::vector<unsafe *Type>
    /// The receiver OBJECT's value category on a method call (ChainInfo::
    /// receiver_cat), which only an imported method with a ref-qualifier
    /// reads (_judge_receiver). LValue -- what every other caller means --
    /// unless CallTyping sets it around one resolve.
    pub var recv_cat: Expr::ValueCategory = Expr::ValueCategory::LValue

    fn OverloadResolution(self) {
        self.sc   = &null
        self.conv = &null
    }

    fn OverloadResolution(self, sc: unsafe *SemaContext, conv: unsafe *Conversion) {
        self.sc   = sc
        self.conv = conv
        self.tu   = TypeUtil(sc)
    }

    /// ### Parameters
    /// - `cands`: the decls under the name; non-functions are skipped
    ///   (a mixed cell was N(a)'s error already).
    /// - `has_receiver`: `obj.m(...)`: the `self` param is bound to the
    ///   receiver and not matched against args. `Type::m(obj)`
    ///   passes false and `self` is an ordinary first param.
    /// - `receiver`: the type `obj` has, already stripped of nullable and
    ///   pointer. Not a duplicate of has_receiver: an interface
    ///   member's `Self` IS this type, and viability has to see
    ///   that -- `fn merge(self, other: Self)` reached through a
    ///   `T impl Drawable` takes a T, so ranking the argument
    ///   against `Drawable` would reject a correct call. Null
    ///   when there is no receiver, or when the caller has none
    ///   to offer.
    /// - `qualifier`: the interface instance a qualified requirement call
    ///   names (`Container<i32>::get(b, 0)`): its arguments
    ///   are the requirement's interface parameters, decided
    ///   before any argument is ranked, as an extension's are
    ///   by the receiver. Null on every other call.
    fn resolve(self,
               cands:        unsafe *cxx::std::vector<unsafe *Decl>,
               args:         unsafe *[ArgInfo],
               has_receiver: bool,
               at:           SourceRange,
               const name:   string,
               receiver:     unsafe *Type = &null,
               qualifier:    unsafe *Type = &null) -> OvlResult {
        return self.resolve_mixed(
            cands,
            args,
            has_receiver,
            &null,
            &null,
            at,
            name,
            receiver,
            false,
            qualifier,
        )
    }

    /// resolve() for a call whose callee is DEPENDENT but nameable -- a
    /// constructor of `Rec<T>` inside a generic body. A parameter still
    /// dependent after reading it through `receiver`, or a dependent
    /// argument, is viable for anything and unranked: convertibility is the
    /// instance's question, as it is for initializer fields. Concrete pairs
    /// rank normally, so a concrete mismatch is still an error here.
    ///
    /// Selection is resolve()'s plus one rule: an Exact candidate that
    /// assumed nothing beats one that did. Without it every generic record
    /// is ambiguous at the definition, because they all have a transfer
    /// constructor taking `Self`. A tie that exists only through an assumed
    /// candidate is OvlOutcome::Deferred, silently.
    fn resolve_deferred(self,
                        cands:        unsafe *cxx::std::vector<unsafe *Decl>,
                        args:         unsafe *[ArgInfo],
                        has_receiver: bool,
                        at:           SourceRange,
                        const name:   string,
                        receiver:     unsafe *Type) -> OvlResult {
        return self.resolve_mixed(
            cands,
            args,
            has_receiver,
            &null,
            &null,
            at,
            name,
            receiver,
            true,
        )
    }

    /// One overload set drawn from two argument shapes. `members` are judged
    /// against `margs` exactly as resolve() judges them; `frees` (free
    /// functions -- an ADL-found `fn op +(a: A, b: B)`) against `fargs`,
    /// where the receiver operand is an ordinary first argument. Everything
    /// ranks in ONE candidate list: which list a candidate came from is not a
    /// tiebreak, so a member and a free function at the same rank are an
    /// ordinary ambiguity (the C++ rule for operators). The winner's
    /// arg_to_param indexes `fargs` iff OvlResult::via_free. `frees` and
    /// `fargs` may be null.
    /// Whether any candidate is viable for these arguments, reporting
    /// nothing. For a caller that has a fallback when none is: C++20's
    /// `a != b` is `!(a == b)` whenever no `operator!=` takes the operands,
    /// even with `!=` overloads in scope -- libc++ declares only `==` on its
    /// iterators, beside a std full of `!=` for optional, variant, pair.
    fn any_viable(self,
                  members:      unsafe *cxx::std::vector<unsafe *Decl>,
                  margs:        unsafe *[ArgInfo],
                  has_receiver: bool,
                  frees:        unsafe *cxx::std::vector<unsafe *Decl>,
                  fargs:        unsafe *[ArgInfo],
                  receiver:     unsafe *Type = &null) -> bool {
        if self._any_dependent(margs) || self._any_dependent(fargs) {
            return true
        }

        var cs: [Candidate]
        self._collect(
            unsafe &cs,
            members,
            margs,
            has_receiver,
            receiver,
            false,
            false,
        )

        if fargs != &null {
            self._collect(unsafe &cs, frees, fargs, false, &null, true, false)
        }

        for var i: usize = 0; i < cs.size(); ++i {
            if cs[i].viable() {
                return true
            }
        }

        return false
    }

    /// `receiver` is a dependent instance of an imported class template
    /// and `members` are its (imported) members.
    priv fn _dependent_foreign_receiver(self,
                                        receiver: unsafe *Type,
                                        members:  unsafe *cxx::std::vector<unsafe *Decl>) -> bool {
        if receiver == &null || members == &null || members->size() == 0 {
            return false
        }

        var unsafe *r = canon_unqual(self.tu.as_value(receiver))
        if r == &null || !isa<RecordType>(r) || !r->is_dependent() {
            return false
        }

        if !decl_is_imported(cast<RecordType>(r)->decl) {
            return false
        }

        for var i: usize = 0; i < members->size(); ++i {
            var unsafe *f = dyn_cast<FunctionDecl>((*members)[i])
            if f != &null && f->is_imported() {
                return true
            }
        }

        return false
    }

    fn resolve_mixed(self,
                     members:      unsafe *cxx::std::vector<unsafe *Decl>,
                     margs:        unsafe *[ArgInfo],
                     has_receiver: bool,
                     frees:        unsafe *cxx::std::vector<unsafe *Decl>,
                     fargs:        unsafe *[ArgInfo],
                     at:           SourceRange,
                     const name:   string,
                     receiver:     unsafe *Type = &null,
                     defer:        bool = false,
                     qualifier:    unsafe *Type = &null) -> OvlResult {
        var out = OvlResult()
        // `receiver` carries the OBJECT's cv (a const object's method call
        // ranks on it, _judge_receiver); everything downstream of the
        // result wants the type the call was made through, unqualified.
        out.receiver = canon_unqual(receiver)

        if !defer && (self._any_dependent(margs) || self._any_dependent(fargs)) {
            out.outcome = OvlOutcome::Dependent
            return out
        }

        // A member of a C++ class template instance over a Kairo parameter
        // (`self.v[i]`, `self.v.size()` on a `vector<T>`): the pattern's
        // signatures are dependent (`operator[](size_type)` with size_type
        // `allocator_traits<A>::size_type`) and import as opaque types no
        // argument converts to. C++ resolves a call on a dependent object
        // per instantiation, and so does Kairo: Dependent, as for a
        // dependent argument. The concrete instance resolves as before.
        if !defer && self._dependent_foreign_receiver(receiver, members) {
            out.outcome = OvlOutcome::Dependent
            return out
        }

        var cs: [Candidate]
        self._collect(
            unsafe &cs,
            members,
            margs,
            has_receiver,
            receiver,
            false,
            defer,
            qualifier,
        )

        if fargs != &null {
            self._collect(unsafe &cs, frees, fargs, false, &null, true, defer)
        }

        self._hide(unsafe &cs)

        if cs.size() == 0 {
            self.sc->diag->report(
                DiagID::SC062E,
                at.start,
                f"'{name}' is not callable",
            ).first(at)->emit()
            out.outcome = OvlOutcome::Empty
            return out
        }

        self._requires_filter(unsafe &cs)

        // best rank among viable
        var best: u8 = CAND_NO_VIABLE
        for var i: usize = 0; i < cs.size(); ++i {
            if cs[i].viable() && cs[i].rank < best {
                best = cs[i].rank
            }
        }

        if best == CAND_NO_VIABLE {
            // An argument already diagnosed (poisoned) is no candidate's
            // fault: "no matching overload" for it only repeats that error.
            var any_poisoned = false
            if margs != &null {
                for var i: usize = 0; i < margs->size(); ++i {
                    if (*margs)[i].expr != &null && (*margs)[i].expr->is_poisoned() {
                        any_poisoned = true
                    }
                }
            }

            if fargs != &null {
                for var i: usize = 0; i < fargs->size(); ++i {
                    if (*fargs)[i].expr != &null && (*fargs)[i].expr->is_poisoned() {
                        any_poisoned = true
                    }
                }
            }

            if !any_poisoned {
                self._report_no_viable(unsafe &cs, at, name, margs, fargs)
            }

            out.outcome = OvlOutcome::NoViable
            return out
        }

        var winners: [usize]
        for var i: usize = 0; i < cs.size(); ++i {
            if cs[i].viable() && cs[i].rank == best {
                winners.push(i)
            }
        }

        // An assumed candidate's rank is a lower bound, so it can tie an
        // Exact winner at best -- never beat one. Only at Exact: a firm
        // Converted winner could still tie an assumed one at the instance.
        if defer && winners.size() > 1 && best == 0 {
            var firm: [usize]
            for var i: usize = 0; i < winners.size(); ++i {
                if cs[winners[i]].verdict() != Verdict::Assumed {
                    firm.push(winners[i])
                }
            }

            if firm.size() > 0 {
                winners = firm
            }
        }

        // A soft-rejected template (Verdict::SoftRejected) yields to any
        // winner clang did not reject: `make_unique<Cp>(4)` keeps the
        // single-object overload over the array ones, whose conditions the
        // stand-in for `Cp` answers truly. Alone, it stands: the concept a
        // Kairo record meets through its methods is not one a stand-in can.
        if winners.size() > 1 {
            var firm: [usize]
            for var i: usize = 0; i < winners.size(); ++i {
                if cs[winners[i]].verdict() != Verdict::SoftRejected {
                    firm.push(winners[i])
                }
            }

            if firm.size() > 0 {
                winners = firm
            }
        }

        // Reference kind, BEFORE the generic tiebreak for the reason C++
        // orders them so ([over.match.best]: better conversion sequences
        // first, templates after): see _ref_better.
        if winners.size() > 1 {
            winners = self._ref_tiebreak(unsafe &cs, winners, margs, fargs)
        }

        // Integer spelling, also a conversion-sequence ordering: see _int_better.
        if winners.size() > 1 {
            winners = self._int_tiebreak(unsafe &cs, winners)
        }

        // Pointee cv, the same ordering for a pointer parameter: see _cv_better.
        if winners.size() > 1 {
            winners = self._cv_tiebreak(unsafe &cs, winners)
        }

        // A float literal is C++'s double: see _flit_better.
        if winners.size() > 1 {
            winners = self._flit_tiebreak(unsafe &cs, winners)
        }

        // non-generic beats generic.
        if winners.size() > 1 {
            var nongen: [usize]
            for var i: usize = 0; i < winners.size(); ++i {
                if !cs[winners[i]].generic {
                    nongen.push(winners[i])
                }
            }

            if nongen.size() > 0 {
                winners = nongen
            }
        }

        if winners.size() > 1 {
            winners = self._partial_order(unsafe &cs, winners)
        }

        // enable_if, clang's last tiebreak before the ambiguity: see
        // _enable_if_tiebreak.
        if winners.size() > 1 {
            winners = self._enable_if_tiebreak(unsafe &cs, winners)
        }

        if defer && self._undecided(cs, winners) {
            out.outcome = OvlOutcome::Deferred
            return out
        }

        // A tie only among imported templates whose substitution waits on a
        // generic body's parameter: SFINAE may well split it at every
        // instance (`on_default(x)` with `x: T`), so it is no ambiguity yet.
        // Dependent, as a dependent argument is: decided per instance.
        if winners.size() > 1 && self._sfinae_pending(cs, winners) {
            out.outcome = OvlOutcome::Dependent
            return out
        }

        // A tie in a generic body among candidates whose clauses test an
        // open parameter: the bounds decide nothing between them, and the
        // body is checked against its bounds, not per instance.
        if winners.size() > 1 && self._report_open_tie(unsafe &cs, &winners, at, name) {
            out.outcome = OvlOutcome::Ambiguous
            return out
        }

        // A tie kept by a conformance whose witness this file cannot use,
        // where the emitted C++ would still see it: the error is the
        // member's visibility or the missing import, named as such.
        if winners.size() > 1 {
            for var i: usize = 0; i < winners.size(); ++i {
                var *c = &cs[winners[i]]
                if c->generic
                    && c->f != &null
                    && !c->f->is_imported()
                    && ConformanceChecking(self.sc).report_hidden_tie(
                        c->f,
                        unsafe &c->ded,
                        at,
                    ) {
                    out.outcome = OvlOutcome::Ambiguous
                    return out
                }
            }
        }

        if winners.size() > 1 {
            self._report_ambiguous(
                unsafe &cs,
                unsafe &winners,
                margs,
                fargs,
                at,
                name,
            )

            out.outcome = OvlOutcome::Ambiguous
            return out
        }

        var *w = &cs[winners[0]]
        out.outcome        = OvlOutcome::Selected
        out.decl           = w->f
        out.overloaded     = cs.size() > 1
        out.arg_to_param   = w->arg_to_param.copy()
        out.via_free       = w->free
        out.receiver_bound = has_receiver && !w->free
        out.ded            = w->ded
        out.inout_unmarked = w->inout_unmarked.copy()
        out.inout_params   = w->inout_params.copy()
        out.user_convs     = w->user_convs.copy()
        out.cxx_ret        = w->cxx_ret
        out.cxx_spec       = w->cxx_spec
        out.cxx_spec_set   = w->cxx_spec_set
        out.deref_dep      = w->deref_dep
        return out
    }

    /// A generic candidate whose `requires` clause is known false for its
    /// deduced arguments is not viable (requires.mdx: the clause is a
    /// compile-time gate), so overloads with complementary clauses never
    /// tie. Inline bounds are clause conjuncts (RequiresDesugar), so a
    /// failed `<T impl I>` counts the same, and so does a failed bound of
    /// the extension a member comes from. A clause that cannot be decided
    /// leaves the candidate viable. When the clause is the only thing
    /// standing against the one viable candidate it stays selected, and
    /// ConformanceChecking reports the clause at the instance; with
    /// several, each rejection is a note of the no-viable error.
    priv fn _requires_filter(self, cs: unsafe *[Candidate]) {
        if cs->size() < 2 {
            return
        }

        var fails: [usize]
        var whys:  [string]
        var held            = 0 as usize
        for var i: usize = 0; i < cs->size(); ++i {
            var *c = &(*cs)[i]
            if !c->viable() {
                continue
            }

            if c->f == &null || c->f->is_imported() || c->verdict() != Verdict::Viable {
                held += 1
                continue
            }

            var cc   = ConformanceChecking(self.sc)
            var r    = ClauseFalse{}
            var what = "its 'requires' clause"
            if c->generic && c->ded.is_complete(c->f) {
                r = cc.clause_false(c->f, unsafe &c->ded)
            }

            // An extension's bounds are the candidate's too: a member of
            // `extend <T impl I> Box<T>` does not exist for a `Box<X>`
            // whose X is not an I.
            if !r.known {
                r    = cc.extension_clause_false(c->f, unsafe &c->ded)
                what = "the bound of its extension"
            }

            if !r.known {
                held += 1
                continue
            }

            fails.push(i)
            whys.push(f"{what} does not hold: {r.why}")
        }

        if fails.size() == 0 || (held == 0 && fails.size() == 1) {
            return
        }

        for var i: usize = 0; i < fails.size(); ++i {
            var *c = &(*cs)[fails[i]]
            c->reject()
            c->reason = whys[i].copy()
        }
    }

    /// [temp.func.order]: of `winners`, all generic and tied, the one more
    /// specialized than each of the others, or `winners` unchanged. Only
    /// candidates of one kind are ordered (all members or all free), over the
    /// parameters the call's arguments landed on; a pack or C `...` slot
    /// leaves the tie for the ambiguity diagnostic. Two candidates equally
    /// specialized are ordered by their constraints (_more_specialized).
    priv fn _partial_order(self, cs: unsafe *[Candidate], const winners: [usize]) -> [usize] {
        var *first = &(*cs)[(((winners)[0]))]
        for var i: usize = 0; i < winners.size(); ++i {
            var *c = &(*cs)[(((winners)[i]))]
            if !(c->generic || self._of_generic_extension(c->f)) || c->free != first->free {
                return winners.copy()
            }
        }

        for var i: usize = 0; i < winners.size(); ++i {
            var *a   = &(*cs)[(((winners)[i]))]
            var best = true
            for var j: usize = 0; j < winners.size(); ++j {
                if i == j {
                    continue
                }

                var *b = &(*cs)[(((winners)[j]))]
                if !self._more_specialized(a, b) {
                    best = false
                    break
                }
            }

            if best {
                var one: [usize]
                one.push((winners)[i])
                return one
            }
        }

        return winners.copy()
    }

    /// `f` is a member of a generic extension (`extend <T> Box<T>`): a
    /// template in C++ through the extension's parameters, whether or not
    /// it declares its own.
    priv fn _of_generic_extension(self, f: unsafe *FunctionDecl) -> bool {
        if f == &null {
            return false
        }

        var unsafe *ext = decl_extension_of(unsafe (f as unsafe *Decl))
        return ext != &null && decl_generic_params(unsafe (ext as unsafe *Decl)).size() > 0
    }

    /// [temp.func.order]/2-6: `a` is more specialized than `b` when it is
    /// at least as specialized and `b` is not, or when each is at least as
    /// specialized as the other, their template heads are equivalent, and
    /// `a` is more constrained (ConformanceChecking::more_constrained):
    /// `requires T impl I` over no clause, `requires T impl I && T impl J`
    /// over `requires T impl I`. The emitted C++ heads carry the same
    /// clauses, so clang's own ordering picks the same candidate.
    priv fn _more_specialized(self, a: *Candidate, b: *Candidate) -> bool {
        if !self._as_specialized(a, b) {
            return false
        }

        if !self._as_specialized(b, a) {
            return true
        }

        if !self._equivalent_heads(a, b) || self._clause_open(a) || self._clause_open(b) {
            return false
        }

        return ConformanceChecking(self.sc).more_constrained(a->f, b->f)
    }

    /// `c`'s clause is not known to hold for its arguments
    /// (ConformanceChecking::clause_decided_true). Constraints order only
    /// candidates whose clauses are decided: C++ orders them after the
    /// clauses have admitted both, so one Kairo cannot decide (an open
    /// parameter, the `sizeof` of a class) may be false where C++ decides
    /// it, and C++ would call the other candidate. A tie this leaves in a
    /// generic body is _report_open_tie's.
    priv fn _clause_open(self, c: *Candidate) -> bool {
        if c->f == &null || c->f->is_imported() {
            return true
        }

        return !ConformanceChecking(self.sc).clause_decided_true(
            c->f,
            unsafe &c->ded,
        )
    }

    /// `a` and `b`, each at least as specialized as the other, have
    /// equivalent template parameter lists ([temp.over.link]/6): as many
    /// parameters, of the same kinds, and b's parameters deduce from a's
    /// parameter types position for position (`(x: T, y: U)` against `(x:
    /// U, y: T)` is not equivalent, so its constraints order nothing).
    priv fn _equivalent_heads(self, a: *Candidate, b: *Candidate) -> bool {
        var ga = a->f->generic_params
        var gb = b->f->generic_params
        if ga.size() != gb.size() || self._own_param_count(a) != self._own_param_count(b) {
            return false
        }

        for var k: usize = 0; k < ga.size(); ++k {
            if ga[k] == &null || gb[k] == &null {
                return false
            }

            if ga[k]->is_pack != gb[k]->is_pack || ga[k]->is_const_param != gb[k]->is_const_param {
                return false
            }
        }

        var pa = self._ordering_params(a)
        var pb = self._ordering_params(b)
        var d  = Deduction(self.sc, self.conv)
        for var k: usize = 0; k < pa.size() && k < pb.size(); ++k {
            if d.unify(
                self._ordering_type(pb[k]),
                self._ordering_type(pa[k]),
                false,
            ) != ImplicitRank::Exact {
                return false
            }
        }

        var unsafe *fa = NameLookup::representative(
            unsafe (a->f as unsafe *Decl),
        )

        for var k: usize = 0; k < gb.size(); ++k {
            var unsafe *x = d.lookup(unsafe (b->f as unsafe *Decl), k as u32)
            if x == &null {
                x = d.lookup(
                    NameLookup::representative(unsafe (b->f as unsafe *Decl)),
                    k as u32,
                )
            }

            if x == &null {
                continue
            }

            var unsafe *g = dyn_cast<GenericParamType>(canon_unqual(x))
            if g == &null || g->param_index != k as u32 || g->owner == &null {
                return false
            }

            if NameLookup::representative(g->owner) != fa {
                return false
            }
        }

        return true
    }

    /// `c`'s parameters other than its receiver, defaulted ones included:
    /// two function parameter lists of different lengths are not
    /// equivalent ([temp.over.link]), whatever the call passes.
    priv fn _own_param_count(self, c: *Candidate) -> usize {
        var n: usize = 0
        for var i: usize = 0; i < c->f->params.size(); ++i {
            var unsafe *p = c->f->params[i]
            if p != &null && !(p->is_self && !c->free) {
                n += 1
            }
        }

        return n
    }

    /// Whether `a` is at least as specialized as `b` ([temp.deduct.partial]):
    /// b's generic parameters deduce from a's parameter types, a's own
    /// generic parameters standing in as the unique types the rule asks for
    /// (a GenericParamType of a's is a type b can bind and never equals one
    /// of b's). References and top-level cv are stripped from both sides
    /// first, and no conversion is allowed: exact unification or nothing.
    priv fn _as_specialized(self, a: *Candidate, b: *Candidate) -> bool {
        // No argument lands on a parameter of either (`b.pick<i32>()`):
        // deduction compares nothing and succeeds both ways
        // ([temp.deduct.partial]/3), so the constraints decide.
        if a->arg_to_param.size() == 0 && b->arg_to_param.size() == 0 {
            return true
        }

        var pa = self._ordering_params(a)
        var pb = self._ordering_params(b)
        if pa.size() == 0 || pa.size() != pb.size() {
            return false
        }

        var d = Deduction(self.sc, self.conv)
        for var k: usize = 0; k < pa.size(); ++k {
            if d.unify(
                self._ordering_type(pb[k]),
                self._ordering_type(pa[k]),
                false,
            ) != ImplicitRank::Exact {
                return false
            }
        }

        return true
    }

    /// The parameter types `c`'s arguments landed on, in argument order;
    /// empty if one landed on a pack or C `...` tail, or a type is missing.
    priv fn _ordering_params(self, c: *Candidate) -> cxx::std::vector<unsafe *Type> {
        var params: [unsafe *ParamDecl]
        for var i: usize = 0; i < c->f->params.size(); ++i {
            var unsafe *p = c->f->params[i]
            if p == &null {
                continue
            }

            if p->is_self && !c->free {
                continue
            }

            params.push(p)
        }

        var out = cxx::std::vector<unsafe *Type>()
        for var i: usize = 0; i < c->arg_to_param.size(); ++i {
            var k = c->arg_to_param[i]
            if k >= params.size() {
                return cxx::std::vector<unsafe *Type>()
            }

            var unsafe *p = params[(k)]
            if p->type_ == &null || p->type_->canonical == &null {
                return cxx::std::vector<unsafe *Type>()
            }

            out.push_back(p->type_->canonical)
        }

        return out
    }

    /// [temp.deduct.partial]/5-7: a reference becomes its referee, then
    /// top-level cv goes.
    priv fn _ordering_type(self, t: unsafe *Type) -> unsafe *Type {
        var unsafe *c = t
        if isa<CXXLValueRefType>(c) {
            c = cast<CXXLValueRefType>(c)->referee
        } else if isa<CXXRValueRefType>(c) {
            c = cast<CXXRValueRefType>(c)->referee
        }

        return canon_unqual(c)
    }

    /// defer mode: whether `winners` leave the choice to the instance. A tie
    /// with an assumed candidate in it is not an ambiguity anyone can see
    /// yet. A lone assumed winner is a choice only when it is the ONLY viable
    /// candidate; otherwise the instance may rank it below another.
    priv fn _undecided(self, const cs: [Candidate], const winners: [usize]) -> bool {
        var any_assumed = false
        for var i: usize = 0; i < winners.size(); ++i {
            if (cs)[(((winners)[i]))].verdict() == Verdict::Assumed {
                any_assumed = true
            }
        }

        if !any_assumed {
            return false
        }

        if winners.size() > 1 {
            return true
        }

        var viable: usize = 0
        for var i: usize = 0; i < cs.size(); ++i {
            if (cs)[i].viable() {
                viable += 1
            }
        }

        return viable > 1
    }

    /// Every one of `winners` is an imported template whose substitution
    /// waits on a dependent argument (Verdict::SfinaeDeferred).
    priv fn _sfinae_pending(self, const cs: [Candidate], const winners: [usize]) -> bool {
        for var i: usize = 0; i < winners.size(); ++i {
            if (cs)[(((winners)[i]))].verdict() != Verdict::SfinaeDeferred {
                return false
            }
        }

        return true
    }

    /// The winners no other winner beats on reference kind.
    priv fn _ref_tiebreak(self,
                          cs:            unsafe *[Candidate],
                          const winners: [usize],
                          margs:         unsafe *[ArgInfo],
                          fargs:         unsafe *[ArgInfo]) -> [usize] {
        var keep: [usize]
        for var i: usize = 0; i < winners.size(); ++i {
            var *ci    = &(*cs)[(((winners)[i]))]
            var beaten = false
            for var j: usize = 0; j < winners.size(); ++j {
                if i == j {
                    continue
                }

                var        *cj   = &(*cs)[(((winners)[j]))]
                var unsafe *args = if (cj->free) => (fargs) else => margs
                if self._ref_better(cj, ci, args) {
                    beaten = true
                    break
                }
            }

            if !beaten {
                keep.push((winners)[i])
            }
        }

        if keep.size() == 0 { // a strict order never beats everyone; defensive.
            return winners.copy()
        }

        return keep
    }

    /// `x` beats `y` on reference kind: on no argument does `y` bind
    /// better, on at least one `x` does. The only "better" there is, and it
    /// applies only where BOTH bound at Exact ([over.ics.rank]/3.2.3, 3.2.6
    /// reduced): an rvalue argument prefers `T&&` to `const T&`, a non-const
    /// lvalue prefers `T&` to `const T&`. Nothing else is ordered: every
    /// other tie stays a tie, and ambiguity is still reported for it.
    ///
    /// Candidates from different argument lists (a member judged against the
    /// operands minus the receiver, a free function against all of them)
    /// are not position-aligned, so they never beat each other here.
    priv fn _ref_better(self, x: *Candidate, y: *Candidate, args: unsafe *[ArgInfo]) -> bool {
        if x->free != y->free {
            return false
        }

        if args == &null || x->judged.size() != args->size() || y->judged.size() != args->size() {
            return false
        }

        var better = false
        // The implicit object parameter, when both judged it: a non-const
        // object prefers `self` to `const self` exactly as a non-const
        // lvalue prefers `T&` to `const T&` -- data() over data() const. The
        // object counts as an lvalue even when it is a temporary
        // ([over.match.funcs]/5).
        // A base's method counts as the derived class's here: it reaches the
        // object through the `using Base::m;` InterfaceEmitter writes, and
        // C++ types such a method's implicit object parameter as the
        // DERIVED class ([over.match.funcs]/4), so a non-const object
        // prefers a base's `self` to the derived class's `const self`.
        // With ref-qualifiers on both ([over.ics.rank]/3.2.3 excludes only
        // an implicit object of a method WITHOUT one), the object is what it
        // is: a temporary prefers `q() &&` to `q() const &`.
        if x->recv_bind != RefBind::None && y->recv_bind != RefBind::None {
            var ra = ArgInfo()
            ra.cat = Expr::ValueCategory::LValue
            if x->f->ffi_ref_qualifier != 0 && y->f->ffi_ref_qualifier != 0 {
                ra.cat = self.recv_cat
            }

            ra.is_const = x->recv_const
            if x->recv_quals != y->recv_quals {
                // Different cv: both bind the object, so each covers the
                // object's cv (_judge_receiver), and the less qualified one
                // is better ([over.ics.rank]/3.2.6) -- data() over data()
                // const for a plain object. recv_bind sees only const: read
                // alone it tied std::atomic's `load() const` and `load()
                // const volatile`, and picked `m() volatile` over `m()
                // const`, which C++ calls ambiguous. Neither a subset of the
                // other stays a tie.
                var xq = x->recv_quals
                var yq = y->recv_quals
                if (xq & ~yq) == 0 {
                    better = true
                } else if (yq & ~xq) == 0 {
                    return false
                }
            } else if self._ref_prefers(&ra, x->recv_bind, y->recv_bind) {
                better = true
            } else if self._ref_prefers(&ra, y->recv_bind, x->recv_bind) {
                return false
            }
        }

        for var k: usize = 0; k < args->size(); ++k {
            var *a = &(*args)[k]
            if self._ref_prefers(a, x->judged[k].bind, y->judged[k].bind) {
                better = true
                continue
            }

            if self._ref_prefers(a, y->judged[k].bind, x->judged[k].bind) {
                return false
            }
        }

        return better
    }

    /// The winners no other winner beats on integer spelling.
    priv fn _int_tiebreak(self, cs: unsafe *[Candidate], const winners: [usize]) -> [usize] {
        var keep: [usize]
        for var i: usize = 0; i < winners.size(); ++i {
            var *ci    = &(*cs)[(((winners)[i]))]
            var beaten = false
            for var j: usize = 0; j < winners.size(); ++j {
                if i == j {
                    continue
                }

                if self._int_better(&(*cs)[(((winners)[j]))], ci) {
                    beaten = true
                    break
                }
            }

            if !beaten {
                keep.push((winners)[i])
            }
        }

        if keep.size() == 0 { // defensive, as _ref_tiebreak.
            return winners.copy()
        }

        return keep
    }

    /// `x` beats `y` on integer spelling: on no argument does `y` bind
    /// its natural C type where `x` binds an alias, on at least one the
    /// reverse. Kairo maps C integers by width, so an i32 is EXACT against
    /// both `int` and, on LLP64, `long`; to C++ only `int` is identity and
    /// `long` is an integral conversion ([over.ics.rank]/4). Without this,
    /// `std::cout << x` with x: i32 tied `operator<<(int)` and
    /// `operator<<(long)` on Windows. Only typed arguments: an untyped
    /// literal ties every integer overload on purpose (§5), and still does.
    /// Same alignment rule as _ref_better.
    priv fn _int_better(self, x: *Candidate, y: *Candidate) -> bool {
        if x->free != y->free {
            return false
        }

        if x->judged.size() != y->judged.size() {
            return false
        }

        var better = false
        for var k: usize = 0; k < x->judged.size(); ++k {
            if x->judged[k].int_kind == ExactFit::Natural
                && y->judged[k].int_kind == ExactFit::Alias {
                better = true
                continue
            }

            if x->judged[k].int_kind == ExactFit::Alias
                && y->judged[k].int_kind == ExactFit::Natural {
                return false
            }
        }

        return better
    }

    /// An imported function whose enable_if condition is false is no
    /// candidate, as in clang (CheckEnableIf). A condition only clang can
    /// decide, one naming a parameter, leaves the candidate viable.
    priv fn _enable_if(self, c: *Candidate) {
        var why = ""
        var state = ForeignInstantiate::decl_enable_if(
            unsafe (c->f as unsafe *Decl),
            &why,
        )

        c->enable_if = state
        if state != EnableIfState::Failed as u8 {
            return
        }

        c->reject()
        c->reason = if why.size() > 0 => f"its enable_if condition is false: {why}"
                    else => "its enable_if condition is false"
    }

    /// Of tied winners, those whose enable_if conditions all hold, when any
    /// do and some others have no enable_if at all: clang's
    /// compareEnableIfAttrs makes a function with enable_if attributes
    /// better than one without, so libc++'s `_LIBCPP_PREFERRED_OVERLOAD`
    /// `memchr` (`enable_if(true, "")`) beats the C library's. A winner
    /// whose condition clang decides only at the call is neither preferred
    /// nor dropped, and two winners that both have conditions stay tied:
    /// clang orders those by comparing the conditions, which Kairo does not.
    priv fn _enable_if_tiebreak(self, cs: unsafe *[Candidate], const winners: [usize]) -> [usize] {
        var held: [usize]
        var none          = false
        for var i: usize = 0; i < winners.size(); ++i {
            var st = (*cs)[winners[i]].enable_if
            if st == EnableIfState::Satisfied as u8 {
                held.push(winners[i])
            } else if st == EnableIfState::None as u8 {
                none = true
            } else {
                return winners.copy()
            }
        }

        if held.size() == 0 || !none {
            return winners.copy()
        }

        return held
    }

    /// The winners no other winner beats on pointee cv.
    priv fn _cv_tiebreak(self, cs: unsafe *[Candidate], const winners: [usize]) -> [usize] {
        var keep: [usize]
        for var i: usize = 0; i < winners.size(); ++i {
            var *ci    = &(*cs)[(((winners)[i]))]
            var beaten = false
            for var j: usize = 0; j < winners.size(); ++j {
                if i == j {
                    continue
                }

                if self._cv_better(&(*cs)[(((winners)[j]))], ci) {
                    beaten = true
                    break
                }
            }

            if !beaten {
                keep.push((winners)[i])
            }
        }

        if keep.size() == 0 { // defensive, as _ref_tiebreak.
            return winners.copy()
        }

        return keep
    }

    /// `x` beats `y` on pointee cv: on no argument does `x`'s pointer
    /// parameter point at MORE cv than `y`'s of the same pointee, on at
    /// least one it points at less. A derived pointer reaches `*Base` and
    /// `*const Base` alike, both at the Converted rank; C++ orders them
    /// because the first is a subsequence of the second plus a
    /// qualification conversion ([over.ics.rank]/3.2.1), so `cast(p)` with
    /// `cast(*Stmt)` beside `cast(*const Stmt)` took the first, and here was
    /// SC064E for every derived `p`. Only pointers to the same unqualified
    /// type are compared: a different pointee is a different conversion.
    /// Same alignment rule as _ref_better.
    priv fn _cv_better(self, x: *Candidate, y: *Candidate) -> bool {
        if x->free != y->free {
            return false
        }

        if x->judged.size() != y->judged.size() {
            return false
        }

        var better = false
        for var k: usize = 0; k < x->judged.size(); ++k {
            var unsafe *tx = x->judged[k].target
            var unsafe *ty = y->judged[k].target
            if tx == &null || ty == &null || tx == ty {
                continue
            }

            // `*B?` beside `*const B?` orders as `*B` beside `*const B`:
            // the null is carried alike, the pointee's cv is what
            // differs. Only when both are nullable: a `*B` beside a
            // `*const B?` differs in more than the qualification.
            if isa<NullableType>(canon_unqual(tx)) && isa<NullableType>(canon_unqual(ty)) {
                tx = self.tu.strip_nullable(canon_unqual(tx))
                ty = self.tu.strip_nullable(canon_unqual(ty))
                if tx == &null || ty == &null || tx == ty {
                    continue
                }
            }

            var unsafe *px = dyn_cast<PointerType>(canon_unqual(tx))
            var unsafe *py = dyn_cast<PointerType>(canon_unqual(ty))
            if px == &null || py == &null || px->is_unsafe != py->is_unsafe {
                continue
            }

            if px->pointee == &null || py->pointee == &null {
                continue
            }

            if canon_unqual(px->pointee) != canon_unqual(py->pointee) {
                continue
            }

            var qx = canon_quals(px->pointee)
            var qy = canon_quals(py->pointee)
            if qx == qy {
                continue
            }

            if (qx & ~qy) == 0 {
                better = true
                continue
            }

            if (qy & ~qx) == 0 {
                return false
            }
        }

        return better
    }

    /// The winners no other winner beats on a float literal's type.
    priv fn _flit_tiebreak(self, cs: unsafe *[Candidate], const winners: [usize]) -> [usize] {
        var keep: [usize]
        for var i: usize = 0; i < winners.size(); ++i {
            var *ci    = &(*cs)[(((winners)[i]))]
            var beaten = false
            for var j: usize = 0; j < winners.size(); ++j {
                if i == j {
                    continue
                }

                if self._flit_better(&(*cs)[(((winners)[j]))], ci) {
                    beaten = true
                    break
                }
            }

            if !beaten {
                keep.push((winners)[i])
            }
        }

        if keep.size() == 0 { // defensive, as _ref_tiebreak.
            return winners.copy()
        }

        return keep
    }

    /// `x` beats `y` on untyped float literals: on no argument does `y`
    /// bind f64 where `x` binds another float, on at least one the
    /// reverse. Kairo's literal takes any float it is given (§5), so both
    /// rank Exact; C++'s `16.0` is a double, an identity to `double` and a
    /// conversion to `float` / `long double`, which is how `std::sqrt(16.0)`
    /// picks one of libc++'s three overloads. Integer literals are
    /// left alone: C++ converts an int to every float alike, and ties there
    /// too. Same alignment rule as _int_better.
    priv fn _flit_better(self, x: *Candidate, y: *Candidate) -> bool {
        if x->free != y->free {
            return false
        }

        if x->judged.size() != y->judged.size() {
            return false
        }

        var better = false
        for var k: usize = 0; k < x->judged.size(); ++k {
            if x->judged[k].flit_kind == ExactFit::Natural
                && y->judged[k].flit_kind == ExactFit::Alias {
                better = true
                continue
            }

            if x->judged[k].flit_kind == ExactFit::Alias
                && y->judged[k].flit_kind == ExactFit::Natural {
                return false
            }
        }

        return better
    }

    /// ArgJudgment::flit_kind code for a float literal ranked Exact against
    /// `pt`, read through a reference and a nullable as _rank_literal_arg
    /// reads it. A dependent parameter is not judged: what the literal
    /// deduces there is the generic tiebreak's business, not this one's.
    priv fn _flit_code(self, pt: unsafe *Type) -> ExactFit {
        if pt == &null || pt->is_dependent() {
            return ExactFit::Unjudged
        }

        var unsafe *t = pt
        if isa<CXXLValueRefType>(t) {
            t = cast<CXXLValueRefType>(t)->referee
        } else if isa<CXXRValueRefType>(t) {
            t = cast<CXXRValueRefType>(t)->referee
        }

        t = canon_unqual(self.tu.strip_nullable(canon_unqual(t)))
        if t == &null || !self.tu.is_float(t) {
            return ExactFit::Unjudged
        }

        return if (self.tu.kind_of(t) == BuiltinKind::F64) => (ExactFit::Natural)
               else => ExactFit::Alias
    }

    /// ArgJudgment::flit_kind code for an int literal ranked Exact against an
    /// imported `pt`: Natural C's `int` (i32 spelled `int`, not LLP64's
    /// `long` alias), Alias any other type (a conversion to C++). Dependent:
    /// not judged.
    priv fn _ilit_code(self, pt: unsafe *Type, alias: bool) -> ExactFit {
        if pt == &null || pt->is_dependent() {
            return ExactFit::Unjudged
        }

        var unsafe *t = pt
        if isa<CXXLValueRefType>(t) {
            t = cast<CXXLValueRefType>(t)->referee
        } else if isa<CXXRValueRefType>(t) {
            t = cast<CXXRValueRefType>(t)->referee
        }

        t = canon_unqual(self.tu.strip_nullable(canon_unqual(t)))
        if t == &null || t->is_dependent() {
            return ExactFit::Unjudged
        }

        if (!alias) && self.tu.kind_of(t) == BuiltinKind::I32 {
            return ExactFit::Natural
        }

        return ExactFit::Alias
    }

    /// `Base::Base(self, other)` in a derived `@copy`/`@move` constructor:
    /// the transfer constructor's source parameter is a reference in C++
    /// (`const Base&`, `Base&&`), so the derived object binds by
    /// derived-to-base conversion, the copy of just the base part C++'s own
    /// implicit transfer constructor makes. Only on a constructor called by
    /// name (no receiver), and only for an argument of a class strictly
    /// derived from the parameter's: an ordinary `Base(d)` is still not a
    /// slicing copy, and a Base argument ranks as it always did.
    priv fn _transfer_upcast(self,
                             f:            unsafe *FunctionDecl,
                             p:            unsafe *ParamDecl,
                             a:            *ArgInfo,
                             pt:           unsafe *Type,
                             has_receiver: bool) -> bool {
        if has_receiver || f->transfer == TransferKind::NotTransfer || !f->is_method() {
            return false
        }

        if a->ty == &null || a->lit != LitKind::None || pt == &null || pt->is_dependent() {
            return false
        }

        var first: unsafe *ParamDecl = &null
        for var i: usize = 0; i < f->params.size(); ++i {
            if f->params[i] != &null && !f->params[i]->is_self {
                first = f->params[i]
                break
            }
        }

        if first != p {
            return false
        }

        var unsafe *av = canon_unqual(self.tu.as_value(a->ty))
        var unsafe *pv = canon_unqual(pt)
        if av == &null || pv == &null || av == pv {
            return false
        }

        return Substitution(self.sc).derives_from(av, pv)
    }

    /// The proper base of record `a` that is an instance of the pattern
    /// the dependent `self` type `pt` names, read through `a`'s
    /// arguments as Substitution::derives_from reads them; null if none.
    priv fn _self_upcast(self, a: unsafe *Type, pt: unsafe *Type) -> unsafe *Type {
        var unsafe *pr = dyn_cast<RecordType>(canon_unqual(pt))
        var unsafe *ar = dyn_cast<RecordType>(canon_unqual(self.tu.as_value(a)))
        if pr == &null || ar == &null || pr->decl == &null || ar->decl == &null {
            return &null
        }

        var unsafe *want = NameLookup::representative(
            self.tu.pattern_of(pr->decl),
        )

        if NameLookup::representative(self.tu.pattern_of(ar->decl)) == want {
            return &null
        }

        return self._base_instance(ar, want, 0)
    }

    priv fn _base_instance(self, t: unsafe *Type, want: unsafe *Decl, depth: u32) -> unsafe *Type {
        var unsafe *r = dyn_cast<RecordType>(canon_unqual(t))
        if r == &null || r->decl == &null || depth > DERIVES_WALK_DEPTH_MAX {
            return &null
        }

        if NameLookup::representative(self.tu.pattern_of(r->decl)) == want {
            return r
        }

        var unsafe *body = self.sc->record_body(r)
        if body == &null {
            return &null
        }

        var unsafe *cd = dyn_cast<ClassDecl>(NameLookup::representative(body))
        if cd == &null {
            return &null
        }

        for var i: usize = 0; i < cd->derives_list.size(); ++i {
            var unsafe *e = cd->derives_list.get(i)
            if e == &null || e->base == &null || e->base->canonical == &null {
                continue
            }

            var unsafe *c = canon_unqual(e->base->canonical)
            if c != &null && self.tu.param_edge(e) != &null {
                c = Substitution(self.sc).base_through(r, e) // the argument, or its bound's class.
            }

            if c == &null || !isa<RecordType>(c) {
                continue
            }

            if c->is_dependent() {
                var s = Substitution(self.sc)
                s.bind_from_record(r)
                var unsafe *sub = s.substitute(c)
                if sub != &null && isa<RecordType>(canon_unqual(sub)) {
                    c = canon_unqual(sub)
                }
            }

            var unsafe *hit = self._base_instance(c, want, depth + 1)
            if hit != &null {
                return hit
            }
        }

        return &null
    }

    /// Drop every member candidate a method of a class derived from its own
    /// overrides or hides: one with the same parameter types and the same
    /// `self` constness ([namespace.udecl]/14). MemberLookup MERGES a base's
    /// members with the derived class's (Compiler/Spec/Generics.md#partial-selection), which is C++'s
    /// lookup with a `using Base::m;` in the derived class -- the
    /// declaration InterfaceEmitter writes for every shared name -- and
    /// under a using-declaration a same-signature member of the derived
    /// class hides the base's rather than conflicting with it. Without this
    /// `d.k()` on an `override fn k` was SC064E "ambiguous" between D::k
    /// and A::k, and so was any same-name method, on the derived type.
    /// Different signatures stay and rank as usual: C++ keeps them too.
    /// Free candidates, and two methods of unrelated classes (two bases of
    /// a multiple-inheritance class: C++ calls that ambiguous too), are
    /// never compared.
    priv fn _hide(self, cs: unsafe *[Candidate]) {
        for var i: usize = 0; i < cs->size(); ++i {
            var *y = &(*cs)[i]
            if !y->viable() || y->free {
                continue
            }

            var unsafe *oy = self._method_owner(y->f)
            if oy == &null {
                continue
            }

            for var j: usize = 0; j < cs->size(); ++j {
                if i == j {
                    continue
                }

                var *x = &(*cs)[j]
                if x->free {
                    continue
                }

                var unsafe *ox = self._method_owner(x->f)
                if ox == &null || ox == oy {
                    continue
                }

                var seen = cxx::std::vector<unsafe *Decl>()
                if !self._class_derives(ox, oy, unsafe &seen, 0) {
                    continue
                }

                if !self._same_signature(x, y) {
                    continue
                }

                y->reject()
                y->reason = f"hidden by '{self.tu.decl_name(ox)}::{self.tu.decl_name((unsafe (x->f as unsafe *Decl)))}', which takes the same parameters"
                break
            }
        }
    }

    /// `x` and `y` take the same parameters after `self`, in the same
    /// modes, and the same `self` constness. A parameter that names a
    /// generic one of its record reads through what the call deduced
    /// (`GB<i32>`'s `h(self, t: T)` is `h(self, t: i32)`); one that stays
    /// dependent never matches.
    priv fn _same_signature(self, x: *Candidate, y: *Candidate) -> bool {
        var unsafe *fx = x->f
        var unsafe *fy = y->f
        if fx->generic_params.size() > 0 || fy->generic_params.size() > 0 {
            return false
        }

        if fx->is_method() != fy->is_method() {
            return false
        }

        if fx->is_method() && self._self_const(fx) != self._self_const(fy) {
            return false
        }

        var px: [unsafe *ParamDecl]
        var py: [unsafe *ParamDecl]
        for var i: usize = 0; i < fx->params.size(); ++i {
            if fx->params[i] != &null && !fx->params[i]->is_self {
                px.push(fx->params[i])
            }
        }

        for var i: usize = 0; i < fy->params.size(); ++i {
            if fy->params[i] != &null && !fy->params[i]->is_self {
                py.push(fy->params[i])
            }
        }

        if px.size() != py.size() {
            return false
        }

        for var i: usize = 0; i < px.size(); ++i {
            if self._sig_mode(fx, px[i]) != self._sig_mode(fy, py[i])
                || px[i]->is_pack != py[i]->is_pack {
                return false
            }

            var unsafe *tx = self._sig_type(x, px[i])
            var unsafe *ty = self._sig_type(y, py[i])
            if tx == &null || ty == &null || tx != ty {
                return false
            }
        }

        return true
    }

    /// `const self`: the receiver's own canonical carries the const.
    priv fn _self_const(self, f: unsafe *FunctionDecl) -> bool {
        var unsafe *p = f->params[0]
        if p == &null || p->type_ == &null || p->type_->canonical == &null {
            return false
        }

        return (canon_quals(p->type_->canonical) & QUAL_CONST) != 0
    }

    /// A C++ reference parameter is the mode a Kairo override spells it with
    /// (`const lo: T` for `const T&`, `@inout x: T` for `T&`, `@move x: T`
    /// for `T&&`): imported parameters carry the reference in their TYPE and
    /// leave the mode Value. Without this a Kairo `override` of
    /// `BeginSourceFile(const LangOptions&, ...)` never hid the base's
    /// virtual, and every call on the derived type was SC064E.
    priv fn _sig_mode(self, f: unsafe *FunctionDecl, p: unsafe *ParamDecl) -> ParamMode {
        if !f->is_imported() || p->type_ == &null || p->type_->canonical == &null {
            return p->mode
        }

        var unsafe *c = canon_unqual(p->type_->canonical)
        if c == &null {
            return p->mode
        }

        if isa<CXXRValueRefType>(c) {
            return ParamMode::Move
        }

        if isa<CXXLValueRefType>(c) {
            var unsafe *r = cast<CXXLValueRefType>(c)->referee
            if r != &null && (canon_quals(r) & QUAL_CONST) == 0 {
                return ParamMode::Inout
            }
        }

        return p->mode
    }

    priv fn _sig_type(self, c: *Candidate, p: unsafe *ParamDecl) -> unsafe *Type {
        if p->type_ == &null || p->type_->canonical == &null {
            return &null
        }

        var unsafe *t = canon_unqual(p->type_->canonical)
        // The reference itself is the mode (see _sig_mode); the referee is
        // the type, as the Kairo spelling gives it.
        if c->f->is_imported() && t != &null {
            if isa<CXXLValueRefType>(t) {
                t = cast<CXXLValueRefType>(t)->referee
            } else if isa<CXXRValueRefType>(t) {
                t = cast<CXXRValueRefType>(t)->referee
            }

            if t != &null {
                t = canon_unqual(t)
            }
        }

        if t != &null && t->is_dependent() {
            t = c->ded.substitute(t)
            if t != &null {
                t = canon_unqual(t)
            }
        }

        if t != &null && t->is_dependent() {
            return &null
        }

        return t
    }

    /// The record `f` is a member of, as its pattern's representative (an
    /// instance's members and the pattern's are one class for this
    /// question); null for a free function, an extension member or an
    /// interface requirement.
    priv fn _method_owner(self, f: unsafe *FunctionDecl) -> unsafe *Decl {
        if f == &null || f->semantic_dc == &null {
            return &null
        }

        var unsafe *dc = f->semantic_dc
        if !dc->is_type_scope() || dc->dc_kind == DeclContextKind::Extension {
            return &null
        }

        var unsafe *owner = dc->owner_decl()
        if owner == &null || !isa<ClassDecl>(owner) {
            return &null
        }

        return NameLookup::representative(self.tu.pattern_of(owner))
    }

    /// `d` (a pattern representative) reaches `base` through `derives`
    /// edges, by entity: the edge's arguments do not matter, because
    /// `base` is a pattern too and only the pattern's relation is asked.
    priv fn _class_derives(self,
                           d:     unsafe *Decl,
                           base:  unsafe *Decl,
                           seen:  unsafe *cxx::std::vector<unsafe *Decl>,
                           depth: u32) -> bool {
        if d == &null || depth > DERIVES_WALK_DEPTH_MAX || !isa<ClassDecl>(d) {
            return false
        }

        for var i: usize = 0; i < seen->size(); ++i {
            if (*seen)[i] == d {
                return false
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

            // A parameter base: by entity it reaches what its bound names,
            // and every class deriving the bound, which an argument may be
            // (a member such a class declares was found through the edge).
            if r == &null && self.tu.param_edge(e) != &null {
                var pb = self.tu.param_edge_bases(&null, e)
                if pb.size() > 0 {
                    r = dyn_cast<RecordType>(canon_unqual(pb[0]))
                }

                if r != &null && r->decl != &null {
                    var s2 = cxx::std::vector<unsafe *Decl>()
                    if self._class_derives(
                        base,
                        NameLookup::representative(self.tu.pattern_of(r->decl)),
                        unsafe &s2,
                        depth + 1,
                    ) {
                        return true
                    }
                }
            }

            if r == &null || r->decl == &null {
                continue
            }

            var unsafe *bd = NameLookup::representative(
                self.tu.pattern_of(r->decl),
            )

            if bd == base {
                return true
            }

            if self._class_derives(bd, base, seen, depth + 1) {
                return true
            }
        }

        return false
    }

    priv fn _ref_prefers(self, a: *ArgInfo, bx: RefBind, by: RefBind) -> bool {
        // A safe `&x` is the `@inout` marker (functions-parameter-modes.mdx):
        // binding it as `@inout` beats taking it as the pointer it would
        // otherwise be -- `pick(&x)` is `pick(int&)`, not `pick(int*)`;
        // `pick(unsafe &x)` is no marker and takes the pointer.
        if a->marked && bx == RefBind::LRef && by == RefBind::None {
            return true
        }

        // Two bindings of one converted temporary: it is an rvalue, so `T&&`
        // beats `const T&` ([over.ics.rank]/3.2.3), as for an rvalue at Exact.
        if by == RefBind::TempConstLRef {
            return bx == RefBind::TempRRef
        }

        if by != RefBind::ConstLRef { // only ever over `const T&`.
            return false
        }

        var rvalue = a->cat == Expr::ValueCategory::RValue || a->cat == Expr::ValueCategory::XValue
        if bx == RefBind::RRef && rvalue {
            return true
        }

        if bx == RefBind::LRef && a->cat == Expr::ValueCategory::LValue && !a->is_const {
            return true
        }

        return false
    }

    /// The ArgJudgment::bind kind for a parameter of type `pt`.
    priv fn _bind_kind(self, pt: unsafe *Type) -> RefBind {
        if pt == &null {
            return RefBind::None
        }

        if isa<CXXRValueRefType>(pt) {
            return RefBind::RRef
        }

        if isa<CXXLValueRefType>(pt) {
            return if (canon_has_const(cast<CXXLValueRefType>(pt)->referee)) => (RefBind::ConstLRef)
                   else => RefBind::LRef
        }

        return RefBind::None
    }

    priv fn _any_dependent(self, args: unsafe *[ArgInfo]) -> bool {
        if args == &null {
            return false
        }

        for var i: usize = 0; i < args->size(); ++i {
            if (*args)[i].dependent {
                return true
            }
        }

        return false
    }

    /// Judge every function in `cands` against `args` and append it to
    /// `cs`, skipping one `cs` already holds (fwd + def are one entity,
    /// RedeclMerge; and a decl reached as both member and ADL free is one).
    priv fn _collect(self,
                     cs:           unsafe *[Candidate],
                     cands:        unsafe *cxx::std::vector<unsafe *Decl>,
                     args:         unsafe *[ArgInfo],
                     has_receiver: bool,
                     receiver:     unsafe *Type,
                     free:         bool,
                     defer:        bool = false,
                     qualifier:    unsafe *Type = &null) {
        if cands == &null {
            return
        }

        for var i: usize = 0; i < cands->size(); ++i {
            var unsafe *f = dyn_cast<FunctionDecl>((*cands)[i])
            if f == &null {
                continue
            }

            // A `where` group is one candidate with one signature, and a
            // call binds to its lead, the function WhereDispatchLowering
            // makes the dispatcher (FunctionDecl::where_lead).
            if f->where_lead != &null {
                f = f->where_lead
            }

            if f->is_poisoned() {
                continue
            }

            // A specialization is never a candidate: C++ selects among primary
            // templates, and the call names the primary whose body (or a
            // member specialization's, FunctionDecl::member_spec_of) runs.
            if NameLookup::is_specialization(unsafe (f as unsafe *Decl))
                || f->member_spec_of != &null {
                continue
            }

            var seen = false
            for var j: usize = 0; j < cs->size(); ++j {
                if NameLookup::representative((*cs)[j].f) == NameLookup::representative(
                    unsafe (f as unsafe *Decl),
                ) {
                    seen = true
                    break
                }
            }

            if seen {
                continue
            }

            var c = Candidate()
            c.f       = f
            c.free    = free
            c.defer   = defer
            c.generic = f->generic_params.size() > 0
            c.ded     = Deduction(self.sc, self.conv)
            if !self._bind_explicit(&c) {
                cs->push(c)
                continue
            }

            self._judge(unsafe &c, args, has_receiver, receiver, qualifier)
            if c.viable() && f->is_imported() {
                self._enable_if(&c)
            }

            if c.viable() && c.generic && f->is_imported() && c.verdict() != Verdict::Assumed {
                self._clang_substitute(&c, args, has_receiver)
            }

            cs->push(c)
        }
    }

    /// An imported function template Kairo found viable goes through clang's
    /// own deduction and substitution as well (ForeignInstantiate::
    /// deduce_call), so a substitution failure removes it exactly as in
    /// C++: libc++'s `make_unique` overloads differ only in which
    /// `enable_if_t<...> = 0` fails, and `vector::insert(pos, a, b)` keeps
    /// its iterator template away from two integers the same way. Kairo's
    /// deduction cannot evaluate any of it -- the conditions are C++
    /// expressions over the deduced arguments -- and asking for one shape
    /// at a time would never end. A Kairo candidate in the same set is not
    /// touched, and neither is the ranking among the survivors.
    ///
    /// The arguments go to clang in C++ order: param slots in declaration
    /// order, a pack's run where the pack is, C `...` extras last. The
    /// implicit object is not one of them (no explicit object parameters
    /// are imported), so a `Type::m(obj, ...)` call drops `obj`. Anything
    /// clang cannot be shown leaves the candidate as Kairo judged it.
    priv fn _clang_substitute(self, c: *Candidate, args: unsafe *[ArgInfo], has_receiver: bool) {
        if self.sc->foreign == &null || args == &null {
            return
        }

        var unsafe *f                          = c->f
        var        params: [unsafe *ParamDecl]
        for var i: usize = 0; i < f->params.size(); ++i {
            var unsafe *p = f->params[i]
            if p == &null {
                continue
            }

            if p->is_self && has_receiver {
                continue
            }

            params.push(p)
        }

        var order: [usize]
        for var k: usize = 0; k < params.size(); ++k {
            if params[k]->is_self {
                continue
            }

            if params[k]->is_pack {
                for var i: usize = 0; i < args->size(); ++i {
                    if c->arg_to_param[i] == ARG_PACK_TAIL {
                        order.push(i)
                    }
                }

                continue
            }

            for var i: usize = 0; i < args->size(); ++i {
                if c->arg_to_param[i] == k {
                    order.push(i)
                }
            }
        }

        for var i: usize = 0; i < args->size(); ++i {
            if c->arg_to_param[i] == ARG_C_VARARG {
                order.push(i)
            }
        }

        var tys     = cxx::std::vector<unsafe *Type>()
        var cats    = cxx::std::vector<Expr::ValueCategory>()
        var conv_at = cxx::std::vector<usize>()
        for var j: usize = 0; j < order.size(); ++j {
            var *a              = &(*args)[order[j]]
            var t: unsafe *Type = &null
            // A list literal becomes whatever container its parameter asks
            // for, which C++ only learns from Kairo's lowering: not shown.
            if a->lit == LitKind::List {
                return
            }

            var to_clang = false
            for var q: usize = 0; q < c->clang_convs.size(); ++q {
                if c->clang_convs[q] == order[j] {
                    to_clang = true
                }
            }

            if to_clang {
                conv_at.push_back(j)
            }

            if self.tu.c_string_literal(a->expr) != &null
                && (to_clang || self._forwards_cstr(c->f, a, c->judged[order[j]].target)) {
                // What EmitIR writes: the literal's bytes, which C++ reads
                // as `const char[N]` decayed (CallTyping, user_convs).
                t = self.tu.c_string_ptr_type()
            } else if a->lit != LitKind::None {
                // A literal takes the type it was ranked at: its default
                // where a deduced parameter reads it, which is what C++
                // deduces from the literal EmitIR writes.
                t = self._literal_default(a, c->judged[order[j]].target)
            } else if a->ty != &null {
                t = canon_unqual(self.tu.as_value(a->ty))
                if a->is_const && a->cat != Expr::ValueCategory::RValue {
                    t = self.sc->types->qualified(t, QUAL_CONST)
                }
            }

            // `&x` as the marker on a C++ `T&` is `x` itself, an lvalue,
            // which is what EmitIR writes and what C++ deduces `T` from:
            // shown as the pointer, `steal(&h)` against `steal(T&)` deduced
            // `T = Res*`.
            var marked_ref = false
            if a->marked && t != &null && a->lit == LitKind::None {
                var k = c->arg_to_param[order[j]]
                if k < params.size() && params[k]->type_ != &null {
                    var unsafe *pk = if (params[k]->type_->canonical != &null) => (params[k]->type_->canonical)
                                     else => params[k]->type_
                    var unsafe *pe = self.tu.pointee(t)
                    if isa<CXXLValueRefType>(canon_unqual(pk)) && pe != &null {
                        t          = pe
                        marked_ref = true
                    }
                }
            }

            if t == &null { // `null`, `.V`: nothing clang can be shown.
                return
            }

            // A generic body's argument (`x: T`): which template survives is
            // each instance's question, exactly as for a dependent call in a
            // C++ template. Flagged, so a tie it leaves defers (resolve_mixed).
            if t->is_dependent() || t->is_instantiation_dependent() {
                c->note(Verdict::SfinaeDeferred)
                var unsafe *ue = dyn_cast<UnaryOperatorExpr>(a->expr)
                if ue != &null && ue->op_token.kind == TokenKind::OpStar {
                    c->deref_dep = true
                }

                return
            }

            tys.push_back(t)
            cats.push_back(
                     if (marked_ref) => (Expr::ValueCategory::LValue)
                else if (a->lit != LitKind::None) => (Expr::ValueCategory::RValue)
                else => a->cat,
            )
        }

        var why = ""
        // The specialization's return type is wanted only where Kairo's
        // import of it is opaque: a return type that IS the SFINAE
        // (`enable_if_t<cond, int>`, `-> decltype(...)`) has no Kairo shape.
        var want_ret = f->return_type != &null
            && f->return_type->canonical != &null
            && has_opaque_ffi(f->return_type->canonical)
        // So is one Kairo's deduction cannot finish: a parameter only
        // clang deduces (from a derived-class argument, `out << s` on an
        // ofstream against `basic_ostream<C, T>& operator<<(basic_ostream<C,
        // T>&, const basic_string<C, T, A>&)`) leaves the declared return
        // type dependent, and the call ended untyped.
        if !want_ret
            && f->return_type != &null
            && f->return_type->canonical != &null
            && f->return_type->canonical->is_dependent()
            && c->ded.substitute(f->return_type->canonical) == &null {
            want_ret = true
        }

        var ret:      unsafe *Type = &null
        var spec:     unsafe *void = &null
        var spec_set: unsafe *void = &null
        var fid:      i64          = -1
        if self.sc->ctx != &null {
            fid = (self.sc->ctx->fid)
        }

        // The calling TU's own header set: deduce_call's retry when the
        // function's set cannot spell an argument.
        var alt: unsafe *void = &null
        if self.sc->tu != &null {
            alt = self.sc->tu->header_set
        }

        var keep = self.sc->foreign->deduce_call(
            f,
            unsafe &self.explicit_args,
            unsafe &tys,
            unsafe &cats,
            self.sc->diag,
            unsafe &why,
            want_ret,
            &ret,
            &spec,
            &spec_set,
            fid,
            alt,
            unsafe &conv_at,
        )

        if keep == 1 {
            c->cxx_spec     = spec
            c->cxx_spec_set = spec_set
        }

        // An opaque in clang's answer is taken only when it is not the
        // declared type over again: `std::move(v)` of a `__m128i` returns
        // `__m128i&&`, an opaque but the argument's own type, where the
        // declaration's `__libcpp_remove_reference_t<_Tp>&&` binds nothing.
        // The same opaque as declared (an undeduced `auto`) adds no
        // information and keeps the declared type.
        var same_as_declared = f->return_type != &null && ret == f->return_type->canonical
        if keep == 1 && ret != &null && (!has_opaque_ffi(ret) || !same_as_declared) {
            c->cxx_ret = ret
        }

        if keep == 0 {
            c->reject()
            c->reason = f"template ignored: {why}"
        }

        // Removed over a Kairo record's stand-in: maybe the stand-in's fault
        // (no methods), so it only loses a tie (resolve_mixed).
        if keep == 2 {
            c->note(Verdict::SoftRejected)
        }
    }

    /// # one candidate

    /// explicit_args into `c`'s deduction, positionally. More arguments than
    /// `c` has generic parameters, or any for a non-generic one, makes it
    /// not viable; a value where a type parameter is (or the reverse) too.
    priv fn _bind_explicit(self, c: *Candidate) -> bool {
        var n = self.explicit_args.size()
        if n == 0 {
            return true
        }

        var gps = c->f->generic_params
        // A type pack among the parameters takes every written argument from
        // its slot on ([temp.arg.explicit]/9), so the count cannot overflow.
        var has_pack = false
        for var g: usize = 0; g < gps.size(); ++g {
            if gps[g] != &null && gps[g]->is_pack {
                has_pack = true
            }
        }

        if n > gps.size() && !has_pack {
            c->reject()
            c->reason = f"it takes {gps.size()} generic argument(s), and {n} were written"
            return false
        }

        for var i: usize = 0; i < n; ++i {
            var unsafe *gp = gps[i]
            var unsafe *a  = self.explicit_args[i]
            if gp == &null || a == &null || gp->owner == &null {
                continue
            }

            // `isa<A, B>(x)` against `template <typename... To, typename From>`:
            // the pack takes every written argument from here and the
            // parameters after it deduce, as clang does. A pack that ALSO
            // types a function parameter would have the written elements
            // extended by the arguments' (push_pack appends), which nothing
            // checks yet, so that stays rejected.
            if gp->is_pack {
                var in_params = false
                for var k: usize = 0; k < c->f->params.size(); ++k {
                    if c->f->params[k] != &null && c->f->params[k]->is_pack {
                        in_params = true
                    }
                }

                if in_params || gp->is_const_param {
                    c->reject()
                    var pn = self.sc->ctx->get_spelling(gp->name)
                    c->reason = f"'{pn}' is a type pack, deduced from the arguments; it cannot be written as a generic argument yet"
                    return false
                }

                c->ded.open_pack(gp->owner, gp->index)
                for var j: usize = i; j < n; ++j {
                    var unsafe *e = self.explicit_args[j]
                    if e == &null {
                        continue
                    }

                    var unsafe *ce = canon_unqual(e)
                    if isa<TypeExpr>(ce) && cast<TypeExpr>(ce)->is_value {
                        c->reject()
                        var pn2 = self.sc->ctx->get_spelling(gp->name)
                        c->reason = f"'{pn2}' is a type pack, and argument {j + 1} is a value"
                        return false
                    }

                    c->ded.push_pack(gp->owner, gp->index, e)
                }

                c->ded.seeded = true
                return true
            }

            var unsafe *ca = canon_unqual(a)
            var is_value = isa<TypeExpr>(ca) && cast<TypeExpr>(ca)->is_value
            if isa<GenericParamType>(ca) {
                var unsafe *g = cast<GenericParamType>(ca)
                var        ps = decl_generic_params(g->owner)
                var        ix = (g->param_index as usize)
                if g->owner != &null && ix < ps.size() && ps[ix] != &null {
                    is_value = ps[ix]->is_const_param
                }
            }

            if is_value != gp->is_const_param {
                c->reject()
                var nm = self.sc->ctx->get_spelling(gp->name)
                c->reason = if (gp->is_const_param) => (f"'{nm}' is a generic value parameter, and argument {i + 1} is a type")
                            else => f"'{nm}' is a type parameter, and argument {i + 1} is a value"
                return false
            }

            c->ded.bind(gp->owner, gp->index, a)
            // As a receiver's args do: a parameter they decide ranks as the
            // type it is, so `gen<i64>(4)` takes the literal as an i64.
            c->ded.seeded = true
        }

        return true
    }

    /// The implicit object parameter ([over.match.funcs]/4): the receiver
    /// OBJECT against `self`, whose canonical carries the method's cv -- a
    /// const method's self is `const Record` (TypeResolve's
    /// _synthesize_receiver, and DeclImport through `this`). It binds as a
    /// reference would: a const object cannot bind a plain `self`, and
    /// either object binds `const self`. `receiver`'s own cv is the
    /// object's; null means no object is known, and nothing is judged.
    /// `f` is declared in the body of a partial specialization.
    priv fn _member_of_partial(self, f: unsafe *FunctionDecl) -> bool {
        if f->semantic_dc == &null {
            return false
        }

        var unsafe *dc = f->semantic_dc
        if !dc->is_type_scope() || dc->dc_kind == DeclContextKind::Extension {
            return false
        }

        var unsafe *owner = dc->owner_decl()
        return owner != &null && decl_spec_kind(owner) == SpecKind::Partial
    }

    /// `f` is declared in the body of the pattern `receiver` is a
    /// concrete instance of (`Opt<i32>` for a member of `class <T> Opt`).
    /// An inherited member is not: its parameters are its own record's.
    priv fn _member_of_instance(self, f: unsafe *FunctionDecl, receiver: unsafe *Type) -> bool {
        if f->semantic_dc == &null {
            return false
        }

        var unsafe *dc = f->semantic_dc
        if !dc->is_type_scope() || dc->dc_kind == DeclContextKind::Extension {
            return false
        }

        var unsafe *owner = dc->owner_decl()
        if owner == &null {
            return false
        }

        var unsafe *r = dyn_cast<RecordType>(canon_unqual(receiver))
        if r == &null || r->is_dependent() || r->is_instantiation_dependent() {
            return false
        }

        var unsafe *own = NameLookup::representative(owner)
        if r->args.size() > 0 && own == NameLookup::representative(self.tu.pattern_of(r->decl)) {
            return true
        }

        // A member of `L<i32>::Cell`: typed over L's parameters, which the
        // receiver's enclosing instance binds (GH#91).
        if r->outer != &null {
            return true
        }

        // A member of a generic BASE the concrete receiver derives an
        // instance of (CRTP: `s.me()` on `class Seven derives
        // Mixin<Seven>`): bind_from_record reads the receiver's bases too,
        // so Mixin's X is Seven before any argument is ranked.
        if decl_generic_params(own).size() == 0 {
            return false
        }

        return own != NameLookup::representative(self.tu.pattern_of(r->decl))
    }

    /// The instance of `c`'s declaring interface that a bound of the
    /// parameter `receiver` names, read through the bound's `derives` chain
    /// (`C impl Wrapped<i32>` declares Container's `get` at
    /// `Container<Wrap<i32>>`); null when `receiver` is no bounded
    /// parameter or no bound declares the candidate. The first bound that
    /// does wins: two bounds reaching one requirement at different
    /// arguments is a conflict the bounds' own checking owns, not this call.
    priv fn _bound_declaring(self, c: unsafe *Candidate, receiver: unsafe *Type) -> unsafe *Type {
        var bs = Substitution(self.sc).bound_ifaces(receiver)
        for var i: usize = 0; i < bs.size(); ++i {
            var unsafe *di = c->ded.declaring_instance(c->f, bs[i])
            if di != &null {
                return di
            }
        }

        return &null
    }

    priv fn _judge_receiver(self,
                            c:        unsafe *Candidate,
                            p:        unsafe *ParamDecl,
                            receiver: unsafe *Type) {
        if receiver == &null || p->type_ == &null || p->type_->canonical == &null {
            return
        }

        var sq = canon_quals(p->type_->canonical)
        // An imported method's constness is clang's own (CXXMethodDecl::
        // isConst, DeclImport::_define_function). In a multi-input build the
        // imported `self` type can come back without its cv (every
        // `array<bool, 256>::operator[]` candidate read sq == 0), and then
        // the const and non-const overloads both bound as non-const and tied
        // in _ref_better. clang's rule needs the method's constness, not the
        // type's.
        if c->f->is_imported() && p->is_const {
            sq = sq | QUAL_CONST
        }

        var oq = canon_quals(receiver)
        if (oq & ~sq) != 0 {
            c->reject()
            // An operator has no name token to spell (TokenText::resolve
            // asserts on its empty one): its symbol, `op +=`.
            var nm = if (c->f->is_operator) => ("op " + OperatorFacts::symbol(
                         c->f,
                     ))
                     else => self.tu.decl_name(c->f)
            c->reason       = f"'{nm}' is not const; it cannot be called on a const object"
            c->const_reject = true
            return
        }

        c->recv_bind  = if ((sq & QUAL_CONST) != 0) => (RefBind::ConstLRef) else => RefBind::LRef
        c->recv_const = (oq & QUAL_CONST) != 0
        c->recv_quals = sq & (QUAL_CONST | QUAL_VOLATILE)
        // A ref-qualified method's implicit object parameter IS a reference
        // ([over.match.funcs]/4) and binds like one: `q() &` an lvalue
        // only (`const &` anything), `q() &&` an rvalue only. Without a
        // qualifier any object binds, rvalues included (/5), as above.
        var rq = c->f->ffi_ref_qualifier
        if rq == 0 {
            return
        }

        var rvalue = self.recv_cat == Expr::ValueCategory::RValue
            || self.recv_cat == Expr::ValueCategory::XValue
        var mname = if (c->f->is_operator) => ("op " + OperatorFacts::symbol(
                        c->f,
                    ))
                    else => self.tu.decl_name(c->f)
        if rq == 1 && rvalue && (sq & QUAL_CONST) == 0 {
            c->reject()
            c->reason = f"'{mname}' is '&'-qualified; it cannot be called on a temporary"
            return
        }

        if rq == 2 && !rvalue {
            c->reject()
            c->reason = f"'{mname}' is '&&'-qualified; it can only be called on a temporary"
            return
        }

        if rq == 2 {
            c->recv_bind = RefBind::RRef
        }
    }

    priv fn _judge(self,
                   c:            unsafe *Candidate,
                   args:         unsafe *[ArgInfo],
                   has_receiver: bool,
                   receiver:     unsafe *Type,
                   qualifier:    unsafe *Type = &null) {
        var unsafe *f = c->f

        // parameter slots, skipping the receiver when it is bound elsewhere.
        var params: [unsafe *ParamDecl]
        for var i: usize = 0; i < f->params.size(); ++i {
            var unsafe *p = f->params[i]
            if p == &null {
                continue
            }

            if p->is_self && has_receiver {
                self._judge_receiver(c, p, receiver)
                if !c->viable() {
                    return
                }

                continue
            }

            params.push(p)
        }

        // An extension's own parameters are the receiver's, decided before any
        // argument is ranked (Deduction::bind_from_extension).
        if !c->ded.bind_from_extension(f, receiver) {
            c->reject()
            c->reason = "the receiver is not an instance this extension applies to"
            return
        }

        // A member of a PARTIAL specialization is over the partial's own
        // parameters, which no argument need name the way it is passed:
        // `Store(self, v: *const P)` called with a `*i32` deduces nothing
        // (the pointee lacks the const), yet `Store<*const i32>` already
        // says P := i32. The receiver binds them before any argument is
        // ranked.
        //
        // A primary's members the same, on a concrete instance: the record's
        // parameters are its arguments, not a guess from the call's. Left to
        // the arguments, `fn Opt(self, v: T)` deduced T := NullT from
        // `Opt<i32>(NullT {})` and tied the exact `fn Opt(self, n: NullT)`;
        // a constructor has no `self` argument to bind T first. A dependent
        // receiver is defer mode's (member_through), or deduces as before.
        if receiver != &null && self._member_of_partial(f) {
            c->ded.bind_from_record(canon_unqual(receiver))
            c->ded.seeded = true
        } else if receiver != &null && !c->defer && self._member_of_instance(f, receiver) {
            c->ded.bind_from_record(canon_unqual(receiver))
            c->ded.seeded = true
        }

        // `Container<i32>::get(b, 0)`: the requirement's interface parameters
        // are the qualifier's, so `-> T` reads i32 and `x: T` takes one. Left
        // to the arguments, nothing binds a T the parameters never name.
        if qualifier != &null {
            var unsafe *di = c->ded.declaring_instance(f, qualifier)
            if di != &null {
                c->ded.bind_from_record(di)
                c->ded.seeded = true
            }
        } else if receiver != &null {
            // `c.get(1)` through `C impl PW<i32>`: the bound is the qualifier
            // the call did not write. The body is checked once, against its
            // bounds (Compiler/Spec/Generics.md#decisions), so the requirement means what the bound
            // says at the bound's arguments -- `-> Wrap<V>` reads `Wrap<i32>`
            // -- and the result is an ordinary value. Left unbound, V made
            // the result unknown: nothing checked `var z: Q = c.shine()`, and
            // `c.get(1).w` reached codegen with its member step unbound.
            // A non-generic interface has nothing to bind, and its `Self` is
            // call_result_type's (through_receiver), so it is not seeded.
            var unsafe *di = self._bound_declaring(c, receiver)
            if di != &null && self.tu.record_args(di).size() > 0 {
                c->ded.bind_from_record(di)
                c->ded.seeded = true
            }
        }

        var nparams = params.size()
        // The pack is wherever it is MARKED, not the last slot: a keyword-only
        // tail sits after it, and treating the last parameter as the pack gave
        // every one of those arguments to the wrong place.
        var pack_at = usize::MAX
        for var i: usize = 0; i < nparams; ++i {
            if params[i]->is_pack {
                pack_at = i
                break
            }
        }

        var filled: [u8]
        for var i: usize = 0; i < nparams; ++i {
            filled.push(0)
        }

        for var i: usize = 0; i < args->size(); ++i {
            c->arg_to_param.push(ARG_PACK_TAIL) // placed below
            c->judged.push(ArgJudgment{})
        }

        // 1. NAMED first, then positional. Placement has to know which slots a
        //    name already claimed before it decides where the positionals
        //    stop, and reading the list once in source order cannot: a name
        //    may appear before the positional it affects.
        for var i: usize = 0; i < args->size(); ++i {
            var *a = &(*args)[i]
            if a->name.size() == 0 {
                continue
            }

            var found = usize::MAX
            for var j: usize = 0; j < nparams; ++j {
                if self.tu.param_name(params[j]) == a->name {
                    found = j
                    break
                }
            }

            if found == usize::MAX {
                c->reject()
                c->reason_code = DiagID::SC019E
                c->reason      = f"no parameter named '{a->name}'"
                return
            }

            if filled[found] != 0 {
                c->reject()
                c->reason_code = DiagID::SC020E
                c->reason      = f"parameter '{a->name}' was already given"
                return
            }

            filled[found]      = 1
            c->arg_to_param[i] = found
        }

        // 2. positional, left to right over the slots no name claimed.
        //    pack_lo/pack_hi/pack_n describe the pack's RUN in `args`, which
        //    CallExpr::arg_map records as a first index plus a length.
        var pos:     usize = 0
        var pack_lo: usize = usize::MAX
        var pack_hi: usize = usize::MAX
        var pack_n:  usize = 0
        for var i: usize = 0; i < args->size(); ++i {
            var *a = &(*args)[i]
            if a->name.size() > 0 {
                continue
            }

            if pack_at != usize::MAX && pos >= pack_at {
                // This argument joins the pack. If it cannot, the useful
                // reading is usually not "bad pack element" but "you meant a
                // keyword-only parameter and wrote it positionally" -- there
                // is no argument count at which a positional reaches one, so
                // without this the user gets a conversion error naming the
                // pack and no hint that the parameter they wanted exists.
                var kw = self._keyword_only_meant(
                    c,
                    a,
                    unsafe &params,
                    pack_at,
                    nparams,
                    receiver,
                )

                if kw != usize::MAX {
                    c->reject()
                    c->reason_code = DiagID::SC018E
                    c->reason = f"parameter '{self.tu.param_name(params[kw])}' can only be given by name; it follows a pack, so this argument joins the pack instead"
                    return
                }

                if pack_lo == usize::MAX {
                    pack_lo = i
                }

                pack_hi = i
                pack_n += 1
                c->arg_to_param[i] = ARG_PACK_TAIL
                filled[pack_at]    = 1
                continue
            }

            while pos < nparams && filled[pos] != 0 {
                pos += 1
            }

            if pos >= nparams {
                // C `...`: a positional argument past the declared ones has
                // no parameter to judge it against; C's default promotions
                // are the callee's contract, not a Kairo conversion.
                if f->ffi_c_variadic {
                    c->arg_to_param[i] = ARG_C_VARARG
                    continue
                }

                c->reject()
                c->reason = f"expects {nparams} argument(s), {args->size()} given"
                return
            }

            filled[pos]        = 1
            c->arg_to_param[i] = pos
            pos += 1
        }

        // 2a. the pack must be one unbroken run. arg_map describes it as a
        //     first index plus a length, so a named argument spliced into the
        //     middle would put a non-member inside that run and CallLowering
        //     would reorder it as a pack element.
        if pack_n > 0 && pack_hi - pack_lo + 1 != pack_n {
            c->reject()
            c->reason_code = DiagID::SC022E
            c->reason = "a named argument cannot appear between two pack arguments; move it after them"
            return
        }

        // 3. missing parameters need defaults. A parameter WITHOUT a default is
        //    allowed to follow one with a default, so an unfilled slot here is
        //    never implied by the slots around it. The default is looked for
        //    across the WHOLE chain: defaults accumulate over redeclarations,
        //    and the link judged here need not be the one that wrote it.
        for var j: usize = 0; j < nparams; ++j {
            if filled[j] != 0 {
                continue
            }

            if j == pack_at {
                continue
            }

            if self.tu.param_default(f, self.tu.param_index(f, params[j])) != &null {
                continue
            }

            var pn = self.tu.param_name(params[j])
            c->reason_code = DiagID::SC021E
            c->reject()
            c->reason = f"missing argument for parameter '{pn}'"
            return
        }

        // 3b. A C++ function's defaults are clang's, applied by omission, and a
        //     C++ call can only omit TRAILING arguments. A named argument that
        //     fills a parameter after an unfilled defaulted one has no C++
        //     spelling.
        if f->is_imported() {
            var skipped: unsafe *ParamDecl = &null
            for var j: usize = 0; j < nparams; ++j {
                if j == pack_at {
                    continue
                }

                if filled[j] == 0 {
                    if skipped == &null {
                        skipped = params[j]
                    }

                    continue
                }

                if skipped != &null {
                    c->reject()
                    c->reason_code = DiagID::SC107E
                    c->reason = f"parameter '{self.tu.param_name(params[j])}' is given but '{self.tu.param_name(skipped)}' before it is left to its C++ default; a C++ call can only leave out trailing defaults"
                    return
                }
            }
        }

        // 4. rank every placed argument. A type pack is bound even when no
        //    argument reaches it: `f()` of `fn <...T> f(...xs: T)` is T = {}.
        if pack_at != usize::MAX && param_is_type_pack(params[pack_at]) {
            var unsafe *pg = param_type_pack_param(params[pack_at])
            c->ded.open_pack(pg->owner, pg->param_index)
        }

        // A parameter read through an associated type (`v: J::Item`,
        // `v: S::Item?`) is a non-deduced context ([temp.deduct.type]/5.1):
        // it is ranked after every other argument, against its type at what
        // they deduced (J := Count makes it Count's Item).
        var order: [usize]
        var later: [usize]
        for var i: usize = 0; i < args->size(); ++i {
            var pj                    = c->arg_to_param[i]
            var pd: unsafe *ParamDecl = &null
            if pj == ARG_PACK_TAIL {
                pd = params[pack_at]
            } else if pj != ARG_C_VARARG {
                pd = params[pj]
            }

            if pd != &null
                && !pd->is_self
                && pd->type_ != &null
                && self._reads_assoc(pd->type_->canonical) {
                later.push(i)
            } else {
                order.push(i)
            }
        }

        for var i: usize = 0; i < later.size(); ++i {
            order.push(later[i])
        }

        for var oi: usize = 0; oi < order.size(); ++oi {
            var i  = order[oi]
            var *a = &(*args)[i]
            var pi = c->arg_to_param[i]
            if pi == ARG_C_VARARG { // Converted, unchecked.
                if c->rank < CAND_CONVERTED {
                    c->rank = CAND_CONVERTED
                }

                continue
            }

            var p: unsafe *ParamDecl = if (pi != ARG_PACK_TAIL) => (params[pi])
                                       else => params[pack_at]
            var pt: unsafe *Type = &null
            if p->type_ != &null {
                pt = p->type_->canonical
            }

            // Top-level cv on a parameter is not part of the call
            // ([dcl.fct]/5): `f(const i32)` takes an i32. The receiver is
            // exempt -- its `const` is `const Foo*`, one level down.
            if pt != &null && !p->is_self {
                pt = canon_unqual(pt)
            }

            if p->type_ != &null && p->type_->is_poisoned() {
                c->reject()
                c->reason = "parameter type is invalid"
                return
            }

            pt = c->ded.through_receiver(c->f, canon_unqual(receiver), pt) // `other: Self` is `other: <receiver>`.
            if pt != &null && !c->defer && pt->is_dependent() && self._reads_assoc(pt) {
                var unsafe *sp = c->ded.substitute(pt)
                if sp != &null && !sp->is_dependent() {
                    pt = canon_unqual(sp)
                }
            }

            // Defer mode: read the parameter through the call's record
            // arguments (`Box<U>`'s `p: T` is `p: U`), then assume what is
            // still dependent on either side. No unify: the receiver is a
            // pattern, and binding its parameters from an argument would
            // decide what only the instance knows.
            if c->defer {
                if pt != &null {
                    pt = c->ded.member_through(canon_unqual(receiver), pt)
                }

                if pt == &null || pt->is_dependent() || a->dependent {
                    if pt == &null
                        && (p->type_ == &null
                            || !(p->type_->is_dependent()
                                || p->type_->is_instantiation_dependent())) {
                        c->reject()
                        c->reason = "parameter type is unresolved"
                        return
                    }

                    c->note(Verdict::Assumed)
                    continue
                }
            }

            if pt == &null {
                // dependent-but-uncanonical parameter (`[T; N]`, an alias
                // application substitution could not rewrite): cannot
                // decide here; accept at Converted and let M2 judge.
                if p->type_ != &null
                    && (p->type_->is_dependent() || p->type_->is_instantiation_dependent()) {
                    if c->rank < CAND_CONVERTED {
                        c->rank = CAND_CONVERTED
                    }

                    continue
                }

                c->reject()
                c->reason = "parameter type is unresolved"
                return
            }

            // The parameter's mode. A pack tail ranks by value; the receiver
            // never reaches here (bound above, and it takes no mode).
            var mode = if (pi == ARG_PACK_TAIL) => (ParamMode::Value) else => p->mode
            // A C++ `T&` is `@inout x: T` (cxx_lref_inout): judged as one,
            // against its referee, so `&x` is the marker and binds by reference.
            if self.call_syntax
                && pi != ARG_PACK_TAIL
                && isa<CXXLValueRefType>(pt)
                && cxx_lref_inout(f, p, a->marked) {
                mode = ParamMode::Inout
                pt   = canon_unqual(cast<CXXLValueRefType>(pt)->referee)
            }

            c->judged[i].target = pt
            // `Base::m(obj)`: the object is an ordinary argument here, but
            // it is still the implicit object, which C++ binds as `Base&`
            // (`const Base&` for `const self`) -- a Derived binds by
            // derived-to-base conversion and nothing is sliced or copied.
            // Ranked by value it was not viable at all, and the qualified
            // call is the only way to reach a base's version (no `super`).
            // The object counts as an lvalue even when it is a temporary
            // ([over.match.funcs]/5), as on the receiver path.
            var unsafe *rt = pt
            var        *ra = a
            var        obj = ArgInfo()
            if p->is_self && !pt->is_dependent() && a->lit == LitKind::None {
                rt      = self.sc->types->cxx_lref(pt)
                obj     = a->copy()
                obj.cat = Expr::ValueCategory::LValue
                ra      = &obj
            } else if a->if_lvalue && p->mode == ParamMode::Inout {
                // Kairo's own `@inout` borrows a place, and an `if`
                // expression is none. A C++ `T&` still binds the lvalue the
                // emitted conditional is, and asks for its marker.
                obj          = a->copy()
                obj.cat      = Expr::ValueCategory::RValue
                obj.is_const = false
                ra           = &obj
            }

            var r = ImplicitRank::None
            if self._transfer_upcast(f, p, a, pt, has_receiver) {
                r = ImplicitRank::Converted
            } else if self._c_string_literal_arg(f, a, pt, mode) {
                // Exact, as in C++: `"ab"` is `const char[3]`, whose decay to
                // `const char *` is an exact-match conversion. At Converted a
                // template `append(const _Tp&)` deduced from the literal's
                // `string` outranked `append(const char *)`, and the literal
                // was then emitted as a builtin::string clang cannot take.
                // Tied at Exact, the non-generic candidate wins.
                r = ImplicitRank::Exact
                // A string literal is taken at `const char *` AND `const u8 *`
                // (unsigned char, char8_t, uint8_t), but to C++ the literal
                // IS `const char[N]`: only the first is viable there. Both
                // here, they tied -- `llvm::outs() << "\n"` against
                // raw_ostream's `<<(const char *)` and its deleted
                // `<<(const char8_t *)`. The integer tiebreak orders them:
                // `char` is the natural spelling, a byte pointer the alias.
                var unsafe *lp = self.tu.pointee(canon_unqual(pt))
                c->judged[i].int_kind = if (lp != &null
                                            && self.tu.is_builtin(
                                                canon_unqual(lp),
                                                BuiltinKind::CChar,
                                            )) => (ExactFit::Natural)
                                        else => ExactFit::Alias
            } else {
                r = self._rank_arg(c, ra, rt, pi == ARG_PACK_TAIL, mode)
            }

            // `Box<i32>::Box(self, n)` from `class IntBox derives Box<i32>`:
            // a generic record's `self` is `Box<T>`, and unification alone
            // never looks past IntBox for it. C++ deduces against a base of
            // the argument ([temp.deduct.call]/4.3), and so does this.
            if r == ImplicitRank::None && p->is_self && pt->is_dependent() && a->ty != &null {
                var unsafe *up = self._self_upcast(a->ty, pt)
                if up != &null {
                    r = if (c->ded.unify(
                            canon_unqual(pt),
                            up,
                            true,
                        ) != ImplicitRank::None) => (ImplicitRank::Converted)
                        else => ImplicitRank::None
                }
            }

            // C++ takes an argument through one implicit user-defined
            // conversion ([over.best.ics]); Kairo does only at a C++ callee
            // and only under -fcxx-implicit-conv (crossing into
            // C++ follows C++; -fimplicit-conv is the
            // Kairo-side rules and has no say here). Below every standard
            // conversion, as C++ ranks it. Without the flag the reason says
            // which conversion C++ would have used.
            var uto:     unsafe *Type = &null
            var uvia                  = ""
            var cxx_conv              = self.sc->cxx_implicit_conv_on()
            if r == ImplicitRank::None && mode != ParamMode::Inout {
                uto = self._cxx_conv_target(f, a, pt)
                if uto != &null {
                    uvia = self._cxx_conv_via(f, a, uto)
                }
            }

            // `fmt::format(fmt: format_string<T...>, args: T&&...)`: the
            // parameter is a C++ alias over the pack, opaque to Kairo, and
            // T... comes from the OTHER arguments. Which class the literal
            // must become is known only once clang has substituted T..., so
            // the conversion is clang's to check at deduction.
            if r == ImplicitRank::None
                && uvia == ""
                && mode != ParamMode::Inout
                && cxx_conv
                && c->generic
                && f->is_imported()
                && (!a->marked)
                && has_opaque_ffi(pt)
                && (self.tu.c_string_literal(a->expr) != &null
                    || (a->ty != &null
                        && self._is_cxx_record(
                            canon_unqual(self.tu.as_value(a->ty)),
                        ))) {
                c->user_convs.push(i)
                c->clang_convs.push(i)
                if c->rank < CAND_USER_CONV {
                    c->rank = CAND_USER_CONV
                }

                continue
            }

            if uvia != "" && cxx_conv {
                c->user_convs.push(i)
                if c->rank < CAND_USER_CONV {
                    c->rank = CAND_USER_CONV
                }

                continue
            }

            if r == ImplicitRank::None {
                var pn = self.tu.param_name(p)
                var got = if (a->ty != &null) => (self.tu.str(a->ty)) else => "<literal>"
                if a->lit == LitKind::Variant {
                    got = "." + a->lit_name
                }

                if mode == ParamMode::Inout {
                    var iv = if (a->marked && a->inner_ty != &null) => (self.tu.str(
                                 a->inner_ty,
                             ))
                             else => got
                    c->reject()
                    c->reason = f"parameter '{pn}' is {LangAttrs::quoted(LangAttrs::param_inout())} and needs a mutable lvalue of type '{self.tu.str(pt)}'; got '{iv}'"
                    c->const_reject = a->ty != &null && canon_has_const(a->ty)
                        || a->inner_ty != &null && canon_has_const(a->inner_ty)
                    var unsafe *ca = dyn_cast<UnaryOperatorExpr>(a->expr)
                    if ca != &null && ca->const_addr {
                        c->reason = f"parameter '{pn}' is {LangAttrs::quoted(LangAttrs::param_inout())} and writes its argument; 'const &' makes a pointer to const, not the '&' marker"
                    }

                    // `&x[k]` where the type's `op []=` is only the setter
                    // form took the read form: there is no place to pass.
                    var unsafe *cs = if (ca != &null) => (dyn_cast<SubscriptExpr>(
                                         self.tu.strip_parens(ca->operand),
                                     ))
                                     else => (unsafe (&null as unsafe *SubscriptExpr))
                    var unsafe *cf = if (cs != &null
                                         && cs->resolved_op != &null) => (dyn_cast<FunctionDecl>(
                                         cs->resolved_op,
                                     ))
                                     else => (unsafe (&null as unsafe *FunctionDecl))
                    if cf != &null && OperatorFacts::reads_setter_only(cf) {
                        c->reason += "; its type declares only the setter form of 'op []=', so declare the place form, 'fn op []= (self, k: K) -> *V'"
                    }

                    return
                }

                // The type it was ranked against: on `Box<i32>`, `v: T`
                // takes an i32, and "of type 'T'" names nothing the caller
                // can pass.
                var unsafe *shown = pt
                if c->ded.seeded && (pt->is_dependent() || pt->in_generic_owner()) {
                    var unsafe *sp = c->ded.substitute(pt)
                    if sp != &null {
                        shown = sp
                    }
                }

                c->reject()
                c->reason = f"cannot convert argument of type '{got}' to parameter '{pn}' of type '{self.tu.str(shown)}'"
                if uvia != "" {
                    var tn = self.tu.str(uto)
                    c->uconv_to  = tn.copy()
                    c->uconv_via = uvia.copy()
                    c->fix_at    = a->range.end
                    c->fix_open  = a->range.start
                    c->fix_text  = f" as {tn}"
                    if self._needs_parens_for_as(a->expr) {
                        c->fix_text  = ")" + c->fix_text
                        c->fix_paren = true
                        c->fix_open  = a->range.start
                    }
                }

                // A C string parameter takes C chars only: bytes (`*u8`,
                // a string's `data`) or i8s become them by reinterpreting
                // the pointer, which is the edit, inside `unsafe`.
                if self._c_string_reinterpret(a->ty, pt) {
                    c->reason += "; a C string is '*const c_char' (std::c_char), which no byte or i8 pointer converts to"
                    c->fix_text = f" as {self.tu.str(pt)}"
                    c->fix_at   = a->range.end
                } else if self._raw_fn_from_capturing(a, pt) {
                    // SC258E's wording, which a declaration's initializer
                    // gets: as a bare SC063E a capturing closure handed to
                    // `qsort` said only that the types differ.
                    if a->expr != &null && isa<ClosureExpr>(self.tu.strip_parens(a->expr)) {
                        c->reason += "; this closure captures, so it has no function pointer: only a named function or a closure that captures nothing is a raw 'unsafe fn'"
                    } else {
                        c->reason += "; a 'fn' value may hold a capturing closure, which has no function pointer: only a named function or a closure that captures nothing is a raw 'unsafe fn'"
                    }
                } else if f->is_imported()
                    && a->ty != &null
                    && self.tu.is_string(a->ty)
                    && self.tu.is_c_string_param(pt)
                    && mode != ParamMode::Inout {
                    // Only a literal is its own C string; any other
                    // string hands over its NUL-terminated bytes, O(1).
                    c->reason += "; a string other than a literal passes its bytes with '.c_str()'"
                    c->fix_text = ".c_str()"
                    c->fix_at   = a->range.end
                }

                return
            }

            // An unmarked argument reaching `@inout` is TOLERATED (CallTyping
            // warns), never preferred: it ranks as a conversion. At Exact it
            // would tie `f(x: T)` and make `f(a)` ambiguous; ranked as a
            // conversion, the by-value overload wins `f(a)` and `f(&a)` still picks `@inout`.
            // Kairo's own `@inout` only: a C++ `T&` read as one
            // (cxx_lref_inout) ranks as C++ ranks it, so `(int&, const int&)`
            // still picks `int&` for a bare lvalue -- and SC097E says the
            // marker is missing, rather than `const int&` winning silently.
            if mode == ParamMode::Inout
                && !a->marked
                && r == ImplicitRank::Exact
                && p->mode == ParamMode::Inout {
                r = ImplicitRank::Converted
            }

            if r == ImplicitRank::Converted && c->rank < CAND_CONVERTED {
                c->rank = CAND_CONVERTED
            }

            // An `@inout` binding IS a `T&` binding for the reference tiebreak.
            if r == ImplicitRank::Exact {
                c->judged[i].bind = if (mode == ParamMode::Inout) => (RefBind::LRef)
                                    else => self._bind_kind(rt)
                // Only a forwarding reference takes an lvalue at `T&&`: T
                // deduces to the lvalue reference and the parameter
                // collapses to it ([dcl.ref]/6), `T&` or `const T&` as the
                // argument is.
                if c->judged[i].bind == RefBind::RRef && ra->cat == Expr::ValueCategory::LValue {
                    c->judged[i].bind = if (ra->is_const) => (RefBind::ConstLRef)
                                        else => RefBind::LRef
                }
            }

            // A reference reached through a conversion binds the converted
            // TEMPORARY, an rvalue whatever the argument was: `push_back(x)`
            // with x: i32 into `vector<i64>`. Recorded apart from the Exact
            // kinds (the Temp ones), so only two such bindings are ever
            // compared (_ref_prefers).
            if r == ImplicitRank::Converted && mode != ParamMode::Inout {
                var bk = self._bind_kind(pt)
                if bk != RefBind::None {
                    c->judged[i].bind = ref_bind_on_temp(bk)
                }
            }

            if r == ImplicitRank::Exact
                && a->lit == LitKind::None
                && a->ty != &null
                && self.tu.is_integer(a->ty) {
                c->judged[i].int_kind = if (p->cxx_int_alias) => (ExactFit::Alias)
                                        else => ExactFit::Natural
            }

            // usize / isize is C++'s size_t / ptrdiff_t, which every target
            // Kairo builds for makes the natural C type of its width
            // (`unsigned long` on LP64, `unsigned long long` on LLP64). So
            // against an imported same-width integer parameter it is the
            // identity where that parameter is the natural type and a
            // conversion where it is the other alias -- the same order the
            // fixed-width case has at Exact. Without it both converted and
            // `cxx::std::to_string(n)` with n: usize tied `to_string(unsigned
            // long)` and `to_string(unsigned long long)`, which clang does not.
            if r == ImplicitRank::Converted
                && f->is_imported()
                && a->lit == LitKind::None
                && a->ty != &null {
                var ak = self.tu.kind_of(self.tu.as_value(a->ty))
                if (ak == BuiltinKind::USize || ak == BuiltinKind::ISize)
                    && self.tu.is_integer(pt)
                    && self.tu.int_bits(canon_unqual(pt)) == self.tu.int_bits(
                        canon_unqual(self.tu.as_value(a->ty)),
                    )
                    && self.tu.is_signed_int(pt) == (ak == BuiltinKind::ISize) {
                    c->judged[i].int_kind = if (p->cxx_int_alias) => (ExactFit::Alias)
                                            else => ExactFit::Natural
                }
            }

            if r == ImplicitRank::Exact && a->lit == LitKind::Float {
                c->judged[i].flit_kind = self._flit_code(pt)
            }

            // An imported overload set is ranked as C++ ranks it (docs:
            // c-cpp.mdx, Overloading), and to C++ an unsuffixed `7` is an
            // int: the identity to `int`, a conversion to everything else.
            // Kairo's literal takes any integer or float it fits (§5), so
            // without this `f(int)` / `f(unsigned)` / `f(double)` all rank
            // Exact and `f(7)` would be ambiguous. Same code space and
            // tiebreak as a float literal. Kairo's own overloads keep the
            // documented closed list of tiebreaks: none orders an int literal.
            if r == ImplicitRank::Exact && a->lit == LitKind::Int && f->is_imported() {
                c->judged[i].flit_kind = self._ilit_code(pt, p->cxx_int_alias)
            }

            if mode == ParamMode::Inout && !a->marked {
                c->inout_unmarked.push(i)
                c->inout_params.push(p)
            }
        }

        // 5. a generic candidate must have deduced every param. In defer mode
        //    an assumed argument deduced nothing, so a gap is assumed too.
        //    An imported template's undeduced defaults are bound first.
        if c->generic && f->is_imported() {
            c->ded.fill_ffi_defaults(f)
        }

        if c->generic && c->verdict() == Verdict::Assumed && !c->ded.is_complete(f) {
            return
        }

        if c->generic && !c->ded.is_complete(f) {
            c->reject()
            c->reason = "could not deduce every generic parameter from the arguments"
            return
        }

        var unsafe *ext = decl_extension_of(f)
        if ext != &null && !c->ded.is_complete(ext) {
            c->reject()
            c->reason = "could not deduce the extension's generic parameters"
            return
        }
    }

    /// The keyword-only parameter `a` was probably meant for, or usize(-1).
    ///
    /// Only asked when the argument does NOT fit the pack, so the answer is
    /// "there is a parameter this would have fitted, and it is unreachable
    /// positionally". Dependent parameters are skipped on both sides: ranking
    /// one unifies into `c->ded`, and this is a speculative probe that must
    /// leave the candidate exactly as it found it.
    priv fn _keyword_only_meant(self,
                                c:        unsafe *Candidate,
                                a:        *ArgInfo,
                                params:   unsafe *[unsafe *ParamDecl],
                                pack_at:  usize,
                                nparams:  usize,
                                receiver: unsafe *Type) -> usize {
        var unsafe *pack_ty = self._param_target(c, *params, pack_at, receiver)
        if pack_ty == &null || pack_ty->is_dependent() {
            return usize::MAX
        }

        if self._rank_arg(c, a, pack_ty, true, ParamMode::Value) != ImplicitRank::None {
            return usize::MAX
        }

        for var j: usize = 0; j < nparams; ++j {
            if !(*params)[j]->keyword_only {
                continue
            }

            var unsafe *kt = self._param_target(c, *params, j, receiver)
            if kt == &null || kt->is_dependent() {
                continue
            }

            if self._rank_arg(c, a, kt, false, (*params)[j]->mode) != ImplicitRank::None {
                return j
            }
        }

        return usize::MAX
    }

    /// The parameter's canonical target type as the ranking loop derives it:
    /// top-level cv dropped, `Self` resolved through the receiver.
    priv fn _param_target(self,
                          c:            unsafe *Candidate,
                          const params: [unsafe *ParamDecl],
                          j:            usize,
                          receiver:     unsafe *Type) -> unsafe *Type {
        var unsafe *p = (params)[j]
        if p->type_ == &null {
            return &null
        }

        var unsafe *pt = p->type_->canonical
        if pt == &null {
            return &null
        }

        if !p->is_self {
            pt = canon_unqual(pt)
        }

        return c->ded.through_receiver(c->f, canon_unqual(receiver), pt)
    }

    /// `mode` is the parameter's passing mode. `@inout` is judged exactly as
    /// a C++ `T&` parameter is (Conversion::ref_binding, [over.ics.ref]): a
    /// mutable lvalue of T binds Exact, a derived object Converted, a
    /// temporary never. `@move` ranks by VALUE: `f(x)` moves, the call site
    /// writes nothing, and MoveCheck owns what follows. No new ranking rule
    /// lives here; modes restate the reference rules in Kairo terms.
    priv fn _rank_arg(self,
                      c:       unsafe *Candidate,
                      a:       *ArgInfo,
                      pt:      unsafe *Type,
                      is_pack: bool,
                      mode:    ParamMode) -> ImplicitRank {
        // A parameter the receiver already decided ranks as the type it is: a
        // literal takes it (§5), an argument converts to it, nothing re-deduces it.
        if c->ded.seeded && pt != &null && (pt->is_dependent() || pt->in_generic_owner()) {
            var unsafe *s = c->ded.substitute(pt)
            if s != &null {
                pt = s
            }
        }

        if mode == ParamMode::Inout {
            // The operand's view when marked; the argument itself otherwise
            // (viable; CallTyping warns). A literal is a prvalue and can never
            // be borrowed mutably.
            var unsafe *ty = a->ty
            var        cat = a->cat
            var        cst = a->is_const
            if a->pass_moves {
                cat = Expr::ValueCategory::LValue
            }

            if a->marked {
                ty  = a->inner_ty
                cat = a->inner_cat
                cst = a->inner_const
            }

            if !a->marked && a->lit != LitKind::None {
                return ImplicitRank::None
            }

            if ty == &null {
                return ImplicitRank::None
            }

            if pt->is_dependent() {
                // `fn <T> f(@inout x: T)`: T deduces from the operand's view,
                // then binds as a plain `T&` -- a const lvalue does not bind.
                var d = c->ded.unify(pt, ty, true)
                // A C++ `X<T>&` read as `@inout` (cxx_lref_inout) deduces
                // from a derived argument too ([temp.deduct.call]/4.3):
                // getline's `basic_istream<C, T>&` from an istringstream.
                // Unification does that through the reference form.
                if d == ImplicitRank::None && c->f != &null && c->f->is_imported() {
                    d = c->ded.unify(self.sc->types->cxx_lref(pt), ty, true)
                }

                if d == ImplicitRank::None {
                    return ImplicitRank::None
                }

                var unsafe *lref = self.sc->types->cxx_lref(canon_unqual(ty))
                return self.conv->ref_binding(lref, cat, cst, RefRel::Same)
            }

            var unsafe *lref = self.sc->types->cxx_lref(pt)
            return self.conv->implicit_arg(ty, lref, cat, cst)
        }

        // Pack element: the param's canonical is the pack's generic param
        // (VariadicPackType shares it). Bind nothing -- a pack is one slot
        // with many types, and the registry does not model that yet -- accept.
        if is_pack {
            // A type pack's element is the argument's own type, by value (a
            // literal its default): that is the instance's element, and what
            // C++'s `T... xs` deduces from the same argument.
            var unsafe *pg = dyn_cast<GenericParamType>(pt)
            // An imported pack's pattern through a reference -- `Args&&...`
            // (emplace_back, make_unique), `const Ts&...` -- deduces each
            // element through the reference, as [temp.deduct.call]/3 reads a
            // single `T&&`: any argument binds a forwarding `&&` or a `const
            // &`, only an lvalue a plain `&`. The element is still the
            // argument's value type; C++ re-deduces the reference itself.
            var pref: unsafe *Type = &null
            if pg == &null {
                if isa<CXXRValueRefType>(pt) {
                    pref = cast<CXXRValueRefType>(pt)->referee
                }

                if isa<CXXLValueRefType>(pt) {
                    pref = cast<CXXLValueRefType>(pt)->referee
                }

                if pref != &null {
                    pg = dyn_cast<GenericParamType>(canon_unqual(pref))
                }
            }

            if pg != &null && pg->is_pack {
                if pref != &null
                    && isa<CXXLValueRefType>(pt)
                    && !canon_has_const(pref)
                    && a->cat != Expr::ValueCategory::LValue {
                    return ImplicitRank::None
                }

                var et: unsafe *Type = &null
                if self._forwards_cstr(c->f, a, pt) {
                    // `args: T&&...` of a C++ template: a literal element is
                    // a C string, as for a single forwarding reference.
                    et = self.tu.c_string_ptr_type()
                } else if a->lit != LitKind::None {
                    et = self._literal_default(a, pg)
                } else if a->ty != &null {
                    et = self.tu.as_value(a->ty)
                }

                if et == &null { // `null`, `.V`: no type to deduce an element from.
                    return ImplicitRank::None
                }

                c->ded.push_pack(pg->owner, pg->param_index, et)
                return ImplicitRank::Exact
            }

            if pt->is_dependent() {
                return ImplicitRank::Converted
            }

            if a->lit != LitKind::None {
                return self._rank_literal_arg(a, pt)
            }

            return self.conv->implicit_arg(a->ty, pt, a->cat, a->is_const)
        }

        if a->lit != LitKind::None {
            if pt->is_dependent() {
                // `fn <T> f(x: T, r: Range<T>)` with `f(n, 0..4)`: an
                // argument before it deduced T, and the range takes that
                // element type as it takes a concrete parameter's.
                if a->lit == LitKind::Range {
                    var unsafe *sp = c->ded.substitute(pt)
                    if sp != &null && !sp->is_dependent() {
                        return self._rank_literal_arg(a, sp)
                    }
                }

                // `fn <T> f(x: T)` with `f(10)`: T := the literal's default.
                var unsafe *def = self._literal_default(a, pt)
                if self._forwards_cstr(c->f, a, pt) {
                    def = self.tu.c_string_ptr_type()
                }

                if def == &null {
                    return ImplicitRank::None
                }

                var ur = c->ded.unify(pt, def, true)
                // A literal is a prvalue: it binds a deduced `T&&` as its
                // referee matched.
                if ur != ImplicitRank::None && isa<CXXRValueRefType>(canon_unqual(pt)) {
                    ur = c->ded.rref_rank
                }

                // A list literal reaching a slice or vector is never Exact.
                if ur != ImplicitRank::None
                    && a->lit == LitKind::List
                    && !isa<FixedArrayType>(canon_unqual(def)) {
                    return ImplicitRank::Converted
                }

                return ur
            }

            return self._rank_literal_arg(a, pt)
        }

        if a->ty == &null {
            return ImplicitRank::None
        }

        if pt->is_dependent() {
            var u = c->ded.unify(pt, self._foreign_deduce_arg(c, a, pt), true)
            if u == ImplicitRank::None {
                return u
            }

            // Deduction sees types only; a dependent reference still binds by
            // category ([dcl.init.ref]). `X<T>&&` that is not a forwarding
            // reference (a bare `T&&`) takes no lvalue, and a non-const
            // `X<T>&` no rvalue: getline's `basic_istream<C, T>&&` overload
            // tied the `&` one for an ifstream variable.
            var unsafe *pc    = canon_unqual(pt)
            var        lvalue = a->cat == Expr::ValueCategory::LValue
            var rvalue = a->cat == Expr::ValueCategory::RValue
                || a->cat == Expr::ValueCategory::XValue
            if isa<CXXRValueRefType>(pc) {
                var unsafe *rr = cast<CXXRValueRefType>(pc)->referee
                var forwarding = isa<GenericParamType>(rr) && canon_quals(rr) == 0
                if lvalue && !forwarding {
                    return ImplicitRank::None
                }

                // Deduction ranked the binding without the category. With
                // it, the binding is the referee's own match: an rvalue
                // binds `X<T>&&` directly, and a forwarding reference
                // deduces the argument's own type and kind
                // ([temp.deduct.call]/3), an identity either way. Ranked
                // as a conversion, a forwarding constructor lost to a
                // `const T&` one that C++ ranks below it.
                return c->ded.rref_rank
            } else if isa<CXXLValueRefType>(pc) {
                // A MOVE value is only an xvalue by CallTyping's say-so; a plain `T&` borrows it.
                if rvalue
                    && !a->pass_moves
                    && !canon_has_const(cast<CXXLValueRefType>(pc)->referee) {
                    return ImplicitRank::None
                }
            }

            return u
        }

        // A MOVE value passed to a plain `T&` is not moved from: the reference
        // borrows it (`T&` is an `@inout` parameter, c-cpp-calling.md), so
        // it binds as the lvalue it is -- the xvalue CallTyping gave it would
        // never bind a non-const lvalue reference, and `ci->ExecuteAction(act)`
        // with a non-copyable `act` had no viable candidate.
        var cat = a->cat
        if a->pass_moves
            && isa<CXXLValueRefType>(pt)
            && !canon_has_const(cast<CXXLValueRefType>(pt)->referee) {
            cat = Expr::ValueCategory::LValue
        }

        var r = self.conv->implicit_arg(a->ty, pt, cat, a->is_const)
        // A C/C++ signature reads `size_t` at the target's width: `u32` into
        // `write(int, const void*, size_t)` widens there (Conversion::abi_widen).
        if r == ImplicitRank::None && c->f != &null && c->f->is_imported() {
            r = self.conv->abi_widen(a->ty, pt)
        }

        // A tuple literal converts element by element (ExprTyper's
        // check_convertible retypes it once the call is chosen): never
        // Exact, since its own type is not the parameter's.
        if r == ImplicitRank::None && self.conv->tuple_literal_fits(a->expr, pt) {
            r = ImplicitRank::Converted
        }

        return r
    }

    /// A literal is a PRVALUE of whatever type it takes. Against a reference
    /// parameter that makes it the referee exactly (Same) when it takes that
    /// type (§5), a temporary (Converts) when it only fits by conversion, and
    /// Conversion::ref_binding decides from there -- the literal has no
    /// reference rule of its own.
    priv fn _rank_literal_arg(self, a: *ArgInfo, pt: unsafe *Type) -> ImplicitRank {
        var referee: unsafe *Type = &null
        if isa<CXXLValueRefType>(pt) {
            referee = cast<CXXLValueRefType>(pt)->referee
        }

        if isa<CXXRValueRefType>(pt) {
            referee = cast<CXXRValueRefType>(pt)->referee
        }

        if referee == &null {
            return self._rank_literal(a, pt)
        }

        var vr = self._rank_literal(a, canon_unqual(referee))
        var rel =      if (vr == ImplicitRank::Exact) => (RefRel::Same)
                  else if (vr == ImplicitRank::Converted) => (RefRel::Converts)
                  else => RefRel::None
        return self.conv->ref_binding(
            pt,
            Expr::ValueCategory::RValue,
            false,
            rel,
        )
    }

    priv fn _rank_literal(self, a: *ArgInfo, pt: unsafe *Type) -> ImplicitRank {
        var unsafe *target = self.tu.strip_nullable(pt)
        match a->lit {
            case LitKind::Int {
                var k = self.tu.kind_of(target)
                if k == BuiltinKind::COUNT {
                    return ImplicitRank::None
                }

                if builtin_info(k)->is_float() { // §5: the literal takes the type.
                    return ImplicitRank::Exact
                }

                var pb = self.tu.builtin(BuiltinKind::USize)->size_bits
                return if (literal_fits_int(
                           a->lit_lo,
                           a->lit_hi,
                           a->lit_big,
                           a->lit_neg,
                           k,
                           pb,
                           a->lit_bits,
                       )) => (ImplicitRank::Exact)
                       else => ImplicitRank::None
            } case LitKind::Float {
                return if (self.tu.is_float(target)) => (ImplicitRank::Exact)
                       else => ImplicitRank::None
            } case LitKind::Null {
                return if (self.tu.nullable_inner(pt) != &null) => (ImplicitRank::Exact)
                       else => ImplicitRank::None
            } case LitKind::NullPtr {
                // `&null` is C++'s `nullptr`: it IS a `std::nullptr_t` (identity),
                // and only converts to a pointer ([conv.ptr]). Ranked apart so
                // `It(std::nullptr_t)` beats `It(int *)` as it does in clang
                // instead of tying it.
                if self.tu.is_nullptr_t(target) {
                    return ImplicitRank::Exact
                }

                // A raw function pointer holds the null address too (a C
                // callback parameter takes `&null`).
                var unsafe *fpt = canon_unqual(target)
                if fpt != &null
                    && isa<FunctionPointerType>(fpt)
                    && cast<FunctionPointerType>(fpt)->is_raw {
                    return ImplicitRank::Converted
                }

                return if (self.tu.pointee(target) != &null) => (ImplicitRank::Converted)
                       else => ImplicitRank::None
            } case LitKind::List {
                return self._rank_list(a, pt)
            } case LitKind::Range {
                return self._rank_range(a, pt)
            } case LitKind::Variant {
                // `.V` TAKES the parameter's enum when it has a variant of
                // that name (§5, as a literal takes its type); it converts to
                // nothing else.
                var unsafe *et = self._variant_enum(target)
                if et == &null {
                    return ImplicitRank::None
                }

                var unsafe *en = cast<EnumDecl>(
                    self.tu.pattern_of(self.tu.record_decl(et)),
                )

                for var i: usize = 0; i < en->variants.size(); ++i {
                    var unsafe *v = en->variants[i]
                    if v != &null && self.tu.decl_name(unsafe (v as unsafe *Decl)) == a->lit_name {
                        return ImplicitRank::Exact
                    }
                }

                return ImplicitRank::None
            } default {
                return ImplicitRank::None
            }
        }
    }

    /// The enum a `.V` argument takes from parameter type `pt`, or null
    /// when `pt` is not one. A reference is read through to its referee and
    /// a nullable to its inner type. Ranking and the ambiguity hint both ask,
    /// and must agree on which enum a parameter offers.
    priv fn _variant_enum(self, pt: unsafe *Type) -> unsafe *Type {
        if pt == &null {
            return &null
        }

        var unsafe *t = pt
        if isa<CXXLValueRefType>(t) {
            t = cast<CXXLValueRefType>(t)->referee
        } else if isa<CXXRValueRefType>(t) {
            t = cast<CXXRValueRefType>(t)->referee
        }

        t = canon_unqual(self.tu.strip_nullable(canon_unqual(t)))
        if t == &null {
            return &null
        }

        var unsafe *rd = self.tu.record_decl(t)
        if rd == &null {
            return &null
        }

        if dyn_cast<EnumDecl>(self.tu.pattern_of(rd)) == &null {
            return &null
        }

        return t
    }

    /// A list literal TAKES its parameter's type (§5), so nothing is converted;
    /// the rank says which target it took. `[T; N]` with N == count is the
    /// literal's own type and ranks as the worst element does. Slice and Vector
    /// are Converted, and unordered against each other: with only those two
    /// overloads the call is ambiguous, as in C++.
    priv fn _rank_list(self, a: *ArgInfo, pt: unsafe *Type) -> ImplicitRank {
        var unsafe *target = canon_unqual(self.tu.strip_nullable(pt))
        if target == &null {
            return ImplicitRank::None
        }

        var is_array = false
        if isa<FixedArrayType>(target) {
            var unsafe *at = cast<FixedArrayType>(target)
            if at->is_incomplete || at->size_bits != a->elems_n {
                return ImplicitRank::None
            }

            is_array = true
        } else if !self.tu.is_slice(target) && !self.tu.is_vector_like(target) {
            return ImplicitRank::None
        }

        var unsafe *elem = self.tu.container_elem(target)
        if elem == &null {
            return ImplicitRank::None
        }

        var worst = ImplicitRank::Exact
        for var i: usize = 0; i < a->elems_n; ++i {
            var *el = &self.list_shapes[a->elems_lo + i]
            var r   = self._rank_elem(el, elem)
            if r == ImplicitRank::None {
                return ImplicitRank::None
            }

            if r == ImplicitRank::Converted {
                worst = ImplicitRank::Converted
            }
        }

        if !is_array {
            return ImplicitRank::Converted
        }

        return worst
    }

    /// The lang record a range literal of form `form` builds.
    priv fn _range_record(self, form: u32) -> WellKnownType {
        if (form & RANGE_HAS_END) == 0 {
            return WellKnownType::RangeFrom
        }

        if (form & RANGE_HAS_BEGIN) == 0 {
            return WellKnownType::RangeTo
        }

        return WellKnownType::Range
    }

    /// A range literal TAKES its parameter's range type (§5) when that is
    /// the record of its form over an integer every bound fits; it converts
    /// to nothing else.
    priv fn _rank_range(self, a: *ArgInfo, pt: unsafe *Type) -> ImplicitRank {
        var unsafe *target = canon_unqual(self.tu.strip_nullable(pt))
        if target == &null || !self.tu.is_lang(target, self._range_record(a->lit_bits)) {
            return ImplicitRank::None
        }

        var args = self.tu.record_args(target)
        if args.size() != 1 || args[0] == &null || !self.tu.is_integer(args[0]) {
            return ImplicitRank::None
        }

        for var i: usize = 0; i < a->elems_n; ++i {
            var *el = &self.list_shapes[a->elems_lo + i]
            if self._rank_elem(el, args[0]) != ImplicitRank::Exact {
                return ImplicitRank::None
            }
        }

        return ImplicitRank::Exact
    }

    /// The type a range literal has where nothing asks for one: its record
    /// over the join of its bounds' own defaults, `usize` for `..`.
    priv fn _range_default(self, a: *ArgInfo) -> unsafe *Type {
        var e: unsafe *Type = &null
        for var i: usize = 0; i < a->elems_n; ++i {
            var *el = &self.list_shapes[a->elems_lo + i]
            var sub = ArgInfo()
            sub.lit      = el->lit
            sub.lit_lo   = el->lit_lo
            sub.lit_hi   = el->lit_hi
            sub.lit_big  = el->lit_big
            sub.lit_bits = el->lit_bits
            sub.lit_neg  = el->lit_neg
            var unsafe *t = self._literal_default(&sub, &null)
            if t == &null {
                return &null
            }

            e = self.conv->join(e, t)
            if e == &null {
                return &null
            }
        }

        if e == &null {
            e = self.tu.builtin(BuiltinKind::USize)
        }

        var ra = cxx::std::vector<unsafe *Type>()
        ra.push_back(e)
        return self.tu.lang_record(self._range_record(a->lit_bits), unsafe &ra)
    }

    /// One element against the container's element type. A nested list is
    /// ranked through its own range; everything else is its literal shape or
    /// its type.
    priv fn _rank_elem(self, el: *ListShape, elem: unsafe *Type) -> ImplicitRank {
        if el->lit == LitKind::List {
            var sub = ArgInfo()
            sub.lit      = LitKind::List
            sub.elems_lo = el->kids_lo
            sub.elems_n  = el->kids_n
            return self._rank_list(&sub, elem)
        }

        if el->lit == LitKind::Range {
            var sub = ArgInfo()
            sub.lit      = LitKind::Range
            sub.lit_bits = el->lit_bits
            sub.elems_lo = el->kids_lo
            sub.elems_n  = el->kids_n
            return self._rank_range(&sub, elem)
        }

        if el->lit != LitKind::None {
            var sub = ArgInfo()
            sub.lit      = el->lit
            sub.lit_lo   = el->lit_lo
            sub.lit_hi   = el->lit_hi
            sub.lit_big  = el->lit_big
            sub.lit_bits = el->lit_bits
            sub.lit_neg  = el->lit_neg
            sub.lit_name = el->lit_name.copy()
            return self._rank_literal(&sub, elem)
        }

        if el->ty != &null {
            return self.conv->implicit(el->ty, elem)
        }

        return ImplicitRank::None
    }

    /// `pt` is the (dependent) parameter the default will be unified against;
    /// only a list reads it, to choose which container its default is.
    priv fn _literal_default(self, a: *ArgInfo, pt: unsafe *Type) -> unsafe *Type {
        match a->lit {
            case LitKind::Int {
                var pb = self.tu.builtin(BuiltinKind::USize)->size_bits
                if literal_fits_int(
                    a->lit_lo,
                    a->lit_hi,
                    a->lit_big,
                    a->lit_neg,
                    BuiltinKind::I32,
                    pb,
                    a->lit_bits,
                ) {
                    return self.tu.builtin(BuiltinKind::I32)
                }

                if literal_fits_int(
                    a->lit_lo,
                    a->lit_hi,
                    a->lit_big,
                    a->lit_neg,
                    BuiltinKind::I64,
                    pb,
                    a->lit_bits,
                ) {
                    return self.tu.builtin(BuiltinKind::I64)
                }

                if literal_fits_int(
                    a->lit_lo,
                    a->lit_hi,
                    a->lit_big,
                    a->lit_neg,
                    BuiltinKind::U64,
                    pb,
                    a->lit_bits,
                ) {
                    return self.tu.builtin(BuiltinKind::U64)
                }

                if literal_fits_int(
                    a->lit_lo,
                    a->lit_hi,
                    a->lit_big,
                    a->lit_neg,
                    BuiltinKind::I128,
                    pb,
                    a->lit_bits,
                ) {
                    return self.tu.builtin(BuiltinKind::I128)
                }

                return self.tu.builtin(BuiltinKind::U128)
            } case LitKind::Float {
                return self.tu.builtin(BuiltinKind::F64)
            }

            // `&null` deduces `std::nullptr_t` as C++'s `nullptr` does: a
            // forwarding `Args&&` then forwards a nullptr, which the callee
            // converts to whatever pointer it takes.
            case LitKind::NullPtr {
                return self.tu.nullptr_t_type()
            } case LitKind::List {
                return self._list_default(a->elems_lo, a->elems_n, pt)
            } case LitKind::Range {
                return self._range_default(a)
            }

            // `.V` has no type of its own to deduce a `T` from.
            case LitKind::Variant {
                return &null
            } default {
                return &null
            }
        }
    }

    /// The type a list literal takes when its parameter is dependent: the
    /// join of its elements' own defaults, in whichever container `pt` asks
    /// for (an array when it asks for nothing).
    priv fn _list_default(self, lo: usize, n: usize, pt: unsafe *Type) -> unsafe *Type {
        var unsafe *target = canon_unqual(self.tu.strip_nullable(pt))
        var ept: unsafe *Type = if (target != &null) => (self.tu.container_elem(
                                    target,
                                ))
                                else => &null
        var e: unsafe *Type = &null
        for var i: usize = 0; i < n; ++i {
            var *el              = &self.list_shapes[lo + i]
            var t:  unsafe *Type = &null
            if el->lit == LitKind::List {
                t = self._list_default(el->kids_lo, el->kids_n, ept)
            } else if el->lit == LitKind::Range {
                var sub = ArgInfo()
                sub.lit      = LitKind::Range
                sub.lit_bits = el->lit_bits
                sub.elems_lo = el->kids_lo
                sub.elems_n  = el->kids_n
                t            = self._range_default(&sub)
            } else if el->lit != LitKind::None {
                var sub = ArgInfo()
                sub.lit      = el->lit
                sub.lit_lo   = el->lit_lo
                sub.lit_hi   = el->lit_hi
                sub.lit_big  = el->lit_big
                sub.lit_bits = el->lit_bits
                sub.lit_neg  = el->lit_neg
                sub.lit_name = el->lit_name.copy()
                t            = self._literal_default(&sub, ept)
            } else {
                t = el->ty
            }

            if t == &null {
                return &null
            }

            var unsafe *j = self.conv->join(e, t)
            if j == &null {
                return &null
            }

            e = j
        }

        if e == &null {
            return &null
        }

        if target != &null && self.tu.is_vector_like(target) {
            return self.tu.vector_of(e)
        }

        if target != &null && self.tu.is_slice(target) {
            return self.tu.slice_of(e)
        }

        return self.sc->types->array(e, n as u64)
    }

    /// # diagnostics

    /// `from` points at u8 or i8 (or byte) and `to` at C's `char`.
    /// A string literal at a C string parameter of an imported function:
    /// its static, NUL-terminated bytes are the `const char *`
    /// already, so it converts without a `string` being made (CallTyping
    /// marks it, StringLowering passes the bytes). Exact, as C++ ranks it: a
    /// generic overload then loses the tie. Imported callees
    /// only -- a Kairo function's `*const u8` parameter keeps its own
    /// rules -- and never `@inout`, which needs a place.
    priv fn _c_string_literal_arg(self,
                                  f:    unsafe *FunctionDecl,
                                  a:    *ArgInfo,
                                  pt:   unsafe *Type,
                                  mode: ParamMode) -> bool {
        if f == &null || !f->is_imported() || mode == ParamMode::Inout || a->marked {
            return false
        }

        if self.tu.c_string_literal(a->expr) == &null {
            return false
        }

        return self.tu.is_c_string_param(pt)
    }

    /// `a` is a string literal at an imported template's forwarding
    /// reference `pt` (`T&&`, toml++'s `value_or(T&& default)`): T is a C
    /// string, never builtin::string, which no C++ template expects (the
    /// rule for `T`). C++ itself deduces `const char(&)[N]`,
    /// which Kairo cannot spell; the decayed pointer is what every such
    /// template also takes. Also true for `pt` already substituted to
    /// `const char*&&`.
    priv fn _forwards_cstr(self, f: unsafe *FunctionDecl, a: *ArgInfo, pt: unsafe *Type) -> bool {
        if f == &null || (!f->is_imported()) || a->marked || pt == &null {
            return false
        }

        if self.tu.c_string_literal(a->expr) == &null {
            return false
        }

        var unsafe *u = canon_unqual(pt)
        // spdlog's `debug(const T& msg)`: C++ deduces T as the array, and the
        // decayed pointer is as good to every such template; a Kairo string
        // there would be a builtin::string no formatter knows.
        if u != &null && isa<CXXLValueRefType>(u) {
            var unsafe *lr = cast<CXXLValueRefType>(u)->referee
            return lr != &null
                && isa<GenericParamType>(canon_unqual(lr))
                && canon_quals(lr) == QUAL_CONST
        }

        if u == &null || (!isa<CXXRValueRefType>(u)) {
            return false
        }

        var unsafe *rr = cast<CXXRValueRefType>(u)->referee
        if isa<GenericParamType>(rr) && canon_quals(rr) == 0 {
            return true
        }

        return self.tu.is_c_string_param(canon_unqual(rr))
    }

    /// The type a by-value parameter of an imported template deduces from
    /// `a`. To C++ a string literal is `const char[N]`, which a by-value
    /// `T` deduces as `const char *` ([temp.deduct.call]/2): deduced from
    /// the Kairo `string` instead, `template<class T> f(T)` was instantiated
    /// on builtin::string, which no C++ template expects. CallTyping
    /// then sees the substituted `const char *` slot and passes the bytes,
    /// as for a written C string parameter. A reference parameter is left
    /// alone: C++ deduces the ARRAY there, which Kairo cannot spell.
    priv fn _foreign_deduce_arg(self,
                                c:  unsafe *Candidate,
                                a:  *ArgInfo,
                                pt: unsafe *Type) -> unsafe *Type {
        if c->f == &null || (!c->f->is_imported()) || a->marked {
            return a->ty
        }

        if self._forwards_cstr(c->f, a, pt) {
            return self.tu.c_string_ptr_type()
        }

        var unsafe *u = canon_unqual(pt)
        if u == &null || isa<CXXLValueRefType>(u) || isa<CXXRValueRefType>(u) {
            return a->ty
        }

        if self.tu.c_string_literal(a->expr) == &null {
            return a->ty
        }

        return self.tu.c_string_ptr_type()
    }

    /// `t` is an associated type of a type parameter (`J::Item`), under
    /// nullables, pointers and qualifiers: a type no argument deduces.
    priv fn _reads_assoc(self, t: unsafe *Type) -> bool {
        var unsafe *u = if (t != &null) => (canon_unqual(t)) else => &null
        while u != &null {
            if isa<AssocType>(u) {
                return u->is_dependent()
            }

            if isa<NullableType>(u) {
                u = canon_unqual(cast<NullableType>(u)->inner)
            } else if isa<PointerType>(u) {
                u = canon_unqual(cast<PointerType>(u)->pointee)
            } else {
                return false
            }
        }

        return false
    }

    /// The imported record a C++ user-defined conversion would build for
    /// parameter `pt` of the imported callee `f`, or null: `pt` by
    /// value, `const T&` or `T&&` (a temporary binds neither `T&` nor a
    /// Kairo `@inout`), T a C++ class.
    priv fn _cxx_conv_target(self,
                             f:  unsafe *FunctionDecl,
                             a:  *ArgInfo,
                             pt: unsafe *Type) -> unsafe *Type {
        if f == &null || (!f->is_imported()) || a->marked || pt == &null || pt->is_dependent() {
            return &null
        }

        var unsafe *t = pt
        if isa<CXXLValueRefType>(t) {
            t = cast<CXXLValueRefType>(t)->referee
            if !canon_has_const(t) {
                return &null
            }
        } else if isa<CXXRValueRefType>(t) {
            t = cast<CXXRValueRefType>(t)->referee
        }

        t = canon_unqual(t)
        if t == &null || (!isa<RecordType>(t)) {
            return &null
        }

        if !self._is_cxx_record(t) {
            return &null
        }

        return t
    }

    /// `t` names a C++ class: imported, or an instance of an imported
    /// template (`std::string` is a registry shell of basic_string, which
    /// is not itself marked imported).
    priv fn _is_cxx_record(self, t: unsafe *Type) -> bool {
        var unsafe *d = self.tu.record_decl(t)
        if d == &null {
            return false
        }

        return decl_is_imported(d) || decl_is_imported(self.tu.pattern_of(d))
    }

    /// How C++ would reach the record `to` from `a` with ONE
    /// user-defined conversion -- `'View(const char *)'` or `'operator B'`
    /// -- or "" when it would not. A standard conversion may precede a
    /// converting constructor ([over.ics.user]), never a second user one,
    /// so the constructor's parameter is judged on the builtin lattice; a
    /// string literal is C++'s `const char[N]`, which a C string parameter
    /// takes.
    priv fn _cxx_conv_via(self, f: unsafe *FunctionDecl, a: *ArgInfo, to: unsafe *Type) -> string {
        var unsafe *from = if (a->ty != &null) => (self.tu.as_value(a->ty)) else => &null
        var lit = self.tu.c_string_literal(a->expr) != &null
        if from != &null && (!lit) {
            var unsafe *cop = self.conv->cxx_conversion_op(from, to)
            if cop != &null {
                return f"'operator {self.tu.str(to)}\x27"
            }
        }

        if from == &null && (!lit) {
            return ""
        }

        var hand = self._cxx_ctor_by_hand(a, from, lit, to)
        if hand != "" {
            return hand
        }

        // What the hand search cannot see -- a constructor template, a
        // defaulted trailing parameter, a consteval or lazily declared
        // constructor -- clang answers. Only for what C++ itself
        // sees at the boundary: a string literal (`const char[N]`, decayed)
        // or a C++ class value. A Kairo `string` VALUE stays out: the docs
        // give it `.c_str()`, so no implicit route into C++ (c-cpp.mdx).
        if self.sc->foreign == &null {
            return ""
        }

        var src:   unsafe *Type = &null
        var cat                 = a->cat
        var lit_n: u64          = 0
        if lit {
            src = self.tu.c_string_ptr_type()
            cat = Expr::ValueCategory::RValue
            lit_n = LowerSynth(self.sc).c_literal_extent(
                self.tu.c_string_literal(a->expr),
            )
        } else {
            var unsafe *fu = canon_unqual(from)
            if fu == &null || (!isa<RecordType>(fu)) {
                return ""
            }

            if !self._is_cxx_record(fu) {
                return ""
            }

            src = from
            if a->is_const && cat != Expr::ValueCategory::RValue {
                src = self.sc->types->qualified(canon_unqual(from), QUAL_CONST)
            }
        }

        if self.sc->foreign->cxx_converts(f, src, cat, to, lit_n) {
            return f"'{self.tu.str(to)}({self.tu.str(src)})\x27"
        }

        return ""
    }

    /// _cxx_conv_via's own search: a non-template constructor of exactly one
    /// parameter, judged on the builtin lattice. Kept ahead of clang: it
    /// needs no header set, so it also answers where none is reachable.
    priv fn _cxx_ctor_by_hand(self,
                              a:    *ArgInfo,
                              from: unsafe *Type,
                              lit:  bool,
                              to:   unsafe *Type) -> string {
        var unsafe *body = self.sc->body_of(self.tu.record_decl(to))
        var unsafe *dc   = NameLookup::context_of(body)
        if dc == &null {
            return ""
        }

        var cell = self.sc->lookup.in_context(dc, DeclName::ctor())
        if !cell.found() {
            return ""
        }

        for var i: usize = 0; i < cell.cell->size(); ++i {
            var unsafe *k = dyn_cast<FunctionDecl>(cell.cell->get(i))
            if k == &null
                || k->is_poisoned()
                || k->ffi_explicit
                || k->transfer != TransferKind::NotTransfer {
                continue
            }

            var nreal: usize             = 0
            var only:  unsafe *ParamDecl = &null
            for var j: usize = 0; j < k->params.size(); ++j {
                if k->params[j] != &null && (!k->params[j]->is_self) {
                    nreal += 1
                    only = k->params[j]
                }
            }

            if nreal != 1 || only->type_ == &null || only->type_->canonical == &null {
                continue
            }

            var unsafe *qt = only->type_->canonical
            var        ok  = false
            if lit {
                ok = self.tu.is_c_string_param(qt)
            } else {
                var unsafe *qv = qt
                if isa<CXXLValueRefType>(qv) {
                    qv = cast<CXXLValueRefType>(qv)->referee
                } else if isa<CXXRValueRefType>(qv) {
                    qv = cast<CXXRValueRefType>(qv)->referee
                }

                ok = self.conv->implicit_builtin(
                    canon_unqual(from),
                    canon_unqual(qv),
                ) != ImplicitRank::None
            }

            if ok {
                return f"'{self.tu.str(to)}({self.tu.str(qt)})\x27"
            }
        }

        return ""
    }

    /// `e` binds looser than a postfix `as`, so a cast appended to it
    /// needs parentheses around it.
    priv fn _needs_parens_for_as(self, e: unsafe *Expr) -> bool {
        if e == &null {
            return false
        }

        return isa<BinaryOperatorExpr>(e) || isa<AssignOperatorExpr>(e) || isa<RangeExpr>(e)
    }

    /// A `fn` value (`a`: a closure or a variable of `fn` type) offered to
    /// a raw `unsafe fn` parameter `pt`: the conversion that never holds,
    /// since the value may capture.
    priv fn _raw_fn_from_capturing(self, a: *ArgInfo, pt: unsafe *Type) -> bool {
        if a->ty == &null || pt == &null || a->ty->canonical == &null || pt->canonical == &null {
            return false
        }

        var unsafe *from = canon_unqual(a->ty->canonical)
        var unsafe *to   = canon_unqual(pt->canonical)
        if !isa<FunctionPointerType>(from) || !isa<FunctionPointerType>(to) {
            return false
        }

        return cast<FunctionPointerType>(to)->is_raw && !cast<FunctionPointerType>(from)->is_raw
    }

    priv fn _c_string_reinterpret(self, from: unsafe *Type, to: unsafe *Type) -> bool {
        if from == &null || to == &null {
            return false
        }

        var unsafe *fp = self.tu.pointee(canon_unqual(from))
        var unsafe *tp = self.tu.pointee(canon_unqual(to))
        if fp == &null || tp == &null {
            return false
        }

        if !self.tu.is_builtin(canon_unqual(tp), BuiltinKind::CChar) {
            return false
        }

        var fk = self.tu.kind_of(canon_unqual(fp))
        return fk == BuiltinKind::U8 || fk == BuiltinKind::I8 || fk == BuiltinKind::Byte
    }

    /// The borrowing binder (BinderBorrow) a failed call changes: the
    /// object of a method a candidate refused for its constness, an
    /// argument such a candidate refused, or an address `&x` of one.
    priv fn _borrowed_in_call(self,
                              cs:    unsafe *[Candidate],
                              margs: unsafe *[ArgInfo],
                              fargs: unsafe *[ArgInfo]) -> unsafe *VariableDecl {
        var const_reject = false
        for var i: usize = 0; i < cs->size(); ++i {
            if (*cs)[i].const_reject {
                const_reject = true
            }
        }

        if const_reject && self.call_callee != &null {
            var unsafe *cb = borrowed_binder_of(self.call_callee)
            if cb != &null {
                return cb
            }
        }

        var lists: [unsafe *[ArgInfo]]
        lists.push(margs)
        lists.push(fargs)
        for var l: usize = 0; l < lists.size(); ++l {
            var unsafe *as_ = lists[l]
            if as_ == &null {
                continue
            }

            for var i: usize = 0; i < as_->size(); ++i {
                var unsafe *e = (*as_)[i].expr
                if e == &null {
                    continue
                }

                var unsafe *x = self.tu.strip_parens(e)
                var addr = x != &null
                    && isa<UnaryOperatorExpr>(x)
                    && cast<UnaryOperatorExpr>(x)->op_token.kind == TokenKind::OpAmp
                if addr || const_reject {
                    var unsafe *ab = borrowed_binder_of(e)
                    if ab != &null {
                        return ab
                    }
                }
            }
        }

        return &null
    }

    priv fn _report_no_viable(self,
                              cs:         unsafe *[Candidate],
                              at:         SourceRange,
                              const name: string,
                              margs:      unsafe *[ArgInfo] = &null,
                              fargs:      unsafe *[ArgInfo] = &null) {
        var unsafe *bb = self._borrowed_in_call(cs, margs, fargs)
        // One candidate: the rule that rejected it IS the error, named at the
        // call. "no matching overload" plus a single note says the same thing
        // twice and buries the part the user can act on.
        if cs->size() == 1 {
            var *only = &(*cs)[0]
            if only->reason_code != DiagID::SC001E {
                var sb = self.sc->diag->report(
                    only->reason_code,
                    at.start,
                    only->reason.copy(),
                )

                sb.first(at)
                sb.note(only->f->range.start, declared_here())->child_first(
                    only->f->range,
                )

                if bb != &null {
                    note_borrowed_binder(self.sc, &sb, bb)
                }

                sb.emit()
                return
            }
        }

        var b = self.sc->diag->report(
            DiagID::SC063E,
            at.start,
            f"no matching overload for call to '{name}'",
        )

        b.first(at)
        // C++ would have converted an argument implicitly. One target
        // record: the note names how, and `as` is the edit. Several (each
        // overload reachable by its own conversion): the note lists them and
        // no edit is offered, since which one is meant is the user's call.
        var utargets: [string]
        var ufirst:   usize    = usize::MAX
        for var i: usize = 0; i < cs->size(); ++i {
            var *c = &(*cs)[i]
            if c->uconv_to == "" {
                continue
            }

            var dup = false
            for var j: usize = 0; j < utargets.size(); ++j {
                if utargets[j] == c->uconv_to {
                    dup = true
                    break
                }
            }

            if !dup {
                utargets.push(c->uconv_to.copy())
            }

            if ufirst == usize::MAX {
                ufirst = i
            }
        }

        var shown: usize = 0
        var fixed        = utargets.size() > 1
        for var i: usize = 0; i < cs->size() && shown < 6; ++i {
            var *c = &(*cs)[i]
            b.note(c->f->range.start, f"candidate not viable: {c->reason}")->child_first(
                c->f->range,
            )

            // One edit per call: two candidates' casts cannot both apply.
            if !fixed && c->fix_text != "" {
                var why = if (c->fix_text == ".c_str()") => ("pass the string's NUL-terminated bytes")
                          else => "reinterpret the pointer inside an 'unsafe' block"
                if c->uconv_to != "" {
                    why = "convert explicitly"
                }

                if c->fix_paren {
                    b.insert(c->fix_open, "(", why)
                }

                b.insert(c->fix_at, c->fix_text, why)
                fixed = true
            }

            shown += 1
        }

        if utargets.size() == 1 {
            var to  = utargets[0].copy()
            var via = (*cs)[ufirst].uconv_via.copy()
            b.note(
                (*cs)[ufirst].fix_open,
                f"C++ would convert the argument to '{to}' implicitly through {via}; Kairo applies no C++ implicit conversion unless -fcxx-implicit-conv is given: write 'as {to}', or pass -fcxx-implicit-conv",
            )
        } else if utargets.size() > 1 {
            var list = ""
            for var j: usize = 0; j < utargets.size(); ++j {
                if j > 0 {
                    list += ", "
                }

                list += "\x27" + utargets[j] + "\x27"
            }

            b.note(
                at.start,
                f"C++ would convert the argument implicitly to one of {list}; Kairo applies no C++ implicit conversion unless -fcxx-implicit-conv is given: write the cast to the one you mean, or pass -fcxx-implicit-conv",
            )
        }

        if cs->size() > shown {
            b.note(at.start, f"and {cs->size() - shown} more candidate(s)")
        }

        if bb != &null {
            note_borrowed_binder(self.sc, &b, bb)
        }

        b.emit()
    }

    /// The hint for a tie a `.V` argument caused, or "" when none did. A
    /// `.V` takes whichever enum its parameter offers, so there is nothing to
    /// cast: the fix is to name the enum. Only when the winners' enums for
    /// that argument DIFFER -- with `place(Shape, i32)` beside
    /// `place(Shape, i64)`, `Shape::Empty` decides nothing, the tie is in
    /// another argument, and the cast hint is the right one.
    priv fn _variant_spellings(self,
                               const cs:      [Candidate],
                               const winners: [usize],
                               margs:         unsafe *[ArgInfo],
                               fargs:         unsafe *[ArgInfo]) -> string {
        // A member and a free winner index different argument lists, so the
        // `.V` is found per winner and matched across them by its node,
        // never by index.
        var        *first = &(cs)[(((winners)[0]))]
        var unsafe *args0 = if (first->free) => (fargs) else => margs
        if args0 == &null {
            return ""
        }

        for var k: usize = 0; k < args0->size(); ++k {
            var *a = &(*args0)[k]
            if a->lit != LitKind::Variant {
                continue
            }

            var names: [string]
            for var i: usize = 0; i < winners.size(); ++i {
                var        *c                 = &(cs)[(((winners)[i]))]
                var unsafe *args              = if (c->free) => (fargs) else => margs
                var        et:   unsafe *Type = &null
                for var j: usize = 0; args != &null && j < args->size(); ++j {
                    var *aj = &(*args)[j]
                    if aj->lit != LitKind::Variant || aj->expr != a->expr {
                        continue
                    }

                    if j < c->judged.size() {
                        et = self._variant_enum(c->judged[j].target)
                    }

                    break
                }

                if et == &null {
                    continue
                }

                var n   = self.tu.str(et)
                var dup = false
                for var m: usize = 0; m < names.size(); ++m {
                    if names[m] == n {
                        dup = true
                        break
                    }
                }

                if !dup {
                    names.push(n)
                }
            }

            if names.size() < 2 {
                continue
            }

            var joined = ""
            for var m: usize = 0; m < names.size(); ++m {
                if m > 0 {
                    joined = joined + (if (m + 1 == names.size()) => (" or ") else => ", ")
                }

                joined = joined + names[m] + "::" + a->lit_name
            }

            return f"'.{a->lit_name}' is a variant of more than one candidate's enum; write the enum name: {joined}"
        }

        return ""
    }

    /// `margs` / `fargs` are the argument lists the winners were judged
    /// against, chosen per winner by Candidate::free as in _ref_tiebreak.
    /// SC320E for a tie among `winners` when at least one has a clause
    /// conjunct that tests an open parameter (a parameter of the generic
    /// whose body makes the call) and its bounds leave undecided
    /// (ConformanceChecking::open_conjuncts). A generic body is checked
    /// against its bounds (generics.mdx), so the instance does not choose:
    /// each candidate gets a note saying which bound selects it, or that no
    /// bound can (a negated conformance, a value predicate). False, with
    /// nothing reported, when no winner's clause is open.
    priv fn _report_open_tie(self,
                             cs:         unsafe *[Candidate],
                             winners:    *[usize],
                             at:         SourceRange,
                             const name: string) -> bool {
        var cc = ConformanceChecking(self.sc)
        var opens: [cxx::std::vector<unsafe *Expr>]
        var any                                     = false
        for var i: usize = 0; i < winners->size(); ++i {
            var *c = &(*cs)[(*winners)[i]]
            var os = cxx::std::vector<unsafe *Expr>()
            if c->generic && c->f != &null && !c->f->is_imported() {
                cc.open_conjuncts(c->f, unsafe &c->ded, unsafe &os)
            }

            if os.size() > 0 {
                any = true
            }

            opens.push(os)
        }

        if !any {
            return false
        }

        var b = self.sc->diag->report(
            DiagID::SC320E,
            at.start,
            f"call to '{name}' cannot be resolved in this generic body: its candidates' 'requires' clauses test a type parameter whose bounds do not decide them",
        )

        b.first(at)
        for var i: usize = 0; i < winners->size() && i < 6; ++i {
            var *c    = &(*cs)[(*winners)[i]]
            var yes   = ""
            var bnds  = ""
            var no    = ""
            var other = false
            var hid   = false
            for var k: usize = 0; k < opens[i].size(); ++k {
                var bound = ""
                var t = cc.open_conjunct_text(
                    opens[i][k],
                    unsafe &c->ded,
                    unsafe &bound,
                    unsafe &hid,
                )

                if t.size() == 0 {
                    other = true
                } else if bound.size() == 0 {
                    no += if (no.size() == 0) => (t) else => " and " + t
                } else {
                    yes += if (yes.size() == 0) => (t) else => " and " + t
                    bnds += if (bnds.size() == 0) => (bound) else => ", " + bound
                }
            }

            var msg = ""
            if opens[i].size() == 0 {
                msg = "this candidate's clause does not test the parameter; it is chosen only where the others' clauses are known false, which no bound can promise"
            } else if no.size() == 0 && !other {
                msg = f"this candidate is selected when {yes}: add the bound '{bnds}'"
                if hid {
                    msg += ", though the interface is not public, so this file cannot name it"
                }
            } else if no.size() > 0 {
                msg = "no bound selects this candidate: it applies when "
                if yes.size() > 0 {
                    msg += yes.copy() + " and "
                }

                msg += no.copy() + ", and no bound can promise that " + no
            } else {
                msg = "no bound selects this candidate: its clause tests the parameter with a condition no bound can promise"
            }

            b.note(DiagCode(DiagID::SC320N), c->f->range.start, msg)->child_first(
                c->f->range,
            )
        }

        b.note(
            at.start,
            "a generic body is checked against its bounds, not per instance, so the bounds must decide every candidate's clause",
        )

        b.emit()
        return true
    }

    priv fn _report_ambiguous(self,
                              cs:         unsafe *[Candidate],
                              winners:    unsafe *[usize],
                              margs:      unsafe *[ArgInfo],
                              fargs:      unsafe *[ArgInfo],
                              at:         SourceRange,
                              const name: string) {
        var b = self.sc->diag->report(
            DiagID::SC064E,
            at.start,
            f"call to '{name}' is ambiguous: more than one candidate matches at the same rank",
        )

        b.first(at)
        for var i: usize = 0; i < winners->size() && i < 6; ++i {
            var *c = &(*cs)[(((*winners)[i]))]
            b.note(c->f->range.start, "candidate declared here")->child_first(
                c->f->range,
            )
        }

        var spelled = self._variant_spellings(*cs, *winners, margs, fargs)
        if spelled.size() > 0 {
            b.note(at.start, spelled)
        } else {
            b.note(
                at.start,
                "conversions are not ordered within a rank; cast one argument to make the choice explicit",
            )
        }

        b.emit()
    }
}
