const std = @import("std");

const expression_pkg = @import("expression.zig");
const eval_pkg = @import("eval.zig");
const sema_pkg = @import("sema.zig");
const lexer_pkg = @import("lexer.zig");

const Allocator = std.mem.Allocator;
const Cursor = lexer_pkg.Cursor;
const Expr = expression_pkg.Expr;
const ArithExpr = expression_pkg.ArithExpr;
const BoolExpr = expression_pkg.BoolExpr;
const IfExpr = expression_pkg.IfExpr;
const FnCallExpr = expression_pkg.FnCallExpr;
const StructInstanceExpr = expression_pkg.StructInstanceExpr;

const Context = sema_pkg.Context;
const Vars = eval_pkg.Vars;
const Var = eval_pkg.Var;
const assert_of_type = sema_pkg.assert_of_type;

const panic = std.debug.panic;

/// Units of work for the iterative evaluator.
/// `eval` schedules evaluation of an expression; the `apply_*` tasks
/// consume already-evaluated operands from the value stack.
const Task = union(enum) {
    eval: struct { expr: Expr, env: *Vars },
    apply_arith: struct { op: ArithExpr, cursor: Cursor },
    apply_bool_cmp: struct { op: BoolExpr, cursor: Cursor },
    apply_bool_and: struct { rhs: Expr, env: *Vars, cursor: Cursor },
    apply_bool_or: struct { rhs: Expr, env: *Vars, cursor: Cursor },
    /// branch == 0: main condition evaluated, branch == i: elseif i-1 evaluated
    apply_if: struct { if_expr: IfExpr, branch: usize, env: *Vars },
    apply_bind: struct { id: []const u8, closure: Expr, env: *Vars },
    unwind_bind: struct { id: []const u8, env: *Vars },
    apply_fn_call: struct { fn_call: FnCallExpr, cursor: Cursor },
    pop_fn_scope: struct { params: *Vars },
    apply_field_access: struct { field: []const u8 },
    apply_struct_instance: struct { name: []const u8, keys: []const []const u8, cursor: Cursor },
    apply_list: struct { count: usize },
};

const ExprAs = @FieldType(Expr, "as");

fn make_expr(as: ExprAs, ctx: Context, cursor: Cursor) Expr {
    return .{
        .as = as,
        .content = ctx.content,
        .cursor = cursor,
        .file_path = ctx.file_path,
    };
}

fn to_var(value: Expr) Var {
    return if (value.tag() == .bool_)
        .{ .bool_ = value.as.bool_.constant }
    else if (value.tag() == .arith and value.as.arith.tag() == .int)
        .{ .int = value.as.arith.int }
    else if (value.tag() == .arith and value.as.arith.tag() == .float)
        .{ .float = value.as.arith.float }
    else if (value.is_struct_instance())
        .{ .struct_instance = value.as.struct_instance }
    else if (value.is_str())
        .{ .str = value.as.str }
    else if (value.is_void())
        .{ .void_ = {} }
    else
        panic("value must be of type int, float, bool, struct_instance, str or void", .{});
}

