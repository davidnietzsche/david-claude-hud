// Claude HUD — a floating always-on-top panel that shows every running Claude
// Code session, machine load, Anthropic usage limits, and background jobs.
//
// Native shell only: an NSPanel that never steals focus, floats above normal
// windows, follows you across Spaces, and hosts a WKWebView for the interface.
//
// build:  clang -fobjc-arc -O2 -framework Cocoa -framework WebKit \
//               -framework Carbon -framework UserNotifications hud.m -o ClaudeHUD

#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>
#import <Carbon/Carbon.h>
#import <UserNotifications/UserNotifications.h>
#import <mach/mach.h>
#import <sys/sysctl.h>
#import <signal.h>
#import <IOKit/IOKitLib.h>

static NSString *const kFrameKey = @"hudFrame";

// NSLog from an ad-hoc-signed accessory app doesn't reliably reach the unified
// log, and launchd only owns the `open` wrapper so stderr goes nowhere either.
// Write our own file instead.
static void hlog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSString *line = [NSString stringWithFormat:@"%@ %@\n",
                      [NSDate date].description, msg];
    NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:
                      @".claude-hud/hud.log"];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!fh) {
        [line writeToFile:path atomically:NO
                 encoding:NSUTF8StringEncoding error:nil];
        return;
    }
    [fh seekToEndOfFile];
    [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
    [fh closeFile];
}

#pragma mark - Panel

// A panel that can take clicks without activating the app, so clicking the HUD
// never pulls focus away from the terminal you're watching.
@interface HUDPanel : NSPanel
@end

@implementation HUDPanel
- (NSTimeInterval)animationResizeTime:(NSRect)r { return 0.13; }
// Without this the first click on an inactive panel is spent activating it,
// so moving the HUD took two clicks: one to wake it, one to actually drag.
- (BOOL)acceptsFirstMouse:(NSEvent *)e { return YES; }
- (BOOL)canBecomeKeyWindow { return YES; }
- (BOOL)canBecomeMainWindow { return NO; }
@end

// The web view has to accept the first mouse too — otherwise it swallows the
// click that reaches it rather than passing it to the page.
@interface HUDWebView : WKWebView
@end
@implementation HUDWebView
- (BOOL)acceptsFirstMouse:(NSEvent *)e { return YES; }
@end

#pragma mark - Controller

@interface HUD : NSObject <WKScriptMessageHandler, WKNavigationDelegate,
                           NSApplicationDelegate, UNUserNotificationCenterDelegate>
@property (strong) HUDPanel *panel;
@property (strong) HUDWebView *web;
@property (strong) NSStatusItem *statusItem;
@property (strong) NSTimer *timer;
@property (strong) NSString *root;
@property (assign) BOOL ready;
@property (assign) BOOL collecting;
// previous CPU tick counters, for an instantaneous (not since-boot) reading
@property (assign) uint64_t pUser, pSys, pIdle, pNice;
@property (assign) BOOL notifyAllowed;
@property (copy)   NSString *charState;   // @"work", @"wait" or @"rest"
@property (assign) NSInteger charFrame;
@property (assign) NSInteger unread;
@property (strong) NSTimer *charTimer;
@property (assign) float alertVolume;
@property (strong) NSSlider *volumeSlider;
@property (strong) NSString *dockSide;   // @"", @"left" or @"right"
@property (assign) BOOL dockedOut;       // slid out, vs peeking at the edge
@end

@implementation HUD

#pragma mark Machine stats

- (double)cpuPercent {
    host_cpu_load_info_data_t info;
    mach_msg_type_number_t count = HOST_CPU_LOAD_INFO_COUNT;
    if (host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO,
                        (host_info_t)&info, &count) != KERN_SUCCESS) return -1;

    uint64_t u = info.cpu_ticks[CPU_STATE_USER];
    uint64_t s = info.cpu_ticks[CPU_STATE_SYSTEM];
    uint64_t i = info.cpu_ticks[CPU_STATE_IDLE];
    uint64_t n = info.cpu_ticks[CPU_STATE_NICE];

    uint64_t du = u - _pUser, ds = s - _pSys, di = i - _pIdle, dn = n - _pNice;
    _pUser = u; _pSys = s; _pIdle = i; _pNice = n;

    uint64_t total = du + ds + di + dn;
    if (total == 0) return -1;
    return (double)(du + ds + dn) * 100.0 / (double)total;
}

