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
///     Eight sections, in pipeline order, so the dump reads as a phase trace:
///
///       phase        -- how far sema actually got for this TU.
///       lang items   -- sc.well_known                            [N(a)]
///       tables       -- every DeclContext's frozen table, whole  [I]
///       chains       -- multi-decl cells: overload set vs redecl [N(a)]
///       out-of-line  -- `fn Class::method` attachment            [N(a)]
///       scopes       -- the lexical frame tree: what each scope  [N(b)]
///                       declares and what each name SHADOWS
///       bindings     -- every NamedIdentExpr use site, with the  [N(b)]
///                       source that answered it
///       types        -- every Type node's canonical / dependent  [T]
///
///     `tables` and `scopes` are NOT the same list seen twice. A DeclContext
///     owns a symbol table; a lexical frame does not, and N keeps locals out
///     of tables entirely. So a class body appears only in `tables` and a
///     function body only in `scopes`, and the two together are what "which
///     declaration is in scope here" actually means.
///
///     The scopes and bindings sections answer different questions and are
///     both worth having: `scopes` is N's decision log, replayed in the order
///     N made the decisions, and is the only place shadowing is visible at
///     all; `bindings` is the AST's FINAL state, walked fresh. A use that
///     appears in one and not the other is a bug   an unvisited node shows
///     up only in `bindings`, a rewritten one only in `scopes`.
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
import Sema::Resolve::ResolutionTrace::*;
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
fn sema_dump_decl_name(ctx_in: *ASTContext, d: *Decl) -> string {
    if (d == &null) || (ctx_in == &null) { return ""; }
    // Names are interned per file: a decl reached through an import must be
    // spelled with ITS OWN context, not the importing TU's.
    var ctx = NameLookup::ctx_of(d);
    if ctx == &null { ctx = ctx_in; }
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
fn sema_dump_decl_brief(ctx_in: *ASTContext, d: *Decl) -> string {
    if d == &null { return "<null>"; }
    var ctx = NameLookup::ctx_of(d);
    if ctx == &null { ctx = ctx_in; }
    var kind = sema_dump_kind_str(d->kind);
    var name = sema_dump_decl_name(ctx, d);
    var at   = sema_dump_loc(ctx, d->range.start);
    var pois = ("  [poisoned]") if (d->is_poisoned()) else ("");
    if name.size() == 0 { return f"{kind} @ {at}{pois}"; }
    return f"{kind} {name} @ {at}{pois}";
}

/// \brief Which lookup source answered, in N's own search order. The single
///        most useful column on a binding row: `local` vs `scope` vs
///        `overlay` is usually the whole explanation for a surprise.
fn sema_dump_via_str(v: TraceVia) -> string {
    switch v {
        case TraceVia::Local   { return "local";   }
        case TraceVia::Scope   { return "scope";   }
        case TraceVia::Overlay { return "import";  }
        case TraceVia::Miss    { return "miss";    }
        default                { return "";        }
    }
}

/// \brief Source-shaped word for a lexical frame.
fn sema_dump_scope_kind_str(k: TraceScopeKind) -> string {
    switch k {
        case TraceScopeKind::Function       { return "fn";      }
        case TraceScopeKind::Closure        { return "closure"; }
        case TraceScopeKind::Block          { return "block";   }
        case TraceScopeKind::ForBody        { return "for";     }
        case TraceScopeKind::CatchArm       { return "catch";   }
        case TraceScopeKind::MatchArm       { return "case";    }
        case TraceScopeKind::ContextBinding { return "with";    }
    }
    return "scope";
}

/// \brief The access operator a deferred chain step was reached through, so
///        `.x` and `::x` are told apart on sight   they are resolved by very
///        different rules in T.
fn sema_dump_sep_str(k: TraceSep) -> string {
    switch k {
        case TraceSep::Dot           { return ".";   }
        case TraceSep::Arrow         { return "->";  }
        case TraceSep::ColonColon    { return "::";  }
        case TraceSep::QuestionDot   { return "?.";  }
        case TraceSep::QuestionArrow { return "?->"; }
    }
    return ".";
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

    /// use-site SourceLocation::id -> index into sc->trace.rows. Built once
    /// in run(); empty when the trace was not recorded.
    priv var _use_index: libcxx::unordered_map::<u32, usize>;

    // Counters for the summary line.
    priv var _n_bound:      usize = 0;
    priv var _n_deferred:   usize = 0;
    priv var _n_unresolved: usize = 0;
    /// Chain steps N handed to T. Counted off the TRACE, not the AST walk:
    /// the RAV skips step names, so this walk never sees one.
    priv var _n_member:     usize = 0;
    priv var _n_ty_total:   usize = 0;
    priv var _n_ty_canon:   usize = 0;
    priv var _n_ty_dep:     usize = 0;
    priv var _n_ty_err:     usize = 0;
    
    priv var _n_step_bound: usize = 0;
    priv var _n_step_cands: usize = 0;
    priv var _n_step_open:  usize = 0;
    priv var _n_step_err:   usize = 0;

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

        self._build_use_index();

        self._dump_lang_items();
        self._dump_symbol_tables(tu);
        self._dump_chains(tu);
        self._dump_out_of_line(tu);
        self._dump_scopes();
        self._dump_bindings(tu);
        self._dump_summary();

        std::print(self._p.out);
    }

    // --- section 1: lang items --------------------------------------------

    /// Lang items are ORDINARY library decls, found by unqualified lookup at
    /// the TU root (`NameResolution::_bind_well_known`)   `i32` is a name,
    /// not an intrinsic. So a TU with no prelude in scope binds none of them,
    /// which is expected and not a failure. Thirty-odd `<unresolved>` rows
    /// read like one, though, so that case collapses to a single line.
    priv fn _dump_lang_items(self) {
        self._p.paint(Color::NodeKind, "-- lang items (well_known) --");
        self._p.newline();
        if self._lang_rows(false) == 0 {
            self._p.paint(Color::Tree, "  ");
            self._p.paint(Color::Dim,
                "(none bound: no prelude in scope for this TU   expected, not an error)");
            self._p.newline();
            return;
        }
        self._lang_rows(true);
    }

    /// The spelling table, walked twice: once to count, once to print. One
    /// list, so a lang item can never be counted and not rendered.
    priv fn _lang_rows(self, emit: bool) -> usize {
        var n: usize = 0;
        n += self._lang_row(emit, WellKnownType::Future,   "Future");
        n += self._lang_row(emit, WellKnownType::Range,    "Range");
        n += self._lang_row(emit, WellKnownType::Yield,    "Yield");
        n += self._lang_row(emit, WellKnownType::Ordering, "Ordering");
        n += self._lang_row(emit, WellKnownType::Null,     "Null");
        n += self._lang_row(emit, WellKnownType::Panic,    "Panic");

        n += self._lang_row(emit, WellKnownType::String,   "string");
        n += self._lang_row(emit, WellKnownType::Vector,   "vector");
        n += self._lang_row(emit, WellKnownType::Slice,    "slice");
        n += self._lang_row(emit, WellKnownType::Array,    "array");
        n += self._lang_row(emit, WellKnownType::HashMap,  "map");
        n += self._lang_row(emit, WellKnownType::HashSet,  "set");

        n += self._lang_row(emit, WellKnownType::BigInt,   "int");
        n += self._lang_row(emit, WellKnownType::BigFloat, "float");

        return n;
    }

    /// \return 1 when the item is bound, 0 otherwise, so the caller can decide
    ///         whether the section is worth printing at all.
    priv fn _lang_row(self, emit: bool, k: WellKnownType, spelling: string) -> usize {
        var d = self.sc->well_known.get(k);
        if !emit {
            return (1) if (d != &null) else (0);
        }
        self._p.paint(Color::Tree, "  ");
        self._p.paint(Color::TypeName, spelling);
        self._p.put("  ");
        if d == &null {
            // Not an error by itself: a lang item is only required at USE.
            self._p.paint(Color::Dim, "<unresolved>");
        } else {
            self._p.paint(Color::Operator, "-> ");
            self._p.put(sema_dump_decl_brief(self.ctx, d));
        }
        self._p.newline();
        return (1) if (d != &null) else (0);
    }

    // --- section 1b: scope symbol tables ----------------------------------

    /// Every DeclContext's FROZEN table, in full. The lexical-scopes section
    /// below cannot show these: it replays N's lexical FRAME stack, and a
    /// class body owns a table, not a frame, so `Foo` can never appear there.
    /// The chains section walks the same contexts but drops every cell of
    /// size 1, which is most of them.
    ///
    /// Without this section a member's declaration is visible only obliquely,
    /// in a shadowing note on some unrelated row   and whether member
    /// injection put the right things in the right scope is not checkable at
    /// all. This is the section you read to answer "what does Foo contain".
    priv fn _dump_symbol_tables(self, tu: *TranslationUnit) {
        self._p.paint(Color::NodeKind, "-- scope symbol tables (what each scope declares) --");
        self._p.newline();
        var n = self._tables_in(static_cast::<*DeclContext>(tu), "<tu>");
        if n == 0 {
            self._p.paint(Color::Tree, "  ");
            self._p.paint(Color::Dim, "(no scope declares anything)");
            self._p.newline();
        }
    }

    /// \return how many scopes actually printed, so the caller can say
    ///         "nothing" rather than printing a bare header.
    priv fn _tables_in(self, dc: *DeclContext, qual: string) -> usize {
        if dc == &null { return 0; }
        var printed: usize = 0;

        if dc->dc_symbols != &null {
            var rows = vec::<SymbolTable::Entry>();
            dc->dc_symbols->collect_entries(rows);
            var order = vec::<usize>();
            self._source_order(rows, order);

            if rows.size() > 0 {
                self._p.paint(Color::Tree, "  ");
                self._p.paint(Color::Keyword, qual);
                self._p.paint(Color::Dim, f"   [{rows.size()} name(s)]");
                self._p.newline();
                printed += 1;

                for var k: usize = 0; k < order.size(); ++k {
                    var i    = order[k];
                    var cell = rows[i].cell;
                    if cell == &null { continue; }
                    var name = rows[i].name.describe(self.ctx);

                    self._p.paint(Color::Tree, "    ");
                    self._p.paint(Color::Ident, self._pad(name, 12));
                    if cell->size() == 1 {
                        self._p.paint(Color::Operator, "-> ");
                        self._p.put(sema_dump_decl_brief(self.ctx, cell->get(0)));
                        self._p.newline();
                    } else {
                        // The full listing is the chains section's job; here
                        // just say the name is plural so the count adds up.
                        self._p.paint(Color::Dim, f"   [{cell->size()} decls   see chains below]");
                        self._p.newline();
                    }
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
            printed += self._tables_in(child, f"{qual}::{nm}");
        }
        return printed;
    }

    /// Table order is hash order: stable per run, but meaningless to a reader
    /// and it churns the moment a name is added. \p out receives indices into
    /// \p rows ordered by where the decl was WRITTEN, so the section reads
    /// down the source file. Permuting INDICES rather than entries keeps the
    /// sort off the entries themselves, which hold an observer into the
    /// frozen table. Insertion sort: this is one scope's table, not the TU.
    priv fn _source_order(self, rows: ref!(vec::<SymbolTable::Entry>),
                          out: ref!(vec::<usize>)) {
        for var i: usize = 0; i < rows.size(); ++i { out.push_back(i); }
        for var i: usize = 1; i < out.size(); ++i {
            var j = i;
            while (j > 0) && (self._entry_pos(rows, out[j - 1]) > self._entry_pos(rows, out[j])) {
                var tmp     = out[j - 1];
                out[j - 1]  = out[j];
                out[j]      = tmp;
                j -= 1;
            }
        }
    }

    /// Source position of a table row, for ordering. A row with no usable
    /// decl sorts last rather than first: it is the odd one out, and the top
    /// of the list is where the reader starts.
    priv fn _entry_pos(self, rows: ref!(vec::<SymbolTable::Entry>), i: usize) -> u32 {
        var cell = rows[i].cell;
        if cell == &null { return u32(-1); }
        if cell->size() == 0 { return u32(-1); }
        var d = cell->get(0);
        if d == &null { return u32(-1); }
        return d->range.start.id;
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

    // --- section 4: lexical scopes (N's decision log) ---------------------

    /// Replay sc->trace: the lexical frame tree N pushed, what each frame
    /// declared, and what every declaration and every use HID. Shadowing
    /// exists nowhere on the AST   the shadowed decl is simply never
    /// consulted   so this section is the only place it can be seen.
    priv fn _dump_scopes(self) {
        self._p.paint(Color::NodeKind, "-- lexical scopes (declarations & shadowing) --");
        self._p.newline();

        var tr = &(self.sc->trace);
        if !tr->enabled {
            // Cannot happen through the driver (the flag that prints this is
            // the flag that records it), but a programmatic caller can build a
            // SemaContext by hand; say why the section is empty rather than
            // implying the TU has no scopes.
            self._p.paint(Color::Dim, "  (trace not recorded for this run)");
            self._p.newline();
            return;
        }
        if tr->rows.empty() {
            self._p.paint(Color::Dim, "  (no lexical scopes: nothing with a body in this TU)");
            self._p.newline();
            return;
        }

        for var i: usize = 0; i < tr->rows.size(); ++i {
            var r = &(tr->rows[i]);
            switch r->kind {
                case TraceRowKind::ScopeOpen  { self._trace_scope_open(r);  }
                case TraceRowKind::ScopeClose { 0;                          }
                case TraceRowKind::Declare    { self._trace_declare(r);     }
                case TraceRowKind::Use        { self._trace_use(r);         }
                case TraceRowKind::Member     { self._trace_member(r);      }
            }
        }
    }

    /// Two spaces of lead-in plus two per frame depth, so the frame tree reads
    /// as the nesting the source has.
    priv fn _trace_indent(self, depth: usize) {
        self._p.paint(Color::Tree, "  ");
        for var i: usize = 0; i < depth; ++i { self._p.paint(Color::Tree, "  "); }
    }

    priv fn _trace_scope_open(self, r: *TraceRow) {
        self._trace_indent(r->depth);
        self._p.paint(Color::Keyword, sema_dump_scope_kind_str(r->scope_kind));
        if r->owner != &null {
            var nm = sema_dump_decl_name(self.ctx, r->owner);
            if nm.size() > 0 {
                self._p.put(" ");
                // Qualified by the table-owning scope the frame sits in, so
                // `bump` reads as `Counter::bump`. A class body owns a table,
                // not a frame, so it never gets a row of its own here.
                var home = self._dc_label(r->enclosing);
                if (home.size() > 0) && (home != "<tu>") {
                    self._p.paint(Color::Ident, f"{home}::{nm}");
                } else {
                    self._p.paint(Color::Ident, nm);
                }
            }
        }
        self._p.paint(Color::Dim, f"  @ {sema_dump_loc(self.ctx, r->at.start)}");
        self._p.newline();
    }

    priv fn _trace_declare(self, r: *TraceRow) {
        self._trace_indent(r->depth);
        self._p.paint(Color::Attr, "declare ");
        self._p.paint(Color::Ident, self._pad(self._imm_name(r->name), 12));
        self._p.paint(Color::Operator, "= ");
        self._p.put(sema_dump_decl_brief(self.ctx, r->decl));
        self._trace_shadow_note(r);
        self._p.newline();
    }

    priv fn _trace_use(self, r: *TraceRow) {
        self._trace_indent(r->depth);
        self._p.paint(Color::Operator, "use     ");
        self._p.paint(Color::Ident, self._pad(self._imm_name(r->name), 12));
        self._p.paint(Color::Dim,
            self._pad(f"@ {sema_dump_loc(self.ctx, r->at.start)}", 10));
        self._p.put(" ");

        if r->via == TraceVia::Miss {
            self._p.paint(Color::Error, "<UNRESOLVED>");
            self._p.paint(Color::Dim, "  (diagnosed: no such name in any scope)");
            self._p.newline();
            return;
        }

        self._p.paint(Color::Operator, "-> ");
        if r->decl != &null {
            self._p.put(sema_dump_decl_brief(self.ctx, r->decl));
        } else if r->cell_size > 0 {
            self._p.paint(Color::Dim, f"{r->cell_size} candidate(s), deferred to overload resolution");
        } else {
            self._p.paint(Color::Error, "<nothing>");
        }

        self._p.paint(Color::Dim, f"  [{self._via_label(r)}]");
        if r->poisoned { self._p.paint(Color::Error, "  (diagnosed)"); }
        self._trace_shadow_note(r);
        self._p.newline();
    }

    /// A chain step. N recorded it as deferred; ChainBinding (after T) may
    /// have decided it. Join the outcome by location so the row stays where
    /// N put it, in source order.
    priv fn _trace_member(self, r: *TraceRow) {
        self._trace_indent(r->depth);
        self._p.paint(Color::Operator, "member  ");

        var sep = sema_dump_sep_str(r->sep);
        var txt = f"{sep}<?>";
        switch r->member_kind {
            case TraceMemberKind::Name       { txt = f"{sep}{self._imm_name(r->name)}"; }
            case TraceMemberKind::TupleIndex { txt = f"{sep}{r->index}";                }
            case TraceMemberKind::Operator   { txt = f"{sep}<operator>";                }
        }
        self._p.paint(Color::Ident, self._pad(txt, 12));
        self._p.paint(Color::Dim,
            self._pad(f"@ {sema_dump_loc(self.ctx, r->at.start)}", 10));
        self._p.put(" ");

        var mr = self.sc->trace.member_result_for(r->at.start.id);
        if mr == &null {
            // ChainBinding never ran: the honest pre-T reading.
            if r->sep == TraceSep::ColonColon {
                self._p.paint(Color::Dim, "<deferred: needs the scope named by the base   ChainBinding>");
            } else {
                self._p.paint(Color::Dim, "<deferred: needs the type of the base   ChainBinding>");
            }
            self._p.newline();
            return;
        }

        var _where = "";
        if mr->found_in != &null { _where = f"  [member of {sema_dump_decl_name(self.ctx, mr->found_in)}]"; }

        switch mr->outcome {
            case MemberOutcome::Bound {
                self._p.paint(Color::Operator, "-> ");
                self._p.put(sema_dump_decl_brief(self.ctx, mr->decl));
                self._p.paint(Color::Dim, _where);
            }
            case MemberOutcome::Candidates {
                self._p.paint(Color::Operator, "-> ");
                self._p.paint(Color::Dim, f"{mr->ncand} candidate(s), awaiting overload resolution{_where}");
            }
            case MemberOutcome::NeedsInference {
                self._p.paint(Color::Dim, "<deferred: base type is inferred   TypeInference>");
            }
            case MemberOutcome::Dependent {
                self._p.paint(Color::Dim, "<dependent: rooted in a generic parameter   M2>");
            }
            case MemberOutcome::Errored {
                self._p.paint(Color::Error, "<UNRESOLVED>");
                self._p.paint(Color::Dim, "  (diagnosed)");
            }
            default {
                self._p.paint(Color::Dim, "<deferred>");
            }
        }
        self._p.newline();
    }

    /// `local frame 2` / `scope Foo` / `import overlay`   _WHERE the answer
    /// came from, named the way the reader thinks about it.
    priv fn _via_label(self, r: *TraceRow) -> string {
        switch r->via {
            case TraceVia::Local {
                if r->frame == usize(-1) { return "local"; }
                return f"local frame {r->frame}";
            }
            case TraceVia::Scope   { return f"scope {self._dc_label(r->found_in)}"; }
            case TraceVia::Overlay { return "import overlay";                       }
            case TraceVia::Miss    { return "miss";                                 }
            default                { return "?";                                    }
        }
    }

    /// The whole point of the section: name the decl this one hid, and say
    /// which source it lived in, so "why did it pick THAT one" has an answer
    /// on the same line.
    priv fn _trace_shadow_note(self, r: *TraceRow) {
        if r->shadowed == &null { return; }
        self._p.paint(Color::Attr,
            f"  (shadows {sema_dump_decl_brief(self.ctx, r->shadowed)}");
        // Where the loser lived. A named scope beats the bare source word:
        // "in Counter" answers the follow-up question that "via scope" only
        // raises.
        if r->shadowed_via == TraceVia::Scope {
            self._p.paint(Color::Attr, f" in {self._dc_label(r->shadowed_found_in)}");
        } else if r->shadowed_via == TraceVia::Overlay {
            self._p.paint(Color::Attr, " from an import");
        } else if r->shadowed_via == TraceVia::Local {
            self._p.paint(Color::Attr, " in an enclosing frame");
        }
        self._p.paint(Color::Attr, ")");
    }

    /// Right-pad to a fixed column so the `-> target` arrows line up down the
    /// section. Names longer than the column push their row out rather than
    /// being truncated (a clipped identifier is worse than a ragged column),
    /// but they still get ONE space   without it `wildcard_target@ 98:13`
    /// runs the name into the location that follows it.
    priv fn _pad(self, s: string, w: usize) -> string {
        var out = s;
        if s.size() >= w { return out + " "; }
        for var i: usize = s.size(); i < w; ++i { out += " "; }
        return out;
    }

    priv fn _imm_name(self, imm: u32) -> string {
        if imm == u32(-1) { return "<?>"; }
        return self.sc->imm_table()->get_ident(imm);
    }

    /// Index the trace's Use rows by source location so the AST-walk section
    /// below can show the same provenance without re-running lookup. A use
    /// site is unique by location, so `SourceLocation::id` is a sufficient
    /// key; built once because the alternative is a scan per use, which is
    /// quadratic on exactly the large files this tool is used on.
    priv fn _build_use_index(self) {
        var tr = &(self.sc->trace);
        if !tr->enabled { return; }
        for var i: usize = 0; i < tr->rows.size(); ++i {
            if tr->rows[i].kind == TraceRowKind::Member {
                self._n_member += 1;
                continue;
            }
            if tr->rows[i].kind != TraceRowKind::Use { continue; }
            self._use_index[tr->rows[i].at.start.id] = i;
        }
    }

    priv fn _trace_use_for(self, loc: SourceLocation) -> *TraceRow {
        var tr = &(self.sc->trace);
        if !tr->enabled { return &null; }
        var it = self._use_index.find(loc.id);
        if it == self._use_index.end() { return &null; }
        return &(tr->rows[it->second]);
    }

    // --- section 5 + 6: bindings and types (one walk) ---------------------

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
        self._p.paint(Color::Ident, self._pad(nm, 12));
        self._p.paint(Color::Dim,
            self._pad(f"@ {sema_dump_loc(self.ctx, n->range.start)}", 10));
        self._p.put(" ");

        // The trace row for this exact use, when N recorded one. Its absence
        // on a BOUND node is itself information: the node was bound by
        // something other than N(b)'s use path (N(a)'s qualifier walk, or a
        // previous run over the same AST).
        var tr = self._trace_use_for(n->range.start);

        if n->is_bound() {
            self._n_bound += 1;
            self._p.paint(Color::Operator, "-> ");
            self._p.put(sema_dump_decl_brief(self.ctx, n->resolved_decl));
            if tr != &null {
                self._p.paint(Color::Dim, f"  [{self._via_label(tr)}]");
                self._trace_shadow_note(tr);
            } else {
                self._p.paint(Color::Dim, "  [pre-bound: not resolved by N(b)]");
            }
            self._p.newline();
        } else if n->is_deferred() {
            self._n_deferred += 1;
            var cell = n->candidate_cell;
            self._p.paint(Color::Operator, "-> ");
            self._p.paint(Color::Dim, f"{cell->size()} candidate(s), awaiting overload resolution");
            if tr != &null { self._p.paint(Color::Dim, f"  [{self._via_label(tr)}]"); }
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
        if n->is_poisoned() { self._n_ty_err += 1; }
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

    /// A closure body is its own scope for the reader even though it owns no
    /// DeclContext, and without this its uses are filed under the enclosing
    /// function   which is exactly the row you are staring at when a capture
    /// bound to the wrong thing.
    fn traverse_closure_expr(self, n: *ClosureExpr) -> *ClosureExpr {
        if n == &null { return n; }
        var saved = self._scope;
        self._scope = f"{self._scope}::<closure @ {sema_dump_loc(self.ctx, n->range.start)}>";
        var out = RecursiveASTVisitor_SemaDump::traverse_closure_expr(n);
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

    /// The RAV skips step names; print them from AST state so the FINAL
    /// binding of every step is visible here, not only N's decision log.
    fn traverse_chain_expr(self, n: *ChainExpr) -> *ChainExpr {
        if n == &null { return n; }
        var out = RecursiveASTVisitor_SemaDump::traverse_chain_expr(n);
        for var i: usize = 0; i < n->steps.size(); ++i {
            var st = n->steps.get(i);
            if (st == &null) || (st->name == &null) { continue; }
            self._scope_header();
            var sep = ".";
            switch st->access_kind {
                case ChainExpr::AccessKind::Arrow         { sep = "->";  }
                case ChainExpr::AccessKind::ColonColon    { sep = "::";  }
                case ChainExpr::AccessKind::QuestionDot   { sep = "?.";  }
                case ChainExpr::AccessKind::QuestionArrow { sep = "?->"; }
                default                                   { sep = ".";   }
            }
            var nm = f"{sep}{self.ctx->get_spelling(st->name->name)}";
            self._p.paint(Color::Tree, "    ");
            self._p.paint(Color::Ident, self._pad(nm, 12));
            self._p.paint(Color::Dim,
                self._pad(f"@ {sema_dump_loc(self.ctx, st->name->range.start)}", 10));
            self._p.put(" ");
            if st->resolved_decl != &null {
                self._n_step_bound += 1;
                self._p.paint(Color::Operator, "-> ");
                self._p.put(sema_dump_decl_brief(self.ctx, st->resolved_decl));
            } else if st->candidate_cell != &null {
                self._n_step_cands += 1;
                self._p.paint(Color::Operator, "-> ");
                self._p.paint(Color::Dim, f"{st->candidate_cell->size()} candidate(s), awaiting overload resolution");
            } else if st->name->is_poisoned() {
                self._n_step_err += 1;
                self._p.paint(Color::Error, "<UNRESOLVED>");
                self._p.paint(Color::Dim, "  (diagnosed)");
            } else {
                self._n_step_open += 1;
                self._p.paint(Color::Dim, "<open: inference or M2>");
            }
            self._p.newline();
        }
        return out;
    }

    // --- section 6 + summary ----------------------------------------------

    priv fn _dump_summary(self) {

        self._p.paint(Color::NodeKind, "-- types --");
        self._p.newline();
        self._p.paint(Color::Tree, "  ");
        self._p.put(f"{self._n_ty_total} type node(s): ");
        self._p.put(f"{self._n_ty_canon} canonical, ");
        self._p.put(f"{self._n_ty_dep} dependent, ");
        self._p.put(f"{self._n_ty_err} errored");
        self._p.newline();
        if (self._n_ty_total > 0) && (self._n_ty_canon == 0)
        && (static_cast::<u8>(self.sc->phase) < static_cast::<u8>(SemaPhase::TypesResolved)) {
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

        // A SEPARATE figure, not folded into `deferred`. The two defer for
        // unrelated reasons   an overload set waits on argument types, a
        // member waits on the base's type   and a reader chasing one is not
        // helped by a number that could be either.
        var steps = self._n_step_bound + self._n_step_cands + self._n_step_open + self._n_step_err;
        if steps > 0 {
            self._p.paint(Color::Tree, "  ");
            self._p.put(f"{steps} chain step(s): {self._n_step_bound} bound, ");
            self._p.put(f"{self._n_step_cands} overload sets, {self._n_step_open} open");
            if self._n_step_err > 0 { self._p.paint(Color::Error, f", {self._n_step_err} unresolved"); }
            self._p.newline();
        }
    }
}
