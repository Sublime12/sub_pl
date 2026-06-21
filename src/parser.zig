const std = @import("std");

const expression_pkg = @import("expression.zig");
const lexer_pkg = @import("lexer.zig");

const Expr = expression_pkg.Expr;
const FnExpr = expression_pkg.FnExpr;
const ArithExpr = expression_pkg.ArithExpr;
const BoolExpr = expression_pkg.BoolExpr;
const ArgsExpr = expression_pkg.ArgsExpr;
const FieldAccessExpr = expression_pkg.FieldAccessExpr;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const Lexer = lexer_pkg.Lexer;

const panic = std.debug.panic;
const expect = std.testing.expectEqual;
const expectStrings = std.testing.expectEqualStrings;

pub const Parser = struct {
    const Self = @This();
    lexer: *Lexer,
    alloc: Allocator,

    pub fn init(l: *Lexer, alloc: Allocator) Self {
        return .{
            .lexer = l,
            .alloc = alloc,
        };
    }

    pub fn parse(self: *Self) !Expr {
        self.lexer.cursor = .empty;
        self.lexer.nexti();

        var program: std.ArrayList(Expr) = .empty;
        var i: i32 = 0;
        while (self.lexer.token != .end) {
            const expr = try parse_expr(self.lexer, self.alloc);
            self.lexer.eat(.semicolon);
            try program.append(self.alloc, expr);
            i += 1;
        }
        return Expr.create_list(program, self.lexer);
    }

    fn parse_fn_def(l: *Lexer, alloc: Allocator) !Expr {
        l.expect(.id);
        const id = l.name.as_str(l.content);
        l.nexti();
        l.eat(.assign);
        l.eat(.fn_);
        var args = std.ArrayList([]const u8).empty;
        while (l.token == .id) {
            try args.append(alloc, l.name.as_str(l.content));
            l.nexti();
        }
        l.eat(.arrow);

        const body = try alloc.create(Expr);
        body.* = try parse_expr(l, alloc);

        const fn_expr: FnExpr = .{
            .name = id,
            .args = args,
            .body = .{ .fn_std = .{ .body = body } },
        };
        return Expr.create_fn_def(fn_expr, l);
    }

    /// can be an arith expr a + 1 - 3
    /// or a bool expr a = 1
    /// or a function call a(b, c, d)
    /// or more
    fn parse_arith_or_bool_expr(l: *Lexer, alloc: Allocator) !Expr {
        const name = l.name.as_str(l.content);
        var next_l = l.nextl();
        var lhs = try alloc.create(Expr);
        if (l.token == .id) {
            lhs.* = switch (next_l.token) {
                .oparen => blk: {
                    l.nexti();
                    const expr = try parse_fn_call(l, alloc, name);
                    break :blk expr;
                },
                .dot => blk: {
                    l.nexti();
                    l.eat(.dot);

                    l.expect(.id);
                    const field = l.name.as_str(l.content);
                    l.nexti();

                    const lhs_dot = try alloc.create(Expr);
                    lhs_dot.* = Expr.create_var(name, l);
                    const expr = Expr.create_field_access(lhs_dot, field, l);
                    break :blk expr;
                },
                else => blk: {
                    l.nexti();
                    break :blk Expr.create_var(name, l);
                },
            };
        } else if (l.token == .int) {
            lhs.* = Expr.create_arith(.{ .int = l.integer_value.? }, l);
            l.nexti();
        } else if (l.token == .float) {
            lhs.* = Expr.create_arith(.{ .float = l.float_value.? }, l);
            l.nexti();
        } else if (l.token == .str) {
            const escaped_string = try escape_row_string(alloc, l.name.as_str(l.content));
            lhs.* = Expr.create_str(escaped_string, l);
            l.nexti();
        } else if (l.token == .bool_) {
            lhs.* = Expr.create_bool(.{ .constant = l.bool_value.? }, l);
            l.nexti();
        } else if (l.token == .oparen) {
            l.nexti();
            lhs.* = try parse_expr(l, alloc);
            l.eat(.cparen);
        } else if (l.tokenType == .primary) panic("Must be identifier, integer or string or bool", .{});

        while (l.tokenType == .arith_op or l.tokenType == .bool_op or l.token == .dot) {
            const op_token = l.token;
            const op_token_type = l.tokenType;
            l.nexti();

            const rhs = try alloc.create(Expr);
            next_l = l.*;
            next_l.nexti();

            const current_name = l.name.as_str(l.content);
            const int_value = l.integer_value;
            const float_value = l.float_value;
            const bool_value = l.bool_value;

            rhs.* = switch (l.token) {
                .id => if (next_l.token == .oparen) blk: {
                    l.nexti();
                    const expr = try parse_fn_call(l, alloc, current_name);
                    break :blk expr;
                } else blk: {
                    l.nexti();
                    break :blk Expr.create_var(current_name, l);
                },
                .int => blk: {
                    l.nexti();
                    break :blk Expr.create_arith(.{ .int = int_value.? }, l);
                },
                .float => blk: {
                    l.nexti();
                    break :blk Expr.create_arith(.{ .float = float_value.? }, l);
                },
                .bool_ => blk: {
                    l.nexti();
                    break :blk Expr.create_bool(.{ .constant = bool_value.? }, l);
                },
                .str => blk: {
                    l.nexti();
                    break :blk Expr.create_str(current_name, l);
                },
                .oparen => blk: {
                    l.nexti();
                    const expr = try parse_expr(l, alloc);
                    l.eat(.cparen);
                    break :blk expr;
                },
                else => blk: {
                    const expr = try parse_expr(l, alloc);
                    break :blk expr;
                },
            };

            if (op_token_type == .arith_op) {
                const op: ArithExpr = switch (op_token) {
                    .prod => .{ .prod = .{ .lhs = lhs, .rhs = rhs } },
                    .div => .{ .div = .{ .lhs = lhs, .rhs = rhs } },
                    .plus => .{ .plus = .{ .lhs = lhs, .rhs = rhs } },
                    .minus => .{ .minus = .{ .lhs = lhs, .rhs = rhs } },
                    else => unreachable,
                };

                lhs = try alloc.create(Expr);
                lhs.* = Expr.create_arith(op, l);
            } else if (op_token_type == .bool_op) {
                const op: BoolExpr = switch (op_token) {
                    .eql => .{ .eql = .{ .lhs = lhs, .rhs = rhs } },
                    .gt => .{ .gt = .{ .lhs = lhs, .rhs = rhs } },
                    .ge => .{ .ge = .{ .lhs = lhs, .rhs = rhs } },
                    .lt => .{ .lt = .{ .lhs = lhs, .rhs = rhs } },
                    .le => .{ .le = .{ .lhs = lhs, .rhs = rhs } },
                    .and_ => .{ .and_ = .{ .lhs = lhs, .rhs = rhs } },
                    else => panic("not catch for {}", .{op_token}),
                };

                lhs = try alloc.create(Expr);
                lhs.* = Expr.create_bool(op, l);
            } else if (op_token == .dot) {
                const field = rhs.as.var_;
                const field_access_expr = Expr.create_field_access(lhs, field, l);
                lhs = try alloc.create(Expr);
                lhs.* = field_access_expr;
            }
        }

        return lhs.*;
    }

    fn parse_fn_call(l: *Lexer, alloc: Allocator, name: []const u8) !Expr {
        l.eat(.oparen);
        const args = try parse_args(l, alloc);
        l.eat(.cparen);
        return Expr.create_fn_call(name, args, l);
    }

    pub fn parse_args(l: *Lexer, alloc: Allocator) !ArgsExpr {
        var args: std.ArrayList(Expr) = .empty;
        while (l.token != .cparen) {
            const arg = try parse_expr(l, alloc);
            try args.append(alloc, arg);
            l.eat(.comma);
        }
        return args;
    }

    fn parse_expr(l: *Lexer, alloc: Allocator) error{OutOfMemory}!Expr {
        switch (l.token) {
            .let => {
                l.nexti();
                return parse_fn_def(l, alloc);
            },
            .if_ => {
                l.nexti();
                return parse_if(l, alloc);
            },
            .id, .int, .float, .bool_, .str, .oparen => {
                return parse_arith_or_bool_expr(l, alloc);
            },
            .bind => {
                return parse_bind(l, alloc);
            },
            .at => {
                return parse_struct_instance(l, alloc);
            },
            .struct_ => {
                return parse_struct(l, alloc);
            },
            else => {},
        }

        panic(
            "Panic with token {}, value: {s}",
            .{ l.token, l.name.as_str(l.content) },
        );
    }

    fn parse_struct_instance(l: *Lexer, alloc: Allocator) !Expr {
        l.nexti();
        l.expect(.id);
        const name = l.name.as_str(l.content);
        l.nexti();

        l.eat(.obrace);
        var fields: std.StringHashMapUnmanaged(Expr) = .empty;
        while (l.token != .cbrace) {
            l.eat(.dot);

            l.expect(.id);
            const field = l.name.as_str(l.content);
            l.nexti();
            l.eat(.assign);

            const value = try parse_expr(l, alloc);
            l.eat(.comma);
            try fields.putNoClobber(alloc, field, value);
        }
        l.nexti();
        return Expr.create_struct_instance(name, fields, l);
    }

    fn parse_struct(l: *Lexer, alloc: Allocator) !Expr {
        l.eat(.struct_);
        l.expect(.id);
        const struct_name = l.name.as_str(l.content);
        l.nexti();
        l.eat(.obrace);

        var fields: std.ArrayList([]const u8) = .empty;
        while (l.token != .cbrace) {
            l.expect(.id);
            const field = l.name.as_str(l.content);
            l.nexti();
            try fields.append(alloc, field);
            l.eat(.comma);
        }

        l.eat(.cbrace);

        return Expr.create_struct(struct_name, fields, l);
    }

    fn parse_bind(l: *Lexer, alloc: Allocator) !Expr {
        l.nexti();
        l.expect(.id);
        const id = l.name.as_str(l.content);
        l.nexti();

        l.eat(.assign);
        const body = try alloc.create(Expr);
        body.* = try parse_expr(l, alloc);
        l.eat(.in);

        const closure = try alloc.create(Expr);
        closure.* = try parse_expr(l, alloc);

        return Expr.create_bind(id, body, closure, l);
    }

    fn parse_if(l: *Lexer, alloc: Allocator) !Expr {
        const eval = try alloc.create(Expr);
        eval.* = try parse_expr(l, alloc);
        l.eat(.then);
        const then = try alloc.create(Expr);
        then.* = try parse_expr(l, alloc);

        var elseif_evals: std.ArrayList(Expr) = .empty;
        var elseif_thens: std.ArrayList(Expr) = .empty;
        while (l.token == .elseif) {
            l.eat(.elseif);
            const elseif_eval = try parse_expr(l, alloc);
            try elseif_evals.append(alloc, elseif_eval);
            l.eat(.then);
            const elseif_then = try parse_expr(l, alloc);
            try elseif_thens.append(alloc, elseif_then);
        }

        l.eat(.else_);
        const else_ = try alloc.create(Expr);
        else_.* = try parse_expr(l, alloc);

        return Expr.create_if(eval, then, elseif_evals, elseif_thens, else_, l);
    }

    fn escape_row_string(alloc: Allocator, raw_str: []const u8) ![]const u8 {
        var i: usize = 0;
        var new_str: std.ArrayList(u8) = .empty;

        while (i < raw_str.len) {
            if (raw_str[i] == '\\') {
                std.debug.assert(i + 1 < raw_str.len);
                const next = raw_str[i + 1];
                const to_append: u8 = switch (next) {
                    'n' => '\n',
                    '\\' => '\\',
                    else => panic("unsupported escaped char {c}", .{next}),
                };
                try new_str.append(alloc, to_append);
                i += 1;
            } else {
                const next = raw_str[i];
                try new_str.append(alloc, next);
            }
            i += 1;
        }
        return new_str.items;
    }
};

