# Functions

Functions in Kairo follow a consistent declaration syntax for both free functions and class methods. The full
grammar covers visibility, ABI linkage, generics, modifiers, bounds, and return types all optional except
the `fn` keyword, the name, and the parameter list.

---

## Declaration Syntax

```kairo
fn name(param1: Type1, param2: Type2) -> ReturnType {
    // body
}
```

The full grammar:

```bnf
function_declaration ::= visibility? abi_mod? leading_mods? "fn" generics? identifier
                         "(" parameter_list? ")" function_mods? ("->" return_type)? constraint? body

visibility    ::= "pub" | "priv" | "prot"
abi_mod       ::= ("ffi" string_literal) | "static" | "virtual" | "override"
leading_mods  ::= ("inline" | "eval")*       ; same meaning as in function_mods
generics      ::= "<" generic_param_list ">"
function_mods ::= ("const" | "volatile" | "unsafe" | "eval" | "async" | "final" | "panic" | "inline")*
constraint    ::= "requires" expression
return_type   ::= type | "!"
body          ::= block | "=" expression | ε        ; ε = forward declaration
```

All parts except `fn`, the name, and the parenthesized parameter list are optional. When the return type is
omitted, it defaults to `void`.

---

## Parameters

Parameters are declared as `name: Type`. Each parameter requires an explicit type annotation there is no
parameter type inference.

```kairo
fn greet(name: string, loud: bool) {
    if loud {
        std::println(f"HELLO, {name}!")
    } else {
        std::println(f"Hello, {name}.")
    }
}
```

### Default parameters

Parameters can have default values. When a caller omits a defaulted argument, the default is used:

```kairo
fn greet(name: string = "world") {
    std::println(f"Hello, {name}!")
}

greet()          // "Hello, world!"
greet("Alice")   // "Hello, Alice!"
```

