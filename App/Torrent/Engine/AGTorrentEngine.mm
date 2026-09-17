#import "AGTorrentEngine.h"

#include <libtorrent/add_torrent_params.hpp>
#include <libtorrent/alert_types.hpp>
#include <libtorrent/announce_entry.hpp>
#include <libtorrent/bencode.hpp>
#include <libtorrent/create_torrent.hpp>
#include <libtorrent/download_priority.hpp>
#include <libtorrent/fingerprint.hpp>
#include <libtorrent/error_code.hpp>
#include <libtorrent/magnet_uri.hpp>
#include <libtorrent/read_resume_data.hpp>
#include <libtorrent/session.hpp>
#include <libtorrent/session_stats.hpp>
#include <libtorrent/settings_pack.hpp>
#include <libtorrent/torrent_flags.hpp>
#include <libtorrent/torrent_handle.hpp>
#include <libtorrent/torrent_info.hpp>
#include <libtorrent/torrent_status.hpp>
#include <libtorrent/write_resume_data.hpp>

#include <memory>
#include <string>
#include <vector>

namespace lt = libtorrent;

static NSString *const AGTorrentErrorDomain = @"com.uhmmu.AnimeGod.torrent";

/// Community tracker snapshot injected into tasks that arrive with few
/// trackers, as magnet-crawler did. DHT and PEX cover the rest.
static NSArray<NSString *> *AGDefaultTrackers(void) {
    return @[
        @"udp://tracker.opentrackr.org:1337/announce",
        @"udp://open.stealth.si:80/announce",
        @"udp://tracker.torrent.eu.org:451/announce",
        @"udp://exodus.desync.com:6969/announce",
        @"udp://open.demonii.com:1337/announce",
        @"udp://tracker.dler.org:6969/announce",
        @"udp://explodie.org:6969/announce",
        @"http://nyaa.tracker.wf:7777/announce",
        @"https://tracker.anibt.net/announce",
        @"http://open.acgnxtracker.com:80/announce"
    ];
}

static NSString *AGHexFromHash(lt::sha1_hash const &hash) {
    static char const *digits = "0123456789abcdef";
    char buffer[41];
    for (int index = 0; index < 20; ++index) {
        auto const byte = static_cast<unsigned char>(hash[index]);
        buffer[index * 2] = digits[byte >> 4];
        buffer[index * 2 + 1] = digits[byte & 0x0F];
    }
    buffer[40] = '\0';
    return [NSString stringWithUTF8String:buffer];
}

/// Parses 40 hex digits into a v1 info hash. Returns NO for anything else.
static BOOL AGHashFromHex(NSString *hex, lt::sha1_hash &out) {
    if (hex.length != 40) { return NO; }
    char const *text = hex.UTF8String;
    for (int index = 0; index < 20; ++index) {
        int value = 0;
        for (int nibble = 0; nibble < 2; ++nibble) {
            char const character = text[index * 2 + nibble];
            int digit;
            if (character >= '0' && character <= '9') { digit = character - '0'; }
            else if (character >= 'a' && character <= 'f') { digit = character - 'a' + 10; }
            else if (character >= 'A' && character <= 'F') { digit = character - 'A' + 10; }
            else { return NO; }
            value = (value << 4) | digit;
        }
        out[index] = static_cast<char>(value);
    }
    return YES;
}

static NSString *AGHexFromHandle(lt::torrent_handle const &handle) {
    return AGHexFromHash(handle.info_hashes().get_best());
}

// MARK: - Value types

// The public headers expose these as read-only; the engine fills them in
// through these private read-write redeclarations.
@interface AGTorrentSnapshot ()
@property (nonatomic, copy) NSString *infoHash;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *savePath;
@property (nonatomic) AGTorrentState state;
@property (nonatomic) double progress;
@property (nonatomic) int64_t totalBytes;
@property (nonatomic) int64_t downloadedBytes;
@property (nonatomic) int64_t uploadedBytes;
@property (nonatomic) int downloadRate;
@property (nonatomic) int uploadRate;
@property (nonatomic) int connectedPeers;
@property (nonatomic) int connectedSeeds;
@property (nonatomic) int totalPeers;
@property (nonatomic) int totalSeeds;
@property (nonatomic) BOOL sequential;
@property (nonatomic) BOOL hasMetadata;
@property (nonatomic, copy, nullable) NSString *errorMessage;
@property (nonatomic) double estimatedSecondsRemaining;
@end

