# NFD.ZIG
**nfd.zig** is a native file dialogue for zig. It's aim is to make Native File Dialogue, easy to use in zig programs

## Supported Operations

|Operation     |        Status          |
|--------------|------------------------|
|File Open     |<ul><li> [x] </li></ul> |
|Save Dialogue |<ul><li> [x] </li></ul> |
|Open Folder   |<ul><li> [x] </li></ul> |

## Usage
It targets zig master version. To use this, add this package in to your build.zon

```lua
.{
    .dependencies = {
            .nfd = .{
               .url = "https://github.com/ArtemisX64/nfd.zig/archive/refs/tags/0.1.1.tar.gz",
            .hash = "12206ba65e37f89f23c006e7f1323ff88263bccb38d39c1d08048d404c2d1f86fdf8"
            },
        },
}
```

In build.zig, add
```rs
    const nfd = @import("nfd");

    nfd.install(exe);
```

## Quick Start
### Creating Open Dialog
```rs
const nfd = @import("nfd");
nfd.openDialog(std.testing.allocator, null, null); //Requires an allocator to convert sentinal terminated slice to zig slice. Use openFileDialogZ() otherwise
```
### Creating Save File Dialog
```rs
const nfd = @import("nfd");
nfd.saveDialog(std.testing.allocator, null, null); //Requires an allocator to convert sentinal terminated slice to zig slice. Use saveDialogZ() otherwise
```
### Creating Pick Folder Dialog
```rs
const nfd = @import("nfd");
nfd.pickFolder(std.testing.allocator, null, null); //Requires an allocator to convert sentinal terminated slice to zig slice. Use pickFolderZ() otherwise
```

### Supported Platforms
- [x] Linux
- [x] Windows
- [x] MacOS

