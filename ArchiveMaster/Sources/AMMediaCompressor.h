#import <CoreLocation/CoreLocation.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface AMMediaResult : NSObject
@property (nonatomic, strong) NSURL *source;
@property (nonatomic, strong) NSURL *url;
@property (nonatomic) long long originalBytes;
@property (nonatomic) long long bytes;
@property (nonatomic) NSInteger width, height;              // output pixels (images)
@property (nonatomic) NSInteger originalWidth, originalHeight;
@property (nonatomic) BOOL isVideo;
@property (nonatomic) BOOL keptOriginal;                    // re-encoding didn't help, original copied
@property (nonatomic, strong, nullable) NSDate *captureDate;
@property (nonatomic, strong, nullable) CLLocation *location;
@end

@interface AMMediaCompressor : NSObject

+ (BOOL)canEncodeHEIC;

/// Re-encodes an image so the file is at most `budget` bytes (when budget > 0), lowering JPEG/HEIC
/// quality first and then the resolution. `maxEdge` > 0 also caps the longest side. Synchronous.
+ (nullable AMMediaResult *)compressImageAtURL:(NSURL *)source
                                   toDirectory:(NSURL *)directory
                                        budget:(long long)budget
                                       maxEdge:(NSInteger)maxEdge
                                          heic:(BOOL)heic
                                 stripLocation:(BOOL)stripLocation;

/// Re-encodes a video with an AVAssetExportSession preset (e.g. AVAssetExportPreset1280x720).
/// Synchronous; `cancelled` is polled, `progress` gets 0...1.
+ (nullable AMMediaResult *)compressVideoAtURL:(NSURL *)source
                                   toDirectory:(NSURL *)directory
                                        preset:(NSString *)preset
                                     cancelled:(BOOL (^)(void))cancelled
                                      progress:(nullable void (^)(float fraction))progress;

/// Pixel size of an image file without decoding it.
+ (CGSize)pixelSizeOfImageAtURL:(NSURL *)url;

@end

NS_ASSUME_NONNULL_END