@implementation AGTorrentSnapshot
@end

@interface AGTorrentFileEntry ()
@property (nonatomic) NSInteger index;
@property (nonatomic, copy) NSString *path;
@property (nonatomic) int64_t length;
@property (nonatomic) int64_t downloadedBytes;
@property (nonatomic) BOOL wanted;
@end

@implementation AGTorrentFileEntry
@end

@interface AGTorrentSessionInfo ()
@property (nonatomic) BOOL isRunning;
@property (nonatomic) int dhtNodes;
@property (nonatomic) int listenPort;
@property (nonatomic, nullable) NSNumber *portMapped;
@property (nonatomic, copy, nullable) NSString *portMapDetail;
@property (nonatomic, copy, nullable) NSString *listenError;
@property (nonatomic) int alertCount;
@property (nonatomic) int downloadRate;
@property (nonatomic) int uploadRate;
@end

@implementation AGTorrentSessionInfo
@end

// MARK: - Engine

@implementation AGTorrentEngine {
    std::unique_ptr<lt::session> _session;
    NSURL *_stateDirectory;
    dispatch_queue_t _alertQueue;
    dispatch_source_t _alertTimer;
    dispatch_source_t _maintenanceTimer;
    BOOL _stopped;
    int _listenPort;
    int _dhtNodes;
    int _dhtNodesMetricIndex;
    int _statsTick;
    int _alertCount;
    NSNumber *_portMapped;
    NSString *_portMapDetail;
    NSString *_listenError;
    NSString *_lastAlertMessage;
    NSString *_startupError;
}

@synthesize startupError = _startupError;

- (instancetype)initWithStateDirectory:(NSURL *)stateDirectory
                            listenPort:(int)listenPort
                             preferTCP:(BOOL)preferTCP {
    self = [super init];
    if (!self) { return nil; }
    _stateDirectory = stateDirectory;
    _listenPort = listenPort;
    _dhtNodes = 0;
    _alertQueue = dispatch_queue_create("com.uhmmu.AnimeGod.torrent.alerts", DISPATCH_QUEUE_SERIAL);
    [NSFileManager.defaultManager createDirectoryAtURL:stateDirectory
                           withIntermediateDirectories:YES
                                            attributes:nil
                                                 error:nil];
    try {
        [self startSessionPreferringTCP:preferTCP];
        [self loadPersistedTasks];
        [self startTimers];
    } catch (std::exception const &error) {
        _session.reset();
        _startupError = [NSString stringWithUTF8String:error.what()];
    }
    return self;
}