fn arena_alloc() ArenaAllocator {
    const backed_alloc = std.testing.allocator;
    return std.heap.ArenaAllocator.init(backed_alloc);
}

test "simple fn expression" {
    // For now use an arena alloc because we don't free memory
    var arena = arena_alloc();
    defer arena.deinit();
    const alloc = arena.allocator();
    const source_code =
        \\ print(97, );
    ;
    var lexer = Lexer.init(source_code, "test.zig");
    var parser = Parser.init(&lexer, alloc);
    const expr = try parser.parse();
    try expect(.list, expr.tag());
    const fn_call = expr.as.list.items[0];
    try expect(.fn_call, fn_call.tag());

    const args = fn_call.as.fn_call.args;
    try expect(1, args.items.len);
    const arg = args.items[0];
    try expect(.arith, arg.tag());
    try expect(.int, arg.as.arith.tag());
    try expect(97, arg.as.arith.int);
}

test "parse print_str function" {
    // For now use an arena alloc because we don't free memory
    var arena = arena_alloc();
    defer arena.deinit();
    const alloc = arena.allocator();
    const source_code =
        \\ print_str("bonjour"+"papa",);
    ;
    var lexer = Lexer.init(source_code, "test.zig");

    var parser = Parser.init(&lexer, alloc);
    const expr = try parser.parse();
    try expect(.list, expr.tag());

    try expect(1, expr.as.list.items.len);
    const fn_call = expr.as.list.items[0];
    try expect(.fn_call, fn_call.tag());
    try expectStrings("print_str", fn_call.as.fn_call.name);

    const args = fn_call.as.fn_call.args;
    try expect(1, args.items.len);
    const arg = args.items[0];
    try expect(.arith, arg.tag());
    try expect(.plus, arg.as.arith.tag());

    const lhs = arg.as.arith.plus.lhs;
    const rhs = arg.as.arith.plus.rhs;

    try expect(.str, lhs.tag());
    try expectStrings("bonjour", lhs.as.str);

    try expect(.str, rhs.tag());
    try expectStrings("papa", rhs.as.str);
}

