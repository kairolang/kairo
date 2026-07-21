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

IMPLEMENTED: AST/Context/SymbolTable.k (DeclName, OverloadCell,
SymbolTable), wired into DeclContext::dc_symbols + TranslationUnit::
{out_of_line, import_overlay}, populated by ASTParse::_build_symbols.

```
class SymbolTable {                    // one per DeclContext (TU, module, type)
    var cells:  map<u64, OverloadCell> // key: DeclName::as_key()
    var frozen: bool = false

    fn append(name: DeclName, d: *Decl)  // parse-time only; asserts !frozen
    fn lookup(name: DeclName) -> *OverloadCell
    fn freeze(self)
}

// DeclName = kind:u8 + payload:u32, packed to u64:
//   Identifier(imm)   payload = this TU's imm ident index
//   Operator(k0,k1)   payload = packed op-token kinds (stable cross-TU)
//   Constructor       payload = 0; CONTEXT-RELATIVE: the queried type
//                     scope identifies the type, the key carries none.
//                     (fn in a type scope named == the type keys here.)
//   Destructor        reserved; `fn op delete` keys as Operator for now.
// Names stay pure name-domain: constructing a DeclName never needs type
// info, so name res never waits on type res.

class OverloadCell {                   // SmallVec<*Decl, 1> in spirit
    var first: *Decl                   // inline; most names bind one decl
    var rest:  vec<*Decl>              // overload sets / fwd+def stacks
}

// wired in:
// DeclContext      += var dc_symbols:     *SymbolTable  [done]
// TranslationUnit  += var out_of_line:    ArenaList<*Decl>  // *FunctionDecl;
//                     typed *Decl to dodge a stage0 import cycle  [done]
// TranslationUnit  += var import_overlay: *SymbolTable  // built by phase I
```

- **Keys** are per-TU `u32` ident imms already interned, integer hash,
  no string compares on the hot path. Cross-TU keys never mix: import
  folding re-interns each imported name into the importing TU's imm space
  once (string translation at fold time, cached), integer lookups after.
  Operator keys are the one exception they pack TokenKinds, which are
  build-stable, so ADL may compare them cross-TU directly.
- **Extension members** land in the ExtensionDecl's OWN table at parse
  time (zero judgment). Folding them into the target type's lookup and
  rewriting `semantic_dc` is sema's job (ExtensionLowering / N).
- **Enum variants** are keyed into the enum's table by the build walk
  (they live in `variants`, not dc_decls) so `Direction::North` resolves
  per segment like any qualified name.
- **Dual-context links**: every indexed decl gets `lexical_dc` (where
  written) and `semantic_dc` (lookup home) stamped, Clang's lexical-vs-
  semantic DeclContext model. `extend`/anon-module members are the case
  where they diverge; out-of-line defs get semantic_dc = null until N(a)
  attaches them.
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

### Population (parser-owned) [IMPLEMENTED]

`ASTParse::_build_symbols()` runs at the end of `parse()`, right after
`_wire_scopes`: one walk over the completed TU appending every named decl
to its enclosing DC's table. Top-level `var`/`const` route through the
stmt path (DeclStmt) and never hit tu->dc_decls, so the walk also sweeps
program->items for TU-level DeclStmts. Rules:

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

## 2b. Member lookup & OOP (decided; not yet implemented)

These rules are LOCKED so MemberLookup can be written without re-litigating
them. None of it lives in NameLookup's four core primitives NameLookup is
the name-res floor (single scope, unqualified parent-chain, decl->context,
one qualified segment) and genuinely does not walk bases. OOP adds
components ABOVE it, each at its correct phase.

**Name hiding: MERGE, not hide (Java/C#-style, NOT C++).**
A derived member named `foo` with a DIFFERENT signature does NOT hide base
`foo` overloads; it joins them. `member_lookup(type, name)` walks the WHOLE
inheritance DAG (+ folded extensions + interface defaults), UNIONS every
matching cell into one candidate set (dedup across virtual bases), and
hands it to overload resolution. Only a SAME-signature derived method
replaces a base one and that is overriding, a separate concept.
Rationale: C++ hiding + `using Base::foo;` boilerplate is the single most
complained-about member-lookup rule; merge is what `d.foo()` is expected to
do, and it reuses OverloadCell / candidate_cell unchanged.

**Consequence for C++ codegen (the reason this is written down now).**
Codegen emits C++ tokens, where the DEFAULT is hiding. So wherever Kairo
merged base overloads that C++ would hide, the C++ output needs a
synthesized `using Base::name;`. Contract:
  - MemberLookup is the ONE writer. When it unions a base/extension/
    interface cell into a derived type's candidate set WITHOUT the derived
    type overriding it, it records `(source_decl, name)` on the type's
    `needs_using` list. It does NOT re-walk bases anywhere else.
  - UsingDeclSynthesis (a LOWERING pass, _stage_lowerings) is the ONE
    consumer. It reads `needs_using` and emits implicit UsingDecl nodes
    (is_implicit = true). ZERO re-analysis, zero base-walking.
  - Codegen emits `using Base::name;` for implicit UsingDecls and stays a
    dumb walker.
  - Record condition is EXACTLY: base has overloads of this name that the
    derived type does not override. Overriding (same sig) or no-clash names
    need no `using` a synthesized one there is noise or (with override)
    actively wrong. Inheritance, `extend`, and interface defaults all route
    through the SAME `needs_using` list one synthesis pass, not three.

Requires (additive, deferred until MemberLookup is written): a `UsingDecl`
node + DeclKind (synthesis-only, no parse grammar) and a `needs_using` slot
on the type decls. Neither exists yet; adding them changes nothing built.

**Virtual dispatch is NOT a lookup problem.** virtual/override/final
(AbiKind) drive vtable layout + override-signature checking + an
`overrides: *FunctionDecl` link, all AFTER member lookup, keyed on
signature comparison. Name res binds a CALL to a member; which body runs is
dispatch, decided later. Never resolve overrides during member lookup.

**Access control is a late FILTER, never a lookup key.** Lookup finds the
member regardless of pub/prot/priv, THEN an access check rejects it with a
precise diagnostic ("foo is private to Bar"). Filtering in the table yields
"no member named foo" when the truth is "foo exists, you can't touch it".
`prot` needs member-lookup's base-walk provenance, so it rides on that
component, not on the cell.

Base-walk PRE: T complete `derives Bar<i32>` is a ChainType until T
canonicalizes it, so member lookup cannot walk bases before types resolve.

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
6. One writer per fact. resolved_decl/candidate_cell: written by N,
   cell->decl promoted by inference, nobody else. needs_using: written by
   MemberLookup, read by UsingDeclSynthesis, nobody else. A fact recomputed
   in two places drifts a fact recorded once and read does not. When a
   later pass wants an earlier pass's finding, it reads a node slot or a
   registry never re-derives it, never reaches into the earlier pass.