- (void)startSessionPreferringTCP:(BOOL)preferTCP {
    lt::settings_pack pack;
    // Listen on both stacks: IPv6 reaches peers behind CGNAT, which UK and
    // mobile broadband use widely.
    pack.set_str(lt::settings_pack::listen_interfaces,
                 std::string("0.0.0.0:") + std::to_string(_listenPort) + ",[::]:" + std::to_string(_listenPort));
    pack.set_bool(lt::settings_pack::enable_dht, true);
    pack.set_bool(lt::settings_pack::enable_lsd, true);
    pack.set_bool(lt::settings_pack::enable_upnp, true);
    pack.set_bool(lt::settings_pack::enable_natpmp, true);
    pack.set_bool(lt::settings_pack::enable_outgoing_tcp, true);
    pack.set_bool(lt::settings_pack::enable_outgoing_utp, true);
    pack.set_bool(lt::settings_pack::enable_incoming_tcp, true);
    pack.set_bool(lt::settings_pack::enable_incoming_utp, true);
    // A single default bootstrap node leaves DHT dead when it is unreachable.
    pack.set_str(lt::settings_pack::dht_bootstrap_nodes,
                 "dht.libtorrent.org:25401,router.bittorrent.com:6881,"
                 "router.utorrent.com:6881,dht.transmissionbt.com:6881");
    pack.set_int(lt::settings_pack::connections_limit, 800);
    pack.set_int(lt::settings_pack::active_downloads, 8);
    pack.set_int(lt::settings_pack::active_seeds, 8);
    pack.set_int(lt::settings_pack::active_limit, 16);
    pack.set_int(lt::settings_pack::alert_queue_size, 5000);
    // Announcing to only the first working tracker misses most of the swarm
    // for anime releases, which list many trackers.
    pack.set_bool(lt::settings_pack::announce_to_all_trackers, true);
    pack.set_bool(lt::settings_pack::announce_to_all_tiers, true);
    pack.set_int(lt::settings_pack::mixed_mode_algorithm,
                 preferTCP ? lt::settings_pack::prefer_tcp : lt::settings_pack::peer_proportional);
    // Encryption enabled (not forced): networks that shape BitTorrent still
    // work, and peers that only speak plaintext are not lost.
    pack.set_int(lt::settings_pack::out_enc_policy, lt::settings_pack::pe_enabled);
    pack.set_int(lt::settings_pack::in_enc_policy, lt::settings_pack::pe_enabled);
    pack.set_int(lt::settings_pack::allowed_enc_level, lt::settings_pack::pe_both);
    pack.set_int(lt::settings_pack::connection_speed, 100);
    pack.set_int(lt::settings_pack::max_queued_disk_bytes, 16 * 1024 * 1024);
    pack.set_str(lt::settings_pack::user_agent, "AnimeGod/0.1 libtorrent/2.0");
    pack.set_str(lt::settings_pack::peer_fingerprint, lt::generate_fingerprint("AG", 0, 1, 0, 0));
    int alertMask = lt::alert_category::error
        | lt::alert_category::status
        | lt::alert_category::storage
        | lt::alert_category::port_mapping;
    if ([NSProcessInfo.processInfo.environment[@"AG_TORRENT_LOG"] isEqualToString:@"1"]) {
        alertMask |= lt::alert_category::dht | lt::alert_category::tracker | lt::alert_category::peer;
    }
    pack.set_int(lt::settings_pack::alert_mask, alertMask);

    _session = std::make_unique<lt::session>(lt::session_params(pack));
    _dhtNodesMetricIndex = lt::find_metric_idx("dht.dht_nodes");
}

/// Resume every task the previous run left behind. Resume data carries the
/// save path, so downloads continue exactly where they were.
- (void)loadPersistedTasks {
    NSArray<NSURL *> *files = [NSFileManager.defaultManager
        contentsOfDirectoryAtURL:_stateDirectory
      includingPropertiesForKeys:nil
                         options:NSDirectoryEnumerationSkipsHiddenFiles
                           error:nil];
    for (NSURL *url in files) {
        if (![url.pathExtension isEqualToString:@"resume"]) { continue; }
        NSData *data = [NSData dataWithContentsOfURL:url];
        if (data.length == 0) { continue; }
        lt::error_code ec;
        lt::add_torrent_params params = lt::read_resume_data(
            {static_cast<char const *>(data.bytes), static_cast<long>(data.length)}, ec);
        if (ec) { continue; }
        // A `.torrent` saved beside the resume file restores metadata
        // without asking the swarm for it again.
        NSURL *metadataURL = [[url URLByDeletingPathExtension] URLByAppendingPathExtension:@"torrent"];
        NSData *metadata = [NSData dataWithContentsOfURL:metadataURL];
        if (metadata.length > 0) {
            lt::error_code metadataError;
            auto info = std::make_shared<lt::torrent_info>(
                static_cast<char const *>(metadata.bytes), static_cast<int>(metadata.length), metadataError);
            if (!metadataError) { params.ti = info; }
        }
        _session->async_add_torrent(std::move(params));
    }
}

- (void)startTimers {
    __weak AGTorrentEngine *weakSelf = self;
    _alertTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _alertQueue);
    dispatch_source_set_timer(_alertTimer, dispatch_time(DISPATCH_TIME_NOW, 0),
                              (uint64_t)(0.5 * NSEC_PER_SEC), (uint64_t)(0.1 * NSEC_PER_SEC));
    dispatch_source_set_event_handler(_alertTimer, ^{ [weakSelf drainAlerts]; });
    dispatch_resume(_alertTimer);

    // Periodic resume writes and re-announces: a long download that is
    // force-quit still comes back, and its peer pool keeps refreshing.
    _maintenanceTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _alertQueue);
    dispatch_source_set_timer(_maintenanceTimer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(60 * NSEC_PER_SEC)),
                              (uint64_t)(60 * NSEC_PER_SEC), (uint64_t)(5 * NSEC_PER_SEC));
    dispatch_source_set_event_handler(_maintenanceTimer, ^{ [weakSelf runMaintenance]; });
    dispatch_resume(_maintenanceTimer);
}

