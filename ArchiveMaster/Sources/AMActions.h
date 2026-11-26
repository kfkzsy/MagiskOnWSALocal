#import <UIKit/UIKit.h>
#import <PhotosUI/PhotosUI.h>
#import "AMArchiver.h"
#import "AMCompressViewController.h"

NS_ASSUME_NONNULL_BEGIN

/// User-facing flows shared by all screens: progress UI, password prompts, results.
@interface AMActions : NSObject

+ (void)extractArchive:(NSURL *)archive
                  into:(NSURL *)directory
                  from:(UIViewController *)vc
            completion:(nullable void (^)(NSURL *_Nullable result))completion;

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
                 completion:(void (^)(NSArray<NSURL *> *urls))completion;

+ (NSString *)suggestedNameForItems:(NSArray<NSURL *> *)items;

@end

NS_ASSUME_NONNULL_END
