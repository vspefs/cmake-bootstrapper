const std = @import("std");
const utils = @import("utils.zig");

pub fn build(b: *std.Build) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}).init;
    defer {
        if (gpa.deinit() == .leak) {
            @panic("memory leak!");
        }
    }

    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const alloc = arena.allocator();

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const dep = b.dependency("cmake_src", .{});

    // ---- setup related files ---- //
    var proj_cache = try ProjCacher.init(alloc, b, target);
    defer proj_cache.deinit();

    // ---- gathering information ---- //

    const cmake_version = try utils.getCMakeVersion(dep.builder.build_root.handle);
    const cmake_version_str = try cmake_version.toString(alloc);
    const cmake_version_suffix = if (cmake_version.rc) |rc| try std.fmt.allocPrint(alloc, "-rc{d}", .{rc}) else "";

    const kwsys_features = try std.json.parseFromSliceLeaky(
        struct {
            KWSYS_NAME_IS_KWSYS: bool = false,
            KWSYS_BUILD_SHARED: bool = false,
            KWSYS_LFS_AVAILABLE: bool = false,
            KWSYS_LFS_REQUESTED: bool = false,
            KWSYS_STL_HAS_WSTRING: bool,
            KWSYS_CXX_HAS_EXT_STDIO_FILEBUF_H: bool,
            KWSYS_CXX_HAS_SETENV: bool,
            KWSYS_CXX_HAS_UNSETENV: bool,
            KWSYS_CXX_HAS_ENVIRON_IN_STDLIB_H: bool,
            KWSYS_CXX_HAS_UTIMENSAT: bool,
            KWSYS_CXX_HAS_UTIMES: bool,
        },
        alloc,
        blk: {
            const dir = b.dependency("kwsys_features_detector", .{}).builder.build_root.handle;
            var process = std.process.Child.init(&.{ b.graph.zig_exe, "build", "run" }, alloc);
            process.cwd = try dir.realpathAlloc(alloc, ".");
            process.stdout_behavior = .Pipe;
            process.stderr_behavior = .Pipe;
            var stdout = std.ArrayList(u8).init(alloc);
            var stderr = std.ArrayList(u8).init(alloc);
            defer stderr.deinit();
            _ = try process.spawn();
            try process.collectOutput(&stdout, &stderr, 1024);
            _ = try process.wait();
            break :blk try stdout.toOwnedSlice();
        },
        .{},
    );

    var basic_defines = ArrayList([]const u8).init(alloc);
    defer basic_defines.deinit();
    try basic_defines.append("-D_FILE_OFFSET_BITS=64");

    var basic_cargs = ArrayList([]const u8).init(alloc);
    defer basic_cargs.deinit();
    try basic_cargs.append("-fno-sanitize=undefined");

    const basic_args = try std.mem.concat(alloc, []const u8, &.{ basic_defines.items, basic_cargs.items });

    // ---- config headers ---- //

    const kwsys_config_header_names = [_][]const u8{ "Configure.h", "Configure.hxx", "Directory.hxx", "Encoding.h", "Encoding.hxx", "FStream.hxx", "Glob.hxx", "Process.h", "RegularExpression.hxx", "Status.hxx", "String.h", "System.h", "SystemTools.hxx", "Terminal.h" };
    var kwsys_config_headers = ArrayList(*ConfigHeader).init(alloc);
    defer kwsys_config_headers.deinit();
    for (kwsys_config_header_names) |name| {
        const template_name = try std.fmt.allocPrint(alloc, "{s}.in", .{name});
        const include_path = try std.fmt.allocPrint(alloc, "cmsys/{s}", .{name});
        try kwsys_config_headers.append(blk: {
            const h = b.addConfigHeader(
                .{
                    .style = .{ .cmake = dep.path(try std.fs.path.join(b.allocator, &.{ "Source", "kwsys", template_name })) },
                    .include_path = b.dupe(include_path),
                },
                .{
                    .KWSYS_NAMESPACE = "cmsys",
                },
            );
            h.addValues(kwsys_features);
            break :blk h;
        });
    }

    const cmSTL_hxx = b.addConfigHeader(
        .{
            .style = .{ .cmake = dep.path("Utilities/std/cmSTL.hxx.in") },
            .include_path = "cmSTL.hxx",
        },
        .{
            .CMake_HAVE_CXX_MAKE_UNIQUE = true,
            .CMake_HAVE_CXX_FILESYSTEM = true,
        },
    );

    const cmConfigure_h = b.addConfigHeader(
        .{
            .style = .{ .cmake = dep.path("Source/cmConfigure.cmake.h.in") },
            .include_path = "cmConfigure.h",
        },
        .{
            .HAVE_ENVIRON_NOT_REQUIRE_PROTOTYPE = kwsys_features.KWSYS_CXX_HAS_ENVIRON_IN_STDLIB_H,
            .HAVE_UNSETENV = kwsys_features.KWSYS_CXX_HAS_UNSETENV,
            .CMake_ENABLE_DEBUGGER = false,
            .CMake_USE_MACH_PARSER = target.result.isDarwin(),
            .CMake_USE_XCOFF_PARSER = false,
            .CMAKE_USE_WMAKE = false,
            .CMake_DEFAULT_RECURSION_LIMIT = 400,
            .CMAKE_BIN_DIR = "bootstrap-not-insalled",
            .CMAKE_DATA_DIR = "bootstrap-not-insalled",
            .CMAKE_DOC_DIR = "bootstrap-not-insalled",
            .CURL_CA_BUNDLE = false,
            .CURL_CA_PATH = false,
            .CMake_STAT_HAS_ST_MTIM = false,
            .CMake_STAT_HAS_ST_MTIMESPEC = false,
        },
    );
    if (target.result.os.tag == .windows) {
        cmConfigure_h.addValues(.{ .KWSYS_ENCODING_DEFAULT_CODEPAGE = "CP_UTF8" });
    } else {
        cmConfigure_h.addValues(.{ .KWSYS_ENCODING_DEFAULT_CODEPAGE = false });
    }

    const cmVersionConfig_h = b.addConfigHeader(
        .{
            .style = .{ .cmake = dep.path("Source/cmVersionConfig.h.in") },
            .include_path = "cmVersionConfig.h",
        },
        .{
            .CMake_VERSION_MAJOR = cmake_version.major,
            .CMake_VERSION_MINOR = cmake_version.minor,
            .CMake_VERSION_PATCH = cmake_version.patch,
            .CMake_VERSION_SUFFIX = b.dupe(cmake_version_suffix),
            .CMake_VERSION_IS_DIRTY = false, // I have no idea what this is
            .CMake_VERSION = b.dupe(cmake_version_str),
        },
    );

    const cmThirdParty_h = b.addConfigHeader(
        .{
            .style = .{ .cmake = dep.path("Utilities/cmThirdParty.h.in") },
            .include_path = "cmThirdParty.h",
        },
        .{
            .CMAKE_USE_SYSTEM_LIBUV = true,
            .CMAKE_USE_SYSTEM_JSONCPP = true,
        },
    );

    // ---- define modules ---- //

    //-- kwsys
    const kwsys_flags = try std.mem.concat(b.allocator, []const u8, &.{ basic_args, &.{"-DKWSYS_NAMESPACE=cmsys"} });
    const kwsys_root = dep.path("Source/kwsys");
    const kwsys = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
    });
    for (kwsys_config_headers.items) |h| {
        kwsys.addConfigHeader(h);
    }
    kwsys.addIncludePath(dep.path("Utilities/std"));
    kwsys.addIncludePath(dep.path("Utilities"));

    kwsys.addCSourceFiles(.{
        .flags = kwsys_flags,
        .root = kwsys_root,
        .files = &.{
            "Directory.cxx",
            "FStream.cxx",
            "Glob.cxx",
            "RegularExpression.cxx",
            "Status.cxx",
        },
    });
    kwsys.addCSourceFile(.{
        .file = kwsys_root.path(b, "EncodingCXX.cxx"),
        .flags = try std.mem.concat(b.allocator, []const u8, &.{
            &.{"-DKWSYS_ENCODING_DEFAULT_CODEPAGE=CP_ACP"},
            kwsys_flags,
        }),
    });
    kwsys.addCSourceFiles(if (target.result.os.tag == .windows) .{
        .flags = kwsys_flags,
        .root = kwsys_root,
        .files = &.{ "ProcessWin32.c", "System.c", "Terminal.c" },
    } else .{
        .flags = kwsys_flags,
        .root = kwsys_root,
        .files = &.{ "ProcessUNIX.c", "System.c", "Terminal.c" },
    });
    kwsys.addCSourceFile(.{
        .file = kwsys_root.path(b, "SystemTools.cxx"),
        .flags = try std.mem.concat(b.allocator, []const u8, &.{
            &.{
                try std.fmt.allocPrint(alloc, "-DKWSYS_CXX_HAS_SETENV={d}", .{@intFromBool(kwsys_features.KWSYS_CXX_HAS_SETENV)}),
                try std.fmt.allocPrint(alloc, "-DKWSYS_CXX_HAS_UNSETENV={d}", .{@intFromBool(kwsys_features.KWSYS_CXX_HAS_UNSETENV)}),
                try std.fmt.allocPrint(alloc, "-DKWSYS_CXX_HAS_ENVIRON_IN_STDLIB_H={d}", .{@intFromBool(kwsys_features.KWSYS_CXX_HAS_ENVIRON_IN_STDLIB_H)}),
                try std.fmt.allocPrint(alloc, "-DKWSYS_CXX_HAS_UTIMENSAT={d}", .{@intFromBool(kwsys_features.KWSYS_CXX_HAS_UTIMENSAT)}),
                try std.fmt.allocPrint(alloc, "-DKWSYS_CXX_HAS_UTIMES={d}", .{@intFromBool(kwsys_features.KWSYS_CXX_HAS_UTIMES)}),
            },
            kwsys_flags,
        }),
    });
    kwsys.addCSourceFile(.{
        .file = kwsys_root.path(b, "EncodingC.c"),
        .flags = try std.mem.concat(b.allocator, []const u8, &.{
            &.{"-DKWSYS_ENCODING_DEFAULT_CODEPAGE=CP_ACP"},
            kwsys_flags,
        }),
    });
    kwsys.addCSourceFile(.{
        .file = kwsys_root.path(b, "String.c"),
        .flags = try std.mem.concat(b.allocator, []const u8, &.{
            &.{"-DKWSYS_STRING_C"},
            kwsys_flags,
        }),
    });

    //-- librhash
    //   I'm sorry, "All Your Codebase"-ify librhash is too fucking hard.
    const librhash_args = try std.mem.concat(b.allocator, []const u8, &.{ &.{ "-DNO_IMPORT_EXPORT", "-DCMAKE_BOOTSTRAP" }, basic_args });
    const librhash = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    for (kwsys_config_headers.items) |h| {
        librhash.addConfigHeader(h);
    }
    librhash.addConfigHeader(cmThirdParty_h);
    librhash.addIncludePath(dep.path("Utilities"));

    librhash.addCSourceFiles(.{
        .flags = librhash_args,
        .root = dep.path("Utilities/cmlibrhash/librhash"),
        .files = &.{
            "algorithms.c",
            "byte_order.c",
            "hex.c",
            "md5.c",
            "rhash.c",
            "sha1.c",
            "sha256.c",
            "sha3.c",
            "sha512.c",
            "util.c",
        },
    });

    //-- libuv
    const uv_lib = b.dependency("libuv", .{}).artifact("static");

    //-- jsoncpp
    const jsoncpp_lib = b.dependency("jsoncpp", .{}).artifact("static");

    //-- cmake-std && cmake
    const cmake_flags = try std.mem.concat(b.allocator, []const u8, &.{
        basic_args,
        &.{
            posixifySlashes(try std.fmt.allocPrint(alloc, "-DCMAKE_BOOTSTRAP_SOURCE_DIR=\"{s}\"", .{getDependencyAbsolutePath(dep.path("."))})),
            posixifySlashes(try std.fmt.allocPrint(alloc, "-DCMAKE_BOOTSTRAP_BINARY_DIR=\"{s}\"", .{try std.fs.path.join(alloc, &.{ try proj_cache.out.realpathAlloc(alloc, "."), "bin" })})),
            "-DCMAKE_BOOTSTRAP_NINJA",
            "-DCMAKE_BOOTSTRAP",
        },
    });

    const cmake_std = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libcpp = true,
    });
    cmake_std.addIncludePath(dep.path("Utilities"));
    cmake_std.addIncludePath(dep.path("Utilities/std"));
    cmake_std.addCSourceFiles(.{
        .flags = cmake_flags,
        .root = dep.path("Utilities/std/cm/bits"),
        .files = &.{
            "fs_path.cxx",
            "string_view.cxx",
        },
    });
    cmake_std.addConfigHeader(cmSTL_hxx);

    const cmake_1 = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
    });
    cmake_1.addIncludePath(dep.path("Source"));
    cmake_1.addIncludePath(dep.path("Utilities"));
    cmake_1.addIncludePath(dep.path("Utilities/std"));
    cmake_1.addIncludePath(dep.path("Source/LexerParser"));
    cmake_1.addConfigHeader(cmConfigure_h);
    cmake_1.addConfigHeader(cmVersionConfig_h);
    cmake_1.addConfigHeader(cmThirdParty_h);
    cmake_1.addConfigHeader(cmSTL_hxx);
    for (kwsys_config_headers.items) |h| {
        cmake_1.addConfigHeader(h);
    }
    cmake_1.addCSourceFiles(.{
        .flags = cmake_flags,
        .root = dep.path("Source"),
        .files = &.{
            "cmAddCompileDefinitionsCommand.cxx",
            "cmAddCustomCommandCommand.cxx",
            "cmAddCustomTargetCommand.cxx",
            "cmAddDefinitionsCommand.cxx",
            "cmAddDependenciesCommand.cxx",
            "cmAddExecutableCommand.cxx",
            "cmAddLibraryCommand.cxx",
            "cmAddSubDirectoryCommand.cxx",
            "cmAddTestCommand.cxx",
            "cmArgumentParser.cxx",
            "cmBinUtilsLinker.cxx",
            "cmBinUtilsLinuxELFGetRuntimeDependenciesTool.cxx",
            "cmBinUtilsLinuxELFLinker.cxx",
            "cmBinUtilsLinuxELFObjdumpGetRuntimeDependenciesTool.cxx",
            "cmBinUtilsMacOSMachOGetRuntimeDependenciesTool.cxx",
            "cmBinUtilsMacOSMachOLinker.cxx",
            "cmBinUtilsMacOSMachOOToolGetRuntimeDependenciesTool.cxx",
            "cmBinUtilsWindowsPEGetRuntimeDependenciesTool.cxx",
            "cmBinUtilsWindowsPEDumpbinGetRuntimeDependenciesTool.cxx",
            "cmBinUtilsWindowsPELinker.cxx",
            "cmBinUtilsWindowsPEObjdumpGetRuntimeDependenciesTool.cxx",
            "cmBlockCommand.cxx",
            "cmBreakCommand.cxx",
            "cmBuildCommand.cxx",
            "cmBuildDatabase.cxx",
            "cmCMakeLanguageCommand.cxx",
            "cmCMakeMinimumRequired.cxx",
            "cmList.cxx",
            "cmCMakePath.cxx",
            "cmCMakePathCommand.cxx",
            "cmCMakePolicyCommand.cxx",
            "cmCPackPropertiesGenerator.cxx",
            "cmCacheManager.cxx",
            "cmCommandArgumentParserHelper.cxx",
            "cmCommands.cxx",
            "cmCommonTargetGenerator.cxx",
            "cmComputeComponentGraph.cxx",
            "cmComputeLinkDepends.cxx",
            "cmComputeLinkInformation.cxx",
            "cmComputeTargetDepends.cxx",
            "cmConsoleBuf.cxx",
            "cmConditionEvaluator.cxx",
            "cmConfigureFileCommand.cxx",
            "cmContinueCommand.cxx",
            "cmCoreTryCompile.cxx",
            "cmCreateTestSourceList.cxx",
            "cmCryptoHash.cxx",
            "cmCustomCommand.cxx",
            "cmCustomCommandGenerator.cxx",
            "cmCustomCommandLines.cxx",
            "cmCxxModuleMapper.cxx",
            "cmCxxModuleUsageEffects.cxx",
            "cmDefinePropertyCommand.cxx",
            "cmDefinitions.cxx",
            "cmDocumentationFormatter.cxx",
            "cmELF.cxx",
            "cmEnableLanguageCommand.cxx",
            "cmEnableTestingCommand.cxx",
            "cmEvaluatedTargetProperty.cxx",
            "cmExecProgramCommand.cxx",
            "cmExecuteProcessCommand.cxx",
            "cmExpandedCommandArgument.cxx",
            "cmExperimental.cxx",
            "cmExportBuildCMakeConfigGenerator.cxx",
            "cmExportBuildFileGenerator.cxx",
            "cmExportCMakeConfigGenerator.cxx",
            "cmExportFileGenerator.cxx",
            "cmExportInstallCMakeConfigGenerator.cxx",
            "cmExportInstallFileGenerator.cxx",
            "cmExportSet.cxx",
            "cmExportTryCompileFileGenerator.cxx",
            "cmExprParserHelper.cxx",
            "cmExternalMakefileProjectGenerator.cxx",
            "cmFileCommand.cxx",
            "cmFileCommand_ReadMacho.cxx",
            "cmFileCopier.cxx",
            "cmFileInstaller.cxx",
            "cmFileSet.cxx",
            "cmFileTime.cxx",
            "cmFileTimeCache.cxx",
            "cmFileTimes.cxx",
            "cmFindBase.cxx",
            "cmFindCommon.cxx",
            "cmFindFileCommand.cxx",
            "cmFindLibraryCommand.cxx",
            "cmFindPackageCommand.cxx",
            "cmFindPackageStack.cxx",
            "cmFindPathCommand.cxx",
            "cmFindProgramCommand.cxx",
            "cmForEachCommand.cxx",
            "cmFunctionBlocker.cxx",
            "cmFunctionCommand.cxx",
            "cmFSPermissions.cxx",
            "cmGeneratedFileStream.cxx",
            "cmGeneratorExpression.cxx",
            "cmGeneratorExpressionContext.cxx",
            "cmGeneratorExpressionDAGChecker.cxx",
            "cmGeneratorExpressionEvaluationFile.cxx",
            "cmGeneratorExpressionEvaluator.cxx",
            "cmGeneratorExpressionLexer.cxx",
            "cmGeneratorExpressionNode.cxx",
            "cmGeneratorExpressionParser.cxx",
            "cmGeneratorTarget.cxx",
            "cmGeneratorTarget_CompatibleInterface.cxx",
            "cmGeneratorTarget_IncludeDirectories.cxx",
            "cmGeneratorTarget_Link.cxx",
            "cmGeneratorTarget_LinkDirectories.cxx",
            "cmGeneratorTarget_Options.cxx",
            "cmGeneratorTarget_Sources.cxx",
            "cmGeneratorTarget_TargetPropertyEntry.cxx",
            "cmGeneratorTarget_TransitiveProperty.cxx",
            "cmGetCMakePropertyCommand.cxx",
            "cmGetDirectoryPropertyCommand.cxx",
            "cmGetFilenameComponentCommand.cxx",
            "cmGetPipes.cxx",
            "cmGetPropertyCommand.cxx",
            "cmGetSourceFilePropertyCommand.cxx",
            "cmGetTargetPropertyCommand.cxx",
            "cmGetTestPropertyCommand.cxx",
            "cmGlobalCommonGenerator.cxx",
            "cmGlobalGenerator.cxx",
            "cmGlobVerificationManager.cxx",
            "cmHexFileConverter.cxx",
            "cmIfCommand.cxx",
            "cmImportedCxxModuleInfo.cxx",
            "cmIncludeCommand.cxx",
            "cmIncludeGuardCommand.cxx",
            "cmIncludeDirectoryCommand.cxx",
            "cmIncludeRegularExpressionCommand.cxx",
            "cmInstallCMakeConfigExportGenerator.cxx",
            "cmInstallCommand.cxx",
            "cmInstallCommandArguments.cxx",
            "cmInstallCxxModuleBmiGenerator.cxx",
            "cmInstallDirectoryGenerator.cxx",
            "cmInstallExportGenerator.cxx",
            "cmInstallFileSetGenerator.cxx",
            "cmInstallFilesCommand.cxx",
            "cmInstallFilesGenerator.cxx",
            "cmInstallGenerator.cxx",
            "cmInstallGetRuntimeDependenciesGenerator.cxx",
            "cmInstallImportedRuntimeArtifactsGenerator.cxx",
            "cmInstallRuntimeDependencySet.cxx",
            "cmInstallRuntimeDependencySetGenerator.cxx",
            "cmInstallScriptGenerator.cxx",
            "cmInstallSubdirectoryGenerator.cxx",
            "cmInstallTargetGenerator.cxx",
            "cmInstallTargetsCommand.cxx",
            "cmInstalledFile.cxx",
            "cmJSONHelpers.cxx",
            "cmJSONState.cxx",
            "cmLDConfigLDConfigTool.cxx",
            "cmLDConfigTool.cxx",
            "cmLinkDirectoriesCommand.cxx",
            "cmLinkItem.cxx",
            "cmLinkItemGraphVisitor.cxx",
            "cmLinkLineComputer.cxx",
            "cmLinkLineDeviceComputer.cxx",
            "cmListCommand.cxx",
            "cmListFileCache.cxx",
            "cmLocalCommonGenerator.cxx",
            "cmLocalGenerator.cxx",
            "cmMSVC60LinkLineComputer.cxx",
            "cmMacroCommand.cxx",
            "cmMakeDirectoryCommand.cxx",
            "cmMakefile.cxx",
            "cmMarkAsAdvancedCommand.cxx",
            "cmMathCommand.cxx",
            "cmMessageCommand.cxx",
            "cmMessenger.cxx",
            "cmNewLineStyle.cxx",
            "cmOSXBundleGenerator.cxx",
            "cmOptionCommand.cxx",
            "cmOrderDirectories.cxx",
            "cmOutputConverter.cxx",
            "cmParseArgumentsCommand.cxx",
            "cmPathLabel.cxx",
            "cmPathResolver.cxx",
            "cmPolicies.cxx",
            "cmProjectCommand.cxx",
            "cmValue.cxx",
            "cmPropertyDefinition.cxx",
            "cmPropertyMap.cxx",
            "cmGccDepfileLexerHelper.cxx",
            "cmGccDepfileReader.cxx",
            "cmReturnCommand.cxx",
            "cmPackageInfoReader.cxx",
            "cmPlaceholderExpander.cxx",
            "cmPlistParser.cxx",
            "cmRulePlaceholderExpander.cxx",
            "cmRuntimeDependencyArchive.cxx",
            "cmScriptGenerator.cxx",
            "cmSearchPath.cxx",
            "cmSeparateArgumentsCommand.cxx",
            "cmSetCommand.cxx",
            "cmSetDirectoryPropertiesCommand.cxx",
            "cmSetPropertyCommand.cxx",
            "cmSetSourceFilesPropertiesCommand.cxx",
            "cmSetTargetPropertiesCommand.cxx",
            "cmSetTestsPropertiesCommand.cxx",
            "cmSiteNameCommand.cxx",
            "cmSourceFile.cxx",
            "cmSourceFileLocation.cxx",
            "cmStandardLevelResolver.cxx",
            "cmState.cxx",
            "cmStateDirectory.cxx",
            "cmStateSnapshot.cxx",
            "cmString.cxx",
            "cmStringAlgorithms.cxx",
            "cmStringReplaceHelper.cxx",
            "cmStringCommand.cxx",
            "cmSubcommandTable.cxx",
            "cmSubdirCommand.cxx",
            "cmSystemTools.cxx",
            "cmTarget.cxx",
            "cmTargetCompileDefinitionsCommand.cxx",
            "cmTargetCompileFeaturesCommand.cxx",
            "cmTargetCompileOptionsCommand.cxx",
            "cmTargetIncludeDirectoriesCommand.cxx",
            "cmTargetLinkLibrariesCommand.cxx",
            "cmTargetLinkOptionsCommand.cxx",
            "cmTargetPrecompileHeadersCommand.cxx",
            "cmTargetPropCommandBase.cxx",
            "cmTargetPropertyComputer.cxx",
            "cmTargetSourcesCommand.cxx",
            "cmTargetTraceDependencies.cxx",
            "cmTest.cxx",
            "cmTestGenerator.cxx",
            "cmTimestamp.cxx",
            "cmTransformDepfile.cxx",
            "cmTryCompileCommand.cxx",
            "cmTryRunCommand.cxx",
            "cmUnsetCommand.cxx",
            "cmUVHandlePtr.cxx",
            "cmUVProcessChain.cxx",
            "cmVersion.cxx",
            "cmWhileCommand.cxx",
            "cmWindowsRegistry.cxx",
            "cmWorkingDirectory.cxx",
            "cmXcFramework.cxx",
            "cmake.cxx",
            "cmakemain.cxx",
            "cmcmd.cxx",
            "cm_fileno.cxx",
            "cmFortranParserImpl.cxx",
            "cmGlobalNinjaGenerator.cxx",
            "cmLocalNinjaGenerator.cxx",
            "cmNinjaLinkLineComputer.cxx",
            "cmNinjaLinkLineDeviceComputer.cxx",
            "cmNinjaNormalTargetGenerator.cxx",
            "cmNinjaTargetGenerator.cxx",
            "cmNinjaUtilityTargetGenerator.cxx",
        },
    });
    cmake_1.addCSourceFiles(.{
        .flags = cmake_flags,
        .root = dep.path("Source/LexerParser"),
        .files = &.{
            "cmCommandArgumentLexer.cxx",
            "cmCommandArgumentParser.cxx",
            "cmExprLexer.cxx",
            "cmExprParser.cxx",
            "cmGccDepfileLexer.cxx",
            "cmFortranLexer.cxx",
            "cmFortranParser.cxx",
        },
    });
    cmake_1.addCSourceFile(.{
        .file = dep.path("Source/LexerParser/cmListFileLexer.c"),
        .flags = cmake_flags,
    });
    cmake_1.addCSourceFile(.{
        .file = dep.path("Source/cmProcessOutput.cxx"),
        .flags = try std.mem.concat(b.allocator, []const u8, &.{
            &.{"-DKWSYS_ENCODING_DEFAULT_CODEPAGE=CP_ACP"},
            cmake_flags,
        }),
    });
    if (target.result.isDarwin()) {
        cmake_1.addCSourceFile(.{
            .flags = cmake_flags,
            .file = dep.path("Source/cmMachO.cxx"),
        });
    } else if (target.result.os.tag == .windows) {
        // TODO: they're useless to the cmake_1 executable. replace them with dummy code one day?
        cmake_1.addCSourceFiles(.{
            .flags = cmake_flags,
            .root = dep.path("Source"),
            .files = &.{
                "cmGlobalMSYSMakefileGenerator.cxx",
                "cmGlobalMinGWMakefileGenerator.cxx",
                "cmVSSetupHelper.cxx",
                "cmDepends.cxx",
                "cmDependsC.cxx",
                "cmDependsCompiler.cxx",
                "cmGlobalUnixMakefileGenerator3.cxx",
                "cmLocalUnixMakefileGenerator3.cxx",
                "cmMakefileExecutableTargetGenerator.cxx",
                "cmMakefileLibraryTargetGenerator.cxx",
                "cmMakefileTargetGenerator.cxx",
                "cmMakefileUtilityTargetGenerator.cxx",
                "cmProcessTools.cxx",
            },
        });
    }

    // ---- build ---- //
    const cmake_1_exe = b.addExecutable(.{
        .name = "cmake_1",
        .root_module = cmake_1,
    });

    // meant to make them objects but Windows coff doesn't allow linking multiple objects or something
    const librhash_lib = b.addStaticLibrary(.{
        .name = "librhash",
        .root_module = librhash,
    });
    const kwsys_lib = b.addStaticLibrary(.{
        .name = "kwsys",
        .root_module = kwsys,
    });
    const cmake_std_lib = b.addStaticLibrary(.{
        .name = "cmstd",
        .root_module = cmake_std,
    });

    cmake_1_exe.linkLibrary(librhash_lib);
    cmake_1_exe.linkLibrary(kwsys_lib);
    cmake_1_exe.linkLibrary(cmake_std_lib);
    cmake_1_exe.linkLibrary(uv_lib);
    cmake_1_exe.linkLibrary(jsoncpp_lib);
    if (target.result.os.tag == .windows) {
        // needs this so the "useless" source files compile. otherwise of no use.
        cmake_1_exe.linkSystemLibrary2("oleaut32", .{});
    }
    if (target.result.isDarwin()) cmake_1_exe.linkFramework("CoreFoundation");

    // ---- bootstrap ---- //

    const bootstrap = b.addRunArtifact(cmake_1_exe);
    bootstrap.addDirectoryArg(dep.path("."));
    bootstrap.addArg(try std.fmt.allocPrint(b.allocator, "-C{s}", .{try proj_cache.tools.realpathAlloc(alloc, "bootstrap_cache.cmake")}));
    bootstrap.addArg("-GNinja");
    bootstrap.addArg("-DCMAKE_BOOTSTRAP=1");
    bootstrap.setCwd(b.path(".proj-cache/bootstrap"));

    const bootstrap_make = b.addSystemCommand(&.{ "ninja", "-j12" });
    bootstrap_make.setCwd(b.path(".proj-cache/bootstrap"));
    bootstrap_make.step.dependOn(&bootstrap.step);

    const bootstrap_install = b.addSystemCommand(&.{ "ninja", "-j12", "install" });
    bootstrap_install.setCwd(b.path(".proj-cache/bootstrap"));
    bootstrap_install.step.dependOn(&bootstrap_make.step);

    const zig_install = b.addInstallDirectory(.{
        .source_dir = b.path(".proj-cache/out"),
        .install_dir = .prefix,
        .install_subdir = "",
    });

    b.addNamedLazyPath("out", b.path(".proj-cache/out"));
    if (not_built: {
        proj_cache.out.access("bin/cmake", .{}) catch |err| {
            if (err == error.FileNotFound) {
                break :not_built true;
            } else {
                return err;
            }
        };
        break :not_built false;
    }) {
        b.getInstallStep().dependOn(&bootstrap_install.step);
        zig_install.step.dependOn(&bootstrap_install.step);
    }
    b.getInstallStep().dependOn(&zig_install.step);
}