/// Iterative evaluator: uses heap-allocated task and value stacks
/// instead of the native call stack, so deep recursion in the
/// interpreted program cannot overflow the Zig stack.
pub fn eval(expr: Expr, ctx: Context, local_vars: *Vars) Expr {
    const alloc = ctx.alloc;
    var tasks: std.ArrayList(Task) = .empty;
    defer tasks.deinit(alloc);
    var values: std.ArrayList(Expr) = .empty;
    defer values.deinit(alloc);

    tasks.append(alloc, .{ .eval = .{ .expr = expr, .env = local_vars } }) catch unreachable;

    while (tasks.pop()) |task| {
        switch (task) {
            .eval => |t| schedule(t.expr, t.env, ctx, &tasks, &values),
            .apply_arith => |t| {
                const rhs = values.pop().?;
                const lhs = values.pop().?;
                values.append(alloc, compute_arith(t.op, lhs, rhs, ctx, t.cursor)) catch unreachable;
            },
            .apply_bool_cmp => |t| {
                const rhs = values.pop().?;
                const lhs = values.pop().?;
                assert_of_type(lhs, lhs.tag() == .arith);
                assert_of_type(rhs, rhs.tag() == .arith);
                const a = lhs.as.arith.int;
                const b = rhs.as.arith.int;
                const result = switch (t.op) {
                    .eql => a == b,
                    .ge => a >= b,
                    .gt => a > b,
                    .le => a <= b,
                    .lt => a < b,
                    else => unreachable,
                };
                values.append(alloc, make_expr(.{ .bool_ = .{ .constant = result } }, ctx, t.cursor)) catch unreachable;
            },
            .apply_bool_and => |t| {
                const lhs = values.pop().?;
                assert_of_type(lhs, lhs.tag() == .bool_);
                if (!lhs.as.bool_.constant) {
                    values.append(alloc, make_expr(.{ .bool_ = .{ .constant = false } }, ctx, t.cursor)) catch unreachable;
                } else {
                    tasks.append(alloc, .{ .eval = .{ .expr = t.rhs, .env = t.env } }) catch unreachable;
                }
            },
            .apply_bool_or => |t| {
                const lhs = values.pop().?;
                assert_of_type(lhs, lhs.tag() == .bool_);
                if (lhs.as.bool_.constant) {
                    values.append(alloc, make_expr(.{ .bool_ = .{ .constant = true } }, ctx, t.cursor)) catch unreachable;
                } else {
                    tasks.append(alloc, .{ .eval = .{ .expr = t.rhs, .env = t.env } }) catch unreachable;
                }
            },
            .apply_if => |t| {
                const cond = values.pop().?;
                assert_of_type(cond, cond.tag() == .bool_);
                assert_of_type(cond, cond.as.bool_.tag() == .constant);
                const if_expr = t.if_expr;
                const next: Task = if (cond.as.bool_.constant) blk: {
                    const branch_expr = if (t.branch == 0) if_expr.then.* else if_expr.elseif_thens.items[t.branch - 1];
                    break :blk .{ .eval = .{ .expr = branch_expr, .env = t.env } };
                } else if (t.branch < if_expr.elseif_evals.items.len) blk: {
                    tasks.append(alloc, .{ .apply_if = .{ .if_expr = if_expr, .branch = t.branch + 1, .env = t.env } }) catch unreachable;
                    break :blk .{ .eval = .{ .expr = if_expr.elseif_evals.items[t.branch], .env = t.env } };
                } else .{ .eval = .{ .expr = if_expr.else_.*, .env = t.env } };
                tasks.append(alloc, next) catch unreachable;
            },
            .apply_bind => |t| {
                const body = values.pop().?;
                t.env.putNoClobber(t.id, to_var(body)) catch unreachable;
                tasks.append(alloc, .{ .unwind_bind = .{ .id = t.id, .env = t.env } }) catch unreachable;
                tasks.append(alloc, .{ .eval = .{ .expr = t.closure, .env = t.env } }) catch unreachable;
            },
            .unwind_bind => |t| std.debug.assert(t.env.remove(t.id)),
            .apply_fn_call => |t| apply_fn_call(t.fn_call, t.cursor, ctx, &tasks, &values),
            .pop_fn_scope => |t| {
                t.params.deinit();
                alloc.destroy(t.params);
            },
            .apply_field_access => |t| {
                const lhs = values.pop().?;
                assert_of_type(lhs, lhs.tag() == .struct_instance);
                const field = lhs.as.struct_instance.fields.get(t.field) orelse {
                    panic("tried accessing {s} in struct {s} but do not exist", .{
                        t.field,
                        lhs.as.struct_instance.name,
                    });
                };
                values.append(alloc, field) catch unreachable;
            },
            .apply_struct_instance => |t| {
                const base = values.items.len - t.keys.len;
                var new_expr: StructInstanceExpr = .{ .name = t.name, .fields = .empty };
                for (t.keys, values.items[base..]) |key, value| {
                    new_expr.fields.putNoClobber(alloc, key, value) catch unreachable;
                }
                values.shrinkRetainingCapacity(base);
                values.append(alloc, make_expr(.{ .struct_instance = new_expr }, ctx, t.cursor)) catch unreachable;
            },
            .apply_list => |t| {
                // the value of a list is the value of its last expression
                const last = values.pop().?;
                values.shrinkRetainingCapacity(values.items.len - (t.count - 1));
                values.append(alloc, last) catch unreachable;
            },
        }
    }

    std.debug.assert(values.items.len == 1);
    return values.pop().?;
}

