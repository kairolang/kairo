// check for the plaindrome of a string
import std::range::*;

fn is_palindrome(str: string) -> bool {
    if str.length() % 2 == 0 {
        return false;
    }

    var count: usize = 2;

    for i in range::<usize>(((str.length()/2)+1), (str.length())) {
        if str[i] != str[(i - count)] {
            return false;
        }

        count += 2;
    }

    return true;
}

fn main() -> i32 {
    print(f"Is 'racecar' a palindrome?    {"true" if is_palindrome("racecar") else "false"}");
    print(f"Is 'hello' a palindrome?      {"true" if is_palindrome("hello") else "false"}");
    print(f"Is 'madam' a palindrome?      {"true" if is_palindrome("madam") else "false"}");
    print(f"Is 'apple' a palindrome?      {"true" if is_palindrome("apple") else "false"}");
    print(f"Is 'palindrome' a palindrome? {"true" if is_palindrome("palindrome") else "false"}");
    print(f"Is 'abba' a palindrome? {"true" if is_palindrome("abba") else "false"}");
}