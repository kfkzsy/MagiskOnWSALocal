#import "AMMediaCompressor.h"
#import "AMUI.h"
#import <AVFoundation/AVFoundation.h>
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

@implementation AMMediaResult
@end

static const double kQualityMax = 0.92;
static const double kQualityMin = 0.42;
static const NSInteger kMinEdge = 160;

@implementation AMMediaCompressor

+ (BOOL)canEncodeHEIC {
    static BOOL can;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSArray *types = CFBridgingRelease(CGImageDestinationCopyTypeIdentifiers());
        can = [types containsObject:UTTypeHEIC.identifier];
    });
    return can;
}

+ (CGSize)pixelSizeOfImageAtURL:(NSURL *)url {
    CGImageSourceRef src = CGImageSourceCreateWithURL((__bridge CFURLRef)url, NULL);
    if (!src) return CGSizeZero;
    NSDictionary *p = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(src, 0, NULL));
    CFRelease(src);
    CGFloat w = [p[(id)kCGImagePropertyPixelWidth] doubleValue], h = [p[(id)kCGImagePropertyPixelHeight] doubleValue];
    NSInteger orientation = [p[(id)kCGImagePropertyOrientation] integerValue];
    return orientation >= 5 ? CGSizeMake(h, w) : CGSizeMake(w, h);
}

#pragma mark - Metadata

static NSDate *AMCaptureDate(NSDictionary *props) {
    NSDictionary *exif = props[(id)kCGImagePropertyExifDictionary];
    NSString *s = exif[(id)kCGImagePropertyExifDateTimeOriginal] ?: props[(id)kCGImagePropertyTIFFDictionary][(id)kCGImagePropertyTIFFDateTime];
    if (![s isKindOfClass:NSString.class]) return nil;
    NSDateFormatter *f = [NSDateFormatter new];
    f.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    NSString *offset = exif[@"OffsetTimeOriginal"];
    if ([offset isKindOfClass:NSString.class] && offset.length >= 6) {
        f.dateFormat = @"yyyy:MM:dd HH:mm:ssZZZZZ";
        NSDate *d = [f dateFromString:[s stringByAppendingString:offset]];
        if (d) return d;
    }
    f.dateFormat = @"yyyy:MM:dd HH:mm:ss";
    f.timeZone = NSTimeZone.localTimeZone;
    return [f dateFromString:s];
}

static CLLocation *AMLocation(NSDictionary *props) {
    NSDictionary *gps = props[(id)kCGImagePropertyGPSDictionary];
    if (![gps isKindOfClass:NSDictionary.class]) return nil;
    NSNumber *lat = gps[(id)kCGImagePropertyGPSLatitude], *lon = gps[(id)kCGImagePropertyGPSLongitude];
    if (!lat || !lon) return nil;
    double la = lat.doubleValue, lo = lon.doubleValue;
    if ([gps[(id)kCGImagePropertyGPSLatitudeRef] isEqual:@"S"]) la = -la;
    if ([gps[(id)kCGImagePropertyGPSLongitudeRef] isEqual:@"W"]) lo = -lo;
    if (!CLLocationCoordinate2DIsValid(CLLocationCoordinate2DMake(la, lo))) return nil;
    return [[CLLocation alloc] initWithLatitude:la longitude:lo];
}