fn getDependencyAbsolutePath(path: std.Build.LazyPath) []const u8 {
    return path.dependency.dependency.builder.pathFromRoot(path.dependency.sub_path);
}

fn posixifySlashes(str: []u8) []u8 {
    for (str) |*chr| {
        if (chr.* == '\\') {
            chr.* = '/';
        }
    }
    return str;
}

const ProjCacher = struct {
    root: std.fs.Dir,
    tools: std.fs.Dir,
    bootstrap: std.fs.Dir,
    out: std.fs.Dir,

    pub fn init(allocator: std.mem.Allocator, builder: *std.Build, target: std.Build.ResolvedTarget) !ProjCacher {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        const root = blk: {
            const path = try std.fs.path.join(alloc, &.{ try builder.build_root.handle.realpathAlloc(alloc, "."), ".proj-cache" });
            break :blk try builder.build_root.handle.makeOpenPath(path, .{});
        };
        const bootstrap = try root.makeOpenPath("bootstrap", .{});
        const out = try root.makeOpenPath("out", .{});
        const tools = blk: {
            try root.deleteTree("tools");
            const dir = try root.makeOpenPath("tools", .{});
            if (builtin.os.tag != .windows) {
                const zig_cc = try dir.createFile("cc", .{});
                defer zig_cc.close();
                try zig_cc.writeAll(try std.fmt.allocPrint(alloc,
                    \\#!/bin/sh
                    \\{s} cc "$@"
                , .{builder.graph.zig_exe}));
                try zig_cc.chmod(0o777);

                const zig_cxx = try dir.createFile("c++", .{});
                defer zig_cxx.close();
                try zig_cxx.writeAll(try std.fmt.allocPrint(alloc,
                    \\#!/bin/sh
                    \\{s} c++ "$@"
                , .{builder.graph.zig_exe}));
                try zig_cxx.chmod(0o777);

                const zig_ar = try dir.createFile("ar", .{});
                defer zig_ar.close();
                try zig_ar.writeAll(try std.fmt.allocPrint(alloc,
                    \\#!/bin/sh
                    \\{s} ar "$@"
                , .{builder.graph.zig_exe}));
                try zig_ar.chmod(0o777);

                const zig_rc = try dir.createFile("rc", .{});
                defer zig_rc.close();
                try zig_rc.writeAll(try std.fmt.allocPrint(alloc,
                    \\#!/bin/sh
                    \\{s} rc "$@"
                , .{builder.graph.zig_exe}));
                try zig_rc.chmod(0o777);
            } else {
                const zig_cc = try dir.createFile("cc.bat", .{});
                defer zig_cc.close();
                try zig_cc.writeAll(try std.fmt.allocPrint(alloc,
                    \\@echo off
                    \\{s} cc %*
                , .{builder.graph.zig_exe}));

                const zig_cxx = try dir.createFile("c++.bat", .{});
                defer zig_cxx.close();
                try zig_cxx.writeAll(try std.fmt.allocPrint(alloc,
                    \\@echo off
                    \\{s} c++ %*
                , .{builder.graph.zig_exe}));

                const zig_ar = try dir.createFile("ar.bat", .{});
                defer zig_ar.close();
                try zig_ar.writeAll(try std.fmt.allocPrint(alloc,
                    \\@echo off
                    \\{s} ar %*
                , .{builder.graph.zig_exe}));

                const zig_rc = try dir.createFile("rc.bat", .{});
                defer zig_rc.close();
                try zig_rc.writeAll(try std.fmt.allocPrint(alloc,
                    \\@echo off
                    \\{s} rc %*
                , .{builder.graph.zig_exe}));
            }

            const cmake_cache = try dir.createFile("bootstrap_cache.cmake", .{});
            defer cmake_cache.close();
            try cmake_cache.writeAll(cache: {
                const cache_str = try std.fmt.allocPrint(alloc,
                    \\set(CMAKE_C_LINKER_DEPFILE_SUPPORTED OFF CACHE BOOL "someday needs it, bro." FORCE)
                    \\set(CMAKE_CXX_LINKER_DEPFILE_SUPPORTED OFF CACHE BOOL "someday needs it, bro." FORCE)
                    \\set(CMAKE_C_COMPILER "{s}" CACHE PATH "" FORCE)
                    \\set(CMAKE_C_FLAGS "{s}" CACHE STRING "" FORCE)
                    \\set(CMAKE_CXX_COMPILER "{s}" CACHE PATH "" FORCE)
                    \\set(CMAKE_CXX_FLAGS "{s}" CACHE STRING "" FORCE)
                    \\set(CMAKE_AR "{s}" CACHE PATH "" FORCE)
                    \\set(CMAKE_RC_COMPILER "{s}" CACHE PATH "" FORCE)
                    \\set(CMAKE_INSTALL_PREFIX "{s}" CACHE PATH "" FORCE)
                    \\set(CMAKE_DATA_DIR "share/cmake" CACHE PATH "" FORCE)
                    \\set(CMAKE_BUILD_TYPE "Release" CACHE STRING "") # "not FORCE to preserve defaults specified elsewhere", according to original CMake bootstrap script
                , .{
                    try dir.realpathAlloc(alloc, if (builtin.os.tag != .windows) "cc" else "cc.bat"),
                    "-fno-sanitize=undefined -D_FILE_OFFSET_BITS=64",
                    try dir.realpathAlloc(alloc, if (builtin.os.tag != .windows) "c++" else "c++.bat"),
                    "-fno-sanitize=undefined -D_FILE_OFFSET_BITS=64",
                    try dir.realpathAlloc(alloc, if (builtin.os.tag != .windows) "ar" else "ar.bat"),
                    try dir.realpathAlloc(alloc, if (builtin.os.tag != .windows) "rc" else "rc.bat"),
                    try out.realpathAlloc(alloc, "."),
                });
                if (target.result.os.tag == .windows) {
                    _ = posixifySlashes(cache_str);
                }
                break :cache cache_str;
            });

            break :blk dir;
        };

        return ProjCacher{
            .root = root,
            .tools = tools,
            .bootstrap = bootstrap,
            .out = out,
        };
    }
    pub fn deinit(self: *ProjCacher) void {
        self.root.close();
        self.tools.close();
        self.bootstrap.close();
        self.out.close();
    }
};

const ArrayList = std.ArrayList;
const ConfigHeader = std.Build.Step.ConfigHeader;
const builtin = @import("builtin");