// macOS won't hand out a CPU die temperature without root on Apple silicon —
// the IOKit sensor nodes exist but publish no value. What it will give, free
// and in real time, is its own verdict: thermalState says whether the machine
// is about to throttle, which is the thing you actually care about. The
// battery reading is a real temperature but lags badly (unmoved by 20s of full
// load), so it's shown as context, not as the signal.
- (double)batteryTemp {
    io_service_t svc = IOServiceGetMatchingService(
        kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"));
    if (!svc) return -1;
    CFTypeRef v = IORegistryEntryCreateCFProperty(
        svc, CFSTR("Temperature"), kCFAllocatorDefault, 0);
    IOObjectRelease(svc);
    if (!v) return -1;
    int raw = 0;
    if (CFGetTypeID(v) == CFNumberGetTypeID())
        CFNumberGetValue((CFNumberRef)v, kCFNumberIntType, &raw);
    CFRelease(v);
    return raw > 0 ? raw / 100.0 : -1;   // centi-degrees C
}

- (int)thermalLevel {
    switch ([NSProcessInfo processInfo].thermalState) {
        case NSProcessInfoThermalStateNominal:  return 0;
        case NSProcessInfoThermalStateFair:     return 1;
        case NSProcessInfoThermalStateSerious:  return 2;
        case NSProcessInfoThermalStateCritical: return 3;
    }
    return 0;
}

- (double)memPercent {
    vm_size_t page = 0;
    host_page_size(mach_host_self(), &page);
    vm_statistics64_data_t vm;
    mach_msg_type_number_t count = HOST_VM_INFO64_COUNT;
    if (host_statistics64(mach_host_self(), HOST_VM_INFO64,
                          (host_info64_t)&vm, &count) != KERN_SUCCESS) return -1;

    // Activity Monitor's "Memory Used": app memory + wired + compressed.
    // Counting everything that isn't free would include the file cache, which
    // macOS always keeps full — that reads ~99% no matter what and tells you
    // nothing.
    uint64_t total = [NSProcessInfo processInfo].physicalMemory;
    uint64_t app        = (uint64_t)(vm.internal_page_count - vm.purgeable_count) * page;
    uint64_t wired      = (uint64_t)vm.wire_count * page;
    uint64_t compressed = (uint64_t)vm.compressor_page_count * page;
    uint64_t used = app + wired + compressed;
    return (double)used * 100.0 / (double)total;
}

#pragma mark Setup

- (void)applicationDidFinishLaunching:(NSNotification *)note {
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    self.root = [[NSBundle mainBundle] resourcePath];
    // Running straight from the build dir (no bundle) — fall back to cwd.
    if (![[NSFileManager defaultManager] fileExistsAtPath:
          [self.root stringByAppendingPathComponent:@"ui.html"]]) {
        self.root = [[NSFileManager defaultManager] currentDirectoryPath];
    }

    [self buildPanel];
    [self buildStatusItem];
    [self registerHotkey];
    [self setupNotifications];
    [self restorePinnedIfNewBoot];

    [self cpuPercent];  // prime the tick counters
    self.timer = [NSTimer scheduledTimerWithTimeInterval:1.5 target:self
                    selector:@selector(tick) userInfo:nil repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:self.timer forMode:NSRunLoopCommonModes];
}

- (void)buildPanel {
    NSRect frame = NSMakeRect(0, 0, 360, 460);
    NSString *saved = [[NSUserDefaults standardUserDefaults] stringForKey:kFrameKey];
    if (saved) frame = NSRectFromString(saved);

    self.panel = [[HUDPanel alloc]
        initWithContentRect:frame
                  styleMask:NSWindowStyleMaskBorderless |
                            NSWindowStyleMaskNonactivatingPanel
                    backing:NSBackingStoreBuffered
                      defer:NO];

    self.panel.opaque = NO;
    self.panel.backgroundColor = [NSColor clearColor];
    self.panel.hasShadow = YES;
    self.panel.level = NSStatusWindowLevel;          // above ordinary windows
    self.panel.hidesOnDeactivate = NO;
    self.panel.movableByWindowBackground = NO;       // we drag via the JS bridge
    self.panel.collectionBehavior =
        NSWindowCollectionBehaviorCanJoinAllSpaces |
        NSWindowCollectionBehaviorStationary |
        NSWindowCollectionBehaviorFullScreenAuxiliary |
        NSWindowCollectionBehaviorIgnoresCycle;

    // Deliberately NOT an NSVisualEffectView. It renders its backdrop through
    // the window server, which layer.cornerRadius does not clip, so its material
    // leaked a square frame outside the rounded corners. The page paints its own
    // near-opaque background anyway, so the blur was contributing nothing.
    NSView *root = [[NSView alloc] initWithFrame:frame];
    root.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    root.wantsLayer = YES;
    root.layer.backgroundColor = NSColor.clearColor.CGColor;
    root.layer.cornerRadius = 14.0;
    root.layer.masksToBounds = YES;
    if (@available(macOS 10.15, *)) root.layer.cornerCurve = kCACornerCurveContinuous;
    self.panel.contentView = root;

    WKWebViewConfiguration *cfg = [WKWebViewConfiguration new];
    [cfg.userContentController addScriptMessageHandler:self name:@"hud"];
    self.web = [[HUDWebView alloc] initWithFrame:root.bounds configuration:cfg];
    self.web.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.web.navigationDelegate = self;
    // WKWebView renders through its own remote layer tree, which the parent's
    // masksToBounds does not clip — the page background squares off the corners
    // unless the web view's own layer is rounded too.
    self.web.wantsLayer = YES;
    self.web.layer.backgroundColor = NSColor.clearColor.CGColor;
    self.web.layer.cornerRadius = 14.0;
    self.web.layer.masksToBounds = YES;
    if (@available(macOS 10.15, *))
        self.web.layer.cornerCurve = kCACornerCurveContinuous;

    // Let the vibrancy behind the web view show through.
    [self.web setValue:@NO forKey:@"drawsBackground"];
    if (@available(macOS 12.0, *)) {
        self.web.underPageBackgroundColor = [NSColor clearColor];
    }
    [root addSubview:self.web];

    NSURL *ui = [NSURL fileURLWithPath:
                 [self.root stringByAppendingPathComponent:@"ui.html"]];
    [self.web loadFileURL:ui allowingReadAccessToURL:[ui URLByDeletingLastPathComponent]];

    if (!saved) [self.panel center];
    [self.panel orderFrontRegardless];
    [self.panel invalidateShadow];   // shadow must trace the rounded shape
}

- (void)buildStatusItem {
    NSNumber *v = [[NSUserDefaults standardUserDefaults] objectForKey:@"alertVolume"];
    self.alertVolume = v ? v.floatValue : 1.0;
    self.statusItem = [[NSStatusBar systemStatusBar]
                       statusItemWithLength:NSVariableStatusItemLength];
    self.statusItem.button.toolTip = @"Claude HUD";
    self.statusItem.button.imagePosition = NSImageLeft;
    self.charState = @"rest";
    self.statusItem.button.image = [self characterImage];
    // Its own timer: the 1.5s data tick is far too slow to read as motion.
    self.charTimer = [NSTimer scheduledTimerWithTimeInterval:0.13 target:self
                       selector:@selector(animateCharacter) userInfo:nil repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:self.charTimer forMode:NSRunLoopCommonModes];

    NSMenu *m = [NSMenu new];
    [m addItemWithTitle:@"Show / Hide  (⌃⌥H)"
                 action:@selector(toggle) keyEquivalent:@""].target = self;
    [m addItemWithTitle:@"Reset Position / Un-park"
                 action:@selector(resetPosition) keyEquivalent:@""].target = self;
    NSMenuItem *vol = [[NSMenuItem alloc] init];
    NSView *box = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 200, 40)];
    NSTextField *lab = [NSTextField labelWithString:@"Alert volume"];
    lab.frame = NSMakeRect(14, 21, 160, 14);
    lab.font = [NSFont menuFontOfSize:11];
    lab.textColor = [NSColor secondaryLabelColor];
    [box addSubview:lab];
    self.volumeSlider = [NSSlider sliderWithValue:self.alertVolume minValue:0 maxValue:1
                                           target:self action:@selector(setVolumeFromSlider:)];
    self.volumeSlider.frame = NSMakeRect(14, 2, 172, 18);
    self.volumeSlider.continuous = NO;      // fire once on release, not per pixel
    [box addSubview:self.volumeSlider];
    vol.view = box;
    [m addItem:vol];
    [m addItem:[NSMenuItem separatorItem]];

    [m addItemWithTitle:@"Reopen pinned sessions"
                 action:@selector(restorePinned) keyEquivalent:@""].target = self;
    [m addItemWithTitle:@"Test Notification"
                 action:@selector(testNotify) keyEquivalent:@""].target = self;
    [m addItemWithTitle:@"Reload"
                 action:@selector(reload) keyEquivalent:@""].target = self;
    [m addItem:[NSMenuItem separatorItem]];
    [m addItemWithTitle:@"Quit Claude HUD"
                 action:@selector(terminate) keyEquivalent:@""].target = self;
    self.statusItem.menu = m;
}

