/// --- The Kairo Project ---------------------------- AST/DeclFacts.k --- ///
///
///   \brief Reading the CRTP mixin slots off a `*Decl`.
///
///   \detail
///     TemplateParams, FFILinkage and Redeclarable are mixins: each decl kind
///     derives its own instantiation, so there is no base a `*Decl` can be
///     read through, and every consumer that needed `generic_params` off a
///     base pointer wrote the same eight-arm switch. Those switches lived in
///     TypeResolve, ChainBinding, TypeUtil, MemberLookup, TypeExport,
///     ForeignInstantiate, DeclImport and RedeclMerge, and disagreed on which
///     kinds they covered. This is the one copy.
///
///     Every accessor answers for EVERY kind that carries the slot, and the
///     empty / null / false answer for every kind that does not. A caller
///     that wants a narrower set filters on kind itself.
///
///   Layer: AST. Imports AST only.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

import AST::ASTSupport::*;
import AST::Context::DeclContext::*;
import AST::Node::Base::*;
import AST::Node::Declarations::*;
import AST::Node::Types::*;
import AST::Node::CanonicalNodes::*;
import AST::Node::Casting::*;
import Token::Token::*;

// === TemplateParams =======================================================
//
// Function, Struct, Class, Interface, Extension, Enum, Union, TypeAlias.

fn decl_generic_params(d: *Decl) -> FrozenList::<*GenericParamDecl> {
    if d == &null { return create_empty_frozen_list::<*GenericParamDecl>(); }
    if isa::<ClassDecl>(d)     { return cast::<ClassDecl>(d)->generic_params;     }
    if isa::<StructDecl>(d)    { return cast::<StructDecl>(d)->generic_params;    }
    if isa::<UnionDecl>(d)     { return cast::<UnionDecl>(d)->generic_params;     }
    if isa::<InterfaceDecl>(d) { return cast::<InterfaceDecl>(d)->generic_params; }
    if isa::<EnumDecl>(d)      { return cast::<EnumDecl>(d)->generic_params;      }
    if isa::<TypeAliasDecl>(d) { return cast::<TypeAliasDecl>(d)->generic_params; }
    if isa::<FunctionDecl>(d)  { return cast::<FunctionDecl>(d)->generic_params;  }
    if isa::<ExtensionDecl>(d) { return cast::<ExtensionDecl>(d)->generic_params; }
    return create_empty_frozen_list::<*GenericParamDecl>();
}

/// The decl's `requires` clause (RequiresDesugar hoisted every inline
/// bound into it), or null.
fn decl_requires_clause(d: *Decl) -> *Expr {
    if d == &null { return &null; }
    if isa::<ClassDecl>(d)     { return cast::<ClassDecl>(d)->requires_clause;     }
    if isa::<StructDecl>(d)    { return cast::<StructDecl>(d)->requires_clause;    }
    if isa::<UnionDecl>(d)     { return cast::<UnionDecl>(d)->requires_clause;     }
    if isa::<InterfaceDecl>(d) { return cast::<InterfaceDecl>(d)->requires_clause; }
    if isa::<EnumDecl>(d)      { return cast::<EnumDecl>(d)->requires_clause;      }
    if isa::<TypeAliasDecl>(d) { return cast::<TypeAliasDecl>(d)->requires_clause; }
    if isa::<FunctionDecl>(d)  { return cast::<FunctionDecl>(d)->requires_clause;  }
    if isa::<ExtensionDecl>(d) { return cast::<ExtensionDecl>(d)->requires_clause; }
    return &null;
}

/// The slot itself, for a writer (DeclImport fills it). Null for a kind
/// that has none.
fn decl_generic_params_slot(d: *Decl) -> *FrozenList::<*GenericParamDecl> {
    if d == &null { return &null; }
    if isa::<ClassDecl>(d)     { return &(cast::<ClassDecl>(d)->generic_params);     }
    if isa::<StructDecl>(d)    { return &(cast::<StructDecl>(d)->generic_params);    }
    if isa::<UnionDecl>(d)     { return &(cast::<UnionDecl>(d)->generic_params);     }
    if isa::<InterfaceDecl>(d) { return &(cast::<InterfaceDecl>(d)->generic_params); }
    if isa::<EnumDecl>(d)      { return &(cast::<EnumDecl>(d)->generic_params);      }
    if isa::<TypeAliasDecl>(d) { return &(cast::<TypeAliasDecl>(d)->generic_params); }
    if isa::<FunctionDecl>(d)  { return &(cast::<FunctionDecl>(d)->generic_params);  }
    if isa::<ExtensionDecl>(d) { return &(cast::<ExtensionDecl>(d)->generic_params); }
    return &null;
}

