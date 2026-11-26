#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Lists what's inside an archive without extracting it.
@interface AMArchiveContentsViewController : UITableViewController
- (instancetype)initWithArchive:(NSURL *)archive;
/// Called when the user taps "解压".
@property (nonatomic, copy, nullable) void (^onExtract)(void);
@end

NS_ASSUME_NONNULL_END