#pragma mark Actions

// Keep the blur material in step with the page's theme.
//
// Deliberately NOT a Vibrant* appearance: vibrancy blends an NSVisualEffectView's
// subviews into the backdrop, which washes the web view's text out to a ghost.
// Aqua / DarkAqua leave the hosted content alone. The page also paints its own
// near-opaque background, so contrast never depends on what's behind the panel.
- (void)applyTheme:(BOOL)dark {
    self.panel.appearance = [NSAppearance appearanceNamed:
        dark ? NSAppearanceNameDarkAqua : NSAppearanceNameAqua];
}

// Surface unacknowledged "finished" sessions on the menu-bar icon, so the count
// is visible even when the panel is hidden or minimised.
- (void)setBadge:(NSInteger)n {
    self.unread = n;
    self.statusItem.button.title = n > 0
        ? [NSString stringWithFormat:@" %ld", (long)n] : @"";
}

- (void)toggle {
    if (self.panel.isVisible) [self.panel orderOut:nil];
    else [self.panel orderFrontRegardless];
}

- (void)reload { [self.web reload]; }

- (void)resetPosition {
    // Also un-parks it. Without this, a panel parked at an edge that somehow
    // stops responding to hover would have no way back.
    self.dockSide = @"";
    [self.web evaluateJavaScript:@"window.__dockedSide && window.__dockedSide('')"
               completionHandler:nil];
    NSRect vis = [NSScreen mainScreen].visibleFrame;
    NSRect f = self.panel.frame;
    f.origin.x = NSMaxX(vis) - f.size.width - 20;
    f.origin.y = NSMaxY(vis) - f.size.height - 20;
    [self.panel setFrame:f display:YES];
    [self saveFrame];
    [self.panel orderFrontRegardless];
}

- (void)terminate { [NSApp terminate:nil]; }

#pragma mark Menu-bar character

// The panel can be hidden or parked; the menu bar never is. Drawing the same
// creature up there means the状态 is readable with every window closed.
//
// Same 11x7 grid as the SVG in ui.html, re-drawn natively so it can animate
// without a web view. Cocoa's origin is bottom-left, so y is flipped.
static void fillCell(CGFloat x, CGFloat y, CGFloat w, CGFloat h,
                     CGFloat u, CGFloat oy, CGFloat rows) {
    NSRectFill(NSMakeRect(x * u, (rows - y - h) * u + oy, w * u, h * u));
}

