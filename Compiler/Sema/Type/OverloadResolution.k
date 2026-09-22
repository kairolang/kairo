/// --- The Kairo Project ---------------- Sema/Type/OverloadResolution.k --- ///
///
///   \brief Pick one function from a candidate set for a call, given the
///          argument types. A component; ExprTyper calls it, nothing else.
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
///     ranks. Two ranks, no ordering inside rank 2. Two tiebreaks among the
///     best-ranked, in C++'s order, and neither is a conversion ordering:
///
///       reference kind  on an argument where both bound a C++ reference at
///                       Exact, an rvalue prefers `T&&` to `const T&` and a
///                       non-const lvalue prefers `T&` to `const T&`
///                       (_ref_better). Needs the argument's VALUE CATEGORY,
///                       which ExprTyper assigns and ArgInfo carries.
///       generic         a non-generic candidate beats a generic one,
///                       otherwise `fn f(i32)` next to `fn <T> f(T)` is
///                       ambiguous on every call.
///
///     Everything else that ties is ambiguous and errors, even when one
///     conversion looks "narrower".
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
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

import Sema::SemaContext::*;
import Sema::Resolve::NameLookup::*;
import Sema::Type::TypeUtil::*;
import Sema::Type::Conversion::*;
import Sema::Type::ArgumentDeduction::*;
import Diagnostic::Registry::*;
import AST::ASTSupport::*;
import AST::Node::Base::*;
import AST::Node::Types::*;
import AST::Node::CanonicalNodes::*;
import AST::Node::Declarations::*;
import AST::Node::Casting::*;
import Location::SourceRange::*;
import Diagnostic::Registry::*;
import AST::ParamMode::*;

/// \enum LitKind
/// \brief An argument that is an untyped literal carries its shape so the
///        resolver can rank it without a type.
enum LitKind derives u8 {
    None = 0,
    Int,      ///< lo/hi/big/negative meaningful.
    Float,    ///< fits any float.
    Null,     ///< `null`: fits any nullable.
    NullPtr,  ///< `&null`: fits any pointer or nullable pointer.
    List,     ///< `[...]`: ranked by shape through ArgInfo::elems.
}

/// One element of a list literal, ranked by SHAPE. Flat on purpose: ArgInfo
/// is a value passed and copied everywhere, and a container of ArgInfo inside
/// ArgInfo is a type that contains itself -- its copies do not survive, and
/// what breaks is every OTHER field, silently, on calls that have no list
/// literal in them at all. Children live in the same pool, named by index.
class ListShape {
    pub var lit:     LitKind = LitKind::None;
    pub var lit_lo:  u64  = 0;
    pub var lit_hi:  u64  = 0;
    pub var lit_big: bool = false;
    pub var lit_neg: bool = false;
    pub var ty:      *Type = &null;   ///< set when the element is not an untyped literal.
    pub var kids_lo: usize = 0;       ///< a nested list literal's own elements.
    pub var kids_n:  usize = 0;
    fn ListShape(self) { }
}

class ArgInfo {
    pub var expr:       *Expr = &null;
    /// The node as it sits in `CallExpr::args`. Differs from `expr` only for
    /// a named argument, where the parser wraps the value (see
    /// CallTyping::arg_info); everything but the dump wants `expr`.
    pub var carrier:    *Expr = &null;
    pub var ty:         *Type = &null;      ///< canonical, null for an untyped literal / unknown.
    pub var range:      SourceRange;
    pub var name:       string = "";        ///< named argument spelling; "" for positional.
    pub var name_range: SourceRange;
    pub var lit:        LitKind = LitKind::None;
    pub var lit_lo:     u64  = 0;
    pub var lit_hi:     u64  = 0;
    pub var lit_big:    bool = false;
    pub var lit_neg:    bool = false;
    /// LitKind::List only: the element shapes, as a range in
    /// OverloadResolution::list_shapes. Written by
    /// LiteralTyping::list_literal_shape.
    pub var elems_lo:   usize = 0;
    pub var elems_n:    usize = 0;
    pub var dependent:  bool = false;       ///< type unknowable here; poisons nothing.
    /// The argument's value category (a literal is a prvalue), and for an
    /// lvalue whether it is const. Only reference parameters read them:
    /// they decide which of `T&` / `const T&` / `T&&` the argument binds.
    pub var cat:        Expr::ValueCategory = Expr::ValueCategory::RValue;
    pub var is_const:   bool = false;
    /// The `&` MARKER (AST/ParamMode.k). `marked` when the argument as
    /// written is `&e`. `expr` is the whole `&e`, typed as the address-of it
    /// may still turn out to be (against `x: *T` that is what it means);
    /// `inner_*` are the OPERAND's view, which is what an `@inout` parameter
    /// is judged against. Only the `@inout` path reads `inner_*`; every
    /// other parameter reads `ty` / `cat` / `is_const` and sees address-of.
    pub var marked:      bool  = false;
    pub var inner_ty:    *Type = &null;
    pub var inner_cat:   Expr::ValueCategory = Expr::ValueCategory::RValue;
    pub var inner_const: bool  = false;
    fn ArgInfo(self) { }
}

enum OvlOutcome derives u8 {
    Selected = 0,
    Ambiguous,
    NoViable,
    Dependent,   ///< an argument is dependent: decide at M2, no diagnostic.
    Empty,       ///< nothing callable under that name.
}