fn decl_spec_kind(d: *Decl) -> SpecKind {
    if d == &null { return SpecKind::None; }
    if isa::<ClassDecl>(d)     { return cast::<ClassDecl>(d)->spec_kind;     }
    if isa::<StructDecl>(d)    { return cast::<StructDecl>(d)->spec_kind;    }
    if isa::<UnionDecl>(d)     { return cast::<UnionDecl>(d)->spec_kind;     }
    if isa::<InterfaceDecl>(d) { return cast::<InterfaceDecl>(d)->spec_kind; }
    if isa::<EnumDecl>(d)      { return cast::<EnumDecl>(d)->spec_kind;      }
    if isa::<TypeAliasDecl>(d) { return cast::<TypeAliasDecl>(d)->spec_kind; }
    if isa::<FunctionDecl>(d)  { return cast::<FunctionDecl>(d)->spec_kind;  }
    if isa::<ExtensionDecl>(d) { return cast::<ExtensionDecl>(d)->spec_kind; }
    return SpecKind::None;
}

fn decl_set_spec_kind(d: *Decl, k: SpecKind) {
    if d == &null { return; }
    if isa::<ClassDecl>(d)     { cast::<ClassDecl>(d)->spec_kind     = k; return; }
    if isa::<StructDecl>(d)    { cast::<StructDecl>(d)->spec_kind    = k; return; }
    if isa::<UnionDecl>(d)     { cast::<UnionDecl>(d)->spec_kind     = k; return; }
    if isa::<InterfaceDecl>(d) { cast::<InterfaceDecl>(d)->spec_kind = k; return; }
    if isa::<EnumDecl>(d)      { cast::<EnumDecl>(d)->spec_kind      = k; return; }
    if isa::<TypeAliasDecl>(d) { cast::<TypeAliasDecl>(d)->spec_kind = k; return; }
    if isa::<FunctionDecl>(d)  { cast::<FunctionDecl>(d)->spec_kind  = k; return; }
    if isa::<ExtensionDecl>(d) { cast::<ExtensionDecl>(d)->spec_kind = k; return; }
}

fn decl_spec_args(d: *Decl) -> FrozenList::<*Type> {
    if d == &null { return create_empty_frozen_list::<*Type>(); }
    if isa::<ClassDecl>(d)     { return cast::<ClassDecl>(d)->spec_args;     }
    if isa::<StructDecl>(d)    { return cast::<StructDecl>(d)->spec_args;    }
    if isa::<UnionDecl>(d)     { return cast::<UnionDecl>(d)->spec_args;     }
    if isa::<InterfaceDecl>(d) { return cast::<InterfaceDecl>(d)->spec_args; }
    if isa::<EnumDecl>(d)      { return cast::<EnumDecl>(d)->spec_args;      }
    if isa::<TypeAliasDecl>(d) { return cast::<TypeAliasDecl>(d)->spec_args; }
    if isa::<FunctionDecl>(d)  { return cast::<FunctionDecl>(d)->spec_args;  }
    if isa::<ExtensionDecl>(d) { return cast::<ExtensionDecl>(d)->spec_args; }
    return create_empty_frozen_list::<*Type>();
}

/// `instantiated_from`, or null: the primary for a spec, the pattern for an
/// implicit instance, null for a plain decl.
fn decl_instantiated_from(d: *Decl) -> *Decl {
    if d == &null { return &null; }
    if isa::<ClassDecl>(d)     { return cast::<ClassDecl>(d)->instantiated_from;     }
    if isa::<StructDecl>(d)    { return cast::<StructDecl>(d)->instantiated_from;    }
    if isa::<UnionDecl>(d)     { return cast::<UnionDecl>(d)->instantiated_from;     }
    if isa::<InterfaceDecl>(d) { return cast::<InterfaceDecl>(d)->instantiated_from; }
    if isa::<EnumDecl>(d)      { return cast::<EnumDecl>(d)->instantiated_from;      }
    if isa::<TypeAliasDecl>(d) { return cast::<TypeAliasDecl>(d)->instantiated_from; }
    if isa::<FunctionDecl>(d)  { return cast::<FunctionDecl>(d)->instantiated_from;  }
    if isa::<ExtensionDecl>(d) { return cast::<ExtensionDecl>(d)->instantiated_from; }
    return &null;
}

