// The file that has the C++ types: it imports a header that includes
// <string> and <vector>, so the bridge's conversions exist here. A Kairo
// `string` and a `[i32]` go to C++ functions taking `const std::string &`
// and `const std::vector<int> &` with no cast. plain.k is in the same
// build, imports the same bridge and no header: its C++ names no C++
// standard type, and neither does the bridge's own.

import self::bridge::*
import self::plain::*
ffi "c++" import "takes.hh"

fn main() -> i32 {
    var s: string = " my kairo str"
    var v: [i32]  = [1, 2, 3]
    var c: cxx::std::string = s
    return takes_str(s) + takes_vec(v) + (c.size() as i32) + (s.cxx_size() as i32) + plain_len() - 154
}

// --- lit wiring -----------------------------------------------------------
// RUN: %kairo %s -o %t.exe
// RUN: %t.exe
//
// The scope of each conditional block is defined in this file's C++ only,
// with its body, and each use is a call of it:
// RUN: %kairo %s --print-ir > %t.ir
// RUN: python3 %S/split_ir.py %t.ir %t.d
// RUN: %FileCheck %s --check-prefix=USER --input-file=%t.d/user.k.cc
// USER: struct __kairo_ext_builtin__string__string__if__cxx__std__string {
// USER: ::takes_str({{ ?}}::bridge::__kairo_ext_builtin__string__string__if__cxx__std__string::__kairo_op_as_
// USER: ::takes_vec({{ ?}}::bridge::__kairo_ext_builtin__containers__vector__Vector__if__cxx__std__vector::__kairo_op_as_
// USER: inline{{ ?}}::std::basic_string<char{{.*}}__kairo_ext_builtin__string__string__if__cxx__std__string::__kairo_op_as_
//
// The file with no header, and the bridge itself: no conditional scope, no
// C++ standard string or vector. The unconditional extension is there.
// RUN: %FileCheck %s --check-prefix=PLAIN --input-file=%t.d/plain.k.cc
// RUN: %FileCheck %s --check-prefix=PLAIN --input-file=%t.d/bridge.k.cc
// PLAIN-NOT: __if__
// PLAIN-NOT: std::basic_string
// PLAIN-NOT: std::vector
// PLAIN: __kairo_ext_builtin__string__string
// PLAIN-NOT: __if__
// PLAIN-NOT: std::basic_string
// PLAIN-NOT: std::vector
