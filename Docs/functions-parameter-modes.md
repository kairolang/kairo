# Parameter passing modes

A parameter can be declared in one of three modes. Together they cover every parameter form C++ can declare, so any C++ signature has an exact Kairo spelling.

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

## Modes are not types

`@inout` and `@move` are only allowed on parameters of a `fn` declaration. They cannot appear on locals, fields, return types, generic arguments, tuple elements, or in any other type position. No type `@inout T` exists, and a mode cannot be stored or returned.

```kairo
var y: @inout i32  // compile error: '@inout' is a parameter mode, not a type
var @inout y: i32  // compile error
```

## How `x: T` is passed

For a plain `x: T` parameter of a Kairo function, the compiler picks between passing by value and passing by `const T&`. Scalars, pointers, `fn` values and trivially copyable records go by value. A record that is not trivially copyable (a `string`, a vector, a map, a class with a copy constructor) goes by `const T&` when the function never mutates the parameter (reading it, or iterating it with a loop that has no `*x` binder, is not a mutation): no assignment to it or a field of it, no non-`const` method call on it, no `&x`, no `@inout` or `@move` argument, no `return x`, no use in a closure. A parameter the body does mutate gets its own copy, as before, and a `@move` class always goes by value, since taking ownership is the point. This is why Kairo has no separate mode for `const T&`.

When the compiler passes a parameter by reference this way, it warns that the parameter is never mutated and offers a fix-it that adds `const`:

```kairo
fn length(s: string) -> usize { return s.length() }
//        ^ warning: parameter 's' is never mutated; declare it 'const'
fn length(const s: string) -> usize { return s.length() }   // same code, no warning
```

A `const` parameter is a reference to the caller's object for the whole call. If the function changes that object some other way while the call runs, through `self` or a pointer, the parameter sees the change. A by-value copy would not.

Some functions keep the by-value signature because something else fixes it, and the compiler neither infers the reference nor warns for them: `virtual` and `override` methods (and every method of a class with a polymorphic base), interface members, `ffi "c"` / `ffi "c++"` functions and functions with a calling convention, generic functions and members of generic types, generators and `async` functions, `-> !` and `@cold_path` functions, and `main`. The warning is not reported for the builtin and standard libraries.

For a function declared in an [imported C++ header](/docs/language/c-cpp-calling/), the compiler doesn't choose. The parameter is passed exactly as the header declares it.

