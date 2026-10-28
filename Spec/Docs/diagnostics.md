# Diagnostics

This page lists compiler error messages verbatim so they can be searched. Placeholders are written in braces: `{n}` is a number, `{x}` a parameter name, `{f}` a function name, and `[T; M]` the type as written in your code.

---

## List Literals

### `array literal has {n} element(s), but '[T; M]' needs {m}`

A [list literal](/docs/language/collections/#list-literals) initializes a fixed array of a different length. The literal is not silently turned into a slice.

```kairo
var x: [i32; 4] = [1, 2, 3]    // error: array literal has 3 element(s), but '[i32; 4]' needs 4
```

**Fix:** give the literal the right number of elements, or change the target to `[T;]` or `[T]`.

### `cannot infer the type of an empty list here; annotate the target as '[T;]' or '[T]'`

`[]` has no elements to take a type from and no target to take one from.

```kairo
var e = []                     // error
var f: [i32] = []              // ok
```

**Fix:** annotate the target.

---

## Slice Literal Lifetime

A list literal that becomes a slice `[T;]` is a view of a temporary array. These errors report the positions where the view would outlive that array. See [Primitives](/docs/language/collections/#how-long-a-slice-literals-storage-lives).

### `a list literal returned from a function is a view of a temporary array and would outlive it; use '[T]' to own the elements, or bind the literal to a 'var' first`

```kairo
fn make() -> [i32;] {
    return [1, 2]              // error
}
```

### `a list literal assigned to a slice is a view of a temporary array and would outlive it; use '[T]' to own the elements, or bind the literal to a 'var' first`

```kairo
var s: [i32;] = [1]
s = [1, 2]                     // error
```

### `a list literal used as a field default is a view of a temporary array and would outlive it; use '[T]' to own the elements, or bind the literal to a 'var' first`

```kairo
struct S {
    var xs: [i32;] = [1]       // error
}
```

### `a list literal stored in a field is a view of a temporary array and would outlive it; use '[T]' to own the elements, or bind the literal to a 'var' first`

```kairo
var t = S{ xs: [1, 2] }        // error
```

**Fix, for all four:** declare the target `[T]` so it owns its elements, or bind the literal to a `var` in a scope that outlives the slice and use that variable.

> [!NOTE]
> Passing a slice literal to a function that stores the slice is not diagnosed. Until [Tether](/docs/language/tether/) checks it, it is the programmer's responsibility.

---

## Arrays

A fixed array `[T; N]` is not a value type. See [Primitives](/docs/language/collections/#arrays-t-n).

### `an array is not copyable; initialize it from a list literal, or view the source through a slice or a pointer`

```kairo
var a = [1, 2, 3]
var b = a                      // error
```

### `an array is not assignable; assign its elements, or go through a slice`

```kairo
var a = [1, 2, 3]
var b = [4, 5, 6]
b = a                          // error
```

### `parameter '{x}' takes an array by value; write 'const', '@inout', or take a slice`

```kairo
fn f(xs: [i32; 3]) { }         // error
fn f(const xs: [i32; 3]) { }   // ok
fn f(@inout xs: [i32; 3]) { }  // ok
fn f(xs: [i32;]) { }           // ok
```

### `'{f}' returns an array; an array is not returned by value, return '[T]' or fill an '@inout' parameter`

```kairo
fn g() -> [i32; 3] { ... }     // error
fn g() -> [i32] { ... }        // ok
fn g(@inout out: [i32; 3]) { } // ok
```

---

## Overload Resolution

### `call to '{f}' is ambiguous: more than one candidate matches at the same rank`

Two or more [overloads](/docs/language/functions-overloading/#overload-resolution) are viable and neither is an exact match, so there is nothing to choose between them. Conversions are not ranked against each other.

```kairo
fn f(xs: [i32;]) { }
fn f(xs: [i32]) { }

f([1, 2, 3])                   // error: call to 'f' is ambiguous
f([1, 2, 3] as [i32])          // ok
```

**Fix:** make the argument's type explicit with `as` or a typed local. See [Primitives](/docs/language/conversion-lattice/#list-literal-arguments).

---

## Where Clauses

### `no fallback overload for '{f}' when where condition fails`

Every [`where`](/docs/language/where/#fallback-requirement)-constrained overload needs a fallback: an overload of the same signature with no `where` clause, or conditions the compiler can prove cover every value. A note says what to add.

```kairo
fn root(x: f64) -> f64 where x >= 0.0 { return x }   // error: no fallback
fn root(x: f64) -> f64 { return 0.0 }                 // ok: the fallback
```

**Fix:** add an overload without a `where` clause.

### `'where' is not allowed on ...`

A `where` clause is runtime dispatch among overloads, so it is an error on a type (`'where' is not allowed on a class`, with a fix-it to `requires`), on an interface method, on an `unsafe` overload (unsafe overloads are a separate namespace), and on a closure. A guarded overload also needs a body (`a guarded overload of '{f}' needs a body`).

### `every overload in the 'where' dispatch of '{f}' must have the same {what}`

The overloads of one dispatch become one function, so they must agree on return type, `const self`, `inline`, `-> !` and linkage. A note points at the first overload.

### `'where' guard of '{f}' is unreachable` / `overlaps an earlier one` / `never holds` (warnings)

The compiler compares conditions that test integer parameters against constants. A condition inside an earlier one never fires (a note points at the earlier one); a condition that partly overlaps an earlier one sends the shared values to the earlier overload; a contradictory one (`x > 5 && x < 3`) never holds. See [Declaration Order](/docs/language/where/#declaration-order-determines-priority).

---

## Default Arguments

### SC106E: a default argument refers to another parameter or `self`

A default is evaluated with no access to the call's other arguments, so it cannot name them.

```kairo
fn a(x: i32, y: i32 = x) { }          // error SC106E
fn m(self, y: i32 = self.v) { }       // error SC106E
```

**Fix:** add an overload that leaves the parameter out and forwards the value. See [Functions](/docs/language/functions-parameters/#a-default-stands-alone).

### SC107E: a named argument skips a defaulted parameter of an imported C++ function

C++ applies an imported function's defaults and can only leave out trailing arguments. A call that names a later parameter while an earlier defaulted one is omitted cannot be expressed.

```kairo
// C++: void blit(int x, int y = 0, int scale = 1);
blit(4, scale: 2)            // error SC107E
```

**Fix:** pass the earlier arguments explicitly: `blit(4, y: 0, scale: 2)`. See [Functions](/docs/language/functions-parameters/#defaults-on-imported-c-functions).

---

## Lifecycle

### SC057E: more than one transfer constructor

A class has exactly one transfer constructor. It is an error to declare both a `@copy` and a `@move` transfer constructor, unless both are `= delete` (the non-transferable form), and it is an error to declare two transfer constructors of the same kind, such as `@copy` with and without `const`.

```
'{X}' declares both a '@copy' and a '@move' transfer constructor; pick one (both may be '= delete' together, which makes the class non-transferable)
'{X}' declares more than one '@copy' transfer constructor; a class has exactly one transfer constructor
```

```kairo
class Bad {
    @copy fn Bad(self, const other: Self) = default
    @move fn Bad(self, other: Self) = default       // error SC057E
}

class TwoCopies {
    @copy fn TwoCopies(self, const other: Self) = default
    @copy fn TwoCopies(self, other: Self) = default // error SC057E
}
```

**Fix:** keep one transfer constructor. See [Classes](/docs/language/classes-lifecycle/#the-transfer-constructor).

### SC110E: a constructor has the shape of a transfer constructor but is not declared as one

A constructor that takes `Self` first and defaults every later parameter is a transfer constructor, and is written only as `@copy fn X(self, const other: Self)` or `@move fn X(self, other: Self)`.

```kairo
class A {
    fn A(self, other: Self) { }               // error SC110E: no marker
}
class B {
    fn B(self, @move other: Self) { }         // error SC110E: a mode on the parameter
}
class C {
    fn C(self, other: Self, k: i32 = 0) { }   // error SC110E: a defaulted extra parameter
}
```

**Fix:** put `@copy` or `@move` on the constructor and write the parameter bare. See [Classes](/docs/language/classes-lifecycle/#the-transfer-constructor).

### SC129E: a defaulted transfer constructor cannot be generated

A defaulted `@copy` constructor needs every base and field to be copyable; a defaulted `@move` needs every base and field to be movable or copyable. The error names the field or base that is not.

```
'{X}' cannot have a defaulted copy constructor: field '{f}' of type '{T}' is move-only
'{X}' cannot have a defaulted move constructor: field '{f}' of type '{T}' is not transferable
'{X}' cannot have a defaulted copy constructor: base '{B}' is not transferable
```

```kairo
class Unique {
    @move fn Unique(self, other: Self) = default
}

class CopiesUnique {
    var u: Unique
    @copy fn CopiesUnique(self, const other: Self) = default   // error SC129E: 'u' is move-only
}
```

**Fix:** write the transfer constructor body yourself, change its kind, or `= delete` it. See [Classes](/docs/language/classes-lifecycle/#defaulted-moves-of-non-movable-members).

---

## Enums

### SC128E: an enum discriminant does not evaluate or does not fit

A discriminant must be an integer constant expression whose value fits the enum's underlying type. The message says which part failed.

```
an enum discriminant must be an integer constant that fits '{T}'; this one does not evaluate: {reason}
an enum discriminant must be an integer constant that fits '{T}'; it is {n}, which does not fit
```

```kairo
enum Small derives u8 {
    Top = 255,
    Past,              // error SC128E: 'Past' is one past 'Top', so it is 256
}

enum Order {
    A = Late,          // error SC128E: 'Late' is declared below this variant
    Late = 1,
}
```

**Fix:** use only literals, operators, `as` to an integer type, and earlier variants, and keep the value in range or widen the underlying type. See [Enums](/docs/language/enums-plain/#discriminant-values).

### SC130E: two variants of an enum have the same value

```
'{V}' has the same value as '{W}' ({n})
```

```kairo
enum Flags {
    A = 1,
    B = 1,             // error SC130E
}
```

Imported C++ enums are exempt.

**Fix:** give each variant a distinct value. See [Enums](/docs/language/enums-plain/#discriminant-values).

### SC001E: a constant cast into a closed enum is no variant's value

`as` into a [closed](/docs/language/enums-plain/#closed-and-open-enums) plain enum with a constant that no variant has. The code is a placeholder until the error gets its own.

```
{n} is not a value of '{E}': a closed enum holds only its variants' values
```

```kairo
enum Color derives u8 { Red, Green, Blue }

var c = 3 as Color     // error SC001E: 3 is not a value of 'Color'
```

The note points at the enum. When the enum is declared in the same file, a fix-it inserts `@open` before its `enum` keyword.

**Fix:** cast a value one of the variants has, or declare the enum `@open` if it is meant to hold other values. A non-constant operand is not an error: it is checked when it runs and crashes on a miss.

### SC001E: `@open` on something other than a plain enum

```
'@open' does not apply to an ADT enum: no cast makes its tag, so it is always closed
'@open' does not apply to this declaration; only a plain enum can be open
```

The fix-it removes the attribute.

### SC001E: a pack-expanded variant is malformed

A [pack-expanded variant](/docs/language/enums-adt/#variadic-enums) `V { e: E }...` must have a payload that names the enum's type pack, must be the enum's last variant, and must be its only one. A pack named in a variant without `...` is the same error. The code is a placeholder until the error gets its own.

```
variant '{V}' is followed by ... but has no payload, so there is nothing to expand
variant '{V}' is followed by ..., but its payload names no type pack of '{E}'
pack-expanded variant '{V}' must be the last variant of '{E}'
'{E}' already has a pack-expanded variant, '{V}'; an enum expands its pack once
variant '{V}' names the type pack '{P}', but is one variant; add ... after it to make one variant per element of '{P}'
```

```kairo
enum <T, ...E> R {
    Err { e: E },        // error SC001E: add ... after it
    Ok { v: T },
}
```

A fix-it removes a `...` that expands nothing, or adds the missing one.

**Fix:** follow the variant that holds the pack with `...` and put it last.

### SC001E: no expansion of a pack-expanded variant fits

A construction or a pattern names a pack-expanded variant, and its payload type picks no expansion, or several. A pattern must write the type on the binder of the pack field when there is more than one expansion; a fix-it writes the first one's. The note lists the expansions.

```
no '{V}' of '{T}' holds a '{U}'
a '{U}' fits more than one '{V}' of '{T}'; the payload's type must pick one
'{V}' is one variant per element of a pack in '{T}'; name the payload's type to pick one
'{T}' has no '{V}' variant: its pack is empty
```

```kairo
enum <T, ...E> Outcome { Ok { value: T }, Err { error: E }... }

var o: Outcome<i32, i64, f64> = .Err { error: 1 }   // error SC001E: an i32 fits both
match o {
    case .Err(var error) { }                         // error SC001E: name the type, 'var error: i64'
    default { }
}
```

**Fix:** give the payload a value of exactly one element's type, and write `var error: T` in the pattern.

### SC001E: a type pack or a pack parameter where one value or type is expected

A type pack (`...T`) stands for several types and a pack parameter (`...xs: T`) for several values, so neither can be used as one. A pack is written expanded as an argument (`Box<T...>`, `f(xs...)`), as the type of a `...` parameter, or, for a pack parameter, iterated with `for`. The code is a placeholder until the error gets its own.

```
'{T}' is a type pack and stands for several types; a field cannot have it as its type
'{xs}' is a pack of values with different types; pass it on expanded as an argument, or iterate it with a for loop
a pack expansion is written only as a call argument, where it passes each element as its own argument
only a pack parameter can be expanded
```

```kairo
class <...T> Holder { var xs: T }     // error SC001E
fn <...T> f(...xs: T) {
    var y = xs                         // error SC001E
    for x in xs { }                    // fine
    g(xs...)                           // fine
}
```

**Fix:** expand the pack, or iterate it.

### SC123E: a variant name does not fit the expected type

A `.V`, or a pattern head, must name a variant of the enum it is checked against. It covers construction as well as [`match` patterns](/docs/language/pattern-matching/#enum-variant-matching): `.V` with no expected enum type, `.V` against a type that is not an enum, a variant the enum does not have, a variant of another enum, a type that is not the matched type, and a name that is not a variant, a constant or a type.

```
'.{V}' names an enum variant, but nothing here gives it an enum type; write the enum's name before it
'.{V}' names an enum variant, but the expected type is '{T}', not an enum
'.{V}' names an enum variant, but the matched value is '{T}', not an enum
'{E}' has no variant named '{V}'
'{E}::{V}' is a variant of another enum; the matched value is '{T}'
this pattern matches '{T}', but the matched value is '{U}'
'{E}' is an enum; name one of its variants
'{x}' is not a variant, a constant or a type, so it cannot be matched against; to bind the value to a new name, write 'var {x}'
```

```kairo
enum Dir { North, South }

fn main() -> i32 {
    var a = .North           // error SC123E: nothing gives '.North' an enum type
    var b: i32 = .North      // error SC123E: 'i32' is not an enum
    var c: Dir = .East       // error SC123E: 'Dir' has no variant named 'East'
    match 3 {
        case .North { }      // error SC123E: the matched value is 'i32', not an enum
        default { }
    }
    return 0
}
```

**Fix:** give `.V` an expected enum type, or write the enum's name before it (`Dir::North`). See [Enums](/docs/language/enums/#shorthand-syntax).

### SC131E: a variant is built with the wrong shape

A variant is built from its own payload: every field once, by name, in braces exactly when it has a payload. A field name the payload does not have is SC040E, as for a struct.

```
'{E}::{V}' carries a payload; give its fields in braces after the name
'{E}::{V}' carries no payload; write it without braces
'{E}::{V}' is missing field '{f}'
field '{f}' of '{E}::{V}' is given twice
```

```kairo
enum Shape { Circle { r: i32 }, Rect { w: i32, h: i32 }, Empty }

fn main() -> i32 {
    var a = Shape::Rect { w: 1 }               // error SC131E: missing field 'h'
    var b = Shape::Rect { w: 1, w: 2, h: 3 }   // error SC131E: 'w' given twice
    var c = Shape::Empty { }                   // error SC131E: no payload, no braces
    var d = Shape::Circle                      // error SC131E: a payload needs braces
    return 0
}
```

**Fix:**

```kairo
enum Shape { Circle { r: i32 }, Rect { w: i32, h: i32 }, Empty }

fn main() -> i32 {
    var a = Shape::Rect { h: 2, w: 1 }
    var c = Shape::Empty
    var d: Shape = .Circle { r: 3 }
    return 0
}
```

See [Enums](/docs/language/enums-adt/#construction).

### SC001E: a constructor does not initialize a field that has no default

A field with no initializer whose type has no default (`bool`, an enum with payloads, a class with no default constructor, an array of any of these) is initialized by every constructor, like a `const` member: the constructor's first whole write of it is its initialization, and an array field may instead be built element by element, each element written once with a constant index. See [Classes](/docs/language/classes/#fields-without-a-default). The code is a placeholder until the error gets its own.

```
constructor of '{C}' does not initialize field '{f}', and {why}
field '{f}' is not initialized on every path through the constructor of '{C}', and {why}
'{f}' is written in part before it is initialized, and {why}
a defaulted constructor of '{C}' cannot initialize field '{f}', and {why}
array field '{f}' is initialized on some paths through the constructor of '{C}' only; an array is not assignable, so its one initialization must be on every path
'self' is used before the constructor has initialized its fields
array field '{f}' is built element by element, but element 1 is (elements 1 and 3 are) not initialized on every path through the constructor of '{C}', and {why}
element {k} of '{f}' may already be initialized here; each element is initialized exactly once before '{f}' is whole
the index of an element write that builds '{f}' must be a constant
index {k} is out of range for '{f}', which has {N} elements
an element of '{f}' is initialized inside a loop; each element of an array field built element by element is written exactly once, with a constant index
'{f}' is read before all of its elements are initialized: elements 1 and 2 are not initialized yet on every path
```

`{why}` says why the type has no default, the same reason a local gets (`'Frame' is an enum with payloads, so no variant is its default`). The note points at the field. Element by element, the messages name the elements still missing, the earlier write of a duplicate, or where the array started being built; a write into an element (`self.toks[0].n = 1`) or into an array of arrays does not build anything, and a note says so.

```kairo
enum Frame { Burst { base: i32, count: i32 }, Idle }

class Batch {
    var frames: [Frame; 3]

    fn Batch(self, c: bool) {    // error SC001E: elements 1 and 2 are not initialized on every path
        self.frames[0] = .Idle
        if c { self.frames[1] = .Idle }
    }
}
```

**Fix:** build the field on every path before any method call, whole (`self.frames = [.Idle, .Idle, .Idle]`) or one write per element; or give it an initializer at its declaration.

An array field's one whole write in a constructor is its initialization, so a second one, one inside a loop, or one after an element was already built, is SC071E (`an array is not assignable; 'frames' may already be initialized here`).

---

## Panic

These are the [panic](/docs/language/panic/) effect checks: every error a call or a `panic` may produce is handled with `try`/`catch` or propagated by a `panic` function. Messages name every type involved; a set is listed in a fixed order.

### SC001E: `unhandled panic: '{f}' may panic with '{E}', and '{g}' is not marked 'panic'`

A call to a panicking function, or a `panic` statement, in a function with no `panic` specifier, where no enclosing `try` catches the types listed. Two fix-its: mark the function `panic` to propagate, or wrap the call in `try ... catch => crash!()` to handle it there. The same check applies to a closure (`... and the closure is not marked 'panic'`).

```kairo
fn parse_port(s: string) panic -> i32 { ... }

fn bad() -> i32 {
    return parse_port("8080")   // error SC001E
}
```

**Fix:** mark `bad` `panic`, or handle the error: `return try parse_port("8080") catch => 8080`.

### SC001E: `'{E}' is not in the declared panic set of '{f}'`

A function (or closure) with a [declared set](/docs/language/panic/#declared-panic-sets) `panic(E1, E2)` panics with, or propagates, a type outside it. The note points at the callee the type comes from; the fix-it adds the type to the list.

```kairo
fn load(path: string) panic(IOError) -> i32 {
    return parse_port(read_file(path))   // error: 'RangeError' is not in the declared panic set of 'load'
}
```

### SC001E: `'main' cannot panic` / `a panic cannot reach 'main'`

`main` can never be `panic` (fix-it: remove it), and an error that would reach `main` unhandled is an error at the call that propagates it, with a fix-it handling it there or stopping the program with [`crash!()`](/docs/language/panic/#main-and-crash). A script's top-level code follows the same rule (`a panic cannot reach a script's top level`).

### SC001E: `'{f}' cannot be both 'panic' and '-> !'`

A `panic` function returns its error to the caller; a `-> !` function never returns. Fix-it: remove `panic`.

### SC001E: `{what} cannot panic: it runs where no call is written, so nothing could handle the error`

An `@implicit` conversion and `op panic` are called by the language where no call is written, so an error from them could never be caught. Fix-it: remove `panic`.

### SC001E: `a constructor cannot panic` / `a destructor cannot panic`

No constructor (one with parameters, the default constructor, a transfer constructor) and no destructor (`op delete`) can [panic](/docs/language/classes-lifecycle/#constructors-and-destructors-never-panic): an object is built whole or not at all, and a destructor runs on every exit, where nothing could take an error. Marking one `panic` is `a constructor cannot panic: an object is either built whole or not at all` (or the destructor's reason), with a fix-it removing `panic`. A panic that would escape one's body is `a constructor cannot panic: '{f}' may panic with '{E}', which is not handled`, with fix-its handling it there or stopping the program with `crash!()`. For a constructor, a note says that construction which can fail belongs in a static factory function.

```kairo
class Conn {
    var fd: i32
    fn Conn(self, n: i32) { self.fd = open_fd(n) }   // error: a constructor cannot panic
    static fn open(n: i32) panic -> Conn { return Conn(open_fd(n)) }   // fine
}
```

### SC001E: `type '{T}' cannot be panicked: {why}`

An error is returned and propagated by value, so a type a `panic` raises, a declared set names, or a `catch` names (`cannot be caught`) must be movable, complete, and a value: not a reference, not `void`. The reason says which rule failed, and a note points at the type.

```kairo
class Pinned {
    fn Pinned(self) {}
    @move fn Pinned(self, other: Pinned) = delete
}
fn f() panic -> i32 { panic Pinned() }   // error: it is not movable
```

### SC001E: `a global's initializer cannot panic` / `cannot hold a 'try'`

A global's (or static field's) initializer runs at file scope: there is no function for an error to propagate to, and no place for a `try`. Initialize it in a function instead. A field's default and a parameter's default may call a panicking function only inside a `try` that handles everything (`a field's default cannot panic: ...`).

### SC001E: `the panic set of ... must be declared`

A bare `panic` where the set is a contract or has no body to infer from: a [function type](/docs/language/panic/#where-a-declared-set-is-required) (`the panic set of a 'fn' type must be declared`), an interface requirement, a `virtual` method of a base class, or a closure (`a closure's panic set must be declared`). Where there is a body, the fix-it writes the set it was inferred to be (or removes `panic` when nothing panics); otherwise a note says there is no body to infer from.

```kairo
var retry = fn () panic -> string { return read_file("x") }   // error: write 'panic(IOError)'
```

### SC001E: `'{E}' is not in the panic set of '{Base::m}', which this overrides` / `implements`

An [override](/docs/language/panic/#subsets)'s set must be a subset of the base method's, and a conforming method's a subset of the interface requirement's. The fix-it adds the type to the base's or the requirement's declared set. Overriding a method that does not panic with one that does is `an override cannot panic when '{Base::m}', which it overrides, does not`. A generic base's or interface's set is read at the arguments the class derives it at or conforms to (`class D derives Base<B>` holds `run` to `Base<T>::run`'s `panic(T, A)` as `panic(B, A)`), and then no fix-it is offered: the base's own list names its parameters.

### SC001E: `'{f}' is used as a value, but its panic set is inferred`

A function value's type carries its panic set (`fn() panic(IOError) -> i32`), and a set inferred from the body is not known when the value's type is given. Declare it; the fix-it writes the inferred set. Converting between function types follows the [subset rule](/docs/language/panic/#subsets): a function whose set is not a subset of the target's is a type mismatch (`cannot convert 'fn () panic(E, F) -> i32' to 'fn () panic(E) -> i32'`).

### SC001W: `the panic set of public function '{f}' is inferred ({E}); declare it ...`

Only when building a library (`--shared`): a `pub` function's inferred set is API surface that changes when the body does. The fix-it writes the set.

### SC001W: `this arm never runs: '{T}' is not in the panic set of its 'try' (...)`

A `catch e: T` whose `T` the `try` body cannot panic with. A warning, not an error, so that a library removing an error from a function's set does not break callers that still catch it. The fix-it removes the arm. Arms match [exact types](/docs/language/panic/#arms-match-exact-types): `catch e: Base` does not catch a `Derived`. A C++ type outside the set is a [C++ exception](/docs/language/c-cpp-exceptions/#exceptions) arm and is never reported.

### SC001W: `'finally' runs when the enclosing block exits, like any 'finally', not when the 'try' before it finishes`

A `finally` written directly after a `try`/`catch`, on the line of its closing brace (`} finally {`) or the next, is the ordinary [scope-exit `finally`](/docs/language/panic/#finally): it runs when the enclosing block is left, after whatever follows it in the block, and a `return`, `break` or uncaught panic leaving the `try` never reaches it, so it does not run on that path. A note points at the closing brace where it runs, another at the `try`. There is no fix-it, since no edit keeps the meaning and silences it. To clean up as soon as the `try` is done and on every way out of it, register the `finally` first, in a block of its own: `{ finally { ... } try { ... } catch { ... } }`.

### SC001W: `'{p as *D}' crashes the program when the object is not a '{D}'; use '{p as *D}?' and test the result for cleaner handling`

Every [asserting downcast](/docs/language/casting/#downcasting-base-to-derived) warns: on the wrong dynamic type it crashes the program (it is not a panic and cannot be caught). The fix-it appends `?`, turning it into the checked downcast, which yields null on a miss.

### SC001E: `a second 'catch' arm for '{T}'` / `no 'catch' arm may follow a bare 'catch'`

Two arms for the same type, or any arm after a bare `catch` (which has already handled everything), are errors with a fix-it removing the arm. In the expression form an arm after the default is a syntax error (S054E).

### SC001E: `two 'catch' arms of one 'try' catch '{T}' in '{f<A>}': the first takes every '{T}', and the second never runs`

In a [generic function](/docs/language/panic/#generic-functions), two arms that name different types in the body (`catch e: T` beside `catch e: Missing`) catch the same type at some instantiation (`T = Missing`). Reported where that instantiation is used, with notes at both arms and, when a generic body reached the instantiation, one note per call in the chain. Catch the parameter's type in its own function, or bound the parameter so the two cannot meet.

### SC001E: `the panic set of '{f}' grows without bound: it calls itself (or a function that calls it) at ever-larger type arguments`

A [generic function](/docs/language/panic/#generic-functions) whose inferred set includes what a recursive call at a larger type raises (`f(Box<T> { v: x })` inside `f<T>` lets `Box<T>` through, which lets `Box<Box<T>>` through, and so on). Declare the set, and catch what the recursive call adds outside it.

### SC001E: `'catch' of the C++ exception '{T}' in a build without C++ exceptions (-fno-exceptions, or a target with no OS)`

A `catch e: T` arm whose `T` is a C++ type outside the `try` body's panic set [catches a C++ exception](/docs/language/c-cpp-exceptions/#c-to-kairo), which needs C++ exceptions. They are off with `-fno-exceptions`, and by default for a target with no OS (or `--freestanding`). A note points at the C++ type; the fix-it removes the arm. The code is a placeholder until the error gets its own.

**Fix:** remove the arm, or build with `-fexceptions`.

### SC001E: `'op panic' takes 'const self'` / `'op panic' must return 'string'`

[`op panic`](/docs/language/operator-overloading/#op-panic) is optional, but when a type defines it, it is `fn op panic (const self) -> string`. Fix-its insert `const` and write `string`. An operand besides `self` is SC055E (`'op panic' takes no operand besides the receiver`).

### S055E: `an explicit panic set names at least one error type`

`panic()` with nothing inside, in a function header, a closure or a function type. A bare `panic` already means an inferred set. Fix-it: remove the parentheses.

### SC001E: `'{A}' and '{B}' cannot be in one panic set: both have type id 0x{id}`

Every error type has a 32-bit type id, the tag its errors are stored with, computed from the type's full name so every file agrees on it. Two types whose ids are equal cannot be in one panic set: their errors would be indistinguishable. This is astronomically rare; it is reported where the set is formed, with a note at each type. The code is a placeholder until the error gets its own.

**Fix:** rename one of the two types, or keep them in different sets (handle one of them before the other propagates).

### OPT001R: `'{Panic}' is {n} bytes, so a function returning it returns through memory, not in two registers`

A remark, not a warning. A panicking function's result is returned in two registers while it is at most 16 bytes: the tag and site word, plus a payload of at most 8 bytes. One wider error type (or a wider return type) makes every function with that set return through memory: correct, just slower. The remark names the widest payload. The code is a placeholder until the remark gets its own.

**Fix:** nothing is required. To keep the fast path, panic with a small error (an id, or a pointer to the details).

---

## Imports

### R016E: `ambiguous import: '{name}' names more than one non-function symbol`

One imported name refers to more than one thing that is not a function, for example two types imported from two modules. Functions merge into one overload set; other declarations cannot.

```kairo
import bar::{Box}
import baz::{Box}    // error R016E, reported here
```

When a Kairo import is involved, the error is reported at the import. When every candidate comes from C or C++ headers, it is reported where the name is used, as C++ does, and a note points at each candidate and says what it is (variable, typedef, struct, ...). Importing such headers is not an error by itself.

A header struct and a variable or function with the same name are not ambiguous: the name means the variable or function, and the struct can be named with `ffi "c" struct T`. See [Tags and ordinary names](/docs/language/c-cpp-calling/#tags-and-ordinary-names).

**Fix:** import one of the conflicting names under an alias (`import Foo::{Bar as FooBar}`), or import a header under an alias (`ffi "c++" import "a.h" as a`) and qualify the name.

---

## Members

### SC001W: `nested type '{N}' of '{T}' is named without a qualifier; write 'Self::{N}' so it reads as a member`

A nested type, type alias (`type alias '{N}'`) or associated type (`associated type '{N}'`) of the enclosing type, named bare inside its body. It is legal, the one exception to [Members always need a qualifier](/docs/language/classes/#members-always-need-a-qualifier), but nothing at the use says the name is a member. Warned in type and expression position, in a class, struct, union or interface body, an `extend` block, an out-of-line `fn Type::method` and a closure in any of those. The code is a placeholder until the warning gets its own.

```kairo
class Tree {
    struct Node { var value: i32 }

    fn root(self) -> i32 {
        var n = Node { value: 0 }   // warning SC001W: write 'Self::Node'
        return n.value
    }
}
```

The note points at the declaration, and a fix-it inserts `Self::`. Only the innermost type counts: inside a nested type, its own name and the members of the type around it are not warned. Nested modules are not warned.

**Fix:** write `Self::Node`.

### SC001E: `'{f}' is a static requirement; it takes no 'self' and is called through the type, not a value`

A static [interface requirement](/docs/language/interfaces-requirements/) (one with no `self`) called through a value: `y.make(2)` on `y: T` with `<T impl I>`. The same error reads `static extension member` for a static method added by an [`extend`](/docs/language/extends/) block. A requirement dispatches on the type, so a value names nothing to call it on. A plain class's `static` method called through a value is not an error. The code is a placeholder until the error gets its own.

```kairo
interface I { fn make(x: i32) -> i32 }

fn <T impl I> f(y: T) -> i32 {
    return y.make(2)    // error SC001E: write 'T::make(2)'
}
```

The note points at the declaration, and a fix-it replaces the receiver with its type: `T::make(2)`.

**Fix:** call it through the type.

## Generics

### SC001E: `'{T}: type' needs -fduck-generics: a generic body is checked against its bounds, not per instance`

A [`: type`](/docs/language/generics/#the-type-regime-transitional) generic parameter in a build with `-fno-duck-generics`. `: type` is a transitional regime in which the C++ compiler checks the body per instantiation instead of Kairo checking it against bounds. It is on by default until the compiler compiles itself; `-fno-duck-generics` turns it off. The label is on `: type`. The code is a placeholder until the error gets its own.

```kairo
fn <T: type> show(t: T) -> i32 { return t.value() }   // error SC001E; note at 't.value'
fn <T: type> same(t: T) -> T { return t }             // error SC001E; fix-it deletes ': type'
```

If the body uses no member of `T`, a fix-it deletes `: type`, since an unbounded `T` accepts the same body. If it does, a note points at the first member use instead. Deleting the bound there would only lead to R051E (an unbounded parameter has no members).

**Fix:** bound the parameter with an interface that declares the members the body uses (`<T impl Valued>`), or drop `-fno-duck-generics` while the code is being migrated.

### R051E / R025E: `'{op}' on '{T}' needs a bound that declares '{requirement}'`

A generic body uses an operator, a conversion or an interpolation on a value of a type parameter that nothing grants. The body is [checked once against its bounds](/docs/language/generics/#type-parameter-constraints), so the error is at the use, in the generic, whatever the generic is later used with. R051E when the parameter has no bound at all (a note points at it: `'T' is declared with no bound`); R025E, ending `; none of the bounds of 'T' does`, when it has bounds and none declares the requirement. The forms: `'==' on 'T' needs a bound that declares 'op =='` (`!=` names `op !=` or `op ==`, a relational `op <=>`, `+` `op +=`, `+=` `op +`), `'===' on 'T?' compares the values with 'op ==', so it needs a bound on 'T' that declares 'op =='`, `'as string' on 'T' needs a bound that declares 'op as' returning 'string'`, and `formatting a 'T' needs a bound that declares 'fn repr(self) -> string' or 'op as' returning 'string'`.

```kairo
fn <T> eq(a: T, b: T) -> bool = a == b              // error R051E
interface Same { fn op ==(const self, other: Self) -> bool }
fn <T impl Same> eq2(a: T, b: T) -> bool = a == b   // ok: the bound's 'op =='
```

A `<T: type>` parameter is exempt: C++ checks its operators per instance. A null test on a `T` (`t?`, `t == null`) is the ordinary "is not nullable" error: a `T` is never null.

**Fix:** bound the parameter with an interface that declares the operator, or take the value at its concrete type.

### SC001E: `a value of type '{T}' can only be matched by a binding, '_' or 'default' (with a 'where' guard)`

A `match` pattern other than a binding or `_` on a value of a type parameter. No bound gives `T` variants, fields or values a literal could equal; a note points at the parameter. The code is a placeholder until the error gets its own.

**Fix:** bind the value and test it in a `where` guard through a bound's requirement, or match on a type whose variants are known (a generic ADT `Rep<T>` is fine).

### SC001E: `'{X}' does not conform to '{I}'`, in an instance a generic reached

A bound is checked where it meets a concrete argument, including in an instance that only another generic's body asks for: `outer<Metric>` calling `inner(Wrap<T> { item: a })` instantiates `inner<Wrap<Metric>>`, and its `U impl Named` bound is checked with `U = Wrap<Metric>`. The error is at the use that started the chain, the one written in your code. Notes name the bound and the missing requirement, then one note per step of the chain, innermost first, at the call in the generic's body that needed the instance:

```kairo
pub fn <U impl Named> inner(a: U) -> i32 { return a.name_len() }
pub fn <T impl Scalable> outer(a: T) -> i32 {
    return inner(Wrap<T> { item: a })      // note: in instantiation of 'inner<Wrap<Metric>>' required here
}
fn main() -> i32 {
    return outer(Metric { base: 3 })      // error SC001E: 'Wrap<Metric>' does not conform to 'Named'
}
```

A chain longer than five steps shows the innermost three, a note counting the steps left out, and the outermost two. `--cmax-generic-backtrace=N` changes the five; `0` shows every step. An instance that fails is reported once, at the first use that needs it. The code is a placeholder until the error gets its own.

**Fix:** make the argument conform (an extension can add the missing member to `Wrap`), or bound the outer generic so the call cannot be made with it.

### SC001E: `cannot decide whether a partial specialization of '{X}' applies to these arguments`

A [partial specialization selected by `requires`](/docs/language/requires/#partial-specializations-selected-by-requires) matches an instantiation by its pattern, but its clause needs something the compiler does not compute while choosing (the `sizeof` of a struct, an `eval` function). It is not chosen, and the use is an error; a note points at the partial. Two partials that both apply with neither more specialized are `ambiguous partial specializations of '{X}' for these arguments`. The codes are placeholders until each gets its own.

**Fix:** select by the pattern instead, or test a builtin type's size.

### SC001E: `every overload in the 'where' dispatch of '{f}' must have the same {what}; C++ sees them as one function`

Besides the return type and `const self`, a [`where` group of generic functions](/docs/language/where/#fallback-requirement) must agree on its type parameters' names and its bounds (`generic parameter names`, `bounds`). A second overload with no `where` clause is R029E, a redefinition.

### SC001E: `instantiation depth exceeds {n}: ...`

Each instance a generic body reaches can reach more. A chain that never ends, such as a function that calls itself with its argument wrapped once more, is reported once it is longer than `--cmax-generic-depth` (128 by default), at the use that started it. The message names the first three and the last three instances of the chain, and a note points at the call that would have gone one step deeper.

```kairo
pub fn <T> f(x: T) -> i32 {
    return f(Wrap<T> { item: x })   // note: 'f<Wrap<...<i32>...>>' is required here, instantiation 129 of the chain
}
fn main() -> i32 {
    return f(1)   // error SC001E: instantiation depth exceeds 128: 'f<i32>' -> 'f<Wrap<i32>>' -> ...
}
```

A pointer to the class itself at a bigger argument (`var p: *L<Wrap<T>>` in `L<T>`) is reported the same way today, although following a pointer instantiates nothing. The code is a placeholder until the error gets its own.

**Fix:** end the recursion at a fixed type (dispatch on a value instead of a type, or stop wrapping), or raise the limit with `--cmax-generic-depth=N` when the chain is finite and just long.

## Compile-Time Values

The errors of [array lengths and generic value arguments](/docs/language/generics/#computed-lengths-and-arguments) that are computed at compile time. The codes are placeholders until each gets its own.

### SC001E: `an array length can call only 'eval' functions; '{f}' is not 'eval'`

A length or value argument is computed at compile time, so a function it calls must be `eval`. A note points at the function; when it is yours, the fix-it adds `eval`. (`a generic value argument can call ...` is the same for an argument.)

### SC001E: `'{T}' cannot be the type of a generic value parameter: {why}`

An [eval class](/docs/language/generics/#eval-classes-as-value-parameters) used as a value parameter's type must be structural: `{why}` names the first field that is not `pub`, is `mutable` or points to mutable memory (through nested fields: `its field 'inner' is a 'Hidden', and its field 'secret' is not 'pub'`), or the first of its constructors that is not `eval`, or a destructor. A note points at it.

### SC001E: `the condition of an 'eval if' outside a function body must fold before names are resolved; 'sizeof' needs a type's layout, ...`

A declaration-scope [`eval if`](/docs/language/eval/#eval-if) decides which declarations exist before types are resolved, so `sizeof` and `alignof` cannot be part of it. The note names what works: `defined!(__LP64__)` for the pointer width, or the `eval if` moved into a function body, where it is decided with the layout known.

---

## Not Yet Supported

### SC116E: a feature is not yet supported

The construct is part of the language but the current compiler does not handle it yet. The message names it:

```
{what} is not yet supported
```

It is reported for:

- iterating a vector, set, map, or string
- `label!` and `jump!` in user code
- matching a string against a pattern that isn't a string literal or a constant initialized with one
- matching a record value against a literal-style pattern
- an initializer on an `eval` field, and one on an array-typed field that is `static`, an array of arrays, or not a list literal
- in a constructor that initializes a `const` field or a field without a default: a generic constructor or one with an expression body; `try`, `finally`, an `inline` block, `label!` or `jump!` before the last such initialization; a `static` or array local declared before it and used after it; initializing an array field of arrays, or one whose length is a generic parameter
- a vector, set, map or f-string in an `eval` context (`a vector in an eval context is not yet supported`); a string literal is fine
- an array length computed by C++ from an `eval` constant of the field's own class (`an array length computed by C++ from 'J', an 'eval' constant of the field's own class, is not supported`): inside its own body the class is incomplete. A note points at the constant; the fix-it moves it to module scope
- an array length or generic value argument that calls an `eval fn` (or reads an `eval` constant computed by one) in a declaration's type, a field or a signature (`... is not yet supported in a declaration's type; write it inside a function body, or make the constant fold`); inside a function body it is accepted
- a generic value parameter whose type is neither an integer nor an eval class (`<eval B: bool>`)
- a generic record's field default that reads another field
- an attribute applied to an expression, such as `@create T(args)` (`the expression attribute '@create' is not yet supported`)
- building or matching a [pack-expanded variant](/docs/language/enums-adt/#variadic-enums) at a type that depends on a generic parameter, and a pack-expanded variant's field whose type is built from the pack (`e: *E`)
- naming the panic result type `Panic<T, E...>` in source (`a panic result type cannot be named yet`): a panicking call's result is handled with `try` or propagated, not stored
- keeping a panic result in a variable (`a stored panic result is not yet supported`), such as `var copy = e` for a bare `catch e`'s binding (re-panicking it with `panic e` is fine), and a function type whose panic set names a generic parameter
- a call of a panicking operator (`a call of a panicking operator is not yet supported`)
- a [`panic`](/docs/language/panic/) function under a [`<T: type>`](/docs/language/generics/#the-type-regime-transitional) parameter, a generic `panic` closure, a `panic` generator or `async` function or closure, and a `panic` statement or a call that may panic inside such a body (bounded and unbounded generics are [supported](/docs/language/panic/#generic-functions))
- a call whose callee's panic set names a generic parameter the call does not bind (no bound declares the requirement it calls)
- [`where` dispatch](/docs/language/where/) on a generic function, a `virtual` or `override` method, an `extend` member, an operator, a constructor, an out-of-line definition, a forward declaration, a generator, an `async` function, a variadic function, or an overload with a default argument (`'where' dispatch on a generic function is not yet supported`)

It means "not yet supported", not "invalid": the code is correct Kairo that the current compiler cannot build.

```kairo
struct P { var x: i32  var y: i32 }

fn by_name(p: P) -> i32 {
    var {x, y} = p        // error SC116E
    return x + y
}
```

> [!NOTE]
> For struct destructuring, read the fields one by one: `var x = p.x`.

**Fix:** rewrite around the construct for now. See [Status](/docs/status/).

---

## Scripts

The errors of [script mode](/docs/language/modules/#scripts): a file with top-level statements and no `fn main`.

### `script variable '{x}' is read before the line that gives it a value has run`

A top-level variable whose initializer is not a constant gets its value at its own line. Reading it in the top-level code above that line, or in its own initializer, reads a value that does not exist yet. A note points at the line.

```kairo
import std::io::println

fn load() -> i32 { return 1 }

println(f"{count}")      // error: read before its line
var count = load()
```

**Fix:** move the read below the line, or give the variable a constant initializer.

### `'{f}' reads script variable '{x}' before the line that gives it a value has run`

A top-level call, made above `x`'s line, of a function in the file that reads `x` on every path. Notes point at the read and at the line. A function that reads it only on some path, or through another function, is not reported: that read is checked when it runs, and stops the program with `script variable '{x}' used before its line ran ({file}:{line})`.

**Fix:** call the function after the line.

### `this 'jump!' crosses the line that gives script variable '{x}' its value`

A top-level `jump!` whose path passes over a line whose initializer runs there: forward, the initializer would be skipped while the reads after the label assume it ran; back, it would run again. Notes point at the line and at the label. (A `jump!` written by the user is also [SC116E](#sc116e-a-feature-is-not-yet-supported) for now.)

### `a file with 'fn main' cannot also have top-level statements; 'main' is where the program starts`

The statements would never run. A note points at `main`.

**Fix:** move them into `main`, or delete `main` to make the file a script.

### `a top-level statement runs only in the program's root file; this file is imported as a module`

Only the file the program starts from runs top-level statements. An imported module, or a `.k` file included from C++, runs none.

**Fix:** move the statement into a function, or into the file the program starts from.

### `two script files in one program: '{a}' and '{b}' each run top-level statements as 'main'`

Every command-line input may be a script, and each script is a `main`, so two in one link are two programs. Reported at the second script's first statement, with a note at the first's. Compiling them with `-c` and no link is not an error.

### `a top-level 'return' gives the program's exit status, an integer; this value is a '{T}'`

A top-level `return` returns from the script's `main`: bare it returns `0`, and a value must be an integer.

### `'{x}' redefined`

A name defined twice in one scope; at the top level that includes two bindings of one name, whatever keyword declares each (`static count` and `var count`). A note points at the first. When both are file-scope bindings, a fix-it renames the second to the first free `{x}2`, `{x}3`, ...; a duplicate field or local gets the error and the note only.

---

## Control Flow

### SC003W: unreachable code

Message: `unreachable code; the statement above always transfers control out of this block`

A statement can never run because the one before it in the same block always leaves: a `return`, `break`, `continue`, `panic` or `jump!`; a call to a function that returns `!`; an `if` with an `else` whose every branch leaves; an exhaustive `match` whose every arm leaves; or an infinite `loop` / `while true` that no `break` exits.

```kairo
fn stop() -> ! { loop { } }

fn f(c: bool) -> i32 {
    if c { return 1 } else { return 2 }
    return 3         // warning SC003W
}

fn g() -> i32 {
    stop()
    return 0         // warning SC003W
}
```

One warning covers the whole dead run of statements, up to the end of the block or the next `label!` (a `jump!` target makes what follows it reachable again). A note points at the statement that leaves. A `return` inside a closure ends only the closure, so code after the closure is not affected. A `match` arm that can never match is reported separately, as SC121E.

The top level of a [script](/docs/language/modules/#scripts) is a block too: code after a top-level `return` is reported. A declaration between the statements (a function, a type, a binding with a constant initializer) is never dead code and is left out of the warning and its fix-it; the dead code after it gets a warning of its own.

**Fix:** delete the dead statements (the fix-it does), or move them above the statement that leaves. See [Control Flow](/docs/language/control-flow/).

---

## Generators

### SC111E: `yield` where nothing can yield

`yield` is allowed only in a function declared `-> yield T`. It is an error outside a function, inside a closure, or in a function with any other return type.

```kairo
fn count() -> i32 {
    yield 1          // error SC111E
    return 0
}
```

**Fix:** declare the function `-> yield T`, or remove the `yield`. See [Generators](/docs/language/functions-generators/#generators).

### SC112E: this kind of function cannot be a generator

`main`, constructors, destructors (`op delete`), `eval` functions, C-variadic functions, and functions returning `!` cannot be declared `-> yield T`.

```kairo
fn main() -> yield i32 { }   // error SC112E
```

**Fix:** move the sequence into a separate `-> yield T` function and call it from here.

---

## Portability

### P003E: a primitive type is not available on the target

`f80` exists only where the target ABI's `long double` is x87 extended precision. The error names the target and what its `long double` is.

**Fix:** use `f64` where `long double` is binary64, or `f128` where it is binary128. See [Primitives](/docs/language/primitives/#f80-follows-the-targets-long-double).

### P007E: bundled sysroot for the target is malformed

A `--target` matched a folder under `<prefix>/sysroot/`, but the folder is not a directory, has no `SYSROOT.toml`, or the manifest does not parse. A note says which.

**Fix:** restore the manifest by re-extracting the sysroot, or remove the folder to fall back to `--sysroot`. See [Cross-compilation](/docs/language/c-cpp-toolchain/#cross-compilation).

---

## Value Arms

The value forms of `if`, `match`, and `try`. See [Control Flow](/docs/language/control-flow/#if-as-an-expression-ternary-equivalent).

### S073E: braced value arm in an 'if', 'try' or 'match' expression

Messages:

- `value arms are written '=> expr'; '{ }' arms are statement-only`

#### value arms are written '=> expr'

the expression forms of `if`, `try` and `match` give each arm its value with `=>`. a `{ }` after a control keyword is always a statement block, so braces cannot hold an arm's value. `=>` introduces exactly one value expression.

##### example

```kairo
var z = if a == b { 2 } else { 0 }                  // error
var n = try { parse(s) } catch { 0 }                // error
var k = match s { case 2 { x + y } default { 0 } }  // error
```

##### how to fix

replace each `{` with `=>` and drop its `}`; the fix-it does this when the braces hold a single expression:

```kairo
var z = if a == b => 2 else => 0
var n = try parse(s) catch => 0
var k = match s {
    case 2 => x + y
    default => 0
}
```

an arm that needs several statements belongs in the statement form (`if c { ... }`, a statement-form `match`), or in a `({ ... })` statement expression. to `try` a brace expression such as a set literal, parenthesize it: `try ({1, 2}) catch => {}`.

### S074E: expected '=>' before a value arm

Messages:

- `expected '=>' after condition`
- `expected '=>' after 'else'`
- `expected '=>' after pattern`
- `expected '=>' after catch arm`

#### expected '=>'

in the expression forms of `if`, `try` and `match`, the condition, the `else`, the case pattern and the catch arm are each followed by `=>` and then the arm's value.

##### example

```kairo
var z = if c 1 else => 2      // missing '=>' after the condition
var z = if c => 1 else 2      // missing '=>' after 'else'
```

##### how to fix

insert `=>` where the fix-it points: `var z = if c => 1 else => 2`.

### S075E: match arms mix '=>' and '{ }' forms

Messages:

- `match arms mix '=>' and '{ }' forms`

#### match arms mix '=>' and '{ }' forms

a `match` in statement position is either a statement (every arm is a `{ }` block) or a value (every arm is `=> expr`). an arm of each kind in one `match` is neither.

##### example

```kairo
match s {
    case 1 { f() }
    default => g()     // the other arms are blocks
}
```

##### how to fix

pick one form for every arm: `default { g() }` for a statement match, or `case 1 => f()` for a value match.

### S076E: match arms separated by a comma

Messages:

- `match arms are not separated by ','`

#### match arms are not separated by ','

the arms of a `match` follow each other directly; a value arm ends where its expression does. a `,` after an arm (the Rust spelling) is not part of the grammar.

##### example

```kairo
var k = match s {
    case 1 => a,       // error
    default => b
}
```

##### how to fix

delete the comma.

### S077E: nested 'if' or 'try' expression must be parenthesized

Messages:

- `an 'if' expression here must be parenthesized`
- `a 'try' expression here must be parenthesized`

#### nested 'if' or 'try' expression must be parenthesized

the last arm of an `if` or `try` expression runs to the end of the surrounding expression. where such an expression sits in front of more of the enclosing construct, it is ambiguous to the reader which construct the following `else`, `=>` or `catch` belongs to, so it must be parenthesized. the positions are:

- the `then` arm, or an `else if` arm, of an `if` expression
- the condition of an `if` or `else if`
- a [`where` guard](/docs/language/pattern-matching/#where-guards)
- the operand of a `try` expression, or any catch arm except the last
- a `match` scrutinee

##### example

```kairo
var z = if a => if b => 1 else => 2 else => 3      // error
var n = try try f() catch => 1 catch => 2          // error
```

##### how to fix

parenthesize the inner expression:

```kairo
var z = if a => (if b => 1 else => 2) else => 3
var n = try (try f() catch => 1) catch => 2
```

an inner `try` takes every `catch` that follows it, so in `try try f() ...` the outer `try` is left without arms and the intended split cannot be recovered; no fix-it is offered there. parenthesize the inner `try` together with its own arms.

an `if` or `try` needs no parentheses as the final `else` arm, the final catch arm, a match arm value, a whole initializer, a call argument or a return value.

### S078W: 'if' or 'try' expression as an operator's operand

Messages:

- `this 'if' expression extends to the end of the expression`
- `this 'try' expression extends to the end of the expression`

#### this 'if'/'try' expression extends to the end of the expression

the last arm of an `if` or `try` expression takes everything up to the end of the surrounding expression. as the right operand of a binary operator, or the operand of a prefix operator, that is easy to misread:

```kairo
var z = x + if c => 1 else => 2 + 5     // x + (if c => 1 else => (2 + 5))
```

the parse is well-defined; the warning is only about readability. assignment operators and variable initializers are exempt, since their right side runs to the end of the expression anyway.

##### how to fix

parenthesize the `if` or `try`: `x + (if c => 1 else => 2) + 5`.

### S079W: '=>' between 'else' and 'if' is redundant

Messages:

- `write 'else if'`

#### write 'else if'

`else => if c => a else => b` and `else if c => a else => b` parse to the same thing, an `if` expression whose final arm is another `if`. only `else if` is idiomatic.

##### how to fix

delete the `=>`; the fix-it does this. to keep a nested `if` as the final arm on purpose, parenthesize it: `else => (if c => a else => b)`.

## See also

- [Panic](/docs/language/panic/)
- [Collections](/docs/language/collections/)
- [Function Overloading](/docs/language/functions-overloading/)
- [Default Parameters](/docs/language/functions-parameters/#default-parameters)
- [Class Lifecycle](/docs/language/classes-lifecycle/)
- [Plain Enums](/docs/language/enums-plain/)
- [Generators](/docs/language/functions-generators/)
- [Pattern Matching](/docs/language/pattern-matching/)