fn schedule(
    expr: Expr,
    env: *Vars,
    ctx: Context,
    tasks: *std.ArrayList(Task),
    values: *std.ArrayList(Expr),
) void {
    const alloc = ctx.alloc;
    switch (expr.as) {
        .arith => |arith| switch (arith) {
            .int, .float => values.append(alloc, make_expr(expr.as, ctx, expr.cursor)) catch unreachable,
            .prod, .div, .minus, .plus => |op| {
                tasks.append(alloc, .{ .apply_arith = .{ .op = arith, .cursor = expr.cursor } }) catch unreachable;
                tasks.append(alloc, .{ .eval = .{ .expr = op.rhs.*, .env = env } }) catch unreachable;
                tasks.append(alloc, .{ .eval = .{ .expr = op.lhs.*, .env = env } }) catch unreachable;
            },
        },
        .bool_ => |bool_| switch (bool_) {
            .constant => values.append(alloc, make_expr(expr.as, ctx, expr.cursor)) catch unreachable,
            .eql, .ge, .gt, .le, .lt => |op| {
                tasks.append(alloc, .{ .apply_bool_cmp = .{ .op = bool_, .cursor = expr.cursor } }) catch unreachable;
                tasks.append(alloc, .{ .eval = .{ .expr = op.rhs.*, .env = env } }) catch unreachable;
                tasks.append(alloc, .{ .eval = .{ .expr = op.lhs.*, .env = env } }) catch unreachable;
            },
            .and_ => |op| {
                tasks.append(alloc, .{ .apply_bool_and = .{ .rhs = op.rhs.*, .env = env, .cursor = expr.cursor } }) catch unreachable;
                tasks.append(alloc, .{ .eval = .{ .expr = op.lhs.*, .env = env } }) catch unreachable;
            },
            .or_ => |op| {
                tasks.append(alloc, .{ .apply_bool_or = .{ .rhs = op.rhs.*, .env = env, .cursor = expr.cursor } }) catch unreachable;
                tasks.append(alloc, .{ .eval = .{ .expr = op.lhs.*, .env = env } }) catch unreachable;
            },
        },
        .if_ => |if_| {
            tasks.append(alloc, .{ .apply_if = .{ .if_expr = if_, .branch = 0, .env = env } }) catch unreachable;
            tasks.append(alloc, .{ .eval = .{ .expr = if_.eval.*, .env = env } }) catch unreachable;
        },
        .var_ => |var_| values.append(alloc, eval_var(var_, ctx, env, expr.cursor)) catch unreachable,
        .fn_call => |fn_call| {
            tasks.append(alloc, .{ .apply_fn_call = .{ .fn_call = fn_call, .cursor = expr.cursor } }) catch unreachable;
            var i = fn_call.args.items.len;
            while (i > 0) {
                i -= 1;
                tasks.append(alloc, .{ .eval = .{ .expr = fn_call.args.items[i], .env = env } }) catch unreachable;
            }
        },
        .list => |list| {
            if (list.items.len == 0) panic("cannot evaluate an empty program", .{});
            tasks.append(alloc, .{ .apply_list = .{ .count = list.items.len } }) catch unreachable;
            var i = list.items.len;
            while (i > 0) {
                i -= 1;
                tasks.append(alloc, .{ .eval = .{ .expr = list.items[i], .env = env } }) catch unreachable;
            }
        },
        .struct_instance => |struct_instance| {
            const keys = alloc.alloc([]const u8, struct_instance.fields.count()) catch unreachable;
            const field_exprs = alloc.alloc(Expr, keys.len) catch unreachable;
            var it = struct_instance.fields.iterator();
            var n: usize = 0;
            while (it.next()) |field| : (n += 1) {
                keys[n] = field.key_ptr.*;
                field_exprs[n] = field.value_ptr.*;
            }
            tasks.append(alloc, .{ .apply_struct_instance = .{
                .name = struct_instance.name,
                .keys = keys,
                .cursor = expr.cursor,
            } }) catch unreachable;
            var i = field_exprs.len;
            while (i > 0) {
                i -= 1;
                tasks.append(alloc, .{ .eval = .{ .expr = field_exprs[i], .env = env } }) catch unreachable;
            }
        },
        .field_access => |field_access| {
            tasks.append(alloc, .{ .apply_field_access = .{ .field = field_access.field } }) catch unreachable;
            tasks.append(alloc, .{ .eval = .{ .expr = field_access.lhs.*, .env = env } }) catch unreachable;
        },
        .bind => |bind| {
            tasks.append(alloc, .{ .apply_bind = .{ .id = bind.id, .closure = bind.closure.*, .env = env } }) catch unreachable;
            tasks.append(alloc, .{ .eval = .{ .expr = bind.body.*, .env = env } }) catch unreachable;
        },
        .fn_def, .struct_, .void_, .str => values.append(alloc, expr) catch unreachable,
    }
}

