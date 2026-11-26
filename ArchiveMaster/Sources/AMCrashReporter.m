#import "AMCrashReporter.h"
#import "AMUI.h"
#include <execinfo.h>
#include <fcntl.h>
#include <mach-o/dyld.h>
#include <signal.h>
#include <string.h>
#include <sys/sysctl.h>
#include <unistd.h>

static char gSignalPath[1024];
static char gHeader[640];
static NSString *gExceptionPath;
static NSUncaughtExceptionHandler *gPreviousHandler;
static const int kSignals[] = { SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGTRAP };
static struct sigaction gPrevious[sizeof kSignals / sizeof *kSignals];

static void AMWrite(int fd, const char *s) {
    size_t n = strlen(s);
    while (n) {
        ssize_t w = write(fd, s, n);
        if (w <= 0) return;
        s += w;
        n -= (size_t)w;
    }
}

/// Runs inside the signal handler: only async-signal-safe calls (plus backtrace, as crash reporters do).
static void AMSignalHandler(int sig, siginfo_t *info, void *context) {
    int fd = open(gSignalPath, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd >= 0) {
        AMWrite(fd, gHeader);
        char num[16];
        int v = sig, i = (int)sizeof num - 1;
        num[i] = '\0';
        do { num[--i] = (char)('0' + v % 10); v /= 10; } while (v && i > 0);
        AMWrite(fd, "Signal: ");
        AMWrite(fd, num + i);
        AMWrite(fd, "\nBacktrace:\n");
        void *frames[64];
        int count = backtrace(frames, 64);
        backtrace_symbols_fd(frames, count, fd);
        AMWrite(fd, "\n");
        close(fd);
    }
    // Hand over to whatever was installed before (or the default action) so the process still ends.
    for (size_t k = 0; k < sizeof kSignals / sizeof *kSignals; k++) {
        if (kSignals[k] == sig) {
            sigaction(sig, &gPrevious[k], NULL);
            break;
        }
    }
    raise(sig);
}

static void AMExceptionHandler(NSException *exception) {
    NSString *text = [NSString stringWithFormat:@"%s\nException: %@\nReason: %@\nStack:\n%@\n", gHeader, exception.name,
                                                exception.reason, [exception.callStackSymbols componentsJoinedByString:@"\n"]];
    [text writeToFile:gExceptionPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    if (gPreviousHandler) gPreviousHandler(exception);
}

@implementation AMCrashReporter

+ (NSURL *)directory {
    return [NSFileManager.defaultManager URLsForDirectory:NSLibraryDirectory inDomains:NSUserDomainMask].firstObject;
}

+ (void)install {
    NSURL *dir = self.directory;
    gExceptionPath = [dir URLByAppendingPathComponent:@"LastCrash-exception.txt"].path;
    strlcpy(gSignalPath, [dir URLByAppendingPathComponent:@"LastCrash-signal.txt"].fileSystemRepresentation, sizeof gSignalPath);

    char model[64] = "?";
    size_t len = sizeof model;
    sysctlbyname("hw.machine", model, &len, NULL, 0);
    NSDictionary *info = NSBundle.mainBundle.infoDictionary;
    NSOperatingSystemVersion os = NSProcessInfo.processInfo.operatingSystemVersion;
    // The load address lets the developer map stack addresses back to code.
    snprintf(gHeader, sizeof gHeader, "ArchiveMaster %s (%s) | iOS %ld.%ld.%ld | %s | image %p slide 0x%lx\n",
             [info[@"CFBundleShortVersionString"] UTF8String] ?: "?", [info[@"CFBundleVersion"] UTF8String] ?: "?",
             (long)os.majorVersion, (long)os.minorVersion, (long)os.patchVersion, model,
             (const void *)_dyld_get_image_header(0), (unsigned long)_dyld_get_image_vmaddr_slide(0));

    gPreviousHandler = NSGetUncaughtExceptionHandler();
    NSSetUncaughtExceptionHandler(AMExceptionHandler);
    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_sigaction = AMSignalHandler;
    sa.sa_flags = SA_SIGINFO;
    sigemptyset(&sa.sa_mask);
    for (size_t k = 0; k < sizeof kSignals / sizeof *kSignals; k++) sigaction(kSignals[k], &sa, &gPrevious[k]);
}

+ (NSString *)pendingReport {
    NSMutableString *report = [NSMutableString string];
    for (NSString *name in @[ @"LastCrash-exception.txt", @"LastCrash-signal.txt" ]) {
        NSString *text = [NSString stringWithContentsOfURL:[self.directory URLByAppendingPathComponent:name] encoding:NSUTF8StringEncoding error:nil];
        if (text.length) [report appendFormat:@"%@\n", text];
    }
    return report.length ? report : nil;
}

+ (void)clearPendingReport {
    for (NSString *name in @[ @"LastCrash-exception.txt", @"LastCrash-signal.txt" ])
        [NSFileManager.defaultManager removeItemAtURL:[self.directory URLByAppendingPathComponent:name] error:nil];
}

+ (BOOL)presentPendingReportFrom:(UIViewController *)vc {
    NSString *report = self.pendingReport;
    if (!report) return NO;
    [self clearPendingReport];
    UIAlertController *a = [UIAlertController alertControllerWithTitle:L(@"解压大师上次意外退出")
                                                               message:L(@"已记录错误原因。把报告发给开发者可以帮助尽快修复。")
                                                        preferredStyle:UIAlertControllerStyleAlert];
    UIAlertAction *share = [UIAlertAction actionWithTitle:L(@"分享报告") style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        UIActivityViewController *s = [[UIActivityViewController alloc] initWithActivityItems:@[ report ] applicationActivities:nil];
        s.popoverPresentationController.sourceView = vc.view;
        s.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(vc.view.bounds), CGRectGetMidY(vc.view.bounds), 1, 1);
        [[AMUI topPresenterFrom:vc] presentViewController:s animated:YES completion:nil];
    }];
    [a addAction:share];
    [a addAction:[UIAlertAction actionWithTitle:L(@"拷贝报告") style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        UIPasteboard.generalPasteboard.string = report;
        [AMUI toast:L(@"已拷贝") symbol:@"doc.on.doc"];
    }]];
    [a addAction:[UIAlertAction actionWithTitle:L(@"不用了") style:UIAlertActionStyleCancel handler:nil]];
    a.preferredAction = share;
    [[AMUI topPresenterFrom:vc] presentViewController:a animated:YES completion:nil];
    return YES;
}

@end
