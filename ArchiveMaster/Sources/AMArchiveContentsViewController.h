#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Lists what's inside an archive without extracting it. Tap a file to preview it; select entries
/// to extract only those.
@interface AMArchiveContentsViewController : UITableViewController
- (instancetype)initWithArchive:(NSURL *)archive destination:(NSURL *)destination;
/// Called with the extracted item so the presenter can reveal it.
@property (nonatomic, copy, nullable) void (^onExtracted)(NSURL *result);
@end

NS_ASSUME_NONNULL_END
