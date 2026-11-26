#import "AMActions.h"
#import "AMPasswordBook.h"
#import "AMProgressController.h"
#import "AMQuickLook.h"
#import "AMUI.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

@implementation AMPickedAsset
@end

typedef AMArchiveTask *_Nonnull (^AMArchiveWork)(NSArray<NSString *> *passwords, AMProgressBlock progress,
                                                   void (^done)(NSURL *_Nullable result, NSError *_Nullable error));

@implementation AMActions

#pragma mark - Password-aware runner

+ (void)askPasswordTitle:(NSString *)title
                 message:(NSString *)message
             actionTitle:(NSString *)actionTitle
                    from:(UIViewController *)vc
                 handler:(void (^)(NSString *text, BOOL remember))handler {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = L(@"密码");
        tf.secureTextEntry = YES;
        tf.autocorrectionType = UITextAutocorrectionTypeNo;
        tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
    }];
    __weak UIAlertController *weakA = a;
    UIAlertAction *go = [UIAlertAction actionWithTitle:actionTitle style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        handler(weakA.textFields.firstObject.text ?: @"", NO);
    }];
    [a addAction:go];
    [a addAction:[UIAlertAction actionWithTitle:L(@"确定并存入密码本") style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
           handler(weakA.textFields.firstObject.text ?: @"", YES);
       }]];
    [a addAction:[UIAlertAction actionWithTitle:L(@"取消") style:UIAlertActionStyleCancel handler:^(UIAlertAction *x) {
           handler(@"", NO);
       }]];
    a.preferredAction = go;
    [[AMUI topPresenterFrom:vc] presentViewController:a animated:YES completion:nil];
}

/// Runs `work` behind a progress card. Saved passwords are tried first; if the archive still needs
/// one, asks and retries. Completion gets the result, or nil plus whether the user cancelled.
+ (void)runJobTitle:(NSString *)title
             symbol:(NSString *)symbol
            archive:(NSURL *)archive
              typed:(NSString *)typed
           remember:(BOOL)remember
               from:(UIViewController *)vc
               work:(AMArchiveWork)work
         completion:(void (^)(NSURL *result, BOOL cancelled))completion {
    NSMutableArray<NSString *> *passwords = [NSMutableArray array];
    if (typed.length) [passwords addObject:typed];
    for (NSString *s in AMPasswordBook.passwords)
        if (![passwords containsObject:s]) [passwords addObject:s];

    AMProgressController *p = [[AMProgressController alloc] initWithTitle:title symbol:symbol];
    [p setProgress:0 detail:archive.lastPathComponent];
    __block AMArchiveTask *task = nil;
    p.cancelHandler = ^{ task.cancelled = YES; };
    id op = [AMUI beginLongOperation];
    [[AMUI topPresenterFrom:vc] presentViewController:p animated:YES completion:^{
        task = work(passwords, ^(double fraction, NSString *item) {
            [p setProgress:fraction detail:item];
        }, ^(NSURL *result, NSError *error) {
            [AMUI endLongOperation:op];
            [p dismissViewControllerAnimated:YES completion:^{
                if (result) {
                    if (remember && typed.length) [AMPasswordBook addPassword:typed];
                    completion(result, NO);
                    return;
                }
                if (error.code == AMArchiveErrorCancelled) {
                    completion(nil, YES);
                    return;
                }
                if (error.code == AMArchiveErrorNeedPassword || error.code == AMArchiveErrorBadPassword) {
                    BOOL wrong = typed.length > 0;
                    if (wrong) [AMUI hapticError];
                    NSString *name = archive.lastPathComponent;
                    NSString *msg = wrong ? L(@"密码不正确，请重新输入。")
                                  : AMPasswordBook.passwords.count ? [NSString stringWithFormat:L(@"“%@”已加密，密码本中没有匹配的密码。"), name]
                                                                   : [NSString stringWithFormat:L(@"“%@”已加密。"), name];
                    [self askPasswordTitle:wrong ? L(@"密码错误") : L(@"输入密码") message:msg actionTitle:L(@"确定") from:vc
                                   handler:^(NSString *text, BOOL rememberIt) {
                        if (text.length) [self runJobTitle:title symbol:symbol archive:archive typed:text remember:rememberIt from:vc work:work completion:completion];
                        else completion(nil, YES);
                    }];
                    return;
                }
                [AMUI hapticError];
                [AMUI showError:error title:L(@"无法解压") from:vc];
                completion(nil, NO);
            }];
        });
    }];
}

