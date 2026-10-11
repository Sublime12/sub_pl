const std = @import("std");
const builtin = @import("builtin");

const expression_pkg = @import("expression.zig");
const stdlib_pkg = @import("stdlib.zig");
const lexer_pkg = @import("lexer.zig");
const parser_pkg = @import("parser.zig");

const Parser = parser_pkg.Parser;
const Lexer = lexer_pkg.Lexer;
const expect = std.testing.expectEqual;
const expectStrings = std.testing.expectEqualStrings;

const Allocator = std.mem.Allocator;

const Cursor = lexer_pkg.Cursor;
const Expr = expression_pkg.Expr;
const ExprTag = expression_pkg.ExprTag;
const BoolExpr = expression_pkg.BoolExpr;
const ArithExpr = expression_pkg.ArithExpr;
const IfExpr = expression_pkg.IfExpr;
const FnCallExpr = expression_pkg.FnCallExpr;
const FnExpr = expression_pkg.FnExpr;
const StructExpr = expression_pkg.StructExpr;
const StructInstanceExpr = expression_pkg.StructInstanceExpr;
const BindExpr = expression_pkg.BindExpr;

const panic = std.debug.panic;

const register_functions = stdlib_pkg.register_functions;

// Because functions are meant to be fun to use :)
pub const Funs = std.StringArrayHashMapUnmanaged(FnExpr);
const Structs = std.StringArrayHashMapUnmanaged(StructExpr);
const Context = struct {
    const Self = @This();

    funs: Funs,
    structs: Structs,
    alloc: Allocator,
    io: std.Io,
    content: []const u8,
    file_path: []const u8,

    pub fn print(self: Self) void {
        std.debug.print("defined structs: \n", .{});
        var it = self.structs.iterator();

        while (it.next()) |struct_| {
            std.debug.print("{s} -> ", .{struct_.key_ptr.*});
            struct_.value_ptr.print();
            std.debug.print("\n", .{});
        }
    }
};

pub fn sema(program: Expr, ctx: Context) void {
    switch (program.as) {
        // base case
        .struct_instance => |struct_inst| {
            const struct_ = ctx.structs.get(struct_inst.name) orelse {
                panic("tried getting struct {s} but not defined\n", .{struct_inst.name});
            };

            var inst_fields = struct_inst.fields.iterator();
            while (inst_fields.next()) |inst_field| {
                if (!contains(inst_field.key_ptr.*, struct_.fields)) {
                    panic(
                        "struct instance contains field {s} but not defined in {s}",
                        .{ inst_field.key_ptr.*, struct_.name },
                    );
                }
            }
        },
        .arith => |arith_expr| {
            switch (arith_expr) {
                .plus, .minus, .prod, .div => |expr| {
                    sema(expr.lhs.*, ctx);
                    sema(expr.rhs.*, ctx);
                },
                .int, .float => {},
            }
        },
        .bool_ => |bool_expr| {
            switch (bool_expr) {
                .eql, .ge, .gt, .lt, .le, .and_, .or_ => |expr| {
                    sema(expr.lhs.*, ctx);
                    sema(expr.rhs.*, ctx);
                },
                .constant => {},
            }
        },
        .bind => |bind_expr| {
            sema(bind_expr.body.*, ctx);
            sema(bind_expr.closure.*, ctx);
        },
        .field_access => |field_expr| sema(field_expr.lhs.*, ctx),
        .fn_call => |fn_call_expr| {
            for (fn_call_expr.args.items) |arg| {
                sema(arg, ctx);
            }
        },
        .fn_def => |fn_def_expr| {
            switch (fn_def_expr.body) {
                .fn_std => |fn_std| sema(fn_std.body.*, ctx),
                .fn_binding => {},
            }
        },
        .list => |list_expr| {
            for (list_expr.items) |sub_expr| {
                sema(sub_expr, ctx);
            }
        },
        .if_ => |if_expr| {
            sema(if_expr.eval.*, ctx);
            sema(if_expr.then.*, ctx);
            sema(if_expr.else_.*, ctx);
        },
        .struct_, .var_, .void_, .str => {},
    }
}

