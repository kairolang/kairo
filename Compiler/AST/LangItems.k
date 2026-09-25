/// --- The Kairo Project ----------------------------- AST/LangItems.k --- ///
///
///   \brief Names the compiler knows that are not in the user's source.
///          Two kinds, one bucket test:
///
///            could a user declare it in Kairo?
///              yes -> a LANG ITEM: a real decl in the builtins module,
///                     found by lookup, spelled by CXXSpell like any decl.
///              no  -> a LOWER TARGET: a fragment of the C++ name of
///                     something the USER declared (`__kairo_contains` is
///                     the member name of their `op in`), invented here.
///
///   \par Lang items
///     Ordinary decls that arrive through ordinary imports and sit in
///     ordinary tables; sema needs a direct handle for desugaring. Their
///     names are NEVER special-cased in lookup. The primitive value types
///     are not here: `i32` lexes as a keyword token and is a BuiltinType
///     singleton resolved by token kind (CanonicalNodes.k).
///
///     Runtime types and functions a lowering needs (`Optional<T>` for `T?`,
///     `pow` for `^^` on primitives, the panic entry points) are lang items
///     too: declared in builtins, ffi-backed where the body is C++, and the
///     C++ spelling is DERIVED from the declaration. No lowering carries a
///     `::kairo::rt::...` string.
///
///   \par Lower targets
///     Not user-writable: the `__kairo_` prefix is reserved (CxxNameCheck
///     rejects it in user identifiers). One writer per entry, named.
///
///   Layer: AST leaf. Imports Base only; imported by Sema and Codegen.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

import AST::Node::Base::*;

/// \enum WellKnownType
/// \brief The lang items. One row per decl a lowering needs a handle to.
enum WellKnownType derives u8 {
    Future = 0, ///< spawn foo() desugar type: Future<T>.
    Range,      ///< 1..2 | 1..=2 desugar type: Range(a, b, t/f).
    Yield,      ///< yield T desugar target: Yield<T>.
    Ordering,   ///< <=> builtin value type: Ordering::Less | Equal | Greater.
    Null,       ///< T? desugar type: Null<T>.
    Panic,      ///< fn () panic -> T desugar type: Panic<T>.

    String,   ///< ""     library type: string.
    Vector,   ///< [T]    library type: vector.
    Slice,    ///< [T;]   library type: slice.
    Array,    ///< [T; N] library type: array.
    HashMap,  ///< {K: V} library type: hashmap.
    HashSet,  ///< {T}    library type: hashset.

    BigInt,   ///< 3.0e+100 library type: BigInt.
    BigFloat, ///< 1.2e+100 library type: BigFloat.

    PanicRaise, ///< PanicLowering: raise entry point.
    PanicCatch, ///< PanicLowering: catch entry point.
    AssertFail, ///< PanicLowering: `assert` failure entry point.

    Pow,        ///< `^^` on primitives: `fn <B, E> pow(base: B, exp: E) -> B`.

    COUNT,      ///< keep last.
}

/// The lang item's NAME as the builtin root declares it. Diagnostics quote
/// this, so it must match the spelling `NameResolution::fill_lang_items` looks
/// up -- a message naming an item the tree does not declare is worse than no
/// message.
fn to_string(k: WellKnownType) -> string {
    switch k {
        case WellKnownType::Future     { return "Future";     }
        case WellKnownType::Range      { return "Range";      }
        case WellKnownType::Yield      { return "Yield";      }
        case WellKnownType::Ordering   { return "Ordering";   }
        case WellKnownType::Null       { return "Null";       }
        case WellKnownType::Panic      { return "Panic";      }
        case WellKnownType::String     { return "string";     }
        case WellKnownType::Vector     { return "Vector";     }
        case WellKnownType::Slice      { return "Slice";      }
        case WellKnownType::Array      { return "Array";      }
        case WellKnownType::HashMap    { return "HashMap";    }
        case WellKnownType::HashSet    { return "HashSet";    }
        case WellKnownType::BigInt     { return "BigInt";     }
        case WellKnownType::BigFloat   { return "BigFloat";   }
        case WellKnownType::PanicRaise { return "PanicRaise"; }
        case WellKnownType::PanicCatch { return "PanicCatch"; }
        case WellKnownType::AssertFail { return "AssertFail"; }
        case WellKnownType::Pow        { return "pow"; }
        case WellKnownType::COUNT      { return "<count>";    }
    }
    return "<unknown>";
}

/// \class WellKnownDecls
/// \brief WellKnownType -> canonical *Decl. ONE per build, owned by
///        GlobalDisambigTable and filled once from the builtins fid (lang
///        items are bound by fid + path, never by unqualified name). Read
///        by sema through sc->well_known and by codegen through the
///        CodegenContext. A missing entry is an error only at USE, diagnosed
///        by the pass that needs it.
class WellKnownDecls {
    priv var _decls: vec::<*Decl>;   ///< indexed by WellKnownType; COUNT slots.

    fn WellKnownDecls(self) {
        for var i: usize = 0; i < static_cast::<usize>(WellKnownType::COUNT); ++i {
            self._decls.push_back(&null);
        }
    }

    fn _set(self, k: WellKnownType, d: *Decl) {
        self._decls[static_cast::<usize>(k)] = d;
    }

    /// Canonical decl for the lang item, or null if not (yet) resolved.
    fn get(self, k: WellKnownType) -> *Decl {
        return self._decls[static_cast::<usize>(k)];
    }

    fn has(self, k: WellKnownType) -> bool {
        return self._decls[static_cast::<usize>(k)] != &null;
    }
}

/// \class LowerTargets
/// \brief The invented C++ name fragments. Nothing else in the compiler
///        carries a copy of any string here.
class LowerTargets {
    // --- Operators C++ cannot spell (writer: CXXSpell::operator_name) -----------

    /// `fn op in (self, x: T) -> bool` -- containment.
    static fn op_contains() -> string { return "__kairo_contains"; }
    /// `fn op in (self) -> yield T` -- iteration; IterLowering's output calls it.
    static fn op_iter()     -> string { return "__kairo_iter"; }
    /// `fn op ^^` -- exponentiation; not overloadable in C++.
    static fn op_pow()      -> string { return "__kairo_pow"; }
    /// `fn op .*` -- member-pointer access; not overloadable in C++.
    static fn op_dotstar()  -> string { return "__kairo_dotstar"; }
    /// `fn op await`.
    static fn op_await()    -> string { return "__kairo_await"; }
    /// An extension operator's receiver in its C++ definition. The operator
    /// takes `X&` ([over.oper]/7 wants a class-typed parameter), and the
    /// body's first statement binds `self` to its address, so the body is
    /// emitted exactly as any other extension member's.
    static fn ext_self() -> string { return "__kairo_self"; }

    // --- Witnesses (writer: EmitWitness) -------------------------------------------------

    /// `<Interface>` + suffix: `Drawable_witness`, and the concept `Drawable_c`.
    static fn witness_suffix() -> string { return "_witness"; }
    static fn concept_suffix() -> string { return "_c"; }

    // --- Array prvalues (writer: InterfaceEmitter; reader: EmitIR) --------------------

    /// `template <class T, decltype(sizeof(0)) N> using __kairo_array = T[N];`
    /// An alias, so it is never instantiated: `__kairo_array<int, 3>` IS
    /// `int[3]`, given a name a functional cast can use.
    static fn array_alias() -> string { return "__kairo_array"; }

    /// The reserved identifier prefix. CxxNameCheck rejects user identifiers
    /// that start with it.
    static fn reserved_prefix() -> string { return "__kairo_"; }
}