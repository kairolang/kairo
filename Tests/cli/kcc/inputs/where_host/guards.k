// guards.k: `where` dispatch groups a C++ host calls (where_main.cpp). Each
// group is one function in C++, under its public name; the candidates it
// dispatches to are private to this file.
import std::io::println

pub fn categorize(x: i32) -> i32 where x > 100 { return 2 }
pub fn categorize(x: i32) -> i32 where x > 0   { return 1 }
pub fn categorize(x: i32) -> i32               { return 0 }

pub fn safe_divide(a: i32, b: i32) -> i32 where b != 0 { return a / b }
pub fn safe_divide(a: i32, b: i32) -> i32               { return 0 }

pub class Meter {
    pub var limit: i32
    pub fn Meter(self, limit: i32) { self.limit = limit }
    pub fn read(self, v: i32) -> i32 where v > self.limit { return self.limit }
    pub fn read(self, v: i32) -> i32 { return v }
}
