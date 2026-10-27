# Plain Enums

A plain enum is a set of named integer constants:

```kairo
enum Direction {
    North,
    East,
    South,
    West,
}

fn main() -> i32 {
    var dir = Direction::North
    return 0
}
```

Variants are comma-separated and scoped to the enum name. The trailing comma is optional.

Plain enums (no payloads) cannot be [generic](/docs/language/generics/) there is nothing for a type parameter to parameterize.

## Discriminant values

Variants are assigned sequential integers starting from 0 by default. Explicit values can be assigned with `=`:

```kairo
enum HttpStatus {
    Ok = 200,
    NotFound = 404,
    InternalError = 500,
    ServiceUnavailable,   // 501
}
```

A discriminant is an integer constant expression evaluated by the compiler: literals, `+ - * | & ^ << >>`, unary `-` and `~`, parentheses, `as` to an integer type, and earlier variants of the same enum. Inside a discriminant, an earlier variant has the enum's [underlying type](#underlying-type), so `Exec = Read << 2` and `RW = Read | Write` work. `~` works in the underlying type: `All = ~0` in a `u32` enum is `0xFFFFFFFF`. A variant without a discriminant is the previous value plus one, or 0 if it is first.

A value that doesn't evaluate or doesn't fit the underlying type is [SC128E](/docs/language/diagnostics/#sc128e-an-enum-discriminant-does-not-evaluate-or-does-not-fit). Two variants with the same value is [SC130E](/docs/language/diagnostics/#sc130e-two-variants-of-an-enum-have-the-same-value); imported C++ enums are exempt.

Compound expressions are valid for bit flags:

```kairo
enum FileMode derives u8 {
    Read    = 1 << 0,   // 1
    Write   = 1 << 1,   // 2
    Execute = 1 << 2,   // 4
    RW      = (Read | Write),       // 3
    All     = (Read | Write | Execute),  // 7
}

fn main() -> i32 {
    var perms: FileMode = .RW
    if (perms as u8 & FileMode::Read as u8) != 0 {
        // has read permission
    }
    return 0
}
```

[Bitwise operators](/docs/language/operators/#bitwise) are not defined on the enum type itself, so test a flag on the underlying integer: cast both sides with `as` and compare the result with `0`.

A combination no variant names (`Read | Execute`, 5 above) is not a value of a [closed](#closed-and-open-enums) enum, so casting it back with `as` fails. A flags enum that is meant to hold any combination is declared `@open`.

---

## Underlying Type

The default underlying type is `u32`. The compiler promotes to a wider unsigned integer if the number of variants exceeds what `u32` can represent, though a warning is emitted for enums exceeding 2^32 variants.

Specify an explicit underlying type with `derives` followed by an integer type:

```kairo
enum Opcode derives u8 {
    Nop  = 0x00,
    Load = 0x01,
    Store = 0x02,
    Halt = 0xFF,
}
```

Only integer types (`u8`, `u16`, `u32`, `u64`, `i8`, `i16`, `i32`, `i64`, `usize`, `isize`) are permitted. The compiler errors if any discriminant does not fit in the specified type.

> [!NOTE]
> `derives` on an enum specifies the underlying integer type. This is distinct from `derives` on a [class](/docs/language/classes-inheritance/#inheritance), which declares inheritance.

---

## No Associated Data in Variants (Plain Enums Only)

For plain enums without the `{ field: Type }` payload syntax, variants are strictly integer constants. If you need per-variant data, use an [ADT enum](/docs/language/enums-adt/#adt-enums).

For untagged memory overlays where you manage the active member yourself, use [Unions](/docs/language/unions/).

---

## Casting

Plain enum values can be [cast](/docs/language/casting/#plain-enums) to their underlying integer type and back:

```kairo
enum Direction { North, East, South, West }

fn main() -> i32 {
    var dir = Direction::North
    var raw = dir as u32           // 0

    var back = raw as Direction    // Direction::North
    return 0
}
```

Casting back is checked, unless the enum is `@open`: see the next section.

---

## Closed and open enums

A plain enum is **closed** by default: it only ever holds one of its variants' values. Every way to make a value of it keeps that true:

- `n as E` with a **constant** `n` that is no variant's value is a compile error, [SC001E](/docs/language/diagnostics/#sc001e-a-constant-cast-into-a-closed-enum-is-no-variants-value), with a fix-it that declares the enum `@open`.
- `n as E` with any other `n` is checked when it runs. A value that is no variant's **crashes** the program, like a failed bounds check: it prints the cast and where it is, then aborts. It is not a [`panic`](/docs/language/panic/): no `try` catches it. The check compares the integer before the cast, so when the compiler can see the value it costs nothing: `v >= 3` for an enum whose values are `0`, `1`, `2`, and one compare per variant when the values are explicit.

Because a closed enum never holds anything else, the compiler can use the values past its variants: `Color?` is one byte, `null` stored as a value no `Color` has (see [ADT memory layout](/docs/language/enums-adt/#memory-layout)), and a `match` that covers every variant needs no fallback for an undeclared value.

The `@open` attribute declares an **open** enum, one that may hold any value of its underlying type, as a C++ enum does (clang's `enum_extensibility(open)`):

```kairo
@open enum Signal derives u8 {
    Hup = 1,
    Int = 2,
    Kill = 9,
}

fn main() -> i32 {
    var s = 15 as Signal    // fine: Signal is open, 15 is a value it may hold
    return 0
}
```

An open enum gets no `as` check, no niche (`Signal?` keeps a tag), and a complete `match` over it traps on an undeclared value below `-O3`. Use it for flags whose combinations are values, for codes another program may extend, and for anything filled in by C or C++.

- `@open` applies to a plain enum only. On an enum with payloads, a struct, a function or anything else it is an error with a fix-it that removes it. Written on a [forward declaration](#forward-declarations) or the definition, it opens the enum.
- An enum [imported from C or C++](/docs/language/c-cpp/) is always open: clang owns its values.
- An enum with no variants holds no value at all unless it is `@open`; declare one that is a raw word, like the builtin `Byte`, `@open`.

`unsafe` code can still put an undeclared value into a closed enum without `as`: a reinterpreting pointer cast (`&n as unsafe *Color`), a [union](/docs/language/unions/), or C or C++ code writing through a pointer it was handed. That is undefined behavior: the value may read back as `null` through a `Color?`, and a `match` may take any arm. Declare the enum `@open` when other code writes it.

---

## Forward Declarations

Enums can be forward-declared when the underlying type is specified:

```kairo
enum Opcode derives u8    // forward declaration: size is known

fn is_halt(code: Opcode) -> bool { return code == .Halt }

enum Opcode derives u8 {
    Nop  = 0x00,
    Load = 0x01,
    Store = 0x02,
    Halt = 0xFF,
}
```

Without an explicit underlying type, forward declaration is not permitted the compiler needs the size, which depends on the variant count and payload sizes.

## See also

- [Enums](/docs/language/enums/)
- [ADT Enums](/docs/language/enums-adt/)
- [Unions](/docs/language/unions/)
- [Casting](/docs/language/casting/)
- [Extends](/docs/language/extends/#enums)
- [Pattern Matching](/docs/language/pattern-matching/#enum-variant-matching)
