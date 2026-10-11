const std = @import("std");
const builtin = @import("builtin");

const expression_pkg = @import("expression.zig");

const eql = std.ascii.eqlIgnoreCase;
const panic = std.debug.panic;
const print = std.debug.print;

const expectStrings = std.testing.expectEqualStrings;
const expectEqual = std.testing.expectEqual;

// A slice indexing where is the id
// in the content
const SliceId = struct {
    const Self = @This();
    pub const empty: Self = .{ .first = 0, .end = 0 };
    first: usize,
    end: usize,

    pub fn as_str(self: Self, content: []const u8) []const u8 {
        return content[self.first..self.end];
    }

    pub fn clear(self: *Self, pos: usize) void {
        self.first = pos;
        self.end = pos;
    }

    pub fn isEmpty(self: Self) bool {
        return self.first == self.end;
    }

    pub fn extend(self: *Self) void {
        self.end += 1;
    }
};

pub const Lexer = struct {
    file_path: []const u8,
    content: []const u8,
    token: TokenKind,
    tokenType: TokenType,
    integer_value: ?i32,
    float_value: ?f32,
    bool_value: ?bool,
    previous_cursor: Cursor,
    cursor: Cursor,
    name: SliceId,

    pub fn init(content: []const u8, file_path: []const u8) Lexer {
        return .{
            .file_path = file_path,
            .content = content,
            .token = .none,
            .cursor = .empty,
            .previous_cursor = .empty,
            .name = .empty,
            .integer_value = null,
            .float_value = null,
            .bool_value = null,
            .tokenType = .none,
        };
    }

    pub fn eat(l: *Lexer, token: TokenKind) void {
        l.expect(token);
        l.nexti();
    }

    fn current_line(l: *Lexer) []const u8 {
        var begin: usize = l.cursor.pos;
        var end: usize = l.cursor.pos;

        while (begin > 0 and l.content[begin] != '\n') begin -= 1;
        while (end < l.content.len and l.content[end] != '\n') end += 1;

        return l.content[begin..end];
    }

    pub fn expect(l: *Lexer, expected: TokenKind) void {
        const GREEN_TAG = "\x1b[32m";
        const RED_TAG = "\x1b[31m";
        const END_TAG = "\x1b[0m";
        if (l.token != expected) {
            const panic_line = l.current_line();
            std.debug.print("\n" ++ GREEN_TAG ++ "{s}:{}:{}" ++ END_TAG ++ " expected this `{s}`, found: `{s}` in line\n{s}\n", .{
                l.file_path,
                l.cursor.row + 1,
                l.cursor.col,
                expected.get_str(),
                l.name.as_str(l.content),
                panic_line,
            });

            for (0..l.cursor.col - 1) |_| {
                std.debug.print(" ", .{});
            }
            std.debug.print(RED_TAG ++ "^" ++ END_TAG ++ "\n", .{});

            if (builtin.mode != .Debug or false)
                std.process.exit(1)
            else
                panic("", .{});
        }
    }

    fn clear_append_symbol(l: *Lexer, x: u8) void {
        _ = x;
        // l.name.clearRetainingCapacity();
        // cursor.pos always return the position after the last
        // character that was processed
        l.name.clear(l.cursor.pos - 1);
        l.name.extend();
    }

    fn set_token(l: *Lexer, token: TokenKind) void {
        switch (token) {
            .minus, .prod, .div, .plus => |t| {
                l.token = t;
                l.tokenType = .arith_op;
            },
            .eql, .ge, .gt, .le, .lt, .and_, .or_ => |t| {
                l.token = t;
                l.tokenType = .bool_op;
            },
            .else_, .if_, .elseif, .struct_, .fn_, .then, .arrow, .let, .bind, .in => |t| {
                l.token = t;
                l.tokenType = .keyword;
            },
            .oparen, .cparen, .obrace, .cbrace => |t| {
                l.token = t;
                l.tokenType = .paren;
            },
            .assign, .comma, .dot, .semicolon, .none, .at, .end => |t| {
                l.token = t;
                l.tokenType = .other;
            },
            .id, .int, .float, .bool_, .str => |t| {
                l.token = t;
                l.tokenType = .primary;
            },
            // else => |t| panic("set_token not implemented for {}", .{t}),
        }
    }

    /// like next but ignore the output
    pub fn nexti(l: *Lexer) void {
        const found = l.next();
        _ = found;
        // std.debug.assert(found);
    }

    /// Return a new lexer with the token set
    /// to the element in source code
    pub fn nextl(l: Lexer) Lexer {
        var new_l = l;
        new_l.nexti();
        return new_l;
    }

    pub fn next(l: *Lexer) bool {
        l.previous_cursor = l.cursor;

        while (true) {
            l.trim_left();
            if (l.start_with_comment()) l.drop_line() else break;
        }

        const x_opt = l.next_char();
        if (x_opt == null) {
            l.token = .end;
            return true;
        }

        const x = x_opt.?;

        switch (x) {
            '=' => {
                l.clear_append_symbol(x);
                const n_char = l.current_char();
                if (n_char == '=') {
                    _ = l.next_char();
                    l.name.extend();
                    l.set_token(.eql);
                    return true;
                }
                l.set_token(.assign);
                return true;
            },
            '>' => {
                l.clear_append_symbol(x);
                const n_char = l.current_char();
                if (n_char == '=') {
                    _ = l.next_char();
                    l.name.extend();
                    l.set_token(.ge);
                    return true;
                }
                l.set_token(.gt);
                return true;
            },
            '<' => {
                l.clear_append_symbol(x);
                const n_char = l.current_char();
                if (n_char == '=') {
                    _ = l.next_char();
                    l.name.extend();
                    l.set_token(.le);
                    return true;
                }
                l.set_token(.lt);
                return true;
            },
            '-' => {
                l.clear_append_symbol(x);
                const n_char = l.current_char();
                if (n_char == '>') {
                    _ = l.next_char();
                    l.name.extend();
                    l.set_token(.arrow);
                    return true;
                }
                l.set_token(.minus);
                return true;
            },
            '(' => {
                l.clear_append_symbol(x);
                l.set_token(.oparen);
                return true;
            },
            ')' => {
                l.clear_append_symbol(x);
                l.set_token(.cparen);
                return true;
            },
            '{' => {
                l.clear_append_symbol(x);
                l.set_token(.obrace);
                return true;
            },
            '}' => {
                l.clear_append_symbol(x);
                l.set_token(.cbrace);
                return true;
            },
            '*' => {
                l.clear_append_symbol(x);
                l.set_token(.prod);
                return true;
            },
            '/' => {
                l.clear_append_symbol(x);
                l.set_token(.div);
                return true;
            },
            '+' => {
                l.clear_append_symbol(x);
                l.set_token(.plus);
                return true;
            },
            ',' => {
                l.clear_append_symbol(x);
                l.set_token(.comma);
                return true;
            },
            '.' => {
                l.clear_append_symbol(x);
                l.set_token(.dot);
                return true;
            },
            ';' => {
                l.clear_append_symbol(x);
                l.set_token(.semicolon);
                return true;
            },
            '@' => {
                l.clear_append_symbol(x);
                l.set_token(.at);
                return true;
            },
            '"' => {
                const nb = l.countDComma();
                l.name.clear(l.cursor.pos - 1);

                l.lexString(nb);
                l.set_token(.str);
                return true;
            },
            else => {},
        }

        if (isSymbol(x)) {
            l.clear_append_symbol(x);
            while (l.current_char()) |c| {
                if (!isSymbol(c)) break;
                l.name.extend();
                _ = l.next_char();
            }

            if (eql("let", l.name.as_str(l.content))) {
                l.set_token(.let);
                return true;
            } else if (eql("if", l.name.as_str(l.content))) {
                l.set_token(.if_);
                return true;
            } else if (eql("and", l.name.as_str(l.content))) {
                l.set_token(.and_);
                return true;
            } else if (eql("or", l.name.as_str(l.content))) {
                l.set_token(.or_);
                return true;
            } else if (eql("bind", l.name.as_str(l.content))) {
                l.set_token(.bind);
                return true;
            } else if (eql("in", l.name.as_str(l.content))) {
                l.set_token(.in);
                return true;
            } else if (eql("fn", l.name.as_str(l.content))) {
                l.set_token(.fn_);
                return true;
            } else if (eql("then", l.name.as_str(l.content))) {
                l.set_token(.then);
                return true;
            } else if (eql("else", l.name.as_str(l.content))) {
                l.set_token(.else_);
                return true;
            } else if (eql("elseif", l.name.as_str(l.content))) {
                l.set_token(.elseif);
                return true;
            } else if (eql("struct", l.name.as_str(l.content))) {
                l.set_token(.struct_);
                return true;
            } else if (eql("true", l.name.as_str(l.content))) {
                l.set_token(.bool_);
                l.bool_value = true;
                return true;
            } else if (eql("false", l.name.as_str(l.content))) {
                l.set_token(.bool_);
                l.bool_value = false;
                return true;
            } else if (std.ascii.isDigit(l.name.as_str(l.content)[0])) {
                if (l.cursor.pos < l.content.len and l.content[l.cursor.pos] == '.') {
                    l.name.extend();
                    _ = l.next_char();
                    while (l.current_char()) |c| {
                        if (!isSymbol(c)) break;
                        _ = l.next_char();
                        l.name.extend();
                    }

                    const number = std.fmt.parseFloat(f32, l.name.as_str(l.content)) catch {
                        panic("Expected float, found {s}", .{l.name.as_str(l.content)});
                    };
                    l.float_value = number;
                    l.set_token(.float);
                    return true;
                }
                const number = std.fmt.parseInt(i32, l.name.as_str(l.content), 10) catch {
                    panic("Expected number, found: {s}", .{l.name.as_str(l.content)});
                };
                l.integer_value = number;
                l.set_token(.int);
                return true;
            } else {
                l.set_token(.id);
                return true;
            }
        }
        return false;
    }

    fn isSymbol(x: u8) bool {
        return std.ascii.isAlphanumeric(x) or x == '_';
    }

    fn lexString(l: *Lexer, nb_delimiter: usize) void {
        const MAX_COMMA_STR = 15;
        loop: while (true) {
            const c = l.next_char() orelse break;
            if (c == '"') {
                var count: usize = 1;
                for (0..MAX_COMMA_STR) |_| {
                    const c2 = l.current_char();
                    if (c2 == '"') {
                        count += 1;
                        _ = l.next_char();
                    } else {
                        break;
                    }
                }
                if (count < nb_delimiter) {
                    // This is not the end of the string
                    // so we account the "" as in the string
                    for (0..count) |_| {
                        l.name.extend();
                    }
                } else {
                    const nb_extend = count - nb_delimiter + 1;
                    for (0..nb_extend) |_|
                        l.name.extend();
                    break :loop;
                }
            } else l.name.extend();
        }
    }

    fn countDComma(l: *Lexer) usize {
        var count: usize = 1;
        while (l.next_char()) |c| {
            if (c != '"') break;
            count += 1;
        }
        return count;
    }

    pub fn trim_left(l: *Lexer) void {
        while (std.ascii.isWhitespace(l.current_char() orelse return)) {
            _ = l.next_char();
        }
    }

    fn next_char(l: *Lexer) ?u8 {
        if (l.cursor.pos >= l.content.len) return null;

        const x = l.current_char().?;
        l.cursor.pos += 1;
        l.cursor.col += 1;

        if (is_ln(x)) {
            l.cursor.bol = l.cursor.pos;
            l.cursor.row += 1;
            l.cursor.col = 0;
        }
        return x;
    }

    fn current_char(l: *Lexer) ?u8 {
        if (l.cursor.pos >= l.content.len) return null;
        return l.content[l.cursor.pos];
    }

    fn peek_next_char(l: *Lexer) ?u8 {
        if (l.cursor.pos + 1 >= l.content.len) return null;
        return l.content[l.cursor.pos + 1];
    }

    fn drop_line(l: *Lexer) void {
        while (l.cursor.pos < l.content.len and l.next_char() != '\n') {}
    }

    fn start_with_comment(l: *Lexer) bool {
        return l.current_char() == '#';
    }

    fn is_ln(c: u8) bool {
        return c == '\n';
    }
};

