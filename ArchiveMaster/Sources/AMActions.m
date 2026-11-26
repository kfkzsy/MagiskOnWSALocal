#import "AMActions.h"
#import "AMProgressController.h"
#import "AMUI.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

@implementation AMActions

+ (void)extractArchive:(NSURL *)archive into:(NSURL *)directory from:(UIViewController *)vc completion:(void (^)(NSURL *))completion {
    [self extractArchive:archive into:directory password:nil from:vc completion:completion];
}

+ (void)extractArchive:(NSURL *)archive
                  into:(NSURL *)directory
              password:(NSString *)password
                  from:(UIViewController *)vc
            completion:(void (^)(NSURL *))completion {
    AMProgressController *p = [[AMProgressController alloc] initWithTitle:@"正在解压…" symbol:@"arrow.up.bin"];
    [p setProgress:0 detail:archive.lastPathComponent];
    __block AMArchiveTask *task = nil;
    p.cancelHandler = ^{ task.cancelled = YES; };
    UIViewController *presenter = [AMUI topPresenterFrom:vc];
    [presenter presentViewController:p animated:YES completion:^{
        task = [AMArchiver extractArchive:archive toDirectory:directory password:password progress:^(double fraction, NSString *item) {
            [p setProgress:fraction detail:item];
        } completion:^(NSURL *result, NSError *error) {
            [p dismissViewControllerAnimated:YES completion:^{
                if (result) {
                    [AMUI hapticSuccess];
                    [AMUI toast:[NSString stringWithFormat:@"已解压“%@”", result.lastPathComponent] symbol:@"checkmark.circle.fill"];
                    if (completion) completion(result);
                    return;
                }
                if (error.code == AMArchiveErrorCancelled) {
                    if (completion) completion(nil);
                    return;
                }
                if (error.code == AMArchiveErrorNeedPassword || error.code == AMArchiveErrorBadPassword) {
                    BOOL bad = error.code == AMArchiveErrorBadPassword;
                    if (bad) [AMUI hapticError];
                    [AMUI promptWithTitle:bad ? @"密码错误" : @"输入密码"
                                  message:bad ? @"请重新输入密码。" : [NSString stringWithFormat:@"“%@”已加密。", archive.lastPathComponent]
                              placeholder:@"密码"
                                  initial:nil
                                   secure:YES
                             confirmTitle:@"解压"
                                     from:vc
                                  handler:^(NSString *text) {
                        if (text.length) [self extractArchive:archive into:directory password:text from:vc completion:completion];
                        else if (completion) completion(nil);
                    }];
                    return;
                }
                [AMUI hapticError];
                [AMUI showError:error title:@"无法解压" from:vc];
                if (completion) completion(nil);
            }];
        }];
    }];
}

+ (NSString *)suggestedNameForItems:(NSArray<NSURL *> *)items {
    if (items.count == 1) {
        NSURL *u = items.firstObject;
        NSNumber *isDir = nil;
        [u getResourceValue:&isDir forKey:NSURLIsDirectoryKey error:nil];
        NSString *n = isDir.boolValue ? u.lastPathComponent : u.lastPathComponent.stringByDeletingPathExtension;
        if (n.length) return n;
    }
    return @"归档";
}

+ (void)compressItems:(NSArray<NSURL *> *)items suggestedName:(NSString *)name into:(NSURL *)directory from:(UIViewController *)vc completion:(void (^)(NSURL *))completion {
    if (items.count == 0) return;
    AMCompressViewController *opts = [[AMCompressViewController alloc] initWithItems:items suggestedName:name ?: [self suggestedNameForItems:items]];
    __weak UIViewController *weakVC = vc;
    opts.onConfirm = ^(AMCompressSettings *settings) {
        UIViewController *from = weakVC;
        if (from) [self compressItems:items settings:settings into:directory from:from completion:completion];
    };
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:opts];
    nav.modalPresentationStyle = UIModalPresentationFormSheet;
    [[AMUI topPresenterFrom:vc] presentViewController:nav animated:YES completion:nil];
}

