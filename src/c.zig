const std = @import("std");
pub const c = @cImport({
    @cInclude("nng/nng.h");
    @cInclude("nng/protocol/reqrep0/req.h");
    @cInclude("nng/protocol/reqrep0/rep.h");
    @cInclude("nng/protocol/pair1/pair.h");

    @cInclude("nng/supplemental/util/platform.h");
});