- (void)runMaintenance {
    if (_stopped || !_session) { return; }
    static int tick = 0;
    tick++;
    _session->post_session_stats();
    for (auto const &handle : _session->get_torrents()) {
        if (!handle.is_valid()) { continue; }
        if (handle.need_save_resume_data()) {
            handle.save_resume_data(lt::torrent_handle::save_info_dict);
        }
        // Every five minutes, like magnet-crawler, to keep widening the pool.
        if (tick % 5 == 0) {
            lt::torrent_status status = handle.status();
            if (status.state == lt::torrent_status::downloading
                || status.state == lt::torrent_status::downloading_metadata) {
                handle.force_reannounce();
            }
        }
    }
}

- (void)drainAlerts {
    if (!_session) { return; }
    // Counters (DHT size) only arrive in response to a request.
    _statsTick++;
    if (_statsTick % 4 == 0) { _session->post_session_stats(); }
    std::vector<lt::alert *> alerts;
    _session->pop_alerts(&alerts);
    _alertCount += static_cast<int>(alerts.size());
    // AG_TORRENT_LOG=1 prints every alert; used by the headless smoke test.
    static BOOL const logAlerts = [NSProcessInfo.processInfo.environment[@"AG_TORRENT_LOG"] isEqualToString:@"1"];
    for (lt::alert *alert : alerts) {
        if (logAlerts) {
            printf("ALERT [%s] %s\n", alert->what(), alert->message().c_str());
            fflush(stdout);
        }
        if (auto *resume = lt::alert_cast<lt::save_resume_data_alert>(alert)) {
            [self writeResumeData:resume];
        } else if (auto *metadata = lt::alert_cast<lt::metadata_received_alert>(alert)) {
            [self writeMetadataForHandle:metadata->handle];
            metadata->handle.save_resume_data(lt::torrent_handle::save_info_dict);
        } else if (auto *stats = lt::alert_cast<lt::session_stats_alert>(alert)) {
            if (_dhtNodesMetricIndex >= 0) {
                _dhtNodes = static_cast<int>(stats->counters()[_dhtNodesMetricIndex]);
            }
        } else if (auto *mapped = lt::alert_cast<lt::portmap_alert>(alert)) {
            _portMapped = @YES;
            _portMapDetail = [NSString stringWithUTF8String:mapped->message().c_str()];
        } else if (auto *mapError = lt::alert_cast<lt::portmap_error_alert>(alert)) {
            if (_portMapped == nil || !_portMapped.boolValue) {
                _portMapped = @NO;
                _portMapDetail = [NSString stringWithUTF8String:mapError->message().c_str()];
            }
        } else if (auto *error = lt::alert_cast<lt::torrent_error_alert>(alert)) {
            _lastAlertMessage = [NSString stringWithUTF8String:error->message().c_str()];
        } else if (auto *listenFailed = lt::alert_cast<lt::listen_failed_alert>(alert)) {
            _listenError = [NSString stringWithUTF8String:listenFailed->message().c_str()];
        } else if (auto *listening = lt::alert_cast<lt::listen_succeeded_alert>(alert)) {
            _listenPort = listening->port;
            _listenError = nil;
        } else if (auto *finished = lt::alert_cast<lt::torrent_finished_alert>(alert)) {
            finished->handle.save_resume_data(lt::torrent_handle::save_info_dict);
        } else if (auto *added = lt::alert_cast<lt::add_torrent_alert>(alert)) {
            if (!added->error && added->handle.is_valid()) {
                [self writeMetadataForHandle:added->handle];
            }
        }
    }
}

- (NSURL *)stateFileForInfoHash:(NSString *)infoHash extension:(NSString *)extension {
    return [[_stateDirectory URLByAppendingPathComponent:infoHash] URLByAppendingPathExtension:extension];
}

