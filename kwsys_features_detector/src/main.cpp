#include <print>
#include <type_traits>

#if defined (__APPLE__)
    #include <AvailabilityMacros.h>
#endif

#include <stdlib.h>
#include <string>
#if __has_include(<sys/stat.h>) && __has_include(<fcntl.h>)
    #include <sys/stat.h>
    #include <fcntl.h>
#endif

// all glory to QQ user "anms.." for writing this code
#define SET_PROBE() \
    namespace { auto probe = []{}; decltype(probe) probing_func(); }

#define DETECT_IN(ns, id) \
    namespace ns { \
        namespace { \
            auto id = probe; \
        } \
        namespace id##_helper { \
            constexpr bool result = ::std::is_same_v<decltype(ns :: id), decltype(probe)>; \
        } \
    }
#define DETECT_TYPE_IN(ns, id) \
    namespace ns { \
        namespace { \
            using id = decltype(probe); \
        } \
        namespace id##_helper { \
            constexpr bool result = ::std::is_same_v<ns :: id, decltype(probe)>; \
        } \
    }
#define DETECT_FUNC_IN(ns, id) \
    namespace ns { \
        namespace { \
            decltype(probe) id(); \
        } \
        namespace id##_helper { \
            constexpr bool result = ::std::is_same_v<decltype(ns :: id), decltype(probing_func)>; \
        } \
    }
#define DETECT_GLOBAL(id) DETECT_IN(, id)
#define DETECT_TYPE_GLOBAL(id) DETECT_TYPE_IN(, id)
#define DETECT_FUNC_GLOBAL(id) DETECT_FUNC_IN(, id)

#define IF_EXISTS_IN(ns, id) (!ns :: id##_helper :: result)
#define IF_EXISTS_GLOBAL(id) IF_EXISTS_IN(, id)

SET_PROBE()
DETECT_TYPE_IN(std, wstring)
DETECT_FUNC_GLOBAL(setenv)
DETECT_FUNC_GLOBAL(unsetenv)
#if !defined(environ)
DETECT_GLOBAL(environ)
#endif
DETECT_FUNC_GLOBAL(utimes)
DETECT_FUNC_GLOBAL(utimensat)

int main()
{
    bool has_wstring = IF_EXISTS_IN(std, wstring);

    bool has_ext_stdio_filebuf_h = 
        #if __has_include(<ext/stdio_filebuf.h>)
            true;
        #else
            false;
        #endif

    bool has_setenv = IF_EXISTS_GLOBAL(setenv);

    bool has_unsetenv = IF_EXISTS_GLOBAL(unsetenv);

    bool has_environ_in_stdlib_h =
        #if defined(environ)
            true;
        #else
            IF_EXISTS_GLOBAL(environ);
        #endif

    bool has_utimensat =
        #if __has_include(<sys/stat.h>) && __has_include(<fcntl.h>)
            #if defined (__APPLE__)
                #if MAC_OS_X_VERSION_MIN_REQUIRED < 101300
                    false;
                #else
                    IF_EXISTS_GLOBAL(utimensat);
                #endif
            #else
                IF_EXISTS_GLOBAL(utimensat);
            #endif
        #else
            false;
        #endif

    bool has_utimes =
        #if __has_include(<sys/times.h>)
            IF_EXISTS_GLOBAL(utimes);
        #else
            false;
        #endif

    std::print("{{\"KWSYS_STL_HAS_WSTRING\":{},\"KWSYS_CXX_HAS_EXT_STDIO_FILEBUF_H\":{},\"KWSYS_CXX_HAS_SETENV\":{},\"KWSYS_CXX_HAS_UNSETENV\":{},\"KWSYS_CXX_HAS_ENVIRON_IN_STDLIB_H\":{},\"KWSYS_CXX_HAS_UTIMENSAT\":{},\"KWSYS_CXX_HAS_UTIMES\":{}}}",
        has_wstring,
        has_ext_stdio_filebuf_h,
        has_setenv,
        has_unsetenv,
        has_environ_in_stdlib_h,
        has_utimensat,
        has_utimes
    );
}