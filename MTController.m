#include "MTController.h"
#include "MTRowView.h"
#include "MTScratchpad.h"
#import "VT100.h"

@interface UIKeyboardImpl
+ (id)sharedInstance;
- (BOOL)isShifted;
- (BOOL)isShiftLocked;
- (void)setShift:(BOOL)shift;
@end

@interface UIApplication (Private)
- (void)suspend;
@end

static BOOL scanRGB(NSString *vstr, unsigned int *cv) {
    return ([vstr isKindOfClass:[NSString class]] &&
            [[NSScanner scannerWithString:vstr] scanHexInt:cv])
    ? ((void)(*cv &= 0xffffff), YES)
    : NO;
}
static CGColorRef createColor(CGColorSpaceRef cspace, unsigned int cv) {
    return CGColorCreate(cspace, (CGFloat[]){(CGFloat)((cv >> 16) & 0xff) / 0xff,
        (CGFloat)((cv >> 8) & 0xff) / 0xff,
        (CGFloat)(cv & 0xff) / 0xff, 1});
}
static BOOL cacheColor(CFMutableBagRef bag, CGColorRef *var, CGColorRef color) {
    CFBagAddValue(bag, color);
    CFTypeRef prev = *var, value = *var = (void *)CFBagGetValue(bag, color);
    if (prev) {
        CFBagRemoveValue(bag, prev);
    }
    CFRelease(color);
    return prev != value;
}
static CGSize getScreenSize(UIScrollView *view) {
    CGSize size = view.bounds.size;
    UIEdgeInsets inset = view.adjustedContentInset;
    size.height -= inset.top + inset.bottom;
    return size;
}
static enum {
    kTapZoneTopLeft,
    kTapZoneTop,
    kTapZoneTopRight,
    kTapZoneLeft,
    kTapZoneCenter,
    kTapZoneRight,
    kTapZoneBottomLeft,
    kTapZoneBottom,
    kTapZoneBottomRight,
} getTapZone(UIGestureRecognizer *gesture, CGPoint *optr) {
    UIScrollView *view = (UIScrollView *)gesture.view;
    CGPoint origin = [gesture locationInView:view];
    if (optr) {
        *optr = origin;
    }
    CGPoint offset = view.contentOffset;
    origin.x -= offset.x;
    origin.y -= offset.y;
    CGSize size = getScreenSize(view);
    CGFloat margin = (size.width < size.height ? size.width : size.height) / 5;
    if (margin < 60) {
        margin = 60;
    }
    BOOL right = (origin.x > size.width - margin);
    return (origin.y < margin)                 ? right                 ? kTapZoneTopRight
    : (origin.x < margin) ? kTapZoneTopLeft
    : kTapZoneTop
    : (origin.y > size.height - margin) ? right ? kTapZoneBottomRight
    : (origin.x < margin)
    ? kTapZoneBottomLeft
    : kTapZoneBottom
    : right                             ? kTapZoneRight
    : (origin.x < margin)               ? kTapZoneLeft
    : kTapZoneCenter;
}
static NSString *getTitle(VT100 *terminal) {
    CFStringRef title = terminal.title;
    if (title) {
        return (NSString *)title;
    }
    title = [terminal copyProcessName];
    NSString *tstr = (title && CFStringGetLength(title)) ? [NSString stringWithFormat:@"<%@>", title] : @"---";
    if (title) {
        CFRelease(title);
    }
    return tstr;
}

@interface MTRespondingTableView : UITableView
@end

@implementation MTRespondingTableView
- (BOOL)canBecomeFirstResponder {
    return YES;
}
@end