fn contains(item: []const u8, values: std.ArrayList([]const u8)) bool {
    for (values.items) |val| {
        if (std.mem.eql(u8, item, val)) return true;
    }
    return false;
}

fn assert_of_type(value: Expr, ok: bool) void {
    if (!ok) {
        std.debug.print("\n{s}:{}:{} runtime error\n", .{
            value.file_path,
            value.cursor.row,
            value.cursor.col,
        });
        if (builtin.mode != .Debug)
            std.process.exit(1)
        else
            panic("", .{});
    }
}

pub fn build_context(
    program: Expr,
    alloc: Allocator,
    content: []const u8,
    file_path: []const u8,
    io: std.Io,
) !Context {
    assert_of_type(program, program.tag() == .list);
    var functions: Funs = .empty;
    for (program.as.list.items) |expr| {
        if (expr.tag() == .fn_def) {
            try functions.put(alloc, expr.as.fn_def.name, expr.as.fn_def);
        }
    }

    try register_functions(alloc, &functions);

    var ctx: Context = .{
        .funs = functions,
        .alloc = alloc,
        .structs = .empty,
        .content = content,
        .file_path = file_path,
        .io = io,
    };

    try add_structs(program, &ctx);
    return ctx;
}

fn add_structs(program: Expr, ctx: *Context) !void {
    switch (program.as) {
        .arith => |expr| {
            switch (expr) {
                .plus, .minus, .prod, .div => |arith_expr| {
                    try add_structs(arith_expr.lhs.*, ctx);
                    try add_structs(arith_expr.rhs.*, ctx);
                },
                .int, .float => {},
            }
        },
        .bool_ => |expr| {
            switch (expr) {
                .eql, .gt, .ge, .lt, .le, .and_, .or_ => |bool_expr| {
                    try add_structs(bool_expr.lhs.*, ctx);
                    try add_structs(bool_expr.rhs.*, ctx);
                },
                .constant => {},
            }
        },
        .struct_ => |expr| {
            try ctx.structs.putNoClobber(ctx.alloc, expr.name, expr);
        },
        .list => |list| {
            for (list.items) |sub_expr| {
                try add_structs(sub_expr, ctx);
            }
        },
        .str => {},
        // if you need to add structs for more elements,
        // you can finish implement switch for all other types of expr
        else => {},
    }
}

pub fn eval(expr: Expr, ctx: Context, local_vars: *Vars) Expr {
    switch (expr.as) {
        .bool_ => |bool_| {
            return eval_bool(bool_, ctx, local_vars, expr.cursor);
        },
        .arith => |arith| {
            return eval_arith(arith, ctx, local_vars, expr.cursor);
        },
        .if_ => |if_| {
            return eval_if(if_, ctx, local_vars);
        },
        .var_ => |var_| {
            return eval_var(var_, ctx, local_vars, expr.cursor);
        },
        .fn_call => |fn_call| {
            return eval_fn_call(fn_call, ctx, local_vars, expr.cursor);
        },
        .fn_def => return expr,
        .list => |list| {
            var list_evaluated: std.ArrayList(Expr) = .empty;
            for (list.items) |el_expr| {
                const new_expr = eval(el_expr, ctx, local_vars);
                list_evaluated.append(ctx.alloc, new_expr) catch unreachable;
            }
            return list_evaluated.getLast();
        },
        .struct_ => return expr,
        .struct_instance => |struct_instance| {
            var new_expr: StructInstanceExpr = .{ .name = struct_instance.name, .fields = .empty };
            var it = struct_instance.fields.iterator();
            while (it.next()) |inst_field| {
                const efield = eval(inst_field.value_ptr.*, ctx, local_vars);
                new_expr.fields.putNoClobber(ctx.alloc, inst_field.key_ptr.*, efield) catch unreachable;
            }
            return .{
                .as = .{ .struct_instance = new_expr },
                .content = ctx.content,
                .cursor = expr.cursor,
                .file_path = ctx.file_path,
            };
        },
        .field_access => |field_access| {
            const elhs = eval(field_access.lhs.*, ctx, local_vars);
            assert_of_type(elhs, elhs.tag() == .struct_instance);
            return elhs.as.struct_instance.fields.get(field_access.field) orelse {
                panic("tried accessing {s} in struct {s} but do not exist", .{
                    field_access.field,
                    elhs.as.struct_instance.name,
                });
            };
        },
        .bind => |bind| return eval_bind(bind, ctx, local_vars),
        .void_ => return expr,
        .str => return expr,
    }
}

