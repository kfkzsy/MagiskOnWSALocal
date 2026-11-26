#import "AMAppDelegate.h"
#import "AMArchiveCore.h"
#import "AMArchiver.h"
#import "AMFileBrowserViewController.h"
#import "AMFilesSplitViewController.h"
#import "AMPhotosViewController.h"
#import "AMSettingsViewController.h"
#import "AMActions.h"
#import "AMStorage.h"
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
    NSURL *saveFolder = AMStorage.saveFolder;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0), ^{
        // Copies other apps shared with us that were never handled (older than an hour, so a file
        // being delivered at this very launch is left alone).
        NSURL *inbox = [AMUI.documentsURL URLByAppendingPathComponent:@"Inbox" isDirectory:YES];
        for (NSURL *u in [NSFileManager.defaultManager contentsOfDirectoryAtURL:inbox includingPropertiesForKeys:@[ NSURLCreationDateKey ] options:0 error:nil]) {
            NSDate *created = nil;
            [u getResourceValue:&created forKey:NSURLCreationDateKey error:nil];
            if (!created || -created.timeIntervalSinceNow > 3600) [NSFileManager.defaultManager removeItemAtURL:u error:nil];
        }
        // Half-written outputs in the save location (top level only; it can be large).
        for (NSURL *u in [NSFileManager.defaultManager contentsOfDirectoryAtURL:saveFolder includingPropertiesForKeys:nil options:0 error:nil]) {
            NSString *n = u.lastPathComponent;
            if ([n hasPrefix:@".extracting-"] || [n hasPrefix:@".creating-"]) [NSFileManager.defaultManager removeItemAtURL:u error:nil];
        }
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
@property (nonatomic, strong) AMFilesSplitViewController *filesSplit;
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

    AMFileBrowserViewController *files = [[AMFileBrowserViewController alloc] initForSaveLocation];
    self.filesNav = [self navWithRoot:files title:L(@"文件") symbol:@"folder" selected:@"folder.fill"];
    UINavigationController *photos = [self navWithRoot:[AMPhotosViewController new] title:L(@"相册") symbol:@"photo.on.rectangle" selected:@"photo.fill.on.rectangle.fill"];
    self.photosNav = photos;
    UINavigationController *settings = [self navWithRoot:[AMSettingsViewController new] title:L(@"设置") symbol:@"gearshape" selected:@"gearshape.fill"];
    // Files: list + detail columns on wide screens (iPhone Duo unfolded, iPad); a single list when folded.
    self.filesSplit = [[AMFilesSplitViewController alloc] initWithFilesNavigationController:self.filesNav];
    self.filesSplit.tabBarItem = self.filesNav.tabBarItem;
    self.tabs = [UITabBarController new];
    self.tabs.viewControllers = @[ self.filesSplit, photos, settings ];
    [AMUI configureTabBarController:self.tabs];
    self.window.rootViewController = self.tabs;
    [self.window makeKeyAndVisible];

    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(revealNotification:) name:AMRevealInFilesNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(compressMediaNotification:) name:AMCompressMediaNotification object:nil];

    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(offerLegacyMigration) name:AMSaveFolderDidChangeNotification object:nil];

    NSSet<UIOpenURLContext *> *contexts = connectionOptions.URLContexts;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (contexts.count) [self handleURLContexts:contexts];
        else [self offerLegacyMigration];
    });
}

