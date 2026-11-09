# Member lookup

`Compiler/Sema/Resolve/MemberLookup.k` answers "which declarations named `n` are reachable from canonical type `T`": the type's own table, the extensions that target it, and its bases. It returns a candidate set and nothing more. Overload selection and hiding are [ExprTyping.md](ExprTyping.md#overload-resolution)'s, access is AccessCheck's ([SemanticChecks.md](SemanticChecks.md#check-passes)), and binding a chain step to the result is ChainBinding's ([TypeResolution.md](TypeResolution.md#chain-binding)). It requires T to be complete for the types it walks (base types must be canonical).

## Member lookup

### The walk

`MemberLookup::lookup(canonical, name, out)` appends, in this order, deduped by identity:

0. For an instance of an imported template whose table is still empty: `ForeignInstantiate::fill` asks clang to fill it first. A failed fill is sticky and leaves the instance on its pattern.
1. The record's own table. An anonymous union field's members are not injected and are never found by name; only compiler-minted `field_of` chains reach them.
2. Extensions on this exact declaration and on the primary it is an instance of, so `extend <T> Vec<T>` contributes to `Vec<i32>` whether that instance is implicit or a user-written specialization. 2b. An implicit instance nobody has filled has an empty table and base list; the names it will have are its pattern's, so the pattern is walked: the primary, or the partial specialization the registry selected (`SemaContext::body_of`, [Generics.md](Generics.md#instantiation-registry)). A dependent use such as `Store<*P>` selects the partial the same way (`SemaContext::record_body`), its parameters opaque.
3. Bases, breadth-first.

A non-record type (`i32`, `[u8]`, `*T`) has only its extensions.

**Merge, not hide.** A derived member named `foo` does not hide the base's `foo` overloads; the walk unions every matching cell. That is C++'s lookup with a `using Base::foo;` in the derived class, and the emitted class carries exactly that for every method name it shares with a base (`InterfaceEmitter::_base_usings`, [Inheritance](#inheritance)), so C++'s overload set is Kairo's. OverloadResolution then applies the using-declaration's rule ([namespace.udecl]/14) to the merged set (`_hide`): a base method that a derived method with the same parameters and `self` constness overrides or hides is no candidate, so `d.k()` on an override is D's, not an SC064E tie.

Exceptions to the merge:

- A field or nested type the class declares hides a base's of the same name, as in C++; no `using` can merge two fields, and the emitted class hides the same way. Only overload sets merge.
- An imported class hides as C++ does ([class.member.lookup]): a name its own table answers stops the walk there, unless the header merges the base's name back with a using-declaration (`ClassDecl::ffi_usings`, DeclImport). Operators hide the same way ([over.match.oper]/3.1); since an operator has no spelling, any `using B::operator@;` in the class keeps all its operators merged.

**Interfaces.** An interface's names are answered from its composed requirement list (`InterfaceDecl::requirements`, [Interfaces.md](Interfaces.md#interface-algebra)), never from its table plus a walk of its `derives` edges, which would answer `X - Y` with Y's members. The interfaces a record's `impl` clause names are not walked: an interface has no default bodies, so each requirement is met by a member the walk already finds, and offering the bodiless requirement beside it made every direct call `x.f()` an SC064E tie. A bounded receiver reaches requirements through its bounds ([Interfaces.md](Interfaces.md#associated-types)).

**Conformance methods are ordinary members.** `v.push(x)` resolves the member that implements `VectorI::push` like any other member. Two interfaces both declaring `push` on one type collide at the use. The qualified form (`VectorI::push(v, x)`) resolves through the requirement's declaring instance ([ExprTyping.md](ExprTyping.md#receiver-seeding)); the ambiguity diagnostic does not suggest it.

### Argument-dependent lookup

`MemberLookup::associated_scopes(t)` gives the scopes an operator's operand or an unqualified call's argument associates: the enclosing modules of the type's declaration up to, not including, the TU (`_enclosing_modules`). Pointers, references and nullables are peeled; generic arguments recurse. For a C++ namespace every reopening is searched, not only the block the record sits in (libc++ declares `__wrap_iter`'s operators in a different `namespace std { }` block from the class).

Stopping at the TU is deliberate: a Kairo file's top level is its own module, and including it would make every free function in the declaring file an ADL candidate wherever the type is used. The consequence for C++ is that a type in the global namespace associates no scope, so a global `operator<<` for it is not found by ADL.

`MemberLookup::declaring_scope(t)` adds, for operator lookup only, the file scope the record was declared in: an operator is the one thing a file declares for its types, and without it a free `op *` beside a file-scope type is unreachable from every file. `adl_candidates` collects the functions named `n` in those scopes, minus what member lookup already found. How the typer combines the sets is [ExprTyping.md](ExprTyping.md#expression-typing) (Operators, Calls).

### Imported using-declarations

A namespace-scope using-declaration in a header (`namespace std { using ::sqrt; }`, libc++'s `<cmath>`) is handled as a binding: `HeaderIndex::walk_declare` hands each such `UsingShadowDecl` to `DeclImport::declare_using`, which binds the target's one Kairo declaration in the namespace's table as well as its home's, so `cxx::std::sqrt` finds `::sqrt`. Class-scope shadows stay `ffi_usings` only; binding them too would tie overloads. File-scope shadows are skipped. The stated reason, an untyped float literal tying f32 / f64 overloads, was resolved by the f64 tiebreak, but the exclusion is still in place.

## Extensions

### The index

`MemberLookup::index_extensions` indexes every `ExtensionDecl` of every parsed TU once per run (inside modules, visibility groups and eval blocks too):

- a record target is keyed by `RecordType::decl` (the primary for a dependent target such as `extend <T> Vec<T>`), so at name level a generic extension contributes to every instance; which instance's body runs is decided later;
- any other target (`extend i32`, `extend [u8]`) is keyed by its exact canonical pointer.

An extension whose target has no canonical (errored, or in a TU whose T has not run yet) is skipped.

### Visibility

Design rule: an extension contributes to a TU's lookup iff its file is in that TU's transitive import set (its own file, the builtin subtree, and every file its import edges reach), applied as one filter in `_index_decl`. Conformance applies it already (ConformanceChecking `_usable` / `_sees`, [Interfaces.md](Interfaces.md#conformance)). Member and operator lookup do not: the index is build-wide, so `import std::Vec` only gets the file into the build, and two libraries both adding `push` make every `v.push` ambiguous. The index is also order-dependent, since it skips a TU whose T has not run yet.

### Rules on `extend`

Design rules, not implemented:

- **Orphan rule** (planned `ExtensionOrphanCheck`, check stage, after T). A plain `extend X` must be in X's file; `extend X impl I` may be in X's file or I's file. Keyed on `RecordType::decl` of the target (an explicit specialization's extend lives in the specialization's file; an implicit instance's in the primary's). A rejected extend is poisoned so the index skips it. Reopened modules do not relax it (file, not module), and an imported C++ type can never be plain-extended.
- **Impl-only rule** (ConformanceChecking). An `impl` extend may contain only the interface's members; otherwise `interface Dummy {}` in any file would reopen every cross-file conflict the orphan rule prevents.

### Emitted shape

Every extension member of target X declared in namespace N (the file's module path plus enclosing module blocks) is a static member of `struct N::__kairo_ext_X`, one struct per (N, X), every extend block in that scope contributing:

- X is the target's leaf when the target is declared in N (nested owners joined with `__`: `__kairo_ext_Outer__Inner`), and its full path joined with `__` otherwise (`__kairo_ext_a__Point`), since an `impl` extend in an interface's file can target two modules' `Point`s. A generic record is named by its primary, a builtin by its Kairo spelling (`__kairo_ext_i32`). The name depends on the source tree alone.
- The struct is always complete, private members included, in the preamble and the header alike, and all of it is public in C++: visibility is AccessCheck's, and the struct is one text everywhere.
- The receiver is explicit: `extend Foo { fn m(self) }` is `__kairo_ext_Foo::m(Foo*)`, `fn f(self) const` takes `const Self*`, and `a.push(19)` is `::std::__kairo_ext_Vec::push(&a, 19)`, qualified from `resolved_decl`. ExtensionLowering rewrites the calls ([Lowering.md](Lowering.md#extensionlowering)); a prvalue receiver is materialized (`__kairo_tmp`) and lives to the end of the full-expression.
- Extension methods are never virtual, never `override`, never a constructor. Record extends follow the same rule.
- An extension operator takes `X&` / `const X&`, and its body rebinds `self` to the reference's address. A static member cannot be an `operator+`, so it is named by mnemonic (`LowerTargets::ext_op`: `__kairo_op_plus`, `__kairo_op_preinc`, ...; `in`, `^^`, `await`, `spawn`, `thread` keep their LowerTargets names), and every Kairo use is an explicit call to it. Beside the scope, each extension operator C++ can spell gets an inline namespace-scope `operator<sym>` forwarding every operand to the static member ([over.oper]/7 needs the class-typed parameter, and a C++ consumer can then write `-x`); the postfix `int` dummy is forwarded as is.

**Friendship.** The type's emitted definition carries one `friend struct ::N::__kairo_ext_X;` per extension scope in the type's own file (usually one; `module Geo { extend Point {...} }` beside a file-scope extend is two), so those members see `priv`. An `impl` extend in the interface's file gets its own scope in that file's namespace, is not a friend, and sees only public members. The friend list is closed at the file, so a class definition is byte-identical in every TU, library builds cache, and an extend added downstream rebuilds nothing upstream. EmitPlan forward-declares a class's same-file scope in tier 0 when the class is Complete, since a qualified friend needs a prior declaration ([Codegen.md](Codegen.md#emitplan)).

**Builtin declares, std extends.** `Lib/builtin` declares every lang item with fields and constructors only; std adds methods through `extend` in its own files. Nothing is FFI-backed: the C++ spelling of `Vector<T>` is derived from its declaration like any record's. A builtin type's representation is therefore public API. The root is built this way; std is not yet complete.

**Generic bodies.** A generic body emits once as a C++ template, and ADL searches the type's namespace, not the extension's, so a call bound through an interface bound goes through the interface's witness class template (`VectorI_witness<T, ...>::push(&x, 1)`). The typer binds such a call to the requirement declaration; the C++ shape is [Witnesses.md](Witnesses.md#the-c-shape) and the conformance rows it needs are [Interfaces.md](Interfaces.md#conformance).

## Inheritance

`Substitution::derives_from(derived, base)` is derived-to-base on canonical types, used by every implicit upcast, `as`, and the downcast hint; an instance's bases are its body's declared list with its arguments substituted ([Generics.md](Generics.md#instantiation-model)).

InterfaceEmitter writes `using Base::name;` for every method name a class shares with a base (`needs_using`, `InterfaceEmitter::_base_usings`), straight from the declarations; no slot is recorded and no lowering pass is involved. This is what makes the merged lookup above C++'s lookup.

`derives virtual A` sets `InheritEdge::is_virtual` and is emitted as a virtual base; the walk dedups across virtual bases. A method whose ABI kind is `Virtual` or `Override` is emitted `virtual` (pure when its body kind is `Virtual`). C++'s `override` is not emitted, so clang's "overrides a member function but is not marked 'override'" warning reaches the user.

Access control is AccessCheck, a filter after X ([SemanticChecks.md](SemanticChecks.md#check-passes)). A call to an extension member found on a base gets an explicit upcast from ExtensionLowering (`m(static_cast<Base*>(&d), x)`).
