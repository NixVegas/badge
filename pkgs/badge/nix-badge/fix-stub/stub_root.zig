//! THROWAWAY fetch-less fetchers root: same public surface as root.zig that expr
//! imports, but NO curl_transport / git_transport (no @cImport, no libcurl/libgit2).
const store = @import("store");
const stub_cache = @import("stub_cache.zig");

pub const file_cache = store.file_cache;
pub const fetch = struct {
    pub const types = @import("fetch/types.zig");
    pub const config = @import("fetch/config.zig");
};
pub const forge = @import("forge.zig");
pub const nar = store.nar;

pub const FileCache = store.FileCache;
pub const FetchService = stub_cache.FetchCache;
pub const FetchConfig = fetch.config.Config;
pub const GitSpec = fetch.types.GitSpec;
pub const UrlSpec = fetch.types.UrlSpec;
pub const TarballSpec = fetch.types.TarballSpec;
pub const MercurialSpec = fetch.types.MercurialSpec;