- (void)writeResumeData:(lt::save_resume_data_alert *)alert {
    std::vector<char> buffer = lt::write_resume_data_buf(alert->params);
    NSData *data = [NSData dataWithBytes:buffer.data() length:buffer.size()];
    [data writeToURL:[self stateFileForInfoHash:AGHexFromHandle(alert->handle) extension:@"resume"]
          atomically:YES];
}

- (void)writeMetadataForHandle:(lt::torrent_handle const &)handle {
    std::shared_ptr<const lt::torrent_info> info = handle.torrent_file();
    if (!info || !info->is_valid()) { return; }
    lt::create_torrent creator(*info);
    std::vector<char> buffer;
    lt::bencode(std::back_inserter(buffer), creator.generate());
    NSData *data = [NSData dataWithBytes:buffer.data() length:buffer.size()];
    [data writeToURL:[self stateFileForInfoHash:AGHexFromHandle(handle) extension:@"torrent"] atomically:YES];
}

// MARK: - Adding

- (void)applyDefaultsToParams:(lt::add_torrent_params &)params
                     savePath:(NSURL *)savePath
                   sequential:(BOOL)sequential {
    params.save_path = savePath.path.UTF8String;
    if (sequential) { params.flags |= lt::torrent_flags::sequential_download; }
    int tier = 0;
    for (NSString *tracker in AGDefaultTrackers()) {
        params.trackers.push_back(tracker.UTF8String);
        params.tracker_tiers.push_back(tier);
    }
}

- (nullable NSString *)addMagnet:(NSString *)magnetURI
                        savePath:(NSURL *)savePath
                      sequential:(BOOL)sequential
                           error:(NSError **)error {
    if (!_session) {
        if (error) {
            *error = [NSError errorWithDomain:AGTorrentErrorDomain code:1
                                     userInfo:@{NSLocalizedDescriptionKey: self.startupError ?: @"The download engine is not running."}];
        }
        return nil;
    }
    lt::error_code ec;
    lt::add_torrent_params params = lt::parse_magnet_uri(magnetURI.UTF8String, ec);
    if (ec) {
        if (error) {
            *error = [NSError errorWithDomain:AGTorrentErrorDomain code:2
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithUTF8String:ec.message().c_str()]}];
        }
        return nil;
    }
    [self applyDefaultsToParams:params savePath:savePath sequential:sequential];
    lt::torrent_handle handle = _session->add_torrent(std::move(params), ec);
    if (ec || !handle.is_valid()) {
        if (error) {
            *error = [NSError errorWithDomain:AGTorrentErrorDomain code:3
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithUTF8String:ec.message().c_str()]}];
        }
        return nil;
    }
    return AGHexFromHandle(handle);
}

- (nullable NSString *)addTorrentData:(NSData *)data
                             savePath:(NSURL *)savePath
                           sequential:(BOOL)sequential
                                error:(NSError **)error {
    if (!_session) {
        if (error) {
            *error = [NSError errorWithDomain:AGTorrentErrorDomain code:1
                                     userInfo:@{NSLocalizedDescriptionKey: self.startupError ?: @"The download engine is not running."}];
        }
        return nil;
    }
    lt::error_code ec;
    auto info = std::make_shared<lt::torrent_info>(
        static_cast<char const *>(data.bytes), static_cast<int>(data.length), ec);
    if (ec) {
        if (error) {
            *error = [NSError errorWithDomain:AGTorrentErrorDomain code:4
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithUTF8String:ec.message().c_str()]}];
        }
        return nil;
    }
    lt::add_torrent_params params;
    params.ti = info;
    [self applyDefaultsToParams:params savePath:savePath sequential:sequential];
    lt::torrent_handle handle = _session->add_torrent(std::move(params), ec);
    if (ec || !handle.is_valid()) {
        if (error) {
            *error = [NSError errorWithDomain:AGTorrentErrorDomain code:3
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithUTF8String:ec.message().c_str()]}];
        }
        return nil;
    }
    return AGHexFromHandle(handle);
}

- (lt::torrent_handle)handleForInfoHash:(NSString *)infoHash {
    if (!_session) { return lt::torrent_handle(); }
    lt::sha1_hash hash;
    if (!AGHashFromHex(infoHash, hash)) { return lt::torrent_handle(); }
    return _session->find_torrent(hash);
}