const TokenKind = enum {
    const Self = @This();

    // Cmp ops
    eql,
    assign,
    gt,
    ge,
    lt,
    le,
    and_,
    or_,

    // Arith ops
    minus,
    plus,
    prod,
    div,

    // parentheses
    oparen,
    cparen,
    obrace,
    cbrace,

    // keywords
    arrow,
    fn_,
    if_,
    elseif,
    else_,
    let,
    struct_,
    then,
    bind,
    in,

    // primary
    int,
    float,
    bool_,
    id,
    str,

    // others
    comma,
    dot,
    semicolon,
    at,
    none,
    end,

    pub fn get_str(token: Self) []const u8 {
        return switch (token) {
            .eql => "==",
            .gt => ">",
            .ge => ">=",
            .lt => "<",
            .le => "<=",
            .and_ => "and",
            .or_ => "or",
            .assign => "=",
            .minus => "-",
            .plus => "+",
            .prod => "*",
            .div => "/",
            .oparen => "(",
            .cparen => ")",
            .obrace => "{",
            .cbrace => "}",
            .arrow => "->",
            .fn_ => "fn",
            .else_ => "else",
            .elseif => "elseif",
            .let => "let",
            .if_ => "if",
            .struct_ => "struct",
            .then => "then",
            .bind => "bind",
            .in => "in",
            .int => "int",
            .float => "float",
            .bool_ => "bool",
            .id => "identifier",
            .str => "str",
            .comma => ",",
            .dot => ".",
            .semicolon => ";",
            .at => "@",
            .none => "none",
            .end => "end",
        };
    }
};

