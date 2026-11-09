#import "DriveTracePreviewView.h"

#import <QuickLookUI/QuickLookUI.h>

@interface DriveTracePreviewView ()

@property(nonatomic, strong) QLPreviewView *previewView;

@end


@implementation DriveTracePreviewView

- (instancetype)initWithURL:(NSURL *)url {
    self = [super initWithFrame:NSZeroRect];
    if (self == nil) {
        return nil;
    }

    QLPreviewView *previewView = [[QLPreviewView alloc] initWithFrame:self.bounds
                                                               style:QLPreviewViewStyleNormal];
    previewView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    previewView.autostarts = NO;
    previewView.previewItem = url;
    [self addSubview:previewView];
    self.previewView = previewView;
    return self;
}

- (void)updateURL:(NSURL *)url {
    self.previewView.previewItem = url;
}

- (void)closePreview {
    self.previewView.previewItem = nil;
    [self.previewView close];
}

@end
