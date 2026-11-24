//! Turns handler return values and errors into a `Response`.

const std = @import("std");
const Context = @import("Context.zig");
const Response = @import("Response.zig");

const log = std.log.scoped(.zag);

/// The kinds of value a handler may return.
pub const Kind = enum { no_content, response, status, text, custom };

/// Classifies a return type, or returns null if it can't be a response.
pub fn kindOf(comptime T: type) ?Kind {
    if (T == void) return .no_content;
    if (T == Response) return .response;
    if (T == std.http.Status) return .status;
    if (isString(T)) return .text;
    if (hasToResponse(T)) return .custom;
    return null;
}

/// Converts a handler's (non-error) return value into a response.
/// The type must already have been checked with `kindOf`.
pub fn into(ctx: *Context, value: anytype) anyerror!Response {
    return switch (comptime kindOf(@TypeOf(value)).?) {
        .no_content => .empty(.no_content),
        .response => value,
        .status => .empty(value),
        .text => .text(value),
        .custom => value.toResponse(ctx),
    };
}

/// Maps an error to a response. Known errors become 4xx; anything else is
/// logged and becomes a bare 500 so no internals leak to the client.
pub fn fromError(err: anyerror) Response {
    const status: std.http.Status = switch (err) {
        error.MissingParam, error.InvalidParam, error.MalformedBody => .bad_request,
        error.UnsupportedMediaType => .unsupported_media_type,
        error.PayloadTooLarge => .payload_too_large,
        error.NotFound => .not_found,
        error.Unauthorized => .unauthorized,
        error.Forbidden => .forbidden,
        // From zag.Client: the service we called failed or timed out.
        error.UpstreamStatus, error.UpstreamUnavailable, error.UpstreamInvalidResponse, error.ResponseTooLarge => .bad_gateway,
        error.Timeout => .gateway_timeout,
        // From zag-pg. Other database errors (QueryFailed, …) stay 500s.
        error.UniqueViolation, error.ForeignKeyViolation => .conflict,
        error.ConstraintViolation => .unprocessable_entity,
        error.SerializationFailure, error.PoolTimeout => .service_unavailable,
        error.QueryTimeout => .gateway_timeout,
        // The server is shutting down; nothing went wrong in the handler.
        error.Canceled => .service_unavailable,
        else => {
            log.err("request failed: {s}", .{@errorName(err)});
            return .empty(.internal_server_error);
        },
    };
    return .empty(status);
}

fn isString(comptime T: type) bool {
    if (T == []const u8 or T == []u8) return true;
    const info = @typeInfo(T);
    if (info != .pointer or info.pointer.size != .one) return false;
    const child = @typeInfo(info.pointer.child);
    return child == .array and child.array.child == u8;
}

fn hasToResponse(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum" => @hasDecl(T, "toResponse"),
        else => false,
    };
}

test kindOf {
    try std.testing.expectEqual(Kind.text, kindOf(@TypeOf("literal")).?);
    try std.testing.expectEqual(Kind.text, kindOf([]const u8).?);
    try std.testing.expectEqual(Kind.status, kindOf(std.http.Status).?);
    try std.testing.expectEqual(Kind.no_content, kindOf(void).?);
    try std.testing.expectEqual(null, kindOf(u32));
}

test fromError {
    try std.testing.expectEqual(.bad_request, fromError(error.InvalidParam).status);
    try std.testing.expectEqual(.not_found, fromError(error.NotFound).status);
    try std.testing.expectEqual(.bad_gateway, fromError(error.UpstreamStatus).status);
    try std.testing.expectEqual(.gateway_timeout, fromError(error.Timeout).status);
    try std.testing.expectEqual(.conflict, fromError(error.UniqueViolation).status);
    try std.testing.expectEqual(.unprocessable_entity, fromError(error.ConstraintViolation).status);
    try std.testing.expectEqual(.gateway_timeout, fromError(error.QueryTimeout).status);
}
