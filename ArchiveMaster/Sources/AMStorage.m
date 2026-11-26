#import "AMStorage.h"
#import "AMUI.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

NSNotificationName const AMSaveFolderDidChangeNotification = @"AMSaveFolderDidChangeNotification";
static NSString *const kBookmarkKey = @"AMSaveFolderBookmark";

/// Delegate for one system picker presentation; kept alive until the picker finishes.
@interface AMPickerHandler : NSObject <UIDocumentPickerDelegate>
@property (nonatomic, copy) void (^completion)(NSArray<NSURL *> *urls);
@end

static NSMutableSet<AMPickerHandler *> *AMLivePickers(void) {
    static NSMutableSet *set;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ set = [NSMutableSet set]; });
    return set;
}

/// Security-scoped URLs we opened; access is kept for the rest of the launch.
static NSMutableSet<NSURL *> *AMOpenScopes(void) {
    static NSMutableSet *set;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ set = [NSMutableSet set]; });
    return set;
}

static void AMKeepAccess(NSURL *url) {
    if ([url startAccessingSecurityScopedResource]) [AMOpenScopes() addObject:url];
}

@implementation AMPickerHandler
- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    for (NSURL *u in urls) AMKeepAccess(u);
    if (self.completion) self.completion(urls);
    [AMLivePickers() removeObject:self];
}
- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    if (self.completion) self.completion(@[]);
    [AMLivePickers() removeObject:self];
}
@end

@implementation AMStorage

static NSURL *gSaveFolder;
static BOOL gResolved;

+ (NSURL *)saveFolder {
    if (gResolved) return gSaveFolder;
    gResolved = YES;
    NSData *bookmark = [NSUserDefaults.standardUserDefaults dataForKey:kBookmarkKey];
    if (!bookmark) return nil;
    BOOL stale = NO;
    NSURL *url = [NSURL URLByResolvingBookmarkData:bookmark options:0 relativeToURL:nil bookmarkDataIsStale:&stale error:nil];
    if (!url) return nil;
    AMKeepAccess(url);
    NSNumber *isDir = nil;
    if (![url getResourceValue:&isDir forKey:NSURLIsDirectoryKey error:nil] || !isDir.boolValue) return nil;
    if (stale) {
        NSData *fresh = [url bookmarkDataWithOptions:0 includingResourceValuesForKeys:nil relativeToURL:nil error:nil];
        if (fresh) [NSUserDefaults.standardUserDefaults setObject:fresh forKey:kBookmarkKey];
    }
    gSaveFolder = url;
    return url;
}

+ (NSString *)saveFolderName {
    NSURL *u = self.saveFolder;
    if (!u) return L(@"未选择");
    NSString *name = nil;
    [u getResourceValue:&name forKey:NSURLLocalizedNameKey error:nil];
    return name.length ? name : u.lastPathComponent;
}

+ (BOOL)setSaveFolder:(NSURL *)url {
    AMKeepAccess(url);
    NSData *bookmark = [url bookmarkDataWithOptions:0 includingResourceValuesForKeys:nil relativeToURL:nil error:nil];
    if (!bookmark) return NO;
    [NSUserDefaults.standardUserDefaults setObject:bookmark forKey:kBookmarkKey];
    gSaveFolder = url;
    gResolved = YES;
    [NSNotificationCenter.defaultCenter postNotificationName:AMSaveFolderDidChangeNotification object:url];
    return YES;
}

+ (void)presentPicker:(UIDocumentPickerViewController *)picker from:(UIViewController *)vc completion:(void (^)(NSArray<NSURL *> *))completion {
    AMPickerHandler *handler = [AMPickerHandler new];
    handler.completion = completion;
    [AMLivePickers() addObject:handler];
    picker.delegate = handler;
    [[AMUI topPresenterFrom:vc] presentViewController:picker animated:YES completion:nil];
}

+ (void)pickFolderFrom:(UIViewController *)vc completion:(void (^)(NSURL *))completion {
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[ UTTypeFolder ] asCopy:NO];
    picker.allowsMultipleSelection = NO;
    [self presentPicker:picker from:vc completion:^(NSArray<NSURL *> *urls) { completion(urls.firstObject); }];
}

+ (void)pickFilesOfTypes:(NSArray *)types multiple:(BOOL)multiple from:(UIViewController *)vc completion:(void (^)(NSArray<NSURL *> *))completion {
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:types asCopy:NO];
    picker.allowsMultipleSelection = multiple;
    [self presentPicker:picker from:vc completion:completion];
}

+ (void)chooseSaveFolderFrom:(UIViewController *)vc completion:(void (^)(NSURL *))completion {
    [self pickFolderFrom:vc completion:^(NSURL *folder) {
        if (folder && ![self setSaveFolder:folder]) folder = nil;
        if (folder) [AMUI toast:[NSString stringWithFormat:L(@"保存位置：%@"), self.saveFolderName] symbol:@"folder.fill"];
        if (completion) completion(folder);
    }];
}

+ (void)withSaveFolderFrom:(UIViewController *)vc block:(void (^)(NSURL *))block {
    NSURL *folder = self.saveFolder;
    if (folder) { block(folder); return; }
    UIAlertController *a = [UIAlertController alertControllerWithTitle:L(@"选择保存位置")
                                                               message:L(@"为节省 iPhone 空间，解压大师不在 App 内保存文件。请选择一个文件夹（例如“我的 iPhone”中的“下载”），解压和压缩的结果会直接存到那里。")
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:L(@"取消") style:UIAlertActionStyleCancel handler:nil]];
    UIAlertAction *choose = [UIAlertAction actionWithTitle:L(@"选择文件夹") style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        [self chooseSaveFolderFrom:vc completion:^(NSURL *chosen) {
            if (chosen) block(chosen);
        }];
    }];
    [a addAction:choose];
    a.preferredAction = choose;
    [[AMUI topPresenterFrom:vc] presentViewController:a animated:YES completion:nil];
}

+ (NSArray<NSURL *> *)legacyItems {
    NSMutableArray *items = [NSMutableArray array];
    for (NSURL *u in [NSFileManager.defaultManager contentsOfDirectoryAtURL:AMUI.documentsURL includingPropertiesForKeys:nil
                                                                    options:NSDirectoryEnumerationSkipsHiddenFiles error:nil]) {
        if ([u.lastPathComponent isEqualToString:@"Inbox"]) continue;
        [items addObject:u];
    }
    return items;
}

+ (unsigned long long)appFootprint {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSURL *caches = [fm URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask].firstObject;
    return [AMUI sizeOfItemAtURL:AMUI.documentsURL] + [AMUI sizeOfItemAtURL:[NSURL fileURLWithPath:NSTemporaryDirectory()]] +
           (caches ? [AMUI sizeOfItemAtURL:caches] : 0);
}

@end