static NSMutableDictionary *AMOutputMetadata(NSDictionary *props, BOOL stripLocation) {
    NSMutableDictionary *meta = [props mutableCopy] ?: [NSMutableDictionary dictionary];
    [meta removeObjectsForKeys:@[ (id)kCGImagePropertyPixelWidth, (id)kCGImagePropertyPixelHeight,
                                  (id)kCGImagePropertyOrientation, (id)kCGImagePropertyFileSize ]];
    meta[(id)kCGImagePropertyOrientation] = @1;  // pixels are rotated upright when decoded
    NSMutableDictionary *tiff = [meta[(id)kCGImagePropertyTIFFDictionary] mutableCopy];
    if (tiff) { tiff[(id)kCGImagePropertyTIFFOrientation] = @1; meta[(id)kCGImagePropertyTIFFDictionary] = tiff; }
    NSMutableDictionary *exif = [meta[(id)kCGImagePropertyExifDictionary] mutableCopy];
    if (exif) {
        [exif removeObjectsForKeys:@[ (id)kCGImagePropertyExifPixelXDimension, (id)kCGImagePropertyExifPixelYDimension ]];
        meta[(id)kCGImagePropertyExifDictionary] = exif;
    }
    if (stripLocation) [meta removeObjectForKey:(id)kCGImagePropertyGPSDictionary];
    return meta;
}

#pragma mark - Images

/// Decodes the image upright with its longest side at most `edge` pixels.
static CGImageRef AMDecode(CGImageSourceRef src, NSInteger edge) {
    NSDictionary *opts = @{
        (id)kCGImageSourceCreateThumbnailFromImageAlways : @YES,
        (id)kCGImageSourceCreateThumbnailWithTransform : @YES,
        (id)kCGImageSourceThumbnailMaxPixelSize : @(edge),
        (id)kCGImageSourceShouldCacheImmediately : @YES,
    };
    return CGImageSourceCreateThumbnailAtIndex(src, 0, (__bridge CFDictionaryRef)opts);
}

static BOOL AMHasAlpha(CGImageRef img) {
    CGImageAlphaInfo a = CGImageGetAlphaInfo(img);
    return a != kCGImageAlphaNone && a != kCGImageAlphaNoneSkipFirst && a != kCGImageAlphaNoneSkipLast;
}

/// JPEG has no transparency: composite transparent images onto white instead of black.
static CGImageRef AMFlattenOnWhite(CGImageRef img) {
    size_t w = CGImageGetWidth(img), h = CGImageGetHeight(img);
    CGColorSpaceRef cs = CGImageGetColorSpace(img);
    BOOL rgb = cs && CGColorSpaceGetModel(cs) == kCGColorSpaceModelRGB;
    CGColorSpaceRef space = rgb ? CGColorSpaceRetain(cs) : CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef ctx = CGBitmapContextCreate(NULL, w, h, 8, 0, space, kCGImageAlphaNoneSkipLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(space);
    if (!ctx) return CGImageRetain(img);
    CGContextSetRGBFillColor(ctx, 1, 1, 1, 1);
    CGContextFillRect(ctx, CGRectMake(0, 0, w, h));
    CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), img);
    CGImageRef out = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    return out ?: CGImageRetain(img);
}

static NSData *AMEncode(CGImageRef img, UTType *type, NSDictionary *meta, double quality) {
    NSMutableData *data = [NSMutableData data];
    CGImageDestinationRef d = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)data, (__bridge CFStringRef)type.identifier, 1, NULL);
    if (!d) return nil;
    NSMutableDictionary *props = [meta mutableCopy];
    props[(id)kCGImageDestinationLossyCompressionQuality] = @(quality);
    CGImageDestinationAddImage(d, img, (__bridge CFDictionaryRef)props);
    BOOL ok = CGImageDestinationFinalize(d);
    CFRelease(d);
    return ok ? data : nil;
}

/// Highest quality in [kQualityMin, kQualityMax] whose output fits `budget`; nil if even the minimum doesn't.
static NSData *AMBestFit(CGImageRef img, UTType *type, NSDictionary *meta, long long budget, NSData **smallest) {
    NSData *top = AMEncode(img, type, meta, kQualityMax);
    if (!top) return nil;
    if ((long long)top.length <= budget) return top;
    NSData *low = AMEncode(img, type, meta, kQualityMin);
    if (smallest) *smallest = low;
    if (!low || (long long)low.length > budget) return nil;
    double lo = kQualityMin, hi = kQualityMax;
    NSData *best = low;
    for (int i = 0; i < 4; i++) {
        @autoreleasepool {
            double mid = (lo + hi) / 2;
            NSData *d = AMEncode(img, type, meta, mid);
            if (d && (long long)d.length <= budget) { best = d; lo = mid; }
            else hi = mid;
        }
    }
    return best;
}

