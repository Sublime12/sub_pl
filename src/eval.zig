const std = @import("std");
const builtin = @import("builtin");

const expression_pkg = @import("expression.zig");
const stdlib_pkg = @import("stdlib.zig");
const lexer_pkg = @import("lexer.zig");
const parser_pkg = @import("parser.zig");
const sema_pkg = @import("sema.zig");

const Parser = parser_pkg.Parser;
const Lexer = lexer_pkg.Lexer;
const expect = std.testing.expectEqual;
const expectStrings = std.testing.expectEqualStrings;

const Allocator = std.mem.Allocator;

const Expr = expression_pkg.Expr;
const StructInstanceExpr = expression_pkg.StructInstanceExpr;

// Re-export sema symbols for backward compatibility
pub const sema = sema_pkg.sema;
pub const build_context = sema_pkg.build_context;
pub const Context = sema_pkg.Context;
pub const Funs = sema_pkg.Funs;
pub const Structs = sema_pkg.Structs;
pub const assert_of_type = sema_pkg.assert_of_type;

// Evaluator sub-engines
pub const iterative = @import("iterative_eval.zig");
pub const recursive = @import("recursive_eval.zig");

pub const EvalMode = enum {
    iterative,
    recursive,
};

pub const VarTag = enum {
    int,
    float,
    bool_,
    str,
    struct_instance,
    void_,
};

pub const Var = union(VarTag) {
    const Self = @This();
    int: i32,
    float: f32,
    bool_: bool,
    str: []const u8,
    struct_instance: StructInstanceExpr,
    void_: void,

    pub fn tag(self: Self) VarTag {
        return @as(VarTag, self);
    }
};

pub const Vars = std.StringHashMap(Var);

/// Evaluates expr using the default (iterative) engine.
pub fn eval(expr: Expr, ctx: Context, local_vars: *Vars) Expr {
    return eval_with_mode(expr, ctx, local_vars, .iterative);
}

/// Evaluates expr using either the iterative or recursive engine.
pub fn eval_with_mode(expr: Expr, ctx: Context, local_vars: *Vars, mode: EvalMode) Expr {
    return switch (mode) {
        .iterative => iterative.eval(expr, ctx, local_vars),
        .recursive => recursive.eval(expr, ctx, local_vars),
    };
}

fn arena_alloc() std.heap.ArenaAllocator {
    return std.heap.ArenaAllocator.init(std.testing.allocator);
}

pub fn eval_source_mode(alloc: Allocator, source: []const u8, mode: EvalMode) !Expr {
    var lexer = Lexer.init(source, "test.sub");
    var parser = Parser.init(&lexer, alloc);
    const expr = try parser.parse();
    const io: std.Io = if (builtin.is_test) std.testing.io else undefined;
    const ctx = try build_context(expr, alloc, source, "test.sub", io);
    sema(expr, ctx);
    var local_vars: Vars = .init(alloc);
    defer local_vars.deinit();
    return eval_with_mode(expr, ctx, &local_vars, mode);
}

pub fn eval_source(alloc: Allocator, source: []const u8) !Expr {
    return eval_source_mode(alloc, source, .iterative);
}

test "eval int arithmetic with precedence and parentheses" {
    for ([_]EvalMode{ .iterative, .recursive }) |mode| {
        var arena = arena_alloc();
        defer arena.deinit();
        const alloc = arena.allocator();

        const res1 = try eval_source_mode(alloc, "10 + (20 * 3) - 5;", mode);
        try expect(.arith, res1.tag());
        try expect(65, res1.as.arith.int);

        const res2 = try eval_source_mode(alloc, "(10 + 20) * (3 - 1);", mode);
        try expect(.arith, res2.tag());
        try expect(60, res2.as.arith.int);

        // sub_pl parses sequentially left-to-right without operator precedence
        const res3 = try eval_source_mode(alloc, "10 + 20 * 3 - 5;", mode);
        try expect(.arith, res3.tag());
        try expect(85, res3.as.arith.int);
    }
}