fn decl_set_instantiated_from(d: *Decl, p: *Decl) {
    if d == &null { return; }
    if isa::<ClassDecl>(d)     { cast::<ClassDecl>(d)->instantiated_from     = p; return; }
    if isa::<StructDecl>(d)    { cast::<StructDecl>(d)->instantiated_from    = p; return; }
    if isa::<UnionDecl>(d)     { cast::<UnionDecl>(d)->instantiated_from     = p; return; }
    if isa::<InterfaceDecl>(d) { cast::<InterfaceDecl>(d)->instantiated_from = p; return; }
    if isa::<EnumDecl>(d)      { cast::<EnumDecl>(d)->instantiated_from      = p; return; }
    if isa::<TypeAliasDecl>(d) { cast::<TypeAliasDecl>(d)->instantiated_from = p; return; }
    if isa::<FunctionDecl>(d)  { cast::<FunctionDecl>(d)->instantiated_from  = p; return; }
    if isa::<ExtensionDecl>(d) { cast::<ExtensionDecl>(d)->instantiated_from = p; return; }
}

/// The pattern a decl is an instance of, or the decl itself.
fn decl_pattern(d: *Decl) -> *Decl {
    var p = decl_instantiated_from(d);
    return (p) if (p != &null) else (d);
}

fn decl_is_instance(d: *Decl) -> bool { return decl_spec_kind(d) == SpecKind::Instantiated; }

fn decl_instantiated(d: *Decl) -> bool {
    if d == &null { return false; }
    if isa::<ClassDecl>(d)     { return cast::<ClassDecl>(d)->instantiated;     }
    if isa::<StructDecl>(d)    { return cast::<StructDecl>(d)->instantiated;    }
    if isa::<UnionDecl>(d)     { return cast::<UnionDecl>(d)->instantiated;     }
    if isa::<InterfaceDecl>(d) { return cast::<InterfaceDecl>(d)->instantiated; }
    if isa::<EnumDecl>(d)      { return cast::<EnumDecl>(d)->instantiated;      }
    return false;
}

fn decl_set_instantiated(d: *Decl) {
    if d == &null { return; }
    if isa::<ClassDecl>(d)     { cast::<ClassDecl>(d)->instantiated     = true; return; }
    if isa::<StructDecl>(d)    { cast::<StructDecl>(d)->instantiated    = true; return; }
    if isa::<UnionDecl>(d)     { cast::<UnionDecl>(d)->instantiated     = true; return; }
    if isa::<InterfaceDecl>(d) { cast::<InterfaceDecl>(d)->instantiated = true; return; }
    if isa::<EnumDecl>(d)      { cast::<EnumDecl>(d)->instantiated      = true; return; }
}

/// True for a kind ForeignInstantiate cannot fill at all, so a caller
/// asking "did the fill fail" gets "yes, and do not try" for free.
fn decl_fill_failed(d: *Decl) -> bool {
    if d == &null { return true; }
    if isa::<ClassDecl>(d)  { return cast::<ClassDecl>(d)->foreign_fill_failed;  }
    if isa::<StructDecl>(d) { return cast::<StructDecl>(d)->foreign_fill_failed; }
    if isa::<UnionDecl>(d)  { return cast::<UnionDecl>(d)->foreign_fill_failed;  }
    return true;
}

fn decl_set_fill_failed(d: *Decl) {
    if d == &null { return; }
    if isa::<ClassDecl>(d)  { cast::<ClassDecl>(d)->foreign_fill_failed  = true; return; }
    if isa::<StructDecl>(d) { cast::<StructDecl>(d)->foreign_fill_failed = true; return; }
    if isa::<UnionDecl>(d)  { cast::<UnionDecl>(d)->foreign_fill_failed  = true; return; }
}

// === FFILinkage ===========================================================
//
// Function, Variable, Struct, Class, Interface, Enum, Union, TypeAlias,
// Import.