A default is evaluated once per call that omits that argument. Any parameter may have a default, not only
trailing ones; a defaulted parameter that comes before a required one is skipped by naming the later
argument (see [Named arguments](#named-arguments)).

#### A default stands alone

A default argument may not mention another parameter or `self`. It is evaluated with no access to the
call's other arguments:

```kairo
fn a(x: i32, y: i32 = x) { }          // compile error (SC106E)
fn m(self, y: i32 = self.v) { }       // compile error (SC106E)
```

When a default depends on another argument, use an overload instead:

```kairo
fn a(x: i32, y: i32) { }
fn a(x: i32) { a(x, x) }
```

A default also may not be a slice literal (`[T;]`), since the slice would view a temporary. Use an owning
`[T]`:

```kairo
fn f(xs: [i32;] = [1, 2]) { }         // compile error
fn f(xs: [i32]  = [1, 2]) { }         // ok
```

#### Defaults apply to the whole function

Defaults belong to the function, not to a point in the file. A default added by a later declaration
applies to every call, including calls written above that declaration. This differs from C++, where a
default is only visible after the declaration that introduces it.

Each parameter may be given a default on any one declaration of the function. Defaults from different
declarations accumulate:

```kairo
fn f0(i: i32, j: i32, k: i32 = 3) -> i32
fn f0(i: i32, j: i32 = 2, k: i32) -> i32
fn f0(i: i32 = 1, j: i32, k: i32) -> i32

f0()        // same as f0(1, 2, 3)
f0(7)       // same as f0(7, 2, 3)
```

Out-of-line class methods have one more restriction: their defaults go on the in-class declaration. See
[Classes](/docs/language/classes#rules).

#### Evaluation order

Explicit arguments are evaluated left to right in the order they are written at the call site, whichever
parameter each one names. Defaults for omitted arguments are evaluated after every explicit argument, in
parameter order:

```kairo
fn g(a: i32 = stamp(1), b: i32) -> i32

g(b: stamp(4))               // stamp(4) runs first, then the default stamp(1)

fn h(a: i32, b: i32) -> i32
h(b: stamp(1), a: stamp(2))  // stamp(1) runs first: written order, not parameter order
```

#### Defaults on imported C++ functions

An imported C++ function keeps its C++ defaults, and C++ applies them. C++ can only leave out trailing
arguments, so naming a later parameter while an earlier defaulted one is omitted is an error (SC107E):

```cpp
// lib.hh
void blit(int x, int y = 0, int scale = 1);
```

```kairo
blit(4, scale: 2)            // compile error (SC107E): 'y' would be skipped
blit(4, y: 0, scale: 2)      // ok
blit(4)                      // ok: trailing defaults left to C++
```

Pass the earlier arguments explicitly.

### Named arguments

Arguments can be passed by name at the call site. Positional arguments must come before named arguments,
matching C++ conventions:

```kairo
fn create_user(name: string, age: i32 = 18, country: string = "USA") -> User {
    return User { name, age, country }
}

create_user("Alice")                              // age=18, country="USA"
create_user("Bob", 25)                            // country="USA"
create_user(name: "Eve", country: "UK")           // age=18
create_user("Grace", 22)                          // country="USA"
create_user(name: "Frank", age: 30, country: "CA") // all explicit
```

### Parameter passing modes

A parameter can be declared in one of three modes. Together they cover every parameter form C++ can
declare, so any C++ signature has an exact Kairo spelling.

| Kairo         | C++               | Callee may           | Caller afterwards            |
| ------------- | ----------------- | -------------------- | ---------------------------- |
| `x: T`        | `T` or `const T&` | read                 | unchanged                    |
| `@inout x: T` | `T&`              | read, write          | sees the callee's writes     |
| `@move x: T`  | `T&&`             | read, write, consume | cannot use the argument      |

```kairo
fn read(x: i32) -> i32 { return x + 1 }          // T / const T&
fn bump(@inout x: i32) { x += 1 }                // int&
fn consume(@move b: Buffer) -> usize { /* ... */ }  // Buffer&&

fn use() {
    var n: i32 = 5
    read(n)          // 6, n unchanged
    bump(&n)         // n is now 6
    read(n)          // 7

    var b = Buffer{}
    consume(b)       // no marker; ownership moves
    b.size()         // compile error: use after move
}
```

#### Modes are not types

`@inout` and `@move` are only allowed on parameters of a `fn` declaration. They cannot appear on locals,
fields, return types, generic arguments, tuple elements, or in any other type position. No type `@inout T`
exists, and a mode cannot be stored or returned.

```kairo
var y: @inout i32  // compile error: '@inout' is a parameter mode, not a type
var @inout y: i32  // compile error
```

#### How `x: T` is passed

For a plain `x: T` parameter of a Kairo function, the compiler picks between passing by value and passing by
`const T&`. Small trivially-copyable types go by value; everything else goes by reference. Callers can't
observe the difference, since the callee can't modify the argument either way. This is why Kairo has no
separate mode for `const T&`.

For a function declared in an imported C++ header, the compiler doesn't choose. The parameter is passed
exactly as the header declares it.

A fixed array `[T; N]` is the exception: it is not a value type, so a plain `xs: [T; N]` parameter is an
error. Take it as `const` or `@inout`, both of which pass by reference, or take a slice:

```kairo
fn f(xs: [i32; 3]) { }          // compile error: parameter 'xs' takes an array by value;
                                //   write 'const', '@inout', or take a slice
fn f(const xs: [i32; 3]) { }    // ok: read-only, by reference
fn f(@inout xs: [i32; 3]) { }   // ok: read-write, by reference
fn f(xs: [i32;]) { }            // ok: a view of any length
```

#### Call-site syntax

| Parameter     | Call     |
| ------------- | -------- |
| `x: T`        | `f(a)`   |
| `@inout x: T` | `f(&a)`  |
| `@move x: T`  | `f(a)`   |
| receiver      | `a.f()`  |

In argument position, `&` marks an `@inout` argument. It is not the address-of operator and never produces
a `*T`. The marker is required, so every mutation of a caller's variable is visible where the call is made,
and it is rejected anywhere else:

```kairo
read(&n)           // compile error: parameter 'x' of 'read' is not @inout
bump(n)            // compile error: '@inout' argument requires '&'

const k: i32 = 5
bump(&k)           // compile error: '@inout' requires a non-const lvalue
bump(&10)          // compile error: '@inout' requires an lvalue
```

`@move` takes no marker. The compiler already rejects any later use of the argument, so a marker would add
nothing.

The receiver is never marked. `fn f(self)` is a non-`const` method and `fn f(const self)` is a `const` method
(`void f() const`). Both are called as `a.f()`:

```kairo
class Counter {
    priv var n: i32

    fn get(const self) -> i32 { return self.n }   // int get() const
    fn tick(self) { self.n += 1 }                 // void tick()
}

var c = Counter{ n: 0 }
c.tick()
var v = c.get()
```

#### Overload resolution

Mode resolution follows C++ ([over.ics.rank]), so an imported overload set picks the same function in Kairo
as it does in C++:

| Argument                   | `x: T` | `@inout x: T`       | `@move x: T`        |
| -------------------------- | ------ | ------------------- | ------------------- |
| non-`const` lvalue         | viable | **viable, preferred** | not viable        |
| `const` lvalue             | viable | not viable          | not viable          |
| rvalue (prvalue or xvalue) | viable | not viable          | **viable, preferred** |

```kairo
// std::vector<i32>::push_back(const int&) and push_back(int&&)
var v: std::vector<i32>
var n: i32 = 7

v.push_back(n)     // lvalue  -> push_back(const int&)
v.push_back(1)     // prvalue -> push_back(int&&)
```

#### Overloading on mode

Modes are part of a function's signature. `x: T`, `@inout x: T`, and `@move x: T` are three distinct
overloads. A C++ class that declares `set(const int&)`, `set(int&)`, and `set(int&&)` gets three separate
out-of-line definitions:

```kairo
// cxx.hh:
//   class Widget {
//     void set(const int&);
//     void set(int&);
//     void set(int&&);
//     int  at(size_t) const;
//     int& at(size_t);
//   };

ffi "c++" import "cxx.hh"

fn Widget::set(x: i32)        { }   // const int&
fn Widget::set(@inout x: i32) { }   // int&
fn Widget::set(@move x: i32)  { }   // int&&

fn Widget::at(const self, i: usize) -> i32 { /* ... */ }   // int  at(size_t) const
fn Widget::at(self, i: usize) -> *i32      { /* ... */ }   // int& at(size_t)
```

The `at` pair shows the one exception to the [const overloading restriction](#const-overloading-restriction):
when an imported declaration has a `const`/non-`const` pair, as standard containers do for `at`, `front`,
`back`, `begin`, `end`, and `data`, receiver const-ness is part of the signature and both members can be
defined out of line.

C++ can't overload `f(T)` against `f(const T&)`, and in Kairo both are spelled `x: T`, so that ambiguity never
arises in Kairo code. If an imported header declares both, the compiler reports an error at the import,
naming the header, not at each call.

Overriding an imported virtual uses the same spelling:

```kairo
// cxx.hh:  class Base { virtual void foo(int& x); };

class Derived derives Base {
    override fn foo(@inout x: i32) { x = 42 }
}

var d = Derived{}
var n: i32 = 0
d.foo(&n)        // n is 42
```

#### Reference returns from C++

Modes don't exist in return position. An imported function returning a reference is seen as returning a
pointer, and the value category keeps the reference's meaning:

| C++ return  | Kairo type | Value category |
| ----------- | ---------- | -------------- |
| `T&`        | `*T`       | lvalue         |
| `const T&`  | `*const T` | lvalue         |
| `T&&`       | `*T`       | xvalue         |

Because a `T&&` return is an xvalue, `f(g())` where `g` returns `T&&` selects `f`'s `@move` overload, as it
does in C++.

The call itself is usable as the referenced value, the same way `v[0]` is: as an operand, and as the target
of an assignment or compound assignment.

```kairo
ffi "c++" import <vector>;

var v: cxx::std::vector<i32>
v.push_back(1)

v.at(0) = 3                 // assigns through the returned int&
v.at(0) += 2                // 5
var x = v.at(0) + 1         // 6
```

The same holds for `*p` and for operators that return a reference, such as `cout << x`.

#### `@move` is checked

`@move` is checked against the parameter's type, not just recorded:

- **Move-only class:** `@move` is redundant, since passing already consumes the argument (see
  [Ownership](/docs/language/ownership#function-parameters)), but it's allowed and checked.
- **Copy-only class:** `@move` is a compile error.
- **Generic `T`:** `@move` is the only way to declare that the function consumes its argument. The body can
  then consume `x` whatever `T` turns out to be.

In every case the call counts as the consuming use, and any later use of the argument in the caller is a
[use-after-move error](/docs/language/ownership#moved-from-state).

#### Imported-only forms

Some C++ forms can be imported and called from Kairo but can't be declared in Kairo source, including as
out-of-line definitions:

- `const T&&` parameters. They bind rvalues without consuming them, and C++ uses them almost only as
  deletion targets.
- Functions returning a reference. Kairo has no `std::move`, because whether a transfer moves is decided by
  the type, not by the expression, so it never needs to return one.

Kairo also deliberately has no call-site marker for `@move` and no separate mode for `const T&`.

---

## Return Types

### Explicit return

```kairo
fn add(a: i32, b: i32) -> i32 {
    return a + b
}
```

### Implicit `void`

When no return type is specified, the function returns `void`:

```kairo
fn log(msg: string) {
    std::println(msg)
}

fn log_explicit(msg: string) -> void {   // equivalent
    std::println(msg)
}
```

### Arrays are not returned

A function cannot return a fixed array `[T; N]` by value. Return a vector `[T]`, or fill an `@inout`
parameter:

```kairo
fn make() -> [i32; 3] { ... }           // compile error: 'make' returns an array
fn make() -> [i32] { return [1, 2, 3] } // ok: the caller owns a vector
fn make(@inout out: [i32; 3]) {         // ok: the caller owns the array
    out[0] = 1; out[1] = 2; out[2] = 3
}
```

Returning a slice literal is also an error, because the literal's storage ends with the function. See
[Primitives](/docs/language/primitives#how-long-a-slice-literals-storage-lives).

### No-return `!`

Functions that never return they always panic, loop forever, or call a no-return function use `!` as
their return type:

```kairo
fn fatal(msg: string) -> ! {
    std::println(f"Fatal: {msg}")
    std::crash(1)
}

fn event_loop() -> ! {
    loop {
        process_events()
    }
}
```

`!` is the **no-return type**. It is a subtype of every type, meaning it can appear anywhere a value is
expected:

```kairo
var x: i32 = if valid { compute() } else { fatal("bad state") }
// fatal() returns ! which coerces to i32
```

> [!WARNING]
> No-return functions cannot have a `panic` specifier. Since `panic` acts as an alternative return path, it
> contradicts the guarantee that the function never returns. The compiler rejects `fn f() panic -> !`.

### Special return types

These return type modifiers interact with Kairo's concurrency and type system. Each is covered in detail on
its respective page:

| Return type | Description | Details |
|---|---|---|
| `yield T` | Generator: produces a sequence of `T` values | [Generators](#generators) |
| `atomic T` | Atomic wrapper thread-safe operations | [Concurrency](/docs/language/concurrency) |
| `thread T` | Thread-local storage | [Concurrency](/docs/language/concurrency) |

### Generators

A function is a **generator** when its return type is written `-> yield T`. Calling it does not run the body;
it returns a sequence that runs the body a step at a time as values are asked for, most often by a `for` loop.

```kairo
fn generate_numbers() -> yield i32 {
    for i in 0..10 {
        yield i
    }
}

for n in generate_numbers() {
    std::println(n)
}
```

Only the written return type makes a generator. A spelled-out `-> Yield<T>` is an ordinary function that
returns a `Yield<T>` value, and a `yield` in the body does not turn a function into a generator.

In a generator's body:

- `yield e` produces the next value. `e` must convert to `T`.
- Yielding a slice literal is an error: its backing array ends at the suspension, before the caller sees the
  value.
- A bare `return` ends the sequence early. `return e` is an error, since a generator has no return value.
- Falling off the end of the body also ends the sequence. There is no missing-return error.
- A generator with no `yield` at all is valid and produces nothing.

```kairo
fn first_positive(xs: [i32;]) -> yield i32 {
    for x in xs {
        if x > 0 {
            yield x
            return      // ok: ends the sequence
        }
    }
}                       // ok: falling off the end also ends it
```

`yield` is an error (SC111E):

- outside a function;
- inside a closure (closures cannot yield yet);
- in a function not declared `-> yield T`.

These functions cannot be generators (SC112E): `main`, constructors, destructors (`op delete`), `eval`
functions, C-variadic functions, and functions returning `!`.

#### Generator lifetimes

A generator can do one thing an ordinary function cannot: its suspended body keeps references to `self` and
to `@inout` arguments after the call that created it has returned.

- A loop like `for x in xs.gen()` keeps `xs` alive for the whole loop, so it is safe.
- A generator stored in a variable can outlive what it refers to, and then dangles.

Do not keep a generator longer than the object it was created from.

```kairo
var it = make_list().gen()   // the list is destroyed at the end of this statement
for x in it { }              // it reads a destroyed list
```

> [!NOTE]
> The current compiler does not report a generator that outlives what it refers to. See
> [Implementation Status](/docs/status#not-diagnosed).

---

## Expression-Bodied Functions

Single-expression functions can use the `=` shorthand, omitting braces and `return`:

```kairo
fn add(a: i32, b: i32) -> i32 = a + b
fn square(x: f64) -> f64 = x * x
fn greeting(name: string) -> string = f"Hello, {name}!"
```

The return type annotation is optional for expression-bodied functions it is
inferred from the expression when omitted. This is the only form of return type
inference in Kairo; block-bodied functions always require an explicit return type
(or default to `void`).

```kairo
fn add(a: i32, b: i32) = a + b              // inferred as i32
fn greeting(name: string) = f"Hi, {name}!"  // inferred as string
```

Explicit annotations are still useful when you want to constrain or widen the
inferred type:

```kairo
fn promote(x: i32) -> i64 = x as i64        // would otherwise infer i32
```

---

## Function Return

`return` exits the current function with a value. For `void` functions, `return` takes no operand.

```kairo
fn max(a: i32, b: i32) -> i32 {
    if a > b {
        return a
    }
    return b
}

fn log(msg: string) {
    std::println(msg)
    return   // explicit return from void function valid but optional
}
```

Early returns are permitted anywhere in a function body. The compiler verifies that all code paths return a
value of the declared return type.

---

## Function Overloading

Functions can be overloaded by parameter types, matching C++ overload resolution rules:

```kairo
fn add(a: i32, b: i32) -> i32 = a + b
fn add(a: f64, b: f64) -> f64 = a + b
fn add(a: string, b: string) -> string = a + b
```

Parameter modes also participate in overloading. See [Overloading on mode](#overloading-on-mode).

A candidate either matches an argument exactly or through a conversion, and there is no ordering among
conversions: if two candidates both need one, the call is ambiguous (`call to 'f' is ambiguous: more than
one candidate matches at the same rank`). For a list literal argument, a `[T; N]` parameter with the same
element count is an exact match, while `[T;]` and `[T]` parameters both need a conversion:

```kairo
fn f(const xs: [i32; 3]) { }
fn f(xs: [i32;]) { }
fn f(xs: [i32]) { }
f([1, 2, 3])                // [i32; 3]

fn g(xs: [i32;]) { }
fn g(xs: [i32]) { }
g([1, 2, 3])                // compile error: call to 'g' is ambiguous
g([1, 2, 3] as [i32])       // ok
```

See [Primitives](/docs/language/primitives#list-literal-arguments)
for the ranking rules.

### Unsafe overloads

The `unsafe` modifier creates a separate overload in its own namespace. Safe and unsafe versions of the same
function coexist the caller explicitly selects which one to invoke:

```kairo
fn add(a: i32, b: i32) -> i32 {
    return a + b
}

fn add(a: i32, b: i32) unsafe -> i32 {
    return a << 1 + b << 1   // faster but semantically different
}

var x = add(10, 20)          // calls the safe version
var y = unsafe add(10, 20)   // calls the unsafe overload
```

> [!NOTE]
> `unsafe` overloads are not "unsafe memory" Tether still guarantees memory safety. The `unsafe` qualifier
> signals that the function may not uphold other invariants that the safe version does. See
> [Unsafe](/docs/language/unsafe) for the full unsafe model.

### Const overloading restriction

`const` and non-`const` methods with the same name and parameter types cannot coexist, use distinct names like `get()` and `get_mut()`. This restriction applies to named methods declared in Kairo source. An imported C++ class may have such a pair, and both members can be defined out of line (see [Overloading on mode](#overloading-on-mode)). **Place operators are exempt**, because they cannot be renamed: a place-returning operator (`[]`, `->`) may declare both a `self` overload (returning `*T`) and a `const self` overload (returning `*const T`), dispatched by receiver const-ness. See [Operators](/docs/language/operators#const-overloading-operators).

```kairo
class Foo {
    fn bar(const self) -> i32 { return 42 }
    fn bar(self) -> i32 { return 24 }               // compile error: cannot overload const
    fn bar(const self, a: i32) -> i32 { return a }  // ok: different parameter list ok

    fn op [](const self, index: i32) -> *const i32 { /* ... */ }   // ok: place operator
    fn op [](self, index: i32) -> *i32 { /* ... */ }               // ok: const-ness dispatch

    fn op +(self, o: Foo) -> Foo { /* ... */ }
    fn op +(const self, o: Foo) -> Foo { /* ... */ }  // compile error: not a place operator
}
```

---

## Variadic Functions

The `...` prefix on a parameter name accepts any number of arguments of the same type. Inside the body,
`...xs: T` is a slice `[T;]` over the run of arguments. The slice is passed by value and is valid for the
duration of the call; it views the arguments, so do not store it or return it.

```kairo
fn sum(...xs: i32) -> i32 {
    var total = 0
    for i in 0..xs.len {
        total += xs.data[i]
    }
    return total
}

sum(1, 2, 3)        // 6
sum(10, 20, 30, 40) // 100
sum()               // 0: an empty pack is a zero-length slice
```

Parameters after a pack are keyword-only, since every positional argument goes into the pack:

```kairo
fn join(...parts: string, sep: string = " ") -> string { /* ... */ }

join("a", "b", "c")             // "a b c"
join("a", "b", sep: ", ")       // "a, b"
```

### Generic variadic functions

Combine `...` with generic type packs to accept arguments of different types:

```kairo
fn <...T> print_all(...args: T) {
    for arg in args {
        std::println(arg as string)
    }
}

print_all(42, "hello", true)   // prints each on a new line
```

The parameter is a tuple of heterogeneous types. Each element in the pack must satisfy the constraints used
in the function body in the example above, every `T` must be convertible to `string` via `as`.

### Pack expansion and forwarding

A pack expands with a **postfix** `...` in expression position — declaration is prefix (`...args`),
use is postfix (`args...`). The most common case is forwarding a pack to another call:

```kairo
fn <...T> log_all(...args: T) {
    print_all(args...)         // forwards every element as a separate argument
}
```

The same postfix form appears in type position for pack-typed signatures. The split mirrors the
token-macro splat: `...` before a name declares a pack, `...` after an expression expands one.

---

## Generic Functions

Generic functions declare type parameters in angle brackets before the function name:

```kairo
fn <T> identity(x: T) -> T {
    return x
}
```

Constrain type parameters with `impl` (interface conformance) or `derives` (class inheritance):

```kairo
fn <T impl Comparable> max(a: T, b: T) -> T {
    return if a > b { a } else { b }
}

fn <T derives Serializable> serialize(value: T) -> [byte] {
    return value.to_bytes()
}
```

> [!NOTE]
> `impl` checks structural conformance the type satisfies the interface's required method signatures
> without needing an explicit `impl` declaration. `derives` checks polymorphic inheritance the type is a
> subclass of the specified class. See [Interfaces](/docs/language/interfaces) and
> [Requires Clauses](/docs/language/requires) for details.

### Requires Clauses

For constraints beyond type parameter bounds, attach a `requires` clause after the return type:

```kairo
fn <T impl ToString> print_value(value: T) requires sizeof T <= 64 {
    std::println(value as string)
}
```

`requires` is a compile-time gate: the condition must hold at compile time or the program does not
compile — no runtime fallback, no dispatch. See [Requires Clauses](/docs/language/requires) for the
full constraint system and [Where Clauses](/docs/language/where) for runtime-conditional overload
dispatch.

---

## Function Modifiers

Modifiers appear after the parameter list and before the return type arrow. Multiple modifiers can be
combined, subject to the compatibility rules below. `inline` and `eval` may also be written before `fn`
(`pub inline fn twice(x: i32) -> i32`); both positions mean the same thing.

```kairo
fn compute(x: i32) inline -> i32       { return x * x }
fn dangerous() unsafe -> void          { /* ... */ }
fn compile_time() eval -> i32          { return 42 }
fn may_fail() panic -> i32             { /* ... */ }
fn background() async -> Data          { /* ... */ }
```

### Modifier reference

| Modifier | Free functions | Methods | Description |
|---|---|---|---|
| `const` | | Yes | Method does not modify `self`. See [Variables](/docs/language/variables#the-const-binding-rule) |
| `volatile` | Yes | Yes | Prevents certain compiler optimizations; for hardware interaction |
| `unsafe` | Yes | Yes | Separate overload namespace for alternative implementations |
| `eval` | Yes | Yes | Must be evaluable at compile time. See [Eval](/docs/language/eval) |
| `async` | Yes | Yes | Asynchronous execution. See [Concurrency](/docs/language/concurrency) |
| `panic` | Yes | Yes | May panic; callers must handle. See [Panic](/docs/language/panic) |
| `inline` | Yes | Yes | Puts the body in the interface. See [`inline`](#inline) |
| `final` | | Yes | Prevents override in subclasses. See [Classes](/docs/language/classes) |

### `inline`

`inline` puts the body in the interface: importers compile it themselves. Use it for small functions on
hot paths, and for functions the C++ compiler calls on your behalf (coroutine promises and awaiters).

```kairo
pub inline fn twice(x: i32) -> i32 { return x * 2 }
```

Every module that can see the declaration gets the definition and compiles it, so the optimizer can inline
the call there. In C++ terms it is an `inline` function: one shared definition that the linker merges across
objects. It is not a request to force inlining.

- An `inline` function must have a body, in the same file as its declaration (an in-class declaration may be
  defined out of line in that file). An `inline` declaration with no body is an error.
- Every declaration of the function must agree on `inline`.
- Unused `inline` bodies cost parse time only: no code is generated for one nothing calls.

### Modifier compatibility

Not all modifiers can be combined:

| Combination | Valid | Reason |
|---|---|---|
| `const` + `volatile` | ok: | |
| `const` + `unsafe` | | `unsafe:` implies a separate overload with different invariants |
| `const` + `eval` | | `eval:` implies compile-time evaluation `const self` is meaningless |
| `const` + `async` | ok: | |
| `unsafe` + any other | ok: | `unsafe:` creates a separate overload the other modifiers apply to both versions as appropriate |
| `eval` + `unsafe` | ok: | `eval` and `unsafe` are orthogonal modifiers |
| `eval` + any other (except `unsafe`) | | `eval` implies compile-time evaluation incompatible with runtime modifiers |
| `async` + `const` | ok: | |
| `async` + `volatile` | ok: | |

---

## Visibility

A top-level function with no visibility written is `pub`.

| Keyword | Scope of a top-level function |
|---|---|
| `pub` (default) | Any module that imports this module |
| `priv` | Current file only |
| `prot` | Current file and sibling files in the same library subtree |

```kairo
fn api()                  { /* ... */ }   // pub by default
priv fn internal_helper() { /* ... */ }
prot fn library_helper()  { /* ... */ }
```

See [Modules](/docs/language/modules#visibility-on-top-level-declarations) for how visibility interacts
with imports. Methods follow the member rules in [Classes](/docs/language/classes#default-visibility).

---

## ABI and Linkage

ABI modifiers control name mangling, dispatch mechanism, and symbol visibility at the object code level.

| Modifier | Description |
|---|---|
| `ffi "c"` | C linkage no name mangling. See [C/C++ Interop](/docs/language/c-cpp) |
| `ffi "c++"` | C++ linkage Itanium or MSVC mangling. See [C/C++ Interop](/docs/language/c-cpp) |
| `static` | Internal linkage; no vtable dispatch. Cannot be `virtual` or `override` |
| `virtual` | Dynamic dispatch via vtable. See [Classes](/docs/language/classes) |
| `override` | Overrides a `virtual` method from a base class; implies `virtual` |

`static`, `virtual`, and `override` are mutually exclusive with each other. `ffi` can be combined with any
of them.

```kairo
class Shape {
    virtual fn area(const self) -> f64 { return 0.0 }
}

class Circle derives Shape {
    var radius: f64

    override fn area(const self) -> f64 {
        return 3.14159 * self.radius * self.radius
    }
}

class Math {
    static fn sqrt(x: f64) -> f64 { /* ... */ }
}

Math::sqrt(16.0)   // called without an instance
```

---

## Function Pointers

Functions are first-class values. The type of a function pointer is `fn(ParamTypes) -> ReturnType`:

```kairo
fn add(a: i32, b: i32) -> i32 = a + b
fn sub(a: i32, b: i32) -> i32 = a - b

var #op: fn(i32, i32) -> i32 = add
op(3, 4)   // 7

op = sub
op(10, 3)  // 7
```

Functions can be nested inner functions are scoped to the enclosing function:

```kairo
fn outer(x: i32) -> i32 {
    fn inner(y: i32) -> i32 = y * 2
    return inner(x) + 1
}
```

---

## Closures

Anonymous functions (lambdas) capture variables from the enclosing scope. Default capture is by copy; use
`|*|` to capture by pointer or specify per-variable:

```kairo
var multiplier = 3
var scale = fn (x: i32) -> i32 { return x * multiplier }   // captures multiplier by copy

scale(10)   // 30
```

See [Closures](/docs/language/closures) for capture modes (`|*|`, `|a, *b|`), lifetime rules, and how
closures interact with [Tether](/docs/language/tether).

---

## Operator Functions

Operators are overloaded with the `fn op` syntax:

```kairo
class Vec2 {
    var x: f64
    var y: f64

    fn op +(self, other: Vec2) -> Vec2 {
        return Vec2 { x: self.x + other.x, y: self.y + other.y }
    }
}
```

See [Operators](/docs/language/operators#operator-overloading) for the full list of overloadable operators,
special operator syntax (`l++`/`r++`, `op as`, `op in`, `op delete`), and restrictions.

---

## Forward Declarations

A function can be declared without a body a signature followed by no block:

```kairo
fn parse_expression(tokens: [Token]) -> Expr
fn parse_statement(tokens: [Token]) -> Stmt
```

Within a single module, forward declarations are rarely needed. Kairo hoists all
top-level declarations before type checking, so mutual recursion works without
them:

```kairo
fn is_even(n: u32) -> bool = if n == 0 { true } else { is_odd(n - 1) }
fn is_odd(n: u32) -> bool  = if n == 0 { false } else { is_even(n - 1) }
```

Forward declarations are used when the definition lives elsewhere:

- **FFI imports** the body is provided by a C or C++ library. See
  [C/C++ Interop](/docs/language/c-cpp).
- **Separate translation units** the declaration is visible to callers; the
  definition is linked in from another `.kro` file.
- **Out-of-line class methods** declared in the class body, defined outside it using the `Class::method` qualified-name syntax:

    ```kairo
    class Parser {
        var pos: usize
        fn advance(self)    -> Token
        fn peek(const self) -> Token
    }

    fn Parser::advance(self) -> Token {
        var t = self.tokens[self.pos]
        self.pos += 1
        return t
    }

    fn Parser::peek(const self) -> Token = self.tokens[self.pos]
    ```

    See [Classes](/docs/language/classes#forward-declarations-and-out-of-line-definitions) for the full rules.

### Signature matching

When a definition follows a forward declaration, the two must match exactly:

- Parameter types, return type, and all function modifiers (`const`, `unsafe`,
  `panic`, `eval`, `async`, `inline`, `final`, `volatile`)
- Visibility (`pub`, `priv`, `prot`)
- ABI linkage (`ffi "c"`, `ffi "c++"`, `static`, `virtual`, `override`)

Parameter names may differ; the definition's names are used in the body. Defaults
are not part of the match: each parameter's default may be written on any one
declaration, and it applies to every call (see
[Defaults apply to the whole function](#defaults-apply-to-the-whole-function)).

A mismatch in any other element is a compile error.

---

## Summary

```kairo
// Basic function
fn add(a: i32, b: i32) -> i32 = a + b

// Default parameters + named arguments
fn connect(host: string = "localhost", port: i32 = 8080) { /* ... */ }
connect(port: 9090)

// Parameter modes
fn append(@inout s: string, t: string) { s += t }
append(&name, "!")
fn sink(@move s: string) { /* ... */ }

// Generic with bounds
fn <T impl Printable> show(value: T) { std::println(value as string) }

// Variadic
fn <...T> log(...args: T) { /* ... */ }

// Overloaded
fn process(x: i32) -> i32 { /* ... */ }
fn process(x: string) -> string { /* ... */ }

// Unsafe overload
fn process(x: i32) unsafe -> i32 { /* ... */ }

// Method with modifiers
class Server {
    pub fn start(self) async panic { /* ... */ }
    pub fn status(const self) -> string { /* ... */ }
    pub static fn default_port() -> i32 = 8080
}

// Function pointer
var handler: fn(Request) -> Response = handle_request

// No-return
fn abort() -> ! { std::crash(1) }
```