+ (void)compressItems:(NSArray<NSURL *> *)items settings:(AMCompressSettings *)s into:(NSURL *)directory from:(UIViewController *)vc completion:(void (^)(NSURL *))completion {
    AMProgressController *p = [[AMProgressController alloc] initWithTitle:@"正在压缩…" symbol:@"doc.zipper"];
    [p setProgress:0 detail:[NSString stringWithFormat:@"%@.%@", s.name, @(am_format_extension(s.format))]];
    __block AMArchiveTask *task = nil;
    p.cancelHandler = ^{ task.cancelled = YES; };
    [[AMUI topPresenterFrom:vc] presentViewController:p animated:YES completion:^{
        task = [AMArchiver createArchiveNamed:s.name inDirectory:directory fromItems:items format:s.format level:s.level
                                     password:s.password encryption:s.encryption progress:^(double fraction, NSString *item) {
            [p setProgress:fraction detail:item];
        } completion:^(NSURL *result, NSError *error) {
            [p dismissViewControllerAnimated:YES completion:^{
                if (result) {
                    [AMUI hapticSuccess];
                } else if (error.code != AMArchiveErrorCancelled) {
                    [AMUI hapticError];
                    [AMUI showError:error title:@"无法压缩" from:vc];
                }
                if (completion) completion(result);
            }];
        }];
    }];
}

#pragma mark - Photos

+ (NSString *)typeForProvider:(NSItemProvider *)provider imagesOnly:(BOOL)imagesOnly {
    for (NSString *ident in provider.registeredTypeIdentifiers) {
        UTType *t = [UTType typeWithIdentifier:ident];
        if (!t || [ident isEqualToString:@"com.apple.live-photo-bundle"]) continue;
        if ([t conformsToType:UTTypeImage]) return ident;
        if (!imagesOnly && [t conformsToType:UTTypeMovie]) return ident;
    }
    return nil;
}

+ (void)importPickerResults:(NSArray<PHPickerResult *> *)results into:(NSURL *)directory imagesOnly:(BOOL)imagesOnly from:(UIViewController *)vc completion:(void (^)(NSArray<NSURL *> *))completion {
    if (results.count == 0) { completion(@[]); return; }
    AMProgressController *p = [[AMProgressController alloc] initWithTitle:@"正在读取照片…" symbol:@"photo.on.rectangle"];
    [p setProgress:0 detail:[NSString stringWithFormat:@"0 / %lu", (unsigned long)results.count]];
    AMArchiveTask *task = [AMArchiveTask new];
    p.cancelHandler = ^{ task.cancelled = YES; };
    [[AMUI topPresenterFrom:vc] presentViewController:p animated:YES completion:^{
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSFileManager *fm = NSFileManager.defaultManager;
        [fm createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:nil];
        NSMutableArray<NSURL *> *urls = [NSMutableArray array];
        NSInteger failed = 0;
        for (NSUInteger i = 0; i < results.count && !task.cancelled; i++) {
            NSItemProvider *provider = results[i].itemProvider;
            NSString *type = [self typeForProvider:provider imagesOnly:imagesOnly];
            if (!type) { failed++; continue; }
            dispatch_semaphore_t sem = dispatch_semaphore_create(0);
            __block NSURL *copied = nil;
            [provider loadFileRepresentationForTypeIdentifier:type completionHandler:^(NSURL *url, NSError *error) {
                if (url) {
                    NSString *name = provider.suggestedName.length ? provider.suggestedName : [NSString stringWithFormat:@"IMG_%04lu", (unsigned long)i + 1];
                    NSString *ext = url.pathExtension.length ? url.pathExtension : [UTType typeWithIdentifier:type].preferredFilenameExtension;
                    if (ext.length && ![name.pathExtension.lowercaseString isEqualToString:ext.lowercaseString])
                        name = [name stringByAppendingPathExtension:ext];
                    NSURL *dest = [AMUI uniqueURLForName:name inDirectory:directory];
                    if ([fm copyItemAtURL:url toURL:dest error:nil]) copied = dest;
                }
                dispatch_semaphore_signal(sem);
            }];
            dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
            if (copied) [urls addObject:copied];
            else failed++;
            NSUInteger done = i + 1;
            dispatch_async(dispatch_get_main_queue(), ^{
                [p setProgress:(double)done / results.count detail:[NSString stringWithFormat:@"%lu / %lu", (unsigned long)done, (unsigned long)results.count]];
            });
        }
        BOOL cancelled = task.cancelled;
        dispatch_async(dispatch_get_main_queue(), ^{
            [p dismissViewControllerAnimated:YES completion:^{
                if (cancelled) {
                    for (NSURL *u in urls) [fm removeItemAtURL:u error:nil];
                    completion(@[]);
                    return;
                }
                if (failed > 0)
                    [AMUI showMessage:[NSString stringWithFormat:@"有 %ld 项无法读取（可能尚未从 iCloud 下载）。", (long)failed] title:@"部分项目未导入" from:vc];
                completion(urls);
            }];
        });
    });
    }];
}

@end
