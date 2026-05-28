# Casting

All explicit type conversions in Kairo use the `as` keyword. There are no separate cast operators like
C++'s `static_cast`, `dynamic_cast`, `reinterpret_cast`, and `const_cast` `as` handles all conversion
categories, with safety determined by the source and target types.

For implicit conversions (numeric widening, `T` to `T?`, derived-to-base pointers), see
[Type System](/docs/language/type-system#implicit-conversions).

---

## Numeric Casts

### Widening

Integer and float widening is implicit no `as` required:

```kairo
var a: i32 = 42
var b: i64 = a       // implicit
```

`as` is permitted but redundant for widening conversions.

### Narrowing (truncation)

Narrowing conversions require an explicit `as`. The cast truncates by keeping the low bits of the
source value:

```kairo
var x: i64 = 1000
var y: i8 = x as i8    // truncates to low 8 bits: -24

var big: u32 = 0xDEADBEEF
var small: u8 = big as u8   // 0xEF
```

Truncation never panics. The `as` keyword is the programmer explicitly accepting potential data loss.

### Float to integer

Float-to-integer casts truncate toward zero, matching C++ behavior. Out-of-range values saturate
instead of producing undefined behavior:

```kairo
var f: f64 = 3.9
var i: i32 = f as i32      // 3 (truncates toward zero)

var neg: f64 = -2.7
var n: i32 = neg as i32    // -2

var huge: f64 = 1.0e18
var s: i32 = huge as i32   // i32 max (2147483647) saturates
```

### Integer to float

Integer-to-float casts may lose precision for large values but never fail:

```kairo
var x: i64 = 9007199254740993   // 2^53 + 1
var f: f64 = x as f64           // rounded f64 cannot represent this exactly
```

### Signed/unsigned conversion

Casting between signed and unsigned integers of the same width reinterprets the bit pattern:

```kairo
var s: i8 = -1
var u: u8 = s as u8    // 255 (same bits, different interpretation)
```

---

## Pointer Casts

### Upcasting (derived to base)

Derived-to-base pointer conversion is implicit no `as` required:

```kairo
class Animal { ... }
class Dog derives Animal { ... }

var dog = Dog("Rex", "Labrador")
var animal: *Animal = &dog   // implicit upcast
```

### Downcasting (base to derived)

Base-to-derived casts come in two forms:

**Asserting downcast** panics if the runtime type does not match. The function must have the `panic`
specifier or the cast must be inside a `try` block:

```kairo
fn process(animal: *Animal) panic {
    var dog = animal as *Dog   // panics if animal is not a Dog
    dog->fetch()
}
```

**Checked downcast** returns a nullable pointer. `&null` if the runtime type does not match:

```kairo
fn process(animal: *Animal) {
    var dog = animal as *Dog?   // null if animal is not a Dog
    if dog != &null {
        dog->fetch()
    }
}
```

Both forms perform a runtime type check using the vtable (the class must have at least one
`virtual` method). Downcasting a non-polymorphic class is a compile error.

### Raw pointer cast

Casting to `unsafe *T` reinterprets the pointer with no type checking equivalent to C++'s
`reinterpret_cast`. The compiler performs no validation:

```kairo
var ptr: *i32 = &some_value
var raw = ptr as unsafe *void    // type erasure
var back = raw as unsafe *i32    // reinterpret caller must ensure correctness
```

Casting between `unsafe *T` types is always permitted. The result is the same pointer value with a
different type no runtime check, no adjustment.

> [!CAUTION]
> Raw pointer casts bypass AMT's safety guarantees. Casting to `unsafe *void` erases type information
> permanently the compiler cannot verify the correctness of a subsequent cast back. Use only for
> C/C++ interop, custom allocators, and other low-level scenarios.

### Pointer to integer

Casting a pointer to an integer extracts the numeric address. No `unsafe` block is required:

```kairo
var ptr: *i32 = &some_value
var addr = ptr as usize    // ok: numeric address

var truncated = ptr as u8  // warning: truncation of pointer value
```

`usize` is the natural target type since it matches pointer width. Casting to a narrower integer
produces a truncation warning.

### Integer to pointer

Casting an integer to a pointer fabricates a pointer from a numeric address. The result must be an
`unsafe` pointer safe pointers require provenance tracking that an integer cannot provide:

```kairo
var addr: usize = 0x7FFE_0000_1000
var ptr = addr as unsafe *i32   // ok: fabricating an unsafe pointer

// var bad = addr as *i32       // compile error: cannot create safe pointer from integer
```

---

## Enum Casts

### Plain enums

Plain enums can be cast to their underlying integer type and back:

```kairo
enum Direction derives u8 {
    North = 0,
    East = 1,
    South = 2,
    West = 3,
}

var raw = Direction::North as u8   // 0
var dir = 2u8 as Direction         // Direction::South
```

Casting an integer to an enum that has no matching discriminant is undefined behavior. The compiler
does not insert a runtime check.

The cast target must match the underlying type. `Direction::North as i32` requires the enum to be
backed by `i32`, or an intermediate cast: `Direction::North as u8 as i32`.

### ADT enums

ADT enums cannot be cast to integers. The discriminant tag is an internal implementation detail. If
you need the tag value, expose it through an `extend` method:

```kairo
enum <T> ParseResult {
    Success { value: T, consumed: i32 },
    Error   { message: string },
    EndOfInput,
}

// ParseResult::Success { ... } as u32   // compile error: ADT enums cannot be cast to integers

extend <T> ParseResult<T> {
    fn tag(self) const -> u32 {
        match self {
            case .Success { 0 }
            case .Error   { 1 }
            case .EndOfInput { 2 }
        }
    }
}
```

---

## Nullable Collapsing Cast

Casting a nullable value `T?` to its underlying type `T` produces a non-null value. If the source is
null, a default-constructed value of `T` is used instead:

```kairo
var x: i32? = null
var y = x as i32     // 0 (default-constructed i32)

var s: string? = "hello"
var t = s as string  // "hello"
```

The target type `T` must be trivially default-constructible. If the type has a deleted default
constructor, the collapsing cast is a compile error:

```kairo
class NoDefault {
    fn NoDefault(self) = delete
}

var obj: NoDefault? = null
// var x = obj as NoDefault   // compile error: NoDefault has no default constructor
```

This differs from `unwrap!()`, which panics on null instead of default-constructing:

| | `x as T` | `unwrap!(x)` |
|---|---|---|
| Source is non-null | Returns the value | Returns the value |
| Source is null | Returns `T()` (default) | Panics |
| Requires default constructor | Yes | No |
| Requires `panic` / `try` | No | Yes |

See [Variables](/docs/language/variables#nullable-types) for other nullable operations (`?.`, `??`,
null checking).

---

## User-Defined Conversions (`op as`)

Types can define custom conversions by overloading the `op as` operator:

```kairo
class Temperature {
    var celsius: f64

    fn Temperature(self, c: f64) { self.celsius = c }

    fn op as(self) -> f64 {
        return self.celsius
    }

    fn op as(self) -> string {
        return f"{self.celsius}C"
    }
}

var temp = Temperature(100.0)
var f = temp as f64      // 100.0
var s = temp as string   // "100.0C"
```

`op as` can be overloaded for multiple target types. The compiler selects the overload based on
the target type in the `as` expression. `op as` must take only `self` as a parameter and return
the target type.

See [Operators](/docs/language/operators#special-operators) for the full operator overloading
reference.

---

## Cast Summary

| Cast | Syntax | Safety | Behavior on failure |
|---|---|---|---|
| Numeric widening | Implicit | Safe | N/A |
| Numeric narrowing | `x as i8` | Truncates | Low bits kept |
| Float to int | `x as i32` | Truncates/saturates | Saturates on overflow |
| Int to float | `x as f64` | May lose precision | Rounded |
| Derived-to-base ptr | Implicit | Safe | N/A |
| Base-to-derived ptr (asserting) | `ptr as *Derived` | Runtime check | Panics |
| Base-to-derived ptr (checked) | `ptr as *Derived?` | Runtime check | Returns `&null` |
| Raw pointer cast | `ptr as unsafe *T` | No check | Reinterpret |
| Pointer to integer | `ptr as usize` | Safe | Address value |
| Integer to pointer | `n as unsafe *T` | Unsafe | Fabricated pointer |
| Plain enum to int | `e as u8` | Safe | Discriminant value |
| Int to plain enum | `n as Direction` | UB if no match | No runtime check |
| ADT enum to int | N/A | Compile error | Use `extend` method |
| Nullable collapse | `x as T` | Safe | Default-constructs on null |
| User-defined | `x as TargetType` | Depends on `op as` | Calls user code |
| `T` to `T?` | Implicit | Safe | N/A |
| `T?` to `T` | `x as T` | Collapsing cast | Default on null |

---

## Casts Not in Kairo

| C++ Cast | Kairo Equivalent |
|---|---|
| `static_cast<T>(x)` | `x as T` |
| `dynamic_cast<T*>(p)` | `p as *T?` (checked) or `p as *T` (asserting) |
| `reinterpret_cast<T*>(p)` | `p as unsafe *T` |
| `const_cast<T*>(p)` | Not supported `const` cannot be stripped at runtime |
