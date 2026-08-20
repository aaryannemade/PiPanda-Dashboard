//! pipanda — auxiliary dashboard for a Bambu Lab P1S.
//!
//! This module is the reusable core. The CLI in `src/main.zig` is one consumer;
//! the HTTP dashboard and the camera/timelapse pipeline will be others.

const std = @import("std");

pub const log = @import("log.zig");

pub const cloud = @import("bambu/cloud.zig");
pub const credentials = @import("bambu/credentials.zig");
pub const printer = @import("bambu/printer.zig");
pub const status = @import("bambu/status.zig");
pub const api = @import("api.zig");
pub const homeassistant = @import("homeassistant.zig");
pub const makerworld = @import("makerworld.zig");

pub const mqtt = @import("net/mqtt.zig");
pub const tls_stream = @import("net/tls_stream.zig");

test {
    _ = log;
    _ = cloud;
    _ = credentials;
    _ = printer;
    _ = status;
    _ = api;
    _ = homeassistant;
    _ = makerworld;
    _ = mqtt;
    _ = tls_stream;
}