const TokenType = enum {
    arith_op,
    bool_op,
    cmp_op,
    primary,
    paren,
    keyword,
    other,
    none,
};

pub const Cursor = struct {
    const Self = @This();

    // absolute position in str
    pos: usize,
    // beginning of the current line
    bol: usize,
    // what column the cursor is at
    col: usize,
    // what row the cursor is at (can also be (pos - bol)
    row: usize,

    pub const empty: Self = .{
        .pos = 0,
        .bol = 0,
        .col = 0,
        .row = 0,
    };
};

test "lex string" {
    const source_code =
        //       x                  x        x    x
        \\ """"""bon "abc" x"""""" "amis "
        \\ ""a""
        \\ # the lexer must ignore this line
        \\ "a\n"
    ;
    var l = Lexer.init(source_code, "test.zig");

    l.nexti();
    try expectStrings("bon \"abc\" x", l.name.as_str(l.content));
    l.nexti();
    try expectStrings("amis ", l.name.as_str(l.content));
    l.nexti();
    try expectStrings("a", l.name.as_str(l.content));
    l.nexti();
    try expectStrings("a\\n", l.name.as_str(l.content));

    l.nexti();
    try expectEqual(.end, l.token);
}

test "lex identifiers" {
    const source_code =
        \\ variable_name x123 _secret_id
    ;
    var l = Lexer.init(source_code, "test.zig");

    l.nexti();
    try expectStrings("variable_name", l.name.as_str(l.content));
    try expectEqual(.id, l.token);

    l.nexti();
    try expectStrings("x123", l.name.as_str(l.content));
    try expectEqual(.id, l.token);

    l.nexti();
    try expectStrings("_secret_id", l.name.as_str(l.content));
    try expectEqual(.id, l.token);

    l.nexti();
    try expectEqual(.end, l.token);
}

