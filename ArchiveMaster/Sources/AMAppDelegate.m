#import "AMAppDelegate.h"
#import "AMArchiveCore.h"
#import "AMArchiver.h"
#import "AMFileBrowserViewController.h"
#import "AMPhotosViewController.h"
#import "AMSettingsViewController.h"
#import "AMUI.h"

@implementation AMAppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    am_init();
    [NSUserDefaults.standardUserDefaults registerDefaults:@{
        AMDefaultsFormat : @(AM_FMT_ZIP),
        AMDefaultsLevel : @6,
        AMDefaultsSmartExtract : @YES,
        AMDefaultsDeleteAfterExtract : @NO,
        AMDefaultsEncoding : @"",
        AMDefaultsSort : @0,
    }];
    [self removeLeftovers];
    return YES;
}

/// Removes half-written outputs (".extracting-…", ".creating-…") left behind if the app was killed mid-operation.
- (void)removeLeftovers {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0), ^{
        NSFileManager *fm = NSFileManager.defaultManager;
        NSDirectoryEnumerator *e = [fm enumeratorAtURL:AMUI.documentsURL includingPropertiesForKeys:nil options:0 errorHandler:nil];
        NSMutableArray *junk = [NSMutableArray array];
        for (NSURL *u in e) {
            NSString *n = u.lastPathComponent;
            if ([n hasPrefix:@".extracting-"] || [n hasPrefix:@".creating-"]) {
                [junk addObject:u];
                [e skipDescendants];
            }
        }
        for (NSURL *u in junk) [fm removeItemAtURL:u error:nil];
        // Nothing is using tmp/ right after launch: drop previews, photo copies and partial outputs.
        NSURL *tmp = [NSURL fileURLWithPath:NSTemporaryDirectory()];
        for (NSURL *u in [fm contentsOfDirectoryAtURL:tmp includingPropertiesForKeys:nil options:0 error:nil])
            [fm removeItemAtURL:u error:nil];
    });
}

- (UISceneConfiguration *)application:(UIApplication *)application
    configurationForConnectingSceneSession:(UISceneSession *)connectingSceneSession
                                   options:(UISceneConnectionOptions *)options {
    UISceneConfiguration *c = [[UISceneConfiguration alloc] initWithName:@"Default Configuration" sessionRole:connectingSceneSession.role];
    c.delegateClass = AMSceneDelegate.class;
    return c;
}

@end

@interface AMSceneDelegate ()
@property (nonatomic, strong) UITabBarController *tabs;
@property (nonatomic, strong) UINavigationController *filesNav;
@property (nonatomic, strong) UINavigationController *photosNav;
@end

@implementation AMSceneDelegate

- (UINavigationController *)navWithRoot:(UIViewController *)root title:(NSString *)title symbol:(NSString *)symbol selected:(NSString *)selected {
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:root];
    nav.navigationBar.prefersLargeTitles = YES;
    nav.tabBarItem = [[UITabBarItem alloc] initWithTitle:title image:[UIImage systemImageNamed:symbol] selectedImage:[UIImage systemImageNamed:selected]];
    return nav;
}

- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)connectionOptions {
    if (![scene isKindOfClass:UIWindowScene.class]) return;
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];

    AMFileBrowserViewController *files = [[AMFileBrowserViewController alloc] initWithDirectory:AMUI.documentsURL];
    self.filesNav = [self navWithRoot:files title:L(@"文件") symbol:@"folder" selected:@"folder.fill"];
    UINavigationController *photos = [self navWithRoot:[AMPhotosViewController new] title:L(@"相册") symbol:@"photo.on.rectangle" selected:@"photo.fill.on.rectangle.fill"];
    self.photosNav = photos;
    UINavigationController *settings = [self navWithRoot:[AMSettingsViewController new] title:L(@"设置") symbol:@"gearshape" selected:@"gearshape.fill"];
    self.tabs = [UITabBarController new];
    self.tabs.viewControllers = @[ self.filesNav, photos, settings ];
    self.window.rootViewController = self.tabs;
    [self.window makeKeyAndVisible];

    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(revealNotification:) name:AMRevealInFilesNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(compressMediaNotification:) name:AMCompressMediaNotification object:nil];

    NSSet<UIOpenURLContext *> *contexts = connectionOptions.URLContexts;
    if (contexts.count) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self handleURLContexts:contexts];
        });
    }
}

