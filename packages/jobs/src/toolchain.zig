//! Explicit toolchain selection and receipts. Reads/verification never fetch data.
const std = @import("std");
const firmware = @import("firmware.zig");
const provenance = @import("build_provenance.zig");
const preparation = @import("preparation.zig");
const zon = @import("owned-zon");
pub const native_host = @import("runner_artifact.zig").native_target;
pub const Kind = @import("target_lock.zig").CompilerKind;
pub const Selection = struct {
    kind: Kind = .selected_installation,
    compiler: []const u8,
    distribution: []const u8,
    expected_compiler: ?firmware.Digest = null,
    expected_tree: ?firmware.Digest = null,
    bundle: ?[]const u8 = null,
    expected_bundle: ?firmware.Digest = null,
};
pub const Receipt = struct {
    version: u16 = 1,
    kind: Kind,
    zig_version: []const u8 = "0.17.0",
    host: []const u8 = native_host,
    compiler: []const u8,
    distribution: []const u8,
    compiler_digest: firmware.Digest,
    tree_digest: firmware.Digest,
    bundle: ?[]const u8 = null,
    bundle_digest: ?firmware.Digest = null,
    pub fn validate(self: Receipt) !void {
        if (self.version != 1) return error.UnsupportedToolchainReceipt;
        if (!std.mem.eql(u8, self.zig_version, "0.17.0")) return error.UnsupportedCompilerVersion;
        if (!std.mem.eql(u8, self.host, native_host)) return error.ToolchainHostMismatch;
        try inside(self.compiler, self.distribution);
        if ((self.kind == .checked_bundle) != (self.bundle != null and self.bundle_digest != null)) return error.InvalidToolchainBundle;
        if (self.kind == .selected_installation and (self.bundle != null or self.bundle_digest != null)) return error.InvalidToolchainBundle;
        if (self.bundle) |path| try absolute(path);
    }
    pub fn serialize(self: Receipt, gpa: std.mem.Allocator) ![]u8 {
        try self.validate();
        var writer: std.Io.Writer.Allocating = .init(gpa);
        errdefer writer.deinit();
        try std.zon.stringify.serializeMaxDepth(self, .{}, &writer.writer, 8);
        return writer.toOwnedSlice();
    }
    pub fn parse(gpa: std.mem.Allocator, bytes: []const u8) !Receipt {
        if (bytes.len > 32 * 1024) return error.ToolchainReceiptTooLarge;
        const text = try gpa.dupeSentinel(u8, bytes, 0);
        defer gpa.free(text);
        const receipt = try zon.parse(Receipt, gpa, text);
        errdefer zon.free(gpa, receipt);
        try receipt.validate();
        return receipt;
    }
    pub fn deinit(self: Receipt, gpa: std.mem.Allocator) void {
        zon.free(gpa, self);
    }
    /// Recheck all selected bytes without executing the compiler.
    pub fn verify(self: Receipt, gpa: std.mem.Allocator, io: std.Io) !void {
        try self.validate();
        try same(try hashFile(gpa, io, self.compiler), self.compiler_digest, error.CompilerDigestMismatch);
        try same(try provenance.compilerTreeDigest(gpa, io, self.distribution), self.tree_digest, error.CompilerDistributionChanged);
        if (self.bundle) |path| try same(try hashFile(gpa, io, path), self.bundle_digest.?, error.BundleDigestMismatch);
    }
    /// The returned lock borrows the caller's non-compiler strings; capture
    /// copies them before a build. Installation identity has no archive hash.
    pub fn targetLock(self: Receipt, gpa: std.mem.Allocator, base: @import("target_lock.zig").Lock) !@import("target_lock.zig").Lock {
        const bytes = try self.serialize(gpa);
        defer gpa.free(bytes);
        var lock = base;
        lock.version = @import("target_lock.zig").compiler_origin_version;
        lock.compiler_kind = self.kind;
        lock.compiler_digest = self.compiler_digest;
        lock.compiler_bundle_digest = self.bundle_digest orelse @splat(0);
        lock.compiler_tree_digest = self.tree_digest;
        lock.toolchain_receipt_digest = firmware.digest(bytes);
        try lock.validate();
        return lock;
    }
};
pub const Owned = struct {
    arena: std.heap.ArenaAllocator,
    receipt: Receipt,
    pub fn deinit(self: *Owned) void {
        self.arena.deinit();
        self.* = undefined;
    }
};
fn absolute(path: []const u8) !void {
    if (!std.fs.path.isAbsolute(path) or std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidToolchainPath;
}
fn inside(compiler: []const u8, root: []const u8) !void {
    try absolute(compiler);
    try absolute(root);
    if (root.len < 2 or compiler.len <= root.len + 1 or !std.mem.startsWith(u8, compiler, root) or !std.fs.path.isSep(compiler[root.len])) return error.CompilerOutsideDistribution;
    var parts = std.mem.tokenizeAny(u8, compiler[root.len + 1 ..], "/\\");
    while (parts.next()) |part| if (std.mem.eql(u8, part, "..") or std.mem.eql(u8, part, ".")) return error.InvalidToolchainPath;
}
fn hashFile(gpa: std.mem.Allocator, io: std.Io, path: []const u8) !firmware.Digest {
    try absolute(path);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(512 * 1024 * 1024));
    defer gpa.free(bytes);
    return firmware.digest(bytes);
}
fn same(actual: firmware.Digest, expected: firmware.Digest, failure: anyerror) !void {
    if (!std.mem.eql(u8, &actual, &expected)) return failure;
}
/// Only this deliberate preparation executes the already byte-checked compiler's
/// bounded version command. It does not download, extract or run build scripts.
pub fn prepare(gpa: std.mem.Allocator, io: std.Io, selection: Selection) !Owned {
    try absolute(selection.compiler);
    try absolute(selection.distribution);
    if (selection.kind == .selected_installation and (selection.bundle != null or selection.expected_bundle != null)) return error.InvalidToolchainBundle;
    if (selection.kind == .checked_bundle and (selection.bundle == null or selection.expected_bundle == null)) return error.InvalidToolchainBundle;
    const compiler = try std.Io.Dir.realPathFileAbsoluteAlloc(io, selection.compiler, gpa);
    defer gpa.free(compiler);
    const distribution = try std.Io.Dir.realPathFileAbsoluteAlloc(io, selection.distribution, gpa);
    defer gpa.free(distribution);
    try inside(compiler, distribution);
    const executable = try hashFile(gpa, io, compiler);
    if (selection.expected_compiler) |expected| try same(executable, expected, error.CompilerDigestMismatch);
    const tree = try provenance.compilerTreeDigest(gpa, io, distribution);
    if (selection.expected_tree) |expected| try same(tree, expected, error.CompilerDistributionChanged);
    var bundle_digest: ?firmware.Digest = null;
    if (selection.bundle) |path| {
        bundle_digest = try hashFile(gpa, io, path);
        try same(bundle_digest.?, selection.expected_bundle.?, error.BundleDigestMismatch);
    }
    try preparation.verifyCompiler(gpa, io, compiler, executable);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const receipt = try zon.clone(arena.allocator(), Receipt{
        .kind = selection.kind,
        .compiler = compiler,
        .distribution = distribution,
        .compiler_digest = executable,
        .tree_digest = tree,
        .bundle = selection.bundle,
        .bundle_digest = bundle_digest,
    });
    try receipt.verify(gpa, io);
    return .{ .arena = arena, .receipt = receipt };
}
pub const filename = "toolchain-receipt.zon";
pub fn save(gpa: std.mem.Allocator, io: std.Io, directory: std.Io.Dir, receipt: Receipt) !void {
    const old = directory.readFileAlloc(io, filename, gpa, .limited(32 * 1024)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    if (old) |bytes| {
        defer gpa.free(bytes);
        const parsed = try Receipt.parse(gpa, bytes);
        defer parsed.deinit(gpa);
    }
    const bytes = try receipt.serialize(gpa);
    defer gpa.free(bytes);
    var atomic = try directory.createFileAtomic(io, filename, .{ .replace = true });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, bytes);
    try atomic.replace(io);
}