test "lex integers" {
    const source_code =
        \\ 123 0 4567
    ;
    var l = Lexer.init(source_code, "test.zig");

    l.nexti();
    try expectEqual(123, l.integer_value);
    try expectEqual(.int, l.token);

    l.nexti();
    try expectEqual(0, l.integer_value);
    try expectEqual(.int, l.token);

    l.nexti();
    try expectStrings("4567", l.name.as_str(l.content));
    try expectEqual(4567, l.integer_value);
    try expectEqual(.int, l.token);

    l.nexti();
    try expectEqual(.end, l.token);
}

test "lex floats" {
    const source_code =
        \\ 123.14 0.0 4567.35
    ;
    var l = Lexer.init(source_code, "test.zig");

    l.nexti();
    try expectEqual(123.14, l.float_value);
    try expectEqual(.float, l.token);

    l.nexti();
    try expectEqual(0.0, l.float_value);
    try expectEqual(.float, l.token);

    l.nexti();
    try expectStrings("4567.35", l.name.as_str(l.content));
    try expectEqual(4567.35, l.float_value);
    try expectEqual(.float, l.token);

    l.nexti();
    try expectEqual(.end, l.token);
}

test "lex booleans" {
    const source_code =
        \\ true false
    ;
    var l = Lexer.init(source_code, "test.zig");

    l.nexti();
    try expectEqual(true, l.bool_value);
    try expectEqual(.bool_, l.token);

    l.nexti();
    try expectEqual(false, l.bool_value);
    try expectEqual(.bool_, l.token);

    l.nexti();
    try expectEqual(.end, l.token);
}

