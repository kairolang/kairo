/// --- The Kairo Project ---------------------------- Sema/SemaDump.k --- ///
///
///   \brief `--print-sema`: a readable dump of everything sema has decided
///          about a TU so far.
///
///   \detail
///     The sema-side counterpart to `--print-ast` (syntax), `--print-symbols`
///     (frozen tables) and `--print-imports` (overlays). Those three show what
///     the PARSER and phase I produced; this one shows what the RESOLUTION
///     passes produced, which is otherwise invisible: `resolved_decl` links,
///     redecl chains, out-of-line attachment, lang items, and canonical types.
///
///     Six sections, in pipeline order, so the dump reads as a phase trace:
///
///       phase        -- how far sema actually got for this TU.
///       lang items   -- sc.well_known                            [N(a)]
///       chains       -- multi-decl cells: overload set vs redecl [N(a)]
///       out-of-line  -- `fn Class::method` attachment            [N(a)]
///       bindings     -- every NamedIdentExpr use site            [N(b)]
///       types        -- every Type node's canonical / dependent  [T]
///
///     A section reports the ABSENCE of a result as loudly as its presence:
///     `<UNRESOLVED>` in red is the point of the tool. The types section is
///     wired now and will read as entirely unresolved until TypeResolution
///     lands   that is the honest state, and it means T needs no dump work.
///
///   \par Not a pass
///     Read-only; writes nothing to the AST. Safe to run at any phase, and
///     safe to run when earlier phases errored (a poisoned tree dumps as
///     poisoned rather than crashing).
///
///   Phase: TOOLING
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ----------------------------------------------------------------- ///

import Sema::SemaContext::*;
import Sema::Resolve::NameLookup::*;
import AST::Context::ASTContext::*;
import AST::Context::DeclContext::*;
import AST::Context::TranslationUnit::*;
import AST::Context::SymbolTable::*;
import AST::ASTSupport::*;
import AST::Node::Base::*;
import AST::Node::Program::*;
import AST::Node::PrimaryExpressions::*;
import AST::Node::Expressions::*;
import AST::Node::Patterns::*;
import AST::Node::Statements::*;
import AST::Node::Declarations::*;
import AST::Node::Types::*;
import AST::Node::Casting::*;
import AST::Kind::DeclKind::*;
import AST::Printer::PrintCore::*;
import AST::Printer::ASTPrinter::*;
import AST::Visitor::RecursiveASTVisitor::*;
import Location::SourceManager::*;
import Token::Token::*;

