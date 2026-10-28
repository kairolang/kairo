# ADT Enums

Variants can carry structured data. Each payload is defined as a set of named fields inside braces:

```kairo
enum <T> ParseResult {
    Success { value: T, bytes_consumed: i32 },
    Error   { message: string, position: i32 },
    EndOfInput,
}
```

Variants without a payload (`EndOfInput` above) are plain discriminants. Variants with a payload carry an anonymous struct alongside the discriminant. A single enum can freely mix both.

> [!NOTE]
> A non-generic payload enum whose payload holds a type whose copy, move and destruction are not known until instantiation (such as `Box<i32>` for a generic class `Box`) is not compiled yet. See [Status](/docs/status/#not-compiled-yet).

## Construction

There are three construction forms:

| Form | Use |
|---|---|
| `Enum::V { f: e }` | Payload variant, fully qualified |
| `.V { f: e }` | Payload variant, enum type inferred from context |
| `.V` (or `Enum::V`) | Variant with no payload |

A payload variant written without braces, braces on a variant without a payload, a missing field, or a field given twice is [SC131E](/docs/language/diagnostics/#sc131e-a-variant-is-built-with-the-wrong-shape).

`Enum::V { field: value }` builds a payload variant anywhere; `.V { field: value }` and `.V` work where the expected type is known. A nullary variant takes no braces.

ADT variants are constructed with the variant name followed by brace-delimited field assignment, matching [struct](/docs/language/structures/) aggregate initialization:

```kairo
enum <T> ParseResult {
    Success { value: T, bytes_consumed: i32 },
    Error   { message: string, position: i32 },
    EndOfInput,
}

fn main() -> i32 {
    var result = ParseResult<f64>::Success { value: 3.14, bytes_consumed: 4 }
    var err = ParseResult<f64>::Error { message: "unexpected token", position: 12 }
    var eof = ParseResult<f64>::EndOfInput

    // the enum type is known from the declaration, so the shorthand works
    var inferred: ParseResult<f64> = .Success { value: 3.14, bytes_consumed: 4 }
    return 0
}
```

Field names are required. The order of fields in the initializer does not need to match the declaration order.

## Destructuring with `match`

Use `match` to dispatch on variants and extract payload fields. Destructured fields use `var` or `const` to control mutability of the bound variable:

```kairo
enum <T> ParseResult {
    Success { value: T, bytes_consumed: i32 },
    Error   { message: string, position: i32 },
    EndOfInput,
}

fn report(result: ParseResult<f64>) -> string {
    match result {
        case .Success(var value, var bytes_consumed) {
            return f"parsed {value} from {bytes_consumed} bytes"
        }
        case .Error(const message, const position) {
            // message = "other"  // compile error: message is const
            return f"error at {position}: {message}"
        }
        case .EndOfInput {
            return "nothing left to parse"
        }
    }
}
```

> [!NOTE]
> The current compiler does not report assigning to a `const` pattern binding yet. See [Status](/docs/status/#not-diagnosed).

Field names in the destructuring pattern must match the names in the variant declaration. You can omit fields you do not need the compiler does not require exhaustive field extraction:

```kairo
enum <T> ParseResult {
    Success { value: T, bytes_consumed: i32 },
    Error   { message: string, position: i32 },
    EndOfInput,
}

fn error_message(result: ParseResult<f64>) -> string {
    match result {
        case .Error(const message) {
            // only message is bound, position is ignored
            return message
        }
        default { return "" }
    }
}
```

See [Control Flow](/docs/language/pattern-matching/) for the full `match` syntax, including guards (`where`), ranges, and expression form.

## `match` as an expression

```kairo
enum <T> ParseResult {
    Success { value: T, bytes_consumed: i32 },
    Error   { message: string, position: i32 },
    EndOfInput,
}

fn describe(result: ParseResult<f64>) -> string {
    return match result {
        case .Success(var value, var bytes_consumed) => f"parsed {value} ({bytes_consumed} bytes)"
        case .Error(var message, var position) => f"error at {position}: {message}"
        case .EndOfInput => "end of input"
    }
}
```

ADT enums work in expression-form `match`. Each arm is `case pattern => value`, and every arm must produce the same type.

See [Control Flow](/docs/language/pattern-matching/#match-as-an-expression) for the full expression-form rules.

## Memory layout

An ADT enum stores a discriminant tag plus storage sized to the largest variant's payload. The tag is the enum's `derives` type when it names one, otherwise the smallest unsigned integer that holds a tag per variant: `u8` up to 256 variants, `u16` beyond. A variant with no payload consumes no extra storage beyond the tag. A `derives` type too narrow for the variants is an error.

```
ParseResult<f64> layout:
  [tag: u8] [payload: max(sizeof Success, sizeof Error)] [padding]
```

When every payload field is a primitive, a pointer, or a plain enum, the tag sits inside each payload instead of in front of it, so the payload's padding absorbs it: `enum Pair { Two { a: u8, b: u16 }, One { c: u8 }, Zero }` is 4 bytes, not 6.

An enum with exactly one variant that carries a payload, that payload a single field, and at least one variant without a payload, may need no tag at all. If the field has bit patterns it never holds, each payload-free variant is stored as one of them:

- a pointer is never null, so `null` stands for the variant: `(*Foo)?` is the size of a pointer, and is passed and returned like one;
- a [closed](/docs/language/enums-plain/#closed-and-open-enums) plain enum whose values are `0` to `N-1` never holds a value past its last variant: `Color?` is one byte for an `enum Color derives u8 { Red, Green, Blue }`, with `null` stored as 3;
- an enum with payloads never holds a tag past its last variant: `Inst?` is the size of `Inst`.

An [`@open`](/docs/language/enums-plain/#closed-and-open-enums) plain enum has no spare patterns: `as` can give it any value of its underlying type, so `Color?` keeps a tag (two bytes for an `@open enum Color derives u8`). Neither does a plain enum with explicit values that leave gaps, nor an imported C or C++ enum.

The field must also copy and destroy as plain bytes. Nesting keeps working: `(Color?)?` is still one byte, stored as 4, since `Color?` leaves values to spare, while `((*Foo)?)?` needs a tag, since the pointer's only spare pattern is taken. No program can observe the difference except through `sizeof`.

The compiler generates a [destructor](/docs/language/classes-lifecycle/#destructors---delete-operators) that switches on the tag to destroy the active variant's fields. Copy and move operations follow the same pattern.

## Lifecycle category

An enum whose variants carry payloads follows the struct rule for lifecycle: its [category](/docs/language/classes-lifecycle/#lifecycle-categories) is the weakest of its payload fields' categories (COPY, then MOVE, then NON_TRANSFER), and it is trivially copyable or destructible only when every payload is. A plain enum is COPY.

---

## Generic Enums

Enums with payloads can be [generic](/docs/language/generics/). Type parameters are declared in angle brackets before the enum name:

```kairo
enum <K, V> LookupResult {
    Found    { key: K, value: V },
    NotFound { key: K },
    Error    { message: string },
}

fn main() -> i32 {
    var r = LookupResult<string, i32>::Found { key: "count", value: 42 }
    return 0
}
```

Constrain type parameters with `impl` or `derives` bounds:

```kairo
interface Serializable {
    fn serialize(const self) -> [byte]
}

enum <T impl Serializable> CacheEntry {
    Valid   { data: T, expires: i64 },
    Expired { last_data: T },
    Empty,
}
```

See [Requires Clauses](/docs/language/requires/) for the full constraint system.

### Variadic enums

An enum can take a type pack (`...E`, as in [generic variadic functions](/docs/language/functions-parameters/#generic-variadic-functions)) and declare a **pack-expanded variant**: a variant written once and followed by `...`, which expands to one variant per element of the pack.

```kairo
enum <T, ...E> Outcome {
    Ok  { value: T },
    Err { error: E }...,    // one Err variant per element of E
}

type Parsed = Outcome<i32, string, f64>   // variants: Ok { value: i32 }, Err { error: string }, Err { error: f64 }
type Plain  = Outcome<i32>                 // an empty pack: only Ok
```

- A pack-expanded variant's payload names the pack (`E`) as a field's whole type, and each expansion has that element as its payload type.
- The expansions share the variant's name and are told apart by their payload type: a pattern or construction that names `Err` picks the expansion whose payload type matches.
- Equal types in a pack give one variant, not two: `Outcome<i32, string, string>` has one `Err { error: string }`, and is the same type as `Outcome<i32, string>`.
- A variant that is not followed by `...` is an ordinary variant, the same in every instantiation. It cannot name the pack.
- An enum has at most one pack-expanded variant, and it is the last one.

A construction picks the expansion whose payload type is the value's type exactly, or, failing that, the one expansion the value converts to:

```kairo
var a: Parsed = .Err { error: "bad digit" }   // Err { error: string }
var b: Parsed = .Err { error: 0.5 }           // Err { error: f64 }
var c: Parsed = .Err { error: 1 }             // Err { error: f64 }: an i32 matches neither exactly, and converts only to f64
var d: Parsed = .Err { error: true }          // error: no Err holds a bool
```

A value that converts to more than one expansion is an error too: in `Outcome<i32, i64, f64>`, an `i32` fits both `Err { error: i64 }` and `Err { error: f64 }`, so the payload's type must pick one.

A pattern picks one by the type written on the binder of the pack field. With a single expansion the type may be left out. Each expansion is its own case for [exhaustiveness](/docs/language/pattern-matching/#exhaustiveness):

```kairo
fn describe(p: Parsed) -> string = match p {
    case .Ok(var value)           => f"{value}"
    case .Err(var error: string)  => error
    case .Err(var error: f64)     => "out of range"
}
```

A generic function can take and return a variadic enum, and its pack is deduced from the argument (`fn <...E> relay(o: Outcome<i32, E...>) -> Outcome<i32, E...>`). Building or matching a pack-expanded variant at a type that still depends on a generic parameter is not supported yet ([SC116E](/docs/language/diagnostics/#sc116e-a-feature-is-not-yet-supported)).

The builtin result type of a [panicking function](/docs/language/panic/) is declared this way, with the function's panic set as the pack.

---

## Casting

ADT enums cannot be cast to integers directly they carry payloads that have no integer representation. Cast the tag explicitly if you need the discriminant value.

See [Casting](/docs/language/casting/#enum-casts) for the full casting model.

## See also

- [Enums](/docs/language/enums/)
- [Plain Enums](/docs/language/enums-plain/)
- [Pattern Matching](/docs/language/pattern-matching/)
- [Generics](/docs/language/generics/)
- [Structures](/docs/language/structures/)
- [Unions](/docs/language/unions/)
- [Requires Clauses](/docs/language/requires/)
- [Casting](/docs/language/casting/#adt-enums)
