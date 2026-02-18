#![allow(unused_macros)]
#![warn(unreachable_patterns)]
use std::{
    fmt::Debug,
    ops::BitOr,
    ptr::{slice_from_raw_parts, NonNull},
    sync::atomic::Ordering,
};

// idea, parse the whole std and make the interfaces for the stuff for a test
#[derive(Debug)]
pub struct Token<'cxx> {
    sub_tokens: &'cxx [u8],
    column: usize,
    row: isize,
    ty: TokenType,
}

macro_rules! token_patterns {
    ($($name:ident: $pattern:pat),*) => {
        $(
            macro_rules! $name {
                () => {
                    $pattern
                };

                (first_char) => {
                    kairo_proc::get_first_char_pattern!($pattern)
                };

                (u16$phantom:literal) => {
                    kairo_proc::convert_bytes_to_u16!($pattern)
                };

                (contains $ch:expr) => { matches!($ch, $name!()) };

                (raw$phantom:literal) => {kairo_proc::raw!($pattern)};
                (contains u16 $ch:expr ) => {
                    matches!($ch, $name!(u16 ""))
                };
            }
        )*
    }
}

token_patterns! {

    open_delimiters:curly_open!() | paren_open!() | square_open!() | angle_open!(),
    close_delimiters:curly_close!() | paren_close!() | square_close!() | angle_close!(),
    delimiters: open_delimiters!() | close_delimiters!(),

    curly_open: b'{',
    curly_close: b'}',
    paren_open: b'(',
    paren_close: b')',
    square_open: b'[',
    square_close: b']',
    angle_open: b'<',
    angle_close: b'>',

    list_separator: b',',

    scope_separator: b';',

    type_separator: b':',


    newline: b'\n',
    other_whitespace: b'\t' | b'\x0C' | b'\r' | b' ',

    whitespace: other_whitespace!() | newline!(),

    string_quotes: b'"',
    char_quotes: b'\'',

    quotes: string_quotes!() | char_quotes!(),

    backslash: b'\\',

    raw_literal_prefix: b'r',
    binary_literal_prefix: b'b',
    unicode_literal_prefix: b'u',
    formatted_literal_prefix: b'f',

    quote_prefixes: raw_literal_prefix!() | binary_literal_prefix!() | unicode_literal_prefix!() | formatted_literal_prefix!(),




    // Null operators
    nullish_coalescing: b"??",
    nullable: b'?', // Postfix
    safe_propagation: b'?', // Suffix
    //elvis: b"?:",


    // Bitwise
    bitwise_not: b'~', // Prefix
    bitwise_not_assign: b"~=", // Infix, b"~~="
    bitwise_and: b'&',// Infix, b"~~&"
    bitwise_and_assign: b"&=", // Infix, b"~~&="
    bitwise_or: b'|', // Infix, b"~~|"
    bitwise_or_assign: b"|=", // Infix, b"~~|="
    bitwise_xor: b'^', // Infix, b"~~^"
    bitwise_xor_assign: b"^=", // Infix, b"~~^="
    bitwise_nor: b"~|", // Infix, b"~~~|"
    bitwise_nor_assign: b"~|=", // Infix, b"~~~|="

    bitwise_nand: b"~&", // Infix, b"~~~&"
    bitwise_nand_assign: b"~&=", // Infix, b"~~~&="
    bitwise_xnor: b"~^", // Infix, b"~~~^"
    bitwise_xnor_assign: b"~^=", // Infix, b"~~~^="
    left_shift: b"<<", // Infix, b"~>>"
    left_shift_assign: b"<<=", // Infix, b"~>>="
    right_shift: b">>", // Infix, b"~<<"
    right_shift_assign: b">>=", // Infix, b"~<<="


    // Arithmetic operators
    power: b"**", // Infix, b"--*"
    power_assign: b"**=", // Infix, b"--*="

    root: b"-*", // Infix, b"-**"
    root_assign: b"-*=", // Infix, b"-**="
    multiply: b'*', // Infix
    multiply_assign: b"*=", // Infix
    divide: b'/', // Infix
    divide_assign: b"/=",// Infix
    add: b'+', // Infix, b"--",
    add_assign: b"+=", // Infix
    subtract: b'-', // Infix, b"-+"
    subtract_assign: b"-=",// Infix
    modulo: b'%', // Infix
    modulo_assign: b"%=", // Infix
    matrix_multiply: b'@', // Infix
    matrix_multiply_assign: b"@=", // Infix
    floor_divide: b"\\", // Infix
    floor_divide_assign: b"\\=", // Infix
    decrement: b"--", // Prefix and Postfix
    increment: b"++", // Prefix and Postfix
    absolute_value: b"+-", // Prefix

    // Logical operators
    logical_and: b"&&", // Infix
    logical_or: b"||", // Infix
    logical_nand: b"!&",// Infix
    logical_nor: b"!|",// Infix
    assign: b'=',// Infix
    equal_to: b"==",// Infix
    equal_to_location: b"===",// Infix

    not: b'!', // Infix
    not_equal_to: b"!=",// Infix
    not_equal_to_location: b"!==",// Infix
    implies: b"=>",// Infix
    converse: b"<=",// Infix
    subjunctor: b"->",// Infix 
    no : b"<-",// Infix
    iff : b"<=>",// Infix

    less_than: b'<', // Infix, b"!>", !<=! exclusive
    greater_than: b'>', // Infix, b"!<" !>=! exclusive
    less_than_or_equal_to: b"<=", //Infix,  b"!>=", inclusive
    greater_than_or_equal_to: b">=", // Infix, b"!<=" inclusive



    // Range operators
    exclusive_range: b"..", // Infix
    inclusive_range: b"..=", // Infix

    // Spread operators
    spread: b"...", // Prefix and Postfix

    // Implication operators, used in function definitions


    // Access operators
    static_resolution: b"::", // Infix
    instance_resolution: b'.',// Infix

    // Ignores a code branch
    pass: b"...",

    operators_1: nullable!() | instance_resolution!() | not!() | assign!() | less_than!() | greater_than!() | bitwise_and!() | bitwise_or!() | add!() | subtract!() | multiply!() | divide!() | modulo!() | bitwise_xor!() | matrix_multiply!() | safe_propagation!() | bitwise_not!(),
    operators_2: equal_to!() | not_equal_to!() | less_than_or_equal_to!() | greater_than_or_equal_to!() | floor_divide!() | power!() | exclusive_range!() | left_shift!() | right_shift!() | add_assign!() | subtract_assign!() | multiply_assign!() | divide_assign!() | modulus_assign!() | bitwise_and_assign!() | bitwise_or_assign!() | bitwise_xor_assign!() | lambda!() | matrix_multiply_assign!() | implies_left!() | implies_right!() | logical_and!() | decrement!() | logical_or!() | increment!() | nullish_coalescing!() | conditional!() | static_resolution!(),
    operators_3: not_equal_to_location!() | equal_to_location!() | pass!() | floor_divide_assign!() | power_assign!() | left_shift_assign!() | right_shift_assign!() | inclusive_range!(),

    // Numeric
    rational_number_separator: b':', // Infix

    // Floating point
    float_exponent: b'e'|b'E',
    decimal_point: b'.',


    uppercase: b'A'..=b'Z',
    lowercase: b'a'..=b'z',
    numeric: b'0'..=b'9',
    numeric_separator: b'_',

    alpha: lowercase!() | uppercase!(),

    alphanumeric: alpha!() | numeric!(),

    identifier_start: alpha!() | b'_',

    identifier_end: identifier_start!() | numeric!(),



    punctuation: b'!'..=b'/'|b':'..=b'@'|b'['..=b'`'|b'{'..=b'~',

    operators: operator_1!() | operator_2!() | operator_3!()

}

