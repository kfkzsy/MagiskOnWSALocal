#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// "相册" tab: pick photos/videos, then compress them (by ratio or per-photo size, saved straight
/// back to the photo library) or pack them into an archive with an optional target size.
@interface AMPhotosViewController : UITableViewController
/// Loads image/video files (e.g. sent from the Files tab). The files are copied; originals stay untouched.
- (void)loadFileURLs:(NSArray<NSURL *> *)urls;
@end

NS_ASSUME_NONNULL_END