class Candidate {
    pub var f:            *FunctionDecl = &null;
    pub var viable:       bool  = true;
    pub var rank:         u8    = 0;        ///< 0 Exact, 1 Converted.
    pub var generic:      bool  = false;
    pub var free:         bool  = false;    ///< from resolve_mixed's free list: judged with no receiver.
    pub var reason:       string = "";
    /// Which placement rule rejected this candidate, or SC001E for anything
    /// else. `_report_no_viable` promotes it to the real diagnostic when there
    /// is exactly ONE candidate; with an overload set the specific rule is a
    /// property of one candidate, not of the call, so it stays a note.
    pub var reason_code:  DiagID = DiagID::SC001E;
    /// per arg: param index, usize(-1) for the Kairo pack tail, usize(-2) for
    /// a C `...` tail (no parameter at all; finish_call_args finds none and
    /// types a literal there with its default, which is C's promotion).
    pub var arg_to_param: vec::<usize>;
    /// per arg: the reference kind it bound AT EXACT -- 0 none (a value
    /// parameter, or not Exact), 1 `const T&`, 2 `T&&`, 3 `T&`. Read only by
    /// the reference tiebreak.
    pub var binds:        vec::<u8>;
    /// The implicit object parameter, judged like one more reference
    /// argument: 1 `const self`, 3 plain `self`, 0 not judged (no receiver
    /// object known). recv_const is the OBJECT's constness.
    pub var recv_bind:    u8   = 0;
    pub var recv_const:   bool = false;
    /// Arguments that reached an `@inout` parameter WITHOUT the marker.
    /// Viable (migration tolerance); CallTyping warns after selection. The
    /// two are parallel: arg index, the parameter it landed on.
    pub var inout_unmarked: vec::<usize>;
    pub var inout_params:   vec::<*ParamDecl>;
    pub var ded:          Deduction;
    fn Candidate(self) { }
}

class OvlResult {
    pub var outcome:      OvlOutcome = OvlOutcome::Empty;
    pub var decl:         *FunctionDecl = &null;
    pub var arg_to_param: vec::<usize>;
    pub var via_free:     bool = false;     ///< winner came from the free list: arg_to_param indexes fargs.
    /// The receiver was bound to the winner's `self`, which then matched no
    /// argument: arg_to_param indexes the params AFTER `self`.
    /// finish_call_args reads this rather than guessing.
    pub var receiver_bound: bool = false;
    pub var ded:          Deduction;
    /// The type the call was made THROUGH, stripped of nullable and pointer:
    /// `obj.m(x)`'s `obj`. Filled by the caller after resolution, alongside
    /// `ded.bind_from_record`, because it answers a question deduction cannot:
    /// an interface member's `Self` is the receiver, and through a bound
    /// `T impl I` the receiver is `T` rather than any record. Null when the
    /// call had no receiver.
    pub var receiver:     *Type = &null;
    /// Copied off the winner; see Candidate.
    pub var inout_unmarked: vec::<usize>;
    pub var inout_params:   vec::<*ParamDecl>;
    fn OvlResult(self) { }
}

class OverloadResolution {
    pub var sc:   *SemaContext;
    pub var conv: *Conversion;
    pub var tu:   TypeUtil;

    /// Every list literal's element shapes, for this TU. Append-only, and
    /// indices into it are stable for exactly that reason: an ArgInfo names
    /// its elements by range, so nothing has to hold a container of itself.
    pub var list_shapes: vec::<ListShape>;

    fn OverloadResolution(self) { self.sc = &null; self.conv = &null; }
    fn OverloadResolution(self, sc: *SemaContext, conv: *Conversion) {
        self.sc   = sc;
        self.conv = conv;
        self.tu   = TypeUtil(sc);
    }

    /// \param cands   the decls under the name; non-functions are skipped
    ///                (a mixed cell was N(a)'s error already).
    /// \param has_receiver  `obj.m(...)`: the `self` param is bound to the
    ///                receiver and not matched against args. `Type::m(obj)`
    ///                passes false and `self` is an ordinary first param.
    /// \param receiver  the type `obj` has, already stripped of nullable and
    ///                pointer. Not a duplicate of has_receiver: an interface
    ///                member's `Self` IS this type, and viability has to see
    ///                that -- `fn merge(self, other: Self)` reached through a
    ///                `T impl Drawable` takes a T, so ranking the argument
    ///                against `Drawable` would reject a correct call. Null
    ///                when there is no receiver, or when the caller has none
    ///                to offer.
    fn resolve(self, cands: *vec::<*Decl>, args: *vec::<ArgInfo>, has_receiver: bool,
               at: SourceRange, name: string, receiver: *Type = &null) -> OvlResult {
        return self.resolve_mixed(cands, args, has_receiver, &null, &null, at, name, receiver);
    }