- (NSImage *)characterImage {
    const CGFloat H = 18.0;                  // menu-bar height budget
    const CGFloat rows = 9.4;                // 7 body + headroom for the "!"
    const CGFloat u = H / rows;              // one grid cell in points
    const CGFloat W = 11 * u + 2;

    NSString *st = self.charState ?: @"rest";
    BOOL work = [st isEqualToString:@"work"];
    BOOL wait = [st isEqualToString:@"wait"];
    NSInteger f = self.charFrame;

    // Per-state motion, kept to whole-ish pixels so it stays crisp.
    CGFloat bob = 0, armL = 0, armR = 0, squash = 0;
    if (work) {
        CGFloat cycle[4] = {0, 1, 0, 1};
        bob = cycle[f % 4] * u * 0.5;
        armL = (f % 2) ? -u * 0.5 : u * 0.5;
        armR = -armL;
    } else if (wait) {
        bob = (f % 2) ? u * 0.6 : 0;         // hopping
        armR = (f % 2) ? u * 1.1 : u * 0.6;  // waving
    } else {
        squash = (f / 4) % 2 ? u * 0.18 : 0; // slow breathing
    }

    NSImage *img = [[NSImage alloc] initWithSize:NSMakeSize(W, H)];
    [img lockFocus];

    NSColor *skin = [NSColor colorWithSRGBRed:0.77 green:0.47 blue:0.35 alpha:1];
    NSColor *dark = [NSColor colorWithWhite:0.10 alpha:1];
    CGFloat oy = bob + 1;
    CGFloat top = 3.0 + squash / u;          // headroom above the body

    [skin set];
    fillCell(2, top, 7, 5 - squash / u, u, oy, rows);        // torso
    for (int i = 0; i < 4; i++)
        fillCell(2 + i * 2, top + 5 - squash / u, 1, 2, u, oy, rows);   // legs
    fillCell(0, top + 2, 2, 2, u, oy + armL, rows);          // left arm
    fillCell(9, top + 2, 2, 2, u, oy + armR, rows);          // right arm

    [dark set];
    if (work || wait) {                                       // open eyes
        fillCell(3, top + 1, 1, 1, u, oy, rows);
        fillCell(7, top + 1, 1, 1, u, oy, rows);
    } else {                                                  // shut eyes
        fillCell(3, top + 1.55, 1, 0.4, u, oy, rows);
        fillCell(7, top + 1.55, 1, 0.4, u, oy, rows);
    }

    if (wait && (f % 2) == 0) {                               // blinking "!"
        [[NSColor colorWithSRGBRed:0.83 green:0.18 blue:0.18 alpha:1] set];
        fillCell(5, top - 2.4, 1, 1.6, u, oy, rows);
    }

    [img unlockFocus];
    img.template = NO;                        // keep the character's colour
    return img;
}

- (void)animateCharacter {
    // Idle needs almost no motion, so it costs almost nothing to draw.
    BOOL lively = [self.charState isEqualToString:@"work"] ||
                  [self.charState isEqualToString:@"wait"];
    self.charFrame++;
    if (!lively && (self.charFrame % 6)) return;
    self.statusItem.button.image = [self characterImage];
}

#pragma mark Background job actions

// The three things you actually do with a failing job: read it, retry it, or
// stop it. Disabling is confirmed twice in the UI before it reaches here.
- (void)runJobAction:(NSString *)action label:(NSString *)label log:(NSString *)log {
    if ([action isEqualToString:@"log"]) {
        if (!log.length) return;
        NSString *safe = [log stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];
        NSString *src = [NSString stringWithFormat:
            @"tell application \"Terminal\"\n activate\n"
             " do script \"tail -n 200 -f '%@'\"\nend tell", safe];
        [self runTool:@"/usr/bin/osascript" args:@[@"-e", src]];
        return;
    }
    if (!label.length) return;
    NSString *target = [NSString stringWithFormat:@"gui/%d/%@", getuid(), label];
    if ([action isEqualToString:@"run"]) {
        [self runTool:@"/bin/launchctl" args:@[@"kickstart", @"-k", target]];
    } else if ([action isEqualToString:@"stop"]) {
        [self runTool:@"/bin/launchctl" args:@[@"bootout", target]];
        hlog(@"disabled job %@", label);
    }
}

- (void)runTool:(NSString *)path args:(NSArray<NSString *> *)args {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSTask *t = [NSTask new];
        t.executableURL = [NSURL fileURLWithPath:path];
        t.arguments = args;
        t.standardOutput = [NSFileHandle fileHandleWithNullDevice];
        t.standardError = [NSFileHandle fileHandleWithNullDevice];
        @try { [t launch]; [t waitUntilExit]; } @catch (NSException *e) {}
    });
}

#pragma mark Pinned sessions

// Sessions you've pinned are reopened after a reboot: a terminal per session,
// each resuming its own conversation by id. Transcripts live in
// ~/.claude/projects and survive a restart, so the conversation comes back with
// its history, not as a fresh session in the right folder.
- (NSString *)pinnedPath {
    return [NSHomeDirectory() stringByAppendingPathComponent:
            @".claude-hud/pinned.json"];
}

- (NSMutableArray *)pinnedList {
    NSData *d = [NSData dataWithContentsOfFile:[self pinnedPath]];
    id j = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
    return [j isKindOfClass:NSArray.class] ? [j mutableCopy] : [NSMutableArray new];
}

