const std = @import("std");

const eval_pkg = @import("eval.zig");
const lexer_pkg = @import("lexer.zig");

const Cursor = lexer_pkg.Cursor;
const Lexer = lexer_pkg.Lexer;
const Vars = eval_pkg.Vars;

const FnExprTag = enum { fn_std, fn_binding };

const panic = std.debug.panic;

pub const FnExpr = struct {
    const Self = @This();

    name: []const u8,
    args: std.ArrayList([]const u8),
    body: FnBody,

    pub fn print(self: Self) void {
        std.debug.print("let {s} = fn ", .{self.name});
        for (self.args.items) |arg| {
            std.debug.print("{s} ", .{arg});
        }
        std.debug.print(" -> ", .{});
        switch (self.body) {
            .fn_binding => std.debug.print("binding:  ...", .{}),
            .fn_std => |fn_std| fn_std.print(),
        }
    }
};

pub const BindExpr = struct {
    const Self = @This();

    id: []const u8,
    body: *Expr,
    closure: *Expr,

    pub fn print(self: Self) void {
        std.debug.print("bind {s} = ", .{self.id});
        self.body.print();
        std.debug.print(" in (", .{});
        self.closure.print();
        std.debug.print(")", .{});
    }
};

pub const FnBody = union(FnExprTag) {
    const Self = @This();
    fn_std: FnStdExpr,
    fn_binding: FnBindingExpr,

    pub fn init(body: *const Expr) FnExpr {
        return .{ .fn_std = FnStdExpr.init(body) };
    }

    pub fn print(self: Self) void {
        self.fn_std.print();
    }
};

pub const Context = struct {
    cursor: Cursor,
    content: []const u8,
    file_path: []const u8,
    io: std.Io,
    alloc: std.mem.Allocator,
};

pub const FnBindingExpr = struct {
    fn_: *const fn (args: *Vars, call_ctx: Context) Expr,
};

pub const FnStdExpr = struct {
    const Self = @This();

    body: *const Expr,

    pub fn init(body: *const Expr) FnStdExpr {
        return .{
            .body = body,
        };
    }

    pub fn print(self: Self) void {
        self.body.print();
    }
};

pub const ExprTag = enum {
    if_,
    arith,
    bool_,
    fn_call,
    fn_def,
    var_,
    bind,
    list,
    struct_,
    struct_instance,
    field_access,
    str,
    void_,
};

