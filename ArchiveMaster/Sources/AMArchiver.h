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

/// Cancellation token for a running operation.
@interface AMArchiveTask : NSObject
@property (atomic) BOOL cancelled;
@end

typedef void (^AMProgressBlock)(double fraction, NSString *_Nullable currentItem);

@interface AMArchiver : NSObject

/// Whether the file name looks like something the app can extract.
+ (BOOL)isArchiveURL:(NSURL *)url;
/// "photos.tar.gz" -> "photos", "movie.part1.rar" -> "movie".
+ (NSString *)baseNameForArchive:(NSString *)fileName;
/// Human readable kind, e.g. "ZIP 压缩包".
+ (NSString *)kindForArchive:(NSString *)fileName;

/// Extracts into `directory`. With "smart extract" on, a single top-level item lands directly in
/// `directory`; otherwise everything goes into a new folder named after the archive.
/// Completion (main queue) gets the URL of the extracted item/folder.
+ (AMArchiveTask *)extractArchive:(NSURL *)archive
                      toDirectory:(NSURL *)directory
                         password:(nullable NSString *)password
                         progress:(nullable AMProgressBlock)progress
                       completion:(void (^)(NSURL *_Nullable result, NSError *_Nullable error))completion;

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

/// Lists entries (capped at 20,000). Completion runs on the main queue.
+ (void)listArchive:(NSURL *)archive
         completion:(void (^)(NSArray<AMArchiveEntry *> *entries, BOOL truncated, NSError *_Nullable error))completion;

@end

NS_ASSUME_NONNULL_END
