#import <QuickLook/QuickLook.h>

NS_ASSUME_NONNULL_BEGIN

@interface AMPreviewItem : NSObject <QLPreviewItem>
@property (nonatomic, strong) NSURL *previewItemURL;
@property (nonatomic, strong, nullable) NSString *previewItemTitle;
+ (instancetype)itemWithURL:(NSURL *)url title:(nullable NSString *)title;
@end

/// QuickLook controller that owns its items (QLPreviewController's data source is weak).
@interface AMQuickLook : QLPreviewController <QLPreviewControllerDataSource>
- (instancetype)initWithItems:(NSArray<id<QLPreviewItem>> *)items index:(NSInteger)index;
/// Runs when the preview is dismissed (e.g. to delete temporary files).
@property (nonatomic, copy, nullable) void (^onDismiss)(void);
@end

NS_ASSUME_NONNULL_END
