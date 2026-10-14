//! Deliberate acquisition-to-resolution orchestration. Offline is the default.
const std = @import("std");
const jobs = @import("root.zig");
const zon = @import("owned-zon");
pub const Import = struct { package_hash: []const u8, archive: []const u8 };
pub const Plan = struct {
    options: jobs.package_resolution.Options,
    imports: []const Import = &.{},
    allow_network: bool = false,
};
pub const Phase = enum { checking_cache, cached, importing, downloading, verified, missing_archive };
pub const Reporter = struct {
    context: *anyopaque,
    update: *const fn (*anyopaque, []const u8, Phase) void,
    checkpoint: ?*const fn (*anyopaque) anyerror!void = null,
};
const Context = struct {
    gpa: std.mem.Allocator,
    environment: *const std.process.Environ.Map,
    compiler: jobs.toolchain.Receipt,
    cache: std.Io.Dir,
    plan: Plan,
    reporter: ?Reporter,
    compiler_session: ?*const jobs.package_cache.CompilerSession = null,
    fn report(self: *const Context, hash: []const u8, phase: Phase) void {
        if (self.reporter) |reporter| reporter.update(reporter.context, hash, phase);
    }
    fn acquire(pointer: *anyopaque, output: std.mem.Allocator, io: std.Io, hash: []const u8, origin: jobs.package_manifest.Archive) anyerror!jobs.package_cache.Source {
        const self: *Context = @ptrCast(@alignCast(pointer));
        if (self.reporter) |reporter| if (reporter.checkpoint) |check| try check(reporter.context);
        self.report(hash, .checking_cache);
        if (try jobs.package_cache.loadWithAudit(self.gpa, io, self.cache, hash, self.plan.options.audit_packages)) |cached| {
            var owned = cached;
            defer owned.deinit();
            self.report(hash, .cached);
            return zon.clone(output, owned.source);
        }
        var input: ?jobs.package_cache.Input = null;
        for (self.plan.imports) |item| if (std.mem.eql(u8, item.package_hash, hash)) {
            if (input != null) return error.DuplicateOfflinePackageImport;
            input = .{ .offline_archive = item.archive };
        };
        if (input == null) {
            if (!self.plan.allow_network) {
                self.report(hash, .missing_archive);
                return error.OfflinePackageArchiveRequired;
            }
            input = .{ .download = origin.url };
        }
        self.report(hash, if (input.? == .download) .downloading else .importing);
        var acquired = if (self.compiler_session) |session| try session.acquire(self.gpa, io, self.environment, self.cache, hash, input.?) else try jobs.package_cache.acquire(self.gpa, io, self.environment, self.compiler, self.cache, hash, input.?);
        defer acquired.deinit();
        if (self.reporter) |reporter| if (reporter.checkpoint) |check| try check(reporter.context);
        self.report(hash, .verified);
        return zon.clone(output, acquired.source);
    }
};
pub fn prepare(gpa: std.mem.Allocator, io: std.Io, environment: *const std.process.Environ.Map, compiler: jobs.toolchain.Receipt, cache: std.Io.Dir, plan: Plan) !jobs.package_resolution.Owned {
    return prepareReported(gpa, io, environment, compiler, cache, plan, null);
}
pub fn prepareReported(gpa: std.mem.Allocator, io: std.Io, environment: *const std.process.Environ.Map, compiler: jobs.toolchain.Receipt, cache: std.Io.Dir, plan: Plan, reporter: ?Reporter) !jobs.package_resolution.Owned {
    return prepareWithSession(gpa, io, environment, compiler, cache, plan, reporter, null);
}
pub fn prepareWithSession(gpa: std.mem.Allocator, io: std.Io, environment: *const std.process.Environ.Map, compiler: jobs.toolchain.Receipt, cache: std.Io.Dir, plan: Plan, reporter: ?Reporter, session: ?*const jobs.package_cache.CompilerSession) !jobs.package_resolution.Owned {
    if (session) |admitted| {
        const expected = try compiler.serialize(gpa);
        defer gpa.free(expected);
        const actual = try admitted.receipt.serialize(gpa);
        defer gpa.free(actual);
        if (!std.mem.eql(u8, expected, actual)) return error.ToolchainReceiptMismatch;
        try admitted.check(io);
    }
    const cache_path = try cache.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(cache_path);
    var selected = plan;
    if (selected.options.cache_directory) |directory| {
        const actual = try std.Io.Dir.realPathFileAbsoluteAlloc(io, directory, gpa);
        defer gpa.free(actual);
        if (!std.mem.eql(u8, actual, cache_path)) return error.PreparedPackageCacheMismatch;
    }
    selected.options.cache_directory = cache_path;
    for (selected.imports, 0..) |item, index| {
        try jobs.build_provenance.validatePackageHash(item.package_hash);
        if (!std.fs.path.isAbsolute(item.archive)) return error.AbsolutePackagePathRequired;
        for (selected.imports[0..index]) |prior| if (std.mem.eql(u8, prior.package_hash, item.package_hash)) return error.DuplicateOfflinePackageImport;
    }
    var context = Context{ .gpa = gpa, .environment = environment, .compiler = compiler, .cache = cache, .plan = selected, .reporter = reporter, .compiler_session = session };
    return jobs.package_resolution.prepare(gpa, io, selected.options, .{ .context = &context, .acquire = Context.acquire });
}