A [fixed array](/docs/language/collections/#arrays-t-n) `[T; N]` is the exception: it is not a value type, so a plain `xs: [T; N]` parameter is an error. Take it as `const` or `@inout`, both of which pass by reference, or take a slice:

```kairo
fn f(xs: [i32; 3]) { }          // compile error: parameter 'xs' takes an array by value;
                                //   write 'const', '@inout', or take a slice
fn f(const xs: [i32; 3]) { }    // ok: read-only, by reference
fn f(@inout xs: [i32; 3]) { }   // ok: read-write, by reference
fn f(xs: [i32;]) { }            // ok: a view of any length
```

## Call-site syntax

| Parameter     | Call     |
| ------------- | -------- |
| `x: T`        | `f(a)`   |
| `@inout x: T` | `f(&a)`  |
| `@move x: T`  | `f(a)`   |
| receiver      | `a.f()`  |

In argument position, `&x` says the call may mutate `x`. Which of two things it is depends on the parameter it is passed to:

| Parameter | Argument | Meaning |
| --------- | -------- | ------- |
| `@inout x: T` | `f(&a)` | the `@inout` marker: `a` is passed by reference, no pointer is made |
| `p: *T` | `f(&a)` | address-of: a safe, non-null pointer to `a` |
| `p: *const T` | `f(const &a)` | address-of as a pointer to const (a plain `&a` warns, SC310W) |
| `p: unsafe *T` | `f(unsafe &a)` | an unsafe pointer to `a`, outside the borrow rules |

The marker is required, so every mutation of a caller's variable is visible where the call is made. A `const` `@inout`-free parameter and a `@move` parameter take no marker. `&` is rejected anywhere it means neither:

```kairo
read(&n)           // compile error: parameter 'x' of 'read' is not @inout
bump(n)            // compile error: '@inout' argument requires '&'

const k: i32 = 5
bump(&k)           // compile error: '@inout' requires a non-const lvalue
bump(&10)          // compile error: '@inout' requires an lvalue
```

`@move` takes no marker. The compiler already rejects any later use of the argument, so a marker would add nothing.

The receiver is never marked. `fn f(self)` is a non-`const` method and `fn f(const self)` is a `const` method (`void f() const`). Both are called as `a.f()`:

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

Overload resolution by mode and overloading on mode are covered in [Function Overloading](/docs/language/functions-overloading/#overload-resolution).

## Reference returns from C++

Modes don't exist in return position. A C++ function that returns a reference is written, on the Kairo side, with one of three return spellings:

| C++ return | Kairo return | Value category of a call |
| ---------- | ------------ | ------------------------ |
| `T&`       | `ffi::ref<T>`        | lvalue |
| `const T&` | `ffi::ref<const T>`  | lvalue |
| `T&&`      | `ffi::mref<T>`       | xvalue |

These are not types: nothing in Kairo can hold a reference, so a variable, parameter, field, alias or generic argument can't be one, and `typeof(f())` is `T`. They appear only as the whole return type of a Kairo definition of a function C++ declares (an out-of-line `fn Widget::at`, or a `fn ns::f` for a function in a C++ namespace) and of an override of a C++ virtual method. The return type must match the C++ declaration exactly; the compiler's fix-it gives the right spelling. The body returns the place itself, with no `&` (`return self.items[i]`); returning a temporary or a local is an error, because the caller would hold a reference to nothing.

```kairo
ffi "c++" import "widget.h"   // int& at(size_t); int at(size_t) const;

fn Widget::at(self, i: usize) -> ffi::ref<i32> { return self.items[i] }
fn Widget::at(const self, i: usize) -> i32     { return self.items[i] }

class D derives Base {         // virtual const std::string& name() const;
    pub var label: cxx::std::string
    override fn name(const self) -> ffi::ref<const cxx::std::string> { return self.label }
}
```

[Calling an imported function that returns a reference](/docs/language/c-cpp-calling/#calls-that-return-a-reference) needs no spelling at all: the call is a place.

Because a `T&&` return is an xvalue, `f(g())` where `g` returns `T&&` selects `f`'s `@move` overload, as it does in C++.

The call itself is usable as the referenced value, the same way `v[0]` is: as an operand, and as the target of an assignment or compound assignment.

```kairo
ffi "c++" import <vector>;

var v: cxx::std::vector<i32>
v.push_back(1)

v.at(0) = 3                 // assigns through the returned int&
v.at(0) += 2                // 5
var x = v.at(0) + 1         // 6
```

The same holds for `*p` and for operators that return a reference, such as `cout << x`.

## `@move` is checked

`@move` is checked against the parameter's type, not just recorded:

- **[Move-only class](/docs/language/classes-lifecycle/#the-four-categories):** `@move` is redundant, since passing already consumes the argument (see [Ownership](/docs/language/ownership/#function-parameters)), but it's allowed and checked.
- **Copy-only class:** `@move` is a compile error.
- **Generic `T`:** `@move` is the only way to declare that the function consumes its argument. The body can then consume `x` whatever `T` turns out to be.

In every case the call counts as the consuming use, and any later use of the argument in the caller is a [use-after-move error](/docs/language/ownership/#moved-from-state).

## Imported-only forms

Some C++ forms can be imported and called from Kairo but can't be declared in Kairo source, including as out-of-line definitions:

- `const T&&` parameters. They bind rvalues without consuming them, and C++ uses them almost only as deletion targets.
- Functions returning a reference. Kairo has no `std::move`, because whether a transfer moves is decided by the type, not by the expression, so it never needs to return one.

Kairo also deliberately has no call-site marker for `@move` and no separate mode for `const T&`.


## See also

- [Functions](/docs/language/functions/)
- [Default, Named, and Variadic Parameters](/docs/language/functions-parameters/)
- [Function Overloading](/docs/language/functions-overloading/)
- [Generators](/docs/language/functions-generators/)
- [Function Declarations](/docs/language/functions-declarations/)
- [Ownership](/docs/language/ownership/)
- [Pointers](/docs/language/pointers/)
- [C/C++ Interop](/docs/language/c-cpp/)