pub const Expr = struct {
    const Self = @This();

    as: ExprAs,
    cursor: Cursor,
    content: []const u8,
    file_path: []const u8,

    pub fn create_if(
        eval: *Expr,
        then: *Expr,
        elseif_evals: std.ArrayList(Expr),
        elseif_thens: std.ArrayList(Expr),
        else_: *Expr,
        l: *const Lexer,
    ) Expr {
        return .{
            .as = .{
                .if_ = .{
                    .eval = eval,
                    .then = then,
                    .elseif_evals = elseif_evals,
                    .elseif_thens = elseif_thens,
                    .else_ = else_,
                },
            },
            .cursor = l.previous_cursor,
            .content = l.content,
            .file_path = l.file_path,
        };
    }

    pub fn create_bind(
        id: []const u8,
        body: *Expr,
        closure: *Expr,
        l: *const Lexer,
    ) Expr {
        return .{
            .as = .{ .bind = .{
                .id = id,
                .body = body,
                .closure = closure,
            } },
            .cursor = l.previous_cursor,
            .content = l.content,
            .file_path = l.file_path,
        };
    }

    pub fn create_struct(
        name: []const u8,
        fields: std.ArrayList([]const u8),
        l: *const Lexer,
    ) Expr {
        return .{
            .as = .{ .struct_ = .{
                .name = name,
                .fields = fields,
            } },
            .cursor = l.previous_cursor,
            .content = l.content,
            .file_path = l.file_path,
        };
    }

    pub fn create_struct_instance(
        name: []const u8,
        fields: std.StringHashMapUnmanaged(Expr),
        l: *const Lexer,
    ) Expr {
        return .{
            .as = .{ .struct_instance = .{ .name = name, .fields = fields } },
            .cursor = l.previous_cursor,
            .content = l.content,
            .file_path = l.file_path,
        };
    }

    pub fn create_fn_call(
        name: []const u8,
        args: std.ArrayList(Expr),
        l: *const Lexer,
    ) Expr {
        return .{
            .as = .{ .fn_call = .{ .name = name, .args = args } },
            .cursor = l.previous_cursor,
            .content = l.content,
            .file_path = l.file_path,
        };
    }

    pub fn create_arith(op: ArithExpr, l: *const Lexer) Expr {
        return .{
            .as = .{ .arith = op },
            .cursor = l.previous_cursor,
            .content = l.content,
            .file_path = l.file_path,
        };
    }

    pub fn create_str(str: []const u8, l: *const Lexer) Expr {
        return .{
            .as = .{ .str = str },
            .cursor = l.previous_cursor,
            .content = l.content,
            .file_path = l.file_path,
        };
    }

    pub fn create_bool(op: BoolExpr, l: *const Lexer) Expr {
        return .{
            .as = .{ .bool_ = op },
            .cursor = l.previous_cursor,
            .content = l.content,
            .file_path = l.file_path,
        };
    }

    pub fn create_list(program: std.ArrayList(Expr), l: *const Lexer) Expr {
        return .{
            .as = .{ .list = program },
            .cursor = l.cursor,
            .content = l.content,
            .file_path = l.file_path,
        };
    }

    pub fn create_fn_def(fn_expr: FnExpr, l: *const Lexer) Expr {
        return .{
            .as = .{ .fn_def = fn_expr },
            .cursor = l.previous_cursor,
            .content = l.content,
            .file_path = l.file_path,
        };
    }

    pub fn create_var(name: []const u8, l: *const Lexer) Expr {
        return .{
            .as = .{ .var_ = name },
            .cursor = l.previous_cursor,
            .content = l.content,
            .file_path = l.file_path,
        };
    }

    pub fn create_field_access(
        lhs_dot: *Expr,
        field: []const u8,
        l: *const Lexer,
    ) Expr {
        return .{
            .as = .{ .field_access = .{
                .lhs = lhs_dot,
                .field = field,
            } },
            .cursor = l.previous_cursor,
            .content = l.content,
            .file_path = l.file_path,
        };
    }

    pub fn is_int(self: Self) bool {
        if (self.tag() != .arith) return false;
        return self.as.arith.tag() == .int;
    }

    pub fn is_str(self: Self) bool {
        return self.tag() == .str;
    }

    pub fn is_bool(self: Self) bool {
        if (self.tag() != .bool_) return false;
        return self.as.bool_.tag() == .constant;
    }

    pub fn is_struct_instance(self: Self) bool {
        return self.tag() == .struct_instance;
    }

    pub fn is_void(self: Self) bool {
        return self.tag() == .void_;
    }

    pub fn print(self: Self) void {
        switch (self.as) {
            .if_ => |expr| expr.print(),
            .arith => |expr| expr.print(),
            .bool_ => |expr| expr.print(),
            .fn_call => |expr| expr.print(),
            .fn_def => |expr| expr.print(),
            .var_ => |expr| std.debug.print("{s}", .{expr}),
            .struct_instance => |expr| expr.print(),
            .field_access => |expr| expr.print(),
            .list => |expr| {
                for (expr.items) |el| {
                    el.print();
                    std.debug.print("; \n", .{});
                }
            },
            .void_ => std.debug.print("void", .{}),
            .str => |expr| std.debug.print("{s}", .{expr}),
            .struct_ => |expr| expr.print(),
            .bind => |expr| expr.print(),
        }
    }

    pub fn tag(self: Self) ExprTag {
        return @as(ExprTag, self.as);
    }
};

const ExprAs = union(ExprTag) {
    const Self = @This();

    if_: IfExpr,
    arith: ArithExpr,
    bool_: BoolExpr,
    fn_call: FnCallExpr,
    fn_def: FnExpr,
    var_: []const u8,
    bind: BindExpr,
    list: std.ArrayList(Expr),
    struct_: StructExpr,
    struct_instance: StructInstanceExpr,
    field_access: FieldAccessExpr,
    str: []const u8,
    void_: void,
};

pub const StructExpr = struct {
    const Self = @This();

    name: []const u8,
    fields: std.ArrayList([]const u8),

    pub fn print(self: Self) void {
        std.debug.print("struct {s}{{", .{self.name});
        for (self.fields.items) |field| {
            std.debug.print(" {s},", .{field});
        }
        std.debug.print(" }}", .{});
    }
};

pub const StructInstanceExpr = struct {
    const Self = @This();
    name: []const u8,
    fields: std.StringHashMapUnmanaged(Expr),

    pub fn print(self: Self) void {
        std.debug.print("@{s}{{ ", .{self.name});
        var it = self.fields.iterator();
        while (it.next()) |value| {
            std.debug.print(".{s} = ", .{value.key_ptr.*});
            value.value_ptr.print();
            std.debug.print(", ", .{});
        }
        std.debug.print("}}", .{});
    }
};