+ (AMMediaResult *)compressImageAtURL:(NSURL *)source toDirectory:(NSURL *)directory budget:(long long)budget
                              maxEdge:(NSInteger)maxEdge heic:(BOOL)heic stripLocation:(BOOL)stripLocation {
    CGImageSourceRef src = CGImageSourceCreateWithURL((__bridge CFURLRef)source, NULL);
    if (!src) return nil;
    NSDictionary *props = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(src, 0, NULL));
    NSInteger w = [props[(id)kCGImagePropertyPixelWidth] integerValue];
    NSInteger h = [props[(id)kCGImagePropertyPixelHeight] integerValue];
    NSInteger longest = MAX(w, h);
    if (longest <= 0) { CFRelease(src); return nil; }

    AMMediaResult *r = [AMMediaResult new];
    r.source = source;
    r.originalBytes = (long long)[AMUI sizeOfItemAtURL:source];
    CGSize upright = [self pixelSizeOfImageAtURL:source];
    r.originalWidth = (NSInteger)upright.width;
    r.originalHeight = (NSInteger)upright.height;
    r.captureDate = AMCaptureDate(props);
    r.location = stripLocation ? nil : AMLocation(props);

    // Already within the size budget and no resolution cap to apply: leave the photo untouched.
    if (budget > 0 && r.originalBytes <= budget && (maxEdge <= 0 || longest <= maxEdge)) {
        CFRelease(src);
        NSURL *copy = [AMUI uniqueURLForName:source.lastPathComponent inDirectory:directory];
        if (![NSFileManager.defaultManager copyItemAtURL:source toURL:copy error:nil]) return nil;
        r.url = copy;
        r.bytes = r.originalBytes;
        r.width = r.originalWidth;
        r.height = r.originalHeight;
        r.keptOriginal = YES;
        return r;
    }

    UTType *type = heic ? UTTypeHEIC : UTTypeJPEG;
    NSDictionary *meta = AMOutputMetadata(props, stripLocation);
    NSInteger edge = (maxEdge > 0 && maxEdge < longest) ? maxEdge : longest;
    NSData *result = nil, *fallback = nil;
    CGSize outSize = CGSizeZero, fallbackSize = CGSizeZero;

    for (int attempt = 0; attempt < 10 && !result; attempt++) {
        @autoreleasepool {
            CGImageRef img = AMDecode(src, edge);
            if (!img) break;
            if (!heic && AMHasAlpha(img)) {
                CGImageRef flat = AMFlattenOnWhite(img);
                CGImageRelease(img);
                img = flat;
            }
            outSize = CGSizeMake(CGImageGetWidth(img), CGImageGetHeight(img));
            NSData *smallest = nil;
            if (budget <= 0) {
                result = AMEncode(img, type, meta, 0.82);
            } else {
                result = AMBestFit(img, type, meta, budget, &smallest);
                if (smallest) { fallback = smallest; fallbackSize = outSize; }
                if (!result) {
                    // Too big even at low quality: shrink the resolution. File size scales roughly
                    // with the pixel count, so aim for the edge at which quality ~0.7 would fit;
                    // a smaller clean image looks better than a full-size blocky one.
                    NSData *mid = AMEncode(img, type, meta, 0.7);
                    double ratio = mid.length ? (double)budget / (double)mid.length : 0.5;
                    double scale = MIN(0.9, MAX(0.25, sqrt(ratio) * 0.97));
                    NSInteger next = MAX(kMinEdge, (NSInteger)(edge * scale));
                    if (next >= edge) result = smallest;  // already at the minimum size
                    edge = next;
                }
            }
            CGImageRelease(img);
        }
    }
    CFRelease(src);
    if (!result && fallback) { result = fallback; outSize = fallbackSize; }  // smallest we could make
    if (!result) return nil;

    NSString *base = source.lastPathComponent.stringByDeletingPathExtension;
    NSURL *dst = [AMUI uniqueURLForName:[base stringByAppendingPathExtension:heic ? @"heic" : @"jpg"] inDirectory:directory];
    if (![result writeToURL:dst atomically:YES]) return nil;
    r.url = dst;
    r.bytes = (long long)result.length;
    r.width = (NSInteger)outSize.width;
    r.height = (NSInteger)outSize.height;

    // Never make a photo bigger: if re-encoding to the same type at full size didn't help, keep the original.
    UTType *srcType = [UTType typeWithFilenameExtension:source.pathExtension];
    BOOL fullSize = MAX(outSize.width, outSize.height) >= longest;
    if (r.bytes >= r.originalBytes && fullSize && srcType && [srcType conformsToType:type]) {
        [NSFileManager.defaultManager removeItemAtURL:dst error:nil];
        NSURL *copy = [AMUI uniqueURLForName:source.lastPathComponent inDirectory:directory];
        if (![NSFileManager.defaultManager copyItemAtURL:source toURL:copy error:nil]) return nil;
        r.url = copy;
        r.bytes = r.originalBytes;
        r.width = r.originalWidth;
        r.height = r.originalHeight;
        r.keptOriginal = YES;
    }
    return r;
}