fn eval_bind(bind: BindExpr, ctx: Context, local_vars: *Vars) Expr {
    const id = bind.id;
    const ebody = eval(bind.body.*, ctx, local_vars);
    const body: Var =
        if (ebody.is_int())
            .{ .int = ebody.as.arith.int }
        else if (ebody.is_bool())
            .{ .bool_ = ebody.as.bool_.constant }
        else if (ebody.is_struct_instance())
            .{ .struct_instance = ebody.as.struct_instance }
        else if (ebody.is_str())
            .{ .str = ebody.as.str }
        else if (ebody.is_void())
            .{ .void_ = {} }
        else
            panic("body must be evaluated of type int or bool or struct_instance or str", .{});

    local_vars.putNoClobber(id, body) catch unreachable;
    defer std.debug.assert(local_vars.remove(id));
    return eval(bind.closure.*, ctx, local_vars);
}

fn eval_fn_call(expr: FnCallExpr, ctx: Context, local_vars: *Vars, cursor: Cursor) Expr {
    const fn_def = ctx.funs.get(expr.name) orelse {
        panic("Called this function {s} but it does not exist\n", .{expr.name});
    };
    assert_of_type(.{
        .as = .{ .fn_def = fn_def },
        .cursor = cursor,
        .content = ctx.content,
        .file_path = ctx.file_path,
    }, fn_def.args.items.len == expr.args.items.len);
    var fn_params: Vars = .init(ctx.alloc);
    defer fn_params.deinit();
    for (0..expr.args.items.len) |i| {
        const arg = expr.args.items[i];
        const arg_name = fn_def.args.items[i];
        const arg_eval = eval(arg, ctx, local_vars);
        assert_of_type(
            arg_eval,
            arg_eval.tag() == .bool_ or arg_eval.tag() == .arith or arg_eval.tag() == .str or arg_eval.is_struct_instance(),
        );
        const var_: Var = if (arg_eval.tag() == .bool_)
            .{ .bool_ = arg_eval.as.bool_.constant }
        else if (arg_eval.tag() == .arith and arg_eval.as.arith.tag() == .int)
            .{ .int = arg_eval.as.arith.int }
        else if (arg_eval.tag() == .arith and arg_eval.as.arith.tag() == .float)
            .{ .float = arg_eval.as.arith.float }
        else if (arg_eval.tag() == .str)
            .{ .str = arg_eval.as.str }
        else if (arg_eval.is_struct_instance())
            .{ .struct_instance = arg_eval.as.struct_instance }
        else
            panic("unhandled case", .{});
        fn_params.putNoClobber(arg_name, var_) catch unreachable;
    }

    return eval_fn(fn_def, ctx, &fn_params, cursor);
}

fn eval_fn(fn_def: FnExpr, ctx: Context, fn_params: *Vars, cursor: Cursor) Expr {
    return switch (fn_def.body) {
        .fn_std => |fn_std| eval(fn_std.body.*, ctx, fn_params),
        .fn_binding => |fn_binding| fn_binding.fn_(
            fn_params,
            .{
                .content = ctx.content,
                .cursor = cursor,
                .file_path = ctx.file_path,
                .alloc = ctx.alloc,
                .io = ctx.io,
            },
        ),
    };
}