/// Earlier versions stored files inside the app. Offer once per launch to move them out (or delete them).
- (void)offerLegacyMigration {
    static BOOL offered;
    NSArray<NSURL *> *legacy = AMStorage.legacyItems;
    NSURL *folder = AMStorage.saveFolder;
    if (offered || legacy.count == 0 || !folder || self.tabs.presentedViewController) return;
    offered = YES;
    unsigned long long size = 0;
    for (NSURL *u in legacy) size += [AMUI sizeOfItemAtURL:u];
    UIAlertController *a = [UIAlertController alertControllerWithTitle:L(@"App 内还有旧文件")
        message:[NSString stringWithFormat:L(@"旧版本在 App 内保存了 %lu 个项目（%@）。为节省空间，现在可以把它们移到“%@”，或直接删除。"),
                                           (unsigned long)legacy.count, [AMUI byteString:(long long)size], AMStorage.saveFolderName]
        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:L(@"移到保存位置") style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        NSInteger moved = 0;
        for (NSURL *u in legacy) {
            NSURL *dest = [AMUI uniqueURLForName:u.lastPathComponent inDirectory:folder];
            if ([NSFileManager.defaultManager moveItemAtURL:u toURL:dest error:nil]) moved++;
        }
        [self.filesRoot reload];
        [AMUI toast:[NSString stringWithFormat:L(@"已移动 %ld 个项目"), (long)moved] symbol:@"checkmark.circle.fill"];
    }]];
    [a addAction:[UIAlertAction actionWithTitle:L(@"删除") style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x) {
        for (NSURL *u in legacy) [NSFileManager.defaultManager removeItemAtURL:u error:nil];
        [AMUI toast:L(@"已删除") symbol:@"trash"];
    }]];
    [a addAction:[UIAlertAction actionWithTitle:L(@"以后再说") style:UIAlertActionStyleCancel handler:nil]];
    [self.tabs presentViewController:a animated:YES completion:nil];
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
    self.tabs.selectedViewController = self.filesSplit;
    [self.filesNav popToRootViewControllerAnimated:NO];
    NSURL *docs = AMStorage.saveFolder.URLByResolvingSymlinksInPath;
    NSURL *parent = url.URLByDeletingLastPathComponent.URLByResolvingSymlinksInPath;
    AMFileBrowserViewController *target = self.filesRoot;
    if (docs && ![parent.path isEqualToString:docs.path] && [AMUI url:parent isInsideDirectory:docs]) {
        // Push one browser per path component below the save location.
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
/// Nothing is kept inside the app: the user extracts them or saves them to the save location,
/// and the temporary copy the system made in Documents/Inbox is deleted afterwards.
- (void)handleURLContexts:(NSSet<UIOpenURLContext *> *)contexts {
    NSMutableArray<NSURL *> *received = [NSMutableArray array];
    for (UIOpenURLContext *ctx in contexts) {
        NSURL *url = ctx.URL;
        if (!url.isFileURL) continue;
        [url startAccessingSecurityScopedResource];  // in-place files: access for the rest of this launch
        [received addObject:url];
    }
    if (received.count == 0) return;
    NSURL *folder = AMStorage.saveFolder;
    if (folder && received.count == 1 && [AMUI url:received.firstObject isInsideDirectory:folder]) {
        [self showInFiles:received.firstObject];  // already in the save location (opened from the Files app)
        return;
    }
    UIViewController *from = self.tabs;
    [AMStorage withSaveFolderFrom:from block:^(NSURL *dest) {
        [self offerActionsForReceived:received saveFolder:dest];
    }];
}

- (void)cleanUpReceived:(NSArray<NSURL *> *)urls {
    NSURL *inbox = [AMUI.documentsURL URLByAppendingPathComponent:@"Inbox" isDirectory:YES];
    for (NSURL *u in urls)
        if ([AMUI url:u isInsideDirectory:inbox]) [NSFileManager.defaultManager removeItemAtURL:u error:nil];
}

- (void)offerActionsForReceived:(NSArray<NSURL *> *)received saveFolder:(NSURL *)folder {
    NSArray<NSArray<NSURL *> *> *groups = [AMArchiver volumeGroupsForURLs:received];
    BOOL allArchives = YES;
    for (NSURL *u in received) if (![AMArchiver isArchiveURL:u]) allArchives = NO;
    NSString *title = received.count == 1 ? [NSString stringWithFormat:L(@"已收到“%@”"), received.firstObject.lastPathComponent]
                                          : [NSString stringWithFormat:L(@"已收到 %lu 个文件"), (unsigned long)received.count];
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title
                                                               message:[NSString stringWithFormat:L(@"结果会保存到“%@”。"), AMStorage.saveFolderName]
                                                        preferredStyle:UIAlertControllerStyleAlert];
    if (allArchives) {
        UIAlertAction *extract = [UIAlertAction actionWithTitle:L(@"解压") style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
            [AMActions extractGroups:groups into:folder from:self.tabs completion:^(NSArray<NSURL *> *results) {
                [self cleanUpReceived:received];
                if (results.count) [self showInFiles:results.lastObject];
            }];
        }];
        [a addAction:extract];
        a.preferredAction = extract;
    }
    [a addAction:[UIAlertAction actionWithTitle:L(@"存到保存位置") style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        NSURL *last = nil;
        for (NSURL *u in received) {
            NSURL *dest = [AMUI uniqueURLForName:u.lastPathComponent inDirectory:folder];
            if ([NSFileManager.defaultManager copyItemAtURL:u toURL:dest error:nil]) last = dest;
        }
        [self cleanUpReceived:received];
        if (last) [self showInFiles:last];
    }]];
    [a addAction:[UIAlertAction actionWithTitle:L(@"取消") style:UIAlertActionStyleCancel handler:^(UIAlertAction *x) {
        [self cleanUpReceived:received];
    }]];
    [[AMUI topPresenterFrom:self.tabs] presentViewController:a animated:YES completion:nil];
}

@end