- (void)setPinned:(NSString *)sid on:(BOOL)on
             name:(NSString *)name cwd:(NSString *)cwd {
    if (!sid.length) return;
    NSMutableArray *list = [self pinnedList];
    [list filterUsingPredicate:
        [NSPredicate predicateWithFormat:@"SELF.sid != %@", sid]];
    if (on) [list addObject:@{@"sid": sid, @"name": name ?: sid,
                              @"cwd": cwd ?: NSHomeDirectory()}];
    NSData *out = [NSJSONSerialization dataWithJSONObject:list options:0 error:nil];
    [out writeToFile:[self pinnedPath] atomically:YES];
    hlog(@"pin %@ %@ (%lu pinned)", on ? @"+" : @"-", name, (unsigned long)list.count);
}

// Session ids that already have a live process, so a restore never opens a
// second terminal for something that's already there.
- (NSSet *)liveSessionIds {
    NSMutableSet *live = [NSMutableSet new];
    NSString *dir = [NSHomeDirectory() stringByAppendingPathComponent:
                     @".claude/sessions"];
    for (NSString *f in [[NSFileManager defaultManager]
                         contentsOfDirectoryAtPath:dir error:nil]) {
        if (![f hasSuffix:@".json"]) continue;
        NSData *d = [NSData dataWithContentsOfFile:
                     [dir stringByAppendingPathComponent:f]];
        NSDictionary *j = d ? [NSJSONSerialization JSONObjectWithData:d
                                                             options:0 error:nil] : nil;
        NSNumber *pid = j[@"pid"];
        // A session file outlives its process, so check the process is real.
        if (j[@"sessionId"] && pid && kill(pid.intValue, 0) == 0)
            [live addObject:j[@"sessionId"]];
    }
    return live;
}