#pragma mark - Extract

+ (void)extractArchive:(NSURL *)archive into:(NSURL *)directory onlyPaths:(NSSet<NSString *> *)paths from:(UIViewController *)vc completion:(void (^)(NSURL *))completion {
    [self extractArchive:archive into:directory onlyPaths:paths announce:YES from:vc completion:^(NSURL *result, BOOL cancelled) {
        if (completion) completion(result);
    }];
}

+ (void)extractArchive:(NSURL *)archive
                  into:(NSURL *)directory
             onlyPaths:(NSSet<NSString *> *)paths
              announce:(BOOL)announce
                  from:(UIViewController *)vc
            completion:(void (^)(NSURL *result, BOOL cancelled))completion {
    AMArchiveWork work = ^AMArchiveTask *(NSArray<NSString *> *passwords, AMProgressBlock progress, void (^done)(NSURL *, NSError *)) {
        AMExtractOptions *o = [AMExtractOptions fromSettings];
        o.passwords = passwords;
        o.onlyPaths = paths;
        return [AMArchiver extractArchive:archive toDirectory:directory options:o progress:progress completion:done];
    };
    [self runJobTitle:L(@"正在解压…") symbol:@"arrow.up.bin" archive:archive typed:nil remember:NO from:vc work:work
           completion:^(NSURL *result, BOOL cancelled) {
        if (result) {
            [AMUI hapticSuccess];
            if (announce) [AMUI toast:[NSString stringWithFormat:L(@"已解压“%@”"), result.lastPathComponent] symbol:@"checkmark.circle.fill"];
        }
        completion(result, cancelled);
    }];
}

+ (void)extractArchives:(NSArray<NSURL *> *)archives into:(NSURL *)directory from:(UIViewController *)vc completion:(void (^)(NSArray<NSURL *> *))completion {
    [self extractArchives:archives index:0 results:[NSMutableArray array] into:directory from:vc completion:completion];
}

+ (void)extractArchives:(NSArray<NSURL *> *)archives
                  index:(NSUInteger)index
                results:(NSMutableArray<NSURL *> *)results
                   into:(NSURL *)directory
                   from:(UIViewController *)vc
             completion:(void (^)(NSArray<NSURL *> *))completion {
    if (index >= archives.count) {
        if (results.count) [AMUI toast:[NSString stringWithFormat:L(@"已解压 %lu 个压缩包"), (unsigned long)results.count] symbol:@"checkmark.circle.fill"];
        if (completion) completion(results);
        return;
    }
    [self extractArchive:archives[index] into:directory onlyPaths:nil announce:NO from:vc completion:^(NSURL *result, BOOL cancelled) {
        if (result) [results addObject:result];
        if (cancelled) {  // stop the whole batch
            if (completion) completion(results);
            return;
        }
        [self extractArchives:archives index:index + 1 results:results into:directory from:vc completion:completion];
    }];
}

+ (void)previewEntry:(NSString *)path inArchive:(NSURL *)archive from:(UIViewController *)vc {
    AMArchiveWork work = ^AMArchiveTask *(NSArray<NSString *> *passwords, AMProgressBlock progress, void (^done)(NSURL *, NSError *)) {
        return [AMArchiver extractEntry:path fromArchive:archive passwords:passwords progress:progress completion:done];
    };
    [self runJobTitle:L(@"正在打开…") symbol:@"eye" archive:archive typed:nil remember:NO from:vc work:work
           completion:^(NSURL *file, BOOL cancelled) {
        if (!file) return;
        // file = tmp/Preview/<uuid>/<entry path>; remove the <uuid> folder when the preview closes.
        NSString *previewRoot = [NSTemporaryDirectory() stringByAppendingPathComponent:@"Preview"].stringByStandardizingPath;
        NSString *rest = [file.path.stringByStandardizingPath stringByReplacingOccurrencesOfString:[previewRoot stringByAppendingString:@"/"] withString:@""];
        NSString *uuid = rest.pathComponents.firstObject;
        AMQuickLook *ql = [[AMQuickLook alloc] initWithItems:@[ [AMPreviewItem itemWithURL:file title:file.lastPathComponent] ] index:0];
        ql.onDismiss = ^{
            if (uuid.length && ![uuid isEqualToString:rest])
                [NSFileManager.defaultManager removeItemAtPath:[previewRoot stringByAppendingPathComponent:uuid] error:nil];
        };
        [[AMUI topPresenterFrom:vc] presentViewController:ql animated:YES completion:nil];
    }];
}

