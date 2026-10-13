//! Offline flash provenance and frozen bytes. No device access or subprocesses.
const std = @import("std");
const firmware = @import("firmware.zig");
const target = @import("target_lock.zig");
const preparation = @import("preparation.zig");
pub const Digest = firmware.Digest;
pub const tools_name = "flash-tools.zon";
pub const picotool_revision = "d8df33801dbea792128baaab516291720d400a91";
pub const picotool_package_hash = "picotool-2.3.1-PtJrRaJNAAA3xRwGctKAdomuKCJXz5UwMOrhzQ_Z2f-e";
pub const Record = struct {
    version: u16 = 1,
    wrapper_contract_version: u16 = 1,
    picotool_dependency_revision: []const u8 = picotool_revision,
    picotool_dependency_hash: []const u8 = picotool_package_hash,
    firmware_repository: []const u8 = target.repository,
    firmware_revision: []const u8,
    firmware_source_digest: Digest,
    source_kind: @FieldType(target.Lock, "source_kind"),
    wrapper_path: []const u8,
    wrapper_hash: Digest,
    picotool_path: []const u8,
    picotool_hash: Digest,

    pub fn validate(self: Record) !void {
        if (self.version != 1) return error.UnsupportedToolsVersion;
        if (self.wrapper_contract_version != 1) return error.UnsupportedWrapperContract;
        if (!std.mem.eql(u8, self.picotool_dependency_revision, picotool_revision) or !std.mem.eql(u8, self.picotool_dependency_hash, picotool_package_hash)) return error.UnsupportedPicotoolDependency;
        if (!std.mem.eql(u8, self.firmware_repository, target.repository)) return error.UnsupportedFirmwareRepository;
        if (self.firmware_revision.len != 40) return error.InvalidFirmwareRevision;
        for (self.firmware_revision) |c| if (!std.ascii.isDigit(c) and (c < 'a' or c > 'f')) return error.InvalidFirmwareRevision;
        try path(self.wrapper_path);
        try path(self.picotool_path);
        if (std.mem.eql(u8, self.wrapper_path, self.picotool_path)) return error.AliasedFlashTools;
    }
};
fn path(value: []const u8) !void {
    if (!std.fs.path.isAbsolute(value) or std.mem.indexOfScalar(u8, value, 0) != null) return error.InvalidFlashPath;
}
fn fileHash(gpa: std.mem.Allocator, io: std.Io, filename: []const u8) !Digest {
    try path(filename);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, filename, gpa, .limited(128 * 1024 * 1024));
    defer gpa.free(bytes);
    if (bytes.len == 0) return error.EmptyFlashTool;
    return firmware.digest(bytes);
}
pub const Tools = struct {
    arena: std.heap.ArenaAllocator,
    record: Record,

    pub fn capture(gpa: std.mem.Allocator, io: std.Io, revision: []const u8, source_digest: Digest, source_kind: @FieldType(target.Lock, "source_kind"), wrapper: []const u8, picotool: []const u8) !Tools {
        const record: Record = .{ .firmware_revision = revision, .firmware_source_digest = source_digest, .source_kind = source_kind, .wrapper_path = wrapper, .wrapper_hash = try fileHash(gpa, io, wrapper), .picotool_path = picotool, .picotool_hash = try fileHash(gpa, io, picotool) };
        return clone(gpa, record);
    }
    pub fn clone(gpa: std.mem.Allocator, record: Record) !Tools {
        try record.validate();
        var arena: std.heap.ArenaAllocator = .init(gpa);
        errdefer arena.deinit();
        var owned = record;
        inline for (.{ "firmware_repository", "firmware_revision", "wrapper_path", "picotool_path", "picotool_dependency_revision", "picotool_dependency_hash" }) |name| @field(owned, name) = try arena.allocator().dupe(u8, @field(record, name));
        return .{ .arena = arena, .record = owned };
    }
    pub fn validate(self: Tools) !void {
        try self.record.validate();
    }
    pub fn verify(self: Tools, gpa: std.mem.Allocator, io: std.Io) !void {
        try self.validate();
        if (!std.mem.eql(u8, &self.record.wrapper_hash, &try fileHash(gpa, io, self.record.wrapper_path))) return error.WrapperChanged;
        if (!std.mem.eql(u8, &self.record.picotool_hash, &try fileHash(gpa, io, self.record.picotool_path))) return error.PicotoolChanged;
    }
    pub fn serialize(self: Tools, gpa: std.mem.Allocator) ![]u8 {
        try self.validate();
        var writer: std.Io.Writer.Allocating = .init(gpa);
        errdefer writer.deinit();
        try std.zon.stringify.serializeMaxDepth(self.record, .{}, &writer.writer, 8);
        return writer.toOwnedSlice();
    }
    pub fn parse(gpa: std.mem.Allocator, bytes: []const u8) !Tools {
        if (bytes.len > 16 * 1024) return error.ToolsRecordTooLarge;
        var arena: std.heap.ArenaAllocator = .init(gpa);
        errdefer arena.deinit();
        const text = try arena.allocator().dupeSentinel(u8, bytes, 0);
        const record = try @import("owned-zon").parse(Record, arena.allocator(), text);
        try record.validate();
        return .{ .arena = arena, .record = record };
    }
    pub fn deinit(self: *Tools) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const Request = struct {
    captured: Digest,
    current: Digest,
    cancelled: bool = false,
    pub fn validate(self: Request) !void {
        if (self.cancelled) return error.FlashCancelled;
        if (!std.mem.eql(u8, &self.captured, &self.current)) return error.StaleFlashRequest;
    }
};
pub const Frozen = struct {
    tools: Tools,
    path: []const u8,
    build_key: Digest,
    uf2_hash: Digest,
    uf2_size: usize,

    /// Recheck frozen bytes and installed tools immediately before dispatch.
    pub fn verify(self: Frozen, gpa: std.mem.Allocator, io: std.Io, current: firmware.Inputs, request: Request) !void {
        try request.validate();
        if (!std.mem.eql(u8, &self.build_key, &firmware.key(current))) return error.StaleBuild;
        try self.tools.verify(gpa, io);
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, self.path, gpa, .limited(4 * 1024 * 1024));
        defer gpa.free(bytes);
        if (bytes.len != self.uf2_size or !std.mem.eql(u8, &self.uf2_hash, &firmware.digest(bytes))) return error.ArtifactChanged;
        try @import("firmware-uf2").validate(gpa, bytes);
    }
    pub fn deinit(self: *Frozen) void {
        self.tools.deinit();
        self.* = undefined;
    }
};