    /// One overload set drawn from two argument shapes. \p members are judged
    /// against \p margs exactly as resolve() judges them; \p frees (free
    /// functions -- an ADL-found `fn op +(a: A, b: B)`) against \p fargs,
    /// where the receiver operand is an ordinary first argument. Everything
    /// ranks in ONE candidate list: which list a candidate came from is not a
    /// tiebreak, so a member and a free function at the same rank are an
    /// ordinary ambiguity (the C++ rule for operators). The winner's
    /// arg_to_param indexes \p fargs iff OvlResult::via_free. \p frees and
    /// \p fargs may be null.
    fn resolve_mixed(self, members: *vec::<*Decl>, margs: *vec::<ArgInfo>, has_receiver: bool,
                     frees: *vec::<*Decl>, fargs: *vec::<ArgInfo>,
                     at: SourceRange, name: string, receiver: *Type = &null) -> OvlResult {
        var out = OvlResult{};
        // \p receiver carries the OBJECT's cv (a const object's method call
        // ranks on it, _judge_receiver); everything downstream of the
        // result wants the type the call was made through, unqualified.
        out.receiver = canon_unqual(receiver);

        if self._any_dependent(margs) || self._any_dependent(fargs) {
            out.outcome = OvlOutcome::Dependent;
            return out;
        }

        var cs = vec::<Candidate>();
        self._collect(&cs, members, margs, has_receiver, receiver, false);
        if fargs != &null { self._collect(&cs, frees, fargs, false, &null, true); }

        if cs.size() == 0 {
            self.sc->diag->report(DiagID::SC001E, at.start,
                f"'{name}' is not callable"
            ).first(at).emit();
            out.outcome = OvlOutcome::Empty;
            return out;
        }

        // best rank among viable
        var best: u8 = 255;
        for var i: usize = 0; i < cs.size(); ++i {
            if cs[i].viable && (cs[i].rank < best) { best = cs[i].rank; }
        }
        if best == 255 {
            self._report_no_viable(&cs, at, name);
            out.outcome = OvlOutcome::NoViable;
            return out;
        }

        var winners = vec::<usize>();
        for var i: usize = 0; i < cs.size(); ++i {
            if cs[i].viable && (cs[i].rank == best) { winners.push_back(i); }
        }
        // Reference kind, BEFORE the generic tiebreak for the reason C++
        // orders them so ([over.match.best]: better conversion sequences
        // first, templates after): see _ref_better.
        if winners.size() > 1 { winners = self._ref_tiebreak(&cs, &winners, margs, fargs); }
        // non-generic beats generic.
        if winners.size() > 1 {
            var nongen = vec::<usize>();
            for var i: usize = 0; i < winners.size(); ++i {
                if !cs[winners[i]].generic { nongen.push_back(winners[i]); }
            }
            if nongen.size() > 0 { winners = nongen; }
        }

        if winners.size() > 1 {
            self._report_ambiguous(&cs, &winners, at, name);
            out.outcome = OvlOutcome::Ambiguous;
            return out;
        }

        var w = &(cs[winners[0]]);
        out.outcome      = OvlOutcome::Selected;
        out.decl         = w->f;
        out.arg_to_param = w->arg_to_param;
        out.via_free     = w->free;
        out.receiver_bound = has_receiver && (!w->free);
        out.ded          = w->ded;
        out.inout_unmarked = w->inout_unmarked;
        out.inout_params   = w->inout_params;
        return out;
    }

    /// The winners no other winner beats on reference kind.
    priv fn _ref_tiebreak(self, cs: *vec::<Candidate>, winners: *vec::<usize>,
                          margs: *vec::<ArgInfo>, fargs: *vec::<ArgInfo>) -> vec::<usize> {
        var keep = vec::<usize>();
        for var i: usize = 0; i < winners->size(); ++i {
            var ci = &((*cs)[(*winners)[i]]);
            var beaten = false;
            for var j: usize = 0; j < winners->size(); ++j {
                if i == j { continue; }
                var cj = &((*cs)[(*winners)[j]]);
                var args = (fargs) if (cj->free) else (margs);
                if self._ref_better(cj, ci, args) { beaten = true; break; }
            }
            if !beaten { keep.push_back((*winners)[i]); }
        }
        if keep.size() == 0 { return *winners; }       // a strict order never beats everyone; defensive.
        return keep;
    }

    /// \p x beats \p y on reference kind: on no argument does \p y bind
    /// better, on at least one \p x does. The only "better" there is, and it
    /// applies only where BOTH bound at Exact ([over.ics.rank]/3.2.3, 3.2.6
    /// reduced): an rvalue argument prefers `T&&` to `const T&`, a non-const
    /// lvalue prefers `T&` to `const T&`. Nothing else is ordered: every
    /// other tie stays a tie, and ambiguity is still reported for it.
    ///
    /// Candidates from different argument lists (a member judged against the
    /// operands minus the receiver, a free function against all of them)
    /// are not position-aligned, so they never beat each other here.
    priv fn _ref_better(self, x: *Candidate, y: *Candidate, args: *vec::<ArgInfo>) -> bool {
        if x->free != y->free { return false; }
        if (args == &null) || (x->binds.size() != args->size()) || (y->binds.size() != args->size()) { return false; }
        var better = false;
        // The implicit object parameter, when both judged it: a non-const
        // object prefers `self` to `const self` exactly as a non-const
        // lvalue prefers `T&` to `const T&` -- data() over data() const. The
        // object counts as an lvalue even when it is a temporary
        // ([over.match.funcs]/5).
        if (x->recv_bind != 0) && (y->recv_bind != 0) {
            var ra = ArgInfo{};
            ra.cat      = Expr::ValueCategory::LValue;
            ra.is_const = x->recv_const;
            if self._ref_prefers(&ra, x->recv_bind, y->recv_bind) { better = true; }
            else if self._ref_prefers(&ra, y->recv_bind, x->recv_bind) { return false; }
        }
        for var k: usize = 0; k < args->size(); ++k {
            var a = &((*args)[k]);
            if self._ref_prefers(a, x->binds[k], y->binds[k]) { better = true; continue; }
            if self._ref_prefers(a, y->binds[k], x->binds[k]) { return false; }
        }
        return better;
    }

