#import <UIKit/UIKit.h>
#import "AMAppDelegate.h"

int main(int argc, char *argv[]) {
    NSString *delegateClassName;
    @autoreleasepool {
        delegateClassName = NSStringFromClass(AMAppDelegate.class);
    }
    return UIApplicationMain(argc, argv, nil, delegateClassName);
}