/// Caller serializes cache writers and supplies the absolute path belonging to
/// cache. Content-addressed atomic creation preserves corrupt entries for review.
pub fn freeze(gpa: std.mem.Allocator, io: std.Io, cache: std.Io.Dir, cache_path: []const u8, manifest: firmware.Manifest, current: firmware.Inputs, tools: Tools, request: Request) !Frozen {
    try request.validate();
    try path(cache_path);
    const actual_cache_path = try cache.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(actual_cache_path);
    if (!std.mem.eql(u8, actual_cache_path, cache_path)) return error.CachePathMismatch;
    try tools.verify(gpa, io);
    if (!std.mem.eql(u8, tools.record.firmware_revision, manifest.inputs.lock.firmware_revision)) return error.ToolsRevisionMismatch;
    if (tools.record.source_kind != manifest.inputs.lock.source_kind or !std.mem.eql(u8, &tools.record.firmware_source_digest, &manifest.inputs.lock.firmware_source_digest)) return error.ToolsSourceMismatch;
    // Reparse the record to reject unsupported or manually altered manifests.
    const encoded = try manifest.serialize(gpa);
    defer gpa.free(encoded);
    var validated = try firmware.Manifest.parse(gpa, encoded);
    defer validated.deinit();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, validated.uf2_path, gpa, .limited(4 * 1024 * 1024));
    defer gpa.free(bytes);
    try validated.verify(gpa, current, bytes);
    var owned = try Tools.clone(gpa, tools.record);
    errdefer owned.deinit();
    const name = std.fmt.bytesToHex(validated.uf2_hash, .lower);
    const frozen_path = try std.fs.path.join(owned.arena.allocator(), &.{ cache_path, &name });
    try preparation.importBlob(gpa, io, cache, validated.uf2_hash, bytes);
    const frozen: Frozen = .{ .tools = owned, .path = frozen_path, .build_key = validated.build_key, .uf2_hash = validated.uf2_hash, .uf2_size = validated.uf2_size };
    try frozen.verify(gpa, io, current, request);
    return frozen;
}