fn decl_is_imported(d: *Decl) -> bool {
    if d == &null { return false; }
    if isa::<ClassDecl>(d)     { return cast::<ClassDecl>(d)->is_imported();     }
    if isa::<StructDecl>(d)    { return cast::<StructDecl>(d)->is_imported();    }
    if isa::<UnionDecl>(d)     { return cast::<UnionDecl>(d)->is_imported();     }
    if isa::<InterfaceDecl>(d) { return cast::<InterfaceDecl>(d)->is_imported(); }
    if isa::<EnumDecl>(d)      { return cast::<EnumDecl>(d)->is_imported();      }
    if isa::<TypeAliasDecl>(d) { return cast::<TypeAliasDecl>(d)->is_imported(); }
    if isa::<FunctionDecl>(d)  { return cast::<FunctionDecl>(d)->is_imported();  }
    if isa::<VariableDecl>(d)  { return cast::<VariableDecl>(d)->is_imported();  }
    return false;
}

/// The clang decl behind an imported entity, as *void (this layer cannot
/// name clang). Null on a Kairo-authored decl and on kinds without the mixin.
fn decl_clang(d: *Decl) -> *void {
    if d == &null { return &null; }
    if isa::<ClassDecl>(d)     { return cast::<ClassDecl>(d)->clang_decl;     }
    if isa::<StructDecl>(d)    { return cast::<StructDecl>(d)->clang_decl;    }
    if isa::<UnionDecl>(d)     { return cast::<UnionDecl>(d)->clang_decl;     }
    if isa::<InterfaceDecl>(d) { return cast::<InterfaceDecl>(d)->clang_decl; }
    if isa::<EnumDecl>(d)      { return cast::<EnumDecl>(d)->clang_decl;      }
    if isa::<TypeAliasDecl>(d) { return cast::<TypeAliasDecl>(d)->clang_decl; }
    if isa::<FunctionDecl>(d)  { return cast::<FunctionDecl>(d)->clang_decl;  }
    if isa::<VariableDecl>(d)  { return cast::<VariableDecl>(d)->clang_decl;  }
    return &null;
}

fn decl_origin_set(d: *Decl) -> *void {
    if d == &null { return &null; }
    if isa::<ClassDecl>(d)     { return cast::<ClassDecl>(d)->origin_set;     }
    if isa::<StructDecl>(d)    { return cast::<StructDecl>(d)->origin_set;    }
    if isa::<UnionDecl>(d)     { return cast::<UnionDecl>(d)->origin_set;     }
    if isa::<InterfaceDecl>(d) { return cast::<InterfaceDecl>(d)->origin_set; }
    if isa::<EnumDecl>(d)      { return cast::<EnumDecl>(d)->origin_set;      }
    if isa::<TypeAliasDecl>(d) { return cast::<TypeAliasDecl>(d)->origin_set; }
    if isa::<FunctionDecl>(d)  { return cast::<FunctionDecl>(d)->origin_set;  }
    if isa::<VariableDecl>(d)  { return cast::<VariableDecl>(d)->origin_set;  }
    return &null;
}

fn decl_origin_fid(d: *Decl) -> u32 {
    if d == &null { return 0; }
    if isa::<ClassDecl>(d)     { return cast::<ClassDecl>(d)->origin_fid;     }
    if isa::<StructDecl>(d)    { return cast::<StructDecl>(d)->origin_fid;    }
    if isa::<UnionDecl>(d)     { return cast::<UnionDecl>(d)->origin_fid;     }
    if isa::<InterfaceDecl>(d) { return cast::<InterfaceDecl>(d)->origin_fid; }
    if isa::<EnumDecl>(d)      { return cast::<EnumDecl>(d)->origin_fid;      }
    if isa::<TypeAliasDecl>(d) { return cast::<TypeAliasDecl>(d)->origin_fid; }
    if isa::<FunctionDecl>(d)  { return cast::<FunctionDecl>(d)->origin_fid;  }
    if isa::<VariableDecl>(d)  { return cast::<VariableDecl>(d)->origin_fid;  }
    return 0;
}