pub const FieldAccessExpr = struct {
    const Self = @This();

    lhs: *Expr,
    field: []const u8,

    pub fn print(self: Self) void {
        std.debug.print("(", .{});
        self.lhs.print();
        std.debug.print(".{s})", .{self.field});
    }
};

pub const ArgsExpr = std.ArrayList(Expr);

pub const FnCallExpr = struct {
    const Self = @This();

    name: []const u8,
    args: ArgsExpr,

    pub fn print(self: Self) void {
        std.debug.print("{s} (", .{self.name});
        for (self.args.items) |arg| {
            std.debug.print(" ", .{});
            arg.print();
            std.debug.print(",", .{});
        }
        std.debug.print(")", .{});
    }
};

pub const IfExpr = struct {
    const Self = @This();

    eval: *Expr,
    then: *Expr,

    elseif_evals: std.ArrayList(Expr),
    elseif_thens: std.ArrayList(Expr),

    else_: *Expr,

    pub fn print(self: Self) void {
        std.debug.print("if (", .{});
        self.eval.print();
        std.debug.print(") ", .{});
        self.then.print();
        std.debug.print("\n", .{});
        std.debug.assert(self.elseif_evals.items.len == self.elseif_thens.items.len);
        for (self.elseif_evals.items, self.elseif_thens.items) |eval, then| {
            std.debug.print("elseif (", .{});
            eval.print();
            std.debug.print(") ", .{});
            then.print();
            std.debug.print("\n", .{});
        }

        std.debug.print("else ", .{});
        self.else_.print();
    }
};

const ArithTag = enum {
    prod,
    div,
    minus,
    plus,
    int,
    float,
};

pub const ArithExpr = union(ArithTag) {
    const Self = @This();

    prod: BinOp,
    div: BinOp,
    minus: BinOp,
    plus: BinOp,
    int: i32,
    float: f32,

    pub fn print(self: Self) void {
        switch (self) {
            .prod => |expr| expr.print("*"),
            .div => |expr| expr.print("/"),
            .minus => |expr| expr.print("-"),
            .plus => |expr| expr.print("+"),
            .int => |expr| std.debug.print("{}", .{expr}),
            .float => |expr| std.debug.print("{}", .{expr}),
        }
    }

    pub fn tag(self: Self) ArithTag {
        return @as(ArithTag, self);
    }
};

pub const BinOp = struct {
    const Self = @This();
    lhs: *Expr,
    rhs: *Expr,

    pub fn print(self: Self, str: []const u8) void {
        std.debug.print("(", .{});
        self.lhs.print();
        std.debug.print(" {s} ", .{str});
        self.rhs.print();

        std.debug.print(")", .{});
    }
};

pub const BinCmpExpr = struct {
    const Self = @This();

    lhs: *const Expr,
    rhs: *const Expr,

    pub fn print(self: Self, op: []const u8) void {
        self.lhs.print();
        std.debug.print(" {s} ", .{op});
        self.rhs.print();
    }
};

const BoolTag = enum {
    constant,
    eql,
    gt,
    ge,
    lt,
    le,
    and_,
    or_,
};

pub const BoolExpr = union(BoolTag) {
    const Self = @This();

    constant: bool,
    eql: BinCmpExpr,
    gt: BinCmpExpr,
    ge: BinCmpExpr,
    lt: BinCmpExpr,
    le: BinCmpExpr,
    and_: BinCmpExpr,
    or_: BinCmpExpr,

    pub fn tag(self: Self) BoolTag {
        return @as(BoolTag, self);
    }

    pub fn print(self: Self) void {
        switch (self) {
            .constant => |expr| std.debug.print("{}", .{expr}),
            .eql => |expr| {
                expr.print("==");
            },
            .gt => |expr| {
                expr.print("<");
                std.debug.print(")", .{});
            },
            .ge => |expr| {
                expr.print(">=");
                std.debug.print(")", .{});
            },
            .lt => |expr| {
                expr.print(">");
                std.debug.print(")", .{});
            },
            .le => |expr| {
                expr.print(">=");
                std.debug.print(")", .{});
            },
            .and_ => |expr| {
                expr.print("and");
                std.debug.print(")", .{});
            },
            .or_ => |expr| {
                expr.print("or");
                std.debug.print(")", .{});
            },
        }
    }
};