    priv fn _ref_prefers(self, a: *ArgInfo, bx: u8, by: u8) -> bool {
        if by != 1 { return false; }                      // only ever over `const T&`.
        var rvalue = (a->cat == Expr::ValueCategory::RValue) || (a->cat == Expr::ValueCategory::XValue);
        if (bx == 2) && rvalue { return true; }
        if (bx == 3) && (a->cat == Expr::ValueCategory::LValue) && (!a->is_const) { return true; }
        return false;
    }

    /// The Candidate::binds code for a parameter of type \p pt.
    priv fn _bind_kind(self, pt: *Type) -> u8 {
        if pt == &null { return 0; }
        if isa::<CXXRValueRefType>(pt) { return 2; }
        if isa::<CXXLValueRefType>(pt) { return (1) if (canon_has_const(cast::<CXXLValueRefType>(pt)->referee)) else (3); }
        return 0;
    }

    priv fn _any_dependent(self, args: *vec::<ArgInfo>) -> bool {
        if args == &null { return false; }
        for var i: usize = 0; i < args->size(); ++i {
            if (*args)[i].dependent { return true; }
        }
        return false;
    }

    /// Judge every function in \p cands against \p args and append it to
    /// \p cs, skipping one \p cs already holds (fwd + def are one entity,
    /// RedeclMerge; and a decl reached as both member and ADL free is one).
    priv fn _collect(self, cs: *vec::<Candidate>, cands: *vec::<*Decl>, args: *vec::<ArgInfo>,
                     has_receiver: bool, receiver: *Type, free: bool) {
        if cands == &null { return; }
        for var i: usize = 0; i < cands->size(); ++i {
            var f = dyn_cast::<FunctionDecl>((*cands)[i]);
            if f == &null { continue; }
            if f->is_poisoned() { continue; }
            if NameLookup::is_specialization(static_cast::<*Decl>(f)) { continue; }   // OverloadResolution pairs later.
            var seen = false;
            for var j: usize = 0; j < cs->size(); ++j {
                if NameLookup::representative(static_cast::<*Decl>((*cs)[j].f))
                == NameLookup::representative(static_cast::<*Decl>(f)) { seen = true; break; }
            }
            if seen { continue; }
            var c = Candidate{};
            c.f       = f;
            c.free    = free;
            c.generic = f->generic_params.size() > 0;
            c.ded     = Deduction(self.sc, self.conv);
            self._judge(&c, args, has_receiver, receiver);
            cs->push_back(c);
        }
    }

    // === one candidate ======================================================

    /// The implicit object parameter ([over.match.funcs]/4): the receiver
    /// OBJECT against `self`, whose canonical carries the method's cv -- a
    /// const method's self is `const Record` (TypeResolve's
    /// _synthesize_receiver, and DeclImport through `this`). It binds as a
    /// reference would: a const object cannot bind a plain `self`, and
    /// either object binds `const self`. \p receiver's own cv is the
    /// object's; null means no object is known, and nothing is judged.
    priv fn _judge_receiver(self, c: *Candidate, p: *ParamDecl, receiver: *Type) {
        if (receiver == &null) || (p->type_ == &null) || (p->type_->canonical == &null) { return; }
        var sq = canon_quals(p->type_->canonical);
        var oq = canon_quals(receiver);
        if (oq & (~sq)) != 0 {
            c->viable = false;
            c->reason = f"'{self.tu.decl_name(static_cast::<*Decl>(c->f))}' is not const; it cannot be called on a const object";
            return;
        }
        c->recv_bind  = (1) if ((sq & QUAL_CONST()) != 0) else (3);
        c->recv_const = (oq & QUAL_CONST()) != 0;
    }

