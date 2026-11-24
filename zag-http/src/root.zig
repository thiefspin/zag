//! Zag: an HTTP framework for Zig. Plain-function handlers, typed extractors,
//! middleware layers, and an HTTP client. This file only re-exports the public API.

const extract = @import("extract.zig");
const serve_impl = @import("serve.zig");

pub const serve = serve_impl.serve;
pub const ServeOptions = serve_impl.ServeOptions;

pub const Router = @import("router.zig").Router;
pub const Context = @import("Context.zig");
pub const Request = @import("Request.zig");
pub const Response = @import("Response.zig");

pub const ExtractError = extract.Error;
pub const Path = extract.Path;
pub const Query = extract.Query;
pub const Json = extract.Json;
pub const State = extract.State;
pub const Headers = extract.Headers;
pub const Body = extract.Body;

/// HTTP client for calling other services. See `Client.zig`.
pub const Client = @import("client/Client.zig");

pub const middleware = @import("middleware.zig");
pub const testing = @import("testing.zig");

test {
    _ = @import("path.zig");
    _ = @import("fields.zig");
    _ = @import("respond.zig");
    _ = @import("Request.zig");
    _ = @import("Response.zig");
    _ = @import("client/url.zig");
    _ = @import("client/retry.zig");
    _ = @import("client/body.zig");
    _ = @import("client/Client.zig");
    _ = @import("tests.zig");
    _ = @import("client/tests.zig");
}
