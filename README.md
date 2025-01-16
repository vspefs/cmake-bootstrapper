Bootstrap CMake from a pure Zig toolchain, a working ninja (which you can bootstrap with nothing but a Zig toolchain [here](https://github.com/vspefs/ninja-bootstrapper)), and a CMake source tree.

Working on Linux and Windows. Should work on macOS but not tested.

Note that you should have a ninja executable in your PATH. Otherwise you'll have to wait a couple of hours before I get home and add an option specifying the ninja path.

Check out [someday](https://github.com/vspefs/someday-dev), what this project (and [ayc-libuv](https://github.com/vspefs/ayc-libuv), [ayc-jsoncpp](https://github.com/vspefs/ayc-jsoncpp)) ultimately contributes to. It's a project that allows you to use any C++ package from any build system/any package manager on any platform, integrating them to your build.zig, with nothing but a functional Zig toolchain!