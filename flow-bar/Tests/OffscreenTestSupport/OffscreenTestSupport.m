#import "OffscreenTestSupport.h"
#import <objc/runtime.h>

#import <XCTest/XCTest.h>

static BOOL installed;
static id observer;
static NSLock *beepLock;
static NSMutableArray<NSString *> *beeps;
static NSString *runningTest;
static NSUInteger testBeepStart;
static char compositorKey;
static NSMutableArray<NSString *> *violations;

static void CheckIsolation(void) {
    for (NSWindow *window in NSApp.orderedWindows) {
        BOOL intersects = NO;
        for (NSScreen *screen in NSScreen.screens) {
            intersects |= NSIntersectsRect(window.frame, screen.frame);
        }
        if (window.isKeyWindow || (window.isVisible && (intersects || (window.alphaValue != 0 && !objc_getAssociatedObject(window, &compositorKey))))) {
            [violations addObject:@"HYG2: test window escaped offscreen isolation"];
        }
    }
    if (NSApp.isActive) [violations addObject:@"HYG2: test application became active"];
}
static void Exchange(Class cls, SEL original, SEL replacement) {
    method_exchangeImplementations(class_getInstanceMethod(cls, original), class_getInstanceMethod(cls, replacement));
}

static NSPoint OffscreenOrigin(NSSize size) {
    // Compute against ALL displays, including screens above/left of the primary.
    CGFloat left = 0, bottom = 0;
    for (NSScreen *screen in NSScreen.screens) {
        left = MIN(left, NSMinX(screen.frame));
        bottom = MIN(bottom, NSMinY(screen.frame));
    }
    return NSMakePoint(left - size.width - 10000, bottom - size.height - 10000);
}

static void Prepare(NSWindow *window) {
    window.alphaValue = objc_getAssociatedObject(window, &compositorKey) ? 1 : 0;
    window.animationBehavior = NSWindowAnimationBehaviorNone;
    window.hidesOnDeactivate = NO;
    [window setFrameOrigin:OffscreenOrigin(window.frame.size)];
}

@interface VLOffscreenObserver : NSObject <XCTestObservation>
@end
@implementation VLOffscreenObserver
- (void)testCaseWillStart:(XCTestCase *)testCase {
    [beepLock lock]; runningTest = testCase.name; testBeepStart = beeps.count; [beepLock unlock];
}
- (void)testBundleDidFinish:(NSBundle *)bundle {
    [beepLock lock];
    NSArray *records = [beeps copy];
    [beepLock unlock];
    for (NSString *record in records) fprintf(stderr, "%s\n", record.UTF8String);
    fprintf(stderr, "BEEP_AUDIT count=%lu\n", (unsigned long)records.count);
}

- (void)testCaseDidFinish:(id)testCase {
    void (^check)(void) = ^{
        [beepLock lock];
        NSArray *unexpected = [beeps subarrayWithRange:NSMakeRange(testBeepStart, beeps.count - testBeepStart)];
        [beepLock unlock];
        for (NSString *record in unexpected) {
            [testCase recordFailureWithDescription:record inFile:@__FILE__ atLine:__LINE__ expected:YES];
        }
        CheckIsolation();
        for (NSString *violation in violations) {
            [testCase recordFailureWithDescription:violation inFile:@__FILE__ atLine:__LINE__ expected:YES];
        }
        [violations removeAllObjects];
    };
    if (NSThread.isMainThread) check(); else dispatch_sync(dispatch_get_main_queue(), check);
}
@end

@implementation NSResponder (VLBeepAudit)
- (void)vl_noResponderFor:(SEL)eventSelector {
    BOOL key = eventSelector == @selector(keyDown:) || eventSelector == @selector(keyUp:)
        || eventSelector == @selector(performKeyEquivalent:) || eventSelector == @selector(flagsChanged:);
    if (!key) { [self vl_noResponderFor:eventSelector]; return; }
    [beepLock lock];
    [beeps addObject:[NSString stringWithFormat:@"BEEP: %@ responder=%@ selector=%@",
        runningTest ?: @"outside-test", NSStringFromClass(self.class), NSStringFromSelector(eventSelector)]];
    [beepLock unlock];
}
@end