@implementation MTController
- (id)init {
    if ((self = [super init])) {
        colorBag = CFBagCreateMutable(NULL, 0, &kCFTypeBagCallBacks);
        colorSpace = CGColorSpaceCreateDeviceRGB();
        nullColor = CGColorCreate(colorSpace, (CGFloat[]){0, 0, 0, 0});
        const CGFloat cvfloat[6] = {
            0, (CGFloat)0x5f / 0xff, (CGFloat)0x87 / 0xff, (CGFloat)0xaf / 0xff, (CGFloat)0xd7 / 0xff, 1
        };
        unsigned int i, j, k, z = 16;
        CGFloat RGBA[4];
        RGBA[3] = 1;
        for (i = 0; i < 6; i++) {
            RGBA[0] = cvfloat[i];
            for (j = 0; j < 6; j++) {
                RGBA[1] = cvfloat[j];
                for (k = 0; k < 6; k++) {
                    RGBA[2] = cvfloat[k];
                    CGColorRef color = CGColorCreate(colorSpace, RGBA);
                    CFBagAddValue(colorBag, colorTable[z++] = color);
                    CFRelease(color);
                }
            }
        }
        for (i = 0; i < 24; i++) {
            unsigned int cv = i * 10 + 8;
            CGFloat c = (CGFloat)cv / 0xff;
            CGColorRef color = CGColorCreate(colorSpace, (CGFloat[]){c, c, c, 1});
            CFBagAddValue(colorBag, colorTable[z++] = color);
            CFRelease(color);
        }
        // set up text decoration attributes
        ctUnderlineStyleSingle = CFNumberCreate(
                                                NULL, kCFNumberIntType, (const int[]){kCTUnderlineStyleSingle});
        ctUnderlineStyleDouble = CFNumberCreate(
                                                NULL, kCFNumberIntType, (const int[]){kCTUnderlineStyleDouble});
        // set up bell sound
        CFURLRef soundURL = CFBundleCopyResourceURL(
                                                    CFBundleGetMainBundle(), CFSTR("bell"), CFSTR("caf"), NULL);
        if (soundURL) {
            bellSound = AudioServicesCreateSystemSoundID(soundURL, &bellSoundID) ==
            kAudioServicesNoError;
            CFRelease(soundURL);
        }
        // set up display
        screenSection = [[NSIndexSet alloc] initWithIndex:0];
        allTerminals = [[NSMutableArray alloc] init];
    }
    return self;
}
- (BOOL)handleOpenURL:(NSURL *)URL {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSString *name = [NSBundle mainBundle].bundleIdentifier;
    NSDictionary *settings = [defaults persistentDomainForName:name];
    union {
        id list[1];
        struct {
            id palette, bgDefault, fgDefault, fgBold, bgCursor, fgCursor, fontName,
            fontSize, fontWidthSample, fontProportional;
        };
    } values = {{0}}, keys = {
        .palette = @"palette",
        .bgDefault = @"bgColor",
        .fgDefault = @"fgColor",
        .fgBold = @"fgBoldColor",
        .bgCursor = @"bgCursorColor",
        .fgCursor = @"fgCursorColor",
        .fontName = @"fontName",
        .fontSize = @"fontSize",
        .fontWidthSample = @"fontWidthSample",
        .fontProportional = @"fontProportional",
    };
    const int nprefs = sizeof(values) / sizeof(id);
    if (URL) {
        for (NSString *kvstr in [URL.query componentsSeparatedByString:@"&"]) {
            NSUInteger pos = [kvstr rangeOfString:@"="].location;
            if (pos == NSNotFound || pos == 0) {
                continue;
            }
            NSString *key = [kvstr substringToIndex:pos];
            int i;
            for (i = 0; i < nprefs; i++) {
                if (![key isEqualToString:keys.list[i]]) {
                    continue;
                }
                if (pos == kvstr.length - 1) {
                    values.list[i] = (id)kCFNull;
                } else {
                    key = keys.list[i];
                    NSString *vstr = [[kvstr substringFromIndex:pos + 1] stringByRemovingPercentEncoding];
                    values.list[i] = (key == keys.palette) ? [vstr componentsSeparatedByString:@","] : (key == keys.fontSize) ? [NSNumber numberWithDouble:vstr.doubleValue] : (key == keys.fontProportional) ? vstr.boolValue ? (id)kCFBooleanTrue : (id)kCFNull : vstr;
                }
                break;
            }
        }
        NSMutableDictionary *msettings = [NSMutableDictionary dictionaryWithCapacity:nprefs];
        BOOL keep = (URL.path == nil);
        int i;
        for (i = 0; i < nprefs; i++) {
            NSString *key = keys.list[i];
            id value = values.list[i];
            if (!value) {
                id prev = [settings objectForKey:key];
                if (keep || !prev) {
                    keys.list[i] = nil;
                    if (keep) {
                        values.list[i] = value = prev;
                    }
                }
            } else if (value == (id)kCFNull) {
                values.list[i] = value = nil;
            }
            if (value) {
                [msettings setObject:value forKey:key];
            }
        }
        if (msettings.count) {
            [defaults setPersistentDomain:msettings forName:name];
        } else {
            [defaults removePersistentDomainForName:name];
        }
    } else {
        int i;
        for (i = 0; i < nprefs; i++) {
            values.list[i] = [settings objectForKey:keys.list[i]];
        }
    }
    unsigned int cv;
    struct {
        BOOL screen : 1;
        BOOL bgDefault : 1;
        BOOL fgDefault : 1;
        BOOL darkBG : 1;
        BOOL ctFont : 1;
    } changed = {0};
    if (keys.palette) {
        const unsigned int xterm16[] = {0x000000, 0xaa0000, 0x00aa00, 0xaa5500,
            0x0000aa, 0xaa00aa, 0x00aaaa, 0xaaaaaa,
            0x555555, 0xff5555, 0x55ff55, 0xffff55,
            0x5555ff, 0xff55ff, 0x55ffff, 0xffffff};
        NSArray *palette = values.palette;
        NSUInteger count =
        [palette isKindOfClass:[NSArray class]] ? palette.count : 0;
        unsigned int i;
        for (i = 0; i < 16; i++) {
            if (cacheColor(colorBag, &colorTable[i], createColor(colorSpace, (i < count && scanRGB([palette objectAtIndex:i], &cv)) ? cv : xterm16[i]))) changed.screen = YES;
        }
    }
    if (keys.bgDefault &&
        cacheColor(colorBag, &bgDefault, createColor(colorSpace, scanRGB(values.bgDefault, &cv) ? cv : 0x000000))) {
        changed.screen = changed.bgDefault = YES;
        // convert RGB to YIQ, presume dark background if luma<50%
        const CGFloat *bgRGB = CGColorGetComponents(bgDefault);
        BOOL _darkBG =
        (bgRGB[0] * 0.299 + bgRGB[1] * 0.587 + bgRGB[2] * 0.114) < 0.5;
        if (darkBG != _darkBG) {
            darkBG = _darkBG;
            changed.darkBG = YES;
        }
    }
    if ((keys.fgDefault || changed.darkBG) && cacheColor(colorBag, &fgDefault, createColor(colorSpace, scanRGB(values.fgDefault, &cv) ? cv : darkBG ? 0xaaaaaa : 0x000000))) changed.screen = changed.fgDefault = YES;
    if ((keys.fgBold || changed.darkBG) && cacheColor(colorBag, &fgBold, createColor(colorSpace, scanRGB(values.fgBold, &cv) ? cv : darkBG ? 0xffffff : 0x000000))) changed.screen = YES;
    if ((keys.bgCursor || changed.fgDefault) && cacheColor(colorBag, &bgCursor, scanRGB(values.bgCursor, &cv) ? createColor(colorSpace, cv) : CGColorRetain(fgDefault))) changed.screen = YES;
    if ((keys.fgCursor || changed.bgDefault) && cacheColor(colorBag, &fgCursor, scanRGB(values.fgCursor, &cv) ? createColor(colorSpace, cv) : CGColorRetain(bgDefault))) changed.screen = YES;
    if (keys.fontName || keys.fontSize || keys.fontProportional) {
        if (ctFont) {
            CFRelease(ctFont);
            CFRelease(ctFontBold);
            CFRelease(ctFontItalic);
            CFRelease(ctFontBoldItalic);
        }
        NSString *fname = values.fontName;
        NSNumber *fsize = values.fontSize;
        ctFont = CTFontCreateWithName(([fname isKindOfClass:[NSString class]] && fname.length) ? (CFStringRef)fname : CFSTR("Courier"), ([fsize isKindOfClass:[NSNumber class]] ? fsize.doubleValue : 0) ?: 10, NULL); 
        changed.screen = changed.ctFont = YES;
    }
    if (keys.fontWidthSample || changed.ctFont) {
        NSString *sample = values.fontWidthSample;
        NSUInteger sslength;
        CFDictionaryRef ssattr =
        CFDictionaryCreate(NULL, (const void **)&kCTFontAttributeName, (const void **)&ctFont, 1, NULL, NULL);
        CFAttributedStringRef ssobj = CFAttributedStringCreate(NULL, ([sample isKindOfClass:[NSString class]] && (sslength = sample.length)) ? (CFStringRef)sample : ((void)(sslength = 1), CFSTR("$")),  ssattr);
        CTLineRef ssline = CTLineCreateWithAttributedString(ssobj);
        CGFloat ascent, descent, leading;
        CGFloat _colWidth = CTLineGetTypographicBounds(ssline, &ascent, &descent, &leading) / sslength, _rowHeight = ascent + descent + leading;
        if (colWidth != _colWidth) {
            colWidth = _colWidth;
            changed.screen = YES;
        }
        if (rowHeight != _rowHeight) {
            rowHeight = _rowHeight;
            changed.screen = YES;
        }
        CFRelease(ssline);
        CFRelease(ssobj);
        CFRelease(ssattr);
    }
    if (changed.ctFont) {
        NSNumber *varwidth = values.fontProportional;
        if (![varwidth isKindOfClass:[NSNumber class]] || !varwidth.boolValue) {
            // turn off all optional ligatures
            const int values[] = {kCommonLigaturesOffSelector,
                kRareLigaturesOffSelector,
                kLogosOffSelector,
                kRebusPicturesOffSelector,
                kDiphthongLigaturesOffSelector,
                kSquaredLigaturesOffSelector,
                kAbbrevSquaredLigaturesOffSelector,
                kSymbolLigaturesOffSelector,
                kContextualLigaturesOffSelector,
                kHistoricalLigaturesOffSelector};
            const size_t nvalues = sizeof(values) / sizeof(int);
            CFNumberRef ligkey =
            CFNumberCreate(NULL, kCFNumberIntType, (const int[]){kLigaturesType});
            CFMutableArrayRef ffsettings =
            CFArrayCreateMutable(NULL, nvalues, &kCFTypeArrayCallBacks);
            unsigned int i;
            for (i = 0; i < nvalues; i++) {
                CFNumberRef ligvalue =
                CFNumberCreate(NULL, kCFNumberIntType, &values[i]);
                CFDictionaryRef ligsetting = CFDictionaryCreate(NULL, (const void *[]){
                    kCTFontFeatureTypeIdentifierKey, kCTFontFeatureSelectorIdentifierKey
                }, (const void *[]){ligkey, ligvalue}, 2, NULL, &kCFTypeDictionaryValueCallBacks);
                CFRelease(ligvalue);
                CFArrayAppendValue(ffsettings, ligsetting);
                CFRelease(ligsetting);
            }
            CFRelease(ligkey);
            // set fixed advance
            CFNumberRef advance =
            CFNumberCreate(NULL, kCFNumberCGFloatType, &colWidth);
            CFDictionaryRef attrdict =
            CFDictionaryCreate(NULL, (const void *[]) {
                kCTFontFixedAdvanceAttribute,
                kCTFontFeatureSettingsAttribute
            }, (const void *[]){advance, ffsettings}, 2, NULL, &kCFTypeDictionaryValueCallBacks);
            CFRelease(advance);
            CFRelease(ffsettings);
            CTFontDescriptorRef desc = CTFontDescriptorCreateWithAttributes(attrdict);
            CFRelease(attrdict);
            // try to derive a new font
            CTFontRef font = CTFontCreateCopyWithAttributes(ctFont, 0, NULL, desc);
            CFRelease(desc);
            if (font) {
                CFRelease(ctFont);
                ctFont = font;
            }
        }
        CTFontSymbolicTraits traits =
        CTFontGetSymbolicTraits(ctFont) ^ kCTFontBoldTrait ^ kCTFontItalicTrait; 
        ctFontBold = CTFontCreateCopyWithSymbolicTraits(ctFont, 0, NULL, traits, kCTFontBoldTrait) ?: CFRetain(ctFont);
        ctFontItalic = CTFontCreateCopyWithSymbolicTraits(ctFont, 0, NULL, traits, kCTFontItalicTrait) ?: CFRetain(ctFont);
        ctFontBoldItalic = CTFontCreateCopyWithSymbolicTraits(ctFont, 0, NULL, traits, kCTFontBoldTrait ^ kCTFontItalicTrait) ?: CFRetain(ctFont);
    }
    UITableView *tableView = (UITableView *)self.view;
    [UIApplication sharedApplication].delegate.window.backgroundColor =
    tableView.backgroundColor = [UIColor colorWithCGColor:bgDefault];
    tableView.indicatorStyle = darkBG ? UIScrollViewIndicatorStyleWhite : UIScrollViewIndicatorStyleBlack;
    tableView.rowHeight = rowHeight;
    if (URL) {
        if (changed.darkBG) {
            // redraw the keyboard too
            [UIView setAnimationsEnabled:NO];
            [self resignFirstResponder];
            [self becomeFirstResponder];
            [UIView setAnimationsEnabled:YES];
        } else if (changed.screen) {
            // redraw the screen only
            [self screenSizeDidChange];
        }
    }
    return YES;
}
- (BOOL)isRunning {
    for (VT100 *terminal in allTerminals) {
        if (terminal.isRunning) {
            return YES;
        }
    }
    return NO;
}
- (void)screenSizeDidChange {
    UITableView *tableView = (UITableView *)self.view;
    CGSize size = getScreenSize(tableView);
    CFIndex width = size.width / colWidth;
    CFIndex height = size.height / rowHeight;
    if (activeTerminal) {
        [activeTerminal setWidth:width height:height];
    } else {
        VT100 *terminal = [[VT100 alloc] initWithWidth:width height:height];
        terminal.delegate = self;
        terminal.encoding = kCFStringEncodingUTF8;
        [allTerminals insertObject:terminal atIndex:activeIndex];
        [activeTerminal = terminal release];
    }
    if (previousIndex == activeIndex) {
        [self terminal:activeTerminal changed:NULL deleted:NULL inserted:NULL bell:NO];
    } else {
        CGRect frame = tableView.frame, endFrame = frame;
        endFrame.origin.x = frame.size.width;
        if (previousIndex == NSNotFound || previousIndex < activeIndex)
            endFrame.origin.x *= -1;
        previousIndex = activeIndex;
        [UIView animateWithDuration:0.25 animations:^{
    tableView.frame = endFrame;
        } completion:^(BOOL finished) {
            tableView.frame = frame;
            [self terminal:activeTerminal changed:NULL deleted:NULL inserted:NULL bell:NO];
        }];
    }
}
- (void)closeWindow {
    [allTerminals removeObjectAtIndex:activeIndex];
    NSUInteger count = allTerminals.count;
    if (count == 0) {
        [[UIApplication sharedApplication] suspend];
    } else {
        if (activeIndex == count) {
            activeIndex--;
        } else {
            previousIndex = NSNotFound;
        }
        activeTerminal = [allTerminals objectAtIndex:activeIndex];
        [self screenSizeDidChange];
    }
}
- (BOOL)canBecomeFirstResponder {
    return YES;
}
- (UIStatusBarStyle)preferredStatusBarStyle {
    return UIStatusBarStyleLightContent;
}
- (UIKeyboardAppearance)keyboardAppearance {
    return darkBG ? UIKeyboardAppearanceDark : UIKeyboardAppearanceDefault;
}
- (UITextAutocapitalizationType)autocapitalizationType {
    return UITextAutocapitalizationTypeNone;
}
- (UITextAutocorrectionType)autocorrectionType {
    return UITextAutocorrectionTypeNo;
}
- (BOOL)isSecureTextEntry {
    return YES; // disable dictation
}
- (UITextRange *)selectedTextRange {
    return nil; // disable the native arrow keys
}
- (BOOL)hasText {
    return YES; // always enable the backspace key
}
- (void)deleteBackward {
    [activeTerminal sendKey:kVT100KeyBackArrow];
}
- (void)insertText:(NSString *)text {
    if (text.length == 1) {
        unichar c = [text characterAtIndex:0];
        if (c < 0x80) {
            [activeTerminal sendKey:((c == 0x20 || c >= 0x40) && ctrlLock) ? c &0x1f : c]; text = nil;
        }
    }
    if (text) {
        [activeTerminal sendString:(CFStringRef)text];
    }
	if (ctrlLock) {
		ctrlLock = NO;
	}
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 1;
}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return activeTerminal.numberOfLines;
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)ipath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Cell"];
    MTRowView *rowView;
    if (cell) {
        rowView = (MTRowView *)cell.backgroundView;
    } else {
        cell = [[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"Cell"] autorelease];
        cell.backgroundView = rowView = [[[MTRowView alloc] init] autorelease];
    }
    CFIndex length, cursorColumn;
    screen_char_t *ptr = [activeTerminal charactersAtLineIndex:ipath.row length:&length cursorColumn:&cursorColumn];
    if (ptr) {
        unichar *ucbuf = malloc(length * sizeof(unichar));
        CFIndex i;
        for (i = 0; i < length; i++) {
            ucbuf[i] = ptr[i].c ?: ' ';
        }
        CFStringRef ucstr = CFStringCreateWithCharactersNoCopy(NULL, ucbuf, length, kCFAllocatorMalloc);
        CFMutableAttributedStringRef string =
        CFAttributedStringCreateMutable(NULL, length);
        CFAttributedStringBeginEditing(string);
        CFAttributedStringReplaceString(string, CFRangeMake(0, 0), ucstr);
        CFRelease(ucstr); // will automatically free(ucbuf)
        CTFontRef fontface = NULL;
        CGColorRef bgcolor = NULL, fgcolor = NULL, stcolor = NULL, ulcolor = NULL;
        CFNumberRef ulstyle = NULL;
        CFIndex ffspan = 0, bgcspan = 0, fgcspan = 0, stcspan = 0, ulcspan = 0,
        ulsspan = 0;
        for (i = 0; i <= length; i++, ptr++) {
            CTFontRef ff;
            CGColorRef bgc, fgc, stc, ulc;
            CFNumberRef uls;
            if (i == length) {
                ff = NULL;
                bgc = fgc = stc = ulc = NULL;
                uls = NULL;
            } else {
                BOOL bold = ptr->weight == kFontWeightBold;
                ff = bold ? ptr->italicize ? ctFontBoldItalic : ctFontBold : ptr->italicize ? ctFontItalic : ctFont;
                if (i == cursorColumn) {
                    bgc = bgCursor;
                    fgc = fgCursor;
                } else {
                    bgc = ptr->bgcolor_isset ? colorTable[ptr->bgcolor] : bgDefault;
                    fgc = ptr->fgcolor_isset ? colorTable[(bold && ptr->fgcolor < 8) ? ptr->fgcolor + 8 : ptr->fgcolor] : bold ? fgBold : fgDefault;
                    if (ptr->inverse) {
                        CGColorRef _fgc = fgc;
                        fgc = bgc;
                        bgc = _fgc;
                    }
                }
                stc = (ptr->strikethrough && fgc != bgc) ? fgc : NULL;
                switch (ptr->underline) {
                    case kUnderlineSingle:
                        ulc = fgc;
                        uls = ctUnderlineStyleSingle;
                        break;
                    case kUnderlineDouble:
                        ulc = fgc;
                        uls = ctUnderlineStyleDouble;
                        break;
                    default:
                        ulc = NULL;
                        uls = NULL;
                        break;
                }
                if (ptr->hidden) {
                    fgc = nullColor;
                }
                if (bgc == bgDefault) {
                    bgc = NULL;
                }
            }
            if (fontface == ff) {
                ffspan++;
            } else {
                if (fontface)
                    CFAttributedStringSetAttribute(string, CFRangeMake(i - ffspan, ffspan), kCTFontAttributeName, fontface);
                fontface = ff;
                ffspan = 1;
            }
            if (bgcolor == bgc) {
                bgcspan++;
            } else {
                if (bgcolor)
                    CFAttributedStringSetAttribute(string, CFRangeMake(i - bgcspan, bgcspan), kMTBackgroundColorAttributeName, bgcolor);
                bgcolor = bgc;
                bgcspan = 1;
            }
            if (fgcolor == fgc) {
                fgcspan++;
            } else {
                if (fgcolor)
                    CFAttributedStringSetAttribute(string, CFRangeMake(i - fgcspan, fgcspan), kCTForegroundColorAttributeName, fgcolor);
                fgcolor = fgc;
                fgcspan = 1;
            }
            if (stcolor == stc) {
                stcspan++;
            } else {
                if (stcolor)
                    CFAttributedStringSetAttribute(string, CFRangeMake(i - stcspan, stcspan), kMTStrikethroughColorAttributeName, stcolor);
                stcolor = stc;
                stcspan = 1;
            }
            if (ulcolor == stc) {
                ulcspan++;
            } else {
                if (ulcolor)
                    CFAttributedStringSetAttribute(string, CFRangeMake(i - ulcspan, ulcspan), kCTUnderlineColorAttributeName, ulcolor);
                ulcolor = ulc;
                ulcspan = 1;
            }
            if (ulstyle == uls) {
                ulsspan++;
            } else {
                if (ulstyle)
                    CFAttributedStringSetAttribute(string, CFRangeMake(i - ulsspan, ulsspan), kCTUnderlineStyleAttributeName, ulstyle);
                ulstyle = uls;
                ulsspan = 1;
            }
        }
        CFAttributedStringEndEditing(string);
        [rowView renderString:string withBGColor:bgDefault];
        CFRelease(string);
    }
    return cell;
}
- (void)handleKeyboardGesture:(UIGestureRecognizer *)gesture {
    if (gesture.state == UIGestureRecognizerStateBegan)
        [self.isFirstResponder ? self.view : self becomeFirstResponder];
}
- (void)handleSwipeGesture:(UISwipeGestureRecognizer *)gesture {
    switch (gesture.direction) {
        case UISwipeGestureRecognizerDirectionRight:
            if (activeIndex == 0) {
                return;
            }
            activeIndex--;
            break;
        case UISwipeGestureRecognizerDirectionLeft:
            if (activeIndex == allTerminals.count - 1) {
                return;
            }
            activeIndex++;
            break;
        default:
            return;
    }
    activeTerminal = [allTerminals objectAtIndex:activeIndex];
    [self screenSizeDidChange];
}
- (void)handleTapGesture:(UIGestureRecognizer *)gesture {
    if (!activeTerminal) {
        return;
    }
    UIKeyboardImpl *keyboard = [UIKeyboardImpl sharedInstance];
    BOOL shift = keyboard.isShifted;
    VT100Key key;
    switch (getTapZone(gesture, NULL)) {
        case kTapZoneTop:
            key = shift ? kVT100KeyPageUp : kVT100KeyUpArrow;
            break;
        case kTapZoneBottom:
            key = shift ? kVT100KeyPageDown : kVT100KeyDownArrow;
            break;
        case kTapZoneLeft:
            key = shift ? kVT100KeyHome : kVT100KeyLeftArrow;
            break;
        case kTapZoneRight:
            key = shift ? kVT100KeyEnd : kVT100KeyRightArrow;
            break;
        case kTapZoneTopLeft:
            key = kVT100KeyInsert;
            break;
        case kTapZoneTopRight:
            key = kVT100KeyDelete;
            break;
        case kTapZoneBottomLeft:
            key = kVT100KeyEsc;
            break;
        case kTapZoneBottomRight:
            key = kVT100KeyTab;
            break;
        default:
            return;
    }
    [activeTerminal sendKey:key];
    if (shift && !keyboard.isShiftLocked) {
        [keyboard setShift:NO];
    }
}
- (void)handleHoldGesture:(UIGestureRecognizer *)gesture {
    if (!activeTerminal) {
        return;
    }
    if (gesture.state == UIGestureRecognizerStateBegan) {
        if (repeatTimer) {
            return;
        }
        VT100Key key;
        CGPoint origin;
        switch (getTapZone(gesture, &origin)) {
            case kTapZoneTop:
                key = kVT100KeyUpArrow;
                break;
            case kTapZoneBottom:
                key = kVT100KeyDownArrow;
                break;
            case kTapZoneLeft:
                key = kVT100KeyLeftArrow;
                break;
            case kTapZoneRight:
                key = kVT100KeyRightArrow;
                break;
            case kTapZoneTopRight:
                if (activeTerminal.isRunning) {
                    UIAlertController *sheet = [UIAlertController
                                                alertControllerWithTitle:nil
                                                message:nil
                                                preferredStyle:UIAlertControllerStyleActionSheet];
                    [sheet addAction:[UIAlertAction
                                      actionWithTitle:@"Cancel"
                                      style:UIAlertActionStyleCancel
                                      handler:^(UIAlertAction *action) {
                        [self dismissViewControllerAnimated:YES
                                                 completion:^{
                        }];
                    }]];
                    
                    [sheet
                     addAction:[UIAlertAction
                                actionWithTitle:@"Force Quit"
                                style:UIAlertActionStyleDestructive
                                handler:^(UIAlertAction *action) {
                        [self
                         dismissViewControllerAnimated:YES
                         completion:^{
                            [self closeWindow];
                        }];
                    }]];
                    [self presentViewController:sheet animated:YES completion:nil];
                    [sheet release];
                } else {
                    [self closeWindow];
                }
                return;
            case kTapZoneBottomRight: {
                UIAlertController *sheet = [UIAlertController alertControllerWithTitle:nil message:nil preferredStyle:UIAlertControllerStyleActionSheet];
                [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(UIAlertAction *action) {
                    [self dismissViewControllerAnimated:YES completion:^{
                    }];
                }]];
                int index2 = -1;
                int index;
                for (VT100 *terminal in allTerminals) {
                    index = index2 + 1;
                    [sheet addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"%@%d: %@", (terminal == activeTerminal) ? @"\u2713 " : terminal.bellDeferred ? @"\u2407 " : @"", terminal.processID, getTitle(terminal)] style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
                        [self dismissViewControllerAnimated:YES completion:^{
                            activeIndex = index;
                            activeTerminal = (index < allTerminals.count) ? [allTerminals objectAtIndex:index] : nil;
                            [self screenSizeDidChange];
                        }];
                    }]];
                    index2 = index;
                }
                index = index2 + 1;
                [sheet addAction:[UIAlertAction actionWithTitle:@"(+)" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
                    [self dismissViewControllerAnimated:YES completion:^{
                        activeIndex = index;
                        activeTerminal = (index < allTerminals.count) ? [allTerminals objectAtIndex:index] : nil;
                        [self screenSizeDidChange];
                    }];
                }]];
                [self presentViewController:sheet animated:YES completion:nil];
                [sheet release];
                return;
            }
            case kTapZoneCenter:
                ctrlLock = NO;
            default:
                return;
        }
        repeatTimer =
        [[NSTimer scheduledTimerWithTimeInterval:0.1
                                          target:self
                                        selector:@selector(repeatTimerFired:)
                                        userInfo:[NSNumber numberWithInt:key]
                                         repeats:YES] retain];
    } else if (gesture.state == UIGestureRecognizerStateEnded) {
        if (!repeatTimer) {
            return;
        }
        [repeatTimer invalidate];
        [repeatTimer release];
        repeatTimer = nil;
    }
}
- (void)repeatTimerFired:(NSTimer *)timer {
    [activeTerminal sendKey:[timer.userInfo intValue]];
}
- (void)reflow {
    NSMutableString *text = [NSMutableString string];
    CFIndex count = activeTerminal.numberOfLines, i, blankspan = 0;
    for (i = 0; i < count; i++) {
        CFIndex length, j;
        screen_char_t *ptr = [activeTerminal charactersAtLineIndex:i length:&length cursorColumn:NULL];
        while (length && !ptr[length - 1].c) {
            length--;
        }
        if (i && !ptr->wrapped) {
            [text appendString:@"\n"];
            if (!length) {
                blankspan++;
            }
        }
        if (length) {
            blankspan = 0;
            unichar *ucbuf = malloc(length * sizeof(unichar));
            for (j = 0; j < length; j++) {
                ucbuf[j] = ptr[j].c ?: 0xA0;
            }
            CFStringRef ucstr = CFStringCreateWithCharactersNoCopy(
                                                                   NULL, ucbuf, length, kCFAllocatorMalloc);
            [text appendString:(NSString *)ucstr];
            CFRelease(ucstr); // will automatically free(ucbuf)
        }
    }
    if (blankspan) {
        NSUInteger length = text.length;
        [text deleteCharactersInRange:NSMakeRange(length - blankspan, blankspan)];
    }
    MTScratchpad *scratch = [[MTScratchpad alloc] initWithText:text fontSize:CTFontGetSize(ctFont) darkBG:darkBG];
    scratch.title = getTitle(activeTerminal);
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:scratch];
    [scratch release];
    nav.navigationBar.barStyle = darkBG ? UIBarStyleBlack : UIBarStyleDefault;
    [self presentViewController:nav animated:YES completion:nil];
    [nav release];
}
- (void)viewWillAppear:(BOOL)animated {
	[super viewWillAppear:animated];
    UITableView *tableView = (UITableView *)self.view;
    CGRect tableFrame = tableView.frame;
    [tableView setFrame:CGRectMake(tableFrame.origin.x, 44, tableFrame.size.width, tableFrame.size.height - 44)];
}
- (void)loadView {
    UITableView *tableView = [[MTRespondingTableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    tableView.allowsSelection = NO;
    tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    tableView.dataSource = self;

    UITapGestureRecognizer *tapGesture = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleTapGesture:)];
    [tableView addGestureRecognizer:tapGesture];

    UILongPressGestureRecognizer *longTap = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleHoldGesture:)];
    [longTap setMinimumPressDuration:0.5];
    [tableView addGestureRecognizer:longTap];
    [tapGesture requireGestureRecognizerToFail:longTap];
    [longTap release];

    UISwipeGestureRecognizer *leftSwipe = [[UISwipeGestureRecognizer alloc] initWithTarget:self action:@selector(handleSwipeGesture:)];
    leftSwipe.direction = UISwipeGestureRecognizerDirectionLeft;
    [tableView addGestureRecognizer:leftSwipe];
    [leftSwipe release];

    UISwipeGestureRecognizer *rightSwipe = [[UISwipeGestureRecognizer alloc] initWithTarget:self action:@selector(handleSwipeGesture:)];
    rightSwipe.direction = UISwipeGestureRecognizerDirectionRight;
    [tableView addGestureRecognizer:rightSwipe];
    [rightSwipe release];

    [tapGesture release];
    [self.view = tableView release];
    [self handleOpenURL:nil];
}
- (BOOL)terminalShouldReportChanges:(VT100 *)terminal {
    return terminal == activeTerminal;
}
- (void)terminal:(VT100 *)terminal changed:(CFSetRef)changes deleted:(CFSetRef)deletions inserted:(CFSetRef)insertions bell:(BOOL)bell {
    if (bell && bellSound) {
        AudioServicesPlaySystemSound(bellSoundID);
    }
    UITableView *tableView = (UITableView *)self.view;
    [UIView setAnimationsEnabled:NO];
    if (changes) {
        [tableView beginUpdates];
        unsigned int i;
        for (i = 0; i < 3; i++) {
            CFSetRef iset = (i == 0) ? changes : (i == 1) ? deletions : insertions;
            CFIndex count = CFSetGetCount(iset), j;
            id *items = malloc(count * sizeof(id));
            CFSetGetValues(iset, (const void **)items);
            for (j = 0; j < count; j++) {
                items[j] = [NSIndexPath indexPathForRow:(NSUInteger)items[j] inSection:0];
            }
            NSArray *ipaths = [NSArray arrayWithObjects:items count:count];
            free(items);
            switch (i) {
                case 0:
                    [tableView reloadRowsAtIndexPaths:ipaths withRowAnimation:UITableViewRowAnimationNone];
                    break;
                case 1:
                    [tableView deleteRowsAtIndexPaths:ipaths withRowAnimation:UITableViewRowAnimationNone];
                    break;
                case 2:
                    [tableView insertRowsAtIndexPaths:ipaths withRowAnimation:UITableViewRowAnimationNone];
                    break;
            }
        }
        [tableView endUpdates];
    } else {
        [tableView reloadSections:screenSection withRowAnimation:UITableViewRowAnimationNone];
    }
    [UIView setAnimationsEnabled:YES];
    [tableView scrollToRowAtIndexPath:[NSIndexPath indexPathForRow:terminal.numberOfLines - 1 inSection:0] atScrollPosition:UITableViewScrollPositionBottom animated:NO];
}
- (UIView *)inputAccessoryView {
    UIToolbar *toolbar = [[UIToolbar alloc] initWithFrame:CGRectMake(0, 0, [[UIScreen mainScreen] bounds].size.width, 50)];
    toolbar.translucent = NO;
    toolbar.barTintColor = [UIColor systemBackgroundColor];

    UIBarButtonItem *leftItem = [[UIBarButtonItem alloc] initWithImage:[[UIImage systemImageNamed:@"arrow.backward"] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate] style:UIBarButtonItemStylePlain target:self action:@selector(left:)];
    UIBarButtonItem *rightItem = [[UIBarButtonItem alloc] initWithImage:[[UIImage systemImageNamed:@"arrow.forward"] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate] style:UIBarButtonItemStylePlain target:self action:@selector(right:)];
    UIBarButtonItem *upItem = [[UIBarButtonItem alloc] initWithImage:[[UIImage systemImageNamed:@"arrow.up"] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate] style:UIBarButtonItemStylePlain target:self action:@selector(up:)];
    UIBarButtonItem *downItem = [[UIBarButtonItem alloc] initWithImage:[[UIImage systemImageNamed:@"arrow.down"] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate] style:UIBarButtonItemStylePlain target:self action:@selector(down:)];
    UIBarButtonItem *tabItem = [[UIBarButtonItem alloc] initWithImage:[[UIImage systemImageNamed:@"arrow.right.to.line"] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate] style:UIBarButtonItemStylePlain target:self action:@selector(insertTab:)];
	UIBarButtonItem *ctrlItem = [[UIBarButtonItem alloc] initWithImage:[[UIImage systemImageNamed:@"chevron.up"] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate] style:UIBarButtonItemStylePlain target:self action:@selector(toggleCtrlLock:)];
	UIBarButtonItem *pasteItem = [[UIBarButtonItem alloc] initWithImage:[[UIImage systemImageNamed:@"paperclip"] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate] style:UIBarButtonItemStylePlain target:self action:@selector(paste:)];
	UIBarButtonItem *settingsItem = [[UIBarButtonItem alloc] initWithImage:[[UIImage systemImageNamed:@"gearshape"] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate] style:UIBarButtonItemStylePlain target:self action:@selector(settings:)];
	UIBarButtonItem *spaceItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil];

    toolbar.items = [NSArray arrayWithObjects:settingsItem, pasteItem, ctrlItem, tabItem, spaceItem, spaceItem, spaceItem, leftItem, rightItem, upItem, downItem, nil];

    for (UIBarButtonItem *buttonItem in toolbar.items) {
        buttonItem.tintColor = [UIColor labelColor];
    }
    [toolbar sizeToFit];
    return toolbar;
}
- (void)left:(UIBarButtonItem *)sender {
	[activeTerminal sendKey:kVT100KeyLeftArrow];
}
- (void)right:(UIBarButtonItem *)sender {
	[activeTerminal sendKey:kVT100KeyRightArrow];
}
- (void)up:(UIBarButtonItem *)sender {
	[activeTerminal sendKey:kVT100KeyUpArrow];
}
- (void)down:(UIBarButtonItem *)sender {
	[activeTerminal sendKey:kVT100KeyDownArrow];
}
- (void)insertTab:(UIBarButtonItem *)sender {
	[activeTerminal sendKey:kVT100KeyTab];
}
- (void)paste:(UIBarButtonItem *)sender {
	[activeTerminal sendString:(CFStringRef)[UIPasteboard generalPasteboard].string];
}
- (void)toggleCtrlLock:(UIBarButtonItem *)sender {
	ctrlLock = !ctrlLock;
}
- (void)settings:(UIBarButtonItem *)sender {
    MTSettingsController *settingsController = [[MTSettingsController alloc] init];
    UINavigationController *navigationController = [[UINavigationController alloc] initWithRootViewController:settingsController];
    [self presentViewController:navigationController animated:YES completion:nil];
}
- (UIContextMenuConfiguration *)contextMenuInteraction:(UIContextMenuInteraction *)interaction configurationForMenuAtLocation:(CGPoint)location {
    UIContextMenuConfiguration *config = [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:nil actionProvider:^UIMenu* _Nullable(NSArray<UIMenuElement*>* _Nonnull suggestedActions) {
       	UIAction *settings = [UIAction actionWithTitle:@"Settings" image:[UIImage systemImageNamed:@"gearshape.fill"] identifier:nil handler:^(__kindof UIAction *_Nonnull action) {
            [self openSettings];
        }];

        UIMenu *subMenu = [UIMenu menuWithTitle:@"" children:@[settings]];
        return subMenu;
    }];
    return config;
}
- (UITargetedPreview *)contextMenuInteraction:(UIContextMenuInteraction *)interaction previewForHighlightingMenuWithConfiguration:(UIContextMenuConfiguration *)configuration {
    UITableView *tableView = (UITableView *)self.view;
	UITableViewCell *cell = [tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:0]];
	
	UIPreviewParameters *params = [[UIPreviewParameters alloc] init];
    params.backgroundColor = [UIColor clearColor]; 
    UITargetedPreview *preview = [[UITargetedPreview alloc] initWithView:cell.contentView parameters:params];
    return preview;
}
- (void)dealloc {
    CFRelease(colorBag);
    CFRelease(colorSpace);
    CFRelease(nullColor);
    CFRelease(ctFont);
    CFRelease(ctFontBold);
    CFRelease(ctFontItalic);
    CFRelease(ctFontBoldItalic);
    CFRelease(ctUnderlineStyleSingle);
    CFRelease(ctUnderlineStyleDouble);
    if (bellSound) {
        AudioServicesDisposeSystemSoundID(bellSoundID);
    }
    [repeatTimer release];
    [screenSection release];
    [allTerminals release];
    [super dealloc];
}
@end
