/// --- The Kairo Project ----------------------- AST/Mixin/FFILinkage.k --- ///
///
///   CRTP mixin for declarations that may carry foreign-language linkage.
///
///   Two populations derive this: Kairo-authored decls the parser stamped
///   from an `ffi "c"/"c++"` prefix (linkage only), and decls IMPORTED from a
///   C++ header by Sema/Foreign (linkage + everything sema needs that has no
///   Kairo spelling). `is_imported()` tells them apart. Every field past the
///   linkage triple is null/zero on a Kairo-authored decl.
///
///   Nothing here is read by name resolution or the typer through a special
///   path: an imported decl is an ordinary Decl with its slots pre-filled.
///   These fields serve EmitIR (spellings), LayoutPass (layout parity),
///   CopyMoveLowering (triviality), ConformanceChecking (concept bounds),
///   OverloadResolution (C varargs, `explicit`) and M2 (the live clang decl).
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// -------------------------------------------------------------------- ///

import Location::SourceRange::*;
import Token::Token::*;

enum LinkageKind derives u8 {
    None = 0,  ///< No FFI linkage. Default Kairo linkage.
    C,         ///< ffi "c"  , no mangling.
    Cpp,       ///< ffi "c++", Itanium/MSVC mangling.
}

/// Layout facts clang computed for a complete, non-dependent record. Filled
/// by DeclImport from ASTContext::getASTRecordLayout; read by LayoutPass to
/// assert parity against a Kairo record declared as a mirror, and by
/// CopyMoveLowering for the triviality bits.
class ForeignLayout {
    pub var known:            bool  = false;  ///< false: dependent or incomplete; nothing below is valid.
    pub var size_bytes:       u64   = 0;
    pub var align_bytes:      u64   = 0;
    pub var field_offsets:    vec::<u64>;     ///< bits, in field declaration order (non-static fields only).
    pub var has_vfptr:        bool  = false;
    pub var polymorphic:      bool  = false;
    pub var abstract_:        bool  = false;
    pub var trivially_copyable:  bool = false;
    pub var trivial_dtor:        bool = false;
    pub var trivial_default_ctor: bool = false;
    fn ForeignLayout(self) { }
}

/// CRTP mixin: Decl nodes derive FFILinkage::<SelfType>.
class <T> FFILinkage {
    pub var ffi_linkage:        LinkageKind = LinkageKind::None;
    pub var _ffi_linkage_range: SourceRange = SourceRange::invalid();
    pub var _ffi_lang_token:    Token;  ///< the string literal token ("c"/"c++")

    // --- Imported-from-clang facts (null/zero on Kairo-authored decls) --------

    /// The clang decl this was imported from, in the owning HeaderSet's
    /// ASTContext. LIVE only while that set's phase-A instance is alive
    /// (until every importer passes Checked); nulled by HeaderSet::release.
    /// Typed *void: this mixin cannot name clang.
    pub var clang_decl:   obs::<void> = &null;
    /// Unified Symbol Resolution string. Stable across clang instances: the
    /// phase-B differential check and mangling re-find the decl by this.
    pub var usr:          string = "";
    /// Fully qualified C++ spelling of the entity (`::std::vector`), what
    /// EmitIR writes. For a function this is the callee spelling; the
    /// per-parameter spellings live in `cxx_param_spellings`.
    pub var cxx_spelling: string = "";
    /// The HeaderSet that owns `clang_decl`. Typed *void for the same reason.
    pub var origin_set:   obs::<void> = &null;
    /// Kairo fid of the header this decl was imported from.
    pub var origin_fid:   u32 = 0;