#pragma mark - Compress

+ (NSString *)suggestedNameForItems:(NSArray<NSURL *> *)items {
    if (items.count == 1) {
        NSURL *u = items.firstObject;
        NSNumber *isDir = nil;
        [u getResourceValue:&isDir forKey:NSURLIsDirectoryKey error:nil];
        NSString *n = isDir.boolValue ? u.lastPathComponent : u.lastPathComponent.stringByDeletingPathExtension;
        if (n.length) return n;
    }
    return L(@"归档");
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
    AMProgressController *p = [[AMProgressController alloc] initWithTitle:L(@"正在压缩…") symbol:@"doc.zipper"];
    [p setProgress:0 detail:[NSString stringWithFormat:@"%@.%@", s.name, @(am_format_extension(s.format))]];
    __block AMArchiveTask *task = nil;
    p.cancelHandler = ^{ task.cancelled = YES; };
    id op = [AMUI beginLongOperation];
    [[AMUI topPresenterFrom:vc] presentViewController:p animated:YES completion:^{
        task = [AMArchiver createArchiveNamed:s.name inDirectory:directory fromItems:items format:s.format level:s.level
                                     password:s.password encryption:s.encryption progress:^(double fraction, NSString *item) {
            [p setProgress:fraction detail:item];
        } completion:^(NSURL *result, NSError *error) {
            [AMUI endLongOperation:op];
            [p dismissViewControllerAnimated:YES completion:^{
                if (result) {
                    [AMUI hapticSuccess];
                } else if (error.code != AMArchiveErrorCancelled) {
                    [AMUI hapticError];
                    [AMUI showError:error title:L(@"无法压缩") from:vc];
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

+ (void)importPickerResults:(NSArray<PHPickerResult *> *)results into:(NSURL *)directory imagesOnly:(BOOL)imagesOnly from:(UIViewController *)vc completion:(void (^)(NSArray<AMPickedAsset *> *))completion {
    if (results.count == 0) { completion(@[]); return; }
    AMProgressController *p = [[AMProgressController alloc] initWithTitle:L(@"正在读取照片…") symbol:@"photo.on.rectangle"];
    [p setProgress:0 detail:[NSString stringWithFormat:@"0 / %lu", (unsigned long)results.count]];
    AMArchiveTask *task = [AMArchiveTask new];
    p.cancelHandler = ^{ task.cancelled = YES; };
    id op = [AMUI beginLongOperation];
    [[AMUI topPresenterFrom:vc] presentViewController:p animated:YES completion:^{
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSFileManager *fm = NSFileManager.defaultManager;
        [fm createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:nil];
        NSMutableArray<AMPickedAsset *> *assets = [NSMutableArray array];
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
            if (copied) {
                AMPickedAsset *a = [AMPickedAsset new];
                a.url = copied;
                a.assetIdentifier = results[i].assetIdentifier;
                a.isVideo = [[UTType typeWithIdentifier:type] conformsToType:UTTypeMovie];
                [assets addObject:a];
            } else {
                failed++;
            }
            NSUInteger done = i + 1;
            dispatch_async(dispatch_get_main_queue(), ^{
                [p setProgress:(double)done / results.count detail:[NSString stringWithFormat:@"%lu / %lu", (unsigned long)done, (unsigned long)results.count]];
            });
        }
        BOOL cancelled = task.cancelled;
        dispatch_async(dispatch_get_main_queue(), ^{
            [AMUI endLongOperation:op];
            [p dismissViewControllerAnimated:YES completion:^{
                if (cancelled) {
                    for (AMPickedAsset *a in assets) [fm removeItemAtURL:a.url error:nil];
                    completion(@[]);
                    return;
                }
                if (failed > 0)
                    [AMUI showMessage:[NSString stringWithFormat:L(@"有 %ld 项无法读取（可能尚未从 iCloud 下载）。"), (long)failed] title:L(@"部分项目未导入") from:vc];
                completion(assets);
            }];
        });
    });
    }];
}

@end
