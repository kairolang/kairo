// Neighbouring niche-shaped generic ADTs whose payload names no parameter:
// a u8, a bool, and a two-field payload. Each builds, matches and type-checks
// without an internal error and keeps its payload.

enum <T> G8 { A { x: u8 }, B }
enum <T> GB { A { x: bool }, B }
enum <T> G2 { A { x: i32, y: i32 }, B }

fn val8(const g: G8<i32>) -> i32 = match g {
    case .A(const x) => x as i32
    case .B => 0
}
fn fb(const g: GB<u8>) -> i32 = match g {
    case .A(const x) => 1
    case .B => 2
}
fn val2(const g: G2<i32>) -> i32 = match g {
    case .A(const x, const y) => x + y
    case .B => 0
}

fn main() -> i32 {
    if val8(G8<i32>::A { x: 7 as u8 }) != 7 { return 1 }
    if fb(GB<u8>::B) != 2 { return 2 }
    if fb(GB<u8>::A { x: true }) != 1 { return 3 }
    if val2(G2<i32>::A { x: 1, y: 2 }) != 3 { return 4 }
    if val2(G2<i32>::B) != 0 { return 5 }
    return 0
}

// --- lit wiring ---
// RUN: rm -f %t.exe
// RUN: %kairo %s -w -o %t.exe --cache-dir %t.d 2>&1 | %FileCheck %s --allow-empty --implicit-check-not='I003E' --implicit-check-not='CL001E' --implicit-check-not='error ['
// RUN: %t.exe
