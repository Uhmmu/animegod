#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// What a task is doing right now, as reported by libtorrent.
typedef NS_ENUM(NSInteger, AGTorrentState) {
    AGTorrentStateQueued = 0,
    AGTorrentStateFetchingMetadata,
    AGTorrentStateChecking,
    AGTorrentStateDownloading,
    AGTorrentStateFinished,
    AGTorrentStateSeeding,
    AGTorrentStatePaused,
    AGTorrentStateErrored
};

/// One poll of a task's state. Immutable; Swift rebuilds its view models
/// from these roughly once a second.
@interface AGTorrentSnapshot : NSObject
@property (nonatomic, readonly, copy) NSString *infoHash;
@property (nonatomic, readonly, copy) NSString *name;
@property (nonatomic, readonly, copy) NSString *savePath;
@property (nonatomic, readonly) AGTorrentState state;
/// 0–1 over the bytes that were actually selected for download.
@property (nonatomic, readonly) double progress;
@property (nonatomic, readonly) int64_t totalBytes;
@property (nonatomic, readonly) int64_t downloadedBytes;
@property (nonatomic, readonly) int64_t uploadedBytes;
@property (nonatomic, readonly) int downloadRate;
@property (nonatomic, readonly) int uploadRate;
@property (nonatomic, readonly) int connectedPeers;
@property (nonatomic, readonly) int connectedSeeds;
/// Swarm size as trackers/DHT report it, including peers not connected.
@property (nonatomic, readonly) int totalPeers;
@property (nonatomic, readonly) int totalSeeds;
@property (nonatomic, readonly) BOOL sequential;
@property (nonatomic, readonly) BOOL hasMetadata;
@property (nonatomic, readonly, copy, nullable) NSString *errorMessage;
/// Seconds remaining at the current rate, or -1 when unknown.
@property (nonatomic, readonly) double estimatedSecondsRemaining;
@end

/// One file inside a task, so the UI can show what a batch contains and
/// play an episode before the rest finishes.
@interface AGTorrentFileEntry : NSObject
@property (nonatomic, readonly) NSInteger index;
@property (nonatomic, readonly, copy) NSString *path;
@property (nonatomic, readonly) int64_t length;
@property (nonatomic, readonly) int64_t downloadedBytes;
@property (nonatomic, readonly) BOOL wanted;
@end

/// Session-wide connectivity, mirroring magnet-crawler's diagnostics: being
/// reachable is the single biggest factor in BitTorrent speed.
@interface AGTorrentSessionInfo : NSObject
@property (nonatomic, readonly) BOOL isRunning;
@property (nonatomic, readonly) int dhtNodes;
@property (nonatomic, readonly) int listenPort;
/// YES once UPnP or NAT-PMP mapped the port, NO if mapping failed, nil while
/// it is still being attempted.
@property (nonatomic, readonly, nullable) NSNumber *portMapped;
@property (nonatomic, readonly, copy, nullable) NSString *portMapDetail;
@property (nonatomic, readonly, copy, nullable) NSString *listenError;
/// Alerts seen since start — zero means the session is not running at all.
@property (nonatomic, readonly) int alertCount;
@property (nonatomic, readonly) int downloadRate;
@property (nonatomic, readonly) int uploadRate;
@end

/// The embedded BitTorrent engine: a libtorrent session owned by one
/// Objective-C++ object, safe to call from the main thread.
///
/// The engine persists its own state (`.torrent` + resume data) under the
/// state directory, so restarting the app resumes tasks without the database
/// knowing anything about BitTorrent internals.
@interface AGTorrentEngine : NSObject

/// Creates and starts a session. `stateDirectory` holds resume data;
/// `listenPort` is the preferred port (another is chosen if it is taken).
- (instancetype)initWithStateDirectory:(NSURL *)stateDirectory
                            listenPort:(int)listenPort
                              preferTCP:(BOOL)preferTCP NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@property (nonatomic, readonly, copy, nullable) NSString *startupError;

/// Adds a magnet link. Returns the info hash, or nil with `error` set.
- (nullable NSString *)addMagnet:(NSString *)magnetURI
                        savePath:(NSURL *)savePath
                      sequential:(BOOL)sequential
                           error:(NSError **)error;

/// Adds a `.torrent` file's contents (already verified by the caller).
- (nullable NSString *)addTorrentData:(NSData *)data
                             savePath:(NSURL *)savePath
                           sequential:(BOOL)sequential
                                error:(NSError **)error;

/// How many tasks libtorrent lets download at once; the rest are queued
/// and start as slots free up. Clamped to 1…24.
@property (nonatomic) int maximumActiveDownloads;

/// Extra trackers for a task that arrived with few or none.
- (void)addTrackers:(NSArray<NSString *> *)trackers forInfoHash:(NSString *)infoHash;

- (void)pause:(NSString *)infoHash;
- (void)resume:(NSString *)infoHash;
/// Removes the task; `deleteFiles` also deletes what was downloaded.
- (void)remove:(NSString *)infoHash deleteFiles:(BOOL)deleteFiles;
/// Sequential download lets a file play while it is still arriving.
- (void)setSequential:(BOOL)sequential forInfoHash:(NSString *)infoHash;
/// Forces a tracker/DHT re-announce to widen the peer pool.
- (void)forceReannounce:(NSString *)infoHash;

- (NSArray<AGTorrentSnapshot *> *)snapshots;
- (nullable AGTorrentSnapshot *)snapshotForInfoHash:(NSString *)infoHash;
- (NSArray<AGTorrentFileEntry *> *)filesForInfoHash:(NSString *)infoHash;
/// Restricts a task to some of its files (an episode out of a batch).
- (void)setWantedFileIndexes:(NSArray<NSNumber *> *)indexes forInfoHash:(NSString *)infoHash;
/// Prioritises the pieces of one file so it can be played while downloading.
- (void)prioritiseFileForPlayback:(NSInteger)fileIndex forInfoHash:(NSString *)infoHash;

/// Moves a task's files to another folder without interrupting it —
/// libtorrent relocates the storage and keeps seeding from the new place.
- (void)moveStorage:(NSString *)infoHash toFolder:(NSURL *)folder;

/// The one folder a task's files live in, relative to its save path. Every
/// task has one: batches bring their own, and a single-file torrent is put
/// into a folder named after it so downloads never litter the folder they
/// land in. Nil until metadata has arrived.
- (nullable NSString *)contentFolderNameForInfoHash:(NSString *)infoHash;

- (AGTorrentSessionInfo *)sessionInfo;

/// Builds `.torrent` data for a local file or folder. Used by the headless
/// loopback test, which seeds from one engine and downloads with another.
+ (nullable NSData *)createTorrentDataForPath:(NSURL *)path error:(NSError **)error;

/// Writes resume data for every task and stops the session. Called on quit;
/// safe to call more than once.
- (void)shutdown;

@end

NS_ASSUME_NONNULL_END