- (void)addTrackers:(NSArray<NSString *> *)trackers forInfoHash:(NSString *)infoHash {
    lt::torrent_handle handle = [self handleForInfoHash:infoHash];
    if (!handle.is_valid()) { return; }
    for (NSString *tracker in trackers) {
        handle.add_tracker(lt::announce_entry(tracker.UTF8String));
    }
}

// MARK: - Control

- (void)pause:(NSString *)infoHash {
    lt::torrent_handle handle = [self handleForInfoHash:infoHash];
    if (!handle.is_valid()) { return; }
    handle.unset_flags(lt::torrent_flags::auto_managed);
    handle.pause(lt::torrent_handle::graceful_pause);
    handle.save_resume_data(lt::torrent_handle::save_info_dict);
}

- (void)resume:(NSString *)infoHash {
    lt::torrent_handle handle = [self handleForInfoHash:infoHash];
    if (!handle.is_valid()) { return; }
    handle.set_flags(lt::torrent_flags::auto_managed);
    handle.resume();
    handle.force_reannounce();
}

- (void)remove:(NSString *)infoHash deleteFiles:(BOOL)deleteFiles {
    lt::torrent_handle handle = [self handleForInfoHash:infoHash];
    if (handle.is_valid() && _session) {
        _session->remove_torrent(handle, deleteFiles ? lt::session::delete_files : lt::remove_flags_t{});
    }
    NSFileManager *files = NSFileManager.defaultManager;
    [files removeItemAtURL:[self stateFileForInfoHash:infoHash extension:@"resume"] error:nil];
    [files removeItemAtURL:[self stateFileForInfoHash:infoHash extension:@"torrent"] error:nil];
}

- (void)setSequential:(BOOL)sequential forInfoHash:(NSString *)infoHash {
    lt::torrent_handle handle = [self handleForInfoHash:infoHash];
    if (!handle.is_valid()) { return; }
    if (sequential) {
        handle.set_flags(lt::torrent_flags::sequential_download);
    } else {
        handle.unset_flags(lt::torrent_flags::sequential_download);
    }
}

- (void)forceReannounce:(NSString *)infoHash {
    lt::torrent_handle handle = [self handleForInfoHash:infoHash];
    if (handle.is_valid()) { handle.force_reannounce(); }
}

- (void)setWantedFileIndexes:(NSArray<NSNumber *> *)indexes forInfoHash:(NSString *)infoHash {
    lt::torrent_handle handle = [self handleForInfoHash:infoHash];
    std::shared_ptr<const lt::torrent_info> info = handle.is_valid() ? handle.torrent_file() : nullptr;
    if (!info) { return; }
    std::vector<lt::download_priority_t> priorities(static_cast<size_t>(info->num_files()), lt::dont_download);
    for (NSNumber *index in indexes) {
        int value = index.intValue;
        if (value >= 0 && value < info->num_files()) {
            priorities[static_cast<size_t>(value)] = lt::default_priority;
        }
    }
    handle.prioritize_files(priorities);
}

- (void)prioritiseFileForPlayback:(NSInteger)fileIndex forInfoHash:(NSString *)infoHash {
    lt::torrent_handle handle = [self handleForInfoHash:infoHash];
    std::shared_ptr<const lt::torrent_info> info = handle.is_valid() ? handle.torrent_file() : nullptr;
    if (!info || fileIndex < 0 || fileIndex >= info->num_files()) { return; }
    handle.file_priority(lt::file_index_t{static_cast<int>(fileIndex)}, lt::top_priority);
    // Sequential order plus a head start on the first pieces is what makes
    // a file playable before the rest of the task finishes.
    handle.set_flags(lt::torrent_flags::sequential_download);
    lt::peer_request start = info->map_file(lt::file_index_t{static_cast<int>(fileIndex)}, 0, 1);
    int const leadingPieces = 12;
    for (int offset = 0; offset < leadingPieces; ++offset) {
        lt::piece_index_t piece{static_cast<int>(start.piece) + offset};
        if (static_cast<int>(piece) >= info->num_pieces()) { break; }
        handle.piece_priority(piece, lt::top_priority);
        handle.set_piece_deadline(piece, 1000 * (offset + 1), lt::torrent_handle::alert_when_available);
    }
}