test "parse function definition" {
    var arena = arena_alloc();
    defer arena.deinit();
    const alloc = arena.allocator();

    const source_code =
        \\ let add = fn x y -> x + y;
    ;
    var lexer = Lexer.init(source_code, "test.zig");
    var parser = Parser.init(&lexer, alloc);
    const expr = try parser.parse();

    try expect(.list, expr.tag());
    try expect(1, expr.as.list.items.len);

    const fn_def = expr.as.list.items[0];
    try expect(.fn_def, fn_def.tag());
    try expectStrings("add", fn_def.as.fn_def.name);
    try expect(2, fn_def.as.fn_def.args.items.len);
    try expectStrings("x", fn_def.as.fn_def.args.items[0]);
    try expectStrings("y", fn_def.as.fn_def.args.items[1]);

    const body = fn_def.as.fn_def.body.fn_std.body.*;
    try expect(.arith, body.tag());
    try expect(.plus, body.as.arith.tag());
}

test "parse if expression" {
    var arena = arena_alloc();
    defer arena.deinit();
    const alloc = arena.allocator();

    const source_code =
        \\ if n == 1 then "yes" else "no";
    ;
    var lexer = Lexer.init(source_code, "test.zig");
    var parser = Parser.init(&lexer, alloc);
    const expr = try parser.parse();

    try expect(.list, expr.tag());

    const if_expr = expr.as.list.items[0];
    try expect(.if_, if_expr.tag());

    const eval_node = if_expr.as.if_.eval.*;
    try expect(.bool_, eval_node.tag());
    try expect(.eql, eval_node.as.bool_.tag());

    const lhs = eval_node.as.bool_.eql.lhs;
    try expect(.var_, lhs.tag());
    try expectStrings("n", lhs.as.var_);

    const rhs = eval_node.as.bool_.eql.rhs;
    try expect(.arith, rhs.tag());
    try expect(.int, rhs.as.arith.tag());
    try expect(1, rhs.as.arith.int);

    const then_node = if_expr.as.if_.then.*;
    try expect(.str, then_node.tag());
    try expectStrings("yes", then_node.as.str);

    const else_node = if_expr.as.if_.else_.*;
    try expect(.str, else_node.tag());
    try expectStrings("no", else_node.as.str);
}