- (void)restorePinned {
    NSArray *list = [self pinnedList];
    NSSet *live = [self liveSessionIds];
    NSMutableArray *todo = [NSMutableArray new];
    for (NSDictionary *p in list)
        if (![live containsObject:p[@"sid"]]) [todo addObject:p];

    if (!todo.count) { hlog(@"restore: nothing to do"); return; }
    // A guard against a runaway list opening dozens of windows at login.
    NSUInteger n = MIN(todo.count, 12u);
    hlog(@"restore: opening %lu terminal(s)", (unsigned long)n);

    NSMutableString *src = [NSMutableString stringWithString:
        @"tell application \"Terminal\"\n activate\n"];
    for (NSUInteger i = 0; i < n; i++) {
        NSDictionary *p = todo[i];
        NSString *cwd = [p[@"cwd"] stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"];
        NSString *sid = p[@"sid"];
        if (![sid isKindOfClass:NSString.class]) continue;
        [src appendFormat:@" do script \"cd '%@' && claude --resume %@\"\n", cwd, sid];
    }
    [src appendString:@"end tell"];
    [self runTool:@"/usr/bin/osascript" args:@[@"-e", src]];
}

// Only after an actual reboot — not every time the app relaunches, which it
// does on every rebuild.
- (long)bootTime {
    struct timeval bt; size_t len = sizeof(bt);
    if (sysctlbyname("kern.boottime", &bt, &len, NULL, 0) != 0) return 0;
    return bt.tv_sec;
}

- (void)restorePinnedIfNewBoot {
    long boot = [self bootTime];
    if (!boot) return;
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    if ([ud integerForKey:@"lastRestoreBoot"] == boot) return;
    [ud setInteger:boot forKey:@"lastRestoreBoot"];
    // Give the desktop a moment to settle before throwing windows at it.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 6 * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{ [self restorePinned]; });
}

#pragma mark Edge docking

// Parked, only a few pixels stay on screen; the page paints that sliver in the
// current state colour, so a glance at the screen edge still tells you whether
// anything needs you — without the panel covering what you're presenting.
static const CGFloat kPeek = 36.0;   // width of the parked strip
static const CGFloat kInset = 12.0;

// Corners follow the dock state and nothing else. Keeping this in one place
// matters: the mask used to be set when docking but never restored when the
// panel was dragged off an edge, which left it permanently square down one side.
- (void)updateCorners {
    CACornerMask all = kCALayerMinXMinYCorner | kCALayerMinXMaxYCorner |
                       kCALayerMaxXMinYCorner | kCALayerMaxXMaxYCorner;
    CACornerMask m = all;
    if (self.dockSide.length) {
        // Square against the screen edge, rounded on the side facing inward.
        m = [self.dockSide isEqualToString:@"right"]
            ? (kCALayerMinXMinYCorner | kCALayerMinXMaxYCorner)
            : (kCALayerMaxXMinYCorner | kCALayerMaxXMaxYCorner);
    }
    self.panel.contentView.layer.maskedCorners = m;
    self.web.layer.maskedCorners = m;
    [self.panel invalidateShadow];
}

- (void)applyDock:(BOOL)animate {
    if (!self.dockSide.length) return;
    [self updateCorners];
    NSRect vis = [NSScreen mainScreen].visibleFrame;
    NSRect f = self.panel.frame;
    BOOL right = [self.dockSide isEqualToString:@"right"];
    f.origin.x = self.dockedOut
        ? (right ? NSMaxX(vis) - f.size.width - kInset : NSMinX(vis) + kInset)
        : (right ? NSMaxX(vis) - kPeek : NSMinX(vis) - f.size.width + kPeek);
    [self.panel setFrame:f display:YES animate:animate];
}

- (void)setDock:(NSString *)side out:(BOOL)out {
    if (side.length == 0) {
        // Undocked: bring it fully back on screen where it can be dragged.
        self.dockSide = @"";
        [self updateCorners];
        NSRect vis = [NSScreen mainScreen].visibleFrame;
        NSRect f = self.panel.frame;
        f.origin.x = MIN(MAX(f.origin.x, NSMinX(vis) + kInset),
                         NSMaxX(vis) - f.size.width - kInset);
        [self.panel setFrame:f display:YES animate:YES];
        [self saveFrame];
        return;
    }
    self.dockSide = side;
    self.dockedOut = out;
    [self applyDock:YES];
}

// Which edge is it nearer to right now?
- (NSString *)nearestEdge {
    NSRect vis = [NSScreen mainScreen].visibleFrame;
    NSRect f = self.panel.frame;
    return (NSMidX(f) > NSMidX(vis)) ? @"right" : @"left";
}

// Sound needs no authorisation, unlike a notification banner — which is why
// the two alerts are distinguishable by ear alone.
//
// Resolution order: your own override, then the pair shipped in the bundle,
// then a stock system sound if someone stripped the resources out.
// Alert volume is the app's own, independent of the system output level: the
// point of these sounds is to reach you across the room while a call or a video
// is playing at whatever volume that needs.
- (void)setVolumeFromSlider:(NSSlider *)sender {
    self.alertVolume = sender.floatValue;
    [[NSUserDefaults standardUserDefaults] setFloat:self.alertVolume
                                             forKey:@"alertVolume"];
    [self playSound:@"done"];        // hear what you just chose
}

- (void)playSound:(NSString *)which {
    if (![which isEqualToString:@"done"]) which = @"needs-you";

    static NSMutableDictionary<NSString *, NSSound *> *cache = nil;
    if (!cache) cache = [NSMutableDictionary new];

    NSSound *snd = cache[which];
    if (!snd) {
        // Your own drop-in wins over the bundled pair. Any common format, so
        // you can hand it an mp3 straight out of Downloads.
        NSArray *dirs = @[[NSHomeDirectory() stringByAppendingPathComponent:
                             @".claude-hud/sounds"],
                          [self.root stringByAppendingPathComponent:@"sounds"]];
        for (NSString *dir in dirs) {
            for (NSString *ext in @[@"wav", @"mp3", @"aiff", @"aif", @"m4a"]) {
                NSString *p = [dir stringByAppendingPathComponent:
                    [which stringByAppendingPathExtension:ext]];
                snd = [[NSSound alloc] initWithContentsOfFile:p byReference:YES];
                if (snd) break;
            }
            if (snd) break;
        }
        if (!snd) snd = [NSSound soundNamed:
            [which isEqualToString:@"done"] ? @"Glass" : @"Submarine"];
        if (snd) cache[which] = snd;
    }
    [snd stop];
    snd.volume = self.alertVolume;
    [snd play];
}

- (void)testNotify {
    [self notify:@"Claude HUD" body:@"Notifications are working." tty:nil];
    [self playSound:@"needs-you"];
}

#pragma mark Notifications

- (void)setupNotifications {
    @try {
        UNUserNotificationCenter *c = [UNUserNotificationCenter currentNotificationCenter];
        c.delegate = self;
        [c requestAuthorizationWithOptions:
            (UNAuthorizationOptionAlert | UNAuthorizationOptionSound)
         completionHandler:^(BOOL granted, NSError *err) {
            self.notifyAllowed = granted;
            hlog(@"auth granted=%d err=%@", granted, err);
        }];
    } @catch (NSException *e) {
        self.notifyAllowed = NO;   // fall back to AppleScript below
        hlog(@"UN setup threw: %@", e);
    }
}

// Deliver even while the HUD is the active app — the whole point is that you
// are looking at some other window when it fires.
- (void)userNotificationCenter:(UNUserNotificationCenter *)center
       willPresentNotification:(UNNotification *)n
         withCompletionHandler:(void (^)(UNNotificationPresentationOptions))done {
    done(UNNotificationPresentationOptionBanner | UNNotificationPresentationOptionSound);
}

// Tapping the banner jumps to the terminal that raised it.
- (void)userNotificationCenter:(UNUserNotificationCenter *)center
didReceiveNotificationResponse:(UNNotificationResponse *)resp
         withCompletionHandler:(void (^)(void))done {
    NSString *tty = resp.notification.request.content.userInfo[@"tty"];
    if (tty.length) [self focusTTY:tty winId:nil];
    done();
}

- (void)notify:(NSString *)title body:(NSString *)body tty:(NSString *)tty {
    hlog(@"notify allowed=%d title=%@ body=%@", self.notifyAllowed, title, body);
    if (self.notifyAllowed) {
        UNMutableNotificationContent *c = [UNMutableNotificationContent new];
        c.title = title ?: @"Claude";
        c.body = body ?: @"";
        c.sound = [UNNotificationSound defaultSound];
        if (tty.length) c.userInfo = @{@"tty": tty};
        UNNotificationRequest *r = [UNNotificationRequest
            requestWithIdentifier:[[NSUUID UUID] UUIDString]
                          content:c trigger:nil];
        [[UNUserNotificationCenter currentNotificationCenter]
            addNotificationRequest:r withCompletionHandler:^(NSError *e) {
                if (e) hlog(@"UN deliver FAILED: %@", e); else hlog(@"UN delivered ok");
            }];
        return;
    }
    // Fallback for when notification authorisation isn't available.
    hlog(@"using osascript fallback");
    NSString *esc = [body stringByReplacingOccurrencesOfString:@"\"" withString:@"'"];
    NSString *src = [NSString stringWithFormat:
        @"display notification \"%@\" with title \"%@\"", esc, title];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSTask *t = [NSTask new];
        t.executableURL = [NSURL fileURLWithPath:@"/usr/bin/osascript"];
        t.arguments = @[@"-e", src];
        t.standardError = [NSFileHandle fileHandleWithNullDevice];
        @try { [t launch]; [t waitUntilExit]; } @catch (NSException *e) {}
    });
}