- (void)moveStorage:(NSString *)infoHash toFolder:(NSURL *)folder {
    lt::torrent_handle handle = [self handleForInfoHash:infoHash];
    if (!handle.is_valid()) { return; }
    // dont_replace keeps any file that already exists at the destination,
    // so a half-moved task never overwrites good data with a partial copy.
    handle.move_storage(folder.path.UTF8String, lt::move_flags_t::dont_replace);
    handle.save_resume_data(lt::torrent_handle::save_info_dict);
}

// MARK: - Reading state

- (AGTorrentSnapshot *)snapshotFromStatus:(lt::torrent_status const &)status {
    AGTorrentSnapshot *snapshot = [AGTorrentSnapshot new];
    snapshot.infoHash = AGHexFromHash(status.info_hashes.get_best());
    snapshot.name = status.name.empty() ? @"" : [NSString stringWithUTF8String:status.name.c_str()];
    snapshot.savePath = [NSString stringWithUTF8String:status.save_path.c_str()];
    snapshot.errorMessage = status.errc ? [NSString stringWithUTF8String:status.errc.message().c_str()] : nil;

    bool const paused = static_cast<bool>(status.flags & lt::torrent_flags::paused);
    AGTorrentState state;
    if (status.errc) {
        state = AGTorrentStateErrored;
    } else if (paused) {
        state = AGTorrentStatePaused;
    } else {
        switch (status.state) {
            case lt::torrent_status::checking_files:
            case lt::torrent_status::checking_resume_data: state = AGTorrentStateChecking; break;
            case lt::torrent_status::downloading_metadata: state = AGTorrentStateFetchingMetadata; break;
            case lt::torrent_status::downloading: state = AGTorrentStateDownloading; break;
            case lt::torrent_status::finished: state = AGTorrentStateFinished; break;
            case lt::torrent_status::seeding: state = AGTorrentStateSeeding; break;
            default: state = AGTorrentStateQueued; break;
        }
    }
    snapshot.state = state;
    snapshot.progress = status.total_wanted > 0
        ? static_cast<double>(status.total_wanted_done) / static_cast<double>(status.total_wanted)
        : 0.0;
    snapshot.totalBytes = status.total_wanted;
    snapshot.downloadedBytes = status.total_wanted_done;
    snapshot.uploadedBytes = status.all_time_upload;
    snapshot.downloadRate = status.download_payload_rate;
    snapshot.uploadRate = status.upload_payload_rate;
    snapshot.connectedPeers = status.num_peers;
    snapshot.connectedSeeds = status.num_seeds;
    snapshot.totalPeers = status.list_peers > 0 ? status.list_peers : status.num_incomplete;
    snapshot.totalSeeds = status.num_complete > 0 ? status.num_complete : status.list_seeds;
    snapshot.sequential = static_cast<bool>(status.flags & lt::torrent_flags::sequential_download);
    snapshot.hasMetadata = status.has_metadata;

    int64_t const remaining = status.total_wanted - status.total_wanted_done;
    snapshot.estimatedSecondsRemaining = (status.download_payload_rate > 0 && remaining > 0)
        ? static_cast<double>(remaining) / static_cast<double>(status.download_payload_rate)
        : -1;
    return snapshot;
}

- (NSArray<AGTorrentSnapshot *> *)snapshots {
    if (!_session) { return @[]; }
    std::vector<lt::torrent_status> statuses = _session->get_torrent_status(
        [](lt::torrent_status const &) { return true; });
    NSMutableArray<AGTorrentSnapshot *> *result = [NSMutableArray arrayWithCapacity:statuses.size()];
    for (auto const &status : statuses) {
        [result addObject:[self snapshotFromStatus:status]];
    }
    return result;
}

- (nullable AGTorrentSnapshot *)snapshotForInfoHash:(NSString *)infoHash {
    lt::torrent_handle handle = [self handleForInfoHash:infoHash];
    if (!handle.is_valid()) { return nil; }
    return [self snapshotFromStatus:handle.status()];
}