fn decl_cxx_spelling(d: *Decl) -> string {
    if d == &null { return ""; }
    if isa::<ClassDecl>(d)     { return cast::<ClassDecl>(d)->cxx_spelling;     }
    if isa::<StructDecl>(d)    { return cast::<StructDecl>(d)->cxx_spelling;    }
    if isa::<UnionDecl>(d)     { return cast::<UnionDecl>(d)->cxx_spelling;     }
    if isa::<InterfaceDecl>(d) { return cast::<InterfaceDecl>(d)->cxx_spelling; }
    if isa::<EnumDecl>(d)      { return cast::<EnumDecl>(d)->cxx_spelling;      }
    if isa::<TypeAliasDecl>(d) { return cast::<TypeAliasDecl>(d)->cxx_spelling; }
    if isa::<FunctionDecl>(d)  { return cast::<FunctionDecl>(d)->cxx_spelling;  }
    if isa::<VariableDecl>(d)  { return cast::<VariableDecl>(d)->cxx_spelling;  }
    return "";
}

/// The elaborated keyword of an imported tag whose name is hidden by an
/// ordinary name (FFILinkage::ffi_tag_keyword), or "".
fn decl_ffi_tag_keyword(d: *Decl) -> string {
    if d == &null { return ""; }
    if isa::<ClassDecl>(d)  { return cast::<ClassDecl>(d)->ffi_tag_keyword;  }
    if isa::<StructDecl>(d) { return cast::<StructDecl>(d)->ffi_tag_keyword; }
    if isa::<UnionDecl>(d)  { return cast::<UnionDecl>(d)->ffi_tag_keyword;  }
    if isa::<EnumDecl>(d)   { return cast::<EnumDecl>(d)->ffi_tag_keyword;   }
    return "";
}

fn decl_set_ffi_tag_keyword(d: *Decl, kw: string) {
    if d == &null { return; }
    if isa::<ClassDecl>(d)  { cast::<ClassDecl>(d)->ffi_tag_keyword  = kw; return; }
    if isa::<StructDecl>(d) { cast::<StructDecl>(d)->ffi_tag_keyword = kw; return; }
    if isa::<UnionDecl>(d)  { cast::<UnionDecl>(d)->ffi_tag_keyword  = kw; return; }
    if isa::<EnumDecl>(d)   { cast::<EnumDecl>(d)->ffi_tag_keyword   = kw; return; }
}

// === C/C++ name hiding ====================================================
//
// C and C++ keep tags (struct/class/union/enum names) apart from ordinary
// names (variables, functions, typedefs, enumerators): `struct timezone`
// and `extern long timezone` coexist, and the ORDINARY name is what a plain
// `timezone` means ([basic.scope.hiding], [class.name]). Kairo has one
// namespace per scope, so every place that sees both under one key applies
// that rule, and only between IMPORTED decls -- a Kairo decl never hides
// or is hidden this way.

/// Imported from a header: the FFILinkage kinds, plus an enumerator of an
/// imported enum (EnumVariantDecl carries no mixin of its own).
fn decl_is_ffi(d: *Decl) -> bool {
    if d == &null { return false; }
    if isa::<EnumVariantDecl>(d) {
        if d->semantic_dc == &null { return false; }
        var dc = reinterpret_cast::<*DeclContext>(d->semantic_dc);
        return decl_is_imported(dc->owner_decl());
    }
    return decl_is_imported(d);
}

/// An imported C/C++ tag: clang's IDNS_Tag.
fn decl_is_ffi_tag(d: *Decl) -> bool {
    if !decl_is_imported(d) { return false; }
    return isa::<StructDecl>(d) || isa::<ClassDecl>(d) || isa::<UnionDecl>(d) || isa::<EnumDecl>(d);
}

/// An imported typedef that names exactly \p tag: `typedef struct X X`
/// is one entity under one name, not a typedef hiding its own tag.
fn decl_is_ffi_typedef_of(d: *Decl, tag: *Decl) -> bool {
    if (d == &null) || (tag == &null) { return false; }
    if (!isa::<TypeAliasDecl>(d)) || (!decl_is_imported(d)) { return false; }
    var t = cast::<TypeAliasDecl>(d)->aliased;
    if (t == &null) || (!isa::<RecordType>(t)) { return false; }
    return cast::<RecordType>(t)->decl == tag;
}

/// An imported decl in the ORDINARY namespace that hides \p tag: anything
/// imported that is not itself a tag and not a typedef of that very tag.
fn decl_ffi_hides_tag(d: *Decl, tag: *Decl) -> bool {
    if (!decl_is_ffi(d)) || decl_is_ffi_tag(d) { return false; }
    if isa::<ModuleDecl>(d) { return false; }   // a namespace is not an ordinary name.
    if decl_is_ffi_typedef_of(d, tag) { return false; }
    // Hiding is between declarations of ONE scope. Two headers' global
    // scopes are two Kairo tables but one C++ scope, so the scope is read
    // off the qualified C++ spelling: `::timezone` and `::timezone` share
    // one, `::tz` and an inline namespace's `::a::tz` do not -- C++ calls
    // that pair ambiguous, and so do we.
    var ds = decl_cxx_spelling(d);
    var ts = decl_cxx_spelling(tag);
    if (ds.size() > 0) && (ts.size() > 0) && (ds != ts) { return false; }
    return true;
}