- (void)saveFrame {
    [[NSUserDefaults standardUserDefaults]
        setObject:NSStringFromRect(self.panel.frame) forKey:kFrameKey];
}

// Bring the Terminal window that owns a given tty to the front, and select the
// matching tab inside it.
- (void)focusTTY:(NSString *)tty winId:(NSString *)winId {
    if (tty.length == 0) return;
    // Always resolve by tty rather than a cached window id. Window ids go stale
    // the moment a window is closed and reopened, and looking up a dead id just
    // fails silently — the click would do nothing. The tty is ground truth.
    // Deminiaturise too, or a jump to a minimised window is a no-op.
    NSString *src = [NSString stringWithFormat:
        @"tell application \"Terminal\"\n"
         "  set wid to missing value\n"
         // Pass 1 locates the window and selects the tab, but reorders nothing:
         // `repeat with w in windows` yields index-based references, so raising
         // a window mid-loop makes every later reference point somewhere else.
         "  repeat with w in windows\n"
         "    repeat with t in tabs of w\n"
         "      try\n"
         "        if tty of t is \"%@\" then\n"
         "          set wid to id of w\n"
         "          set selected of t to true\n"
         "        end if\n"
         "      end try\n"
         "    end repeat\n"
         "  end repeat\n"
         "  if wid is missing value then return false\n"
         // Activate first: activating pulls whatever window is frontmost on the
         // current Space, which would otherwise undo the raise we just did.
         "  activate\n"
         "  set w2 to (first window whose id is wid)\n"
         "  if miniaturized of w2 then set miniaturized of w2 to false\n"
         // Raise, then confirm. A Space switch can land another window on top,
         // so verify instead of assuming it worked.
         "  repeat 4 times\n"
         "    delay 0.2\n"
         "    set index of w2 to 1\n"
         "    delay 0.15\n"
         "    try\n"
         "      if id of front window is wid then return true\n"
         "    end try\n"
         "  end repeat\n"
         "  return false\n"
         "end tell", tty];
    // Off the main thread: AppleScript into another app can block for a beat.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSTask *t = [NSTask new];
        t.executableURL = [NSURL fileURLWithPath:@"/usr/bin/osascript"];
        t.arguments = @[@"-e", src];
        t.standardOutput = [NSFileHandle fileHandleWithNullDevice];
        t.standardError = [NSFileHandle fileHandleWithNullDevice];
        [t launch];
        [t waitUntilExit];
    });
}

#pragma mark Data tick

- (void)tick {
    if (!self.ready) return;

    double cpu = [self cpuPercent];
    double mem = [self memPercent];
    [self.web evaluateJavaScript:
        [NSString stringWithFormat:@"window.setMachine(%.1f,%.1f,%d,%.1f)",
            cpu, mem, [self thermalLevel], [self batteryTemp]]
              completionHandler:nil];

    if (self.collecting) return;   // don't stack collectors on a slow tick
    self.collecting = YES;

    NSString *script = [self.root stringByAppendingPathComponent:@"collect.py"];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSTask *t = [NSTask new];
        t.executableURL = [NSURL fileURLWithPath:@"/usr/bin/python3"];
        t.arguments = @[script];
        NSPipe *out = [NSPipe pipe];
        t.standardOutput = out;
        t.standardError = [NSFileHandle fileHandleWithNullDevice];

        NSData *data = nil;
        @try {
            [t launch];
            data = [out.fileHandleForReading readDataToEndOfFile];
            [t waitUntilExit];
        } @catch (NSException *e) {
            data = nil;
        }

        NSString *json = data.length
            ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]
            : nil;

        dispatch_async(dispatch_get_main_queue(), ^{
            self.collecting = NO;
            if (!json.length) return;
            NSString *js = [NSString stringWithFormat:@"window.render(%@)", json];
            [self.web evaluateJavaScript:js completionHandler:nil];
        });
    });
}

#pragma mark JS bridge

