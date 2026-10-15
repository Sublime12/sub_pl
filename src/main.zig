const std = @import("std");
const parser_pkg = @import("parser.zig");
const lexer_pkg = @import("lexer.zig");
const expression_pkg = @import("expression.zig");
const sema_pkg = @import("sema.zig");
const eval_pkg = @import("eval.zig");

const ArenaAllocator = std.heap.ArenaAllocator;

const Lexer = lexer_pkg.Lexer;
const FnExpr = expression_pkg.FnExpr;
const BoolExpr = expression_pkg.BoolExpr;
const Expr = expression_pkg.Expr;
const IfExpr = expression_pkg.IfExpr;
const Parser = parser_pkg.Parser;
const Vars = eval_pkg.Vars;
const EvalMode = eval_pkg.EvalMode;

const assert = std.debug.assert;
const print = std.debug.print;
const eql = std.ascii.eqlIgnoreCase;
const eval_with_mode = eval_pkg.eval_with_mode;
const build_context = sema_pkg.build_context;
const sema = sema_pkg.sema;
const expect = std.testing.expectEqual;

const Args = struct {
    eval_mode: EvalMode = .iterative,
    file_path: ?[]const u8 = null,
};

pub fn main(init: std.process.Init) !void {
    const alloc = std.heap.page_allocator;
    const io = init.io;

    const args = try init.minimal.args.toSlice(alloc);

    var parsed_args: Args = .{};

    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--rec-eval")) {
            parsed_args.eval_mode = .recursive;
        } else if (std.mem.eql(u8, arg, "--iter-eval")) {
            parsed_args.eval_mode = .iterative;
        } else {
            parsed_args.file_path = arg;
        }
    }

    const file_path = parsed_args.file_path orelse {
        print("Usage: sub_pl [--iter-eval|--rec-eval] <file_path>\n", .{});
        return;
    };

    const file = try std.Io.Dir.cwd().openFile(io, file_path, .{});
    defer file.close(io);

    const MAX_SIZE = 1024 * 1024;

    var file_reader = file.reader(io, &.{});
    const source_code = try file_reader.interface.allocRemaining(alloc, .limited(MAX_SIZE));
    defer alloc.free(source_code);

    var lexer = Lexer.init(source_code, file_path);

    var parser = Parser.init(&lexer, alloc);
    const expr = try parser.parse();

    {
        var print_expr: bool = false;
        print_expr = false;
        if (print_expr) expr.print();
    }

    var local_vars: Vars = .init(alloc);
    defer local_vars.deinit();

    const ctx = try build_context(expr, alloc, source_code, file_path, io);
    sema(expr, ctx);

    _ = eval_with_mode(expr, ctx, &local_vars, parsed_args.eval_mode);
    print("\n", .{});
}

test {
    std.testing.refAllDecls(@This());
}