/// Apply C++'s tag hiding to a candidate set, in place, keeping order:
/// a `typedef struct X X` collapses into its tag, and an imported tag
/// beside an imported ordinary name drops out. Returns true when anything
/// was removed. Kairo decls are never touched.
fn ffi_hide_tags(cands: *vec::<*Decl>) -> bool {
    var n = cands->size();
    if n < 2 { return false; }
    var keep = vec::<*Decl>();
    for var i: usize = 0; i < n; ++i {
        var d = (*cands)[i];
        var drop = false;
        for var j: usize = 0; (j < n) && (!drop); ++j {
            if i == j { continue; }
            var o = (*cands)[j];
            if o == d { continue; }
            if decl_is_ffi_tag(d) && decl_ffi_hides_tag(o, d) { drop = true; }
            else if decl_is_ffi_tag(o) && decl_is_ffi_typedef_of(d, o) { drop = true; }
        }
        if !drop { keep.push_back(d); }
    }
    if keep.size() == n { return false; }
    (*cands) = keep;
    return true;
}

/// The clang builtin a decl stands for, or 0.
fn decl_builtin_id(d: *Decl) -> u32 {
    if (d == &null) || (!isa::<FunctionDecl>(d)) { return 0; }
    return cast::<FunctionDecl>(d)->ffi_builtin_id;
}

fn decl_set_imported(d: *Decl, cd: *void, usr: string, sp: string, hs: *void, fid: u32) {
    if d == &null { return; }
    if isa::<ClassDecl>(d)     { cast::<ClassDecl>(d)->set_imported(cd, usr, sp, hs, fid);     return; }
    if isa::<StructDecl>(d)    { cast::<StructDecl>(d)->set_imported(cd, usr, sp, hs, fid);    return; }
    if isa::<UnionDecl>(d)     { cast::<UnionDecl>(d)->set_imported(cd, usr, sp, hs, fid);     return; }
    if isa::<InterfaceDecl>(d) { cast::<InterfaceDecl>(d)->set_imported(cd, usr, sp, hs, fid); return; }
    if isa::<EnumDecl>(d)      { cast::<EnumDecl>(d)->set_imported(cd, usr, sp, hs, fid);      return; }
    if isa::<TypeAliasDecl>(d) { cast::<TypeAliasDecl>(d)->set_imported(cd, usr, sp, hs, fid); return; }
    if isa::<FunctionDecl>(d)  { cast::<FunctionDecl>(d)->set_imported(cd, usr, sp, hs, fid);  return; }
    if isa::<VariableDecl>(d)  { cast::<VariableDecl>(d)->set_imported(cd, usr, sp, hs, fid);  return; }
}

// === Names and bases ======================================================

/// The name token of a named decl. `Token{}` (kind TkUnknown) for the
/// unnamed kinds; callers test the kind, never the imm.
fn decl_name_tok(d: *Decl) -> Token {
    if d == &null { return Token{}; }
    if isa::<ClassDecl>(d)        { return cast::<ClassDecl>(d)->name;        }
    if isa::<StructDecl>(d)       { return cast::<StructDecl>(d)->name;       }
    if isa::<UnionDecl>(d)        { return cast::<UnionDecl>(d)->name;        }
    if isa::<InterfaceDecl>(d)    { return cast::<InterfaceDecl>(d)->name;    }
    if isa::<EnumDecl>(d)         { return cast::<EnumDecl>(d)->name;         }
    if isa::<TypeAliasDecl>(d)    { return cast::<TypeAliasDecl>(d)->name;    }
    if isa::<ModuleDecl>(d)       { return cast::<ModuleDecl>(d)->name;       }
    if isa::<FunctionDecl>(d)     { return cast::<FunctionDecl>(d)->name;     }
    if isa::<ParamDecl>(d)        { return cast::<ParamDecl>(d)->name;        }
    if isa::<VariableDecl>(d)     { return cast::<VariableDecl>(d)->name;     }
    if isa::<FieldDecl>(d)        { return cast::<FieldDecl>(d)->name;        }
    if isa::<EnumVariantDecl>(d)  { return cast::<EnumVariantDecl>(d)->name;  }
    if isa::<GenericParamDecl>(d) { return cast::<GenericParamDecl>(d)->name; }
    return Token{};
}

