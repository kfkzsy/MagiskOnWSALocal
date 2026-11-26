#import <Foundation/Foundation.h>
#import "AMArchiveCore.h"

NS_ASSUME_NONNULL_BEGIN

extern NSErrorDomain const AMArchiveErrorDomain;
typedef NS_ENUM(NSInteger, AMArchiveErrorCode) {
    AMArchiveErrorFailed = AM_ERR,
    AMArchiveErrorCancelled = AM_CANCELLED,
    AMArchiveErrorNeedPassword = AM_NEED_PASSWORD,
    AMArchiveErrorBadPassword = AM_BAD_PASSWORD,
    AMArchiveErrorUnsupported = AM_UNSUPPORTED,
    AMArchiveErrorEmpty = -100,
};

/// Describes a format the app can create.
@interface AMFormatInfo : NSObject
@property (nonatomic, readonly) am_format format;
@property (nonatomic, readonly, copy) NSString *name;       // "ZIP"
@property (nonatomic, readonly, copy) NSString *extension;  // "zip"
@property (nonatomic, readonly, copy) NSString *summary;    // one-line description
@property (nonatomic, readonly) BOOL singleFile;
@property (nonatomic, readonly) BOOL supportsPassword;
@property (nonatomic, readonly) BOOL compresses;  // NO for formats that only pack (TAR, ISO, CPIO, RAR)
+ (NSArray<AMFormatInfo *> *)multiFileFormats;
+ (NSArray<AMFormatInfo *> *)singleFileFormats;
+ (AMFormatInfo *)infoForFormat:(am_format)format;
@end

@interface AMArchiveEntry : NSObject
@property (nonatomic, copy) NSString *path;
@property (nonatomic) long long size;  // -1 if unknown
@property (nonatomic) BOOL isDirectory;
@property (nonatomic) BOOL encrypted;
@end

/// How to extract. `+fromSettings` reads the user's preferences and the saved password book.
@interface AMExtractOptions : NSObject
@property (nonatomic, copy) NSArray<NSString *> *passwords;
/// Only these entry paths (and everything under selected folders); nil = everything.
@property (nonatomic, copy, nullable) NSSet<NSString *> *onlyPaths;
@property (nonatomic) BOOL smart;
@property (nonatomic) BOOL deleteArchive;
/// Explicit volume list (e.g. parts picked in the Files picker, whose folder can't be listed).
@property (nonatomic, copy, nullable) NSArray<NSURL *> *volumes;
+ (instancetype)fromSettings;
@end

/// Cancellation token for a running operation.
@interface AMArchiveTask : NSObject
@property (atomic) BOOL cancelled;
@end

typedef void (^AMProgressBlock)(double fraction, NSString *_Nullable currentItem);

/// How many archives a compression produces.
typedef NS_ENUM(NSInteger, AMOutputMode) {
    AMOutputSingle = 0,   // one archive
    AMOutputVolumes,      // one archive split into N pieces: name.zip.001, name.zip.002, ...
    AMOutputSeparate,     // items spread over N independent archives: name-1.zip, name-2.zip, ...
};

@interface AMArchiver : NSObject

/// Whether the file name looks like something the app can extract.
+ (BOOL)isArchiveURL:(NSURL *)url;
/// "photos.tar.gz" -> "photos", "movie.part1.rar" -> "movie".
+ (NSString *)baseNameForArchive:(NSString *)fileName;
/// Human readable kind, e.g. "ZIP 压缩包".
+ (NSString *)kindForArchive:(NSString *)fileName;

/// Ordered list of volumes that make up the archive (just `url` when it isn't split).
+ (NSArray<NSURL *> *)volumesForArchive:(NSURL *)url;
/// Groups picked files into archives: parts of the same split archive end up together, in order.
+ (NSArray<NSArray<NSURL *> *> *)volumeGroupsForURLs:(NSArray<NSURL *> *)urls;

/// Extracts into `directory`. With "smart extract" on, a single top-level item lands directly in
/// `directory`; otherwise everything goes into a new folder named after the archive. When exactly one
/// path is selected, that item itself is placed in `directory`.
/// Completion (main queue) gets the URL of the extracted item/folder.
+ (AMArchiveTask *)extractArchive:(NSURL *)archive
                      toDirectory:(NSURL *)directory
                          options:(AMExtractOptions *)options
                         progress:(nullable AMProgressBlock)progress
                       completion:(void (^)(NSURL *_Nullable result, NSError *_Nullable error))completion;

/// Extracts a single entry into a temporary folder (for previewing). Completion gets the file URL.
+ (AMArchiveTask *)extractEntry:(NSString *)path
                    fromArchive:(NSURL *)archive
                      passwords:(NSArray<NSString *> *)passwords
                       progress:(nullable AMProgressBlock)progress
                     completion:(void (^)(NSURL *_Nullable file, NSError *_Nullable error))completion;

/// Creates "<name>.<ext>" (made unique) in `directory`. Completion runs on the main queue.
+ (AMArchiveTask *)createArchiveNamed:(NSString *)name
                          inDirectory:(NSURL *)directory
                            fromItems:(NSArray<NSURL *> *)items
                               format:(am_format)format
                                level:(NSInteger)level
                             password:(nullable NSString *)password
                           encryption:(am_encryption)encryption
                             progress:(nullable AMProgressBlock)progress
                           completion:(void (^)(NSURL *_Nullable result, NSError *_Nullable error))completion;

/// Like the above, but can produce several archives (see AMOutputMode). Completion gets every file created.
+ (AMArchiveTask *)createArchivesNamed:(NSString *)name
                           inDirectory:(NSURL *)directory
                             fromItems:(NSArray<NSURL *> *)items
                                format:(am_format)format
                                 level:(NSInteger)level
                              password:(nullable NSString *)password
                            encryption:(am_encryption)encryption
                                output:(AMOutputMode)output
                                 count:(NSInteger)count
                              progress:(nullable AMProgressBlock)progress
                            completion:(void (^)(NSArray<NSURL *> *results, NSError *_Nullable error))completion;

/// Lists entries (capped at 20,000). Completion runs on the main queue.
+ (void)listArchive:(NSURL *)archive
         completion:(void (^)(NSArray<AMArchiveEntry *> *entries, BOOL truncated, NSError *_Nullable error))completion;

@end

NS_ASSUME_NONNULL_END