__inline_cpp("
#define RecursiveASTVisitor_SemaDump RecursiveASTVisitor<SemaDump>
");

/// \brief `line:col` for a location, or `?:?` when unmapped. Every row in the
///        dump is anchored this way so a reader can jump straight to it.
fn sema_dump_loc(ctx: *ASTContext, loc: SourceLocation) -> string {
    if ctx == &null { return "?:?"; }
    if ctx->sm == &null { return "?:?"; }
    var full = ctx->sm->get_line_col(loc);
    return f"{full.line}:{full.column}";
}

/// \brief Source-shaped word for a decl kind (`fn`, `class`, `param`, ...).
///        The dump reads better with the spelling the user wrote than with
///        the node class name; AST class names are what --print-ast is for.
fn sema_dump_kind_str(k: DeclKind) -> string {
    switch k {
        case DeclKind::FunctionDecl        { return "fn";        }
        case DeclKind::VariableDecl        { return "var";       }
        case DeclKind::FieldDecl           { return "field";     }
        case DeclKind::ParamDecl           { return "param";     }
        case DeclKind::GenericParamDecl    { return "generic";   }
        case DeclKind::StructDecl          { return "struct";    }
        case DeclKind::ClassDecl           { return "class";     }
        case DeclKind::InterfaceDecl       { return "interface"; }
        case DeclKind::ExtensionDecl       { return "extend";    }
        case DeclKind::EnumDecl            { return "enum";      }
        case DeclKind::EnumVariantDecl     { return "variant";   }
        case DeclKind::UnionDecl           { return "union";     }
        case DeclKind::TypeAliasDecl       { return "type";      }
        case DeclKind::ModuleDecl          { return "module";    }
        case DeclKind::ImportDecl          { return "import";    }
        case DeclKind::TestDecl            { return "test";      }
        case DeclKind::MacroDecl           { return "macro";     }
        case DeclKind::ProcedureMacroDecl  { return "@macro";    }
        case DeclKind::RecoveryDecl        { return "<error>";   }
        default                            { return "decl";      }
    }
}

/// \brief The decl's own spelled name, or "" for the unnamed kinds.
fn sema_dump_decl_name(ctx: *ASTContext, d: *Decl) -> string {
    if (d == &null) || (ctx == &null) { return ""; }
    if isa::<FunctionDecl>(d)      { return ctx->get_spelling(cast::<FunctionDecl>(d)->name);      }
    if isa::<VariableDecl>(d)      { return ctx->get_spelling(cast::<VariableDecl>(d)->name);      }
    if isa::<FieldDecl>(d)         { return ctx->get_spelling(cast::<FieldDecl>(d)->name);         }
    if isa::<ParamDecl>(d)         { return ctx->get_spelling(cast::<ParamDecl>(d)->name);         }
    if isa::<GenericParamDecl>(d)  { return ctx->get_spelling(cast::<GenericParamDecl>(d)->name);  }
    if isa::<ClassDecl>(d)         { return ctx->get_spelling(cast::<ClassDecl>(d)->name);         }
    if isa::<StructDecl>(d)        { return ctx->get_spelling(cast::<StructDecl>(d)->name);        }
    if isa::<UnionDecl>(d)         { return ctx->get_spelling(cast::<UnionDecl>(d)->name);         }
    if isa::<InterfaceDecl>(d)     { return ctx->get_spelling(cast::<InterfaceDecl>(d)->name);     }
    if isa::<EnumDecl>(d)          { return ctx->get_spelling(cast::<EnumDecl>(d)->name);          }
    if isa::<EnumVariantDecl>(d)   { return ctx->get_spelling(cast::<EnumVariantDecl>(d)->name);   }
    if isa::<TypeAliasDecl>(d)     { return ctx->get_spelling(cast::<TypeAliasDecl>(d)->name);     }
    if isa::<ModuleDecl>(d)        { return ctx->get_spelling(cast::<ModuleDecl>(d)->name);        }
    return "";
}

/// \brief One-line identity for a decl: `kind name @ line:col`. Deliberately
///        NOT the full DeclPrinter rendering   a binding row wants a compact
///        target, and a method body's worth of text in a table cell is noise.
fn sema_dump_decl_brief(ctx: *ASTContext, d: *Decl) -> string {
    if d == &null { return "<null>"; }
    var kind = sema_dump_kind_str(d->kind);
    var name = sema_dump_decl_name(ctx, d);
    var at   = sema_dump_loc(ctx, d->range.start);
    var pois = ("  [poisoned]") if (d->is_poisoned()) else ("");
    if name.size() == 0 { return f"{kind} @ {at}{pois}"; }
    return f"{kind} {name} @ {at}{pois}";
}

fn sema_dump_phase_str(p: SemaPhase) -> string {
    switch p {
        case SemaPhase::Parsed          { return "Parsed";          }
        case SemaPhase::ImportsResolved { return "ImportsResolved"; }
        case SemaPhase::Expanded        { return "Expanded";        }
        case SemaPhase::Verified        { return "Verified";        }
        case SemaPhase::NamesResolved   { return "NamesResolved";   }
        case SemaPhase::TypesResolved   { return "TypesResolved";   }
        case SemaPhase::Checked         { return "Checked";         }
        case SemaPhase::Lowered         { return "Lowered";         }
        case SemaPhase::MonoCollected   { return "MonoCollected";   }
        case SemaPhase::Complete        { return "Complete";        }
    }
    return "<?>";
}

///
/// \class SemaDump
/// \brief Renders the sema state of one TU. Construct, `run()`, done.
///
///        Scope paths (`<tu>::Counter::bump`) are maintained during the walk
///        so a binding row says WHERE it was written, not just what it bound
///        to   the single most useful column when chasing a wrong shadow.
///
class SemaDump derives RecursiveASTVisitor::<SemaDump> {
    pub var sc:   *SemaContext;
    pub var ctx:  *ASTContext;
    pub var opts: PrintOptions;
    pub var fid:  u32 = 0;

    /// ONE buffered painter for the whole dump, flushed once in run(). A
    /// painter per section double-spaced every row, since both newline() and
    /// std::print append a line break.
    priv var _p: Painter;

    // Section state.
    priv var _scope: string = "<tu>";     ///< current qualified scope path.
    priv var _emitted_scope: string = ""; ///< last scope header actually printed.

    // Counters for the summary line.
    priv var _n_bound:      usize = 0;
    priv var _n_deferred:   usize = 0;
    priv var _n_unresolved: usize = 0;
    priv var _n_ty_total:   usize = 0;
    priv var _n_ty_canon:   usize = 0;
    priv var _n_ty_dep:     usize = 0;

    fn SemaDump(self, sc: *SemaContext, opts: PrintOptions) {
        self.sc   = sc;
        self.ctx  = sc->ctx;
        self.opts = opts;
        self.fid  = sc->ctx->fid;
    }

    fn run(self) {
        var tu = self.sc->tu;
        if tu == &null { return; }

        self._p = Painter(self.opts);

        var fname: string = "<unknown>";
        if self.ctx->sm != &null { fname = self.ctx->sm->get_filename(self.fid); }
        self._p.paint(Color::NodeKind, f"===== SEMA fid {self.fid}: {fname} =====");
        self._p.newline();
        self._p.paint(Color::Dim, "phase: ");
        self._p.paint(Color::Keyword, sema_dump_phase_str(self.sc->phase));
        var errs = self.sc->error_delta();
        if errs > 0 { self._p.paint(Color::Error, f"   ({errs} sema error(s))"); }
        self._p.newline();

        self._dump_lang_items();
        self._dump_chains(tu);
        self._dump_out_of_line(tu);
        self._dump_bindings(tu);
        self._dump_summary();

        std::print(self._p.out);
    }

    // --- section 1: lang items --------------------------------------------

    priv fn _dump_lang_items(self) {
        self._p.paint(Color::NodeKind, "-- lang items (well_known) --");
        self._p.newline();
        self._lang_row(WellKnownType::Future,   "Future");
        self._lang_row(WellKnownType::Range,    "Range");
        self._lang_row(WellKnownType::Yield,    "Yield");
        self._lang_row(WellKnownType::Ordering, "Ordering");
        self._lang_row(WellKnownType::Null,     "Null");
        self._lang_row(WellKnownType::Panic,    "Panic");

        self._lang_row(WellKnownType::String,   "string");
        self._lang_row(WellKnownType::Vector,   "vector");
        self._lang_row(WellKnownType::Slice,    "slice");
        self._lang_row(WellKnownType::Array,    "array");
        self._lang_row(WellKnownType::HashMap,  "map");
        self._lang_row(WellKnownType::HashSet,  "set");

        self._lang_row(WellKnownType::BigInt,   "int");
        self._lang_row(WellKnownType::BigFloat, "float");

        self._lang_row(WellKnownType::I8,   "i8");
        self._lang_row(WellKnownType::I16,  "i16");
        self._lang_row(WellKnownType::I32,  "i32");
        self._lang_row(WellKnownType::I64,  "i64");
        self._lang_row(WellKnownType::I128, "i128");
        self._lang_row(WellKnownType::I256, "i256");
        self._lang_row(WellKnownType::I512, "i512");

        self._lang_row(WellKnownType::U8,   "u8");
        self._lang_row(WellKnownType::U16,  "u16");
        self._lang_row(WellKnownType::U32,  "u32");
        self._lang_row(WellKnownType::U64,  "u64");
        self._lang_row(WellKnownType::U128, "u128");
        self._lang_row(WellKnownType::U256, "u256");
        self._lang_row(WellKnownType::U512, "u512");

        self._lang_row(WellKnownType::F8,   "f8");
        self._lang_row(WellKnownType::F16,  "f16");
        self._lang_row(WellKnownType::F32,  "f32");
        self._lang_row(WellKnownType::F64,  "f64");
        self._lang_row(WellKnownType::F128, "f128");
        self._lang_row(WellKnownType::F256, "f256");
    }

    priv fn _lang_row(self, k: WellKnownType, spelling: string) {
        self._p.paint(Color::Tree, "  ");
        self._p.paint(Color::TypeName, spelling);
        self._p.put("  ");
        var d = self.sc->well_known.get(k);
        if d == &null {
            // Not an error by itself: a lang item is only required at USE.
            self._p.paint(Color::Dim, "<unresolved>");
        } else {
            self._p.paint(Color::Operator, "-> ");
            self._p.put(sema_dump_decl_brief(self.ctx, d));
        }
        self._p.newline();
    }

    // --- section 2: redecl chains / overload sets -------------------------

    priv fn _dump_chains(self, tu: *TranslationUnit) {
        self._p.paint(Color::NodeKind, "-- multi-decl names (overload sets / redecl chains) --");
        self._p.newline();
        self._chains_in(static_cast::<*DeclContext>(tu), "<tu>");
    }

    priv fn _chains_in(self, dc: *DeclContext, qual: string) {
        if dc == &null { return; }

        if dc->dc_symbols != &null {
            var rows = vec::<SymbolTable::Entry>();
            dc->dc_symbols->collect_entries(rows);
            for var i: usize = 0; i < rows.size(); ++i {
                var cell = rows[i].cell;
                if cell == &null { continue; }
                if cell->size() <= 1 { continue; }

                        var name = rows[i].name.describe(self.ctx);
                self._p.paint(Color::Tree, "  ");
                self._p.paint(Color::Ident, f"{qual}::{name}");

                var all_fn = true;
                for var j: usize = 0; j < cell->size(); ++j {
                    if !isa::<FunctionDecl>(cell->get(j)) { all_fn = false; }
                }
                if all_fn {
                    self._p.paint(Color::Dim, f"   [overload set x{cell->size()}]");
                } else {
                    self._p.paint(Color::Dim, f"   [redecl chain x{cell->size()}]");
                }
                self._p.newline();

                var canon = self._canonical_of(cell->get(0));
                for var j: usize = 0; j < cell->size(); ++j {
                    var d = cell->get(j);
                    if d == &null { continue; }
                    self._p.paint(Color::Tree, "    - ");
                    self._p.put(sema_dump_decl_brief(self.ctx, d));
                    if self._is_definition(d) { self._p.paint(Color::Keyword, "  [definition]"); }
                    if (canon != &null) && (canon == d) {
                        self._p.paint(Color::Attr, "  [canonical]");
                    }
                    self._p.newline();
                }
                    }
        }

        for var i: usize = 0; i < dc->dc_decls.size(); ++i {
            var d = *(dc->dc_decls.get(i));
            if d == &null { continue; }
            var child = NameLookup::context_of(d);
            if child == &null { continue; }
            var nm = sema_dump_decl_name(self.ctx, d);
            if nm.size() == 0 { nm = "<anon>"; }
            self._chains_in(child, f"{qual}::{nm}");
        }
    }

    /// Redeclarable is a CRTP mixin with typed links, so canonical/definition
    /// have to be asked per concrete kind. Non-redeclarable kinds answer null
    /// / false, which is exactly right for the dump.
    priv fn _canonical_of(self, d: *Decl) -> *Decl {
        if d == &null { return &null; }
        if isa::<ClassDecl>(d)     { return static_cast::<*Decl>(cast::<ClassDecl>(d)->canonical_decl());     }
        if isa::<StructDecl>(d)    { return static_cast::<*Decl>(cast::<StructDecl>(d)->canonical_decl());    }
        if isa::<UnionDecl>(d)     { return static_cast::<*Decl>(cast::<UnionDecl>(d)->canonical_decl());     }
        if isa::<InterfaceDecl>(d) { return static_cast::<*Decl>(cast::<InterfaceDecl>(d)->canonical_decl()); }
        if isa::<EnumDecl>(d)      { return static_cast::<*Decl>(cast::<EnumDecl>(d)->canonical_decl());      }
        if isa::<ModuleDecl>(d)    { return static_cast::<*Decl>(cast::<ModuleDecl>(d)->canonical_decl());    }
        return &null;
    }

    priv fn _is_definition(self, d: *Decl) -> bool {
        if d == &null { return false; }
        if isa::<ClassDecl>(d)     { return cast::<ClassDecl>(d)->is_this_definition;     }
        if isa::<StructDecl>(d)    { return cast::<StructDecl>(d)->is_this_definition;    }
        if isa::<UnionDecl>(d)     { return cast::<UnionDecl>(d)->is_this_definition;     }
        if isa::<InterfaceDecl>(d) { return cast::<InterfaceDecl>(d)->is_this_definition; }
        if isa::<EnumDecl>(d)      { return cast::<EnumDecl>(d)->is_this_definition;      }
        if isa::<ModuleDecl>(d)    { return cast::<ModuleDecl>(d)->is_this_definition;    }
        if isa::<FunctionDecl>(d)  { return cast::<FunctionDecl>(d)->has_body();          }
        return false;
    }

    // --- section 3: out-of-line attachment --------------------------------

    priv fn _dump_out_of_line(self, tu: *TranslationUnit) {
        self._p.paint(Color::NodeKind, "-- out-of-line definitions --");
        self._p.newline();
        if tu->out_of_line.size() == 0 {
            self._p.paint(Color::Dim, "  (none)");
            self._p.newline();
                return;
        }

        for var i: usize = 0; i < tu->out_of_line.size(); ++i {
            var d = *(tu->out_of_line.get(i));
            if d == &null { continue; }
            self._p.paint(Color::Tree, "  ");
            self._p.paint(Color::Ident, sema_dump_decl_name(self.ctx, d));
            self._p.paint(Color::Dim, f"  @ {sema_dump_loc(self.ctx, d->range.start)}");
            self._p.put("  ");
            if d->semantic_dc == &null {
                // N(a) diagnosed this; the row records WHY the body will not
                // resolve against a type scope.
                self._p.paint(Color::Error, "<UNATTACHED>");
            } else {
                var home = reinterpret_cast::<*DeclContext>(d->semantic_dc);
                self._p.paint(Color::Operator, "-> ");
                self._p.put(f"attached to {self._dc_label(home)}");
            }
            self._p.newline();
        }
    }

    priv fn _dc_label(self, dc: *DeclContext) -> string {
        if dc == &null { return "<null scope>"; }
        if dc->is_translation_unit() { return "<tu>"; }
        var owner = dc->owner_decl();
        if owner == &null { return "<anon scope>"; }
        var nm = sema_dump_decl_name(self.ctx, owner);
        if nm.size() == 0 { return "<anon scope>"; }
        return nm;
    }

    // --- section 4 + 5: bindings and types (one walk) ---------------------

    priv fn _dump_bindings(self, tu: *TranslationUnit) {
        self._p.paint(Color::NodeKind, "-- name bindings --");
        self._p.newline();

        if tu->program == &null { return; }
        var items = &(tu->program->items);
        for var i: usize = 0; i < items->size(); ++i {
            var item = *(items->get(i));
            switch item.get_kind() {
                case TopLevelKind::Decl { self.dyn()->dispatch_decl(item.as_decl()); }
                case TopLevelKind::Stmt { self.dyn()->dispatch_stmt(item.as_stmt()); }
                case TopLevelKind::Expr { self.dyn()->dispatch_expr(item.as_expr()); }
            }
        }

        if (self._n_bound + self._n_deferred + self._n_unresolved) == 0 {
            self._p.paint(Color::Dim, "  (no identifier uses)");
            self._p.newline();
        }
    }

    /// Print the enclosing-scope header lazily, so scopes with no identifier
    /// uses do not clutter the dump.
    priv fn _scope_header(self) {
        if self._emitted_scope == self._scope { return; }
        self._emitted_scope = self._scope;
        self._p.paint(Color::Tree, "  ");
        self._p.paint(Color::Keyword, self._scope);
        self._p.newline();
    }

    fn visit_named_ident_expr(self, n: *NamedIdentExpr) -> bool {
        if n == &null { return true; }
        self._scope_header();

        var nm = self.ctx->get_spelling(n->name);
        self._p.paint(Color::Tree, "    ");
        self._p.paint(Color::Ident, nm);
        self._p.paint(Color::Dim, f"  @ {sema_dump_loc(self.ctx, n->range.start)}");
        self._p.put("  ");

        if n->is_bound() {
            self._n_bound += 1;
            self._p.paint(Color::Operator, "-> ");
            self._p.put(sema_dump_decl_brief(self.ctx, n->resolved_decl));
            self._p.newline();
        } else if n->is_deferred() {
            self._n_deferred += 1;
            var cell = n->candidate_cell;
            self._p.paint(Color::Operator, "-> ");
            self._p.paint(Color::Dim, f"{cell->size()} candidate(s), awaiting overload resolution");
            self._p.newline();
            for var i: usize = 0; i < cell->size(); ++i {
                self._p.paint(Color::Tree, "        - ");
                self._p.put(sema_dump_decl_brief(self.ctx, cell->get(i)));
                self._p.newline();
            }
        } else {
            self._n_unresolved += 1;
            if n->is_poisoned() {
                self._p.paint(Color::Error, "<UNRESOLVED>");
                self._p.paint(Color::Dim, "  (diagnosed)");
            } else {
                // Both slots null and NO diagnostic: either a deliberately
                // deferred node (pattern head, statement binder) or an N bug.
                // Either way the reader needs to see it.
                self._p.paint(Color::Error, "<UNBOUND>");
                self._p.paint(Color::Dim, "  (no diagnostic  deferred or a bug)");
            }
            self._p.newline();
        }
        return true;
    }

    /// Types are counted during the same walk and reported in the summary +
    /// the types section below. `canonical` is TypeResolution's output slot,
    /// so until T lands every non-dependent type reads as uncanonicalized.
    fn visit_type(self, n: *Type) -> bool {
        if n == &null { return true; }
        self._n_ty_total += 1;
        if n->canonical != &null { self._n_ty_canon += 1; }
        // TypeFlags is a scoped enum: cast to the underlying type to mask.
        var flags = static_cast::<u8>(n->type_flags);
        var dep   = static_cast::<u8>(Type::TypeFlags::IsDependent);
        if (flags & dep) != 0 { self._n_ty_dep += 1; }
        return true;
    }

    // --- scope-path tracking ----------------------------------------------

    fn traverse_function_decl(self, n: *FunctionDecl) -> *FunctionDecl {
        if n == &null { return n; }
        var saved = self._scope;
        self._scope = f"{self._scope}::{self.ctx->get_spelling(n->name)}";
        var out = RecursiveASTVisitor_SemaDump::traverse_function_decl(n);
        self._scope = saved;
        return out;
    }

    fn traverse_class_decl(self, n: *ClassDecl) -> *ClassDecl {
        if n == &null { return n; }
        var saved = self._scope;
        self._scope = f"{self._scope}::{self.ctx->get_spelling(n->name)}";
        var out = RecursiveASTVisitor_SemaDump::traverse_class_decl(n);
        self._scope = saved;
        return out;
    }

    fn traverse_struct_decl(self, n: *StructDecl) -> *StructDecl {
        if n == &null { return n; }
        var saved = self._scope;
        self._scope = f"{self._scope}::{self.ctx->get_spelling(n->name)}";
        var out = RecursiveASTVisitor_SemaDump::traverse_struct_decl(n);
        self._scope = saved;
        return out;
    }

    fn traverse_enum_decl(self, n: *EnumDecl) -> *EnumDecl {
        if n == &null { return n; }
        var saved = self._scope;
        self._scope = f"{self._scope}::{self.ctx->get_spelling(n->name)}";
        var out = RecursiveASTVisitor_SemaDump::traverse_enum_decl(n);
        self._scope = saved;
        return out;
    }

    fn traverse_union_decl(self, n: *UnionDecl) -> *UnionDecl {
        if n == &null { return n; }
        var saved = self._scope;
        self._scope = f"{self._scope}::{self.ctx->get_spelling(n->name)}";
        var out = RecursiveASTVisitor_SemaDump::traverse_union_decl(n);
        self._scope = saved;
        return out;
    }

    fn traverse_interface_decl(self, n: *InterfaceDecl) -> *InterfaceDecl {
        if n == &null { return n; }
        var saved = self._scope;
        self._scope = f"{self._scope}::{self.ctx->get_spelling(n->name)}";
        var out = RecursiveASTVisitor_SemaDump::traverse_interface_decl(n);
        self._scope = saved;
        return out;
    }

    fn traverse_module_decl(self, n: *ModuleDecl) -> *ModuleDecl {
        if n == &null { return n; }
        var saved = self._scope;
        self._scope = f"{self._scope}::{self.ctx->get_spelling(n->name)}";
        var out = RecursiveASTVisitor_SemaDump::traverse_module_decl(n);
        self._scope = saved;
        return out;
    }

    // --- section 6 + summary ----------------------------------------------

    priv fn _dump_summary(self) {

        self._p.paint(Color::NodeKind, "-- types --");
        self._p.newline();
        self._p.paint(Color::Tree, "  ");
        self._p.put(f"{self._n_ty_total} type node(s): ");
        self._p.put(f"{self._n_ty_canon} canonical, ");
        self._p.put(f"{self._n_ty_dep} dependent");
        self._p.newline();
        if (self._n_ty_total > 0) && (self._n_ty_canon == 0) {
            // Expected until TypeResolution is implemented; say so rather
            // than letting a reader mistake it for a resolution failure.
            self._p.paint(Color::Tree, "  ");
            self._p.paint(Color::Dim,
                "(no canonical types: TypeResolution has not run   phase stops at NamesResolved)");
            self._p.newline();
        }

        self._p.paint(Color::NodeKind, "-- summary --");
        self._p.newline();
        self._p.paint(Color::Tree, "  ");
        self._p.put(f"{self._n_bound} bound, ");
        self._p.put(f"{self._n_deferred} deferred (overload sets), ");
        if self._n_unresolved > 0 {
            self._p.paint(Color::Error, f"{self._n_unresolved} unresolved");
        } else {
            self._p.put("0 unresolved");
        }
        self._p.newline();
    }
}