/// The parameter carrying the `...`, or null when there is none. This is the
/// one walk that answers WHICH parameter is the pack; `is_variadic` is exactly
/// `decl_pack_param(d) != null` and says only that one exists.
fn decl_pack_param(d: *Decl) -> *ParamDecl {
    if d == &null { return &null; }
    if !isa::<FunctionDecl>(d) { return &null; }
    var f = cast::<FunctionDecl>(d);
    for var i: usize = 0; i < f->params.size(); ++i {
        var p = f->params[i];
        if (p != &null) && p->is_pack { return p; }
    }
    return &null;
}

/// `...xs: T` with T a TYPE pack (`fn <...T> f(...xs: T)`): a C++
/// parameter pack, `T... xs`, one argument per element. A pack over one
/// type (`...xs: i32`, or a non-pack `U`) is a `Slice<E>` instead
/// (ParamDecl::pack_type); the two never mix, so every reader that builds,
/// spells or passes a pack asks this first.
fn param_is_type_pack(p: *ParamDecl) -> bool {
    if (p == &null) || (!p->is_pack) || (p->type_ == &null) || (p->type_->canonical == &null) { return false; }
    var g = dyn_cast::<GenericParamType>(canon_unqual(p->type_->canonical));
    return (g != &null) && g->is_pack;
}

/// The pack-expanded variant of ADT \p en (`Err { e: E }...`), or null.
fn adt_pack_variant(en: *EnumDecl) -> *EnumVariantDecl {
    if en == &null { return &null; }
    for var i: usize = 0; i < en->variants.size(); ++i {
        var v = en->variants[i];
        if (v != &null) && v->is_pack_expansion { return v; }
    }
    return &null;
}

/// The position in \p en's generic parameters of the type pack its
/// pack-expanded variant expands, or usize(-1) when it has none. An
/// instance's arguments from here on are the pack's elements
/// (InstanceEntry::args keeps packs flat, at the tail).
fn adt_pack_param(en: *EnumDecl) -> usize {
    if adt_pack_variant(en) == &null { return usize(-1); }
    for var i: usize = 0; i < en->generic_params.size(); ++i {
        var gp = en->generic_params[i];
        if (gp != &null) && gp->is_pack { return i; }
    }
    return usize(-1);
}

/// The position of variant \p v in \p en, or usize(-1).
fn adt_variant_pos(en: *EnumDecl, v: *EnumVariantDecl) -> usize {
    if (en == &null) || (v == &null) { return usize(-1); }
    for var i: usize = 0; i < en->variants.size(); ++i { if en->variants[i] == v { return i; } }
    return usize(-1);
}

/// An ADT's EXPANDED index: its constructors in tag order, which every
/// pattern and layout question indexes by. An ordinary variant's is its
/// position; element k of the pack-expanded variant (always the last, at
/// position p) is p + k, so for an enum without one the two are the same.
/// The variant expanded index \p i belongs to, or null past the last.
fn adt_variant_at(en: *EnumDecl, i: usize) -> *EnumVariantDecl {
    if en == &null { return &null; }
    var n = en->variants.size();
    if n == 0 { return &null; }
    if i < n {
        var v = en->variants[i];
        return v;
    }
    var last = en->variants[n - 1];
    if (last != &null) && last->is_pack_expansion { return last; }
    return &null;
}

/// The pack element expanded index \p i stands for, or -1 for an ordinary
/// variant (adt_variant_at).
fn adt_expansion_at(en: *EnumDecl, i: usize) -> i32 {
    var v = adt_variant_at(en, i);
    if (v == &null) || (!v->is_pack_expansion) { return -1; }
    return i32(i - (en->variants.size() - 1));
}

/// Where \p d's arguments become a set (decl_dedup_pack_args): the pack
/// position of an enum with a pack-expanded variant, \p d being it or an
/// instance of it; usize(-1) for every other decl.
fn decl_pack_set_at(d: *Decl) -> usize {
    if d == &null { return usize(-1); }
    var p = decl_instantiated_from(d);
    if p == &null { p = d; }
    var en = dyn_cast::<EnumDecl>(p);
    if (en == &null) || (!en->is_adt) { return usize(-1); }
    return adt_pack_param(en);
}