// convert th fns to a branched macro
macro_rules! discr {
    ($ty:expr, $c:expr) => {
        ($ty as u32) | ($c as u32) << 16
    };
    {2, $ty:expr, $c:expr} => {
    ($ty as u32) | unsafe { $c.as_bytes().as_ptr().cast::<u16>().read() as u32}   << 16
    };
    {3, $ty:expr, $c:expr} => {
    ($ty as u32) | unsafe { $c.as_bytes().as_ptr().cast::<u16>().read() } << 16 | unsafe { $c.as_bytes().as_ptr().add(2).cast::<u8>().read() as u32}
    };
    // Self::Assign as u32 | ('=' as u32) << 16, this is combine mode and it takes in a char and a u32 to shift by

    {combine_2, $ty:expr, $c:expr} => {
        ($ty as u32) | ($c as u32) << 16
    };
}

// todo make it so what ever impls int can be used as a repr
#[repr(u32)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum TokenType {
    Identifier = 0x01 << 24,
    Delimiter = 0x03 << 24,
    // use a bit mask to determine the type of delimiter on the determinate
    CurlyOpen = discr!(Self::Delimiter, '{'),
    CurlyClose = discr!(Self::Delimiter, '}'),
    ParenOpen = discr!(Self::Delimiter, '('),
    ParenClose = discr!(Self::Delimiter, ')'),
    SquareOpen = discr!(Self::Delimiter, '['),
    SquareClose = discr!(Self::Delimiter, ']'),
    AngleOpen = discr!(Self::Delimiter, '<'),
    AngleClose = discr!(Self::Delimiter, '>'),
    FloatLiteral = 0x07 << 24,

    Operator = 0x04 << 24,

    // operators_1: b'?' | b'!' | b'='| b'<'|b'>'|b'&'| b'|' | b'+'|b'-'|b'*'|b'/'|b'%'|b'^'|b'@',
    OptionalOrErrorable = discr!(Self::Operator, '?'),
    Not = discr!(Self::Operator, '!'),
    Assign = discr!(Self::Operator, '='),
    LessThan = discr!(Self::Operator, '<'),
    GreaterThan = discr!(Self::Operator, '>'),
    BitwiseAnd = discr!(Self::Operator, '&'),
    BitwiseOr = discr!(Self::Operator, '|'),
    Add = discr!(Self::Operator, '+'),
    Subtract = discr!(Self::Operator, '-'),
    Multiply = discr!(Self::Operator, '*'),
    Divide = discr!(Self::Operator, '/'),
    Modulus = discr!(Self::Operator, '%'),
    BitwiseXor = discr!(Self::Operator, '^'),
    MatrixMultiply = discr!(Self::Operator, '@'),

    // operators_2: b"==" | b"!=" | b"<=" | b">=" | b"//" | b"**" |b".."|
    // b"<<" | b">>" | b"+=" | b"-=" | b"*=" | b"/=" | b"%=" | b"&=" | b"|=" | b"^=" |
    // b"=>" | b"@=" | b"->" | b"<-" | b"<=" | b">=" | b"&&" | b"--" |
    // b"||" | b"++" | b"?="|b"|:" | b"??" | b"::" |"()",
    //EqualTo = Self::Assign as u32 | (Self::Assign as *const u16) << 16,

    // NotEqualTo = Self::Assign as u32 | (Self::Not as u32) << 16,
    Literal = 0x02 << 24,
    Keyword = 0x05 << 24,
    Comment = 0x06 << 24,

    Whitespace,
    Newline,
    ScopeSeparator,
    TypeSeparator,
    InstanceAccess,
    ListSeparator,
    StaticAccess,
    EmptyCall,
    Unknown,
    CharLiteral = char_quotes!(raw "") as u32,
    StringLiteral = string_quotes!(raw "") as u32,
    NumericLiteral,
}

