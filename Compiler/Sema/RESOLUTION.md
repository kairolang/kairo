# Symbol tables & the resolution pipeline

Design doc for the TU symbol table and the ordering contract between
ImportResolution, NameResolution, and TypeResolution. This is the third
and only REAL symbol table in the compiler. The other two are phase
artifacts and stay untouched: DisambigTable answers one boolean for the
parser pre-parse; the macro table belongs to the PP.

---

## 1. Symbol table data structure

Principle: **the AST is the trie; tables are per-DeclContext leaf maps.**
No parallel scope tree. DisambigTable's mirror-trie needed `_wire_scopes`
to reconcile two structures; this design has nothing to reconcile.

```
class SymbolTable {                    // one per DeclContext (TU, module, type)
    var cells:  map<u32, OverloadCell> // key: ident imm (this TU's ImmediateTable)
    var frozen: bool = false

    fn append(imm: u32, d: *Decl)      // parse-time only; asserts !frozen
    fn lookup(imm: u32) -> *OverloadCell
    fn freeze(self)
}

struct OverloadCell {                  // SmallVec<*Decl, 1> inline
    // most names bind exactly one decl; fns may hold overload sets;
    // pre-NameResolution a cell may also hold fwd-decl + definition
    // (raw, unlinked - see phase N below)
}

// additions elsewhere:
// DeclContext      += var dc_symbols:     *SymbolTable
// TranslationUnit  += var out_of_line:    vec<*FunctionDecl>  // `fn Class::method`
// TranslationUnit  += var import_overlay: *SymbolTable        // built by phase I
```

- **Keys** are per-TU `u32` ident imms already interned, integer hash,
  no string compares on the hot path. Cross-TU keys never mix: import
  folding re-interns each imported name into the importing TU's imm space
  once (string translation at fold time, cached), integer lookups after.
- **Qualified lookup** (`Outer::Inner::make`): resolve `Outer` in the
  current table, follow the decl's `->dc_symbols`, repeat per segment.
  No children map a child scope is reached THROUGH its decl.
- **Unqualified lookup**: this DC's table, then the DC parent chain
  (which already exists), then `import_overlay` at TU level, then miss.
- **Anonymous scopes** (anon modules, vis groups, eval blocks) get no
  table; their decls land in the enclosing DC's table.
- **Excluded**: locals and params. This table is decl-level only. Body
  resolution walks its own lexical stack; params come off the
  FunctionDecl signature.
- **Container**: back with `libcxx::unordered_map<u32, OverloadCell>`
  now. The API above is the contract; a flat open-addressing u32 map can
  replace the container later without touching any caller. Ownership and
  lifetime (arena-allocated with the AST, frozen at parse exit) are the
  unchangeable part get those right first.

### Population (parser-owned)

`ASTParse::_build_symbols()` runs at the end of `parse()`, next to
`_wire_scopes`: one walk over the completed TU appending every named decl
to its enclosing DC's table. Rules:

- append-only multimap, ZERO diagnostics, ZERO judgment. Duplicate
  names, fwd-decl + def, primaries + specializations: all just stack in
  the cell. The parser records; sema judges.
- `fn Class::method` out-of-line defs go to `tu->out_of_line`, not any
  table (attachment is a name-resolution job).
- after the walk: `freeze()` every table. Parse exit = tables immutable.

One walk (not per-production hooks) so methods lists, fields, and nested
decls are caught uniformly and there is exactly one place to audit.

---

## 2. Pipeline order and invariants

```
P:  parse (per TU, parallel)      -> AST + frozen SymbolTables
I:  ImportResolution (per TU)     -> import_overlay built
N:  NameResolution (per TU, parallel)  -> every ident/type-name bound
T:  TypeResolution (per TU, parallel)  -> every Type node canonical
M1: Mono usage collection (parallel)   |  downstream, for context
M2: Mono instantiate + conformance (sync)
```

**P parse.**
POST: every DC has a frozen table; `out_of_line` collected; no
diagnostics emitted from table building.
INVARIANT: frozen tables are never mutated again by ANY later phase.
Later phases add links on NODES (redecl chains), overlays, or separate
registries (instantiations) never entries in source tables.

**I ImportResolution.**
PRE: all imported TUs are parsed and frozen (reading a foreign frozen
table is read-only and thread-safe; ordering is import-DAG order, same
begin/finish discipline as GlobalDisambigTable).
JOB: for each import, verify the imported symbols exist in the source
TU's frozen table (selective imports error here, nowhere else); fold
them into this TU's `import_overlay`, re-interned into this TU's imm
space; dedup; overlay collision = ambiguous-import error, reported here,
nowhere else.
POST: every name visible in this TU is findable in local tables or the
overlay. The TU is now SELF-CONTAINED: no later phase touches another
TU until M2.

**N NameResolution.** Two halves, one pass.
(a) Decl validation over the frozen cells: link `Redeclarable` chains
(fwd decl <-> definition), validate overload sets, group specializations
under their primary, emit redefinition and specialization-without-primary
errors. Attach `out_of_line` defs to their owning type's decl.
(b) Binding: every `NamedIdentExpr` / chain step / pattern head gets its
`resolved_decl` set local lexical stack first, then DC chain, then
overlay. Rule-4 diagnostics land here ("X takes no generic arguments"
when a generic-shaped use bound to a non-generic decl).
PRE: I complete (else imported names are spurious unresolved errors).
POST: no unresolved idents survive except inside generic bodies where the
name is rooted in a type param (dependent deferred to M2 by design).
INVARIANT: N sets `resolved_decl` links; it never creates types and never
reasons about type compatibility.

**T TypeResolution.**
JOB: every `Type` node (ChainType etc.) becomes canonical: type-name ->
decl via the same lookup core as N(b), generic-arg arity checked against
the primary, aliases expanded, `spec_kind` refinement finished
(single-ident spec arg resolving to a type param of the primary keeps
Primary/partial semantics; resolving to a concrete type downgrades to
Explicit closes #68).
PRE: N complete (type names bind through the same tables and need redecl
chains linked).
POST: every non-dependent Type node has a canonical type; dependent types
(rooted in a type param) are MARKED dependent, not resolved.
INVARIANT: T assigns types to type NODES only. Typing expressions
(inference, coercion, operator resolution) is TypeInference/M2 territory,
not T.

N and T may be fused into one pass over the tree later (they share the
lookup core); the ORDERING CONTRACT between their jobs stays even if the
pass boundary disappears.

---

## 3. Hard invariants (the ones that break silently if violated)

1. Frozen means frozen. Post-parse, source tables take no inserts.
   Overlays, node links, and registries are the only growth points.
2. One key space per TU. A u32 imm from TU A never indexes a table of
   TU B; folding re-interns.
3. One error, one home. Import existence errors: phase I. Redefinition /
   spec-without-primary: N(a). Unresolved ident: N(b). Arity /
   unknown-type-name: T. Dependent conformance: M2. No phase re-checks
   another's territory.
4. Parallelism boundary: P, N, T, M1 are embarrassingly parallel per TU.
   I is import-DAG-ordered. M2 is the only sync point.
5. Dependent = deferred, not failed. Anything rooted in a type param is
   marked and skipped by N/T; M2 owns it. N/T must never error on a
   dependent name.
