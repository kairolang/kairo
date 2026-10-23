# Function Overloading

Functions can be overloaded by parameter types, matching C++ overload resolution rules:

```kairo
fn add(a: i32, b: i32) -> i32 = a + b
fn add(a: f64, b: f64) -> f64 = a + b
fn add(a: string, b: string) -> string = a + b
```

Parameter modes also participate in overloading. See [Overloading on mode](#overloading-on-mode).

A candidate either matches an argument exactly or through a conversion, and there is no ordering among
conversions: if two candidates both need one, the call is ambiguous (`call to 'f' is ambiguous: more than
one candidate matches at the same rank`). Before a tie at the same rank is declared ambiguous, three
tie-breaks run, in C++'s order:

1. **Reference binding.** An rvalue argument prefers a `T&&` parameter to `const T&`; a non-const lvalue
   prefers `T&` to `const T&`; a non-const receiver prefers the non-const method.
2. **Non-generic over generic.** A non-generic candidate beats a generic one.
3. **Most specialized generic.** Among generic candidates still tied, the most specialized wins:
   `fn <T> f(a: Box<T>, b: Box<T>)` beats `fn <A, B> f(a: Box<A>, b: Box<B>)` for `f(x, y)` with two
   `Box<i32>`.

These tie-breaks never order conversions. For a list literal argument, a `[T; N]` parameter with the same
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

See [Primitives](/docs/language/conversion-lattice/#list-literal-arguments)
for the ranking rules.

## Unsafe overloads

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
> [Unsafe](/docs/language/unsafe/) for the full unsafe model.

## Const overloading restriction

`const` and non-`const` methods with the same name and parameter types cannot coexist, use distinct names like `get()` and `get_mut()`. This restriction applies to named methods declared in Kairo source. An imported C++ class may have such a pair, and both members can be defined out of line (see [Overloading on mode](#overloading-on-mode)). **Place operators are exempt**, because they cannot be renamed: a place-returning operator (`[]`, `->`) may declare both a `self` overload (returning `*T`) and a `const self` overload (returning `*const T`), dispatched by receiver const-ness. See [Operators](/docs/language/operator-overloading/#const-overloading-operators).

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

## Overload resolution

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

## Overloading on mode

[Modes](/docs/language/functions-parameter-modes/) are part of a function's signature. `x: T`, `@inout x: T`, and `@move x: T` are three distinct
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

Overriding an imported [virtual](/docs/language/classes-inheritance/#virtual-dispatch) uses the same spelling:

```kairo
// cxx.hh:  class Base { virtual void foo(int& x); };

class Derived derives Base {
    override fn foo(@inout x: i32) { x = 42 }
}

var d = Derived{}
var n: i32 = 0
d.foo(&n)        // n is 42
```


## See also

- [Functions](/docs/language/functions/)
- [Default, Named, and Variadic Parameters](/docs/language/functions-parameters/)
- [Parameter Passing Modes](/docs/language/functions-parameter-modes/)
- [Generators](/docs/language/functions-generators/)
- [Function Declarations](/docs/language/functions-declarations/)
- [Operator Overloading](/docs/language/operator-overloading/)
- [Where Clauses](/docs/language/where/)
- [Unsafe](/docs/language/unsafe/)
- [Generics](/docs/language/generics/)
