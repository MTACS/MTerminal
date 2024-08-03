#include "VT100.h"
#include <pthread.h>
#include <stdatomic.h>
#include <sys/event.h>
#include <sys/ioctl.h>
#include <util.h>

extern int proc_pidpath(pid_t, char *, uint32_t);

const char $DA[] = "\033[?1;2c";
const char $DA2[] = "\033[>61;20;1c";
const char $DA3[] = "\033P!|0\033\\";
const char $DSR[] = "\033[0n";
const char $DECREPTPARM0[] = "\033[2;1;1;120;120;1;0x";
const char $DECREPTPARM1[] = "\033[3x";

const CFIndex $tabWidth = 8;
const unichar $charsetGraphics[128] = {
    0x0000, 0x0001, 0x0002, 0x0003, 0x0004, 0x0005, 0x0006, 0x0007, 0x0008,
    0x0009, 0x000a, 0x000b, 0x000c, 0x000d, 0x000e, 0x000f, 0x0010, 0x0011,
    0x0012, 0x0013, 0x0014, 0x0015, 0x0016, 0x0017, 0x0018, 0x0019, 0x001a,
    0x001b, 0x001c, 0x001d, 0x001e, 0x001f, 0x0020, 0x0021, 0x0022, 0x0023,
    0x0024, 0x0025, 0x0026, 0x0027, 0x0028, 0x0029, 0x002a, 0x002b, 0x002c,
    0x002d, 0x002e, 0x002f, 0x0030, 0x0031, 0x0032, 0x0033, 0x0034, 0x0035,
    0x0036, 0x0037, 0x0038, 0x0039, 0x003a, 0x003b, 0x003c, 0x003d, 0x003e,
    0x003f, 0x0040, 0x0041, 0x0042, 0x0043, 0x0044, 0x0045, 0x0046, 0x0047,
    0x0048, 0x0049, 0x004a, 0x004b, 0x004c, 0x004d, 0x004e, 0x004f, 0x0050,
    0x0051, 0x0052, 0x0053, 0x0054, 0x0055, 0x0056, 0x0057, 0x0058, 0x0059,
    0x005a, 0x005b, 0x005c, 0x005d, 0x005e, 0x00a0, 0x25c6, 0x2592, 0x2409,
    0x240c, 0x240d, 0x240a, 0x00b0, 0x00b1, 0x2424, 0x240b, 0x2518, 0x2510,
    0x250c, 0x2514, 0x253c, 0x23ba, 0x23bb, 0x2500, 0x23bc, 0x23bd, 0x251c,
    0x2524, 0x2534, 0x252c, 0x2502, 0x2264, 0x2265, 0x03c0, 0x2260, 0x00a3,
    0x00b7, 0x007f,
};

static void raiseException(NSString *name) {
  [NSException raise:name format:@"%d: %s", errno, strerror(errno)];
}
static void *kqRunEventLoop(void *context) {
  int kqfd = *(int *)context;
  while (1) {
    struct kevent events[8];
    int count = kevent(kqfd, NULL, 0, events, sizeof(events) / sizeof(struct kevent), NULL), i;
    if (count == -1) {
        raiseException(@"kevent");
    }
    for (i = 0; i < count; i++) {
        if (events[i].filter == EVFILT_READ)
            [(id)events[i].udata performSelectorOnMainThread:@selector(ptyRead) withObject:nil waitUntilDone:YES];
        }
    }
    return NULL;
}
static screen_line_t *screen_line_create(size_t size) {
    screen_line_t *line = calloc(1, sizeof(screen_line_t) + size);
    line->retain_count = 1;
    line->size = size;
    return line;
}
static screen_line_t *screen_line_retain(CFAllocatorRef allocator, screen_line_t *line) {
    atomic_fetch_add(&line->retain_count, 1);
    return line;
}
static void screen_line_release(CFAllocatorRef allocator, screen_line_t *line) {
    if (atomic_fetch_sub(&line->retain_count, 1) == 0) {
        free(line);
    }
}

