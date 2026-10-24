# Default, Named, and Variadic Parameters

Parameters can have default values, arguments can be passed by name at the call site, and the `...` prefix on a parameter name accepts any number of arguments of the same type.

## Default parameters

Parameters can have default values. When a caller omits a defaulted argument, the default is used:

```kairo
fn greet(name: string = "world") {
    std::println(f"Hello, {name}!")
}

greet()          // "Hello, world!"
greet("Alice")   // "Hello, Alice!"
```

A default is evaluated once per call that omits that argument. Any parameter may have a default, not only trailing ones; a defaulted parameter that comes before a required one is skipped by naming the later argument (see [Named arguments](#named-arguments)).

### A default stands alone

A default argument may not mention another parameter or `self`. It is evaluated with no access to the call's other arguments:

```kairo
fn a(x: i32, y: i32 = x) { }          // compile error (SC106E)
fn m(self, y: i32 = self.v) { }       // compile error (SC106E)
```

When a default depends on another argument, use an [overload](/docs/language/functions-overloading/) instead:

```kairo
fn a(x: i32, y: i32) { }
fn a(x: i32) { a(x, x) }
```

A default also may not be a [slice literal](/docs/language/collections/#how-long-a-slice-literals-storage-lives) (`[T;]`), since the slice would view a temporary. Use an owning `[T]`:

```kairo
fn f(xs: [i32;] = [1, 2]) { }         // compile error
fn f(xs: [i32]  = [1, 2]) { }         // ok
```

### Defaults apply to the whole function

Defaults belong to the function, not to a point in the file. A default added by a later declaration applies to every call, including calls written above that declaration. This differs from C++, where a default is only visible after the declaration that introduces it.

Each parameter may be given a default on any one declaration of the function. Defaults from different declarations accumulate:

```kairo
fn f0(i: i32, j: i32, k: i32 = 3) -> i32
fn f0(i: i32, j: i32 = 2, k: i32) -> i32
fn f0(i: i32 = 1, j: i32, k: i32) -> i32

f0()        // same as f0(1, 2, 3)
f0(7)       // same as f0(7, 2, 3)
```

Out-of-line class methods have one more restriction: their defaults go on the in-class declaration. See [Classes](/docs/language/classes-out-of-line/#rules).

### Evaluation order

Explicit arguments are evaluated left to right in the order they are written at the call site, whichever parameter each one names. Defaults for omitted arguments are evaluated after every explicit argument, in parameter order:

```kairo
fn g(a: i32 = stamp(1), b: i32) -> i32

g(b: stamp(4))               // stamp(4) runs first, then the default stamp(1)

fn h(a: i32, b: i32) -> i32
h(b: stamp(1), a: stamp(2))  // stamp(1) runs first: written order, not parameter order
```

### Defaults on imported C++ functions

An imported C++ function keeps its C++ defaults, and C++ applies them. C++ can only leave out trailing arguments, so naming a later parameter while an earlier defaulted one is omitted is an error ([SC107E](/docs/language/diagnostics/#sc107e-a-named-argument-skips-a-defaulted-parameter-of-an-imported-c-function)):

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

## Named arguments

Arguments can be passed by name at the call site. Positional arguments must come before named arguments, matching C++ conventions:

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

---

## Variadic Functions

The `...` prefix on a parameter name accepts any number of arguments of the same type. Inside the body, `...xs: T` is a [slice](/docs/language/collections/#slices-t) `[T;]` over the run of arguments. The slice is passed by value and is valid for the duration of the call; it views the arguments, so do not store it or return it.

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

Combine `...` with [generic](/docs/language/generics/) type packs to accept arguments of different types:

```kairo
fn <...T> print_all(...args: T) {
    for arg in args {
        std::println(arg as string)
    }
}

print_all(42, "hello", true)   // prints each on a new line
```

The parameter is a tuple of heterogeneous types. Each element in the pack must satisfy the constraints used in the function body in the example above, every `T` must be convertible to `string` via `as`.

### Pack expansion and forwarding

A pack expands with a **postfix** `...` in expression position. Declaration is prefix (`...args`), use is postfix (`args...`). The most common case is forwarding a pack to another call:

```kairo
fn <...T> log_all(...args: T) {
    print_all(args...)         // forwards every element as a separate argument
}
```

The same postfix form appears in type position for pack-typed signatures. The split mirrors the [token-macro splat](/docs/language/macros/#variadic-macros-and-pack-expansion): `...` before a name declares a pack, `...` after an expression expands one.


## See also

- [Functions](/docs/language/functions/)
- [Parameter Passing Modes](/docs/language/functions-parameter-modes/)
- [Function Overloading](/docs/language/functions-overloading/)
- [Generators](/docs/language/functions-generators/)
- [Function Declarations](/docs/language/functions-declarations/)
- [Generics](/docs/language/generics/)
- [Macros](/docs/language/macros/)
- [C/C++ Interop](/docs/language/c-cpp/)