    priv fn _judge(self, c: *Candidate, args: *vec::<ArgInfo>, has_receiver: bool,
                   receiver: *Type) {
        var f = c->f;

        // parameter slots, skipping the receiver when it is bound elsewhere.
        var params = vec::<*ParamDecl>();
        for var i: usize = 0; i < f->params.size(); ++i {
            var p = f->params[i];
            if p == &null { continue; }
            if p->is_self && has_receiver {
                self._judge_receiver(c, p, receiver);
                if !c->viable { return; }
                continue;
            }
            params.push_back(p);
        }
        var nparams = params.size();
        // The pack is wherever it is MARKED, not the last slot: a keyword-only
        // tail sits after it, and treating the last parameter as the pack gave
        // every one of those arguments to the wrong place.
        var pack_at = usize(-1);
        for var i: usize = 0; i < nparams; ++i {
            if params[i]->is_pack { pack_at = i; break; }
        }

        var filled = vec::<bool>();
        for var i: usize = 0; i < nparams; ++i { filled.push_back(false); }
        for var i: usize = 0; i < args->size(); ++i { c->arg_to_param.push_back(usize(-1)); c->binds.push_back(0); }

        // 1. NAMED first, then positional. Placement has to know which slots a
        //    name already claimed before it decides where the positionals
        //    stop, and reading the list once in source order cannot: a name
        //    may appear before the positional it affects.
        for var i: usize = 0; i < args->size(); ++i {
            var a = &((*args)[i]);
            if a->name.size() == 0 { continue; }
            var found = usize(-1);
            for var j: usize = 0; j < nparams; ++j {
                if self.tu.param_name(params[j]) == a->name { found = j; break; }
            }
            if found == usize(-1) {
                c->viable = false;
                c->reason_code = DiagID::SC019E;
                c->reason = f"no parameter named '{a->name}\x27";
                return;
            }
            if filled[found] {
                c->viable = false;
                c->reason_code = DiagID::SC020E;
                c->reason = f"parameter '{a->name}' was already given";
                return;
            }
            filled[found] = true;
            c->arg_to_param[i] = found;
        }

        // 2. positional, left to right over the slots no name claimed.
        //    pack_lo/pack_hi/pack_n describe the pack's RUN in `args`, which
        //    CallExpr::arg_map records as a first index plus a length.
        var pos: usize = 0;
        var pack_lo: usize = usize(-1);
        var pack_hi: usize = usize(-1);
        var pack_n:  usize = 0;
        for var i: usize = 0; i < args->size(); ++i {
            var a = &((*args)[i]);
            if a->name.size() > 0 { continue; }
            if (pack_at != usize(-1)) && (pos >= pack_at) {
                // This argument joins the pack. If it cannot, the useful
                // reading is usually not "bad pack element" but "you meant a
                // keyword-only parameter and wrote it positionally" -- there
                // is no argument count at which a positional reaches one, so
                // without this the user gets a conversion error naming the
                // pack and no hint that the parameter they wanted exists.
                var kw = self._keyword_only_meant(c, a, &params, pack_at, nparams, receiver);
                if kw != usize(-1) {
                    c->viable = false;
                    c->reason_code = DiagID::SC018E;
                    c->reason = f"parameter '{self.tu.param_name(params[kw])}' can only be given by name; it follows a pack, so this argument joins the pack instead";
                    return;
                }
                if pack_lo == usize(-1) { pack_lo = i; }
                pack_hi = i;
                pack_n += 1;
                c->arg_to_param[i] = usize(-1);   // pack tail
                filled[pack_at] = true;
                continue;
            }
            while (pos < nparams) && filled[pos] { pos += 1; }
            if pos >= nparams {
                // C `...`: a positional argument past the declared ones has
                // no parameter to judge it against; C's default promotions
                // are the callee's contract, not a Kairo conversion.
                if f->ffi_c_variadic { c->arg_to_param[i] = usize(-2); continue; }
                c->viable = false;
                c->reason = f"expects {nparams} argument(s), {args->size()} given";
                return;
            }
            filled[pos] = true;
            c->arg_to_param[i] = pos;
            pos += 1;
        }

        // 2a. the pack must be one unbroken run. arg_map describes it as a
        //     first index plus a length, so a named argument spliced into the
        //     middle would put a non-member inside that run and CallLowering
        //     would reorder it as a pack element.
        if (pack_n > 0) && ((pack_hi - pack_lo + 1) != pack_n) {
            c->viable = false;
            c->reason_code = DiagID::SC022E;
            c->reason = "a named argument cannot appear between two pack arguments; move it after them";
            return;
        }

        // 3. missing parameters need defaults. A parameter WITHOUT a default is
        //    allowed to follow one with a default, so an unfilled slot here is
        //    never implied by the slots around it.
        for var j: usize = 0; j < nparams; ++j {
            if filled[j] { continue; }
            if j == pack_at { continue; }
            if (params[j]->default_val != &null) || params[j]->has_default { continue; }
            var pn = self.tu.param_name(params[j]);
            c->reason_code = DiagID::SC021E;
            c->viable = false;
            c->reason = f"missing argument for parameter '{pn}\x27";
            return;
        }

        // 3. rank every placed argument.
        for var i: usize = 0; i < args->size(); ++i {
            var a  = &((*args)[i]);
            var pi = c->arg_to_param[i];
            if pi == usize(-2) {                     // C `...` tail: Converted, unchecked.
                if c->rank < 1 { c->rank = 1; }
                continue;
            }
            var p: *ParamDecl = (params[pi]) if (pi != usize(-1)) else (params[pack_at]);
            var pt: *Type = &null;
            if p->type_ != &null { pt = p->type_->canonical; }
            // Top-level cv on a parameter is not part of the call
            // ([dcl.fct]/5): `f(const i32)` takes an i32. The receiver is
            // exempt -- its `const` is `const Foo*`, one level down.
            if (pt != &null) && (!p->is_self) { pt = canon_unqual(pt); }
            if (p->type_ != &null) && p->type_->is_poisoned() { c->viable = false; c->reason = "parameter type is invalid"; return; }
            pt = c->ded.through_receiver(c->f, canon_unqual(receiver), pt);   // `other: Self` is `other: <receiver>`.

            if pt == &null {
                // dependent-but-uncanonical parameter (`[T; N]`, alias app):
                // cannot decide here; accept at Converted and let M2 judge.
                if (p->type_ != &null) && (p->type_->is_dependent() || p->type_->is_instantiation_dependent()) {
                    if c->rank < 1 { c->rank = 1; }
                    continue;
                }
                c->viable = false; c->reason = "parameter type is unresolved"; return;
            }

            // The parameter's mode. A pack tail ranks by value; the receiver
            // never reaches here (bound above, and it takes no mode).
            var mode = (ParamMode::Value) if (pi == usize(-1)) else (p->mode);

            var r = self._rank_arg(c, a, pt, pi == usize(-1), mode);
            if r == ImplicitRank::None {
                var pn = self.tu.param_name(p);
                var got = (self.tu.str(a->ty)) if (a->ty != &null) else ("<literal>");
                if mode == ParamMode::Inout {
                    var iv = (self.tu.str(a->inner_ty)) if (a->marked && (a->inner_ty != &null)) else (got);
                    c->viable = false;
                    c->reason = f"parameter '{pn}' is '@inout' and needs a mutable lvalue of type '{self.tu.str(pt)}'; got '{iv}\x27";
                    return;
                }
                c->viable = false;
                c->reason = f"cannot convert argument of type '{got}' to parameter '{pn}' of type '{self.tu.str(pt)}\x27";
                return;
            }
            // An unmarked argument reaching `@inout` is TOLERATED (CallTyping
            // warns), never preferred: it ranks as a conversion. At Exact it
            // tied `f(x: T)` and `f(a)` was ambiguous; now the by-value
            // overload wins `f(a)` and `f(&a)` still picks `@inout`.
            if (mode == ParamMode::Inout) && (!a->marked) && (r == ImplicitRank::Exact) {
                r = ImplicitRank::Converted;
            }
            if (r == ImplicitRank::Converted) && (c->rank < 1) { c->rank = 1; }
            // An `@inout` binding IS a `T&` binding for the reference tiebreak.
            if r == ImplicitRank::Exact { c->binds[i] = (3) if (mode == ParamMode::Inout) else (self._bind_kind(pt)); }
            if (mode == ParamMode::Inout) && (!a->marked) {
                c->inout_unmarked.push_back(i);
                c->inout_params.push_back(p);
            }
        }

        // 4. a generic candidate must have deduced every param.
        if c->generic && (!c->ded.is_complete(static_cast::<*Decl>(f))) {
            c->viable = false;
            c->reason = "could not deduce every generic parameter from the arguments";
            return;
        }
    }