fn eval_var(expr: []const u8, ctx: Context, local_vars: *Vars, cursor: Cursor) Expr {
    const value = local_vars.get(expr) orelse panic("var {s} not in context", .{expr});
    return switch (value) {
        .bool_ => |var_| .{
            .as = .{ .bool_ = .{ .constant = var_ } },
            .content = ctx.content,
            .cursor = cursor,
            .file_path = ctx.file_path,
        },
        .int => |var_| .{
            .as = .{ .arith = .{ .int = var_ } },
            .content = ctx.content,
            .cursor = cursor,
            .file_path = ctx.file_path,
        },
        .float => |var_| .{
            .as = .{ .arith = .{ .float = var_ } },
            .content = ctx.content,
            .cursor = cursor,
            .file_path = ctx.file_path,
        },
        .struct_instance => |var_| .{
            .as = .{ .struct_instance = var_ },
            .content = ctx.content,
            .cursor = cursor,
            .file_path = ctx.file_path,
        },
        .str => |var_| .{
            .as = .{ .str = var_ },
            .content = ctx.content,
            .cursor = cursor,
            .file_path = ctx.file_path,
        },
        .void_ => .{
            .as = .{ .void_ = {} },
            .content = ctx.content,
            .cursor = cursor,
            .file_path = ctx.file_path,
        },
    };
}

fn eval_if(expr: IfExpr, ctx: Context, local_vars: *Vars) Expr {
    const cond = eval(expr.eval.*, ctx, local_vars);
    assert_of_type(cond, cond.tag() == .bool_);
    assert_of_type(cond, cond.as.bool_.tag() == .constant);
    if (cond.as.bool_.constant)
        return eval(expr.then.*, ctx, local_vars);

    for (
        expr.elseif_evals.items,
        expr.elseif_thens.items,
    ) |elseif_eval, elseif_then| {
        const elseif_cond = eval(elseif_eval, ctx, local_vars);
        if (elseif_cond.as.bool_.constant)
            return eval(elseif_then, ctx, local_vars);
    }

    return eval(expr.else_.*, ctx, local_vars);
}

fn eval_arith(expr: ArithExpr, ctx: Context, local_vars: *Vars, cursor: Cursor) Expr {
    switch (expr) {
        .int => |constant| return .{
            .as = .{ .arith = .{ .int = constant } },
            .content = ctx.content,
            .cursor = cursor,
            .file_path = ctx.file_path,
        },
        .float => |float| return .{
            .as = .{ .arith = .{ .float = float } },
            .content = ctx.content,
            .cursor = cursor,
            .file_path = ctx.file_path,
        },
        .prod, .div, .minus, .plus => |op| {
            const lhs = eval(op.lhs.*, ctx, local_vars);
            const rhs = eval(op.rhs.*, ctx, local_vars);

            assert_of_type(lhs, lhs.tag() == .arith);
            assert_of_type(rhs, rhs.tag() == .arith);
            assert_of_type(lhs, lhs.as.arith == .int or lhs.as.arith == .float);
            assert_of_type(rhs, rhs.as.arith == .int or rhs.as.arith == .float);
            assert_of_type(lhs, lhs.as.arith.tag() == rhs.as.arith.tag());

            if (lhs.as.arith == .int) {
                return switch (expr) {
                    .prod => .{
                        .as = .{ .arith = .{
                            .int = lhs.as.arith.int * rhs.as.arith.int,
                        } },
                        .content = ctx.content,
                        .cursor = cursor,
                        .file_path = ctx.file_path,
                    },
                    .div => .{
                        .as = .{ .arith = .{
                            .int = @divFloor(lhs.as.arith.int, rhs.as.arith.int),
                        } },
                        .content = ctx.content,
                        .cursor = cursor,
                        .file_path = ctx.file_path,
                    },
                    .plus => .{
                        .as = .{ .arith = .{
                            .int = lhs.as.arith.int + rhs.as.arith.int,
                        } },
                        .content = ctx.content,
                        .cursor = cursor,
                        .file_path = ctx.file_path,
                    },
                    .minus => .{
                        .as = .{ .arith = .{
                            .int = lhs.as.arith.int - rhs.as.arith.int,
                        } },
                        .content = ctx.content,
                        .cursor = cursor,
                        .file_path = ctx.file_path,
                    },
                    .float, .int => unreachable,
                };
            } else if (lhs.as.arith == .float) {
                return switch (expr) {
                    .prod => .{
                        .as = .{ .arith = .{
                            .float = lhs.as.arith.float * rhs.as.arith.float,
                        } },
                        .content = ctx.content,
                        .cursor = cursor,
                        .file_path = ctx.file_path,
                    },
                    .div => .{
                        .as = .{ .arith = .{
                            .float = lhs.as.arith.float / rhs.as.arith.float,
                        } },
                        .content = ctx.content,
                        .cursor = cursor,
                        .file_path = ctx.file_path,
                    },
                    .plus => .{
                        .as = .{ .arith = .{
                            .float = lhs.as.arith.float + rhs.as.arith.float,
                        } },
                        .content = ctx.content,
                        .cursor = cursor,
                        .file_path = ctx.file_path,
                    },
                    .minus => .{
                        .as = .{ .arith = .{
                            .float = lhs.as.arith.float - rhs.as.arith.float,
                        } },
                        .content = ctx.content,
                        .cursor = cursor,
                        .file_path = ctx.file_path,
                    },
                    .float, .int => unreachable,
                };
            } else unreachable;
        },
    }
}

