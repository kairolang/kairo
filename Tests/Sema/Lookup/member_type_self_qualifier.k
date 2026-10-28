// The scope exception's readability lint. Inside a type body a nested type,
// type alias or associated type of that type may be named bare (`Node` means
// `Self::Node`; classes.md "Members always need a qualifier"). That stays
// LEGAL, and is SC001W with a note at the declaration and the fix-it that
// inserts `Self::` -- at the use nothing says the name is a member. Warned
// wherever the exception applies: a class / struct / interface body, an
// `extend` block, an out-of-line `fn Type::m`, a closure inside one; in type
// position and in expression position (`Node { .. }`, `Node::make()`).
// Not warned: `Self::Node` / `Tree::Node`, `Self`, the type's own name, a
// nested type naming itself, a nested type naming a sibling of the type
// AROUND it (`Self::` there would name the wrong scope), a generic
// parameter, a name that is not a member type. (A module cannot be
// declared in a type body, so the exception's "nested module" has no case.)

class Tree {
    class Node {
        var value: i32
        var next: *Node?
        fn depth(self) -> Depth { return 0 }
        static fn make() -> Node { return Node { value: 0, next: &null } }
    }
    type Depth = i32

    var root: Node

    fn Tree(self) { self.root = Self::Node::make() }

    fn first(self) -> Depth {
        var n = Node { value: 1, next: &null }
        var m = Node::make()
        var d: Self::Depth = 0
        var e: Tree::Depth = 1
        var t: Tree = Tree()
        var s: Self = Tree()
        var f = fn () -> i32 { var k: Depth = 2; return k }
        return n.value + m.value + d + e + f()
    }

    fn later(self) -> Depth
}

fn Tree::later(self) -> Depth {
    var n: Node = Node::make()
    return n.value
}

extend Tree {
    fn in_extend(self) -> Depth {
        var n = Node { value: 2, next: &null }
        return n.value
    }
}

interface Shape {
    type Unit
    fn area(self) -> Unit
    fn scale(self) -> Self::Unit
}

struct Pair {
    type Half = i32
    var a: Half
    var b: Self::Half
}