impl<'cxx> Token<'cxx> {
    //const TOKEN_ORDERING: Ordering = Ordering::Relaxed;
    // FIXME: this was unused
    pub fn new(chars: &'cxx [u8], row: isize, column: usize, ty: TokenType) -> Self {
        Token {
            //file,
            sub_tokens: chars,
            column,
            row,
            ty,
        }
    }

    #[inline(always)]
    pub fn as_str(&self) -> &'cxx str {
        // Safe as we only have valid utf8 tokens
        unsafe { std::str::from_utf8_unchecked(self.sub_tokens) }
    }

    #[inline(always)]
    pub fn as_slice(&self) -> &'cxx [u8] {
        self.sub_tokens
    }

    pub fn row(&self) -> isize {
        self.row
    }

    pub fn column(&self) -> usize {
        self.column
    }

    pub fn len(&self) -> usize {
        self.sub_tokens.len()
    }

    pub fn extend(&mut self, other: Token<'cxx>) {
        self.sub_tokens = unsafe {
            &*slice_from_raw_parts(
                self.sub_tokens.as_ptr(),
                self.sub_tokens.len() + other.sub_tokens.len(),
            )
        };
    }
}

#[derive(Debug, Clone)]
pub struct Tokenizer<'cxx> {
    sub_tokens: &'cxx [u8],
    sub_tokens_start: *const u8,
    sub_tokens_end: *const u8,

    // The window head is the start of the current token
    head: *const u8,
    tail: *const u8,
    incomplete: bool,
    row: isize,

    last_row_index: usize,
    current_type: TokenType,
}



