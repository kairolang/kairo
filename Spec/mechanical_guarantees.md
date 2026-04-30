# Kairo's guarantees about mechanical properties of the language specification and implementation.

## Const
We will this use this basic class:
```kairo
struct <T> Vec {
    var data: *T
    var len: i32
}
// we extend to this as we go on
```

attach to a declaration means that the declaration is read-only, and any attempt to modify it will result in a compile-time error.
```kairo
const x: i32 = 5; // x is a immutable
x = 10; // Error: cannot assign to a constant variable

/// pointers
const x: *i32 = ...; // x is a pointer to a constant i32, the pointer itself can be modified but not the value it points to
*x = 10; // valid
x = new_pointer; // Error: cannot assign to a constant pointer
// the value itself is mutable, but the pointer is not.
```

## Self
The self param on methods indicates whether the method can modify the instance it is called on. A method with `const self` cannot modify the instance, while a method with `self` can modify it.
```kairo
extend <T> Vec {
    fn len(const self) -> i32 {
        return self.len; // valid, does not modify self
    }

    fn get(const self, index: i32) -> *const T { // a pointer to a const T, we can change the pointer itself, not the value it points to.
        return &self.data[index];
    }

    fn push(self, value: T) {
        self.data[self.len] = value; // valid, modifies self
        self.len += 1; // valid, self is not marked as const
    }

    fn clear(const self) {
        self.len = 0; // Error: cannot modify self in a const method
    }
}
```

usage:
```kairo
const vec: Vec<i32> = Vec { data: ..., len: 0 }; // vec is a immutable but `Vec<i32>` is not a const type, so we can call non-const methods on it
vec.len(); // valid, calls the const method
vec.push(10); // valid
var dat: *const i32 = vec.get(10);
dat[0] = 5; // invalid, dat is a pointer to a const i32, we cannot modify the value it points to

vec = Vec { data: ..., len: 0 }; // Error: mutate to a immutable variable

var vec2: const Vec<i32> = Vec { data: ..., len: 0 }; // vec2 is a mutable variable, but it holds a immutable Vec
vec2.len(); // valid, calls the const method
vec2.push(10); // Error: cannot call a non-const method on a const type
vec2 = Vec { data: ..., len: 0 }; // valid, vec2 is mutable, we can assign a new value to it

// pointers get a bit more interesting:
// const is applied left to right and freezes immidiately to the right of it, until we get to a base type, where it restictits the type's API, (where cannot call non-const methods on it)
var vec3: const *Vec<i32> = ...; // invalid this is indentical to `const vec3: *Vec<i32> = ...;` so compiler errors and says to fix the syntax.

var vec4: *const Vec<i32> = ...; // valid, vec4 is a mutable pointer to a const Vec
vec4->len(); // valid, calls the const method
vec4->push(10); // Error: cannot call a non-const method on a const type
vec4 = new_pointer; // valid, vec4 is a mutable pointer, we can assign

// a more intresting case is when we have multiple levels of pointers
var vec5: *const *Vec<i32> = ...; // this is a mutable vec5, which is a mutable pointer to a const pointer to a mutable Vec (as stated const reads left to right and freezes immidiately to the right of it)

vec5 = new_pointer; // valid, vec5 is a mutable pointer, we can assign a new value to it
*vec5 = new_pointer; // invalid, this would require us to modify the const pointer that vec5 points to, which is not allowed
(**vec5).push(10); // valid, the underlying Vec is non-const

vec6 = new_pointer; // valid
var vec6: **const Vec<i32> = ...; // this is a mutable vec6, which is a mutable pointer to a mutable pointer to a const Vec
*vec6 = new_pointer; // valid
(**vec6).push(10); // Error: cannot call a non-const method on a const type, the underlying Vec is const
```

# Raw
Kairos mem saftry is simple normal pointers are tracked by the BCIR and AMT and have their aliasing and mutability properties enforced by the type system. the runtime also tracks pointers since a nomral pointer in kairo would be a Fat Pointer, a pointer + size, no other meta, but its enough to be proveable safe at both runtime and compile time. but sometimes you just want to do raw pointer stuff, and for that we have raw pointers, which are not tracked by the BCIR or AMT, and have no guarantees about safety or aliasing.

```kairo
/// raw only exists in one place, and its for pointers
var x: raw *i32 = ...; // x is a raw pointer to an i32, it has no guarantees about safety or aliasing
*x = 10; // invlaid outside a raw block, raw pointers cannot be dereferenced or used in any way that would require safety guarantees outside of a raw block
raw {
    *x = 10; // valid, we are in a raw block, we can use raw pointers
}

// raw blocks are not nested, and they do not propagate, meaning that if we call a function that takes a raw pointer, we must be in a raw block to call it, but the function itself does not have to be marked as raw, and it does not propagate the rawness to its callers.
```

# Unsafe
unsafe is a marker for APIs that are an altranate possbile unsafe implementation of a safe API. unsafe APIs can be used in safe code, compiler enforces AMT and BCIR rules on unsafe APIs, but it says the code might not be logically safe, and its the callers responsibility to ensure that the safety invariants of the API are upheld when using the unsafe version.

```kairo
class Foo {
    var data: [i32; 10];

    fn get(self, index: usize) -> usize { // this method is logically safe, it upholds all safety invariants. (compiler cant check this, but we are claiming it does, and the author is responsible for ensuring it does)
        if index < 10 {
            return self.data[index];
        } else {
            return 0;
        }
    }

    fn get(self, index: usize) unsafe -> usize {
        return self.data[index]; // this method is unsafe because it does not uphold the logical invariant that index must be less than 10, but it is still a valid API to expose, and its the callers responsibility to ensure they uphold the safety invariant when using this method.
        // in this case this unsafe variant might be faster then the safe one, but its up to the author to ensure what the unsafe variant does. Unsafe acts like an alternate implementation to an API.
    }
}

// usage:
var foo = Foo { data: ... };
foo.get(5); // always calls safe version, which upholds the safety invariant
foo.unsafe get(5); // calls the unsafe version

class Bar {
    var data: [i32; 10];

    // no safe version

    unsafe fn get(self, index: usize) -> usize { return self.data[index]; }
}

var bar = Bar { data: ... };
bar.get(5); // error: no safe version of get compiler never chooses an unsafe API to call.
bar.unsafe get(5); // valid, calls the unsafe version

class Baz {
    var data: [i32; 10];

    fn get(self, index: usize) -> usize {
        if index < 10 {
            return self.data[index];
        } else {
            return 0;
        }
    }
}

var baz = Baz { data: ... };
baz.get(5); // valid, calls the only version of get, which is safe
baz.unsafe get(5); // error: no unsafe version of get
```

# Virtual and Dynamic Dispatch
Kairo DOES not expose internal vtable mechanisms, and it does not have a virtual keyword. instead, override is a keyword that indicates that a method is intended to override.

(this is a maybe, implementation specific)
