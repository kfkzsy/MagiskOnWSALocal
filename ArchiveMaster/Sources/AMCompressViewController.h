#import <UIKit/UIKit.h>
#import "AMArchiveCore.h"
#import "AMArchiver.h"

NS_ASSUME_NONNULL_BEGIN

@interface AMCompressSettings : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic) am_format format;
@property (nonatomic) NSInteger level;
@property (nonatomic, copy, nullable) NSString *password;
@property (nonatomic) am_encryption encryption;
@property (nonatomic) AMOutputMode output;
@property (nonatomic) NSInteger count;  // archives/volumes when output != AMOutputSingle
@end

/// Form sheet for choosing the archive name, format, level and password.
@interface AMCompressViewController : UITableViewController
- (instancetype)initWithItems:(NSArray<NSURL *> *)items suggestedName:(NSString *)name;
/// Called after the sheet has been dismissed.
@property (nonatomic, copy, nullable) void (^onConfirm)(AMCompressSettings *settings);
@end

NS_ASSUME_NONNULL_END
