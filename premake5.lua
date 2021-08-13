-- premake5.lua

-- This file describes the build configuration for Slang LLVM/Clang libray so
-- that premake can generate platform-specific build files
-- using Premake 5 (https://premake.github.io/).
--
-- To update the build files that are checked in to the Slang repository,
-- run a `premake5` binary and specify the appropriate action, e.g.:
--
--      premake5.exe --os=windows vs2015
--
-- If you are trying to build on another platform, then you
-- can try invoking `premake5` for your desired OS and build format
-- and see what happens.
--
-- If you are going to modify this file to change/customize the
-- build, then you may need to read up on Premake's approach and
-- how it uses/abuses Lua syntax. A few important things to note:
--
-- * Everything that *looks* like a declarative (e.g., `kind "SharedLib"`)
-- is actually a Lua function call (e.g., `kind("SharedLib")`) that
-- modifies the behind-the-scenes state that describes the build.
--
-- * Many of these function calls are "sticky" and affect subsequent
-- calls, so ordering matters a *lot*. This file uses indentation to
-- represent some of the flow of state, but it is important to recognize
-- that the indentation is not semantically significant.
--
-- * Because the configuration logic is just executable Lua code, we
-- can capture and re-use bits of configuration logic in ordinary
-- Lua subroutines.
--
-- Now let's move on to the actual build:

-- The "workspace" represents the overall build (the "solution" in
-- Visual Studio terms). It sets up basic build settings that will
-- apply across all projects.
--

newoption {
   trigger     = "target-detail",
   description = "(Optional) More specific target information",
   value       = "string",
   allowed     = { {"cygwin"}, {"mingw"} }
}

newoption {
   trigger     = "llvm-path",
   description = "The path to the build directory for LLVM",
   value       = "string"
}

targetDetail = _OPTIONS["target-detail"]
llvmPath = _OPTIONS["llvm-path"]

-- Is true when the target is really windows (ie not something on top of windows like cygwin)
isTargetWindows = (os.target() == "windows") and not (targetDetail == "mingw" or targetDetail == "cygwin")

targetName = "%{cfg.system}-%{cfg.platform:lower()}"

if not (targetDetail == nil) then
    targetName = targetDetail .. "-%{cfg.platform:lower()}"
end

-- This is needed for gcc, for the 'fileno' functions on cygwin
-- _GNU_SOURCE makes realpath available in gcc
if targetDetail == "cygwin" then
    buildoptions { "-D_POSIX_SOURCE" }
    filter { "toolset:gcc*" }
        buildoptions { "-D_GNU_SOURCE" }
end

workspace "slang-llvm"
    -- We will support debug/release configuration and x86/x64 builds.
    configurations { "Debug", "Release" }
    platforms { "x86", "x64"}
    
    if os.target() == "linux" then
        platforms {"aarch64" }
    end
    
    -- 
    -- Make slang-test the startup project.
    --
    -- https://premake.github.io/docs/startproject
    startproject "clang-direct"
    
    -- The output binary directory will be derived from the OS
    -- and configuration options, e.g. `bin/windows-x64/debug/`
    targetdir("bin/" .. targetName .. "/%{cfg.buildcfg:lower()}")

    -- C++11 
    cppdialect "C++11"
    -- Statically link to the C/C++ runtime rather than create a DLL dependency.
    staticruntime "On"
    
    -- Statically link to the C/C++ runtime rather than create a DLL dependency.
    
    -- Once we've set up the common settings, we will make some tweaks
    -- that only apply in a subset of cases. Each call to `filter()`
    -- changes the "active" filter for subsequent commands. In
    -- effect, those commands iwll be ignored when the conditions of
    -- the filter aren't satisfied.

    -- Our `x64` platform should (obviously) target the x64
    -- architecture and similarly for x86.
    filter { "platforms:x64" }
        architecture "x64"
    filter { "platforms:x86" }
        architecture "x86"
    filter { "platforms:aarch64"}
        architecture "ARM"

    filter { "toolset:clang or gcc*" }
        buildoptions { "-Wno-unused-parameter", "-Wno-type-limits", "-Wno-sign-compare", "-Wno-unused-variable", "-Wno-reorder", "-Wno-switch", "-Wno-return-type", "-Wno-unused-local-typedefs", "-Wno-parentheses",  "-fvisibility=hidden" , "-Wno-ignored-optimization-argument", "-Wno-unknown-warning-option", "-Wno-class-memaccess"} 
        
    filter { "toolset:gcc*"}
        buildoptions { "-Wno-unused-but-set-variable", "-Wno-implicit-fallthrough"  }
        
    filter { "toolset:clang" }
         buildoptions { "-Wno-deprecated-register", "-Wno-tautological-compare", "-Wno-missing-braces", "-Wno-undefined-var-template", "-Wno-unused-function", "-Wno-return-std-move"}
        
    -- When compiling the debug configuration, we want to turn
    -- optimization off, make sure debug symbols are output,
    -- and add the same preprocessor definition that VS
    -- would add by default.
    filter { "configurations:debug" }
        optimize "Off"
        symbols "On"
        defines { "_DEBUG" }
    
    -- staticruntime "Off"
    
    -- For the release configuration we will turn optimizations on
    -- (we do not yet micro-manage the optimization settings)
    -- and set the preprocessor definition that VS would add by default.
    filter { "configurations:release" }
        optimize "On"
        defines { "NDEBUG" }
            
    filter { "system:linux" }
        linkoptions{  "-Wl,-rpath,'$$ORIGIN',--no-as-needed", "-ldl"}
            
function dump(o)
    if type(o) == 'table' then
        local s = '{ '
        for k,v in pairs(o) do
            if type(k) ~= 'number' then k = '"'..k..'"' end
            s = s .. '['..k..'] = ' .. dump(v) .. ','
        end
        return s .. '} '
    else
        return tostring(o)
     end
end
    
function dumpTable(o)
    local s = '{ '
    for k,v in pairs(o) do
        if type(k) ~= 'number' then k = '"'..k..'"' end
        s = s .. '['..k..'] = ' .. tostring(v) .. ',\n'
    end
    return s .. '} '
end

function getExecutableSuffix()
    if(os.target() == "windows") then
        return ".exe"
    end
    return ""
end
--
-- We are now going to start defining the projects, where
-- each project builds some binary artifact (an executable,
-- library, etc.).
--
-- All of our projects follow a common structure, so rather
-- than reiterate a bunch of build settings, we define
-- some subroutines that make the configuration as concise
-- as possible.
--
-- First, we will define a helper routine for adding all
-- the relevant files from a given directory path:
--
-- Note that this does not work recursively 
-- so projects that spread their source over multiple
-- directories will need to take more steps.
function addSourceDir(path)
    files
    {
        path .. "/*.cpp",       -- C++ source files
        path .. "/*.h",         -- Header files
        path .. "/*.hpp",       -- C++ style headers (for glslang)
        path .. "/*.natvis",    -- Visual Studio debugger visualization files
    }
end

--
-- A function to return a name to place project files under 
-- in build directory
--
-- This is complicated in so far as when this is used (with location for example)
-- we can't use Tokens 
-- https://github.com/premake/premake-core/wiki/Tokens

function getBuildLocationName()
    if not not targetDetail then
        return targetDetail
    elseif isTargetWindows then
        return "visual-studio"
    else
        return os.target()
    end 
end

--
-- Next we will define a helper routine that all of our
-- projects will bottleneck through. Here `name` is
-- the name for the project (and the base name for
-- whatever output file it produces), while `sourceDir`
-- is the directory that holds the source.
--
-- E.g., for the `slang-llvm` project, the source code
-- is nested in `source/`, so we'd (indirectly) call:
--
--      baseroject("slang-llvm", "source/slang-llvm")
--
-- NOTE! This function will add any source from the sourceDir, *if* it's specified. 
-- Pass nil if adding files is not wanted.
function baseProject(name, sourceDir)

    -- Start a new project in premake. This switches
    -- the "current" project over to the newly created
    -- one, so that subsequent commands affect this project.
    --
    project(name)

    -- We need every project to have a stable UUID for
    -- output formats (like Visual Studio and XCode projects)
    -- that use UUIDs rather than names to uniquely identify
    -- projects. If we don't have a stable UUID, then the
    -- output files might have spurious diffs whenever we
    -- re-run premake generation.
    
    if sourceDir then
        uuid(os.uuid(name .. '|' .. sourceDir))
    else
        -- If we don't have a sourceDir, the name will have to be enough
        uuid(os.uuid(name))
    end

    -- Location could do with a better name than 'other' - but it seems as if %{cfg.buildcfg:lower()} and similar variables
    -- is not available for location to expand. 
    location("build/" .. getBuildLocationName() .. "/" .. name)

    -- The intermediate ("object") directory will use a similar
    -- naming scheme to the output directory, but will also use
    -- the project name to avoid cases where multiple projects
    -- have source files with the same name.
    --
    objdir("intermediate/" .. targetName .. "/%{cfg.buildcfg:lower()}/%{prj.name}")
    
    -- All of our projects are written in C++.
    --
    language "C++"

    -- By default, Premake generates VS project files that
    -- reflect the directory structure of the source code.
    -- While this is nice in principle, it creates messy
    -- results in practice for our projects.
    --
    -- Instead, we will use the `vpaths` feature to imitate
    -- the default VS behavior of grouping files into
    -- virtual subdirectories (VS calls them "filters") for
    -- header and source files respectively.
    --
    -- Note: We are setting `vpaths` using a list of key/value
    -- tables instead of just a key/value table, since this
    -- appears to be an (undocumented) way to fix the order
    -- in which the filters are tested. Otherwise we have
    -- issues where premake will nondeterministically decide
    -- the check something against the `**.cpp` filter first,
    -- and decide that a `foo.cpp.h` file should go into
    -- the `"Source Files"` vpath. That behavior seems buggy,
    -- but at least we appear to have a workaround.
    --
    vpaths {
       { ["Header Files"] = { "**.h", "**.hpp"} },
       { ["Source Files"] = { "**.cpp", "**.slang", "**.natvis" } },
    }
    
    --
    -- Add the files in the sourceDir
    -- NOTE! This doesn't recursively add files in subdirectories
    --
    
    if not not sourceDir then
        addSourceDir(sourceDir)
    end
end


-- We can now use the `baseProject()` subroutine to
-- define helpers for the different categories of project
-- in our source tree.
--
-- For example, the Slang project has several tools that
-- are used during building/testing, but don't need to
-- be distributed. These always have their source code in
-- `tools/<project-name>/`.
--
function tool(name)
    -- We use the `group` command here to specify that the
    -- next project we create shold be placed into a group
    -- named "tools" in a generated IDE solution/workspace.
    --
    -- This is used in the generated Visual Studio solution
    -- to group all the tools projects together in a logical
    -- sub-directory of the solution.
    --
    group "tools"

    -- Now we invoke our shared project configuration logic,
    -- specifying that the project lives under the `tools/` path.
    --
    baseProject(name, "tools/" .. name)
    
    -- Finally, we set the project "kind" to produce a console
    -- application. This is a reasonable default for tools,
    -- and it can be overriden because Premake is stateful,
    -- and a subsequent call to `kind()` would overwrite this
    -- default.
    --
    kind "ConsoleApp"
end

-- "Standard" projects will be those that go to make the binary
-- packages the shared libraries and executables.
--
function standardProject(name, sourceDir)
    -- Because Premake is stateful, any `group()` call by another
    -- project would still be in effect when we create a project
    -- here (e.g., if somebody had called `tool()` before
    -- `standardProject()`), so we are careful here to set the
    -- group to an emptry string, which Premake treats as "no group."
    --
    group ""

    baseProject(name, sourceDir)
end

-- Finally we have the example programs that show how to use Slang.
--
function example(name)
    -- Example programs go into an "example" group
    group "examples"

    -- They have their source code under `examples/<project-name>/`
    baseProject(name, "examples/" .. name)

    -- Set up working directory to be the source directory
    debugdir("examples/" .. name)

    -- By default, all of our examples are console applications. 
    kind "ConsoleApp"
    
    -- The examples also need to link against the core slang library.
    links { "core"  }
end

--
-- With all of these helper routines defined, we can now define the
-- actual projects quite simply. For example, here is the entire
-- declaration of the "Hello, World" example project:
--
example "clang-direct"
    kind "ConsoleApp"
    
    -- So we can access slang.h
    includedirs {"external/slang", "external/slang/source"}

    links { "core", "compiler-core" }

-- Most of the other projects have more interesting configuration going
-- on, so let's walk through them in order of increasing complexity.
--
-- The `core` project is a static library that has all the basic types
-- and routines that get shared across both the Slang compiler/runtime
-- and the various tool projects. It's build is pretty simple:
--

standardProject("core", "external/slang/source/core")
    uuid "F9BE7957-8399-899E-0C49-E714FDDD4B65"
    kind "StaticLib"
    -- We need the core library to be relocatable to be able to link with slang.so
    pic "On"

    removefiles { "external/slang/source/core/slang-lz4-compression-system.cpp",    
        "external/slang/source/core/slang-zip-file-system.cpp",
        "external/slang/source/core/slang-deflate-compression-system.cpp",
        }

    -- For our core implementation, we want to use the most
    -- aggressive warning level supported by the target, and
    -- to treat every warning as an error to make sure we
    -- keep our code free of warnings.
    --
    warnings "Extra"
    flags { "FatalWarnings" }
    
    if isTargetWindows then
        addSourceDir "external/slang/source/core/windows"
    else
        addSourceDir "external/slang/source/core/unix"
    end
    
standardProject("compiler-core", "source/compiler-core")
    uuid "12C1E89D-F5D0-41D3-8E8D-FB3F358F8126"
    kind "StaticLib"
    -- We need the compiler-core library to be relocatable to be able to link with slang.so
    pic "On"

    links { "core" }

    -- For our core implementation, we want to use the most
    -- aggressive warning level supported by the target, and
    -- to treat every warning as an error to make sure we
    -- keep our code free of warnings.
    --
    warnings "Extra"
    flags { "FatalWarnings" }    
    
    if isTargetWindows then
        addSourceDir "external/slang/source/compiler-core/windows"
    else
        addSourceDir "external/slang/source/compiler-core/unix"
    end
