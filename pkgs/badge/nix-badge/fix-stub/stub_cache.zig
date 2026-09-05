//! THROWAWAY fetch-less FetchService: same public type surface + method
//! signatures as fetch_cache.FetchCache, but no libcurl/libgit2. Every network
//! fetch returns error.FetchUnsupported. Proves expr compiles+links without the
//! curl/git C closure (badge has no network fetch needs).
const std = @import("std");
const store = @import("store");
const base = @import("base");
const BlockingPool = base.BlockingPool;
const fetch_types = @import("fetch/types.zig");
const fetch_config = @import("fetch/config.zig");
const FileCache = store.FileCache;

pub const FetchCache = struct {
    allocator: std.mem.Allocator,

    pub const Forge = fetch_types.Forge;
    pub const GitSpec = fetch_types.GitSpec;
    pub const UrlSpec = fetch_types.UrlSpec;
    pub const TarballSpec = fetch_types.TarballSpec;
    pub const MercurialSpec = fetch_types.MercurialSpec;
    pub const Reporter = fetch_types.Reporter;
    pub const UrlResult = fetch_types.UrlResult;
    pub const TarballResult = fetch_types.TarballResult;
    pub const ForgeMetadata = fetch_types.ForgeMetadata;
    pub const GitResult = fetch_types.GitResult;
    pub const MercurialResult = fetch_types.MercurialResult;
    pub const Config = fetch_config.Config;

    pub fn init(allocator: std.mem.Allocator, config: Config) !FetchCache {
        _ = config;
        return .{ .allocator = allocator };
    }
    pub fn deinit(self: *FetchCache) void {
        _ = self;
    }

    pub fn setNetrc(_: *FetchCache, _: []const u8) !void {}
    pub fn setIo(_: *FetchCache, _: std.Io) void {}
    pub fn setEnvironment(_: *FetchCache, _: *const std.process.Environ.Map) !void {}
    pub fn setAccessTokens(_: *FetchCache, _: []const u8) !void {}
    pub fn setMaxConnections(_: *FetchCache, _: u32) !void {}
    pub fn setDownloadAttempts(_: *FetchCache, _: u32) void {}
    pub fn setTarballTtl(_: *FetchCache, _: u32) void {}
    pub fn setConnectTimeout(_: *FetchCache, _: u32) void {}
    pub fn setStalledDownloadTimeout(_: *FetchCache, _: u32) void {}
    pub fn setDownloadSpeed(_: *FetchCache, _: u64) void {}
    pub fn setSslCertFile(_: *FetchCache, _: []const u8) !void {}
    pub fn setFlakeRegistryUrl(_: *FetchCache, _: ?[]const u8) !void {}
    pub fn setCacheRoot(_: *FetchCache, _: []const u8) !void {}

    pub fn globalRegistrySpec(_: *const FetchCache) ?UrlSpec {
        return null;
    }
    pub fn globalRegistryPath(_: *const FetchCache) ?[]const u8 {
        return null;
    }
    pub fn blockingPool(_: *FetchCache) ?*BlockingPool {
        return null;
    }

    pub fn fetchGit(_: *FetchCache, _: *FileCache, _: GitSpec, _: ?Reporter) !GitResult {
        return error.FetchUnsupported;
    }
    pub fn fetchUrl(_: *FetchCache, _: *FileCache, _: UrlSpec, _: ?Reporter) !UrlResult {
        return error.FetchUnsupported;
    }
    pub fn fetchTarball(_: *FetchCache, _: *FileCache, _: TarballSpec, _: ?Reporter) !TarballResult {
        return error.FetchUnsupported;
    }
    pub fn fetchMercurial(_: *FetchCache, _: *FileCache, _: MercurialSpec, _: ?Reporter) !MercurialResult {
        return error.FetchUnsupported;
    }
};
