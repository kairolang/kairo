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
import AST::Node::Base::*;
import AST::Node::Declarations::*;
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

/// `derives_list`: the kinds with nominal bases.
fn decl_bases(d: *Decl) -> FrozenList::<InheritEdge> {
    if d == &null { return create_empty_frozen_list::<InheritEdge>(); }
    if isa::<ClassDecl>(d)     { return cast::<ClassDecl>(d)->derives_list;     }
    if isa::<InterfaceDecl>(d) { return cast::<InterfaceDecl>(d)->derives_list; }
    return create_empty_frozen_list::<InheritEdge>();
}
