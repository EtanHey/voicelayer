#import <AppKit/AppKit.h>

/// Test-only process policy, installed at image load before any XCTest method runs.
FOUNDATION_EXPORT BOOL VLOffscreenPolicyInstalled(void);
FOUNDATION_EXPORT void VLOrderTestWindow(NSWindow *window);
/// Native glass needs WindowServer pixels: opaque only while constrained outside every screen.
FOUNDATION_EXPORT void VLOrderCompositorTestWindow(NSWindow *window);
FOUNDATION_EXPORT void VLPostTestActivation(void);
