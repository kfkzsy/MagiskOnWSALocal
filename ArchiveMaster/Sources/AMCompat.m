// `@available(...)` checks compile to calls into compiler-rt, which the Linux cross toolchain
// does not ship for iOS. These are the same entry points, implemented with NSProcessInfo.
#import <Foundation/Foundation.h>

int32_t __isPlatformVersionAtLeast(uint32_t platform, uint32_t major, uint32_t minor, uint32_t subminor);
int32_t __isOSVersionAtLeast(int32_t major, int32_t minor, int32_t subminor);

int32_t __isPlatformVersionAtLeast(uint32_t platform, uint32_t major, uint32_t minor, uint32_t subminor) {
    (void)platform;
    NSOperatingSystemVersion v = { (NSInteger)major, (NSInteger)minor, (NSInteger)subminor };
    return [NSProcessInfo.processInfo isOperatingSystemAtLeastVersion:v] ? 1 : 0;
}

int32_t __isOSVersionAtLeast(int32_t major, int32_t minor, int32_t subminor) {
    NSOperatingSystemVersion v = { major, minor, subminor };
    return [NSProcessInfo.processInfo isOperatingSystemAtLeastVersion:v] ? 1 : 0;
}
