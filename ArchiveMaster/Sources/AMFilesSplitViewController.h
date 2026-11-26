#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Files tab container. On wide screens (iPhone Duo unfolded, iPad) it shows the file list and a
/// detail column (preview / archive contents); on compact screens it collapses to the list.
@interface AMFilesSplitViewController : UISplitViewController
- (instancetype)initWithFilesNavigationController:(UINavigationController *)nav;
@property (nonatomic, readonly) UINavigationController *filesNav;
/// YES when the detail column is on screen next to the list.
@property (nonatomic, readonly) BOOL showsDetailColumn;
/// Shows `vc` in the detail column (only meaningful when `showsDetailColumn`).
- (void)showDetail:(UIViewController *)vc forURL:(nullable NSURL *)url;
/// Puts the placeholder back if the detail column shows one of `urls` (or something inside them).
- (void)clearDetailIfShowingAnyOf:(NSArray<NSURL *> *)urls;
- (void)clearDetail;
@end

NS_ASSUME_NONNULL_END
