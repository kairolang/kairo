import std::Interfaces

// DISCLAIMER: The standard library is not implemented (yet™) and is subject to change

fn factorial(n: i32) -> i32 {
    if n == 0 {
        return 1
    }
    
    return n * factorial(n - 1)
}

fn <T impl Interfaces::Comparable> selection_sort(arr: list<T>) {
    var n = arr.len()
    
    for i in 0..n {
        var min_idx = i
        
        for j in (i+1)..n {
            if arr[j] < arr[min_idx] {
                min_idx = j
            }
        }
        
        unless min_idx == i {
            var temp     = arr[min_idx]
            arr[min_idx] = arr[i]
            arr[i]       = temp
        }
    }
}