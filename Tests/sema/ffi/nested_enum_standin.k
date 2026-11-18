// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 7
//
// A C++ container of a Kairo record that holds a MEMBER enum
// (`Label::Style`), and of anything holding such a container
// (`vector<unsafe *Diag>`, Diag holding a `vector<Label>`). Filling the
// instance needs a C++ stand-in for the element; a member enum's stand-in
// is nested in its owner's like a member RECORD's; otherwise the
// owner's stand-in fails on that field, the instance stays unfilled, and
// its members come from the pattern with a dependent `size_type`: SC063E on
// `reserve(4)` / `v[i]`, SC066E on `v.size() > 0` -- Diagnostic.k's
// `children` / `labels` shape.

ffi "c++" import "vector";

struct Label {
    enum Style derives u8 { Primary, Secondary }
    var n: i32
    var style: Style
}

class Diag {
    var labels: cxx::std::vector<Label>
    var children: cxx::std::vector<unsafe *Diag>
    fn Diag(self) { self.labels.reserve(4); self.children.reserve(2) }
    fn last(self) -> unsafe *Diag {
        if self.children.size() > 0 { return self.children[self.children.size() - 1] }
        return &null
    }
    fn total(self) -> i32 {
        var t = 0
        for var i: usize = 0; i < self.labels.size(); ++i {
            if self.labels[i].style == Label::Style::Secondary { t += self.labels[i].n }
        }
        return t
    }
}

fn main() -> i32 {
    var d = Diag()
    d.labels.push_back(Label{n: 3, style: Label::Style::Secondary})
    d.labels.push_back(Label{n: 5, style: Label::Style::Primary})
    d.labels.push_back(Label{n: 4, style: Label::Style::Secondary})
    var n = 0
    if d.last() == &null { n = 0 }
    return d.total() + n
}

// DIAG-NOT: error
