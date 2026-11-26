#import "AMQuickLook.h"

@implementation AMPreviewItem
+ (instancetype)itemWithURL:(NSURL *)url title:(NSString *)title {
    AMPreviewItem *i = [AMPreviewItem new];
    i.previewItemURL = url;
    i.previewItemTitle = title;
    return i;
}
@end

@interface AMQuickLook ()
@property (nonatomic, copy) NSArray<id<QLPreviewItem>> *items;
@end

@implementation AMQuickLook

- (instancetype)initWithItems:(NSArray<id<QLPreviewItem>> *)items index:(NSInteger)index {
    if ((self = [super initWithNibName:nil bundle:nil])) {
        _items = [items copy];
        self.dataSource = self;
        self.currentPreviewItemIndex = MAX(0, MIN(index, (NSInteger)items.count - 1));
    }
    return self;
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    if (self.isBeingDismissed || self.isMovingFromParentViewController) {
        if (self.onDismiss) self.onDismiss();
        self.onDismiss = nil;
    }
}

- (NSInteger)numberOfPreviewItemsInPreviewController:(QLPreviewController *)controller {
    return (NSInteger)self.items.count;
}

- (id<QLPreviewItem>)previewController:(QLPreviewController *)controller previewItemAtIndex:(NSInteger)index {
    return self.items[(NSUInteger)index];
}

@end
