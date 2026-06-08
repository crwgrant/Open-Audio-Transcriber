const MB_OK = 0x00000000;
const MB_ICONERROR = 0x00000010;

extern "user32" fn MessageBoxA(
    hWnd: ?*anyopaque,
    text: [*:0]const u8,
    caption: [*:0]const u8,
    uType: u32,
) callconv(.c) c_int;

pub fn show(text: [*:0]const u8) void {
    _ = MessageBoxA(null, text, "Audio Transcriber", MB_OK | MB_ICONERROR);
}
