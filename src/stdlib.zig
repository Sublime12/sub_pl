/// Standard lib of the language
const std = @import("std");

const expression_pkg = @import("expression.zig");
const eval_pkg = @import("eval.zig");

const Allocator = std.mem.Allocator;

const Expr = expression_pkg.Expr;
const FnExpr = expression_pkg.FnExpr;
const Vars = eval_pkg.Vars;
const Funs = eval_pkg.Funs;
const FnCallCtx = expression_pkg.Context;

const assert = std.debug.assert;
const panic = std.debug.panic;

pub fn register_functions(alloc: Allocator, funs: *Funs) !void {
    {
        var print_args: std.ArrayList([]const u8) = .empty;
        try print_args.append(alloc, "c");
        const print_fn: FnExpr = .{
            .name = "print",
            .args = print_args,
            .body = .{ .fn_binding = .{ .fn_ = print } },
        };
        try funs.put(alloc, "print", print_fn);
    }
    {
        var print_int_args: std.ArrayList([]const u8) = .empty;
        try print_int_args.append(alloc, "c");
        const print_int_fn: FnExpr = .{
            .name = "print_int",
            .args = print_int_args,
            .body = .{ .fn_binding = .{ .fn_ = print_int } },
        };
        try funs.put(alloc, "print_int", print_int_fn);
    }
    {
        var print_float_args: std.ArrayList([]const u8) = .empty;
        try print_float_args.append(alloc, "c");
        const print_float_fn: FnExpr = .{
            .name = "print_float",
            .args = print_float_args,
            .body = .{ .fn_binding = .{ .fn_ = print_float } },
        };
        try funs.put(alloc, "print_float", print_float_fn);
    }
    {
        var print_str_args: std.ArrayList([]const u8) = .empty;
        try print_str_args.append(alloc, "str");
        const print_str_fn: FnExpr = .{
            .name = "print_str",
            .args = print_str_args,
            .body = .{ .fn_binding = .{ .fn_ = print_str } },
        };
        try funs.put(alloc, "print_str", print_str_fn);
    }
    {
        var getc_args: std.ArrayList([]const u8) = .empty;
        try getc_args.append(alloc, "str");
        try getc_args.append(alloc, "i");
        const getc_fn: FnExpr = .{
            .name = "getc",
            .args = getc_args,
            .body = .{ .fn_binding = .{ .fn_ = getc } },
        };
        try funs.put(alloc, "getc", getc_fn);
    }
    {
        var read_file_args: std.ArrayList([]const u8) = .empty;
        try read_file_args.append(alloc, "filepath");
        const read_file_fn: FnExpr = .{
            .name = "read_file",
            .args = read_file_args,
            .body = .{ .fn_binding = .{ .fn_ = read_file } },
        };
        try funs.put(alloc, "read_file", read_file_fn);
    }
    {
        var slice_args: std.ArrayList([]const u8) = .empty;
        try slice_args.append(alloc, "str");
        try slice_args.append(alloc, "begin");
        try slice_args.append(alloc, "end");
        const slice_fn: FnExpr = .{
            .name = "slice",
            .args = slice_args,
            .body = .{ .fn_binding = .{ .fn_ = slice } },
        };
        try funs.put(alloc, "slice", slice_fn);
    }
    // {
    //     var parse_int_args: std.ArrayList([]const u8) = .empty;
    //     try parse_int_args.append(alloc, "parse_int");
    //     const parse_int_fn: FnExpr = .{
    //         .name = "parse_int",
    //         .args = parse_int_args,
    //         .body = .{ .fn_binding = .{ .fn_ = parse_int } },
    //     };
    //     try funs.put(alloc, "parse_int", parse_int_fn);
    // }
}

fn print(vars: *Vars, ctx: FnCallCtx) Expr {
    assert(vars.count() == 1);
    assert(vars.contains("c"));
    const c = vars.get("c").?;
    assert(c.tag() == .int);

    print_ascii(c.int);
    return .{
        .as = .{ .void_ = {} },
        .cursor = ctx.cursor,
        .content = ctx.content,
        .file_path = ctx.file_path,
    };
}

fn print_int(vars: *Vars, ctx: FnCallCtx) Expr {
    assert(vars.count() == 1);
    assert(vars.contains("c"));
    const c = vars.get("c").?;

    assert(c.tag() == .int);
    std.debug.print("{}", .{c.int});
    return .{
        .as = .{ .void_ = {} },
        .cursor = ctx.cursor,
        .content = ctx.content,
        .file_path = ctx.file_path,
    };
}

fn print_float(vars: *Vars, ctx: FnCallCtx) Expr {
    assert(vars.count() == 1);
    assert(vars.contains("c"));
    const c = vars.get("c").?;

    assert(c.tag() == .float);
    std.debug.print("{}", .{c.float});
    return .{
        .as = .{ .void_ = {} },
        .cursor = ctx.cursor,
        .content = ctx.content,
        .file_path = ctx.file_path,
    };
}

fn slice(vars: *Vars, ctx: FnCallCtx) Expr {
    assert(vars.count() == 3);
    assert(vars.contains("str"));
    assert(vars.contains("begin"));
    assert(vars.contains("end"));

    const str = vars.get("str").?;
    assert(str.tag() == .str);
    const begin = vars.get("begin").?;
    assert(begin.tag() == .int);
    const end = vars.get("end").?;
    assert(end.tag() == .int);

    return .{
        .as = .{ .str = str.str[@intCast(begin.int)..@intCast(end.int)] },
        .content = ctx.content,
        .cursor = ctx.cursor,
        .file_path = ctx.file_path,
    };
}

fn print_str(vars: *Vars, ctx: FnCallCtx) Expr {
    assert(vars.count() == 1);
    assert(vars.contains("str"));
    const str = vars.get("str").?;

    assert(str.tag() == .str);
    std.debug.print("{s}", .{str.str});
    return .{
        .as = .{ .void_ = {} },
        .cursor = ctx.cursor,
        .content = ctx.content,
        .file_path = ctx.file_path,
    };
}

fn getc(vars: *Vars, ctx: FnCallCtx) Expr {
    assert(vars.count() == 2);

    assert(vars.contains("str"));
    const str = vars.get("str").?;
    assert(str.tag() == .str);

    assert(vars.contains("i"));
    const i = vars.get("i").?;
    assert(i.tag() == .int);

    assert(i.int < str.str.len);
    return .{
        .as = .{ .arith = .{ .int = str.str[@intCast(i.int)] } },
        .cursor = ctx.cursor,
        .content = ctx.content,
        .file_path = ctx.file_path,
    };
}

fn read_file(vars: *Vars, ctx: FnCallCtx) Expr {
    assert(vars.count() == 1);

    assert(vars.contains("filepath"));
    const filepath = vars.get("filepath").?;
    assert(filepath.tag() == .str);

    const file = std.Io.Dir.cwd().openFile(ctx.io, filepath.str, .{}) catch {
        panic("filepath {s} does not exist", .{filepath.str});
    };

    const MAX_SIZE = 1024 * 1024;

    var file_reader = file.reader(ctx.io, &.{});
    const content = file_reader.interface.allocRemaining(ctx.alloc, .limited(MAX_SIZE)) catch unreachable;

    return .{
        .as = .{ .str = content },
        .cursor = ctx.cursor,
        .content = ctx.content,
        .file_path = ctx.file_path,
    };
}

fn print_ascii(ascii: i32) void {
    assert(ascii < 128 and ascii >= 0);

    const c: u8 = @intCast(ascii);
    std.debug.print("{c}", .{c});
}
