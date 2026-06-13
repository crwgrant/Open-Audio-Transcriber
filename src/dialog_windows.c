#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <shobjidl.h>
#include <stdlib.h>
#include <string.h>

#pragma comment(lib, "ole32.lib")
#pragma comment(lib, "shell32.lib")

static wchar_t *utf8_to_wide(const char *utf8) {
    int needed;
    wchar_t *wide;
    if (!utf8 || utf8[0] == '\0') return NULL;
    needed = MultiByteToWideChar(CP_UTF8, 0, utf8, -1, NULL, 0);
    if (needed <= 0) return NULL;
    wide = (wchar_t *)malloc((size_t)needed * sizeof(wchar_t));
    if (!wide) return NULL;
    if (MultiByteToWideChar(CP_UTF8, 0, utf8, -1, wide, needed) == 0) {
        free(wide);
        return NULL;
    }
    return wide;
}

static char *wide_to_utf8_dup(const wchar_t *wide) {
    int needed;
    char *utf8;
    if (!wide) return NULL;
    needed = WideCharToMultiByte(CP_UTF8, 0, wide, -1, NULL, 0, NULL, NULL);
    if (needed <= 0) return NULL;
    utf8 = (char *)malloc((size_t)needed);
    if (!utf8) return NULL;
    if (WideCharToMultiByte(CP_UTF8, 0, wide, -1, utf8, needed, NULL, NULL) == 0) {
        free(utf8);
        return NULL;
    }
    return utf8;
}

static wchar_t *build_filter_pattern(const char *filter_ext) {
    wchar_t *wide_ext;
    wchar_t *pattern;
    size_t out, start, i, part_start, part_end;
    int first;
    size_t wide_len;

    if (!filter_ext || filter_ext[0] == '\0') {
        pattern = (wchar_t *)malloc(4 * sizeof(wchar_t));
        if (!pattern) return NULL;
        wcscpy(pattern, L"*.*");
        return pattern;
    }

    wide_ext = utf8_to_wide(filter_ext);
    if (!wide_ext) return NULL;
    wide_len = wcslen(wide_ext);
    pattern = (wchar_t *)malloc((wide_len * 3 + 8) * sizeof(wchar_t));
    if (!pattern) {
        free(wide_ext);
        return NULL;
    }

    out = 0;
    start = 0;
    first = 1;
    for (i = 0; i <= wide_len; ++i) {
        if (i == wide_len || wide_ext[i] == L',') {
            part_start = start;
            while (part_start < i && (wide_ext[part_start] == L' ' || wide_ext[part_start] == L'\t')) part_start++;
            part_end = i;
            while (part_end > part_start && (wide_ext[part_end - 1] == L' ' || wide_ext[part_end - 1] == L'\t')) part_end--;
            if (part_end > part_start) {
                if (!first) pattern[out++] = L';';
                first = 0;
                pattern[out++] = L'*';
                pattern[out++] = L'.';
                wcsncpy(pattern + out, wide_ext + part_start, part_end - part_start);
                out += part_end - part_start;
            }
            start = i + 1;
        }
    }
    pattern[out] = L'\0';
    free(wide_ext);
    return pattern;
}

typedef struct {
    BOOL should_uninit;
} ComScope;

static void com_scope_init(ComScope *scope) {
    HRESULT hr = CoInitializeEx(NULL, COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE);
    scope->should_uninit = SUCCEEDED(hr) ? TRUE : FALSE;
}

static void com_scope_deinit(ComScope *scope) {
    if (scope->should_uninit) CoUninitialize();
}

static char *pick_path(IFileDialog *dialog) {
    IShellItem *item = NULL;
    wchar_t *wide_path = NULL;
    char *utf8_path = NULL;

    if (FAILED(dialog->lpVtbl->Show(dialog, NULL))) return NULL;
    if (FAILED(dialog->lpVtbl->GetResult(dialog, &item)) || !item) return NULL;

    if (SUCCEEDED(item->lpVtbl->GetDisplayName(item, SIGDN_FILESYSPATH, &wide_path)) && wide_path) {
        utf8_path = wide_to_utf8_dup(wide_path);
        CoTaskMemFree(wide_path);
    }
    item->lpVtbl->Release(item);
    return utf8_path;
}

