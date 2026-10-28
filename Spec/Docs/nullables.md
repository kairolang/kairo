# Nullables

## Nullable Types

`T?` is sugar for `Nullable<T>`, a built-in type that holds either a value of type `T` or `null`. It applies to any type, not just pointers.

```kairo
var name: string? = get_name()   // may be null
var count: i32? = null           // explicitly null
```

`null` is a real value: the one constant of the empty type `null_t`. `Nullable<T>` has exactly two constructors, one from `null_t` and one from `T`, and every implicit conversion to `T?` is one of them: `var c: i32? = 5` constructs from the `i32`, `= null` from the `null_t`. A bare `null` is only ever a nullable's null: it never converts to a pointer, so `var p: unsafe *i32 = null` is a compile error. The null raw pointer is spelled `&null` (see [Pointers and nullability](#pointers-and-nullability)).

The storage depends on `T`. A nullable [safe pointer](#pointers-and-nullability) is the pointer itself, the same size, with `0x0` meaning null; `bool?` is one byte. Every other `T?` stores the value and a presence flag. `Nullable` is not writable as a type name in Kairo; the `?` suffix is the only spelling (see [Type System](/docs/language/type-system/#nullable-types-in-the-type-system)). From C++ it is `::builtin::Nullable<T>`; see [Using Kairo in C++](/docs/language/c-cpp-exposing/#nullables-across-the-boundary).

### Shorthand declaration

The `?` suffix on the variable name infers the nullable type from the initializer:

```kairo
var n? = 10                      // i32?
var name? = get_name()           // get_name() -> string?: name is string?, not (string?)?
var k = 3
var *p? = &k                     // (*i32)?: combines with the pointer shorthand (see Variables)
// var x? = null                 // compile error: no underlying type to infer
```

A declaration that infers a nullable type without the `?` gets a warning, with a fix-it that adds it: `var n = find()` with `find() -> i32?` reads like a plain value, so the compiler asks for `var n? = find()`. See [Declaration Shorthands](/docs/language/variables/#declaration-shorthands).

### Null checking

The `?` suffix on a variable name in a condition checks for non-null:

```kairo
var result? = find_user("alice")

if result? {
    // result is non-null here
    std::println(result.name)
}
```

`x?`, `x != null` and `null != x` are the same test, and `!x?`, `x == null` and `null == x` are its negation. Every spelling narrows the same way.

Accessing members on an unchecked nullable is a compile error:

```kairo
var user? = find_user("alice")
user.name   // compile error: user has not been null-checked
```

### Narrowing

The compiler tracks, at every point in a function, whether each nullable variable or field path (`user`, `req.body`, `a.b.c`) is **known non-null**, **known null**, or **maybe null**. A known non-null nullable is used as its `T` directly, with no syntax at the use. Reading the value of a maybe-null or known-null one (member access, a dereference, an operator, passing it where a `T` is expected) is a compile error, in every build mode. No mode inserts a hidden check; the null path is always written in the source. Uses that do not need the value are fine in any state: assigning it, passing it to a `T?` parameter, and `?`, `== null`, `??`, `?.`, `===`, `unwrap!()`.

Where the compiler cannot tell, the answer is maybe null. Where paths merge, the result is the weaker state: non-null on one path and null on the other is maybe null.

#### Assignments set the state

An assignment gives the variable the state of the value assigned:

```kairo
var x? = 10           // known non-null: a plain i32 was assigned
std::println(x + 1)   // ok, no check needed

x = null              // known null
// x + 1              // compile error: x is always null here

x = lookup()          // lookup() -> i32?: maybe null
// x + 1              // compile error: x may be null here
if x? { std::println(x + 1) }   // ok

var y? = x            // y has x's state

var k = 7
var p: *i32? = &k     // known non-null: an address is never null
```

A parameter of type `T?` starts maybe null.

#### Conditions refine the state

- `if x? { ... } else { ... }`: `x` is non-null in the first block and null in the `else`.
- `!` swaps the two: in `if !x? { ... } else { ... }`, the `else` block sees `x` non-null.
- `a && b`: `b` is checked as if `a` were true, so `x? && x > 0` is fine. The `if` block of `if a && b` sees what both establish.
- `a || b`: `b` is checked as if `a` were false, so `!x? || x > 0` is fine. The `else` of `if a || b` sees what both refute.
- Value-form `if c => t else e` and `??` follow the same rules.
- **Early exit.** When one branch cannot fall through (`return`, `break`, `continue`, a `panic`, a call to a `-> !` function), the code after the `if` continues with the other branch's state:

```kairo
fn area(s: Shape?) -> f64 {
    if !s? { return 0.0 }
    return s.width * s.height   // s is non-null from here on
}
```

**Mind the precedence.** `&&` binds tighter than `||`, so this is an error:

```kairo
var a? = lookup()
if a? && a > 0 || a < 0 { ... }
// compile error: a may be null here
//   parsed as (a? && a > 0) || a < 0, and a < 0 runs when a? is false
```

The compiler offers a fix-it that adds the parentheses putting every use on the checked path, with a note that `unwrap!(a)` is the alternative:

```kairo
if a? && (a > 0 || a < 0) { ... }   // ok
```

#### Loops

A loop condition refines the body the same way an `if` does. Inside the body, a variable stays narrowed unless the body itself can make it maybe null again: `while x? { ... }` re-tests every iteration, so `x` is non-null at the top of the body whatever the body does to it. After a `while`, the state is the condition's false case, merged with the state at every `break`. A `for` loop has no condition to refine with; its body starts from the state before the loop, minus anything the body can make maybe null.

```kairo
var node: *Node? = head
while node? {
    visit(node)          // node is non-null: the condition proves it
    node = node->next    // next: *Node?, so node is maybe null again...
}                        // ...until the condition re-tests it
```

`next` is a nullable pointer, not a `Node?`: a `T?` holds its `T` in place, so a `Node` holding a `Node?` would contain itself, which is a compile error.

#### What makes it maybe null again

Besides an assignment, anything that can write the variable where the compiler cannot see the value:

- passing it to an [`@inout`](/docs/language/functions-parameter-modes/) parameter;
- writing through a non-`const` pointer to it, or to anything that contains it, or passing such a pointer to a function (see [Closures and stored pointers](#closures-and-stored-pointers));
- for a field path such as `foo.data`: any of the above on `foo`, and any method call that takes `foo` as mutable `self`. The call can change `foo`'s fields, not make `foo` itself null, so a nullable `foo` that was checked stays non-null.

A `const` pointer, a `const self` call, or passing it by value leaves the state alone. Taking a pointer into a local (`var *p = &x`) changes nothing by itself; writing through it, or letting it escape, does.

```kairo
if cfg.path? {
    cfg.reload()          // fn reload(self): may write cfg.path
    // open(cfg.path)     // compile error: cfg.path may be null here
}
```

A nullable reached through `->` or a subscript (`p->cache`, `items[i].cache`) is not tracked: a check on it does not narrow it, and the compiler says so. Copy it to a local and check that:

```kairo
var c? = p->cache
if c? { use(c.value) }
```

#### Closures and stored pointers

A [closure](/docs/language/closures/) that captures by copy needs no special care: its copy starts in the state the variable had when the closure was made, unless the closure assigns its copy, which keeps its value from one call to the next. Inside a closure that captures `x` by pointer, `*x` is not tracked: copy it to a local and check that. A closure that captures by non-`const` pointer, or a pointer value such as `var *p = &x`, can write `x` behind the compiler's back, so the compiler follows it:

- calling a closure that captured `x` by pointer, or writing through `p`, makes `x` maybe null;
- once that closure or pointer escapes (passed to a function that can keep it, stored in a field, a global or a container, or returned), **every** call from then until `x` goes out of scope makes `x` maybe null, since any call might run it. A check still narrows `x` until the next call.

```kairo
var x: Node? = make()
var clear = fn ()|*x| { *x = null }
if x? {
    clear()
    // x.value            // compile error: clear() may have set x to null
}
```

A `const *` capture or pointer cannot write, and changes nothing.

#### Globals and statics

A nullable `static` or file-scope variable is narrowed by a check only until the next call: any call may write it.

```kairo
static current: Session? = null

fn report() {
    if current? {
        var id = current.id   // ok: no call since the check
        log(id)
        // current.id         // compile error: log() may have written current
    }
}
```

### Matching on a nullable

A [`match`](/docs/language/pattern-matching/#matching-a-nullable) on a `T?` must answer `case null` first; every later arm, `default` included, sees the value as non-null, and `case var v` binds the unwrapped `T`.

### Safe access (`?.`)

The [`?.` operator](/docs/language/operators/#null-safe-access) calls a method or accesses a member only if the value is non-null. If it is null, nothing to the right of `?.` is evaluated and the whole expression is null, so its type is the member's type made nullable:

```kairo
var config? = load_config()
var t? = config?.timeout         // i32?: null when config is null
var n = config?.timeout ?? 30    // i32: 30 when config is null
var ok? = config?.save(path())   // bool?: save() and path() run only when config is non-null
```

`x?.m` means `if x? => x.m else null`, and `x?.f(args)` the same, with the call and its arguments evaluated only on the non-null path. Nothing is ever constructed on the null path. When the member's type is already nullable it is not wrapped twice: `x?.m` with `m: T?` is `T?`. `?->` is the same over a [nullable pointer](#pointers-and-nullability), and a chain `a?.b?.c` applies each step to the previous step's result.

The steps after a `?.` act on the value, up to the next `?.`: `user?.address.city` is `string?` when `address` is not nullable. A call's result is the nullable, so `user?.find_order()?.total` needs the second `?.`. A method that returns nothing makes a statement: `conn?.close()` calls `close()` only when `conn` is non-null. The result is a value, not a place: `config?.timeout = 5` is a compile error. `?.` and `?->` on a value that cannot be null are a compile error too, with a fix-it that writes `.` (or `->`).

### Null coalescing (`??`)

`??` provides a fallback value when the left side is null. Both sides must be the same underlying type. The result is `T`, or `T?` when the right side is itself nullable, and `??` chains to the right:

```kairo
var value = get_f32() ?? 0.212             // value is f32, not f32?
var name = get_name() ?? "anonymous"       // string
var host? = env_host() ?? config_host()    // string?: config_host() -> string?
var port = env_port() ?? file_port() ?? 80 // i32
```

### Null-aware equality (`===`)

`a === b` is true when both are non-null and their values are equal: `(a? && b?) && a == b`. A non-nullable operand needs no test, so `a === 5` is `a? && a == 5`. The `==` is the values' own, a user `op ==` included. On nullable pointers it compares what they point to, one level down. At least one operand must be nullable, and `x === null` is an error (it is never true; write `!x?`). Like the conjunction it reads as, a true `a === b` narrows both: in `if a === b { ... }`, `a` and `b` are non-null. See [Operators](/docs/language/operators/#comparison).

### Force unwrap

`unwrap!()` extracts the value, or terminates the program if it is null:

```kairo
var x = unwrap!(maybe_value)   // aborts the program if null
```

`unwrap!(x)` reads as `if x? => x else <abort>`. On null it writes a message naming the expression and its source location to stderr (`unwrap!(maybe_value) on null at /home/me/app/main.k:12:13`: the source file's full path, line and column), then aborts the process (like C++ `std::abort`). Since the program cannot continue past a null, `x` itself is known non-null after `unwrap!(x)`, and on a variable or field `unwrap!(x)` is that variable: `unwrap!(cfg).port = 80` writes `cfg`'s value. `unwrap!` on a value that cannot be null is a compile error. It is not a [panic](/docs/language/panic/): nothing can catch it, so it needs no `try` and no `panic` specifier, and it is not part of a function's panic set. Use it where a null value means the program itself is wrong; where null is an outcome to handle, use `if x?`, `??` or `?.`.

### Const interaction

`const` on a nullable binding works the same as on any other type the binding cannot be reassigned after initialization:

```kairo
const x: i32? = 42
x = null   // compile error: x is const
x = 100    // compile error: x is const

var y: i32? = null
y = 42     // ok: var is mutable
y = null   // ok: can go back to null
```

### Pointers and nullability

`*T` is non-null by construction, it cannot hold `&null`. No null checks are needed on dereference because the pointer is always valid:

```kairo
var x = 42
var ptr: *i32 = &x
*ptr = 10              // guaranteed valid, no check

var bad: *i32 = &null  // compile error: *T is non-null
```

To represent a pointer that might not exist, use `*T?`, a nullable pointer. It reads as `(*T)?`, not as a pointer to a nullable, which is `*(T?)` (see [Pointers](/docs/language/pointers/#pointers-and-nullable-types)). It is one pointer wide, with null stored as `0x0`, and supports `?`, `?.`, `?->`, `??`, `===` and `unwrap!()`:

```kairo
var ptr: *i32? = find_pointer()

if ptr? {
    std::println(*ptr)          // compiler knows ptr is non-null here
}

var *val = ptr ?? &fallback     // *i32: use fallback if null
var *forced = unwrap!(ptr)      // aborts if null
```

For a raw pointer with no compiler tracking, use `unsafe *T`. It is the only pointer that can hold the null address, written `&null` (a bare `null` is a nullable's null, never a pointer), and it is checked by comparing against `&null` by hand:

```kairo
var raw: unsafe *i32 = &null
if raw != &null {
    std::println(*raw)
}
```

See [Pointers](/docs/language/pointers/) for the full pointer model and how [Tether](/docs/language/tether/) tracks pointer provenance.

## See also

- [Variables & Bindings](/docs/language/variables/)
- [Pointers](/docs/language/pointers/)
- [Panic](/docs/language/panic/)
- [Tether](/docs/language/tether/)
- [Pattern Matching](/docs/language/pattern-matching/)
- [ADT Enums](/docs/language/enums-adt/)
- [Nullable to Non-Nullable](/docs/language/casting/#nullable-to-non-nullable)
- [Nullable Types in the Type System](/docs/language/type-system/#nullable-types-in-the-type-system)