test "lex if expression" {
    const source_code =
        \\ if 1 + 3 = 7 then
        \\ print_str("" hello "world" "",)
        \\ elseif true then bonjour
        \\ else double(7) ;
    ;
    var l = Lexer.init(source_code, "test.zig");

    l.nexti();
    try expectStrings("if", l.name.as_str(l.content));
    try expectEqual(.if_, l.token);

    l.nexti();
    try expectStrings("1", l.name.as_str(l.content));
    try expectEqual(1, l.integer_value);
    try expectEqual(.int, l.token);

    l.nexti();
    try expectStrings("+", l.name.as_str(l.content));
    try expectEqual(.plus, l.token);

    l.nexti();
    try expectStrings("3", l.name.as_str(l.content));
    try expectEqual(3, l.integer_value);
    try expectEqual(.int, l.token);

    l.nexti();
    try expectStrings("=", l.name.as_str(l.content));
    try expectEqual(.assign, l.token);

    l.nexti();
    try expectStrings("7", l.name.as_str(l.content));
    try expectEqual(7, l.integer_value);
    try expectEqual(.int, l.token);

    l.nexti();
    try expectStrings("then", l.name.as_str(l.content));
    try expectEqual(.then, l.token);

    l.nexti();
    try expectStrings("print_str", l.name.as_str(l.content));
    try expectEqual(.id, l.token);

    l.nexti();
    try expectStrings("(", l.name.as_str(l.content));
    try expectEqual(.oparen, l.token);

    l.nexti();
    try expectStrings(" hello \"world\" ", l.name.as_str(l.content));
    try expectEqual(.str, l.token);

    l.nexti();
    try expectStrings(",", l.name.as_str(l.content));
    try expectEqual(.comma, l.token);

    l.nexti();
    try expectStrings(")", l.name.as_str(l.content));
    try expectEqual(.cparen, l.token);

    l.nexti();
    try expectStrings("elseif", l.name.as_str(l.content));
    try expectEqual(.elseif, l.token);

    l.nexti();
    try expectStrings("true", l.name.as_str(l.content));
    try expectEqual(.bool_, l.token);

    l.nexti();
    try expectStrings("then", l.name.as_str(l.content));
    try expectEqual(.then, l.token);

    l.nexti();
    try expectStrings("bonjour", l.name.as_str(l.content));
    try expectEqual(.id, l.token);

    l.nexti();
    try expectStrings("else", l.name.as_str(l.content));
    try expectEqual(.else_, l.token);

    l.nexti();
    try expectStrings("double", l.name.as_str(l.content));
    try expectEqual(.id, l.token);

    l.nexti();
    try expectStrings("(", l.name.as_str(l.content));
    try expectEqual(.oparen, l.token);

    l.nexti();
    try expectStrings("7", l.name.as_str(l.content));
    try expectEqual(7, l.integer_value);
    try expectEqual(.int, l.token);

    l.nexti();
    try expectStrings(")", l.name.as_str(l.content));
    try expectEqual(.cparen, l.token);

    l.nexti();
    try expectStrings(";", l.name.as_str(l.content));
    try expectEqual(.semicolon, l.token);

    l.nexti();
    try expectEqual(.end, l.token);
}

test "lex bind and self_fn" {
    const source_code =
        \\ bind f = x;
    ;
    var l = Lexer.init(source_code, "test.zig");

    l.nexti();
    try expectStrings("bind", l.name.as_str(l.content));
    try expectEqual(.bind, l.token);

    l.nexti();
    try expectStrings("f", l.name.as_str(l.content));
    try expectEqual(.id, l.token);

    l.nexti();
    try expectStrings("=", l.name.as_str(l.content));
    try expectEqual(.assign, l.token);

    l.nexti();
    try expectStrings("x", l.name.as_str(l.content));
    try expectEqual(.id, l.token);
}