- (NSArray<AGTorrentFileEntry *> *)filesForInfoHash:(NSString *)infoHash {
    lt::torrent_handle handle = [self handleForInfoHash:infoHash];
    std::shared_ptr<const lt::torrent_info> info = handle.is_valid() ? handle.torrent_file() : nullptr;
    if (!info) { return @[]; }
    std::vector<int64_t> progress;
    handle.file_progress(progress);
    std::vector<lt::download_priority_t> priorities = handle.get_file_priorities();
    lt::file_storage const &storage = info->files();

    NSMutableArray<AGTorrentFileEntry *> *entries = [NSMutableArray arrayWithCapacity:info->num_files()];
    for (int index = 0; index < info->num_files(); ++index) {
        lt::file_index_t const fileIndex{index};
        AGTorrentFileEntry *entry = [AGTorrentFileEntry new];
        entry.index = index;
        entry.path = [NSString stringWithUTF8String:storage.file_path(fileIndex).c_str()];
        entry.length = storage.file_size(fileIndex);
        entry.downloadedBytes = static_cast<size_t>(index) < progress.size() ? progress[static_cast<size_t>(index)] : 0;
        entry.wanted = static_cast<size_t>(index) >= priorities.size()
            || priorities[static_cast<size_t>(index)] != lt::dont_download;
        [entries addObject:entry];
    }
    return entries;
}

- (AGTorrentSessionInfo *)sessionInfo {
    AGTorrentSessionInfo *info = [AGTorrentSessionInfo new];
    info.isRunning = _session != nullptr && !_stopped;
    info.dhtNodes = _dhtNodes;
    info.listenPort = _listenPort;
    info.portMapped = _portMapped;
    info.portMapDetail = _portMapDetail;
    info.listenError = _listenError ?: _lastAlertMessage;
    info.alertCount = _alertCount;
    if (_session) {
        // libtorrent 2.0 dropped session_status; summing the tasks gives the
        // same payload rates the UI shows per task.
        int download = 0, upload = 0;
        for (auto const &status : _session->get_torrent_status([](lt::torrent_status const &) { return true; })) {
            download += status.download_payload_rate;
            upload += status.upload_payload_rate;
        }
        info.downloadRate = download;
        info.uploadRate = upload;
    }
    return info;
}

// MARK: - Creating torrents

+ (nullable NSData *)createTorrentDataForPath:(NSURL *)path error:(NSError **)error {
    try {
        lt::file_storage storage;
        lt::add_files(storage, path.path.UTF8String);
        lt::create_torrent creator(storage, 16 * 1024);
        creator.set_creator("AnimeGod loopback test");
        lt::set_piece_hashes(creator, path.URLByDeletingLastPathComponent.path.UTF8String);
        std::vector<char> buffer;
        lt::bencode(std::back_inserter(buffer), creator.generate());
        return [NSData dataWithBytes:buffer.data() length:buffer.size()];
    } catch (std::exception const &failure) {
        if (error) {
            *error = [NSError errorWithDomain:AGTorrentErrorDomain code:5
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithUTF8String:failure.what()]}];
        }
        return nil;
    }
}

// MARK: - Shutdown

- (void)shutdown {
    if (_stopped || !_session) { return; }
    _stopped = YES;
    if (_alertTimer) { dispatch_source_cancel(_alertTimer); _alertTimer = nil; }
    if (_maintenanceTimer) { dispatch_source_cancel(_maintenanceTimer); _maintenanceTimer = nil; }

    // Ask every task for resume data and wait briefly for the alerts, so a
    // quit mid-download resumes instead of re-checking from scratch.
    int outstanding = 0;
    for (auto const &handle : _session->get_torrents()) {
        if (!handle.is_valid()) { continue; }
        lt::torrent_status status = handle.status();
        if (!status.has_metadata) { continue; }
        handle.save_resume_data(lt::torrent_handle::save_info_dict | lt::torrent_handle::flush_disk_cache);
        outstanding++;
    }
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:5];
    while (outstanding > 0 && [deadline timeIntervalSinceNow] > 0) {
        std::vector<lt::alert *> alerts;
        _session->pop_alerts(&alerts);
        for (lt::alert *alert : alerts) {
            if (auto *resume = lt::alert_cast<lt::save_resume_data_alert>(alert)) {
                [self writeResumeData:resume];
                outstanding--;
            } else if (lt::alert_cast<lt::save_resume_data_failed_alert>(alert)) {
                outstanding--;
            }
        }
        if (outstanding > 0) { [NSThread sleepForTimeInterval:0.05]; }
    }
    _session.reset();
}

- (void)dealloc {
    [self shutdown];
}

@end
