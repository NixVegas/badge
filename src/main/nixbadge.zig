const std = @import("std");
const esp_idf = @import("esp-idf");

pub const std_options = esp_idf.std_options;
pub const panic = esp_idf.panic;

pub const app = @import("nixbadge/app.zig");
pub const http = @import("nixbadge/http.zig");
pub const mesh = @import("nixbadge/mesh.zig");
pub const leds = @import("nixbadge/leds.zig");
pub const utils = @import("utils.zig");

comptime {
    _ = &app.app_main;
}
