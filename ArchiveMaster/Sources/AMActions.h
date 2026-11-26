#import <UIKit/UIKit.h>
#import <PhotosUI/PhotosUI.h>
#import "AMArchiver.h"
#import "AMCompressViewController.h"

NS_ASSUME_NONNULL_BEGIN

/// A photo/video copied out of the photo library.
@interface AMPickedAsset : NSObject
@property (nonatomic, strong) NSURL *url;
@property (nonatomic, copy, nullable) NSString *assetIdentifier;  // set when picked with library access
@property (nonatomic) BOOL isVideo;
@end

/// User-facing flows shared by all screens: progress UI, password prompts, results.
@interface AMActions : NSObject

/// Extracts (optionally only some entries). Tries the saved password book automatically and
/// asks for a password when needed.
+ (void)extractArchive:(NSURL *)archive
                  into:(NSURL *)directory
             onlyPaths:(nullable NSSet<NSString *> *)paths
                  from:(UIViewController *)vc
            completion:(nullable void (^)(NSURL *_Nullable result))completion;

/// Extracts several archives one after another.
+ (void)extractArchives:(NSArray<NSURL *> *)archives
                   into:(NSURL *)directory
                   from:(UIViewController *)vc
             completion:(nullable void (^)(NSArray<NSURL *> *results))completion;

/// Extracts one entry to a temporary folder and shows it with QuickLook.
+ (void)previewEntry:(NSString *)path inArchive:(NSURL *)archive from:(UIViewController *)vc;

/// Shows the options sheet, then compresses.
+ (void)compressItems:(NSArray<NSURL *> *)items
        suggestedName:(nullable NSString *)name
                 into:(NSURL *)directory
                 from:(UIViewController *)vc
           completion:(nullable void (^)(NSURL *_Nullable result))completion;

/// Compresses with the given settings (no sheet).
+ (void)compressItems:(NSArray<NSURL *> *)items
             settings:(AMCompressSettings *)settings
                 into:(NSURL *)directory
                 from:(UIViewController *)vc
           completion:(nullable void (^)(NSURL *_Nullable result))completion;

/// Copies picked photos/videos (original files) into `directory`, with a progress card.
+ (void)importPickerResults:(NSArray<PHPickerResult *> *)results
                       into:(NSURL *)directory
                 imagesOnly:(BOOL)imagesOnly
                       from:(UIViewController *)vc
                 completion:(void (^)(NSArray<AMPickedAsset *> *assets))completion;

+ (NSString *)suggestedNameForItems:(NSArray<NSURL *> *)items;

@end

NS_ASSUME_NONNULL_END
