# Nullables

## Nullable Types

`T?` is sugar for `Nullable<T>` a compiler-intrinsic tagged union that holds either a value of type `T` or null. It applies to any type, not just pointers.

```kairo
var name: string? = get_name()   // may be null
var count: i32? = null           // explicitly null
```

### Shorthand declaration

The `?` suffix on the variable name infers the nullable type from the initializer:

```kairo
var name? = get_name()           // inferred as string?
// var x? = null                 // compile error: no underlying type to infer
```

### Null checking

The `?` suffix on a variable name in a condition checks for non-null:

```kairo
var result? = find_user("alice")

if result? {
    // result is non-null here
    std::println(result.name)
}
```

Accessing members on an unchecked nullable is a compile error:

```kairo
var user? = find_user("alice")
user.name   // compile error: user has not been null-checked
```

### Safe access (`?.`)

The [`?.` operator](/docs/language/operators/#null-safe-access) calls a method or accesses a member only if the value is non-null. If null, it default-constructs the type and calls the method on that instead:

```kairo
var config? = load_config()
config?.timeout   // if null, uses Config().timeout
```

If the type is not trivially default-constructible (deleted default constructor, contains atomic types), `?.` is a compile error.

### Null coalescing (`??`)

`??` provides a fallback value when the left side is null. Both sides must be the same underlying type:

```kairo
var value = get_f32() ?? 0.212   // value is f32, not f32?
var name = get_name() ?? "anonymous"
```

### Force unwrap

`unwrap!()` extracts the value or panics if null:

```kairo
var x = unwrap!(maybe_value)   // panics if null
```

`unwrap!()` desugars to a null check followed by a `panic` on the null path. The caller must be inside a `try` block or in a function with the `panic` specifier. See [Panic](/docs/language/panic/) for the panic model.

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

To represent a pointer that might not exist, use `*T?`. This wraps the pointer in the standard `Nullable<T>` system with full support for `?`, `?.`, `??`, and `unwrap!()`:

```kairo
var ptr: *i32? = find_pointer()

if ptr? {
    std::println(*ptr)          // compiler knows ptr is non-null here
}

var val = ptr ?? &fallback      // use fallback if null
var forced = unwrap!(ptr)       // panics if null
```

For raw nullable pointers with no compiler tracking, use `unsafe *T` with manual null comparison:

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