/// How a lang item orders its expanded pack, a set (decl_dedup_pack_args):
/// the Panic item sorts by type id (Sema's PanicTypeIds), which the AST
/// layer cannot compute, so the build's CanonicalTypeStore and
/// InstantiationRegistry hold one, installed by the driver. The default
/// keeps first-occurrence order. Must be stateless and lock-free: it runs
/// inside type formation.
class PackSetOrder {
    fn PackSetOrder(self) { }
    virtual fn order(self, d: *Decl, args: *vec::<*Type>) { }
}

/// `R<i32, string, string>` IS `R<i32, string>` when R's pack is expanded
/// into variants (PANIC.md §1.2: equal types are one variant). The pack is a
/// set, kept in first-occurrence order, so the dedup happens where a type is
/// formed (CanonicalTypes::record, InstantiationRegistry) and every reader
/// after it -- the instance's args, the expansions' tags, C++'s template
/// arguments -- sees one list. \p d is the primary or an instance of it.
fn decl_dedup_pack_args(d: *Decl, args: *vec::<*Type>, ord: *PackSetOrder = &null) {
    if (d == &null) || (args == &null) { return; }
    var at = decl_pack_set_at(d);
    if (at == usize(-1)) || (args->size() <= at + 1) { return; }
    var out = vec::<*Type>();
    for var i: usize = 0; i < args->size(); ++i {
        var a = (*args)[i];
        var dup = false;
        if i > at {
            for var j: usize = at; j < out.size(); ++j { if out[j] == a { dup = true; break; } }
        }
        if !dup { out.push_back(a); }
    }
    if out.size() != args->size() {
        args->clear();
        for var i: usize = 0; i < out.size(); ++i { args->push_back(out[i]); }
    }
    // A lang item may also fix the set's ORDER (PackSetOrder: the Panic
    // item sorts by type id, PANIC.md §1.3), once the duplicates are gone.
    if ord != &null { ord->order(d, args); }
}

/// `derives_list`: the kinds with nominal bases.
fn decl_bases(d: *Decl) -> FrozenList::<InheritEdge> {
    if d == &null { return create_empty_frozen_list::<InheritEdge>(); }
    if isa::<ClassDecl>(d)     { return cast::<ClassDecl>(d)->derives_list;     }
    if isa::<InterfaceDecl>(d) { return cast::<InterfaceDecl>(d)->derives_list; }
    return create_empty_frozen_list::<InheritEdge>();
}

// === Extension membership =================================================

/// The extension \p d was written in, or null. Lexical: an extension
/// member's C++ home and template parameters are its extension's.
fn decl_extension_of(d: *Decl) -> *ExtensionDecl {
    if (d == &null) || (!isa::<FunctionDecl>(d)) { return &null; }
    var lex = reinterpret_cast::<*DeclContext>(d->lexical_dc);
    if (lex == &null) || (lex->dc_kind != DeclContextKind::Extension) { return &null; }
    return dyn_cast::<ExtensionDecl>(lex->dc_owner);
}

// === Interface requirements ===============================================

/// \p m is a CONSTRUCTOR requirement: a method of an interface named after
/// that interface (`interface Defaultable { fn Defaultable(self) }`). A
/// conformer meets it with its own constructor, named after ITSELF, so a
/// lookup by the requirement's name can never find the witness; Sema and
/// Codegen both branch on this. The owner is the semantic one, the
/// interface that wrote it, so a requirement composed into a derived
/// interface is still one. Names are interned per file and a method shares
/// its interface's file, so the imms compare.
fn decl_is_ctor_requirement(m: *FunctionDecl) -> bool {
    if (m == &null) || m->is_operator || (m->semantic_dc == &null) { return false; }
    var owner = reinterpret_cast::<*DeclContext>(m->semantic_dc)->owner_decl();
    if (owner == &null) || (!isa::<InterfaceDecl>(owner)) { return false; }
    var a = decl_name_tok(static_cast::<*Decl>(m));
    var b = decl_name_tok(owner);
    if (!a.has_imm()) || (!b.has_imm()) { return false; }
    return a.imm == b.imm;
}