test "parse nested bind expressions" {
    var arena = arena_alloc();
    defer arena.deinit();
    const alloc = arena.allocator();

    const source_code =
        \\ let double = fn x -> x * 2;
        \\ bind n = 15 + 3 in
        \\ bind n_double = double(n, ) in
        \\ print_int(n_double,);
    ;
    var lexer = Lexer.init(source_code, "test.zig");
    var parser = Parser.init(&lexer, alloc);
    const expr = try parser.parse();

    try expect(.list, expr.tag());
    try expect(2, expr.as.list.items.len);

    const fn_def = expr.as.list.items[0];
    try expect(.fn_def, fn_def.tag());
    try expectStrings("double", fn_def.as.fn_def.name);

    const bind_n = expr.as.list.items[1];
    try expect(.bind, bind_n.tag());
    try expectStrings("n", bind_n.as.bind.id);

    const bind_n_body = bind_n.as.bind.body.*;
    try expect(.arith, bind_n_body.tag());
    try expect(.plus, bind_n_body.as.arith.tag());

    const bind_n_double = bind_n.as.bind.closure.*;
    try expect(.bind, bind_n_double.tag());
    try expectStrings("n_double", bind_n_double.as.bind.id);

    const bind_n_double_body = bind_n_double.as.bind.body.*;
    try expect(.fn_call, bind_n_double_body.tag());
    try expectStrings("double", bind_n_double_body.as.fn_call.name);
    try expect(1, bind_n_double_body.as.fn_call.args.items.len);

    const print_call = bind_n_double.as.bind.closure.*;
    try expect(.fn_call, print_call.tag());
    try expectStrings("print_int", print_call.as.fn_call.name);
    try expect(1, print_call.as.fn_call.args.items.len);

    const print_arg = print_call.as.fn_call.args.items[0];
    try expect(.var_, print_arg.tag());
    try expectStrings("n_double", print_arg.as.var_);
}

