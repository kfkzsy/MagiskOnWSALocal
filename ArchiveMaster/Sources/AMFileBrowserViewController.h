#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Files-style browser for a folder inside the app's Documents directory.
@interface AMFileBrowserViewController : UITableViewController
- (instancetype)initWithDirectory:(NSURL *)directory;
@property (nonatomic, readonly) NSURL *directory;
- (void)reload;
/// Reloads, scrolls to the item and briefly highlights it.
- (void)revealItemAtURL:(NSURL *)url;
/// Offers to extract `url` (used after a file is opened from another app).
- (void)offerToExtract:(NSURL *)url;
@end

NS_ASSUME_NONNULL_END
