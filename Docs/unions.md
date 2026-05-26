# Unions

Unions overlay multiple fields at the same memory address, sized to the largest member. They are a low-level
memory layout tool for hardware registers, binary protocol parsing, and type punning. The user is responsible
for tracking which field is active there is no compiler-managed tag.

For type-safe tagged unions with compiler-enforced variant tracking, use
[ADT enums](/docs/language/enums#adt-enums).

---

## Declaration

```kairo
union Register {
    var as_u32: u32
    var as_bytes: [u8; 4]
    var as_f32: f32
}
```

All fields share the same starting address. The union's size is the size of its largest member, plus
any alignment padding.

---

## Usage

Read and write fields with plain assignment. No special syntax or `unsafe` block is required:

```kairo
var r: Register
r.as_u32 = 0xDEADBEEF
var byte0 = r.as_bytes[0]   // reads overlapping memory as u8

r.as_f32 = 3.14f32
// r.as_u32 now contains the bit representation of 3.14 as f32
```

Reading a field other than the one last written is type punning the value you get is the raw bit
reinterpretation. This is legal but the result depends entirely on the underlying representation.

> [!CAUTION]
> The compiler does not track which field was last written. Reading the wrong field is not a compile
> error it produces whatever bits happen to be in memory. This is the intended use case for unions,
> but it means correctness is entirely on the caller.

---

## Trivial Types Only

Union fields must be trivially copyable. The following types are permitted:

- Integers (`i8`--`i512`, `u8`--`u512`, `isize`, `usize`)
- Floats (`f16`--`f512`)
- Booleans (`bool`)
- Characters (`char`)
- Bytes (`byte`)
- Pointers (`*T`, `unsafe *T`)
- Fixed-size arrays of trivial types (`[T; N]`)
- Structs where all fields are trivially copyable
- Other unions
- Enums (plain, without ADT payloads)

Non-trivially copyable types are a compile error:

```kairo
union Bad {
    var text: string    // compile error: string has a destructor
    var data: [i32]     // compile error: vector owns heap memory
}
```

If you need a union of non-trivial types, use an [ADT enum](/docs/language/enums#adt-enums) the
compiler manages construction, destruction, and active-variant tracking for you.

---

## Unions Must Be Named

Unions cannot exist as standalone anonymous types. They must always be declared with a name:

```kairo
union Pixel {           // ok: named union
    var rgba: u32
    var channels: [u8; 4]
}
```

---

## Nesting in Structs and Classes

Unions are commonly embedded in structs or classes for structured access to overlapping data:

```kairo
struct Packet {
    var opcode: u8
    var payload: PacketData
}

union PacketData {
    var as_int: i64
    var as_float: f64
    var as_bytes: [u8; 8]
}

var pkt: Packet
pkt.opcode = 0x01
pkt.payload.as_int = 42
```

For a type-safe version of this pattern (where the opcode determines which payload field is valid),
use an [ADT enum](/docs/language/enums#adt-enums) instead.

---

## Generic Unions

Unions can be generic:

```kairo
union <T, U> Either {
    var left: T
    var right: U
}

var e: Either<i32, f32>
e.left = 42
```

Type parameters must resolve to trivially copyable types. The compiler errors at instantiation time
if a type argument is not trivially copyable.

---

## Memory Layout

Union layout follows the platform's C++ ABI:

- Size equals the largest member's size, rounded up for alignment
- All fields start at offset 0
- Alignment is the strictest alignment of any member

Layout attributes work the same as on structs and classes:

```kairo
@packed
union Compact {
    var a: u8
    var b: u32   // no padding between a and b at the union level
}

@align(16)
union Aligned {
    var data: [u8; 12]
    var value: i32
}
```

---

## Forward Declarations

Unions can be forward-declared for use in pointer types:

```kairo
union Payload    // forward declaration

struct Message {
    var kind: u8
    var data: unsafe *Payload
}

union Payload {
    var as_int: i64
    var as_bytes: [u8; 8]
}
```

---

## No Extends

Unions do not support `extend` blocks. They are raw memory overlays with no behavior adding
methods would blur the line between unions and [classes](/docs/language/classes). If you need methods
on overlapping data, wrap the union in a struct or class and add behavior there.

---

## No Inheritance

Unions do not support `derives`. They cannot inherit from or be inherited by other types.

---

## Summary

```kairo
// Basic union
union Color {
    var rgba: u32
    var channels: [u8; 4]
}

var c: Color
c.rgba = 0xFF0000FF
c.channels[0]   // 0xFF (on little-endian)

// Generic union
union <A, B> Reinterpret {
    var a: A
    var b: B
}

var bits: Reinterpret<f32, u32>
bits.a = 3.14f32
std::println(f"bits of 3.14: 0x{bits.b:X}")

// Nested in a struct
struct HardwareRegister {
    var address: usize
    var value: RegValue
}

union RegValue {
    var raw: u32
    var fields: RegFields
}

struct RegFields {
    var low: u16
    var high: u16
}

var reg: HardwareRegister
reg.address = 0x4000_0000
reg.value.raw = 0xDEAD_BEEF
reg.value.fields.low    // 0xBEEF (little-endian)
reg.value.fields.high   // 0xDEAD (little-endian)
```