    // Functions.
    pub var cxx_param_spellings: vec::<string>;   ///< clang's spelling per param (incl. `self`? no: value params only), for resolved-call casts.
    pub var cxx_return_spelling: string = "";
    pub var ffi_c_variadic:      bool = false;    ///< C `...` after the last declared parameter.
    pub var ffi_explicit:        bool = false;    ///< `explicit` ctor / conversion.
    pub var ffi_noexcept:        bool = false;
    pub var ffi_deleted:         bool = false;
    pub var ffi_constexpr:       bool = false;
    pub var ffi_virtual:         bool = false;
    pub var ffi_pure_virtual:    bool = false;
    pub var ffi_static_member:   bool = false;    ///< static member function (no receiver).
    pub var ffi_ref_qualifier:   u8   = 0;        ///< 0 none, 1 `&`, 2 `&&`.
    pub var ffi_conversion_op:   bool = false;    ///< `operator T()`; the target is the return type.

    // Records.
    pub var layout:          ForeignLayout;
    pub var ffi_is_union:    bool = false;
    pub var ffi_is_final:    bool = false;
    /// `struct` / `class` / `union` / `enum` when this tag's name is HIDDEN
    /// by an ordinary name in its scope (`struct timezone` beside `extern
    /// long timezone`, C++ [basic.scope.hiding]); "" otherwise. C++ then
    /// reaches the type only through an elaborated specifier, so CXXSpell
    /// writes `struct ::timezone` wherever it spells the type. Set by
    /// DeclImport, monotonic across header sets: once any set saw the name
    /// hidden, the elaborated spelling is the only one valid in every TU.
    pub var ffi_tag_keyword: string = "";
    /// On a Kairo-written bodiless `ffi "c" struct timezone` (or class /
    /// union): the imported tag it names, so the forward declaration IS the
    /// header's entity rather than a new Kairo type. NameLookup::
    /// representative answers with it, which makes every canonical type
    /// built from the forward declaration the header's. One writer: I
    /// (ImportResolution::_bind_ffi_forwards). Null when no header tag of
    /// that name is in the TU's ffi closure. Typed *void: this mixin cannot
    /// name Decl (DeclFacts casts).
    pub var ffi_tag_target:  obs::<void> = &null;

    // Enums.
    pub var ffi_scoped_enum: bool = false;

    // Interfaces.
    pub var is_cxx_concept:  bool = false;        ///< an InterfaceDecl standing for a C++ concept: constraint-only bound, no surface.

    // --- Queries --------------------------------------------------------

    const fn has_ffi_linkage(self) -> bool { return self.ffi_linkage != LinkageKind::None; }
    const fn is_ffi_c(self)        -> bool { return self.ffi_linkage == LinkageKind::C;    }
    const fn is_ffi_cpp(self)      -> bool { return self.ffi_linkage == LinkageKind::Cpp;  }
    const fn is_imported(self)     -> bool { return self.usr.size() > 0; }
    const fn ffi_linkage_range(self) -> SourceRange { return self._ffi_linkage_range; }
    const fn ffi_lang_token(self)    -> Token       { return self._ffi_lang_token; }

    // --- Mutation -------------------------------------------------------

    fn set_ffi_linkage(self, kind: LinkageKind, lang_tok: Token, range: SourceRange) {
        self.ffi_linkage        = kind;
        self._ffi_lang_token    = lang_tok;
        self._ffi_linkage_range = range;
    }

    /// The import stamp. Linkage is always Cpp for an imported decl (a C
    /// header parsed by clang in C++ mode is C++ to us; `extern "C"` is a
    /// mangling fact EmitIR reads off `cxx_spelling`, not a Kairo linkage).
    fn set_imported(self, clang_decl: *void, usr: string, spelling: string,
                    origin_set: *void, origin_fid: u32) {
        self.ffi_linkage  = LinkageKind::Cpp;
        self.clang_decl   = clang_decl;
        self.usr          = usr;
        self.cxx_spelling = spelling;
        self.origin_set   = origin_set;
        self.origin_fid   = origin_fid;
    }

    fn clear_ffi_linkage(self) {
        self.ffi_linkage        = LinkageKind::None;
        self._ffi_linkage_range = SourceRange::invalid();
    }

    /// HeaderSet::release: the phase-A ASTContext is gone.
    fn drop_clang_decl(self) { self.clang_decl = &null; }
}