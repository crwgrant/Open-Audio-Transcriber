#import <AppKit/AppKit.h>

const char *dialog_pick_open_file(const char *title, const char *filter_name, const char *filter_ext) {
    @autoreleasepool {
        NSOpenPanel *panel = [NSOpenPanel openPanel];
        panel.title = title ? [NSString stringWithUTF8String:title] : @"Select file";
        panel.canChooseFiles = YES;
        panel.canChooseDirectories = NO;
        panel.allowsMultipleSelection = NO;
        if (filter_ext) {
            NSString *exts = [NSString stringWithUTF8String:filter_ext];
            NSArray *parts = [exts componentsSeparatedByString:@","];
            NSMutableArray *types = [NSMutableArray arrayWithCapacity:parts.count];
            for (NSString *part in parts) {
                NSString *trimmed = [part stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                if (trimmed.length > 0) {
                    [types addObject:trimmed];
                }
            }
            if (types.count > 0) {
                panel.allowedFileTypes = types;
            }
        }

        if ([panel runModal] != NSModalResponseOK) {
            return NULL;
        }

        NSURL *url = panel.URL;
        if (!url) return NULL;
        const char *path = url.path.UTF8String;
        if (!path) return NULL;
        return strdup(path);
    }
}

const char *dialog_pick_open_directory(const char *title) {
    @autoreleasepool {
        NSOpenPanel *panel = [NSOpenPanel openPanel];
        panel.title = title ? [NSString stringWithUTF8String:title] : @"Select folder";
        panel.canChooseFiles = NO;
        panel.canChooseDirectories = YES;
        panel.allowsMultipleSelection = NO;

        if ([panel runModal] != NSModalResponseOK) {
            return NULL;
        }

        NSURL *url = panel.URL;
        if (!url) return NULL;
        const char *path = url.path.UTF8String;
        if (!path) return NULL;
        return strdup(path);
    }
}

const char *dialog_pick_save_file(const char *title, const char *default_name) {
    @autoreleasepool {
        NSSavePanel *panel = [NSSavePanel savePanel];
        panel.title = title ? [NSString stringWithUTF8String:title] : @"Save file";
        if (default_name) {
            panel.nameFieldStringValue = [NSString stringWithUTF8String:default_name];
        }

        if ([panel runModal] != NSModalResponseOK) {
            return NULL;
        }

        NSURL *url = panel.URL;
        if (!url) return NULL;
        const char *path = url.path.UTF8String;
        if (!path) return NULL;
        return strdup(path);
    }
}

void dialog_free_path(const char *path) {
    if (path) free((void *)path);
}

void dialog_pump_events(void) {}