test "parse struct instance" {
    var arena = arena_alloc();
    defer arena.deinit();
    const alloc = arena.allocator();

    const source_code =
        \\ @Point{
        \\   .x = 2,
        \\   .y = 5,
        \\   .z = if 15 == 2 then "bonjour" else double(1 + 3 - 4,),
        \\ };
    ;
    var lexer = Lexer.init(source_code, "test.zig");
    var parser = Parser.init(&lexer, alloc);
    const expr = try parser.parse();

    try expect(.list, expr.tag());
    try expect(1, expr.as.list.items.len);

    const struct_expr = expr.as.list.items[0];
    try expect(.struct_instance, struct_expr.tag());
    try expectStrings("Point", struct_expr.as.struct_instance.name);
    try expect(3, struct_expr.as.struct_instance.fields.size);

    const field_x = struct_expr.as.struct_instance.fields.get("x") orelse return std.testing.expect(false);

    try expect(.arith, field_x.tag());
    try expect(.int, field_x.as.arith.tag());
    try expect(2, field_x.as.arith.int);

    const field_y = struct_expr.as.struct_instance.fields.get("y") orelse return std.testing.expect(false);
    try expect(.arith, field_y.tag());
    try expect(.int, field_y.as.arith.tag());
    try expect(5, field_y.as.arith.int);

    const field_z = struct_expr.as.struct_instance.fields.get("z") orelse return std.testing.expect(false);
    try expect(.if_, field_z.tag());

    const cond = field_z.as.if_.eval.*;
    try expect(.bool_, cond.tag());
    try expect(.eql, cond.as.bool_.tag());

    const then_branch = field_z.as.if_.then.*;
    try expect(.str, then_branch.tag());
    try expectStrings("bonjour", then_branch.as.str);

    const else_branch = field_z.as.if_.else_.*;
    try expect(.fn_call, else_branch.tag());
    try expectStrings("double", else_branch.as.fn_call.name);
    try expect(1, else_branch.as.fn_call.args.items.len);

    const arg_expr = else_branch.as.fn_call.args.items[0];
    try expect(.arith, arg_expr.tag());
    try expect(.minus, arg_expr.as.arith.tag());

    const lhs_arith = arg_expr.as.arith.minus.lhs.*;
    try expect(.plus, lhs_arith.as.arith.tag());

    const rhs_arith = arg_expr.as.arith.minus.rhs.*;
    try expect(.int, rhs_arith.as.arith.tag());
    try expect(4, rhs_arith.as.arith.int);
}