- (void)userContentController:(WKUserContentController *)ucc
      didReceiveScriptMessage:(WKScriptMessage *)msg {
    NSDictionary *b = msg.body;
    if (![b isKindOfClass:NSDictionary.class]) return;
    NSString *cmd = b[@"cmd"];

    if ([cmd isEqualToString:@"ready"]) {
        self.ready = YES;
        [self tick];

    } else if ([cmd isEqualToString:@"drag"]) {
        // Dragging a parked panel takes it off its edge, which is what you
        // expect when you grab and pull it.
        if (self.dockSide.length) {
            self.dockSide = @"";
            [self updateCorners];          // otherwise it stays square-sided
            [self.web evaluateJavaScript:@"window.__dockedSide('')"
                       completionHandler:nil];
        }
        NSEvent *e = NSApp.currentEvent;
        if (e) [self.panel performWindowDragWithEvent:e];

    } else if ([cmd isEqualToString:@"dragEnd"]) {
        [self saveFrame];

    } else if ([cmd isEqualToString:@"focus"]) {
        [self focusTTY:b[@"tty"] winId:b[@"winId"]];

    } else if ([cmd isEqualToString:@"pin"]) {
        [self setPinned:b[@"sid"] on:[b[@"on"] boolValue]
                   name:b[@"name"] cwd:b[@"cwd"]];

    } else if ([cmd isEqualToString:@"quitApp"]) {
        // Ask the app to quit rather than killing it, so it can prompt about
        // unsaved work. The UI has already confirmed twice by this point.
        pid_t pid = (pid_t)[b[@"pid"] intValue];
        NSRunningApplication *app =
            [NSRunningApplication runningApplicationWithProcessIdentifier:pid];
        if (app) {
            hlog(@"asking %@ to quit", app.localizedName ?: b[@"name"]);
            [app terminate];
        } else {
            hlog(@"no running application for pid %d (%@)", pid, b[@"name"]);
        }

    } else if ([cmd isEqualToString:@"job"]) {
        [self runJobAction:b[@"action"] label:b[@"label"] log:b[@"log"]];

    } else if ([cmd isEqualToString:@"dock"]) {
        NSString *side = b[@"side"];
        if ([side isEqualToString:@"auto"]) side = [self nearestEdge];
        [self setDock:side out:[b[@"out"] boolValue]];
        if (side.length) [self.web evaluateJavaScript:
            [NSString stringWithFormat:@"window.__dockedSide('%@')", side]
                                    completionHandler:nil];

    } else if ([cmd isEqualToString:@"theme"]) {
        [self applyTheme:[b[@"dark"] boolValue]];

    } else if ([cmd isEqualToString:@"sound"]) {
        [self playSound:b[@"which"]];

    } else if ([cmd isEqualToString:@"notify"]) {
        [self notify:b[@"title"] body:b[@"body"] tty:b[@"tty"]];

    } else if ([cmd isEqualToString:@"badge"]) {
        [self setBadge:[b[@"n"] integerValue]];
        NSString *st = b[@"state"];
        if (st.length && ![st isEqualToString:self.charState]) {
            self.charState = st;
            self.charFrame = 0;
            self.statusItem.button.image = [self characterImage];
        }

    } else if ([cmd isEqualToString:@"geometry"]) {
        CGFloat h = [b[@"h"] doubleValue];
        CGFloat w = [b[@"w"] doubleValue];
        h = MAX(34, MIN(h, [NSScreen mainScreen].visibleFrame.size.height - 40));
        // Floor of 40, not 200: the parked strip is deliberately narrow, and a
        // 200pt floor left the character centred in a window whose visible
        // sliver was only 46pt wide — i.e. drawn entirely off screen.
        w = MAX(28, MIN(w, 600));
        NSRect f = self.panel.frame;
        if (fabs(f.size.height - h) < 1.5 && fabs(f.size.width - w) < 1.5) return;
        f.origin.y += f.size.height - h;   // keep the top-left corner pinned
        f.size.height = h;
        f.size.width = w;
        [self.panel setFrame:f display:YES animate:NO];
        // Otherwise the drop shadow keeps the old, square-cornered outline.
        [self.panel invalidateShadow];
        if (self.dockSide.length) [self applyDock:NO];   // keep it on its edge
        else [self saveFrame];

    } else if ([cmd isEqualToString:@"quit"]) {
        [NSApp terminate:nil];
    }
}

- (void)webView:(WKWebView *)wv didFinishNavigation:(WKNavigation *)n {
    // ui.html posts {cmd:"ready"} itself; this is just a safety net.
    [wv evaluateJavaScript:@"window.__notifyReady && window.__notifyReady()"
         completionHandler:nil];
}

#pragma mark Hotkey (⌃⌥H)

static OSStatus HotkeyHandler(EventHandlerCallRef ref, EventRef ev, void *ud) {
    [(__bridge HUD *)ud toggle];
    return noErr;
}

- (void)registerHotkey {
    EventTypeSpec spec = { kEventClassKeyboard, kEventHotKeyPressed };
    InstallApplicationEventHandler(&HotkeyHandler, 1, &spec,
                                   (__bridge void *)self, NULL);
    EventHotKeyID hkid = { 'chud', 1 };
    EventHotKeyRef ref;
    RegisterEventHotKey(kVK_ANSI_H, controlKey | optionKey, hkid,
                        GetApplicationEventTarget(), 0, &ref);
}

@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        // --dump-frames <dir>: render the menu-bar character through the real
        // drawing code so it can be eyeballed without a screen recording.
        // --restore: run the pinned-session restore once and exit, so the
        // behaviour can be exercised without clicking a menu.
        if (argc > 1 && strcmp(argv[1], "--restore") == 0) {
            HUD *h = [HUD new];
            [h restorePinned];
            [NSThread sleepForTimeInterval:2.0];
            return 0;
        }
        if (argc > 2 && strcmp(argv[1], "--dump-frames") == 0) {
            HUD *h = [HUD new];
            for (NSString *st in @[@"rest", @"work", @"wait"]) {
                h.charState = st;
                for (int f = 0; f < 4; f++) {
                    h.charFrame = f;
                    NSImage *im = [h characterImage];
                    NSBitmapImageRep *rep = [NSBitmapImageRep
                        imageRepWithData:[im TIFFRepresentation]];
                    NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG
                                                    properties:@{}];
                    [png writeToFile:[NSString stringWithFormat:@"%s/%@-%d.png",
                                      argv[2], st, f] atomically:YES];
                }
            }
            printf("dumped\n");
            return 0;
        }
        HUD *hud = [HUD new];
        app.delegate = hud;
        [app run];
    }
    return 0;
}
