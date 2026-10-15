const std = @import("std");
const builtin = @import("builtin");

const expression_pkg = @import("expression.zig");
const stdlib_pkg = @import("stdlib.zig");
const lexer_pkg = @import("lexer.zig");

const Allocator = std.mem.Allocator;
const Expr = expression_pkg.Expr;
const FnExpr = expression_pkg.FnExpr;
const StructExpr = expression_pkg.StructExpr;

const panic = std.debug.panic;
const register_functions = stdlib_pkg.register_functions;

// Function and struct symbol tables built during semantic analysis
pub const Funs = std.StringArrayHashMapUnmanaged(FnExpr);
pub const Structs = std.StringArrayHashMapUnmanaged(StructExpr);

pub const Context = struct {
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

pub fn assert_of_type(value: Expr, ok: bool) void {
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
        else => {},
    }
}