    /// The keyword-only parameter \p a was probably meant for, or usize(-1).
    ///
    /// Only asked when the argument does NOT fit the pack, so the answer is
    /// "there is a parameter this would have fitted, and it is unreachable
    /// positionally". Dependent parameters are skipped on both sides: ranking
    /// one unifies into `c->ded`, and this is a speculative probe that must
    /// leave the candidate exactly as it found it.
    priv fn _keyword_only_meant(self, c: *Candidate, a: *ArgInfo, params: *vec::<*ParamDecl>,
                                pack_at: usize, nparams: usize, receiver: *Type) -> usize {
        var pack_ty = self._param_target(c, params, pack_at, receiver);
        if (pack_ty == &null) || pack_ty->is_dependent() { return usize(-1); }
        if self._rank_arg(c, a, pack_ty, true, ParamMode::Value) != ImplicitRank::None { return usize(-1); }

        for var j: usize = 0; j < nparams; ++j {
            if !(*params)[j]->keyword_only { continue; }
            var kt = self._param_target(c, params, j, receiver);
            if (kt == &null) || kt->is_dependent() { continue; }
            if self._rank_arg(c, a, kt, false, (*params)[j]->mode) != ImplicitRank::None { return j; }
        }
        return usize(-1);
    }

    /// The parameter's canonical target type as the ranking loop derives it:
    /// top-level cv dropped, `Self` resolved through the receiver.
    priv fn _param_target(self, c: *Candidate, params: *vec::<*ParamDecl>, j: usize, receiver: *Type) -> *Type {
        var p = (*params)[j];
        if p->type_ == &null { return &null; }
        var pt = p->type_->canonical;
        if pt == &null { return &null; }
        if !p->is_self { pt = canon_unqual(pt); }
        return c->ded.through_receiver(c->f, canon_unqual(receiver), pt);
    }

    /// \p mode is the parameter's passing mode. `@inout` is judged exactly as
    /// a C++ `T&` parameter is (Conversion::ref_binding, [over.ics.ref]): a
    /// mutable lvalue of T binds Exact, a derived object Converted, a
    /// temporary never. `@move` ranks by VALUE: `f(x)` moves, the call site
    /// writes nothing, and MoveCheck owns what follows. No new ranking rule
    /// lives here; modes restate the reference rules in Kairo terms.
    priv fn _rank_arg(self, c: *Candidate, a: *ArgInfo, pt: *Type, is_pack: bool, mode: ParamMode) -> ImplicitRank {
        if mode == ParamMode::Inout {
            // The operand's view when marked; the argument itself otherwise
            // (viable; CallTyping warns). A literal is a prvalue and can never
            // be borrowed mutably.
            var ty  = a->ty;
            var cat = a->cat;
            var cst = a->is_const;
            if a->marked { ty = a->inner_ty; cat = a->inner_cat; cst = a->inner_const; }
            if (!a->marked) && (a->lit != LitKind::None) { return ImplicitRank::None; }
            if ty == &null { return ImplicitRank::None; }
            if pt->is_dependent() {
                // `fn <T> f(@inout x: T)`: T deduces from the operand's view,
                // then binds as a plain `T&` -- a const lvalue does not bind.
                var d = c->ded.unify(pt, ty, true);
                if d == ImplicitRank::None { return ImplicitRank::None; }
                var lref = self.sc->types->cxx_lref(canon_unqual(ty));
                return self.conv->ref_binding(lref, cat, cst, RefRel::Same);
            }
            var lref = self.sc->types->cxx_lref(pt);
            return self.conv->implicit_arg(ty, lref, cat, cst);
        }

        // Pack element: the param's canonical is the pack's generic param
        // (VariadicPackType shares it). Bind nothing -- a pack is one slot
        // with many types, and the registry does not model that yet -- accept.
        if is_pack {
            if pt->is_dependent() { return ImplicitRank::Converted; }
            if a->lit != LitKind::None { return self._rank_literal_arg(a, pt); }
            return self.conv->implicit_arg(a->ty, pt, a->cat, a->is_const);
        }

        if a->lit != LitKind::None {
            if pt->is_dependent() {
                // `fn <T> f(x: T)` with `f(10)`: T := the literal's default.
                var def = self._literal_default(a, pt);
                if def == &null { return ImplicitRank::None; }
                var ur = c->ded.unify(pt, def, true);
                // A list literal reaching a slice or vector is never Exact.
                if (ur != ImplicitRank::None) && (a->lit == LitKind::List)
                && (!isa::<FixedArrayType>(canon_unqual(def))) { return ImplicitRank::Converted; }
                return ur;
            }
            return self._rank_literal_arg(a, pt);
        }

        if a->ty == &null { return ImplicitRank::None; }
        if pt->is_dependent() { return c->ded.unify(pt, a->ty, true); }
        return self.conv->implicit_arg(a->ty, pt, a->cat, a->is_const);
    }