fn fixtureUf2() [512]u8 {
    var bytes: [512]u8 = @splat(0);
    for ([_]struct { usize, u32 }{ .{ 0, 0x0a324655 }, .{ 4, 0x9e5d5157 }, .{ 8, 0x2000 }, .{ 12, 0x10000000 }, .{ 16, 256 }, .{ 24, 1 }, .{ 28, 0xe48bff56 }, .{ 508, 0x0ab16f30 } }) |word| std.mem.writeInt(u32, bytes[word[0]..][0..4], word[1], .little);
    return bytes;
}
test "tools provenance and frozen artifact reject edits stale requests and cancellation" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(base);
    const wrapper = try std.fs.path.join(gpa, &.{ base, "wrapper" });
    defer gpa.free(wrapper);
    const picotool = try std.fs.path.join(gpa, &.{ base, "picotool" });
    defer gpa.free(picotool);
    const artifact = try std.fs.path.join(gpa, &.{ base, "build.uf2" });
    defer gpa.free(artifact);
    try tmp.dir.writeFile(io, .{ .sub_path = "wrapper", .data = "wrapper bytes" });
    try tmp.dir.writeFile(io, .{ .sub_path = "picotool", .data = "picotool bytes" });
    const lock = target.fixture();
    var tools = try Tools.capture(gpa, io, lock.firmware_revision, lock.firmware_source_digest, lock.source_kind, wrapper, picotool);
    defer tools.deinit();
    const encoded = try tools.serialize(gpa);
    defer gpa.free(encoded);
    var parsed = try Tools.parse(gpa, encoded);
    defer parsed.deinit();
    try parsed.verify(gpa, io);
    var unsupported = parsed.record;
    unsupported.wrapper_contract_version = 2;
    try std.testing.expectError(error.UnsupportedWrapperContract, unsupported.validate());
    unsupported = parsed.record;
    unsupported.picotool_dependency_revision = "main";
    try std.testing.expectError(error.UnsupportedPicotoolDependency, unsupported.validate());
    const input: firmware.Inputs = .{ .project_digest = @splat(1), .source_digest = @splat(2), .build_inputs_digest = @splat(3), .profile_id = @splat(4), .identity_digest = @splat(5), .lock = lock };
    const bytes = fixtureUf2();
    try tmp.dir.writeFile(io, .{ .sub_path = "build.uf2", .data = &bytes });
    var manifest = try firmware.Manifest.complete(gpa, .succeeded, firmware.key(input), input, input, artifact, &bytes);
    defer manifest.deinit();
    const request: Request = .{ .captured = @splat(1), .current = @splat(1) };
    var frozen = try freeze(gpa, io, tmp.dir, base, manifest, input, parsed, request);
    defer frozen.deinit();
    try frozen.verify(gpa, io, input, request);
    try std.testing.expectError(error.CachePathMismatch, freeze(gpa, io, tmp.dir, "/missing-flash-cache", manifest, input, parsed, request));
    var other_cache = try tmp.dir.createDirPathOpen(io, "other-cache", .{});
    defer other_cache.close(io);
    const other_path = try other_cache.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(other_path);
    const blob_name = std.fmt.bytesToHex(manifest.uf2_hash, .lower);
    try other_cache.writeFile(io, .{ .sub_path = &blob_name, .data = &bytes });
    try std.testing.expectError(error.CachePathMismatch, freeze(gpa, io, tmp.dir, other_path, manifest, input, parsed, request));
    var wrong_revision = try Tools.clone(gpa, parsed.record);
    defer wrong_revision.deinit();
    wrong_revision.record.firmware_revision = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    try std.testing.expectError(error.ToolsRevisionMismatch, freeze(gpa, io, tmp.dir, base, manifest, input, wrong_revision, request));
    try tmp.dir.writeFile(io, .{ .sub_path = "build.uf2", .data = "changed build output" });
    try frozen.verify(gpa, io, input, request);
    try std.testing.expectError(error.ArtifactChanged, freeze(gpa, io, tmp.dir, base, manifest, input, parsed, request));
    try std.testing.expectError(error.FlashCancelled, frozen.verify(gpa, io, input, .{ .captured = @splat(1), .current = @splat(1), .cancelled = true }));
    try std.testing.expectError(error.StaleFlashRequest, frozen.verify(gpa, io, input, .{ .captured = @splat(1), .current = @splat(2) }));
    var stale = input;
    stale.project_digest[0] ^= 1;
    try std.testing.expectError(error.StaleBuild, frozen.verify(gpa, io, stale, request));
    try tmp.dir.writeFile(io, .{ .sub_path = "wrapper", .data = "changed wrapper" });
    try std.testing.expectError(error.WrapperChanged, frozen.verify(gpa, io, input, request));
    try tmp.dir.writeFile(io, .{ .sub_path = "wrapper", .data = "wrapper bytes" });
    try tmp.dir.writeFile(io, .{ .sub_path = "picotool", .data = "changed picotool" });
    try std.testing.expectError(error.PicotoolChanged, frozen.verify(gpa, io, input, request));
}
