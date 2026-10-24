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

An ADT enum stores a discriminant tag plus storage sized to the largest variant's payload. The tag is a `u32`. A variant with no payload consumes no extra storage beyond the tag.

> [!NOTE]
> A `derives` type on an enum with payloads is accepted but ignored for now: the tag stays `u32`. See [Status](/docs/status/#not-compiled-yet).

```
ParseResult<f64> layout:
  [tag: u32] [payload: max(sizeof Success, sizeof Error)] [padding]
```

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