#[allow(dead_code)]
impl<'cxx> Tokenizer<'cxx> {
    pub const FIRST_ROW: isize = -1;
    pub const DEFAULT_CHAR: u8 = 0;

    pub fn new(chars: &'cxx [u8], starting_row: isize) -> Self {
        Tokenizer {
            sub_tokens: chars,
            sub_tokens_start: chars.as_ptr(),
            sub_tokens_end: unsafe { chars.as_ptr().add(chars.len()) },
            head: chars.as_ptr(),
            tail: chars.as_ptr(),
            row: starting_row,
            incomplete: false,
            last_row_index: 0,
            current_type: TokenType::Unknown,
        }
    }

    /// Allows the tokenizer to be reset with new content without reallocation,
    pub fn reset(&mut self, content: &'cxx [u8], starting_row: isize) {
        self.sub_tokens = content;
        self.sub_tokens_start = self.sub_tokens.as_ptr();
        self.sub_tokens_end = unsafe { self.sub_tokens.as_ptr().add(content.len()) };
        self.tail = content.as_ptr();
        self.head = content.as_ptr();
        self.row = starting_row;
        self.incomplete = false;
        self.last_row_index = 0;
    }

    /// A dirty estimate of the number of tokens in the content
    pub fn fast_estimate_number_of_tokens(&self) -> usize {
        let mut count = 0;
        let mut in_string = false;
        let mut prev_char = b'\0';

        for c in self.sub_tokens.iter() {
            match c {
                quotes!() if in_string & (prev_char != backslash!(raw "")) => {
                    // Handle string closure and escape character
                    in_string = false;
                }
                quotes!() => {
                    // Handle string opening
                    in_string = true;
                    count += 1; // Count the entire string as one token
                }
                alphanumeric!() | punctuation!() => count += 1,
                _ => {}
            }
            prev_char = *c;
        }
        count
    }
    
    /// Increments the row by one
    #[inline(always)]
    pub fn increment_row(&mut self) {
        // Simplified from:
        self.last_row_index = self.window_head_index() - self.len();
        self.row += 1;
    }

    // There might be a trait for this.
    pub fn gather_all_tokens(&mut self) -> Vec<Token> {
        let mut tokens = Vec::with_capacity(self.fast_estimate_number_of_tokens());

        while !self.is_empty() {
            tokens.push(self.next_token());
        }

        tokens
    }



    /// Creates a new token from the current window
    #[inline(always)]
    fn create_next_token(&mut self) -> Token<'cxx> {
        //dbg!((self.window_head_index(), self.last_row_index));

