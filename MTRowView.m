#include "MTRowView.h"
#include <stdatomic.h>

typedef struct hspan_t {
  	volatile _Atomic(int32_t) retain_count;
  	CGFloat x, y, width;
} hspan_t;

static hspan_t *hspan_retain(CFAllocatorRef allocator, hspan_t *span) {
  	atomic_fetch_add(&span->retain_count, 1);
  	return span;
}
static void hspan_release(CFAllocatorRef allocator, hspan_t *span) {
  	if (atomic_fetch_sub(&span->retain_count, 1) == 0) {
		free(span);
	}
}

@implementation MTRowView
- (id)init {
  	if ((self = [super init])) {
    	bgMap = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    	stMap = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    	self.clearsContextBeforeDrawing = NO;
    	self.opaque = YES;
  	}
  	return self;
}
- (void)renderString:(CFAttributedStringRef)string withBGColor:(CGColorRef)_bgColor {
  	if (bgColor != _bgColor) {
    	CGColorRelease(bgColor);
    	bgColor = CGColorRetain(_bgColor);
  	}
  	if (ctLine) {
    	CFRelease(ctLine);
    	CFDictionaryRemoveAllValues(bgMap);
    	CFDictionaryRemoveAllValues(stMap);
  	}
  	ctLine = CTLineCreateWithAttributedString(string);
  	CFArrayRef runs = CTLineGetGlyphRuns(ctLine);
  	CFIndex nruns = CFArrayGetCount(runs), i;
  	CGFloat x = 0, y = 0;
  	CFMutableDictionaryRef colormap[] = {bgMap,stMap};
  	const int nmaps = sizeof(colormap) / sizeof(CFDictionaryRef);
  	for (i = 0; i < nruns; i++) {
    	CTRunRef run = CFArrayGetValueAtIndex(runs, i);
    	CGFloat ascent, width = CTRunGetTypographicBounds(run, CFRangeMake(0, 0), &ascent, NULL, NULL);
    	CFDictionaryRef attr = CTRunGetAttributes(run);
    	const void *colorkey[] = {
     		CFDictionaryGetValue(attr, kMTBackgroundColorAttributeName),
     		CFDictionaryGetValue(attr, kMTStrikethroughColorAttributeName)
		};
    	hspan_t *span = NULL;
    	int j;
    	for (j = 0; j < nmaps; j++) {
			const void* key = colorkey[j];
			if (!key) {
				continue;
			}
			CFMutableArrayRef spans = (void *)CFDictionaryGetValue(colormap[j], key);
			if (!spans) {
				spans = CFArrayCreateMutable(NULL, 0, &(CFArrayCallBacks) {
					.retain = (CFArrayRetainCallBack)hspan_retain,
					.release = (CFArrayReleaseCallBack)hspan_release}
				);
				CFDictionaryAddValue(colormap[j],key,spans);
				CFRelease(spans);
			}
			if (!span) {
				span = malloc(sizeof(hspan_t));
				span->retain_count = 0; // CFArray will retain it
				span->x = x;
				span->width = width;
			}
			// calculate strikethrough position if needed
			if (j == 1) span->y = ascent - CTFontGetXHeight(CFDictionaryGetValue(attr, kCTFontAttributeName)) / 2;
			CFArrayAppendValue(spans, span);
    	}
    	x += width;
    	y += ascent;
  	}
  	lineAscent = y / nruns;
  	[self setNeedsDisplay];
}
- (void)drawRect:(CGRect)drawRect {
	CGContextRef context=UIGraphicsGetCurrentContext();
	CGContextSetFillColorWithColor(context,bgColor);
	CGContextFillRect(context,drawRect);
	CGFloat xmin = CGRectGetMinX(drawRect), xmax = CGRectGetMaxX(drawRect);
	CFIndex nbg = CFDictionaryGetCount(bgMap);
	if (nbg) { // draw background rectangles as needed
		const void** keys = malloc(nbg * sizeof(CGColorRef));
		const void** values = malloc(nbg * sizeof(CFArrayRef));
		CFDictionaryGetKeysAndValues(bgMap, keys, values);
		CFIndex i;
		for (i = 0; i < nbg; i++) {
			CFIndex nvalues = CFArrayGetCount(values[i]), nrects = 0, j;
			CGRect *rects = malloc(nvalues * sizeof(CGRect));
			for (j = 0; j < nvalues; j++) {
				hspan_t *span = (hspan_t *)CFArrayGetValueAtIndex(values[i], j);
				CGFloat x = span->x, width = span->width, xend = x + width;
				if ((x < xmin && xend < xmin) || (x > xmax && xend > xmax)){
					continue;
				}
				rects[nrects++] = CGRectMake(x, drawRect.origin.y, width, drawRect.size.height);
			}
			if (nrects) {
				CGContextSetFillColorWithColor(context, (CGColorRef)keys[i]);
				CGContextFillRects(context, rects, nrects);
			}
			free(rects);
		}
		free(keys);
		free(values);
	}
	CGContextSetTextMatrix(context, CGAffineTransformMake(1, 0, 0, -1, 0, lineAscent));
	CTLineDraw(ctLine,context);
	CFIndex nst = CFDictionaryGetCount(stMap);
	if (nst) { // draw strikethrough lines as needed
		const void** keys = malloc(nst * sizeof(CGColorRef));
		const void** values = malloc(nst * sizeof(CFArrayRef));
		CFDictionaryGetKeysAndValues(stMap, keys, values);
		CGFloat ymin = CGRectGetMinY(drawRect), ymax = CGRectGetMaxY(drawRect);
		CFIndex i;
		for (i = 0; i < nst; i++) {
			CFIndex nvalues = CFArrayGetCount(values[i]), j;
			BOOL first = YES;
			for (j = 0; j < nvalues; j++) {
				hspan_t *span = (hspan_t *)CFArrayGetValueAtIndex(values[i], j);
				CGFloat x = span->x, xend = x + span->width, y = span->y;
				if ((x < xmin && xend < xmin) || (x > xmax && xend > xmax) || y < ymin || y > ymax) {
					continue;
				}
        		if (first) {
          			CGContextSetStrokeColorWithColor(context, (CGColorRef)keys[i]);
          			first = NO;
        		}
        		CGContextMoveToPoint(context, x, y);
        		CGContextAddLineToPoint(context, xend, y);
        		CGContextStrokePath(context);
      		}
    	}
    	free(keys);
    	free(values);
  	}
}
- (void)dealloc {
	CGColorRelease(bgColor);
	if (ctLine) {
		CFRelease(ctLine);
	}
	CFRelease(bgMap);
	CFRelease(stMap);
	[super dealloc];
}
@end