@implementation NSWindow (VLOffscreen)
- (NSRect)vl_constrainFrameRect:(NSRect)frame toScreen:(NSScreen *)screen { return frame; }
- (void)vl_setFrame:(NSRect)frame display:(BOOL)display {
    if (self.isVisible || objc_getAssociatedObject(self, &compositorKey)) frame.origin = OffscreenOrigin(frame.size);
    [self vl_setFrame:frame display:display];
}
- (void)vl_setFrameOrigin:(NSPoint)origin {
    if (self.isVisible || objc_getAssociatedObject(self, &compositorKey)) origin = OffscreenOrigin(self.frame.size);
    [self vl_setFrameOrigin:origin];
}
- (void)vl_orderWindow:(NSWindowOrderingMode)place relativeTo:(NSInteger)other {
    if (place != NSWindowOut) Prepare(self);
    [self vl_orderWindow:place relativeTo:other];
}
- (void)vl_orderFrontRegardless {
    Prepare(self);
    [self vl_orderFrontRegardless];
}
- (void)vl_makeKeyAndOrderFront:(id)sender {
    // Preserve the controller's show/reuse/close lifecycle without acquiring focus.
    VLOrderTestWindow(self);
}
- (void)vl_makeKeyWindow {}
- (void)vl_makeMainWindow {}
@end

@implementation NSApplication (VLOffscreen)
- (void)vl_activateIgnoringOtherApps:(BOOL)ignore {}
- (void)vl_activate {}
- (void)vl_unhide:(id)sender { [self unhideWithoutActivation]; }
@end

@interface VLOffscreenBootstrap : NSObject
@end
@implementation VLOffscreenBootstrap
+ (void)load {
    @autoreleasepool {
        Exchange(NSWindow.class, @selector(setFrame:display:), @selector(vl_setFrame:display:));
        Exchange(NSWindow.class, @selector(setFrameOrigin:), @selector(vl_setFrameOrigin:));
        Exchange(NSWindow.class, @selector(constrainFrameRect:toScreen:), @selector(vl_constrainFrameRect:toScreen:));
        Exchange(NSWindow.class, @selector(orderWindow:relativeTo:), @selector(vl_orderWindow:relativeTo:));
        Exchange(NSWindow.class, @selector(orderFrontRegardless), @selector(vl_orderFrontRegardless));
        Exchange(NSWindow.class, @selector(makeKeyAndOrderFront:), @selector(vl_makeKeyAndOrderFront:));
        Exchange(NSWindow.class, @selector(makeKeyWindow), @selector(vl_makeKeyWindow));
        Exchange(NSWindow.class, @selector(makeMainWindow), @selector(vl_makeMainWindow));
        Exchange(NSApplication.class, @selector(activateIgnoringOtherApps:), @selector(vl_activateIgnoringOtherApps:));
        if ([NSApplication instancesRespondToSelector:@selector(activate)]) {
            Exchange(NSApplication.class, @selector(activate), @selector(vl_activate));
        }
        Exchange(NSApplication.class, @selector(unhide:), @selector(vl_unhide:));
        violations = [NSMutableArray new];
        beepLock = [NSLock new]; beeps = [NSMutableArray new];
        Exchange(NSResponder.class, @selector(noResponderFor:), @selector(vl_noResponderFor:));
        for (NSNotificationName name in @[NSWindowDidBecomeKeyNotification, NSWindowDidMoveNotification,
                                           NSWindowDidResizeNotification, NSWindowDidChangeOcclusionStateNotification,
                                           NSApplicationDidBecomeActiveNotification]) {
            [NSNotificationCenter.defaultCenter addObserverForName:name object:nil queue:nil
                usingBlock:^(NSNotification *note) { CheckIsolation(); }];
        }
        observer = [VLOffscreenObserver new];
        [[XCTestObservationCenter sharedTestObservationCenter] addTestObserver:observer];
        installed = YES;
    }
}
@end

BOOL VLOffscreenPolicyInstalled(void) { return installed; }
void VLOrderTestWindow(NSWindow *window) {
    Prepare(window);
    [window orderFront:nil];
}
void VLOrderCompositorTestWindow(NSWindow *window) {
    // alphaValue=0 makes CGWindowListCreateImage return an all-transparent image.
    // The compositor alone draws native glass correctly. Geometry is still forced
    // outside every NSScreen before ordering AND on subsequent moves/resizes.
    objc_setAssociatedObject(window, &compositorKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    VLOrderTestWindow(window);
}
void VLPostTestActivation(void) {
    // Exercise activation observers without asking the WindowServer for focus.
    [NSNotificationCenter.defaultCenter postNotificationName:NSApplicationDidBecomeActiveNotification object:NSApp];
}