        let token = Token::new(
            self.window(),
            self.row,
            self.window_head_index() - self.last_row_index,
            self.current_type,
        );

        self.window_head_reset();
        token
    }

    fn next_token(&mut self) -> Token<'cxx> {
        self.current_type = TokenType::Unknown;
        'outer: loop {
            match self.window_tail::<u8>() {
                whitespace @ whitespace!() => { // Whitespace
                    self.skip_sub_token();
                    if whitespace == newline!(raw "") {
                        self.increment_row();
                    }
                }

                // Operators
                operators_3!(first_char) // Three character operators
                    if self.is_window_in_bounds(3)
                        && operators_3!(contains self.window_tail_slice(3)) =>
                {
                    break self.increment_tail_window_n(2);
                }
                operators_2!(first_char) // Two character operators
                    if self.is_window_in_bounds(2)
                        && operators_2!(contains u16 self.window_tail::<u16>() ) =>
                {
                    break self.increment_tail_window_n(1);
                }
                delimiters!()  // Delimiters and one len ops
                | operators_1!()
                | scope_separator!()
                | type_separator!()
                | instance_resolution!()
                | list_separator!() => {
                    if !self.is_window_empty() {
                        self.increment_tail()
                    }
                    break;
                }
                quote @ quotes!() => { // Start of quotes
                    while !self.is_empty() {
                        self.increment_tail();
                        match self.window_tail::<u8>() {
                            newline!() => {
                                self.increment_row();
                                // Temp fix for newlines in strings
                                // as this fixes the column calculation
                                self.last_row_index -= 2;
                            }
                            backslash!()
                                if self.is_window_in_bounds(1)
                                    && self.peek_ahead_window() == quote =>
                            {
                                self.increment_tail()
                            }
                            char if char == quote => break 'outer,
                            _ => {}
                        }
                    }
                    self.incomplete = true;
                    return self.create_next_token();
                } // End of quotes

                identifier_start!() => { // Start of identifier
                    // Check if it matches the start of an identifier
                    self.current_type = TokenType::Identifier;
                    while !self.is_empty() {
                        self.increment_tail();
                        match self.window_tail::<u8>() {
                            identifier_end!() if self.is_window_in_bounds(1) => {
                                self.increment_tail()
                            }
                            _ => break 'outer,
                        }
                    }
                } // End of identifier

                /*case numeric_tokens: // Numeric Literals -----------------------
                this->SetTokenType(Token_E::IntegerLiteral);
            number: // Parse the rest of the number
                switch (this->SetCurrentPushBack<Token_E>()) {
                    case Token_E::DotAccess: // Check for decimal point and set type to float if not already a float
                        if (this->currentType == Token_E::FloatLiteral) {
                            this->SetTokenType(Token_E::Invalid); // If there is another dot then it is invalid
                            goto increment_and_return;
                        }
                        this->SetTokenType(Token_E::FloatLiteral);
                    case numeric_tokens:
                    case Token_E::Underscore: // A numeric separator
                        if (this->m_subTokens.IsSubViewInBounds(m_window))
                            goto number;
                    default:
                        goto return_token;
                };
 */

                numeric!() => {
                    self.current_type = TokenType::NumericLiteral;
                    while !self.is_empty() {
                        self.increment_tail();
                        match self.window_tail::<u8>() {
                            
                            decimal_point!() if self.current_type == TokenType::FloatLiteral => {
                                self.current_type = TokenType::Unknown; // TODO: THROW ERROR
                                break 'outer;
                            },

                            // TODO: IEEE 754
                            // float_exponent!() => {
                            //     self.current_type = TokenType::FloatLiteral;
                            //     while !self.is_empty() {
                            //         self.increment_tail();
                            //         match self.window_tail::<u8>() {
                            //             numeric!() => {


                            //             }
                            //             _ => break 'outer,
                            //         }
                            //     }
                            // }

                            decimal_point!() => {
                                self.current_type = TokenType::FloatLiteral;
                            }

                            numeric_separator!() if self.is_window_in_bounds(1) => {
                                self.increment_tail()
                            }
                            _ => break 'outer,
                        }
                    }
                }




                // Characters
                _ => match self.peek_ahead_window() {
                    quotes!() if quote_prefixes!(contains self.peek_behind_tail()) => {
                        self.increment_tail()
                    },
                    whitespace!()
                    | delimiters!()
                    // TODO: add this back when it is fixed --- operators!(first_char)
                    | operators_1!(first_char) // TODO: Remove when fixed
                    | operators_2!(first_char) // TODO: Remove when fixed
                    | operators_3!(first_char) // TODO: Remove when fixed
                    | scope_separator!()
                    | type_separator!()
                    | instance_resolution!()
                    | list_separator!()  => break,

                    _ => self.increment_tail(),
                },
            }
        }
        self.increment_tail();

        self.create_next_token()
    }
}

