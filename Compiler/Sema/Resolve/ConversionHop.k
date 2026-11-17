/// --- The Kairo Project ------------------ Sema/Resolve/ConversionHop.k --- ///
///
/// A member a type lacks, found on the type one of its `@implicit
/// op as` conversions yields.
///
///   \detail
///       class <T> Buf {
///           @implicit fn op as (const self) -> View<const T>
///           @implicit fn op as (self) -> View<T>
///       }
///       b.windows(2)      ->  (b as View<T>).windows(2)
///
///     Asked only after member lookup on the receiver's own type found
///     nothing: the type's members, its extensions' and its bases' always
///     win. The search is one hop. The name is looked up on each
///     conversion's result with the ordinary member lookup, which converts
///     nothing, so `A -> B -> C` never chains.
///
///     Which conversion:
///       1. Only a conversion whose result has a member of the name, all of
///          them functions, is a candidate. A field is not reached: the
///          conversion yields a temporary, and a place in it is no place
///          in the receiver.
///       2. A const receiver uses a `const self` conversion only.
///       3. A mutable receiver uses a `self` conversion when one is a
///          candidate, else a `const self` one. So `v.sort()` goes through
///          `-> View<T>`, and a read member only `View<const T>` has still
///          resolves.
///       4. Two candidates left in the tier that decides are an ambiguity
///          (R028E), naming both conversions.
///     The choice is by name, before the call's arguments are seen: the
///     overloads are the chosen result's alone.
///
///     A generic extension's `op as` is no candidate when its result names
///     the extension's parameters: what they are is Conversion's to bind,
///     at a site that has a target type to bind them against.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "vector"

import AST::Context::SymbolTable::DeclName
import AST::DeclFacts::decl_extension_of
import AST::Node::Base::{
    Decl,
    Type,
}
import AST::Node::CanonicalNodes::{
    RecordType,
    canon_unqual,
}
import AST::Node::Casting::{
    dyn_cast,
    isa,
}
import AST::Node::Declarations::FunctionDecl
import AST::OperatorFacts::OperatorFacts
import Sema::Resolve::MemberLookup::MemberLookup
import Sema::SemaContext::SemaContext
import Sema::Type::ArgumentDeduction::Deduction
import Token::TokenKind::TokenKind

/// The answer for one receiver type and one member name.
pub class ConversionHop {
    /// The conversion to apply and its result for this receiver; null when
    /// none is a candidate the receiver may use, or when two are (`other`).
    pub var conv:   unsafe *FunctionDecl = &null
    pub var target: unsafe *Type         = &null
    /// The two conversions of an ambiguity, with their results.
    pub var other:        unsafe *FunctionDecl = &null
    pub var other_target: unsafe *Type         = &null
    /// A `self` conversion whose result has the member, which the const
    /// receiver asked about cannot use.
    pub var blocked:        unsafe *FunctionDecl = &null
    pub var blocked_target: unsafe *Type         = &null
    /// Some conversion's result has the member, whatever the receiver's
    /// constness: the question is worth asking again once it is known.
    pub var any: bool = false
    /// The members of the name on `target`, in lookup order.
    pub var members: cxx::std::vector<unsafe *Decl>

    fn ConversionHop(self) { }

    pub fn ambiguous(const self) -> bool {
        return self.other != &null
    }

    /// The `op as` `f` takes a `const self`.
    pub static fn const_self(f: unsafe *FunctionDecl) -> bool {
        return f->is_const() || f->params.size() > 0 && f->params[0]->is_const
    }

    /// Searches the conversions of `ty`, a record's canonical with no cv,
    /// for one whose result has a member `name`. `recv_const` is the
    /// constness of the object the member is read from.
    pub static fn find(sc:         unsafe *SemaContext,
                       ml:         *MemberLookup,
                       ty:         unsafe *Type,
                       recv_const: bool,
                       name:       DeclName) -> ConversionHop {
        var out = ConversionHop()
        if ty == &null || !isa<RecordType>(ty) {
            return out
        }

        var ops = cxx::std::vector<unsafe *Decl>()
        ml->lookup(
            ty,
            DeclName::op_name(TokenKind::KwAs, TokenKind::TkUnknown),
            unsafe &ops,
        )

        var mut_ops   = cxx::std::vector<unsafe *FunctionDecl>()
        var mut_tys   = cxx::std::vector<unsafe *Type>()
        var const_ops = cxx::std::vector<unsafe *FunctionDecl>()
        var const_tys = cxx::std::vector<unsafe *Type>()
        for var i: usize = 0; i < ops.size(); ++i {
            var unsafe *f = dyn_cast<FunctionDecl>(ops[i])
            if f == &null || f->is_poisoned() || !OperatorFacts::is_implicit_conv(f) {
                continue
            }

            var unsafe *to = ConversionHop::_result(sc, f, ty)
            if to == &null || to == ty {
                continue
            }

            var found = cxx::std::vector<unsafe *Decl>()
            if !ml->lookup(to, name, unsafe &found) || !ConversionHop::_all_functions(&found) {
                continue
            }

            out.any = true
            if !ConversionHop::const_self(f) {
                if recv_const {
                    if out.blocked == &null {
                        out.blocked        = f
                        out.blocked_target = to
                    }

                    continue
                }

                mut_ops.push_back(f)
                mut_tys.push_back(to)
            } else {
                const_ops.push_back(f)
                const_tys.push_back(to)
            }
        }

        if mut_ops.size() > 0 {
            out._take(&mut_ops, &mut_tys)
        } else if const_ops.size() > 0 {
            out._take(&const_ops, &const_tys)
        }

        if out.conv != &null && out.other == &null {
            ml->lookup(out.target, name, unsafe &out.members)
        }

        return out
    }

    /// The first of `ops` is the answer; a second makes it an ambiguity.
    priv fn _take(self,
                  ops: *cxx::std::vector<unsafe *FunctionDecl>,
                  tys: *cxx::std::vector<unsafe *Type>) {
        self.conv   = (*ops)[0]
        self.target = (*tys)[0]
        if ops->size() > 1 {
            self.other        = (*ops)[1]
            self.other_target = (*tys)[1]
        }
    }

    /// What `f` yields for a source of type `ty`, cv dropped: a member's
    /// result read through the instance's arguments (`-> View<T>` on a
    /// `Buf<i32>` is `View<i32>`). Null when the result is not known here.
    priv static fn _result(sc: unsafe *SemaContext,
                           f:  unsafe *FunctionDecl,
                           ty: unsafe *Type) -> unsafe *Type {
        if f->return_type == &null || f->return_type->canonical == &null {
            return &null
        }

        var unsafe *rt = canon_unqual(f->return_type->canonical)
        if decl_extension_of(f) != &null {
            return if (rt->is_dependent()) => (&null) else => rt
        }

        var ded = Deduction(sc, &null)
        return canon_unqual(ded.member_through(ty, rt))
    }

    priv static fn _all_functions(ds: *cxx::std::vector<unsafe *Decl>) -> bool {
        for var i: usize = 0; i < ds->size(); ++i {
            if !isa<FunctionDecl>((*ds)[i]) {
                return false
            }
        }

        return ds->size() > 0
    }
}
