#import "AMFilesSplitViewController.h"
#import "AMUI.h"

@interface AMDetailPlaceholderViewController : UIViewController
@end

@implementation AMDetailPlaceholderViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    UIImageView *icon = [[UIImageView alloc] initWithImage:[AMUI symbol:@"doc.text.magnifyingglass" pointSize:56]];
    icon.tintColor = UIColor.tertiaryLabelColor;
    icon.contentMode = UIViewContentModeCenter;
    UILabel *title = [UILabel new];
    title.text = L(@"未选择文件");
    title.font = [UIFont preferredFontForTextStyle:UIFontTextStyleTitle2];
    title.adjustsFontForContentSizeCategory = YES;
    title.textAlignment = NSTextAlignmentCenter;
    UILabel *body = [UILabel new];
    body.text = L(@"轻点左侧的文件可以在这里预览；轻点压缩包可以查看其中的内容。");
    body.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    body.adjustsFontForContentSizeCategory = YES;
    body.textColor = UIColor.secondaryLabelColor;
    body.textAlignment = NSTextAlignmentCenter;
    body.numberOfLines = 0;
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[ icon, title, body ]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.alignment = UIStackViewAlignmentCenter;
    stack.spacing = 8;
    [stack setCustomSpacing:16 afterView:icon];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.centerXAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.centerXAnchor],
        [stack.centerYAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.centerYAnchor],
        [stack.widthAnchor constraintLessThanOrEqualToAnchor:self.view.safeAreaLayoutGuide.widthAnchor constant:-64],
        [stack.widthAnchor constraintLessThanOrEqualToConstant:380],
    ]];
}

@end

@interface AMFilesSplitViewController () <UISplitViewControllerDelegate>
@property (nonatomic, readwrite) UINavigationController *filesNav;
@property (nonatomic, strong) UINavigationController *detailNav;
@property (nonatomic, strong, nullable) NSURL *detailURL;
@end

@implementation AMFilesSplitViewController

- (instancetype)initWithFilesNavigationController:(UINavigationController *)nav {
    if ((self = [super initWithStyle:UISplitViewControllerStyleDoubleColumn])) {
        _filesNav = nav;
        _detailNav = [[UINavigationController alloc] initWithRootViewController:[AMDetailPlaceholderViewController new]];
        [self setViewController:nav forColumn:UISplitViewControllerColumnPrimary];
        [self setViewController:_detailNav forColumn:UISplitViewControllerColumnSecondary];
        self.preferredDisplayMode = UISplitViewControllerDisplayModeOneBesideSecondary;
        self.preferredSplitBehavior = UISplitViewControllerSplitBehaviorTile;
        self.preferredPrimaryColumnWidthFraction = 0.4;
        self.minimumPrimaryColumnWidth = 320;
        self.maximumPrimaryColumnWidth = 460;
        self.presentsWithGesture = NO;
        self.delegate = self;
    }
    return self;
}

- (BOOL)showsDetailColumn {
    return !self.isCollapsed;
}

- (void)showDetail:(UIViewController *)vc forURL:(NSURL *)url {
    self.detailURL = url;
    [self.detailNav setViewControllers:@[ vc ] animated:NO];
    [self showColumn:UISplitViewControllerColumnSecondary];
}

- (void)clearDetail {
    self.detailURL = nil;
    if (![self.detailNav.viewControllers.firstObject isKindOfClass:AMDetailPlaceholderViewController.class])
        [self.detailNav setViewControllers:@[ [AMDetailPlaceholderViewController new] ] animated:NO];
}

- (void)clearDetailIfShowingAnyOf:(NSArray<NSURL *> *)urls {
    if (!self.detailURL) return;
    for (NSURL *u in urls) {
        if ([AMUI url:self.detailURL isInsideDirectory:u]) {
            [self clearDetail];
            return;
        }
    }
}

#pragma mark - UISplitViewControllerDelegate

// Folding the phone (or narrowing the window) shows the file list, not the detail.
- (UISplitViewControllerColumn)splitViewController:(UISplitViewController *)svc
       topColumnForCollapsingToProposedTopColumn:(UISplitViewControllerColumn)proposedTopColumn {
    return UISplitViewControllerColumnPrimary;
}

@end
