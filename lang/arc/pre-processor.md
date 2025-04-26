# Pre-Processor
- define
- global
- macro

---

## Table of Contents
- [Pre-Processor](#pre-processor)
  - [Table of Contents](#table-of-contents)
    - [Define](#define)
    - [Global Define](#global-define)
    - [Macro](#macro)
  - [Examples](#examples)

---

### Define
```rs
define PI: 3.14159;

define square_root(a): a as f32 if a is int else sqrt(a);

define add_and_sub(a: Number!, b: Number!) {
    a + b, a - b;
}

priv define create_cast(name: str) {
    define name(ty: Type!, val: Identifier! | Literal! ) {
        extern "C++" compiler::to_code!(f"{name}_cast")<ty>(val);
    }
}
```

### Global Define
```rs
global define PI: 3.14159; // exposed to all namespace equivalent to #define in C
```

### Macro
```rs
macro any_cast(dest: Type!, src: Identifier! | Literal!) {
    return match (helix::compiler::TARGET) {
        compiler::Target::CPP -> compiler::to_string!(unsafe extern "C++" (dest)src);
        compiler::Target::C   -> compiler::to_string!(extern "C" (dest)src);
        _                     -> panic MacroRuntimeError("Unsupported target");
    }
}
```

---

## Examples
```rs
#[no_entry]

define PI: 3.14159;

macro any_cast(dest: Type!, src: Identifier! | Literal!) {
    switch helix::compiler::TARGET {
        case helix::compiler::Target::CPP {
            unsafe extern "C++" ($dest)$src;
            break;
        }

        case helix::compiler::Target::C {
            extern "C" ($dest)$src; 
            break;
        }

        default {
            panic MacroRuntimeError("Unsupported target");
        }
    }
}

let a: i8 = 1;

print(PI as f32);        // 3.14159
print(any_cast(f32, a)); // 1.0
```