#pragma mark - Videos

+ (AMMediaResult *)compressVideoAtURL:(NSURL *)source toDirectory:(NSURL *)directory preset:(NSString *)preset
                            cancelled:(BOOL (^)(void))cancelled progress:(void (^)(float))progress {
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:source options:nil];
    NSArray *compatible = [AVAssetExportSession exportPresetsCompatibleWithAsset:asset];
    NSString *chosen = [compatible containsObject:preset] ? preset : AVAssetExportPresetMediumQuality;
    AVAssetExportSession *session = [[AVAssetExportSession alloc] initWithAsset:asset presetName:chosen];
    if (!session) return nil;
    BOOL mp4 = [session.supportedFileTypes containsObject:AVFileTypeMPEG4];
    NSString *name = [source.lastPathComponent.stringByDeletingPathExtension stringByAppendingPathExtension:mp4 ? @"mp4" : @"mov"];
    NSURL *dst = [AMUI uniqueURLForName:name inDirectory:directory];
    session.outputURL = dst;
    session.outputFileType = mp4 ? AVFileTypeMPEG4 : AVFileTypeQuickTimeMovie;
    session.shouldOptimizeForNetworkUse = YES;

    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [session exportAsynchronouslyWithCompletionHandler:^{ dispatch_semaphore_signal(sem); }];
    while (dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC))) != 0) {
        if (cancelled && cancelled()) [session cancelExport];
        if (progress) progress(session.progress);
    }
    if (session.status != AVAssetExportSessionStatusCompleted) {
        [NSFileManager.defaultManager removeItemAtURL:dst error:nil];
        return nil;
    }

    AMMediaResult *r = [AMMediaResult new];
    r.source = source;
    r.isVideo = YES;
    r.originalBytes = (long long)[AMUI sizeOfItemAtURL:source];
    r.captureDate = asset.creationDate.dateValue;
    r.url = dst;
    r.bytes = (long long)[AMUI sizeOfItemAtURL:dst];
    if (r.bytes >= r.originalBytes) {  // the preset didn't help; keep the original
        [NSFileManager.defaultManager removeItemAtURL:dst error:nil];
        NSURL *copy = [AMUI uniqueURLForName:source.lastPathComponent inDirectory:directory];
        if (![NSFileManager.defaultManager copyItemAtURL:source toURL:copy error:nil]) return nil;
        r.url = copy;
        r.bytes = r.originalBytes;
        r.keptOriginal = YES;
    }
    return r;
}

@end
