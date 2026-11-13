# TODO markers

The `TODO(<CATEGORY>)` marker kinds that remain in the source. Every marker is `TODO(<CATEGORY>)` (grep-able), and a new kind gets a row here when it is introduced. `grep -rn "TODO(" Compiler Linker Extras Analyzer` lists the markers in the tree.

| Category | What it marks | Resolving it |
|---|---|---|
| `TODO(DUCK-GENERIC)` | A generic parameter whose body uses members of `T`. Stage 0's generics were all C++ templates, duck-typed; an unbounded Stage 1 `<T>` has no members (R051E). The parameter is written `<T: type>` (the compiler-build internal regime, [BuildSystem.md](BuildSystem.md#internal-generics-regime)) and the marker names the members used. | Replace `: type` with a bound `<T impl Iface>` where the members are few and fit an existing or small new interface. `: type` stays for CRTP mixins and large surfaces. `-fduck-generics` is off by default and passed only by `build.py` for the compiler's own targets; it is not a user feature. |
| `TODO(DEFAULT-VIS)` | Code written when an unmarked declaration was `pub` (a class's variables `priv`). The rule is `priv`, or `prot` under a `module.k` (`Compiler/AST/VisibilityFacts.k`). The compiler tree is built with `-fdefault-visibility=spec` (`tree_visibility_args` in `build.py`), each top-level directory holds a `module.k`, and what another module uses is marked `pub`. The one marker is the exemption that keeps `Lib/builtin` and `Lib/std` on the old rule (`VisibilityFacts::_is_lib_tu`). | Mark the libraries, then delete the exemption. The flag stays for users and tests. |
| `TODO(ENUM-OPEN): <sub>` | A closed enum made `@open` because an int-to-enum cast cannot be a checked conversion; `<sub>` says why. Every other int-to-enum cast in the tree is the checked `x as E`. Flag enums are `FlagSet<E, U>` (`Support/FlagSet.k`) over a closed single-bit enum. One enum is left: `TokenKind` (`Token/TokenKind.k`), sub-category `hash-probe`: its values are spelling hashes, and the lexer and `is_valid_token_kind` cast an arbitrary hash before knowing it is a kind. | Keep while a cast of unknown values is needed. |
| `TODO(GENERIC-MEMBER-REQUIRES)` | A default constructor added only so an explicitly instantiated generic (`ArenaList<T>`, every member compiled) can default-construct `T` in a member never called for that `T`. Site: `AST/Node/Program.k` `TopLevelItem`. | Member-level requirements on generic members, checked at the call; then delete the constructor. |
| `TODO(RAW-ALLOC)` (the spelling `kairo::std::create` / `kairo::std::destroy` is the marker) | Allocation through Native's `kairo::std::create<T>` / `destroy` (`Native/Types.hh`): new / delete on raw pointers. | Move to `@create` / `@destroy` with safe pointers, through Kairo's allocator (Stage 1.5/2). |
| `TODO(STD-STRING)` (the spelling `kairo::std::to_std_string` / `from_std_string` is the marker) | Native helpers that convert between Kairo's `string` and C++'s `std::string` by bytes and count (`Native/Types.hh`). | Drop the `std::string` uses (Stage 1.5). |
| `TODO(WINDOWS)` | The Windows branch of the language server's process spawn (`Analyzer/kals_io.h`), which returns no child. | Implement `CreatePipe` + `CreateProcess` there. |
| `TODO` (using-declaration hiding) | An imported C++ class whose `using Base::f;` should hide a base overload, worked around with an explicit `Redeclarable` base (`Compiler/Sema/Foreign/DeclImport.k`). | Remove the explicit base once using-declaration hiding lands. |

## Spellings the migration chose

These are not markers; they record what a Stage 0 construct became, so a reader of the source knows why it looks as it does.

- **Pointers.** The Native pointer aliases `own/obs/opt/oot/view<T>` became `unsafe *T`; address-of is `unsafe &x`; reference returns are raw pointers (`-> unsafe *T`, `return unsafe &x`). The intent an alias named (owning, observing, nullable, a view) is not in the type.
- **Containers.** The Stage 0 library containers are `cxx::std::vector/map/set/...`; `map` and `set` iterate in sorted order, as in Stage 0.
- **Truth tests.** A C++ type with an explicit `operator bool` is tested with `as bool` or an explicit comparison; Kairo applies no implicit conversion operator.
- **Imported C++ objects.** A non-const `T&` parameter is `@inout x: T` and is passed as `&x`; a call on an imported object with `operator()` resolves like C++ and never moves the object.
- **Compile-time hashes.** A spelling hashed at compile time (`DiagID` in the generated `Registry.k`, `TokenKind`) is written as its integer value with the spelling in a comment (`/* "X" */`).
- **Builtin names are reserved.** A user class may not shadow a builtin name (R016E), so the lexer's `BigInt` / `BigFloat` are `ImmBigInt` / `ImmBigFloat`.
- **Char literals** in byte contexts are `('a' as u8)`; in a pattern, the integer with the literal in a comment. Kairo has no `b'a'`.
- **Empty-init loops** are `for ; c; s { }`; `continue` runs `s`.