#[cfg(test)]
mod tests {
    use std::{hint::black_box, slice::Iter};

    use super::*;

    #[test]
    fn test_determine_tokens_small() {
        use crate::tests::tokenizer::small_test::{CONTENT, EXPECTED};

        determine_tokens(CONTENT, EXPECTED.into_iter());
    }

    #[test]
    fn test_determine_tokens_large() {
        use crate::tests::tokenizer::large_test::{CONTENT, EXPECTED};

        determine_tokens(CONTENT, EXPECTED.into_iter());
    }

    fn determine_tokens<'a>(content: &'a str, mut expected: Iter<'a, &'a str>) {
        let mut tokenizer = Tokenizer::new(black_box(content.as_bytes()), Tokenizer::FIRST_ROW);

        let mut instant = crate::PrimedInstant::new();

        instant.prime();

        while !tokenizer.is_empty() {
            let start = std::time::Instant::now();
            let token = tokenizer.next_token();
            let end = start.elapsed();
            println!(
                "\nr:{} c:{} t:'{}' e:{:?} {}",
                token.row,
                token.column,
                token.as_str(),
                end,
                if tokenizer.incomplete {
                    "incomplete"
                } else {
                    ""
                }
            );

            assert_eq!(
                token.as_str().to_owned(),
                expected.next().unwrap().to_owned()
            );
        }

        tokenizer = Tokenizer::new(content.as_bytes(), Tokenizer::FIRST_ROW);

        let start = std::time::Instant::now();

        tokenizer.reset(content.as_bytes(), Tokenizer::FIRST_ROW);

        let tokens = tokenizer.gather_all_tokens();

        let elapsed = start.elapsed();

        //println!("Tokens: {:?}", tokens);
        println!("Total Time to gather: {:?}", elapsed);
    }
}

// enum ASTNode<'a> {
//     Root(Vec<ASTNode<'a>>),
//     Delimiter(Vec<ASTNode<'a>>),
//     Token(Token<'a>),
// }
// impl<'a> ASTNode<'a> {
//     pub fn add_node(&mut self, node: ASTNode) {
//         match self {
//             ASTNode::Root(nodes) => nodes.push(node),
//             ASTNode::Delimiter(nodes) => nodes.push(node),
//             ASTNode::Token(_) => panic!("Cannot add node to token"),
//         }
//     }
// }

// impl<'a> From<Vec<Token<'a>>> for ASTNode<'a> {
//     fn from(tokens: Vec<Token<'a>>) -> Self {
//         let mut nodes = Vec::new();
//         let mut iter = tokens.into_iter();

//         while let Some(token) = iter.next() {
//             match token.as_str() {
//                 // opening
//                 delim @ ("{" | "(" | "[" | "<") => {
//                     ...
//                 }

//                 _ => nodes.push(ASTNode::Root(vec![token])),
//             }
//         }

//         ASTNode::Root(nodes)
//     }
// }
