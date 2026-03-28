//! Sig — Strict Zig standard library.
//!
//! A capacity-first, caller-provided-buffer standard library layer
//! that sits alongside `@import("std")`.

pub const errors = @import("errors.zig");
pub const SigError = errors.SigError;

pub const fmt = @import("fmt.zig");
pub const io = @import("io.zig");
pub const containers = @import("containers.zig");
pub const string = @import("string.zig");
pub const parse = @import("parse.zig");
pub const http = @import("http.zig");
pub const fs = @import("fs.zig");
pub const compress = @import("compress.zig");
pub const tar = @import("tar.zig");
pub const zip = @import("zip.zig");
pub const zon = @import("zon.zig");
pub const uri = @import("uri.zig");
pub const json = @import("json.zig");
