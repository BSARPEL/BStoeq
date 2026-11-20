// Runtime integration check. Allows every running app and every known system item;
// never writes preferences. The assertion is released before the process exits.
#import <AppKit/AppKit.h>
#import "STMenuBarShim.h"

int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        if (![STMenuBarShim isAvailable]) { fprintf(stderr, "FAIL: framework unavailable\n"); return 1; }
        NSMutableArray<NSString *> *apps = [NSMutableArray array];
        for (NSRunningApplication *app in NSWorkspace.sharedWorkspace.runningApplications) {
            if (app.bundleIdentifier) [apps addObject:app.bundleIdentifier];
        }
        NSMutableArray<NSNumber *> *items = [NSMutableArray array];
        for (int i = 0; i <= 255; i++) [items addObject:@(i)];
        __block id token = nil;
        __block BOOL finished = NO;
        __block BOOL successful = NO;
        token = [STMenuBarShim activateWithAllowedBundleIdentifiers:apps allowedSystemItems:items completion:^(NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                successful = error == nil;
                if (error) fprintf(stderr, "FAIL: %s\n", error.localizedDescription.UTF8String);
                [STMenuBarShim invalidate:token]; token = nil;
                finished = YES;
            });
        }];
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:5];
        while (!finished && deadline.timeIntervalSinceNow > 0) {
            [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
        }
        [STMenuBarShim invalidate:token];
        if (!finished) fprintf(stderr, "FAIL: activation timeout\n");
        if (successful) puts("PASS: native assertion activated, completion succeeded, assertion released");
        return successful ? 0 : 1;
    }
}
