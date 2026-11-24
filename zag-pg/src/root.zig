//! zag-pg: a PostgreSQL client for Zig. See technical_spec.md.

pub const Config = @import("Config.zig");
pub const Pool = @import("Pool.zig");
pub const Conn = @import("Conn.zig");
pub const Tx = @import("Tx.zig");
pub const Json = @import("params.zig").Json;
pub const QueryError = @import("errors.zig").QueryError;
pub const Diagnostics = @import("errors.zig").Diagnostics;
pub const DecodeError = @import("rows.zig").DecodeError;

test {
    _ = @import("protocol.zig");
    _ = @import("scram.zig");
    _ = @import("errors.zig");
    _ = @import("params.zig");
    _ = @import("rows.zig");
    _ = @import("Config.zig");
    _ = @import("Conn.zig");
    _ = @import("Result.zig");
    _ = @import("tests.zig");
}
