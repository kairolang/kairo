/// --- The Kairo Project ------------------------- Codegen/Emit/Spell.k --- ///
///
/// The ONE C++ speller: canonical type -> text, decl -> qualified
/// name, decl -> namespace path. Both emitters call it; there is
/// no second copy anywhere, because two spellers drift and the
/// drift is a silent link error.
///
///   \par Where its parts are
///     This file holds the class: its fields, construction and the namespace
///     tops every TU shares (NsTops). Its methods are `extend Speller`
///     blocks, one file per concern, reaching the fields as `prot`
///     (Codegen/module.k makes Codegen/ one module). Every emitter, and code
///     outside Codegen/, calls methods of every part, so this file re-exports
///     the parts (`pub import`): importing Spell.k brings all of it.
///       SpellFacts.k        visibility, widths, homes, attributes, linkage
///       SpellOperators.k    operator names, place operators, return types
///       SpellScopes.k       leaf and qualified names, namespaces
///       SpellTypes.k        types, values, signatures, dependent names
///       SpellConstraints.k  witnesses, requires clauses, asserts, heads
///       SpellRecords.k      specializations and record spellings
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

import AST::Context::InstantiationRegistry::InstanceEntry
import AST::LangItems::entry_point_name
import AST::Mixin::Annotation::VisibilityKind
import AST::Node::Base::Decl
import AST::Node::Declarations
import Codegen::CodegenContext::CodegenContext
import Codegen::CodegenICE::codegen_ice
pub import Codegen::Emit::SpellConstraints
pub import Codegen::Emit::SpellFacts
pub import Codegen::Emit::SpellOperators
pub import Codegen::Emit::SpellRecords
pub import Codegen::Emit::SpellScopes
pub import Codegen::Emit::SpellTypes
import Location::SourceRange::SourceRange

/// VisibilityKind enumerator values (AST/Mixin/Annotation.k): None,
/// Private, Protected, Public, Internal. Read through vis_of() and nowhere
/// else. InheritEdge's comment claims 0 none / pub / prot / priv; that
/// order is wrong, and trusting it inverted the header's pub filter.
pub eval fn VIS_NONE() -> u8 {
    return VisibilityKind::None as u8
}

pub eval fn VIS_PRIV() -> u8 {
    return VisibilityKind::Private as u8
}

pub eval fn VIS_PROT() -> u8 {
    return VisibilityKind::Protected as u8
}

pub eval fn VIS_PUB()  -> u8 {
    return VisibilityKind::Public as u8
}

pub eval fn VIS_INTERNAL() -> u8 {
    return VisibilityKind::Internal as u8
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
/// every Speller (TypeExport's sink-less ones too) and every later input of
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

class NsTops {
    priv var _mu: kairo::std::Mutex
    /// _from.size(): read without the lock, so a build with no renames (the
    /// common case) never takes it on the hot path (_ns_from runs per name).
    priv var _n:       kairo::std::Atomic<u32>  = kairo::std::Atomic<u32>(0)
    priv var _from:    cxx::std::vector<string> ///< renamed top segments, as cxx_segment spells them.
    priv var _to:      cxx::std::vector<string> ///< parallel: their C++ spelling.
    priv var _decided: cxx::std::vector<string> ///< every segment decided, renamed or not.

    fn NsTops(self) { }

    /// `s`'s C++ spelling: the recorded one, else the entry-point rule
    /// alone (no build decided it: a tool's bare parse, or a TU outside the
    /// graph), which is also what the build's decision gives such a name
    /// whenever no header claims its `_` forms.
    fn spelling(self, const s: string) -> string {
        if self._n.load() != 0 {
            var lock = kairo::std::LockGuard(self._mu)
            for var i: usize = 0; i < self._from.size(); ++i {
                if self._from[i] == s {
                    return self._to[i].copy()
                }
            }
        }

        if !is_entry_point_name(s) {
            return s.copy()
        }

        var c = s + "_"
        while is_entry_point_name(c) {
            c += "_"
        }

        return c
    }

    /// The Kairo top segment whose C++ spelling is `c` (identity if none).
    fn kairo_of(self, const c: string) -> string {
        if self._n.load() != 0 {
            var lock = kairo::std::LockGuard(self._mu)
            for var i: usize = 0; i < self._to.size(); ++i {
                if self._to[i] == c {
                    return self._from[i].copy()
                }
            }
        }

        return c.copy()
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

    /// `c` is already some OTHER segment's renamed spelling.
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

/// The one instance (see NsTops).
var _NS_TOPS: NsTops = NsTops()

pub class Speller {
    prot var _cg: unsafe *CodegenContext

    /// While EmitWitness spells a witness member: the interface whose bare
    /// `Self` (an argument-less record of it) is spelled `self_spelling` --
    /// `__kairo_Self` in the primary, the conformer in a specialization.
    /// Null everywhere else, where an interface type is still an ICE.
    pub var self_iface: unsafe *Decl = &null
    /// While EmitWitness writes a CONCEPT: the witness an associated type
    /// over Self is a member of, spelled (`::ns::I_witness<__kairo_Self>`).
    /// Empty inside a specialization, whose own `using Node = ...;` the
    /// bare name finds.
    pub var assoc_self_qual: string = ""
    pub var self_spelling:   string = ""
    /// While EmitWitness writes a requirement's head inside a witness
    /// specialization: the interface instance's arguments, which a clause
    /// of the requirement that names the interface's own parameters is
    /// spelled over (`requires __builtin_is_same<J::Item, T>()` at
    /// `FromIterator<i64>` reads `T` as `i64`; the specialization declares
    /// no `T`). Null everywhere else: a clause is spelled as written.
    pub var pred_subst: unsafe *InstanceEntry = &null
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
    prot var _renamed:     cxx::std::vector<unsafe *Declarations::GenericParamDecl>
    prot var _renamed_for: unsafe *Decl                                             = &null
    /// While set (EmitPlan::dump): a top namespace segment is spelled as
    /// the Kairo module names it, not as its renamed C++ form (NsTops),
    /// so a dump shows `::main::f` for the module the source calls `main`.
    /// Never set while emitting.
    pub var kairo_top: bool = false

    fn Speller(self) {
        self._cg = &null
    }

    pub fn Speller(self, cg: unsafe *CodegenContext) {
        self._cg = cg
    }

    /// ICE naming the Kairo source at `at` (CodegenICE). A canonical type
    /// carries no range; pass the written node or the owning decl's.
    prot fn _ice(self, at: SourceRange, const msg: string) {
        codegen_ice(self._cg->ctx, at, msg)
    }
}
