#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Hosts Quick Look without exposing QuickLookUI's transitive modules to Swift.
@interface DriveTracePreviewView : NSView

- (instancetype)initWithURL:(NSURL *)url NS_SWIFT_NAME(init(url:));
- (void)updateURL:(NSURL *)url NS_SWIFT_NAME(update(url:));
- (void)closePreview;

@end

NS_ASSUME_NONNULL_END