test "eval integer division" {
    for ([_]EvalMode{ .iterative, .recursive }) |mode| {
        var arena = arena_alloc();
        defer arena.deinit();
        const alloc = arena.allocator();

        const res = try eval_source_mode(alloc, "100 / 4 / 5;", mode);
        try expect(.arith, res.tag());
        try expect(5, res.as.arith.int);
    }
}

test "eval float arithmetic" {
    for ([_]EvalMode{ .iterative, .recursive }) |mode| {
        var arena = arena_alloc();
        defer arena.deinit();
        const alloc = arena.allocator();

        const res = try eval_source_mode(alloc, "12.5 + (2.5 * 2.0);", mode);
        try expect(.arith, res.tag());
        try expect(17.5, res.as.arith.float);
    }
}

test "eval equality and relational operators" {
    for ([_]EvalMode{ .iterative, .recursive }) |mode| {
        var arena = arena_alloc();
        defer arena.deinit();
        const alloc = arena.allocator();

        const res1 = try eval_source_mode(alloc, "10 == 10;", mode);
        try expect(true, res1.as.bool_.constant);

        const res2 = try eval_source_mode(alloc, "10 == 20;", mode);
        try expect(false, res2.as.bool_.constant);

        const res3 = try eval_source_mode(alloc, "5 < 10;", mode);
        try expect(true, res3.as.bool_.constant);

        const res4 = try eval_source_mode(alloc, "10 <= 10;", mode);
        try expect(true, res4.as.bool_.constant);

        const res5 = try eval_source_mode(alloc, "20 > 5;", mode);
        try expect(true, res5.as.bool_.constant);

        const res6 = try eval_source_mode(alloc, "5 >= 6;", mode);
        try expect(false, res6.as.bool_.constant);
    }
}

test "eval logical and / or" {
    for ([_]EvalMode{ .iterative, .recursive }) |mode| {
        var arena = arena_alloc();
        defer arena.deinit();
        const alloc = arena.allocator();

        const res1 = try eval_source_mode(alloc, "(10 > 5) and (2 == 2);", mode);
        try expect(true, res1.as.bool_.constant);

        const res2 = try eval_source_mode(alloc, "(1 == 2) or (3 == 3);", mode);
        try expect(true, res2.as.bool_.constant);

        const res3 = try eval_source_mode(alloc, "(1 == 2) and (3 == 3);", mode);
        try expect(false, res3.as.bool_.constant);

        const res4 = try eval_source_mode(alloc, "(1 == 2) or (3 == 4);", mode);
        try expect(false, res4.as.bool_.constant);
    }
}

test "eval if-then-else and elseif branches" {
    for ([_]EvalMode{ .iterative, .recursive }) |mode| {
        var arena = arena_alloc();
        defer arena.deinit();
        const alloc = arena.allocator();

        const res1 = try eval_source_mode(alloc, "if 10 > 5 then 100 else 200;", mode);
        try expect(100, res1.as.arith.int);

        const res2 = try eval_source_mode(alloc, "if 5 > 10 then 100 else 200;", mode);
        try expect(200, res2.as.arith.int);

        const res3 = try eval_source_mode(alloc, "bind x = 2 in if x == 1 then 10 elseif x == 2 then 20 else 30;", mode);
        try expect(20, res3.as.arith.int);

        const res4 = try eval_source_mode(alloc, "10 + (if 1 == 1 then 5 else 0);", mode);
        try expect(15, res4.as.arith.int);
    }
}

test "eval variable binding and sequential scopes" {
    for ([_]EvalMode{ .iterative, .recursive }) |mode| {
        var arena = arena_alloc();
        defer arena.deinit();
        const alloc = arena.allocator();

        const res1 = try eval_source_mode(alloc, "bind a = 15 in a * 2;", mode);
        try expect(30, res1.as.arith.int);

        const res2 = try eval_source_mode(alloc, "bind a = 10 in bind b = a * 2 in a + b;", mode);
        try expect(30, res2.as.arith.int);

        const res3 = try eval_source_mode(alloc, "bind a = 1 in bind b = 2 in bind c = 3 in a + b + c;", mode);
        try expect(6, res3.as.arith.int);
    }
}