    /// A literal is a PRVALUE of whatever type it takes. Against a reference
    /// parameter that makes it the referee exactly (Same) when it takes that
    /// type (§5), a temporary (Converts) when it only fits by conversion, and
    /// Conversion::ref_binding decides from there -- the literal has no
    /// reference rule of its own.
    priv fn _rank_literal_arg(self, a: *ArgInfo, pt: *Type) -> ImplicitRank {
        var referee: *Type = &null;
        if isa::<CXXLValueRefType>(pt) { referee = cast::<CXXLValueRefType>(pt)->referee; }
        if isa::<CXXRValueRefType>(pt) { referee = cast::<CXXRValueRefType>(pt)->referee; }
        if referee == &null { return self._rank_literal(a, pt); }
        var vr  = self._rank_literal(a, canon_unqual(referee));
        var rel = (RefRel::Same) if (vr == ImplicitRank::Exact)
                  else (RefRel::Converts) if (vr == ImplicitRank::Converted) else (RefRel::None);
        return self.conv->ref_binding(pt, Expr::ValueCategory::RValue, false, rel);
    }

    priv fn _rank_literal(self, a: *ArgInfo, pt: *Type) -> ImplicitRank {
        var target = self.tu.strip_nullable(pt);
        switch a->lit {
            case LitKind::Int {
                var k = self.tu.kind_of(target);
                if k == BuiltinKind::COUNT { return ImplicitRank::None; }
                if builtin_info(k)->is_float() { return ImplicitRank::Exact; }   // §5: the literal takes the type.
                var pb = self.tu.builtin(BuiltinKind::USize)->size_bits;
                return (ImplicitRank::Exact)
                       if (literal_fits_int(a->lit_lo, a->lit_hi, a->lit_big, a->lit_neg, k, pb))
                       else (ImplicitRank::None);
            }
            case LitKind::Float {
                return (ImplicitRank::Exact) if (self.tu.is_float(target)) else (ImplicitRank::None);
            }
            case LitKind::Null {
                return (ImplicitRank::Exact) if (self.tu.nullable_inner(pt) != &null) else (ImplicitRank::None);
            }
            case LitKind::NullPtr {
                return (ImplicitRank::Exact) if (self.tu.pointee(target) != &null) else (ImplicitRank::None);
            }
            case LitKind::List { return self._rank_list(a, pt); }
            default { return ImplicitRank::None; }
        }
    }

    /// A list literal TAKES its parameter's type (§5), so nothing is converted;
    /// the rank says which target it took. `[T; N]` with N == count is the
    /// literal's own type and ranks as the worst element does. Slice and Vector
    /// are Converted, and unordered against each other: with only those two
    /// overloads the call is ambiguous, as in C++.
    priv fn _rank_list(self, a: *ArgInfo, pt: *Type) -> ImplicitRank {
        var target = canon_unqual(self.tu.strip_nullable(pt));
        if target == &null { return ImplicitRank::None; }

        var is_array = false;
        if isa::<FixedArrayType>(target) {
            var at = cast::<FixedArrayType>(target);
            if at->is_incomplete || (static_cast::<usize>(at->size_bits) != a->elems_n) { return ImplicitRank::None; }
            is_array = true;
        } else if (!self.tu.is_slice(target)) && (!self.tu.is_vector_like(target)) {
            return ImplicitRank::None;
        }
        var elem = self.tu.container_elem(target);
        if elem == &null { return ImplicitRank::None; }

        var worst = ImplicitRank::Exact;
        for var i: usize = 0; i < a->elems_n; ++i {
            var el = &(self.list_shapes[a->elems_lo + i]);
            var r  = self._rank_elem(el, elem);
            if r == ImplicitRank::None { return ImplicitRank::None; }
            if r == ImplicitRank::Converted { worst = ImplicitRank::Converted; }
        }
        if !is_array { return ImplicitRank::Converted; }
        return worst;
    }