static void set_dialog_title(IFileDialog *dialog, const char *title) {
    wchar_t *wide;
    if (!title) return;
    wide = utf8_to_wide(title);
    if (!wide) return;
    dialog->lpVtbl->SetTitle(dialog, wide);
    free(wide);
}

const char *dialog_pick_open_file(const char *title, const char *filter_name, const char *filter_ext) {
    ComScope com;
    IFileOpenDialog *dialog = NULL;
    DWORD options = 0;
    wchar_t *pattern = NULL;
    wchar_t *filter_label = NULL;
    COMDLG_FILTERSPEC spec;
    char *path = NULL;

    com_scope_init(&com);
    if (FAILED(CoCreateInstance(&CLSID_FileOpenDialog, NULL, CLSCTX_INPROC_SERVER, &IID_IFileOpenDialog, (void **)&dialog))) {
        com_scope_deinit(&com);
        return NULL;
    }

    set_dialog_title((IFileDialog *)dialog, title);
    if (SUCCEEDED(((IFileDialog *)dialog)->lpVtbl->GetOptions((IFileDialog *)dialog, &options))) {
        ((IFileDialog *)dialog)->lpVtbl->SetOptions((IFileDialog *)dialog, options | FOS_FORCEFILESYSTEM | FOS_FILEMUSTEXIST);
    }

    pattern = build_filter_pattern(filter_ext);
    filter_label = filter_name ? utf8_to_wide(filter_name) : utf8_to_wide("Files");
    if (pattern && filter_label) {
        spec.pszName = filter_label;
        spec.pszSpec = pattern;
        dialog->lpVtbl->SetFileTypes(dialog, 1, &spec);
    }

    path = pick_path((IFileDialog *)dialog);
    dialog->lpVtbl->Release(dialog);
    free(pattern);
    free(filter_label);
    com_scope_deinit(&com);
    return path;
}

const char *dialog_pick_open_directory(const char *title) {
    ComScope com;
    IFileOpenDialog *dialog = NULL;
    DWORD options = 0;
    char *path = NULL;

    com_scope_init(&com);
    if (FAILED(CoCreateInstance(&CLSID_FileOpenDialog, NULL, CLSCTX_INPROC_SERVER, &IID_IFileOpenDialog, (void **)&dialog))) {
        com_scope_deinit(&com);
        return NULL;
    }

    set_dialog_title((IFileDialog *)dialog, title);
    if (SUCCEEDED(((IFileDialog *)dialog)->lpVtbl->GetOptions((IFileDialog *)dialog, &options))) {
        ((IFileDialog *)dialog)->lpVtbl->SetOptions((IFileDialog *)dialog, options | FOS_FORCEFILESYSTEM | FOS_PICKFOLDERS | FOS_PATHMUSTEXIST);
    }

    path = pick_path((IFileDialog *)dialog);
    dialog->lpVtbl->Release(dialog);
    com_scope_deinit(&com);
    return path;
}

const char *dialog_pick_save_file(const char *title, const char *default_name) {
    ComScope com;
    IFileSaveDialog *dialog = NULL;
    DWORD options = 0;
    wchar_t *wide_name = NULL;
    char *path = NULL;

    com_scope_init(&com);
    if (FAILED(CoCreateInstance(&CLSID_FileSaveDialog, NULL, CLSCTX_INPROC_SERVER, &IID_IFileSaveDialog, (void **)&dialog))) {
        com_scope_deinit(&com);
        return NULL;
    }

    set_dialog_title((IFileDialog *)dialog, title);
    if (default_name) {
        wide_name = utf8_to_wide(default_name);
        if (wide_name) {
            ((IFileDialog *)dialog)->lpVtbl->SetFileName((IFileDialog *)dialog, wide_name);
            free(wide_name);
        }
    }

    if (SUCCEEDED(((IFileDialog *)dialog)->lpVtbl->GetOptions((IFileDialog *)dialog, &options))) {
        ((IFileDialog *)dialog)->lpVtbl->SetOptions((IFileDialog *)dialog, options | FOS_FORCEFILESYSTEM | FOS_OVERWRITEPROMPT);
    }

    path = pick_path((IFileDialog *)dialog);
    dialog->lpVtbl->Release(dialog);
    com_scope_deinit(&com);
    return path;
}

void dialog_free_path(const char *path) {
    if (path) free((void *)path);
}

void dialog_pump_events(void) {}