test "parse field access with dot" {
    var arena = arena_alloc();
    defer arena.deinit();
    const alloc = arena.allocator();

    const source_code =
        \\ p.x.y.z;
    ;
    var lexer = Lexer.init(source_code, "test.zig");
    var parser = Parser.init(&lexer, alloc);
    const expr = try parser.parse();

    try expect(.list, expr.tag());
    try expect(1, expr.as.list.items.len);

    const level_z = expr.as.list.items[0];
    try expect(.field_access, level_z.tag());
    try expectStrings("z", level_z.as.field_access.field);

    const level_y = level_z.as.field_access.lhs.*;
    try expect(.field_access, level_y.tag());
    try expectStrings("y", level_y.as.field_access.field);

    const level_x = level_y.as.field_access.lhs.*;
    try expect(.field_access, level_x.tag());
    try expectStrings("x", level_x.as.field_access.field);

    const base_var = level_x.as.field_access.lhs.*;
    try expect(.var_, base_var.tag());
    try expectStrings("p", base_var.as.var_);
}

test "parse true == false" {
    var arena = arena_alloc();
    defer arena.deinit();
    const alloc = arena.allocator();

    const source_code =
        \\ true == false;
    ;
    var lexer = Lexer.init(source_code, "test.zig");
    var parser = Parser.init(&lexer, alloc);
    const expr = try parser.parse();

    try expect(.list, expr.tag());
    try expect(1, expr.as.list.items.len);

    const eql_expr = expr.as.list.items[0];
    try expect(.bool_, eql_expr.tag());
    try expect(.eql, eql_expr.as.bool_.tag());

    try expect(.bool_, eql_expr.as.bool_.eql.lhs.tag());
    try expect(.constant, eql_expr.as.bool_.eql.lhs.as.bool_.tag());
    try expect(true, eql_expr.as.bool_.eql.lhs.as.bool_.constant);

    try expect(.bool_, eql_expr.as.bool_.eql.rhs.tag());
    try expect(.constant, eql_expr.as.bool_.eql.rhs.as.bool_.tag());
    try expect(false, eql_expr.as.bool_.eql.rhs.as.bool_.constant);
}

test "parse float addition" {
    var arena = arena_alloc();
    defer arena.deinit();
    const alloc = arena.allocator();

    const source_code =
        \\ 123.45 + 0.0;
    ;
    var lexer = Lexer.init(source_code, "test.zig");
    var parser = Parser.init(&lexer, alloc);
    const expr = try parser.parse();

    try expect(.list, expr.tag());
    try expect(1, expr.as.list.items.len);

    const plus_expr = expr.as.list.items[0];
    try expect(.arith, plus_expr.tag());
    try expect(.plus, plus_expr.as.arith.tag());

    const lhs = plus_expr.as.arith.plus.lhs;
    try expect(.arith, lhs.tag());
    try expect(.float, lhs.as.arith.tag());
    try expect(123.45, lhs.as.arith.float);

    const rhs = plus_expr.as.arith.plus.rhs;
    try expect(.arith, rhs.tag());
    try expect(.float, rhs.as.arith.tag());
    try expect(0.0, rhs.as.arith.float);
}

test "parse float division" {
    var arena = arena_alloc();
    defer arena.deinit();
    const alloc = arena.allocator();

    const source_code =
        \\ 123.45 / 2.0;
    ;
    var lexer = Lexer.init(source_code, "test.zig");
    var parser = Parser.init(&lexer, alloc);
    const expr = try parser.parse();

    try expect(.list, expr.tag());
    try expect(1, expr.as.list.items.len);

    const plus_expr = expr.as.list.items[0];
    try expect(.arith, plus_expr.tag());
    try expect(.div, plus_expr.as.arith.tag());

    const lhs = plus_expr.as.arith.div.lhs;
    try expect(.arith, lhs.tag());
    try expect(.float, lhs.as.arith.tag());
    try expect(123.45, lhs.as.arith.float);

    const rhs = plus_expr.as.arith.div.rhs;
    try expect(.arith, rhs.tag());
    try expect(.float, rhs.as.arith.tag());
    try expect(2.0, rhs.as.arith.float);
}
