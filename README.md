# Auto Config Headerr
Adds the ability for compile checks (e.g. header exists or function exists) to the config header of the zig build system.

## Usage
Add this package as a dependency in your `build.zig.zon`, then you can use it as followed:
```zig
const std = @import("std");
const AutoConfigHeaderStep = @import("autoconfigheader").AutoConfigHeaderStep;

pub fn build(b: *std.Build) void {
    // ...
    const config_step = AutoConfigHeaderStep.create(b, target, .{ .style = .{ .cmake = b.path("config.h.in") } });

    // access for non compile checked values
    config_step.config_header.addValues(.{
        .SIZEOF_OFF_T = 4,
        .SIZEOF_SIZE_T = 8,
    });

    // check if a header exists
    config_step.addHaveHeader("HAVE_STRINGS_H", "strings.h");

    // check if a function exists
    config_step.addHaveFunction("HAVE_STRCASECMP", "strcasecmp(NULL, NULL)", &.{"strings.h"});
    // ...

    // add the config header to your executable or library
    exe.addConfigHeader(config_step.config_header);
}
```