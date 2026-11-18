// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 14
// A script's top-level `var a: [i32; 2] = [1, 2]` was deferred, and
// its storage `Nullable<int[2]>` could not be built (clang: "cannot
// initialize an array element"). A list literal of constants is a
// constant initializer: C++'s static `{...}`, as an integer literal's
// is. Nested arrays too.

var a: [i32; 2] = [1, 2]
var g: [[i32; 2]; 2] = [[3, 4], [0, 0]]

fn sum() -> i32 {
    return a[0] + a[1] + g[0][0] + g[0][1]
}

a[1] = 5
g[1][1] = 1
return sum() + g[1][1] // 1 + 5 + 3 + 4 + 1
