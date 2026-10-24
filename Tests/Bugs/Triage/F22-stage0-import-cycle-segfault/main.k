// build: kairo main.k --emit-ir   (Stage 0; expect an import-cycle diagnostic naming a.k and b.k, not exit 139)
import a::*;

fn main() -> i32 {
    return a_val();
}