- (void)scene:(UIScene *)scene openURLContexts:(NSSet<UIOpenURLContext *> *)URLContexts {
    [self handleURLContexts:URLContexts];
}

- (AMFileBrowserViewController *)filesRoot {
    return (AMFileBrowserViewController *)self.filesNav.viewControllers.firstObject;
}

- (void)revealNotification:(NSNotification *)note {
    NSURL *url = note.object;
    if (![url isKindOfClass:NSURL.class]) return;
    [self showInFiles:url];
}

- (void)compressMediaNotification:(NSNotification *)note {
    NSArray *urls = note.object;
    if (![urls isKindOfClass:NSArray.class] || urls.count == 0) return;
    [self.tabs.presentedViewController dismissViewControllerAnimated:NO completion:nil];
    self.tabs.selectedViewController = self.photosNav;
    [self.photosNav popToRootViewControllerAnimated:NO];
    AMPhotosViewController *photos = (AMPhotosViewController *)self.photosNav.viewControllers.firstObject;
    [photos loadViewIfNeeded];
    [photos loadFileURLs:urls];
}

/// Switches to the Files tab, navigates to the item's folder and highlights it.
- (void)showInFiles:(NSURL *)url {
    [self.tabs.presentedViewController dismissViewControllerAnimated:NO completion:nil];
    self.tabs.selectedViewController = self.filesNav;
    [self.filesNav popToRootViewControllerAnimated:NO];
    NSURL *docs = AMUI.documentsURL.URLByResolvingSymlinksInPath;
    NSURL *parent = url.URLByDeletingLastPathComponent.URLByResolvingSymlinksInPath;
    AMFileBrowserViewController *target = self.filesRoot;
    if (![parent.path isEqualToString:docs.path] && [AMUI url:parent isInsideDirectory:docs]) {
        // Push one browser per path component below Documents.
        NSString *rel = [parent.path substringFromIndex:docs.path.length + 1];
        NSURL *dir = docs;
        for (NSString *comp in rel.pathComponents) {
            dir = [dir URLByAppendingPathComponent:comp isDirectory:YES];
            target = [[AMFileBrowserViewController alloc] initWithDirectory:dir];
            [self.filesNav pushViewController:target animated:NO];
        }
    }
    [target revealItemAtURL:url];
}

/// Files shared to the app ("Open in…", "Copy to 解压大师") or opened from the Files app.
- (void)handleURLContexts:(NSSet<UIOpenURLContext *> *)contexts {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSURL *docs = AMUI.documentsURL;
    NSURL *inbox = [docs URLByAppendingPathComponent:@"Inbox" isDirectory:YES];
    NSMutableArray<NSURL *> *received = [NSMutableArray array];
    for (UIOpenURLContext *ctx in contexts) {
        NSURL *url = ctx.URL;
        if (!url.isFileURL) continue;
        if ([AMUI url:url isInsideDirectory:docs] && ![AMUI url:url isInsideDirectory:inbox]) {
            [received addObject:url];  // already ours (e.g. tapped in the Files app)
            continue;
        }
        BOOL scoped = [url startAccessingSecurityScopedResource];
        NSURL *dest = [AMUI uniqueURLForName:url.lastPathComponent inDirectory:docs];
        BOOL ok = [AMUI url:url isInsideDirectory:inbox] ? [fm moveItemAtURL:url toURL:dest error:nil]
                                                         : [fm copyItemAtURL:url toURL:dest error:nil];
        if (scoped) [url stopAccessingSecurityScopedResource];
        if (ok) [received addObject:dest];
    }
    if (received.count == 0) return;
    NSURL *first = received.firstObject;
    [self showInFiles:first];
    if (received.count == 1 && [AMArchiver isArchiveURL:first]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            UIViewController *top = self.filesNav.topViewController;
            if ([top isKindOfClass:AMFileBrowserViewController.class]) [(AMFileBrowserViewController *)top offerToExtract:first];
        });
    } else if (received.count > 1) {
        [AMUI toast:[NSString stringWithFormat:L(@"已收到 %lu 个文件"), (unsigned long)received.count] symbol:@"tray.and.arrow.down.fill"];
    }
}

@end