class <T> Gen {
    type Elem = T
    fn get(self, x: T) -> Elem { return x }
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK-NOT: {{warning|error}}
// CHECK: member_type_self_qualifier.k:24:15: warning [SC001W]: nested type 'Node' of 'Tree' is named without a qualifier; write 'Self::Node' so it reads as a member
// CHECK-NEXT: fix-it:{{.*}}:{24:15-24:15}:"Self::"
// CHECK-NEXT: member_type_self_qualifier.k:16:11: note [SC001N]: 'Node' is declared here, in 'Tree'
// CHECK-NOT: {{warning|error}}
// CHECK: member_type_self_qualifier.k:28:23: warning [SC001W]: type alias 'Depth' of 'Tree' is named without a qualifier; write 'Self::Depth' so it reads as a member
// CHECK-NEXT: fix-it:{{.*}}:{28:23-28:23}:"Self::"
// CHECK-NEXT: member_type_self_qualifier.k:22:10: note [SC001N]: 'Depth' is declared here, in 'Tree'
// CHECK-NOT: {{warning|error}}
// CHECK: member_type_self_qualifier.k:29:17: warning [SC001W]: nested type 'Node' of 'Tree' is named without a qualifier; write 'Self::Node' so it reads as a member
// CHECK-NEXT: fix-it:{{.*}}:{29:17-29:17}:"Self::"
// CHECK-NEXT: member_type_self_qualifier.k:16:11: note [SC001N]: 'Node' is declared here, in 'Tree'
// CHECK-NOT: {{warning|error}}
// CHECK: member_type_self_qualifier.k:30:17: warning [SC001W]: nested type 'Node' of 'Tree' is named without a qualifier; write 'Self::Node' so it reads as a member
// CHECK-NEXT: fix-it:{{.*}}:{30:17-30:17}:"Self::"
// CHECK-NEXT: member_type_self_qualifier.k:16:11: note [SC001N]: 'Node' is declared here, in 'Tree'
// CHECK-NOT: {{warning|error}}
// CHECK: member_type_self_qualifier.k:35:39: warning [SC001W]: type alias 'Depth' of 'Tree' is named without a qualifier; write 'Self::Depth' so it reads as a member
// CHECK-NEXT: fix-it:{{.*}}:{35:39-35:39}:"Self::"
// CHECK-NEXT: member_type_self_qualifier.k:22:10: note [SC001N]: 'Depth' is declared here, in 'Tree'
// CHECK-NOT: {{warning|error}}
// CHECK: member_type_self_qualifier.k:39:23: warning [SC001W]: type alias 'Depth' of 'Tree' is named without a qualifier; write 'Self::Depth' so it reads as a member
// CHECK-NEXT: fix-it:{{.*}}:{39:23-39:23}:"Self::"
// CHECK-NEXT: member_type_self_qualifier.k:22:10: note [SC001N]: 'Depth' is declared here, in 'Tree'
// CHECK-NOT: {{warning|error}}
// CHECK: member_type_self_qualifier.k:42:25: warning [SC001W]: type alias 'Depth' of 'Tree' is named without a qualifier; write 'Self::Depth' so it reads as a member
// CHECK-NEXT: fix-it:{{.*}}:{42:25-42:25}:"Self::"
// CHECK-NEXT: member_type_self_qualifier.k:22:10: note [SC001N]: 'Depth' is declared here, in 'Tree'
// CHECK-NOT: {{warning|error}}
// CHECK: member_type_self_qualifier.k:43:12: warning [SC001W]: nested type 'Node' of 'Tree' is named without a qualifier; write 'Self::Node' so it reads as a member
// CHECK-NEXT: fix-it:{{.*}}:{43:12-43:12}:"Self::"
// CHECK-NEXT: member_type_self_qualifier.k:16:11: note [SC001N]: 'Node' is declared here, in 'Tree'
// CHECK-NOT: {{warning|error}}
// CHECK: member_type_self_qualifier.k:43:19: warning [SC001W]: nested type 'Node' of 'Tree' is named without a qualifier; write 'Self::Node' so it reads as a member
// CHECK-NEXT: fix-it:{{.*}}:{43:19-43:19}:"Self::"
// CHECK-NEXT: member_type_self_qualifier.k:16:11: note [SC001N]: 'Node' is declared here, in 'Tree'
// CHECK-NOT: {{warning|error}}
// CHECK: member_type_self_qualifier.k:48:27: warning [SC001W]: type alias 'Depth' of 'Tree' is named without a qualifier; write 'Self::Depth' so it reads as a member
// CHECK-NEXT: fix-it:{{.*}}:{48:27-48:27}:"Self::"
// CHECK-NEXT: member_type_self_qualifier.k:22:10: note [SC001N]: 'Depth' is declared here, in 'Tree'
// CHECK-NOT: {{warning|error}}
// CHECK: member_type_self_qualifier.k:49:17: warning [SC001W]: nested type 'Node' of 'Tree' is named without a qualifier; write 'Self::Node' so it reads as a member
// CHECK-NEXT: fix-it:{{.*}}:{49:17-49:17}:"Self::"
// CHECK-NEXT: member_type_self_qualifier.k:16:11: note [SC001N]: 'Node' is declared here, in 'Tree'
// CHECK-NOT: {{warning|error}}
// CHECK: member_type_self_qualifier.k:56:22: warning [SC001W]: associated type 'Unit' of 'Shape' is named without a qualifier; write 'Self::Unit' so it reads as a member
// CHECK-NEXT: fix-it:{{.*}}:{56:22-56:22}:"Self::"
// CHECK-NEXT: member_type_self_qualifier.k:55:10: note [SC001N]: 'Unit' is declared here, in 'Shape'
// CHECK-NOT: {{warning|error}}
// CHECK: member_type_self_qualifier.k:62:12: warning [SC001W]: type alias 'Half' of 'Pair' is named without a qualifier; write 'Self::Half' so it reads as a member
// CHECK-NEXT: fix-it:{{.*}}:{62:12-62:12}:"Self::"
// CHECK-NEXT: member_type_self_qualifier.k:61:10: note [SC001N]: 'Half' is declared here, in 'Pair'
// CHECK-NOT: {{warning|error}}
// CHECK: member_type_self_qualifier.k:68:27: warning [SC001W]: type alias 'Elem' of 'Gen' is named without a qualifier; write 'Self::Elem' so it reads as a member
// CHECK-NEXT: fix-it:{{.*}}:{68:27-68:27}:"Self::"
// CHECK-NEXT: member_type_self_qualifier.k:67:10: note [SC001N]: 'Elem' is declared here, in 'Gen'
// CHECK-NOT: {{warning|error}}