fn eval_bool(expr: BoolExpr, ctx: Context, local_vars: *Vars, cursor: Cursor) Expr {
    switch (expr) {
        .constant => |const_| return .{
            .as = .{ .bool_ = .{ .constant = const_ } },
            .content = ctx.content,
            .cursor = cursor,
            .file_path = ctx.file_path,
        },
        .eql, .ge, .gt, .le, .lt => |eql_expr| {
            const lhs = eval(eql_expr.lhs.*, ctx, local_vars);
            const rhs = eval(eql_expr.rhs.*, ctx, local_vars);

            assert_of_type(lhs, lhs.tag() == .arith);
            assert_of_type(rhs, rhs.tag() == .arith);
            const result: BoolExpr = switch (expr) {
                .eql => .{ .constant = (lhs.as.arith.int == rhs.as.arith.int) },
                .ge => .{ .constant = (lhs.as.arith.int >= rhs.as.arith.int) },
                .gt => .{ .constant = (lhs.as.arith.int > rhs.as.arith.int) },
                .le => .{ .constant = (lhs.as.arith.int <= rhs.as.arith.int) },
                .lt => .{ .constant = (lhs.as.arith.int < rhs.as.arith.int) },
                else => unreachable,
            };
            return .{
                .as = .{ .bool_ = result },
                .content = ctx.content,
                .cursor = cursor,
                .file_path = ctx.file_path,
            };
        },
        .and_ => |bin_expr| {
            const lhs = eval(bin_expr.lhs.*, ctx, local_vars);
            assert_of_type(lhs, lhs.tag() == .bool_);
            if (!lhs.as.bool_.constant) {
                return .{
                    .as = .{ .bool_ = .{ .constant = false } },
                    .content = ctx.content,
                    .cursor = cursor,
                    .file_path = ctx.file_path,
                };
            }

            const rhs = eval(bin_expr.rhs.*, ctx, local_vars);

            assert_of_type(rhs, rhs.tag() == .bool_);

            const result: BoolExpr = .{
                .constant = (lhs.as.bool_.constant and rhs.as.bool_.constant),
            };

            return .{
                .as = .{ .bool_ = result },
                .content = ctx.content,
                .cursor = cursor,
                .file_path = ctx.file_path,
            };
        },
        .or_ => |bin_expr| {
            const lhs = eval(bin_expr.lhs.*, ctx, local_vars);
            assert_of_type(lhs, lhs.tag() == .bool_);
            if (lhs.as.bool_.constant) {
                return .{
                    .as = .{ .bool_ = .{ .constant = true } },
                    .content = ctx.content,
                    .cursor = cursor,
                    .file_path = ctx.file_path,
                };
            }

            const rhs = eval(bin_expr.rhs.*, ctx, local_vars);
            assert_of_type(rhs, rhs.tag() == .bool_);

            const result: BoolExpr = .{
                .constant = (lhs.as.bool_.constant or rhs.as.bool_.constant),
            };

            return .{
                .as = .{ .bool_ = result },
                .content = ctx.content,
                .cursor = cursor,
                .file_path = ctx.file_path,
            };
        },
        // else => panic("unhandled for {}", .{expr.tag()}),
    }
}

