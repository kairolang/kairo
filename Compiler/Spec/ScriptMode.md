# Script mode

A script is a root file whose top level holds statements and no `fn main`. Sema turns it into an ordinary program: the statements become the body of a synthesized `fn main() -> i32`, and every top-level binding stays a global. The language rules are in the website reference (modules, Scripts); this document covers how the compiler decides what a script is and how it desugars one. Where `ScriptLowering` sits among the lowerings is [Lowering.md](Lowering.md#pass-order).

| File | Role |
|---|---|
| `Compiler/Sema/Check/ScriptRules.k` | the shared predicates: is this TU a script, which items are statements, which bindings defer |
| `Compiler/Sema/Lower/ScriptLowering.k` | the desugar and the read-before-initialization errors |
| `Compiler/Sema/Verify/JumpLabelCheck.k` | `run_script_jumps`: a `jump!` across a deferred line |
| `Compiler/Sema/Check/ControlFlowAnalysis.k` | unreachable code at a script's top level |
| `Compiler/Sema/Check/PanicEffectChecking.k` | a script's top level judged as `main`'s body |
| `Compiler/Driver/CompilerInstance.k` | sets `SemaContext::script_root`; the two-scripts check |

Tests: `Tests/Codegen/script/`.

## Script files

### Which file is a script

`ScriptRules::is_script` holds when all three are true:

- the TU is a root: `SemaContext::script_root`, which the driver sets (`CompilerInstance.k`, `sem->sc.script_root = fid == self._file_id && !self.discovered`) for the file a frontend action was asked to compile. A command-line input is a root, `kcc`'s included. A file reached through an import, or a `.k` file a C++ input includes (`discovered`), is never one. Every `--emit` mode gets the same answer.
- the file has at least one top-level statement (`is_statement`);
- the file has no `fn main` (`main_of`).

A binding (`var`, `const`, `static`, `thread`, `eval`) is not a statement (`binding_of`). A file of declarations and bindings only, `var g = load()` included, is a library or an ordinary program and is left as it is: a non-constant global there is C++ dynamic initialization before `main`. Everything else at the top level is a statement: an expression, an `if`, a loop, a `return`, a block, a `finally`.

A top-level statement in a file that is not a root is SC234E ("a top-level statement runs only in the program's root file; this file is imported as a module"). A root that has both `fn main` and top-level statements is SC234E at the first statement with a note at `main`: the statements would never run.

### Several inputs

Each command-line input may be a script. When the batch links, two scripts are SC142E at the second script's first statement with a note at the first's; the driver raises it after every frontend action and before the link. Without a link (`-c`, `--type-check-only`, `kcc -c`) several scripts are legal. A script linked with a file that defines `main` (Kairo or C++) is left to the linker's duplicate-symbol error. An input another input imports is analysed as a module by the importer, whatever the input order, so a statement in it is SC234E.

### Redeclaration

Two top-level bindings of one name are R029E in NameResolution, and the pipeline stops there, so `ScriptLowering` never sees one. When both are `VariableDecl`s at file scope, R029E carries a fix-it renaming the second to the first `<name>N` (N from 2) that names nothing in the file's table (`NameResolution.k`). This applies to every file, not only scripts.

### Constant and deferred initializers

`ScriptRules::defers(v)` decides which top-level bindings are deferred: their initializer runs at its source line inside the synthesized `main` instead of as a C++ static initializer. A binding is not deferred when it is `eval`, when it is `thread` (C++ `thread_local` keeps per-thread first-use initialization), when it has no initializer (default construction stays static), or when its initializer is constant (`ScriptRules::constant`):

- an integer, float, char, bool or `null` literal;
- a string literal that is not an f-string;
- `sizeof` / `alignof`;
- an integer ConstEval folds that fits the declared type (`-1`, `1 << 4`, an `eval` name);
- a list literal initializing a fixed array whose every element is constant, nested arrays included (`_constant_array`).

Every other initializer (a call, any other list literal, a read of another global) is deferred. Deferring is always correct and only slower, so the constant list can grow; it grows in `ScriptRules`, which `ScriptLowering`, `JumpLabelCheck::run_script_jumps` and `ControlFlowAnalysis` all read, so they cannot disagree about which lines are deferred. The constant test reads ExprTyper's types and ConstEval, so every reader runs after ExprTyper; the structural questions need only the parsed tree.

## Desugaring

### Synthesized main

```kairo
var cfg = load()          ->  var cfg: Config? = null      // global storage
print(cfg.name)               fn main() -> i32 {
return                            finally { cfg = null }
                                  cfg = load()
                                  print(cfg.name)          // narrowed read
                                  return 0
                              }
```

`ScriptLowering(sc, root)` takes the root flag as an argument and does nothing for a TU that is not a script. For one that is, it moves every top-level statement, in order, into the body of an implicit public `fn main() -> i32`. Each top-level binding stays a namespace-scope variable, never a local of `main`, because functions in the file name it. A deferred binding's initializer becomes an assignment at its position in `main`. After the pass a script's top-level items are declarations and binding `DeclStmt`s only; `EmitIR::emit_tu` ICEs on any other top-level statement, which means `ScriptLowering` did not run.

The slot constraints that fix the pass's place:

- after CopyMoveLowering, so the `e as T&&` cast it put on a moved initializer travels into `main` with the initializer, and a whole-object `g = e` keeps its cast;
- before FinallyLowering, which lowers the `finally` this pass creates;
- before the nullable lowerings ([Nullables.md](Nullables.md#passes)): NullTestLowering lowers the `g?` tests minted here, NarrowedAccessLowering the marked reads, and NullableTypeLowering gives each `T?` minted here its record when it walks the canonical table;
- before every pass that rebuilds bodies (tuples, operators, f-strings, calls, sequencing), to which `main` is an ordinary function body.

`--type-check-only` runs the lowerings, so the read-before-initialization errors appear there too.

### Storage of a deferred global

The global's own declaration becomes its storage: type `T?` (the Nullable lang item), initializer `null`, same decl, same name. EmitIR spells it `::builtin::Nullable<T> g = <null>;`. A deferred `const` becomes `var` storage that `main` assigns; each read still carries the `const T` it was typed with. The name is the user's: a script is a root and is never imported, so nothing links against `g`.

Three shapes are SC235E ("not supported yet"):

- a deferred binding of fixed-array type (`var a: [i32; 2] = [1, f()]`): its storage would be `Nullable<T[N]>`, which Lib/builtin's Nullable cannot construct. The note suggests a list literal of constants and assigning the elements after.

- a deferred binding whose declared type is itself nullable (`var g: i32? = find()`): its storage would be `(i32?)?`, and a read the typer narrowed would need two marks, which NarrowedAccessLowering does not take. The note suggests `= null` and an assignment on the next line.
- a top-level destructuring binding (`var (a, b) = f()`).

Writes to a deferred `const` are not rejected, because ConstChecking is not implemented (`Tests/Codegen/script/deferred_const_write.k` is XFAIL on it).

### Reads

For a read of deferred global `g`:

| Where | Lowered to |
|---|---|
| in `main`, in a statement after `g`'s line | a read marked narrowed (`narrowed_from = T?`), which NarrowedAccessLowering spells `g.__value()`; `main`'s statement order proves it |
| in `main`, at or before `g`'s line, its own initializer included | SC236E "script variable 'g' is read before the line that gives it a value has run", note at the binding |
| anywhere else: another function, a method, any closure body (one written in `main` included), a non-deferred global's initializer | the checked place form of `unwrap!`: `*({ if !g? { unwrap_failed(m, n) } &g })`, an lvalue |

The checked form calls the `UnwrapFailed` lang item (`Lib/builtin/errors/crash.k`, over `kairo_rt_crash` in `Lib/rt/crash.c`) with a message built at compile time: "script variable 'g' used before its line ran (`<file>`:`<line>`)", where `<file>` is the SourceManager's name for the file. The runtime writes it and a newline to stderr and aborts (SIGABRT, exit status 134). The check is present in every build mode, because the call graph cannot prove the order.

A closure body is always checked, even when written in `main`: it runs when called, which `main`'s order does not decide. The rule is positional: a write `g = 5` before the binding's line does not make a later read before the line legal.

A whole-object write `g = e` as a statement is not a read. It assigns the storage (`T -> T?` converts) anywhere, with no check and no error.

### Read before initialization through calls

A direct call from `main`, made before `g`'s line, of a function in this file whose body reads `g` on every path is SC236E at the call ("'f' reads script variable 'g' before the line that gives it a value has run"), with notes at the read and at the binding. `ScriptUseScan` collects the reads and direct calls of a subtree; a use is definite when no branch, loop, `match`, `try`, short-circuit operand or closure encloses it and no `return` / `panic` / `jump!` precedes it in source order. A call anywhere in a statement of `main` counts, even under an `if`: if it runs, it reads.

Only one level is followed: `relay()` calling `report()` that reads `g` is left to the runtime check (`Tests/Codegen/script/guarded_read.k` relies on this). Method calls and calls through values are not followed. The analysis errs toward no error, so it never reports a false one.

### Destruction

`main`'s first statement is one `finally { gN = null ... g1 = null }` over every deferred global, last declared first. It runs on every exit from `main` (a top-level `return`, the end of the file), after everything `main` did and before C++ destroys any static. A global whose line never ran is already null, so its assignment does nothing. Non-deferred globals are destroyed by C++ static destruction after `main`, so every deferred value dies before any static one; a static global cannot depend on a deferred one, since its initializer is constant. A script with no deferred global gets no `finally` (`no_deferred.k`).

### Control flow

- A top-level `return` returns from `main`. Bare, it is `return 0`; its value, when present, is the exit status and must be an integer (SC237E otherwise). A `return` inside a function or closure is that function's own.
- The end of the file is an implicit `return 0`.
- A `jump!` whose source and label are separated by a deferred binding's line is SC238E, in either direction: forward it would skip the initializer while later reads are marked proven, and backward it would run the initializer and the statements around it twice. `JumpLabelCheck::run_script_jumps` decides it on top-level item indices with `ScriptRules::defers`, in the checks after ExprTyper (the constant rule needs types). Every user `label!` / `jump!` is also FeatureGateCheck's SC116E, so such a program does not build either way.
- ControlFlowAnalysis walks a script's top level as one block, so code after a top-level `return` is SC003W. A region is a contiguous run of code items; a declaration or a constant binding ends it and is never in its fix-it, and a deferred binding is code. It runs before lowering, so the trailing `return 0` the pass adds never warns.
- Panics: PanicEffectChecking judges a script's top level as `main`'s body (`PanicBody::Script`), so top-level code must handle every panic as `main` must ([Panic.md](Panic.md#passes)).

### Diagnostics

| Code | Where | Meaning |
|---|---|---|
| SC142E / SC142N | driver | two script files in one linked program |
| SC234E / SC234N | ScriptLowering | top-level statement in an imported module, or beside `fn main` |
| SC235E / SC235N | ScriptLowering | nullable-typed or array-typed deferred binding; top-level destructuring |
| SC236E / SC236N | ScriptLowering | read before the binding's line, directly or through a direct call |
| SC237E | ScriptLowering | top-level `return` value is not an integer |
| SC238E / SC238N | JumpLabelCheck | `jump!` crosses a deferred binding's line |
| R029E | NameResolution | redeclared top-level binding, with the rename fix-it |

### Not implemented

- `sys::args`: a process-wide read-only `[string;]` filled from `argc`/`argv` before the first statement of any `main`. Design intent: a `pub fn args() -> [string;]` in a new `std::sys` over a private global, every program's entry emitted as `int main(int argc, char** argv)` calling a builtin setter (a LowerTargets row) before the body, strings built lazily, `args[0]` the program name. Nothing exists: `Lib/std` has no `sys` module and the entry is `int main()`.
- Module initialization: top-level statements in imported modules, run in import order.
- A script that is also a library.
