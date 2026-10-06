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

**Checked downcast** returns a nullable pointer `*Derived?`, which is null if the runtime type does not match:

```kairo
fn process(animal: *Animal) {
    var dog = animal as *Dog?   // null if animal is not a Dog
    if dog? {
        dog->fetch()
    }
}
```

Both forms perform a runtime type check using the vtable (the class must have at least one
`virtual` method). Downcasting a non-polymorphic class is a compile error.

### Raw pointer cast

Casting to `unsafe *T` reinterprets the pointer with no type checking equivalent to C++'s
`reinterpret_cast`. The compiler performs no validation.

Casting a safe pointer to a raw pointer `*T as unsafe *U` requires an
[`unsafe` block](/docs/language/unsafe#unsafe-blocks). This is the point where Tether loses provenance:
after the cast the compiler can no longer relate the pointer to the allocation it came from, so the
loss is made visible at the source:

```kairo
var ptr: *i32 = &some_value

unsafe {
    var raw = ptr as unsafe *void    // provenance loss: safe pointer to raw
    var back = raw as unsafe *i32    // reinterpret caller must ensure correctness
}
```

Casting between `unsafe *T` types needs no `unsafe` block there is no provenance left to lose. The
result is the same pointer value with a different type no runtime check, no adjustment.

> [!CAUTION]
> Raw pointer casts bypass Tether's safety guarantees. Casting to `unsafe *void` erases type information
> permanently the compiler cannot verify the correctness of a subsequent cast back. Use only for
> C/C++ interop, custom allocators, and other low-level scenarios.

### Pointer to integer

Casting a pointer to an integer extracts the numeric address. This is safe and requires no `unsafe`
block reading an address cannot violate memory safety on its own, and the resulting integer carries
no provenance:

```kairo
var ptr: *i32 = &some_value
var addr = ptr as usize    // ok: numeric address
```

`usize` is the only permitted target it is the one integer type guaranteed to hold a full address.
Casting a pointer directly to a narrower integer is a compile error, not a warning: silently
discarding the high bits of an address is never what the programmer meant.

```kairo
// var truncated = ptr as u8       // compile error: cannot cast pointer to u8

var low = ptr as usize as u8       // ok: address, then explicit truncation
```

If you genuinely want the low byte of an address (tag bits, alignment checks), spell it as two casts.
The second cast is an ordinary [numeric narrowing](#narrowing-truncation) and reads as deliberate.

### Integer to pointer

Casting an integer to a pointer fabricates a pointer from a numeric address. The result must be an
`unsafe` pointer safe pointers require provenance tracking that an integer cannot provide and the
cast requires an [`unsafe` block](/docs/language/unsafe#unsafe-blocks). The integer carries no
provenance, so the cast invents one that Tether has no way to verify:

```kairo
var addr: usize = 0x7FFE_0000_1000

unsafe {
    var ptr = addr as unsafe *i32   // ok: fabricating provenance
}

// var bad = addr as *i32           // compile error: cannot create safe pointer from integer
```

This is the inverse of `ptr as usize`, and the asymmetry is deliberate: discarding provenance is
harmless, inventing it is not.

### Pointer cast rules

Every pointer cast is classified by what it does to *provenance* the compiler's knowledge of which
allocation a pointer belongs to. Casts that discard provenance are safe; casts that create or
fabricate it are not:

| Cast | Status | Provenance | Why |
|---|---|---|---|
| `ptr as usize` | Allowed, no `unsafe` | Discarded | Reading an address cannot cause UB on its own |
| `ptr as u8` (any narrower int) | **Compile error** | | Narrowing an address is never intended write `ptr as usize as u8` |
| `n as unsafe *T` | Allowed, requires `unsafe` block | Fabricated | Tether cannot verify an address that came from an integer |
| `n as *T` | **Compile error** | | Safe pointers require provenance an integer cannot supply |
| `*T as unsafe *U` | Allowed, requires `unsafe` block | Lost | The provenance-loss point keep it visible |
| `unsafe *T as unsafe *U` | Allowed, no `unsafe` | Already absent | Nothing left to lose |
| `*Derived as *Base` | Implicit | Preserved | Same allocation, adjusted offset |
| `*Base as *Derived` | Allowed, runtime check | Preserved | Vtable check, panics or yields null |

The two error rows are deliberate refusals rather than warnings. `ptr as u8` has an honest spelling
(`ptr as usize as u8`) that says the same thing in two steps, and `n as *T` has no honest spelling at
all a safe pointer's guarantees cannot be reconstructed from a number.

`unsafe` blocks appear on exactly the rows where Tether stops being able to reason about the pointer.
See [Unsafe](/docs/language/unsafe#the-safety-boundary) for the boundary model and
[Tether](/docs/language/tether) for what provenance tracking buys.

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
    fn tag(const self) -> u32 {
        match self {
            case .Success { 0 }
            case .Error   { 1 }
            case .EndOfInput { 2 }
        }
    }
}
```

---

## Nullable to Non-Nullable

Casting a nullable value `T?` to its underlying type `T` is a compile error:

```kairo
var x: i32? = null
// var y = x as i32    // compile error: cannot cast i32? to i32
//                     // use `x ?? <default>` or `unwrap!(x)`
```

There is no collapsing cast in Kairo. A cast that quietly produced a default-constructed value on
null would fabricate a value the program never computed which is precisely what the nullable system
exists to prevent. The null case has to be answered, not erased, and the two honest answers already
have syntax:

| Intent | Write | On null |
|---|---|---|
| Supply a fallback | `x ?? 0` | Yields the fallback |
| Assert non-null | `unwrap!(x)` | Panics (requires `panic` / `try`) |

Both read at the call site as a decision about null. `x as i32` reads as a type conversion and hides
one.

```kairo
var count: i32? = lookup_count()

var n = count ?? 0            // explicit: absent means zero
var m = unwrap!(count)        // explicit: absent is a bug, panic
```

See [Variables](/docs/language/variables#nullable-types) for the rest of the nullable operations
(`?.`, `??`, `unwrap!()`, null checking).

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

Marking an `op as` with `@implicit` lets it apply without `as` where its exact result type is wanted. See
[Implicit `op as`](/docs/language/operators#implicit-op-as).

See [Operators](/docs/language/operators#special-operators) for the full operator overloading
reference.

## Conversion Through a Constructor

`x as T` is also a conversion when `T` declares a constructor with one parameter that accepts `x`'s type. The
cast calls that constructor:

```kairo
class Celsius {
    var value: f64

    fn Celsius(self, v: f64) { self.value = v }
}

var c = 21.5 as Celsius     // calls Celsius(21.5)
```

The standing example is slice to vector. A vector has a constructor that takes a slice, so the cast copies the
elements into a new vector:

```kairo
var s: [i32;] = [1, 2, 3]
var v = s as [i32]          // allocates and copies
```

If the source type declares `op as` for `T` and `T` also has a matching constructor, `op as` wins.

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
| Base-to-derived ptr (checked) | `ptr as *Derived?` | Runtime check | Returns null |
| Safe to raw pointer | `ptr as unsafe *T` | Requires `unsafe` block | Provenance loss |
| Raw to raw pointer | `raw as unsafe *T` | No check | Reinterpret |
| Pointer to `usize` | `ptr as usize` | Safe | Address value |
| Pointer to narrower int | `ptr as u8` | Compile error | Use `ptr as usize as u8` |
| Integer to pointer | `n as unsafe *T` | Requires `unsafe` block | Fabricated provenance |
| Plain enum to int | `e as u8` | Safe | Discriminant value |
| Int to plain enum | `n as Direction` | UB if no match | No runtime check |
| ADT enum to int | N/A | Compile error | Use `extend` method |
| User-defined | `x as TargetType` | Depends on `op as` | Calls user code |
| Through a constructor | `x as T` | Depends on the constructor | Calls `T`'s one-parameter constructor |
| Slice to vector | `s as [T]` | Safe | Allocates and copies |
| `T` to `T?` | Implicit | Safe | N/A |
| `T?` to `T` | Not a cast | Compile error | Use `??` or `unwrap!()` |

---

## Casts Not in Kairo

| C++ Cast | Kairo Equivalent |
|---|---|
| `static_cast<T>(x)` | `x as T` |
| `dynamic_cast<T*>(p)` | `p as *T?` (checked) or `p as *T` (asserting) |
| `reinterpret_cast<T*>(p)` | `p as unsafe *T` |
| `const_cast<T*>(p)` | Not supported `const` cannot be stripped at runtime |