fn apply_fn_call(
    fn_call: FnCallExpr,
    cursor: Cursor,
    ctx: Context,
    tasks: *std.ArrayList(Task),
    values: *std.ArrayList(Expr),
) void {
    const alloc = ctx.alloc;
    const fn_def = ctx.funs.get(fn_call.name) orelse {
        panic("Called this function {s} but it does not exist\n", .{fn_call.name});
    };
    assert_of_type(
        make_expr(.{ .fn_def = fn_def }, ctx, cursor),
        fn_def.args.items.len == fn_call.args.items.len,
    );

    const fn_params = alloc.create(Vars) catch unreachable;
    fn_params.* = .init(alloc);

    const base = values.items.len - fn_call.args.items.len;
    for (fn_def.args.items, values.items[base..]) |arg_name, arg_eval| {
        assert_of_type(
            arg_eval,
            arg_eval.tag() == .bool_ or arg_eval.tag() == .arith or arg_eval.tag() == .str or arg_eval.is_struct_instance(),
        );
        fn_params.putNoClobber(arg_name, to_var(arg_eval)) catch unreachable;
    }
    values.shrinkRetainingCapacity(base);

    switch (fn_def.body) {
        .fn_std => |fn_std| {
            tasks.append(alloc, .{ .pop_fn_scope = .{ .params = fn_params } }) catch unreachable;
            tasks.append(alloc, .{ .eval = .{ .expr = fn_std.body.*, .env = fn_params } }) catch unreachable;
        },
        .fn_binding => |fn_binding| {
            const result = fn_binding.fn_(fn_params, .{
                .content = ctx.content,
                .cursor = cursor,
                .file_path = ctx.file_path,
                .alloc = alloc,
                .io = ctx.io,
            });
            fn_params.deinit();
            alloc.destroy(fn_params);
            values.append(alloc, result) catch unreachable;
        },
    }
}

fn compute_arith(op: ArithExpr, lhs: Expr, rhs: Expr, ctx: Context, cursor: Cursor) Expr {
    assert_of_type(lhs, lhs.tag() == .arith);
    assert_of_type(rhs, rhs.tag() == .arith);
    assert_of_type(lhs, lhs.as.arith == .int or lhs.as.arith == .float);
    assert_of_type(rhs, rhs.as.arith == .int or rhs.as.arith == .float);
    assert_of_type(lhs, lhs.as.arith.tag() == rhs.as.arith.tag());

    const result: ArithExpr = switch (lhs.as.arith) {
        .int => |a| blk: {
            const b = rhs.as.arith.int;
            break :blk .{ .int = switch (op) {
                .prod => a * b,
                .div => @divFloor(a, b),
                .plus => a + b,
                .minus => a - b,
                .int, .float => unreachable,
            } };
        },
        .float => |a| blk: {
            const b = rhs.as.arith.float;
            break :blk .{ .float = switch (op) {
                .prod => a * b,
                .div => a / b,
                .plus => a + b,
                .minus => a - b,
                .int, .float => unreachable,
            } };
        },
        else => unreachable,
    };
    return make_expr(.{ .arith = result }, ctx, cursor);
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
