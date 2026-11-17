# Sema agreement

The pass after CodeGen: clang has parsed and type-checked the token stream of one Kairo TU, and before its CodeGen consumes a declaration the pass checks that clang's Sema bound each call to the declaration Kairo's Sema chose.

The premise is [Codegen](Codegen.md)'s: the stream is a reduced C++ in which overloads, specializations and constraints are already resolved, so clang is a lowering target and has no semantic choice to make. A call clang binds differently is therefore a compiler bug: either CodeGen spelled the call in a way that left clang a choice, or Kairo's overload resolution ranked wrongly. The pass finds such a call before it reaches LLVM IR.

A disagreement is counted, and reported as `I012W`, a warning, by a debug-built compiler or under `-fsema-agreement` ([Flags](#flags)). Compilation continues.

## What is checked

Callee agreement, for every call Sema bound to a function declaration and CodeGen wrote as a call: free functions, methods, constructors, and operators lowered to calls. With it, how clang found the callee ([Lookup](#lookup)).

Where the walk runs:

- **A Kairo TU's own stream**, in the TU's clang invocation.
- **A body the interface PCH holds** is walked once, at the PCH's build. A finding there belongs to the TU whose file holds the call. A dependent call in such a body is not compared: its instances are made in TUs, from a pattern the TU's table has no record of.
- **A Kairo file a C++ file includes** (`kcc`, [Interop](Interop.md#kcc)) is walked in the host's parse. A finding is reported at the Kairo call after the host job, never against the C++ file; it is not cached and not in the summary count.

Not compared, and why:

| Call | Reason |
|---|---|
| in a `<T: type>` body ([Generics](Generics.md#duck-regime)) | clang resolves it per instance by design |
| through an interface witness | the C++ callee is the witness's member, not the requirement Sema bound |
| through a `fn` value, a functor object, a deferred f-string hole, a dependent overload set | Sema bound no declaration |
| a free imported operator written infix, `__builtin_expect`, `__builtin_assume` | not written as a call |
| dependent, in a body the interface PCH holds | its instances are made in TUs, from a pattern the TU's table has no record of |
| to an operator, an implicit member, or a function whose C++ name is not its Kairo name | no proof of where clang's callee is written (below); counted as agreed only when its location falls inside Kairo's declaration, else as unchecked |

Which specialization serves an instance is C++'s choice ([Generics](Generics.md)): a clang callee that is an explicit specialization agrees with its primary template.

Template choice per call site and implicit conversions are not compared ([Not built](#not-built)).

## How

### The record (fill)

`EmitIR::_call_inner` ends each bound call with `EmitIR::_agree`, which calls `EmitSink::agree_call(at, decl, name)`: the call's range, and the range and name token of the declaration Sema chose. `TokenSink` keeps an `AgreeSite` with the index of the last token written, the call's `)`. `HashSink` and `TextSink` ignore it. An emitter asks `EmitSink::agree_on` first, so nothing is computed when the pass is off.

After `TokenSink::finish()`, when every token's location is final, `KairoInject::_agree_fill` turns each site into a `SemaAgreeCall` of `Native/ClangSemaAgree.hh`: the raw clang location of the `)` token and of the declaration's name token and first byte. The table is keyed by the `)` location, which the sink gives to no other token.

Cost of the record: one site per bound call (the token index and three ranges). Recorded and walked, the pass adds about 0.1% to the instructions of a whole build of the compiler and about 1.2% to those of a small program (which is mostly the builtin library's generic TUs), so it runs in every build of the compiler.

### The walk

Each codegen action overrides `CreateASTConsumer` and returns clang's CodeGen consumer behind a `SemaAgreeConsumer`, in a `clang::MultiplexConsumer`. The walk is a `RecursiveASTVisitor` run on each top-level declaration in `HandleTopLevelDecl`, and on each inline member body in `HandleInlineFunctionDefinition`, ahead of CodeGen's own handling of the same callback: clang's CodeGen consumes a declaration there, so a repair has to happen first. Instantiated function bodies arrive through `HandleTopLevelDecl` and are walked as any other; a template pattern's non-dependent calls are checked in the pattern.

The interface PCH's streams record their bound calls into one table, and the PCH's action runs the same consumer ahead of the PCH generator. For `#include "x.k"` in a C++ file, the include source keeps a table per host TU, and each host action that builds an AST runs the consumer over it.

Only declarations the stream wrote are walked (their location is in a Kairo file). Type locations are not traversed. There is no second parse; the walk runs inside the TU's own clang invocation, on the worker that compiles the TU.

`CallExpr` (member and operator calls included) joins by `getRParenLoc()`, `CXXConstructExpr` by the end of its paren range, a one-argument `T(x)` by the functional cast's `)`.

### Comparing declarations

The two compilers share no declaration object, so a declaration is identified by where it is written: file and byte offset.

`TokenSink` gives a declaration's name byte to the first token that spells the name; every other token (a later redeclaration's name, any synthesized token) sits on a free byte nearby. So:

- **Agreed**: clang's callee, its template pattern, its primary template, the member it was instantiated from, an inherited constructor's base, or any redeclaration of those, is located at the name token of Kairo's declaration.
- **Disagreed**: none is, and one of them is located on bytes that spell its own name. That location is where clang's callee is written, and it is not Kairo's.
- Otherwise there is no proof either way (an operator, an implicit member, a name C++ spells differently): agreed when a location falls inside Kairo's declaration, else unchecked.

A Kairo function declared more than once (a prototype and its definition, a method defined out of line) is one function: `_agree` passes the name token of each other declaration (`EmitSink::agree_alt`, `SemaAgreeTable::alts`), and a clang callee located at any of them agrees. Sema binds a call to one declaration of the chain and the stream may write another, a module's importer in particular.

In a template instance, a callee that is a member of an explicit specialization of a class template, or of an instance of a partial one, is not a disagreement: Kairo bound the call in the generic body to the primary template's member, and which specialization serves the instance is C++'s choice ([Generics](Generics.md)). It is counted as chosen per instance.

Files are compared by `FileEntry`, so a declaration read from a PCH compares equal to the same file registered by `ClangLocMap`.

Two streams of one parse can give one location to two closing tokens; such records are unchecked. Declarations made by one macro invocation share one position and are not told apart.

### Lookup

`CallExpr::via_adl` says Sema's winner came only from argument-dependent lookup. CallTyping sets it for such a call, OperatorLowering for a free operator, and IterLowering for a range-for's free `begin` / `end`. Where clang's `usesADL()` is true and the record does not say so, the pass reports kind `adl`, even when both reached one declaration. A call Sema found by ADL and CodeGen wrote qualified agrees. On an operator call `via_adl` means "free operator", so the check does not fire for operators.

### Repair

Where clang's callee X differs from Kairo's Y, the call is pointed at Y when all of these hold:

- Y is found in clang's AST (a function located at Kairo's name token), is not deleted, and neither is templated;
- X and Y have the same canonical function type, so every argument conversion clang computed stays valid;
- both are free or static functions, or both are non-virtual instance methods of one class (no constructor, destructor or conversion function);
- the callee is a `DeclRefExpr` or `MemberExpr` naming X with no explicit template arguments.

`DeclRefExpr::setDecl` / `MemberExpr::setMemberDecl` re-point it, and `Sema::MarkFunctionReferenced` marks Y so its body is emitted. A repair in a template pattern carries into each instance.

Everything else is reported and left as clang resolved it: different types, different kinds, a constructor (`CXXConstructExpr` has no setter), a target that would need instantiation. The diagnostic's label says which.

The search for Y reads every declaration of the TU; it runs at most 8 times per TU, and later findings are report-only.

## Diagnostic

`I012W`, at the call, naming clang's callee (qualified, with parameter types) and Kairo's (its name), with a note at each declaration. The label says whether the call was re-pointed or why not, and whether clang found its callee by argument-dependent lookup.

One known disagreement, on an imported C++ overload set, where the call goes out by the set's name, clang picks, and Sema's recorded callee is another member of the set:

| Set | Sema bound | clang bound |
|---|---|---|
| `enable_if` overloads of a function template called with a Kairo record | one whose condition is false | the one whose condition holds |

It goes to the TU's `diag_sink`, as codegen's own reports do, once per TU (a TU runs once per `--emit` kind, and again without the interface PCH). A TU's findings are stored beside its object (`<key>.f.o`, `<key>.agree`) and replayed by the build that reuses it; the text names files by content, and a file whose bytes changed makes the TU compile ([Incremental](Incremental.md)). The object is served only when both files are whole, so a lost findings file is a miss. A finding in an interface PCH body is stored with the object of the TU it belongs to, so a rebuilt PCH does not say a reused TU's finding twice. One key can hold both `<key>.o` and `<key>.f.o` (one build walked the PCH and another did not); the finding-bearing entry is served first.

### Reported or counted

The pass runs, and counts, in every build. Whether it reports is `KairoInject::agree_says`, set in `agree_start`: `-fsema-agreement` reports; with the flag not given, `kairo::sema_agree_reports_unasked()` (`Native/ClangSemaAgree.hh`) decides, and it is true only in a debug build of the compiler (`DEBUG`). A release-built compiler stays silent because the known disagreement below occurs in ordinary interop code and the message tells its reader to report a compiler bug. That function is the one switch: it returns true in every build once Sema's picks for those sets match clang's. Repair does not depend on it.

Whether a run reports is not in the object key: findings are stored either way, and a reporting run that reuses a counting run's object reports its findings. The key's run part (`ObjectCache::run_part`) says what the pass does to the object: `agree off`, or `agree walk [repair] <checks>`, where `<checks>` names the comparisons the compiler makes (`callee adl pch`), plus a line for each test hook that changes what is found (`--test-sema-agreement-no-adl`, `--test-sema-agreement-swap`). A release build's fingerprint holds only its version, so the checks are named there for two compilers that differ in them not to share a clean object.

## Flags

| Flag | Default | |
|---|---|---|
| `-fsema-agreement` | | the pass reports (I012W), in any build |
| `-fno-sema-agreement` | | the pass does not run |
| neither | | the pass runs and counts; a debug-built compiler reports, a release-built one does not |
| `-fsema-agreement-repair` / `-fno-sema-agreement-repair` | on | off: no call is re-pointed |
| `--test-sema-agreement-swap=<from>:<to>` | hidden | compiler tests: the record of a call bound to a function named `<from>` names the function `<to>` instead, found in the scopes enclosing it |
| `--test-sema-agreement-quiet` | hidden | compiler tests: with `-fsema-agreement` not given, count and do not report, as a release-built compiler does |
| `--test-sema-agreement-no-adl` | hidden | compiler tests: the record of every call says Sema did not find its callee by ADL |
| `--sema-agreement-summary` | hidden | after codegen, print `kairo: sema agreement: N finding(s) in M of T file(s) (kind n, ...)`, or `kairo: sema agreement: off`; reused objects count, `-w` and whether the run reports do not ([Driver](Driver.md)) |

With `-v`, each TU logs `sema agreement: N calls recorded, N joined, N agreed (N by range), N dependent, N chosen per instance, N unchecked, N unrecorded, N found by ADL (N by Sema too), N disagreed in <file>`. "joined" is how many records clang's AST held; "unrecorded" is clang calls located in Kairo files with no record (counted only under `-v`).

## Not built

- **Dependent calls in instances of interface PCH bodies**: a dependent call in a body the PCH holds is checked in no instance; the TU that instantiates the pattern has no record of it.
- **Declarations made by one macro invocation**: they share one position, so a call bound to one of them agrees with clang binding it to another.
- **Template / specialization choice**: an explicit specialization, or a member of a partial specialization's instance, agrees with its primary template; which one serves a call, and which `requires` overload, is not compared.
- **Implicit conversions**: the conversion clang applies to an argument is not compared with the one Kairo chose.
- **Ranking**: only the winner is compared, not how many candidates each compiler found viable.