const VarTag = enum {
    int,
    float,
    bool_,
    str,
    struct_instance,
    void_,
};

const Var = union(VarTag) {
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

fn arena_alloc() std.heap.ArenaAllocator {
    return std.heap.ArenaAllocator.init(std.testing.allocator);
}

pub fn eval_source(alloc: Allocator, source: []const u8) !Expr {
    var lexer = Lexer.init(source, "test.sub");
    var parser = Parser.init(&lexer, alloc);
    const expr = try parser.parse();
    const io: std.Io = if (builtin.is_test) std.testing.io else undefined;
    const ctx = try build_context(expr, alloc, source, "test.sub", io);
    sema(expr, ctx);
    var local_vars: Vars = .init(alloc);
    defer local_vars.deinit();
    return eval(expr, ctx, &local_vars);
}

test "eval int arithmetic with precedence and parentheses" {
    var arena = arena_alloc();
    defer arena.deinit();
    const alloc = arena.allocator();

    const res1 = try eval_source(alloc, "10 + (20 * 3) - 5;");
    try expect(.arith, res1.tag());
    try expect(65, res1.as.arith.int);

    const res2 = try eval_source(alloc, "(10 + 20) * (3 - 1);");
    try expect(.arith, res2.tag());
    try expect(60, res2.as.arith.int);

    // sub_pl parses sequentially left-to-right without operator precedence
    const res3 = try eval_source(alloc, "10 + 20 * 3 - 5;");
    try expect(.arith, res3.tag());
    try expect(85, res3.as.arith.int);
}

test "eval integer division" {
    var arena = arena_alloc();
    defer arena.deinit();
    const alloc = arena.allocator();

    const res = try eval_source(alloc, "100 / 4 / 5;");
    try expect(.arith, res.tag());
    try expect(5, res.as.arith.int);
}

test "eval float arithmetic" {
    var arena = arena_alloc();
    defer arena.deinit();
    const alloc = arena.allocator();

    const res = try eval_source(alloc, "12.5 + (2.5 * 2.0);");
    try expect(.arith, res.tag());
    try expect(17.5, res.as.arith.float);
}

test "eval equality and relational operators" {
    var arena = arena_alloc();
    defer arena.deinit();
    const alloc = arena.allocator();

    const res1 = try eval_source(alloc, "10 == 10;");
    try expect(true, res1.as.bool_.constant);

    const res2 = try eval_source(alloc, "10 == 20;");
    try expect(false, res2.as.bool_.constant);

    const res3 = try eval_source(alloc, "5 < 10;");
    try expect(true, res3.as.bool_.constant);

    const res4 = try eval_source(alloc, "10 <= 10;");
    try expect(true, res4.as.bool_.constant);

    const res5 = try eval_source(alloc, "20 > 5;");
    try expect(true, res5.as.bool_.constant);

    const res6 = try eval_source(alloc, "5 >= 6;");
    try expect(false, res6.as.bool_.constant);
}

test "eval logical and / or" {
    var arena = arena_alloc();
    defer arena.deinit();
    const alloc = arena.allocator();

    const res1 = try eval_source(alloc, "(10 > 5) and (2 == 2);");
    try expect(true, res1.as.bool_.constant);

    const res2 = try eval_source(alloc, "(1 == 2) or (3 == 3);");
    try expect(true, res2.as.bool_.constant);

    const res3 = try eval_source(alloc, "(1 == 2) and (3 == 3);");
    try expect(false, res3.as.bool_.constant);

    const res4 = try eval_source(alloc, "(1 == 2) or (3 == 4);");
    try expect(false, res4.as.bool_.constant);
}

test "eval if-then-else and elseif branches" {
    var arena = arena_alloc();
    defer arena.deinit();
    const alloc = arena.allocator();

    const res1 = try eval_source(alloc, "if 10 > 5 then 100 else 200;");
    try expect(100, res1.as.arith.int);

    const res2 = try eval_source(alloc, "if 5 > 10 then 100 else 200;");
    try expect(200, res2.as.arith.int);

    const res3 = try eval_source(alloc, "bind x = 2 in if x == 1 then 10 elseif x == 2 then 20 else 30;");
    try expect(20, res3.as.arith.int);

    const res4 = try eval_source(alloc, "10 + (if 1 == 1 then 5 else 0);");
    try expect(15, res4.as.arith.int);
}

test "eval variable binding and sequential scopes" {
    var arena = arena_alloc();
    defer arena.deinit();
    const alloc = arena.allocator();

    const res1 = try eval_source(alloc, "bind a = 15 in a * 2;");
    try expect(30, res1.as.arith.int);

    const res2 = try eval_source(alloc, "bind a = 10 in bind b = a * 2 in a + b;");
    try expect(30, res2.as.arith.int);

    const res3 = try eval_source(alloc, "bind a = 1 in bind b = 2 in bind c = 3 in a + b + c;");
    try expect(6, res3.as.arith.int);
}

test "eval multi-arg function definition and call" {
    var arena = arena_alloc();
    defer arena.deinit();
    const alloc = arena.allocator();

    const res1 = try eval_source(alloc, "let add3 = fn a b c -> a + b + c; add3(1, 2, 3,);");
    try expect(6, res1.as.arith.int);

    const res2 = try eval_source(alloc, "let double = fn x -> x * 2; let inc = fn x -> x + 1; double(inc(5,),);");
    try expect(12, res2.as.arith.int);
}

test "eval recursive function factorial and fibonacci" {
    var arena = arena_alloc();
    defer arena.deinit();
    const alloc = arena.allocator();

    const res1 = try eval_source(alloc, "let fact = fn n -> if n == 1 then 1 else n * fact(n - 1,); fact(5,);");
    try expect(120, res1.as.arith.int);

    const res2 = try eval_source(alloc, "let fib = fn n -> if n <= 1 then n else fib(n - 1,) + fib(n - 2,); fib(7,);");
    try expect(13, res2.as.arith.int);
}

test "eval struct instantiation and field access" {
    var arena = arena_alloc();
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\ struct Point { x, y, };
        \\ bind p = @Point{ .x = 10, .y = 20, } in p.x + (p.y);
    ;
    const res = try eval_source(alloc, source);
    try expect(30, res.as.arith.int);
}

test "eval struct as function parameter and return value" {
    var arena = arena_alloc();
    defer arena.deinit();
    const alloc = arena.allocator();

    const source1 =
        \\ struct Point { x, y, };
        \\ let get_x = fn pt -> pt.x;
        \\ get_x(@Point{ .x = 42, .y = 0, },);
    ;
    const res1 = try eval_source(alloc, source1);
    try expect(42, res1.as.arith.int);

    const source2 =
        \\ struct Point { x, y, };
        \\ let make_pt = fn x y -> @Point{ .x = x, .y = y, };
        \\ bind p = make_pt(3, 4,) in p.x;
    ;
    const res2 = try eval_source(alloc, source2);
    try expect(3, res2.as.arith.int);
}

test "eval stdlib functions len, getc, slice, parse_int" {
    var arena = arena_alloc();
    defer arena.deinit();
    const alloc = arena.allocator();

    const res1 = try eval_source(alloc, "len(\"hello world\",);");
    try expect(11, res1.as.arith.int);

    const res2 = try eval_source(alloc, "getc(\"ABC\", 1,);");
    try expect(66, res2.as.arith.int);

    const res3 = try eval_source(alloc, "slice(\"abcdef\", 1, 4,);");
    try expectStrings("bcd", res3.as.str);

    const res4 = try eval_source(alloc, "parse_int(\"1234\",) + 6;");
    try expect(1240, res4.as.arith.int);
}