test "lex false and equality" {
    const source_code =
        \\ false == true
    ;
    var l = Lexer.init(source_code, "test.zig");

    l.nexti();
    try expectStrings("false", l.name.as_str(l.content));
    try expectEqual(false, l.bool_value);
    try expectEqual(.bool_, l.token);

    l.nexti();
    try expectStrings("==", l.name.as_str(l.content));
    try expectEqual(.eql, l.token);

    l.nexti();
    try expectStrings("true", l.name.as_str(l.content));
    try expectEqual(true, l.bool_value);
    try expectEqual(.bool_, l.token);
}

test "lex empty input and end token" {
    const source_code = "   ";
    var l = Lexer.init(source_code, "test.zig");

    l.nexti();
    try expectEqual(.end, l.token);
}

test "lex arithmetic operators and punctuation" {
    const source_code =
        \\ (1 + 2) * 3 - 4 / 25,
    ;
    var l = Lexer.init(source_code, "test.zig");

    l.nexti();
    try expectStrings("(", l.name.as_str(l.content));
    try expectEqual(.oparen, l.token);

    l.nexti();
    try expectEqual(1, l.integer_value);
    try expectEqual(.int, l.token);

    l.nexti();
    try expectStrings("+", l.name.as_str(l.content));
    try expectEqual(.plus, l.token);

    l.nexti();
    try expectEqual(2, l.integer_value);
    try expectEqual(.int, l.token);

    l.nexti();
    try expectStrings(")", l.name.as_str(l.content));
    try expectEqual(.cparen, l.token);

    l.nexti();
    try expectStrings("*", l.name.as_str(l.content));
    try expectEqual(.prod, l.token);

    l.nexti();
    try expectEqual(3, l.integer_value);
    try expectEqual(.int, l.token);

    l.nexti();
    try expectStrings("-", l.name.as_str(l.content));
    try expectEqual(.minus, l.token);

    l.nexti();
    try expectEqual(4, l.integer_value);
    try expectEqual(.int, l.token);

    l.nexti();
    try expectStrings("/", l.name.as_str(l.content));
    try expectEqual(.div, l.token);

    l.nexti();
    try expectStrings("25", l.name.as_str(l.content));
    try expectEqual(25, l.integer_value);
    try expectEqual(.int, l.token);

    l.nexti();
    try expectStrings(",", l.name.as_str(l.content));
    try expectEqual(.comma, l.token);

    l.nexti();
    try expectEqual(.end, l.token);
}

test "lex core keywords" {
    const source_code =
        \\ let fn if then else in bind @ . { } { struct @
    ;
    var l = Lexer.init(source_code, "test.zig");

    l.nexti();
    try expectStrings("let", l.name.as_str(l.content));
    try expectEqual(.let, l.token);

    l.nexti();
    try expectStrings("fn", l.name.as_str(l.content));
    try expectEqual(.fn_, l.token);

    l.nexti();
    try expectStrings("if", l.name.as_str(l.content));
    try expectEqual(.if_, l.token);

    l.nexti();
    try expectStrings("then", l.name.as_str(l.content));
    try expectEqual(.then, l.token);

    l.nexti();
    try expectStrings("else", l.name.as_str(l.content));
    try expectEqual(.else_, l.token);

    l.nexti();
    try expectStrings("in", l.name.as_str(l.content));
    try expectEqual(.in, l.token);

    l.nexti();
    try expectStrings("bind", l.name.as_str(l.content));
    try expectEqual(.bind, l.token);

    l.nexti();
    try expectStrings("@", l.name.as_str(l.content));
    try expectEqual(.at, l.token);

    l.nexti();
    try expectStrings(".", l.name.as_str(l.content));
    try expectEqual(.dot, l.token);

    l.nexti();
    try expectStrings("{", l.name.as_str(l.content));
    try expectEqual(.obrace, l.token);

    l.nexti();
    try expectStrings("}", l.name.as_str(l.content));
    try expectEqual(.cbrace, l.token);

    l.nexti();
    try expectStrings("{", l.name.as_str(l.content));
    try expectEqual(.obrace, l.token);

    l.nexti();
    try expectStrings("struct", l.name.as_str(l.content));
    try expectEqual(.struct_, l.token);

    l.nexti();
    try expectStrings("@", l.name.as_str(l.content));
    try expectEqual(.at, l.token);

    l.nexti();
    try expectEqual(.end, l.token);
}