@implementation VT100
@synthesize delegate, encoding, title, processID, bellDeferred;
- (void)ptyReset {
    bDECBKM = false;       // send delete on back arrow
    bDECCKM = false;       // send normal cursor keys
    bDECOM = false;        // disable origin mode
    bDECAWM = true;        // enable auto-wrapping
    bDECTCEM = true;       // show the cursor
    bIRM = false;          // disable insert mode
    bLNM = false;          // send CR on enter
    bPastEOL = false;      // cursor is not past end of line
    bTrackChanges = false; // disable change tracking until next update
    currentIndex = cursorX = cursorY = 0;
    windowTop = 0;
    windowBottom = screenHeight - 1;
    memset(&nullChar, 0, sizeof(nullChar));
    CFIndex i;
    // reset tab stops
    for (i = 0; i < screenWidth; i++) {
        tabstops[i] = ((i % $tabWidth) == 0);
    }
    // reset line buffer
    CFArrayRemoveAllValues(lineBuffer);
    size_t size = screenWidth * sizeof(screen_char_t);
    for (i = 0; i < screenHeight; i++) {
        screen_line_t *newline = screen_line_create(size);
        if (i == cursorY) {
            currentLine = newline;
        }
        CFArrayAppendValue(lineBuffer, newline);
        screen_line_release(NULL, newline);
    }
}
- (id)initWithWidth:(CFIndex)_screenWidth height:(CFIndex)_screenHeight {
    if ((self = [super init])) {
        encoding = kCFStringEncodingASCII;
        screenWidth = _screenWidth;
        screenHeight = _screenHeight;
        tabstops = malloc(tabstops_size = screenWidth);
        lineBuffer = CFArrayCreateMutable(NULL, 0, &(CFArrayCallBacks) {
            .retain = (CFArrayRetainCallBack)screen_line_retain,
            .release = (CFArrayReleaseCallBack)screen_line_release
        });
        indexMap = CFArrayCreateMutable(NULL, 0, NULL);
        linesChanged = CFSetCreateMutable(NULL, 0, NULL);
        [self ptyReset];
        int fd;
        pid_t pid = forkpty(&fd, NULL, NULL, &(struct winsize) {
            .ws_col = screenWidth, .ws_row = screenHeight
        });
        if (pid == -1) {
            raiseException(@"forkpty");
        } else if (pid == 0) {
            if (execve("/var/jb/usr/bin/login", (char *[]){"login", "-fp", getlogin(), NULL}, (char *[]){"TERM=xterm-256color", "LANG=en_US.UTF-8", NULL}) == -1) raiseException(@"execve(login)");
        } else {
            static int kqfd = -1;
            Boolean first = (kqfd == -1);
            // create singleton kqueue
            if (first && (kqfd = kqueue()) == -1) {
                raiseException(@"kqueue");
            }
            struct kevent changes[2];
            // register this pty
            EV_SET(&changes[0], fd, EVFILT_READ, EV_ADD, 0, 0, self);
            // first, register an event to reload the kevent loop
            // then on subsequent calls, trigger the reload event
            EV_SET(&changes[1], 0, EVFILT_USER, first ? EV_ADD | EV_CLEAR : 0, first ? NOTE_FFNOP : NOTE_TRIGGER, 0, NULL);
            if (kevent(kqfd, changes, 2, NULL, 0, NULL)) {
                raiseException(@"kevent");
            }
            if (first) { // detach a separate thread to run the event loop
                pthread_t thread;
                if (pthread_create(&thread, NULL, kqRunEventLoop, &kqfd))
                raiseException(@"pthread_create");
                pthread_detach(thread);
            }
            processID = pid;
            ptyfd = fd;
        }
    }
    return self;
}
- (CFIndex)numberOfLines {
    return CFArrayGetCount(lineBuffer);
}
- (screen_char_t *)charactersAtLineIndex:(CFIndex)index length:(CFIndex *)length cursorColumn:(CFIndex *)cursorColumn {
    if (index < 0 || index >= CFArrayGetCount(lineBuffer)) {
        return NULL;
    }
    screen_line_t *line = (screen_line_t *)CFArrayGetValueAtIndex(lineBuffer, index);
    *length = screenWidth;
    if (cursorColumn) {
        *cursorColumn = (bDECTCEM && line == currentLine) ? cursorX : -1;
    }
    return line->buf;
}
- (CFStringRef)copyProcessName {
    if (ptyfd == -1) {
        return NULL;
    }
    char buf[4096] = {0};
    proc_pidpath(tcgetpgrp(ptyfd), buf, sizeof(buf));
    char *ptr = strrchr(buf, '/');
    return CFStringCreateWithFileSystemRepresentation(NULL, ptr ? ptr + 1 : buf);
}
- (BOOL)isRunning {
    return (ptyfd == -1) ? NO : YES;
}
- (void)sendKey:(VT100Key)key {
    if (ptyfd == -1) {
        return;
    }
    char CSI[4] = "\033[?~";
    char OSC[3] = "\033O?";
    char *ptr;
    size_t len;
    switch (key) {
    case kVT100KeyEnter:
        ptr = (char[]){'\r', '\n'};
        len = bLNM ? 2 : 1;
        break;
    case kVT100KeyBackArrow:
        ptr = (char[]){bDECBKM ? '\b' : 0177};
        len = 1;
        break;
    case kVT100KeyInsert:
        (ptr = CSI)[2] = '2';
        len = 4;
        break;
    case kVT100KeyDelete:
        (ptr = CSI)[2] = '3';
        len = 4;
        break;
    case kVT100KeyPageUp:
        (ptr = CSI)[2] = '5';
        len = 4;
        break;
    case kVT100KeyPageDown:
        (ptr = CSI)[2] = '6';
        len = 4;
        break;
    case kVT100KeyUpArrow:
        (ptr = bDECCKM ? OSC : CSI)[2] = 'A';
        len = 3;
        break;
    case kVT100KeyDownArrow:
        (ptr = bDECCKM ? OSC : CSI)[2] = 'B';
        len = 3;
        break;
    case kVT100KeyLeftArrow:
        (ptr = bDECCKM ? OSC : CSI)[2] = 'D';
        len = 3;
        break;
    case kVT100KeyRightArrow:
        (ptr = bDECCKM ? OSC : CSI)[2] = 'C';
        len = 3;
        break;
    case kVT100KeyHome:
        (ptr = bDECCKM ? OSC : CSI)[2] = 'H';
        len = 3;
        break;
    case kVT100KeyEnd:
        (ptr = bDECCKM ? OSC : CSI)[2] = 'F';
        len = 3;
        break;
    default:
        ptr = (char[]){key};
        len = 1;
        break;
    }
    write(ptyfd, ptr, len);
}
- (void)sendString:(CFStringRef)string {
    if (ptyfd == -1) {
        return;
    }
    CFRange remain = CFRangeMake(0, CFStringGetLength(string));
    while (remain.length > 0) {
        UInt8 buf[4096];
        CFIndex len;
        CFIndex nconv = CFStringGetBytes(string, remain, encoding, '?', false, buf, sizeof(buf), &len);
        write(ptyfd, buf, len);
        remain.location += nconv;
        remain.length -= nconv;
    }
}
- (void)setCurrentLine {
    currentLine = (screen_line_t *)CFArrayGetValueAtIndex(lineBuffer, currentIndex = CFArrayGetCount(lineBuffer) - screenHeight + cursorY);
}
- (void)setEncoding:(CFStringEncoding)_encoding {
    if (encoding != _encoding) {
        encoding = _encoding;
        // allocate a backlog for multi-byte characters
        if (encbuf) {
            free(encbuf);
        }
        CFIndex size = CFStringGetMaximumSizeForEncoding(1, encoding);
        if ((encbuf = (size > 1) ? malloc(size) : NULL)) {
            encbuf_size = size;
            encbuf_index = 0;
        }
    }
}
- (void)setWidth:(CFIndex)newWidth height:(CFIndex)newHeight {
    if (newWidth == screenWidth && newHeight == screenHeight) {
        return;
    }
    if (newWidth < 4) {
        newWidth = 4;
    }
    if (newHeight < 2) {
        newHeight = 2;
    }
    CFIndex count = CFArrayGetCount(lineBuffer), i;
    // remove lines from the bottom if newHeight<screenHeight
    CFIndex iend = (cursorY > newHeight - 1) ? cursorY : newHeight - 1;
    for (i = screenHeight - 1; i > iend; i--) {
        CFArrayRemoveValueAtIndex(lineBuffer, --count);
    }
    size_t newlinesize = newWidth * sizeof(screen_char_t);
    if (newWidth > screenWidth) {
        // resize tab stop array
        if (newWidth > tabstops_size) {
            tabstops = realloc(tabstops, newWidth);
            for (i = tabstops_size; i < newWidth; i++) {
                tabstops[i] = ((i % $tabWidth) == 0);
            }
            tabstops_size = newWidth;
        }
        // resize lines to at least newWidth
        for (i = 0; i < count; i++) {
            screen_line_t *line = (screen_line_t *)CFArrayGetValueAtIndex(lineBuffer, i);
            if (line->size < newlinesize) {
                screen_line_t *newline = screen_line_create(newlinesize);
                memcpy(newline->buf, line->buf, line->size);
                CFArraySetValueAtIndex(lineBuffer, i, newline);
                screen_line_release(NULL, newline);
            }
        }
    }
    if (newHeight > screenHeight) {
        CFIndex nlines = (count < newHeight) ? newHeight - count : 0;
        cursorY += newHeight - screenHeight - nlines;
        for (i = 0; i < nlines; i++) {
            screen_line_t *newline = screen_line_create(newlinesize);
            CFArrayAppendValue(lineBuffer, newline);
            screen_line_release(NULL, newline);
        }
    }
    bPastEOL = false;
    bTrackChanges = false;
    if (cursorX > newWidth - 1) {
        cursorX = newWidth - 1;
    }
    if (cursorY > newHeight - 1) {
        cursorY = newHeight - 1;
    }
    if (windowTop > newHeight - 1) {
        windowTop = newHeight - 1;
    }
    if (windowBottom == screenHeight - 1 || windowBottom > newHeight - 1)
        windowBottom = newHeight - 1;
    screenWidth = newWidth;
    screenHeight = newHeight;
    [self setCurrentLine];
    // resize the pty
    if (ptyfd != -1 && ioctl(ptyfd, TIOCSWINSZ, &(struct winsize){.ws_col = newWidth, .ws_row = newHeight}) == -1)
        raiseException(@"ioctl(TIOCSWINSZ)");
}
- (void)changedLineAtIndex:(CFIndex)index {
    if (bTrackChanges) {
        index = (CFIndex)CFArrayGetValueAtIndex(indexMap, index - indexTop);
        if (index != -1) {
            CFSetAddValue(linesChanged, (void *)(index + indexTop));
        }
    }
}
- (void)shiftLines:(CFIndex)nlines fromY:(CFIndex)fromY toY:(CFIndex)toY {
    CFIndex top = CFArrayGetCount(lineBuffer) - screenHeight;
    CFIndex fromIndex = top + fromY, toIndex = top + toY;
    CFIndex maxlines = (fromIndex < toIndex ? toIndex - fromIndex : fromIndex - toIndex) + 1, i;
    if (nlines > maxlines) {
        nlines = maxlines;
    }
    size_t size = screenWidth * sizeof(screen_char_t);
    for (i = 0; i < nlines; i++) {
        CFArrayRemoveValueAtIndex(lineBuffer, fromIndex);
        screen_line_t *newline = screen_line_create(size);
        CFIndex j;
        for (j = 0; j < screenWidth; j++) {
            newline->buf[j] = nullChar;
        }
        CFArrayInsertValueAtIndex(lineBuffer, toIndex, newline);
        screen_line_release(NULL, newline);
    }
    currentLine = (screen_line_t *)CFArrayGetValueAtIndex(lineBuffer, currentIndex);
    if (bTrackChanges) {
        fromIndex -= indexTop;
        toIndex -= indexTop;
        for (i = 0; i < nlines; i++) {
            CFArrayRemoveValueAtIndex(indexMap, fromIndex);
            CFArrayInsertValueAtIndex(indexMap, toIndex, (void *)-1);
        }
    }
}
- (void)nextLine {
    if (cursorY == windowBottom || cursorY == screenHeight - 1) {
        if (windowTop == 0 && windowBottom == screenHeight - 1) {
            screen_line_t *newline = screen_line_create(screenWidth * sizeof(screen_char_t));
            CFArrayAppendValue(lineBuffer, newline);
            screen_line_release(NULL, newline);
            currentLine = newline;
            currentIndex = CFArrayGetCount(lineBuffer) - 1;
            if (bTrackChanges) {
                CFArrayAppendValue(indexMap, (void *)-1);
            }
        } else {
            [self shiftLines:1 fromY:windowTop toY:cursorY];
        }
    } else {
        cursorY++;
        [self setCurrentLine];
    }
}
- (void)ptyRead {
    int fd = ptyfd;
    unsigned char databuf[4096];
    ssize_t datalen;
    while (1) {
        switch ((datalen = read(fd, databuf, sizeof(databuf)))) {
        case -1:
            if (errno == EINTR) {
                continue;
            }
            kill(processID, SIGKILL);
        case 0:
            close(fd);
            ptyfd = -1;
            int status = 0;
            waitpid(processID, &status, 0);
            datalen = WIFEXITED(status) ? sprintf((char *)databuf, "\033[1m[Exit %d]\r\n", WEXITSTATUS(status)) : WIFSIGNALED(status) ? sprintf((char *)databuf, "\033[1;31m[%s]\r\n", strsignal(WTERMSIG(status))) : 0;
        }
        break;
    }
    BOOL notify = [delegate terminalShouldReportChanges:self];
    if (bTrackChanges) {
        if (notify) {
            // reset change tracking state
            CFSetRemoveAllValues(linesChanged);
            indexTop = CFArrayGetCount(lineBuffer) - screenHeight;
            prevCursorX = bDECTCEM ? cursorX : -1;
            prevCursorY = bDECTCEM ? cursorY : -1;
            CFIndex *list = malloc(screenHeight * sizeof(CFIndex)), i;
            for (i = 0; i < screenHeight; i++) {
                list[i] = i;
            }
            CFArrayReplaceValues(indexMap, CFRangeMake(0, CFArrayGetCount(indexMap)), (const void **)list, screenHeight);
            free(list);
        } else {
            bTrackChanges = false;
        }
    }
    bool bell = false;
    unsigned char *dataptr = databuf;
    unsigned char *dataend = dataptr + datalen;
    for (; dataptr < dataend; dataptr++) {
        CFIndex i, j;
        if (sequence == kSequenceIgnore) {
            if (*dataptr == 033) {
                sequence = kSequencePossibleST;
            }
        } else if (sequence == kSequencePossibleST) {
            sequence = (*dataptr == '\\') ? kSequenceNone : kSequenceIgnore;
        } else if (*dataptr < 0x20) { // this is a control character
            if (OSCString) {
                switch (*dataptr) {
                    case '\a':
                    __processOSC:
                    if ((j = CFStringGetLength(OSCString)) >= 2 && CFStringGetCharacterAtIndex(OSCString, 1) == ';') {
                        switch (CFStringGetCharacterAtIndex(OSCString, 0)) {
                            case '0':
                            case '2':
                            if (title) {
                                CFRelease(title);
                            }
                            title = (j == 2) ? NULL : CFStringCreateWithSubstring(NULL, OSCString, CFRangeMake(2, j - 2));
                            break;
                        }
                    }
                    case 030:
                    case 032:
                    sequence = kSequenceNone;
                    CFRelease(OSCString);
                    OSCString = NULL;
                    break;
                    case 033:
                        sequence = kSequenceESC;
                        break;
                }
            } else {
                switch (*dataptr) {
                    case 005:
                        break; //! ENQ
                    case '\a':
                        bell = true;
                        break;
                    case '\b':
                        bPastEOL = false;
                        if (cursorX > 0) {
                            cursorX--;
                        }
                        break;
                    case '\t':
                        while (cursorX < screenWidth - 1 && !tabstops[++cursorX]);
                        break;
                    case '\n':
                    case '\v':
                    case '\f':
                        if (!bPastEOL) {
                            [self nextLine];
                        }
                        break;
                    case '\r':
                        bPastEOL = false;
                        cursorX = 0;
                        break;
                    case 016:
                        glCharset = 1;
                        break;
                    case 017:
                        glCharset = 0;
                        break;
                    case 030:
                    case 032:
                        sequence = kSequenceNone;
                        break;
                    case 033:
                        sequence = kSequenceESC;
                        break;
                }
            }
        } else if (sequence == kSequenceESC) {
            if (OSCString) {
                if (*dataptr == '\\') {
                    goto __processOSC;
                }
                CFRelease(OSCString);
                OSCString = NULL;
            }
            sequence = kSequenceNone;
            switch (*dataptr) {
                case '[':
                    sequence = kSequenceCSI;
                    break;
                case ']':
                    OSCString = CFStringCreateMutable(NULL, 0);
                    break;
                case '#':
                    sequence = kSequenceDEC;
                    break;
                case '=':
                    break; //! DECKPAM (Keypad Application Mode)
                case '>':
                    break; //! DECKPNM (Keypad Numeric Mode)
                case '<':
                    break; //! VT52=>ANSI mode
                case '(':
                    sequence = kSequenceSCS;
                    SCSIndex = 0;
                    break;
                case ')':
                    sequence = kSequenceSCS;
                    SCSIndex = 1;
                    break;
                case '*':
                    sequence = kSequenceSCS;
                    SCSIndex = 2;
                    break;
                case '+':
                    sequence = kSequenceSCS;
                    SCSIndex = 3;
                    break;
                case '^': // PM (Privacy Message)
                case '_': // APC (Application Program Command)
                case 'P': // DCS (Device Control String)
                case 'X': // SOS (Start of String)
                    sequence = kSequenceIgnore;
                    break;
                case '7': // DECSC (Save Cursor)
                    saveCursorX = cursorX;
                    saveCursorY = cursorY;
                    saveNullChar = nullChar;
                    saveGLCharset = glCharset;
                    memcpy(saveCharsets, charsets, sizeof(charsets));
                    break;
                case '8': // DECRC (Restore Cursor)
                    bPastEOL = false;
                    cursorX = saveCursorX;
                    cursorY = saveCursorY;
                    [self setCurrentLine];
                    nullChar = saveNullChar;
                    glCharset = saveGLCharset;
                    memcpy(charsets, saveCharsets, sizeof(charsets));
                    break;
                case 'E': // NEL (Next Line)
                    bPastEOL = false;
                    cursorX = 0;
                case 'D': // IND (Index)
                    if (cursorY == windowBottom) {
                    [self shiftLines:1 fromY:windowTop toY:windowBottom];
                    } else if (cursorY < screenHeight - 1) {
                    cursorY++;
                    [self setCurrentLine];
                    }
                    break;
                case 'H': // HTS (Horizontal Tabulation Set)
                    tabstops[cursorX] = true;
                    break;
                case 'M': // RI (Reverse Index)
                    if (cursorY == windowTop) {
                    [self shiftLines:1 fromY:windowBottom toY:windowTop];
                    } else if (cursorY > 0) {
                    cursorY--;
                    [self setCurrentLine];
                    }
                    break;
                case 'N':
                    glCharset &= (2 << 2) | 3;
                    break;
                case 'O':
                    glCharset &= (3 << 2) | 3;
                    break;
                case 'Z': // DECID (Identify Terminal)
                    write(fd, $DA, strlen($DA));
                    break;
                case 'c': // RIS (Reset To Initial State)
                    [self ptyReset];
                    break;
                case 'n':
                    glCharset = 2;
                    break;
                case 'o':
                    glCharset = 3;
                    break;
            }
        } else if (sequence == kSequenceCSI) {
            if (!CSIParams) {
                CSIParams = CFArrayCreateMutable(NULL, 0, NULL);
                switch (*dataptr) {
                    case '?':
                        CSIModifier = kCSIModifierQM;
                        continue;
                    case '>':
                        CSIModifier = kCSIModifierGT;
                        continue;
                    case '=':
                        CSIModifier = kCSIModifierEQ;
                        continue;
                    default:
                        CSIModifier = kCSIModifierNone;
                }
            }
            if (*dataptr >= '0' && *dataptr <= '9') {
                CSIParam = CSIParam * 10 + *dataptr - '0';
                continue;
            }
            if (*dataptr == ';' || CSIParam > 0) {
                CFArrayAppendValue(CSIParams, (void *)CSIParam);
                CSIParam = 0;
                if (*dataptr == ';') {
                    continue;
                }
            }
            sequence = kSequenceNone;
            if (*dataptr == 'c') {
                switch (CSIModifier) {
                    case kCSIModifierNone: // DA (Device Attributes)
                        write(fd, $DA, strlen($DA));
                        break;
                    case kCSIModifierGT: // DA2 (Secondary Device Attributes)
                        write(fd, $DA2, strlen($DA2));
                        break;
                    case kCSIModifierEQ: // DA3 (Tertiary Device Attributes)
                        write(fd, $DA3, strlen($DA3));
                        break;
                    default:
                        break;
                }
                CFRelease(CSIParams);
                CSIParams = NULL;
                continue;
            }
            CFIndex nparams = CFArrayGetCount(CSIParams);
            CFIndex *params = malloc(nparams * sizeof(CFIndex));
            CFArrayGetValues(CSIParams, CFRangeMake(0, nparams), (const void **)params);
            CFRelease(CSIParams);
            CSIParams = NULL;
            unsigned char opt = 0;
            if (CSIModifier == kCSIModifierQM) {
                enum {
                    kDECCKM = 1,
                    kDECOM = 6,
                    kDECAWM = 7,
                    kDECTCEM = 25,
                    kDECBKM = 67,
                };
                switch (*dataptr) {
                    case 'h': // DECSET (DEC Private Mode Set)
                        opt = 1;
                    case 'l': // DECRST (DEC Private Mode Reset)
                        __DECRST:
                        for (i = 0; i < nparams; i++) {
                            switch (params[i]) {
                                case kDECBKM:
                                    bDECBKM = (opt == 2) ? mDECBKM : opt;
                                    break;
                                case kDECCKM:
                                    bDECCKM = (opt == 2) ? mDECCKM : opt;
                                    break;
                                case kDECOM:
                                    bDECOM = (opt == 2) ? mDECOM : opt;
                                    break;
                                case kDECAWM:
                                    bDECAWM = (opt == 2) ? mDECAWM : opt;
                                    break;
                                case kDECTCEM:
                                    bDECTCEM = (opt == 2) ? mDECTCEM : opt;
                                    break;
                                case 3: { // DECCOLM (132-column mode)
                                    // reset the screen but do not actually resize
                                    CFIndex count = CFArrayGetCount(lineBuffer);
                                    for (i = count - screenHeight; i < count; i++) {
                                        screen_line_t *line = (screen_line_t *)CFArrayGetValueAtIndex(lineBuffer, i);
                                        memset(line->buf, 0, line->size);
                                        [self changedLineAtIndex:i];
                                    }
                                    bPastEOL = false;
                                    cursorX = cursorY = 0;
                                    windowTop = 0;
                                    windowBottom = screenHeight - 1;
                                    [self setCurrentLine];
                                    break;
                                }
                                case 47:
                                case 1047:
                                case 1049:
                                    if (opt == 1) {
                                        // Use alternate line buffer
                                        if (!swapLineBuffer) {
                                            swapLineBuffer = CFArrayCreateCopy(NULL, lineBuffer);
                                            swapDECOM = bDECOM;
                                            swapDECAWM = bDECAWM;
                                            swapScreenWidth = screenWidth;
                                            swapScreenHeight = screenHeight;
                                            swapWindowTop = windowTop;
                                            swapWindowBottom = windowBottom;
                                            swapCursorX = cursorX;
                                            swapCursorY = cursorY;
                                            swapNullChar = nullChar;
                                            swapGLCharset = glCharset;
                                            memcpy(swapCharsets, charsets, sizeof(charsets));
                                        }
                                        [self ptyReset];
                                    } else if (swapLineBuffer) {
                                    // Restore default line buffer
                                        CFIndex count = CFArrayGetCount(swapLineBuffer);
                                        const void **values = malloc(count * sizeof(screen_line_t *));
                                        CFArrayGetValues(swapLineBuffer, CFRangeMake(0, count), values);
                                        CFArrayReplaceValues(
                                            lineBuffer, CFRangeMake(0, CFArrayGetCount(lineBuffer)),
                                            values, count);
                                        free(values);
                                        CFRelease(swapLineBuffer);
                                        swapLineBuffer = NULL;
                                        bDECOM = swapDECOM;
                                        bDECAWM = swapDECAWM;
                                        CFIndex width = screenWidth, height = screenHeight;
                                        screenWidth = swapScreenWidth;
                                        screenHeight = swapScreenHeight;
                                        windowTop = swapWindowTop;
                                        windowBottom = swapWindowBottom;
                                        bPastEOL = false;
                                        bTrackChanges = false;
                                        cursorX = swapCursorX;
                                        cursorY = swapCursorY;
                                        [self setCurrentLine];
                                        [self setWidth:width height:height];
                                        nullChar = swapNullChar;
                                        glCharset = swapGLCharset;
                                        memcpy(charsets, swapCharsets, sizeof(charsets));
                                    }
                                    break;
                            }
                        }
                        break;
                    case 'r': // Restore DEC Private Mode value
                        opt = 2;
                        goto __DECRST;
                    case 's': // Save DEC Private Mode value
                        for (i = 0; i < nparams; i++) {
                            switch (params[i]) {
                                case kDECBKM:
                                    mDECBKM = bDECBKM;
                                    break;
                                case kDECCKM:
                                    mDECCKM = bDECCKM;
                                    break;
                                case kDECOM:
                                    mDECOM = bDECOM;
                                    break;
                                case kDECAWM:
                                    mDECAWM = bDECAWM;
                                    break;
                                case kDECTCEM:
                                    mDECTCEM = bDECTCEM;
                                    break;
                            }
                        }
                        break;
                }
            } else if (CSIModifier == kCSIModifierNone) {
                switch (*dataptr) {
                    case 'F': // CPL (Cursor Previous Line)
                        bPastEOL = false;
                        cursorX = 0;
                    case 'A': // CUU (Cursor Up)
                        j = cursorY - ((0 < nparams && (i = params[0]) > 1) ? i : 1);
                        if (cursorY >= windowTop && j < windowTop) {
                            j = windowTop;
                        } else if (j < 0) {
                            j = 0;
                        }
                        if (cursorY != j) {
                            cursorY = j;
                            [self setCurrentLine];
                        }
                        break;
                    case 'E': // CNL (Cursor Next Line)
                        bPastEOL = false;
                        cursorX = 0;
                    case 'B': // CUD (Cursor Down)
                    case 'e': // VPR (Vertical Position Relative)
                        j = cursorY + ((0 < nparams && (i = params[0]) > 1) ? i : 1);
                        if (cursorY <= windowBottom && j > windowBottom) {
                            j = windowBottom;
                        } else if (j > screenHeight - 1) {
                            j = screenHeight - 1;
                        }
                        if (cursorY != j) {
                            cursorY = j;
                            [self setCurrentLine];
                        }
                        break;
                    case 'C': // CUF (Cursor Forward)
                    case 'a': // HPR (Horizontal Position Relative)
                        bPastEOL = false;
                        cursorX += ((0 < nparams && (i = params[0]) > 1) ? i : 1);
                        if (cursorX > screenWidth - 1) {
                            cursorX = screenWidth - 1;
                        }
                        break;
                    case 'D': // CUB (Cursor Backward)
                        bPastEOL = false;
                        cursorX -= ((0 < nparams && (i = params[0]) > 1) ? i : 1);
                        if (cursorX < 0) {
                            cursorX = 0;
                        }
                        break;
                    case 'G': // CHA (Cursor Horizontal Absolute)
                    case '`': // HPA (Horizontal Position Absolute)
                        bPastEOL = false;
                        cursorX = (0 < nparams && (i = params[0]) > 1) ? i - 1 : 0;
                        if (cursorX > screenWidth - 1) {
                            cursorX = screenWidth - 1;
                        }
                        break;
                    case 'H': // CUP (Cursor Position)
                    case 'f': // HVP (Horizontal and Vertical Position)
                        bPastEOL = false;
                        cursorX = (1 < nparams && (i = params[1]) > 1) ? i - 1 : 0;
                        if (cursorX > screenWidth - 1) {
                            cursorX = screenWidth - 1;
                        }
                    case 'd': // VPA (Vertical Position Absolute)
                        j = (0 < nparams && (i = params[0]) > 1) ? i - 1 : 0;
                        if (bDECOM) {
                            j += windowTop;
                        }
                        if (j > screenHeight - 1) {
                            j = screenHeight - 1;
                        }
                        if (cursorY != j) {
                            cursorY = j;
                            [self setCurrentLine];
                        }
                        break;
                    case 'I': // CHT (Cursor Horizontal Forward Tabulation)
                        j = (0 < nparams && params[0] > 1) ? params[0] : 1;
                        while (cursorX < screenWidth - 1 && (!tabstops[++cursorX] || --j > 0));
                        break;
                    case 'J': // ED (Erase In Display)
                        i = (j = CFArrayGetCount(lineBuffer)) - screenHeight;
                        switch ((0 < nparams) ? params[0] : 0) {
                            case 0: // erase to end of screen
                                i += cursorY + 1;
                                opt = 1; // fall through to EL
                                bPastEOL = false;
                                break;
                            case 1: // erase from start of screen
                                j = i + cursorY;
                                opt = 1; // fall through to EL
                            case 2:    // erase entire screen
                                bPastEOL = false;
                                break;
                        }
                        for (; i < j; i++) {
                            screen_char_t *ptr = ((screen_line_t *)CFArrayGetValueAtIndex(lineBuffer, i))->buf;
                            screen_char_t *end = ptr + screenWidth;
                            while (ptr < end) {
                                *(ptr++) = nullChar;
                            }
                            [self changedLineAtIndex:i];
                        }
                        if (!opt) {
                            break;
                        }
                    case 'K': // EL (Erase In Line)
                        i = j = screenWidth - 1;
                        switch ((0 < nparams) ? params[0] : 0) {
                            case 0: // erase to end of line
                                if (cursorX < i) {
                                    i = cursorX;
                                }
                                bPastEOL = false;
                                break;
                            case 1: // erase from start of line
                                if (cursorX < j) {
                                j = cursorX;
                                }
                            case 2: // erase entire line
                                i = 0;
                                bPastEOL = false;
                                break;
                        }
                        for (; i <= j; i++) {
                            currentLine->buf[i] = nullChar;
                        }
                        [self changedLineAtIndex:currentIndex];
                        break;
                    case 'L': // IL (Insert Line)
                        bPastEOL = false;
                        cursorX = 0;
                        if (cursorY >= windowTop && cursorY <= windowBottom) {
                            [self shiftLines:(0 < nparams && params[0] > 1) ? params[0] : 1 fromY:windowBottom toY:cursorY];
                        }
                        break;
                    case 'M': // DL (Delete Line)
                        bPastEOL = false;
                        cursorX = 0;
                        if (cursorY >= windowTop && cursorY <= windowBottom) {
                            [self shiftLines:(0 < nparams && params[0] > 1) ? params[0] : 1 fromY:cursorY toY:windowBottom];
                        }
                        break;
                    case '@': // ICH (Insert Character)
                        opt = 1;
                    case 'P': { // DCH (Delete Character)
                        bPastEOL = false;
                        j = (0 < params && (i = params[0]) > 1) ? i : 1;
                        i = screenWidth - cursorX;
                        if (j > i) {
                            j = i;
                        }
                        screen_char_t *ptr = currentLine->buf + cursorX;
                        memmove(opt ? ptr + j : ptr, opt ? ptr : ptr + j, (i - j) * sizeof(screen_char_t));
                        if (!opt) {
                            ptr += i - j;
                        }
                        screen_char_t *end = ptr + j;
                        while (ptr < end) {
                            *(ptr++) = nullChar;
                        }
                        [self changedLineAtIndex:currentIndex];
                        break;
                    }
                    case 'S': // SU (Scroll Up)
                        [self shiftLines:(0 < nparams && params[0] > 1) ? params[0] : 1 fromY:windowTop toY:windowBottom];
                        break;
                    case 'T': // SD (Scroll Down)
                        [self shiftLines:(0 < nparams && params[0] > 1) ? params[0] : 1 fromY:windowBottom toY:windowTop];
                        break;
                    case 'X': // ECH (Erase Character)
                        bPastEOL = false;
                        j = cursorX + ((0 < nparams && params[0] > 1) ? params[0] : 1);
                        if (j > screenWidth) {
                            j = screenWidth;
                        }
                        for (i = cursorX; i < j; i++) {
                            currentLine->buf[i] = nullChar;
                        }
                        [self changedLineAtIndex:currentIndex];
                        break;
                    case 'Z': // CBT (Cursor Backward Tabulation)
                        bPastEOL = false;
                        j = (0 < nparams && params[0] > 1) ? params[0] : 1;
                        while (cursorX > 0 && (!tabstops[--cursorX] || --j > 0));
                    break;
                    case 'g': // TBC (Tabulation Clear)
                        switch ((0 < nparams) ? params[0] : 0) {
                            case 0: // clear tab stop at current position
                                tabstops[cursorX] = false;
                                break;
                            case 3: // clear all tab stops
                                memset(tabstops, false, tabstops_size);
                                break;
                        }
                        break;
                    case 'h': // SM (Set Mode)
                        opt = 1;
                    case 'l': // RM (Reset Mode)
                        for (i = 0; i < nparams; i++) {
                            switch (params[i]) {
                                case 4:
                                    bIRM = opt;
                                    break;
                                case 20:
                                    bLNM = opt;
                                    break;
                            }
                        }
                        break;
                    case 'i':
                        break;  //! MC (Media Copy)
                    case 'm': // SGR (Select Graphic Rendition)
                        for (i = 0; i < nparams; i++) {
                            CFIndex arg = params[i];
                            switch (arg) {
                                case 0:
                                    __defaultSGR:
                                    // all attributes off
                                    memset(&nullChar, 0, sizeof(nullChar));
                                    break;
                                case 1:
                                    nullChar.weight = kFontWeightBold;
                                    break;
                                case 2:
                                    nullChar.weight = kFontWeightFaint;
                                    break;
                                case 3:
                                    nullChar.italicize = true;
                                    break;
                                case 4:
                                    nullChar.underline = kUnderlineSingle;
                                    break;
                                case 5:
                                    nullChar.blink = true;
                                    break;
                                case 7:
                                    nullChar.inverse = true;
                                    break;
                                case 8:
                                    nullChar.hidden = true;
                                    break;
                                case 9:
                                    nullChar.strikethrough = true;
                                    break;
                                case 21:
                                    nullChar.underline = kUnderlineDouble;
                                    break;
                                case 22:
                                    nullChar.weight = kFontWeightNormal;
                                    break;
                                case 23:
                                    nullChar.italicize = false;
                                    break;
                                case 24:
                                    nullChar.underline = kUnderlineNone;
                                    break;
                                case 25:
                                    nullChar.blink = false;
                                    break;
                                case 27:
                                    nullChar.inverse = false;
                                    break;
                                case 28:
                                    nullChar.hidden = false;
                                    break;
                                case 29:
                                    nullChar.strikethrough = false;
                                    break;
                                case 38:
                                    if (i + 1 < nparams) {
                                        switch (params[++i]) {
                                            case 2:
                                                if (i + 3 < nparams) {
                                                    i += 3;
                                                } //! RGB
                                                break;
                                            case 5:
                                                if (i + 1 < nparams) {
                                                    nullChar.fgcolor_isset = true;
                                                    nullChar.fgcolor = params[++i];
                                                }
                                                break;
                                        }
                                    }
                                    break;
                                case 39:
                                    nullChar.fgcolor_isset = false;
                                    break;
                                case 48:
                                    if (i + 1 < nparams) {
                                        switch (params[++i]) {
                                            case 2:
                                                if (i + 3 < nparams) {
                                                    i += 3;
                                                } //! RGB
                                                break;
                                            case 5:
                                                if (i + 1 < nparams) {
                                                    nullChar.bgcolor_isset = true;
                                                    nullChar.bgcolor = params[++i];
                                                }
                                                break;
                                        }
                                    }
                                    break;
                                case 49:
                                    nullChar.bgcolor_isset = false;
                                    break;
                                default:
                                    if (arg >= 30 && arg <= 37) {
                                        nullChar.fgcolor_isset = true;
                                        nullChar.fgcolor = arg - 30;
                                    } else if (arg >= 40 && arg <= 47) {
                                        nullChar.bgcolor_isset = true;
                                        nullChar.bgcolor = arg - 40;
                                    } else if (arg >= 90 && arg <= 97) {
                                        nullChar.fgcolor_isset = true;
                                        nullChar.fgcolor = arg - 90 + 8;
                                    } else if (arg >= 100 && arg <= 107) {
                                        nullChar.bgcolor_isset = true;
                                        nullChar.bgcolor = arg - 100 + 8;
                                    }
                            }
                        }
                        if (!i) {
                            goto __defaultSGR;
                        }
                        break;
                    case 'n': // DSR (Device Status Report)
                        switch ((0 < nparams) ? params[0] : 0) {
                            case 5:
                                write(fd, $DSR, strlen($DSR));
                                break;
                            case 6: {
                                char *msg;
                                int len = asprintf(&msg, "\033[%ld;%ldR", cursorY + 1 - (bDECOM ? windowTop : 0), cursorX + 1);
                                if (len > 0) {
                                    write(fd, msg, len);
                                }
                                if (len != -1) {
                                    free(msg);
                                }
                                break;
                            }
                        }
                        break;
                    case 'q':
                        break;  //! DECLL (Load LEDs)
                    case 'r': // DECSTBM (Set Top and Bottom Margins)
                        if ((i = (0 < nparams) ? params[0] : 0)) {
                            i--;
                        }
                        if ((j = (1 < nparams) ? params[1] : 0)) {
                            j--;
                        } else {
                            j = screenHeight - 1;
                        }
                        if (i < j && j < screenHeight) {
                            windowTop = i;
                            windowBottom = j;
                            bPastEOL = false;
                            cursorX = 0;
                            j = bDECOM ? windowTop : 0;
                            if (cursorY != j) {
                                cursorY = j;
                                [self setCurrentLine];
                            }
                        }
                        break;
                    case 'x': // DECREQTPARM (Request Terminal Parameters)
                        switch ((0 < nparams) ? params[0] : 0) {
                            case 0:
                                write(fd, $DECREPTPARM0, strlen($DECREPTPARM0));
                                break;
                            case 1:
                                write(fd, $DECREPTPARM1, strlen($DECREPTPARM1));
                                break;
                        }
                        break;
                    case 'y':
                        break; //! DECTST (Invoke Confidence Test)
                    case '$':
                    case '&':
                    case '\'':
                        sequence = kSequenceSkipNext;
                }
            }
            free(params);
        } else if (sequence == kSequenceDEC) {
            sequence = kSequenceNone;
                switch (*dataptr) {
                    case '3':
                        break; //! DECDHL (Double Height Line, top half)
                    case '4':
                        break; //! DECDHL (Double Height Line, bottom half)
                    case '5':
                        break; //! DECSWL (Single Width Line)
                    case '6':
                        break;    //! DECDWL (Double Width Line)
                    case '8': { // DECALN (Screen Alignment Test)
                        CFIndex count = CFArrayGetCount(lineBuffer);
                        for (i = count - screenHeight; i < count; i++) {
                        screen_line_t *line =
                            (screen_line_t *)CFArrayGetValueAtIndex(lineBuffer, i);
                        for (j = 0; j < screenWidth; j++) {
                            line->buf[j] = (screen_char_t){.c = 'E'};
                        }
                        [self changedLineAtIndex:i];
                        }
                        bPastEOL = false;
                        cursorX = cursorY = 0;
                        [self setCurrentLine];
                        break;
                    }
                }
        } else if (sequence == kSequenceSCS) {
            sequence = kSequenceNone;
            charsets[SCSIndex] = *dataptr;
        } else if (sequence == kSequenceSkipNext) {
            sequence = kSequenceNone;
        } else { // this is a printable character
            unichar uc;
            if (*dataptr < 0x80) {
                switch (charsets[glCharset > 3 ? glCharset >> 2 : glCharset]) {
                    case '0':
                        uc = $charsetGraphics[*dataptr];
                        break;
                    default:
                        uc = *dataptr;
                        break;
                }
                if (glCharset > 3) {
                    glCharset &= 3;
                }
            } else {
                CFStringRef str;
                if (encbuf) {
                    encbuf[encbuf_index++] = *dataptr;
                    str = CFStringCreateWithBytesNoCopy(NULL, encbuf, encbuf_index, encoding, false, kCFAllocatorNull);
                    if (str || encbuf_index == encbuf_size) {
                        encbuf_index = 0;
                    }
                } else {
                    str = CFStringCreateWithBytesNoCopy(NULL, dataptr, 1, encoding, false, kCFAllocatorNull);
                }
                if (!str) {
                    continue;
                }
                uc = CFStringGetCharacterAtIndex(str, 0);
                CFRelease(str);
                // skip zero-width characters
                if (uc == 0x200b || uc == 0x200c || uc == 0x200d || uc == 0xfeff) {
                    continue;
                }
            }
            if (OSCString) {
                CFStringAppendCharacters(OSCString, &uc, 1);
                continue;
            }
            bool wrapped = false;
            if (bPastEOL) {
                // either auto-wrap or discard this character
                if (!bDECAWM) {
                    continue;
                }
                [self changedLineAtIndex:currentIndex];
                [self nextLine];
                bPastEOL = false;
                cursorX = 0;
                wrapped = true;
            } else if (bIRM && cursorX < screenWidth - 1) {
                // insert mode: shift characters to the right
                screen_char_t *ptr = currentLine->buf + cursorX;
                memmove(ptr + 1, ptr, (screenWidth - cursorX) * sizeof(screen_char_t));
            }
            currentLine->buf[cursorX] = nullChar;
            currentLine->buf[cursorX].c = uc;
            if (wrapped) {
                currentLine->buf[cursorX].wrapped = true;
            }
            [self changedLineAtIndex:currentIndex];
            if (cursorX < screenWidth - 1) {
                cursorX++;
            } else {
                bPastEOL = true;
            }
        }
    }
    if (notify) {
        // compute changes and notify delegate
        if (bTrackChanges) {
            CFIndex count = CFArrayGetCount(indexMap), i;
            CFMutableSetRef deletions = CFSetCreateMutable(NULL, count, NULL);
            CFMutableSetRef insertions = CFSetCreateMutable(NULL, count, NULL);
            bool colchanged = prevCursorX != cursorX;
            CFIndex jnext = 0, jcursor = prevCursorY, top = indexTop;
            CFIndex inext = 0, icursor = bDECTCEM ? currentIndex - top : -1;
            for (i = 0; i <= count; i++) {
                CFIndex j = (i == count) ? screenHeight : (CFIndex)CFArrayGetValueAtIndex(indexMap, i);
                if (j == -1) {
                    CFSetAddValue(insertions, (void *)(top + i));
                } else {
                    while (jnext < j) {
                        CFIndex delindex = top + jnext++;
                        if (inext < i) {
                            CFSetRemoveValue(insertions, (void *)(top + inext++));
                            CFSetAddValue(linesChanged, (void *)delindex);
                        } else {
                            CFSetRemoveValue(linesChanged, (void *)delindex);
                            CFSetAddValue(deletions, (void *)delindex);
                        }
                    }
                    jnext++;
                    inext = i + 1;
                    if (colchanged ? (i == icursor || j == jcursor) : ((i == icursor) != (j == jcursor))) {
                        // erase or redraw cursor
                        CFSetAddValue(linesChanged, (void *)(top + j));
                    }
                }
            }
            [delegate terminal:self changed:linesChanged deleted:deletions inserted:insertions bell:bell];
            CFRelease(deletions);
            CFRelease(insertions);
        } else {
            [delegate terminal:self changed:NULL deleted:NULL inserted:NULL bell:bell];
            bTrackChanges = true;
        }
        bellDeferred = NO;
    } else if (bell) {
        bellDeferred = YES;
    }
}
- (void)dealloc {
    if (ptyfd) {
        kill(processID, SIGKILL);
        close(ptyfd);
    }
    if (CSIParams) {
        CFRelease(CSIParams);
    }
    if (OSCString) {
        CFRelease(OSCString);
    }
    if (encbuf) {
        free(encbuf);
    }
    CFRelease(lineBuffer);
    if (swapLineBuffer) {
        CFRelease(swapLineBuffer);
    }
    free(tabstops);
    CFRelease(indexMap);
    CFRelease(linesChanged);
    if (title) {
        CFRelease(title);
    }
    [super dealloc];
}
@end
