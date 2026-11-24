//! Per-request data passed through middleware and into extractors.
//! Holds data only; no business logic.

const std = @import("std");
const Request = @import("Request.zig");
const path = @import("path.zig");

request: Request,
/// Freed after the response is written. Nothing allocated here may outlive
/// the request.
arena: std.mem.Allocator,
io: std.Io,
/// Filled by the router when a route matches. Already percent-decoded.
params: path.Params = .{},
/// The router's app state. Read it through the `State(T)` extractor.
state: ?*anyopaque = null,
