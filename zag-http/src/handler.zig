//! Turns a user handler into a uniform `fn (*Context) Response` at comptime.
//!
//! This is the only file that inspects handler signatures. It runs each
//! parameter's `extract`, calls the handler, and converts the result.

const std = @import("std");
const Context = @import("Context.zig");
const Response = @import("Response.zig");
const respond = @import("respond.zig");
const Handler = @import("middleware.zig").Handler;

/// Wraps `func` so it can be stored in a route table. `State` is the router's
/// state type; `label` (e.g. "GET /users/:id") is used in compile errors.
pub fn erase(comptime State: type, comptime label: []const u8, comptime func: anytype) Handler {
    const Fn = @TypeOf(func);
    comptime check(State, label, Fn);
    return struct {
        fn call(ctx: *Context) Response {
            return invoke(ctx) catch |err| respond.fromError(err);
        }

        fn invoke(ctx: *Context) anyerror!Response {
            var args: std.meta.ArgsTuple(Fn) = undefined;
            inline for (@typeInfo(Fn).@"fn".param_types, 0..) |Param, i| {
                args[i] = try extractOne(Param.?, ctx);
            }
            const result = @call(.auto, func, args);
            const value = if (comptime isErrorUnion(Fn)) try result else result;
            return respond.into(ctx, value);
        }
    }.call;
}

fn extractOne(comptime T: type, ctx: *Context) !T {
    if (T == *Context) return ctx;
    return T.extract(ctx);
}

fn check(comptime State: type, comptime label: []const u8, comptime Fn: type) void {
    const prefix = "handler for '" ++ label ++ "': ";
    if (@typeInfo(Fn) != .@"fn") {
        @compileError(prefix ++ "expected a function, found '" ++ @typeName(Fn) ++ "'");
    }
    const info = @typeInfo(Fn).@"fn";
    if (info.is_generic) {
        @compileError(prefix ++ "generic handlers are not supported; give every parameter a concrete type");
    }
    for (info.param_types, 1..) |Param, n| {
        checkParam(State, prefix ++ std.fmt.comptimePrint("parameter {d} ", .{n}), Param.?);
    }
    const Payload = returnPayload(Fn);
    if (respond.kindOf(Payload) == null) @compileError(
        prefix ++ "return type '" ++ @typeName(Payload) ++
            "' can't be turned into a response; return void, []const u8, std.http.Status, zag.Response, zag.Json(T), or a type with 'toResponse'",
    );
}

fn checkParam(comptime State: type, comptime prefix: []const u8, comptime T: type) void {
    if (T == *Context) return;
    if (!isExtractor(T)) @compileError(
        prefix ++ "has type '" ++ @typeName(T) ++
            "', which is not an extractor; use zag.Path, zag.Query, zag.Json, zag.State, zag.Headers, zag.Body, *zag.Context, or a type with 'extract'",
    );
    if (!@hasDecl(T, "StateType")) return;
    if (State == void) {
        @compileError(prefix ++ "asks for state, but the router has none; create it with zag.Router(YourState)");
    }
    if (T.StateType != State) @compileError(
        prefix ++ "asks for zag.State(" ++ @typeName(T.StateType) ++ "), but the router's state is '" ++ @typeName(State) ++ "'",
    );
}

fn isExtractor(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum" => @hasDecl(T, "extract"),
        else => false,
    };
}

fn isErrorUnion(comptime Fn: type) bool {
    return @typeInfo(@typeInfo(Fn).@"fn".return_type.?) == .error_union;
}

fn returnPayload(comptime Fn: type) type {
    const Return = @typeInfo(Fn).@"fn".return_type.?;
    return switch (@typeInfo(Return)) {
        .error_union => |eu| eu.payload,
        else => Return,
    };
}
