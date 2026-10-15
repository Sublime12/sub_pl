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
const FnExpr = expression_pkg.FnExpr;
const StructInstanceExpr = expression_pkg.StructInstanceExpr;
const BindExpr = expression_pkg.BindExpr;

const Context = sema_pkg.Context;
const Vars = eval_pkg.Vars;
const Var = eval_pkg.Var;
const assert_of_type = sema_pkg.assert_of_type;

const panic = std.debug.panic;

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
    }
}