test "eval multi-arg function definition and call" {
    for ([_]EvalMode{ .iterative, .recursive }) |mode| {
        var arena = arena_alloc();
        defer arena.deinit();
        const alloc = arena.allocator();

        const res1 = try eval_source_mode(alloc, "let add3 = fn a b c -> a + b + c; add3(1, 2, 3,);", mode);
        try expect(6, res1.as.arith.int);

        const res2 = try eval_source_mode(alloc, "let double = fn x -> x * 2; let inc = fn x -> x + 1; double(inc(5,),);", mode);
        try expect(12, res2.as.arith.int);
    }
}

test "eval recursive function factorial and fibonacci" {
    for ([_]EvalMode{ .iterative, .recursive }) |mode| {
        var arena = arena_alloc();
        defer arena.deinit();
        const alloc = arena.allocator();

        const res1 = try eval_source_mode(alloc, "let fact = fn n -> if n == 1 then 1 else n * fact(n - 1,); fact(5,);", mode);
        try expect(120, res1.as.arith.int);

        const res2 = try eval_source_mode(alloc, "let fib = fn n -> if n <= 1 then n else fib(n - 1,) + fib(n - 2,); fib(7,);", mode);
        try expect(13, res2.as.arith.int);
    }
}

test "eval struct instantiation and field access" {
    for ([_]EvalMode{ .iterative, .recursive }) |mode| {
        var arena = arena_alloc();
        defer arena.deinit();
        const alloc = arena.allocator();

        const source =
            \\ struct Point { x, y, };
            \\ bind p = @Point{ .x = 10, .y = 20, } in p.x + (p.y);
        ;
        const res = try eval_source_mode(alloc, source, mode);
        try expect(30, res.as.arith.int);
    }
}

test "eval struct as function parameter and return value" {
    for ([_]EvalMode{ .iterative, .recursive }) |mode| {
        var arena = arena_alloc();
        defer arena.deinit();
        const alloc = arena.allocator();

        const source1 =
            \\ struct Point { x, y, };
            \\ let get_x = fn pt -> pt.x;
            \\ get_x(@Point{ .x = 42, .y = 0, },);
        ;
        const res1 = try eval_source_mode(alloc, source1, mode);
        try expect(42, res1.as.arith.int);

        const source2 =
            \\ struct Point { x, y, };
            \\ let make_pt = fn x y -> @Point{ .x = x, .y = y, };
            \\ bind p = make_pt(3, 4,) in p.x;
        ;
        const res2 = try eval_source_mode(alloc, source2, mode);
        try expect(3, res2.as.arith.int);
    }
}

test "eval stdlib functions len, getc, slice, parse_int" {
    for ([_]EvalMode{ .iterative, .recursive }) |mode| {
        var arena = arena_alloc();
        defer arena.deinit();
        const alloc = arena.allocator();

        const res1 = try eval_source_mode(alloc, "len(\"hello world\",);", mode);
        try expect(11, res1.as.arith.int);

        const res2 = try eval_source_mode(alloc, "getc(\"ABC\", 1,);", mode);
        try expect(66, res2.as.arith.int);

        const res3 = try eval_source_mode(alloc, "slice(\"abcdef\", 1, 4,);", mode);
        try expectStrings("bcd", res3.as.str);

        const res4 = try eval_source_mode(alloc, "parse_int(\"1234\",) + 6;", mode);
        try expect(1240, res4.as.arith.int);
    }
}

test "eval deep recursion without stack overflow" {
    var arena = arena_alloc();
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\ let count = fn n -> if n <= 0 then 0 else count(n - 1,);
        \\ count(10000,);
    ;
    // Iterative engine can handle 10,000 recursive calls without stack overflow
    const res = try eval_source_mode(alloc, source, .iterative);
    try expect(0, res.as.arith.int);
}