    /// One element against the container's element type. A nested list is
    /// ranked through its own range; everything else is its literal shape or
    /// its type.
    priv fn _rank_elem(self, el: *ListShape, elem: *Type) -> ImplicitRank {
        if el->lit == LitKind::List {
            var sub = ArgInfo{};
            sub.lit      = LitKind::List;
            sub.elems_lo = el->kids_lo;
            sub.elems_n  = el->kids_n;
            return self._rank_list(&sub, elem);
        }
        if el->lit != LitKind::None {
            var sub = ArgInfo{};
            sub.lit     = el->lit;
            sub.lit_lo  = el->lit_lo;
            sub.lit_hi  = el->lit_hi;
            sub.lit_big = el->lit_big;
            sub.lit_neg = el->lit_neg;
            return self._rank_literal(&sub, elem);
        }
        if el->ty != &null { return self.conv->implicit(el->ty, elem); }
        return ImplicitRank::None;
    }

    /// \p pt is the (dependent) parameter the default will be unified against;
    /// only a list reads it, to choose which container its default is.
    priv fn _literal_default(self, a: *ArgInfo, pt: *Type) -> *Type {
        switch a->lit {
            case LitKind::Int {
                var pb = self.tu.builtin(BuiltinKind::USize)->size_bits;
                if literal_fits_int(a->lit_lo, a->lit_hi, a->lit_big, a->lit_neg, BuiltinKind::I32, pb) { return self.tu.builtin(BuiltinKind::I32); }
                if literal_fits_int(a->lit_lo, a->lit_hi, a->lit_big, a->lit_neg, BuiltinKind::I64, pb) { return self.tu.builtin(BuiltinKind::I64); }
                if literal_fits_int(a->lit_lo, a->lit_hi, a->lit_big, a->lit_neg, BuiltinKind::U64, pb) { return self.tu.builtin(BuiltinKind::U64); }
                if literal_fits_int(a->lit_lo, a->lit_hi, a->lit_big, a->lit_neg, BuiltinKind::I128, pb) { return self.tu.builtin(BuiltinKind::I128); }
                return self.tu.builtin(BuiltinKind::U128);
            }
            case LitKind::Float { return self.tu.builtin(BuiltinKind::F64); }
            case LitKind::List { return self._list_default(a->elems_lo, a->elems_n, pt); }
            default { return &null; }
        }
    }

    /// The type a list literal takes when its parameter is dependent: the
    /// join of its elements' own defaults, in whichever container \p pt asks
    /// for (an array when it asks for nothing).
    priv fn _list_default(self, lo: usize, n: usize, pt: *Type) -> *Type {
        var target = canon_unqual(self.tu.strip_nullable(pt));
        var ept: *Type = (self.tu.container_elem(target)) if (target != &null) else (&null);
        var e: *Type = &null;
        for var i: usize = 0; i < n; ++i {
            var el = &(self.list_shapes[lo + i]);
            var t: *Type = &null;
            if el->lit == LitKind::List { t = self._list_default(el->kids_lo, el->kids_n, ept); }
            else if el->lit != LitKind::None {
                var sub = ArgInfo{};
                sub.lit     = el->lit;
                sub.lit_lo  = el->lit_lo;
                sub.lit_hi  = el->lit_hi;
                sub.lit_big = el->lit_big;
                sub.lit_neg = el->lit_neg;
                t = self._literal_default(&sub, ept);
            } else { t = el->ty; }
            if t == &null { return &null; }
            var j = self.conv->join(e, t);
            if j == &null { return &null; }
            e = j;
        }
        if e == &null { return &null; }
        if (target != &null) && self.tu.is_vector_like(target) { return self.tu.vector_of(e); }
        if (target != &null) && self.tu.is_slice(target)       { return self.tu.slice_of(e); }
        return self.sc->types->array(e, static_cast::<u64>(n));
    }

    // === diagnostics ========================================================

    priv fn _report_no_viable(self, cs: *vec::<Candidate>, at: SourceRange, name: string) {
        // One candidate: the rule that rejected it IS the error, named at the
        // call. "no matching overload" plus a single note says the same thing
        // twice and buries the part the user can act on.
        if cs->size() == 1 {
            var only = &((*cs)[0]);
            if only->reason_code != DiagID::SC001E {
                var sb = self.sc->diag->report(only->reason_code, at.start, only->reason);
                sb.first(at);
                sb.note(only->f->range.start, "declared here").first(only->f->range);
                sb.emit();
                return;
            }
        }
        var b = self.sc->diag->report(DiagID::SC001E, at.start,
            f"no matching overload for call to '{name}\x27"
        );
        b.first(at);
        var shown: usize = 0;
        for var i: usize = 0; (i < cs->size()) && (shown < 6); ++i {
            var c = &((*cs)[i]);
            b.note(c->f->range.start, f"candidate not viable: {c->reason}").first(c->f->range);
            shown += 1;
        }
        if cs->size() > shown { b.note(at.start, f"and {cs->size() - shown} more candidate(s)"); }
        b.emit();
    }

    priv fn _report_ambiguous(self, cs: *vec::<Candidate>, winners: *vec::<usize>, at: SourceRange, name: string) {
        var b = self.sc->diag->report(DiagID::SC001E, at.start,
            f"call to '{name}' is ambiguous: more than one candidate matches at the same rank"
        );
        b.first(at);
        for var i: usize = 0; (i < winners->size()) && (i < 6); ++i {
            var c = &((*cs)[(*winners)[i]]);
            b.note(c->f->range.start, "candidate declared here").first(c->f->range);
        }
        b.note(at.start, "conversions are not ordered within a rank; cast one argument to make the choice explicit");
        b.emit();
    }
}