fn <T impl Numeric> sum(self, items: [T]) -> T {
    var total: T = 0 as T
    for var i in items {
        total += i
    }
    return total
}

fn <T impl Numeric> op=(self, items: [T]) -> T {
    var total: T = 0 as T
    for var i in items {
        total += i
    }
    return total
}