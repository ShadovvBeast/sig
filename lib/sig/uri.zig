//! URI parser — re-exports from sig.http.
//!
//! The URI parser is implemented in `lib/sig/http.zig`. This module
//! provides a convenience re-export so users can `@import("sig_uri")`
//! directly.

const http = @import("http.zig");

pub const Uri = http.Uri;
pub const parseUri = http.parseUri;
