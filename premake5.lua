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

-- 
-- Some globals needed by following functions
--

g_isTargetWindows = false
g_targetDetail = nil

function initGlobals(inTargetDetail)
    g_targetDetail = inTargetDetail
    g_isTargetWindows = (os.target() == "windows") and not (inTargetDetail == "mingw" or inTargetDetail == "cygwin")
end

function isTargetWindows()
    return g_isTargetWindows
end

function getTargetDetail()
    return g_targetDetail
end

-- 
-- Define some useful functions
--

function valueToString(o)
    if type(o) == 'table' then
        return tableToString(o)
    else
        return tostring(o)
     end
end
    
function tableToString(o)
    local s = '{ '
    for k,v in pairs(o) do
        if type(k) ~= 'number' then k = '"'..k..'"' end
        s = s .. '['..k..'] = ' .. tostring(v) .. ',\n'
    end
    return s .. '} '
end

function dump(o)
    print(valueToString(o))
end

function getExecutableSuffix()
    if(os.target() == "windows") then
        return ".exe"
    end
    return ""
end

function trimPrefix(s, p)
    local t = (s:sub(0, #p) == p) and s:sub(#p + 1) or s
    return t
end

--
-- It turns out there are 'libraries' inside LLVM/Clang which are not 
-- part of linking with clang, and example would be "clang-interpreter.lib"
-- which if linked with will make clang-interpreter.exe a dependency.
--
-- This functions purpose is to determine if a library name is for a 'normal'
-- clang library
--
function isClangLibraryName(name)
    return not string.startswith(name, "clang-")
end

-- 
-- The LLVM-C library seems to confuse things because
-- 
-- * It must be built as a shared library 
-- ** LLVM will make it a shared library, even if *static* library is selected (as here)
-- * If it links with the project it breaks the LLVM JIT 
-- 
-- This is probably the case because the symbol/s is multiply defined and if the linker picks
-- the ones in LLVM-C, then the registering of targets is *in* the LLVM-C impl.
--
-- So to avoid this we, just remove from linked libraries
function isLLVMLibraryName(name)
    return not string.startswith(name, "LLVM-C")
end

function findLibraries(basePath, inMatchName, matchFunc)
    local matchName = inMatchName
    if isTargetWindows() then
        matchName = inMatchName .. ".lib"
    else
        matchName = "lib" .. inMatchName .. ".a"
    end
 
    local matchPath = path.join(basePath, matchName)
 
    local libs = os.matchfiles(matchPath)
       
    local dstLibs = {}   
       
    for k, v in ipairs(libs) do
        -- Strip off path and extension
        local libBaseName = path.getbasename(v)
        local libName = libBaseName
        
        if not isTargetWindows() then
            -- If the name starts with "lib" strip it
            libName = trimPrefix(libName, "lib")
        end
    
        if matchFunc == nil or matchFunc(libName) then
            table.insert(dstLibs, libName)
        end
    end
        
    return dstLibs
end

function getLLVMLibraryPath(llvmBuildPath, libraryType)
    if isTargetWindows() then
       return path.join(llvmBuildPath, path.join(libraryType, "lib"))
    else
        return path.join(llvmBuildPath, "lib")
    end
end

-- 
-- Append (assuming 'array' table b onto a)
--
function appendTable(a, b)  
    for _,v in ipairs(b) do 
        table.insert(a, v)
    end
end

--
-- Given two (array) tables returns the concatination 
--
function concatTables(a, b)
    a = table.table_copy(a)
    appendTable(a, b)
    return a
end

-- A function to return a name to place project files under 
-- in build directory
--
-- This is complicated in so far as when this is used (with location for example)
-- we can't use Tokens 
-- https://github.com/premake/premake-core/wiki/Tokens

function getBuildLocationName()
    if not not getTargetDetail() then
        return getTargetDetail()
    elseif isTargetWindows() then
        return "visual-studio"
    else
        return os.target()
    end 
end

function displayProgress(total, current)  
    local ratio = current / total;  
    ratio = math.min(math.max(ratio, 0), 1);  
    --local percent = math.floor(ratio * 100);  
    
    local numBars = 32
    local downloadedBars = math.floor(ratio * numBars)
    
    local bar = string.rep("#", downloadedBars) .. string.rep(".", numBars - downloadedBars)
    
    local spinIndex = math.floor(ratio * 4096) % 4
    local spin = string.sub("|\\-/", spinIndex + 1, spinIndex + 1)
    
    io.write("\rDownload progress (" .. spin .. ") " .. bar )
end

function readJSONFromFile(path)
    local fileContents = io.readfile(path)
    if fileContents == nil then
        return nil, "Unable to read file '" .. path .. "'"
    end
    
    return json.decode(fileContents)
end

--
-- Update dependencies
-- 

function updateDeps(platformName, jsonName, noProgress)
    if jsonName == nil then
        jsonName = "deps/target-deps.json"
    end
    
    -- Make noProgress a bool
    noProgress = not not noProgress
    
    -- Load the json
    local result, err = readJSONFromFile(jsonName)
    if err then
        return error(err)
    end
    
    -- Okay we have the json. We now need to work through the dependencies
    local projectInfo = result["project"]
    if projectInfo == nil then
        return error("Expecting 'project' in json")
    end
    
    local projectName = projectInfo["name"]
    
    -- If no dependencies we are done
    local dependencies = projectInfo["dependencies"]
    if dependencies == nil then
        return
    end
    
    for i, dependency in ipairs(dependencies) 
    do
        local dependencyName = dependency["name"]
        if dependencyName == nil then
            return error("Dependency doesn't have a name")
        end
       
        local baseUrl = dependency["baseUrl"]
        local packages = dependency["packages"]
      
        local platformPackage = packages[platformName]
        if platformPackage == nil then
            return error("No package fro dependency '" .. dependencyName .. "' for target '" ..platform .. "'")
        end
       
        local url = platformPackage
        
        -- If it starts with file: we can just use the file
        -- If it starts with dir: (say) then we just use the directory 
        
        if string.startswith(url, "https://") or 
           string.startswith(url, "http://") or
           string.startswith(url, "file://") or 
           string.startswith(url, "dir://") then
        else
            if type(baseUrl) == "string" then
                url = baseUrl .. url
            end
        end
       
        -- We need to work out the filename.
        local packageFileName = path.getname(platformPackage)
        
        local dependencyPath = path.join("external", dependencyName)
        local packagePath = path.join("external", packageFileName)
        local packageInfoPath = path.join(dependencyPath, "package-info.json")
        
        -- Check if there is an expansion of the dependency
        if os.isdir(dependencyPath) then
            -- Check if the package info is suitable
            local result, err = readJSONFromFile(packageInfoPath)
        
            -- If it contains a matching package name, we are done 
            if err == nil and result["name"] == packageFileName then
                return
            end
        end
        
        -- We don't know it the package is complete as downloaded. As the user can cancel for example. 
        -- So we delete what we have, so we can redownload a fresh copy.
        --
        -- NOTE! This means that there is only two states, either we download and extract everything (and mark with package-info.json)
        -- Or we have the download dependency with the correct package-info.json (ie a previous download/extraction was fully 
        -- successful)
        if os.isfile(packagePath) then
            print("Removing '" .. packagePath .. "' for fresh download")
            os.remove(packagePath)
        end

        do
            print("Downloading '" .. url .. "'")
        
            local result_str, response_code
        
            if noProgress then
                result_str, response_code = http.download(url, packagePath, {})
            else
                result_str, response_code = http.download(url, packagePath, {progress = displayProgress})
                -- Move down a line as progress repeatedly writes to same line
                print("")
            end
             
            if result_str == "OK" then
            else
                -- Delete what we have
                return error("Unable to fully download '".. url .. "'")
            end
        end    
        
        if not os.isfile(packagePath) then
            -- It exists, so do nothing
            return error("Destination path '" .. dstPath .. "' not found")
        end
       
        -- If the dependency path exists, delete it so we can extract into a new copy
       
        if os.isdir(dependencyPath) then
            os.rmdir(dependencyPath)
        end
       
        print("Extracting '" .. packagePath .. "' to '" .. dependencyPath .. "' (please be patient) ...")
       
        -- We can now unzip the package
        zip.extract(packagePath, dependencyPath)

        print("Extracted.")

        -- Lets make the 'package info' it in the dependency path
        local packageInfo = { name = packageFileName }
   
        io.writefile(path.join(dependencyPath, "package-info.json"), json.encode(packageInfo))
    end
end

function toBool(v)
    if type(v) == "boolean" then 
        return v
    end
    if  v == "True" or v == "true" then
        return true
    end
    if v == "False" or v == "false" then
        return false
    end
    -- Returns nil as an error
    return nil
end

function getBoolOption(name)
    local v = _OPTIONS[name]
    local b = toBool(v)
    if b == nil then
        return error("Option '" .. name .. "' is '" .. v .. "' - not a valid boolean value")
    end
    return b
end

--
-- Options
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
newoption {
   trigger     = "slang-path",
   description = "The path to the Slang, defaults to external/slang",
   value       = "string",
   default     = "external/slang"
}

newoption { 
    trigger     = "deps",
    description = "(Optional) If true downloads binaries defined in the deps/target-deps.json",
    value       = "bool",
    default     = "false",
    allowed     = { { "true", "True"}, { "false", "False" } }
}

newoption { 
    trigger     = "no-progress",
    description = "(Optional) If true doesn't display progress bars",
    value       = "boolean",
    default     = "false",
    allowed     = { { "true", "True"}, { "false", "False" } }
}

targetDetail = _OPTIONS["target-detail"]
llvmPath = _OPTIONS["llvm-path"]
slangPath = _OPTIONS["slang-path"]
deps = getBoolOption("deps")
noProgress = getBoolOption("no-progress")

if not llvmPath then
    if deps or os.isdir("external/llvm") then
        llvmPath = "external/llvm"
    else
        print("llvm-path option must be set, external/llvm isn't available")
        os.exit(-1)
    end
end

-- Init globals used for setting up projects
initGlobals(targetDetail)

targetName = "%{cfg.system}-%{cfg.platform:lower()}"

if not (getTargetDetail() == nil) then
    targetName = getTargetDetail() .. "-%{cfg.platform:lower()}"
end

-- This is needed for gcc, for the 'fileno' functions on cygwin
-- _GNU_SOURCE makes realpath available in gcc
if getTargetDetail() == "cygwin" then
    buildoptions { "-D_POSIX_SOURCE" }
    filter { "toolset:gcc*" }
        buildoptions { "-D_GNU_SOURCE" }
end

-- We need to disable warnings for building with LLVM
disableWarningsList = {}
if isTargetWindows() then
    disableWarningsList = { "4141", "4146", "4244", "4267", "4291", "4351", "4456", "4457", "4458", "4459", "4503", "4624", "4722", 
            "4100", "4127", "4512", "4505", "4610", "4510", "4702", "4245", "4706", "4310", "4701", "4703", "4389", 
            "4611", "4805", "4204", "4577", "4091", "4592", "4319", "4709", "4324",
            "4996" }
else
end

platformName = ""
if isTargetWindows() then
    platformName = "windows-x86_64"
else
    platformName = "linux-x86_64"
end

if deps then
    updateDeps(platformName, nil, noProgress)
end

-- Set up the llvm path

llvmBuildPath = llvmPath .. "/build"
if (isTargetWindows()) then
    llvmBuildPath = llvmPath .. "/build-x64"
end

if (not os.isdir(llvmPath) or not os.isdir(llvmBuildPath)) then
    print("Need --llvm-path set to the directory root of LLVM project.")
    os.exit(-1)
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

    -- C++14 
    cppdialect "C++14"
    
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
        buildoptions { "-Wno-unused-parameter", "-Wno-type-limits", "-Wno-sign-compare", "-Wno-unused-variable", "-Wno-reorder", "-Wno-switch", "-Wno-return-type", "-Wno-unused-local-typedefs", "-Wno-parentheses",  "-fvisibility=hidden" , "-Wno-ignored-optimization-argument", "-Wno-unknown-warning-option", "-Wno-class-memaccess", "-Wno-error", "-Wno-error=comment"} 
        
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
        buildoptions { "-fno-semantic-interposition", "-ffunction-sections", "-fdata-sections" }
        links { "pthread", "tinfo", "stdc++", "dl", "rt" }
        linkoptions{  "-Wl,-rpath,'$$ORIGIN',--no-as-needed"}
            

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
-- actual projects quite simply. 
--
example "clang-direct"
    kind "ConsoleApp"
    
    exceptionhandling("Off")
    rtti("Off")
    
    includedirs {
        -- So we can access slang.h
        slangPath, 
        -- For core/compiler-core
        path.join(slangPath, "source"), 
        -- LLVM/Clang headers
        path.join(llvmBuildPath, "tools/clang/include"), 
        path.join(llvmBuildPath, "include"), 
        path.join(llvmPath, "clang/include"), 
        path.join(llvmPath, "llvm/include")
    }
    
    filter { "toolset:msc-*" }
        -- Disable warnings that are a problem on LLVM/Clang on windows
        disablewarnings(disableWarningsList)

        -- LLVM/Clang need this system library
        links { "version" }
    
    filter { "configurations:debug" }    
        local libPath = getLLVMLibraryPath(llvmBuildPath, "Debug")
        libdirs { libPath }
        -- We need to vary this depending on type
        links(findLibraries(libPath, "clang*", isClangLibraryName))
        links(findLibraries(libPath, "LLVM*", isLLVMLibraryName))
        
    filter { "configurations:release" }    
        -- Can use RelWithDebInfo if lib is available to have symbols in Release
        local libPath = getLLVMLibraryPath(llvmBuildPath, "Release")
        libdirs { libPath }
        -- We need to vary this depending on type
        links(findLibraries(libPath, "clang*", isClangLibraryName))
        links(findLibraries(libPath, "LLVM*", isLLVMLibraryName))
    
    links { "core", "compiler-core" }

example "link-check"
    kind "ConsoleApp"
    
    exceptionhandling("Off")
    rtti("Off")
    pic "On"

    -- We need to vary this depending on type
    local libPath = getLLVMLibraryPath(llvmBuildPath, "Release")
    libdirs { libPath }
    links { "LLVMSupport" } --, "tinfo"} -- "rt", 

    -- buildoptions { "-fno-semantic-interposition", "-ffunction-sections", "-fdata-sections" }

    includedirs {
        -- So we can access slang.h
        slangPath, 
        -- For core/compiler-core
        path.join(slangPath, "source"), 
        -- LLVM/Clang headers
        path.join(llvmBuildPath, "tools/clang/include"), 
        path.join(llvmBuildPath, "include"), 
        path.join(llvmPath, "clang/include"), 
        path.join(llvmPath, "llvm/include")
    }
    
    filter { "toolset:msc-*" }
        -- Disable warnings that are a problem on LLVM/Clang on windows
        disablewarnings(disableWarningsList)

        -- LLVM/Clang need this system library
        links { "version" }

-- Most of the other projects have more interesting configuration going
-- on, so let's walk through them in order of increasing complexity.
--
-- The `core` project is a static library that has all the basic types
-- and routines that get shared across both the Slang compiler/runtime
-- and the various tool projects. It's build is pretty simple:
--

standardProject("core", path.join(slangPath, "source/core"))
    uuid "F9BE7957-8399-899E-0C49-E714FDDD4B65"
    kind "StaticLib"
    -- We need the core library to be relocatable to be able to link with slang.so
    pic "On"

    removefiles 
    { 
        path.join(slangPath, "source/core/slang-lz4-compression-system.cpp"),    
        path.join(slangPath, "source/core/slang-zip-file-system.cpp"),
        path.join(slangPath, "source/core/slang-deflate-compression-system.cpp"),
    }

    -- For our core implementation, we want to use the most
    -- aggressive warning level supported by the target, and
    -- to treat every warning as an error to make sure we
    -- keep our code free of warnings.
    --
    warnings "Extra"
    flags { "FatalWarnings" }
    
    if isTargetWindows() then
        addSourceDir(path.join(slangPath, "source/core/windows"))
    else
        addSourceDir(path.join(slangPath, "source/core/unix"))
    end
    
standardProject("compiler-core", path.join(slangPath, "source/compiler-core"))
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
    
    if isTargetWindows() then
        addSourceDir(path.join(slangPath, "source/compiler-core/windows"))
    else
        addSourceDir(path.join(slangPath, "source/compiler-core/unix"))
    end

standardProject("slang-llvm", "source/slang-llvm")
    uuid "F74A3AF1-5F0B-4EDF-AD43-04DABE9CDC75"
    kind "SharedLib"
    warnings "Extra"
    flags { "FatalWarnings" }
    pic "On"

    links { "core", "compiler-core" }
    
    includedirs 
    {
        -- So we can access slang.h
        slangPath, 
        -- For core/compiler-core
        path.join(slangPath, "source"), 
        -- LLVM/Clang headers
        path.join(llvmBuildPath, "tools/clang/include"), 
        path.join(llvmBuildPath, "include"), 
        path.join(llvmPath, "clang/include"), 
        path.join(llvmPath, "llvm/include")
    }
    
    filter { "toolset:msc-*" }
        -- Disable warnings that are a problem on LLVM/Clang on windows
        disablewarnings(disableWarningsList) 
        -- LLVM/Clang need this system library
        links { "version" } 
        
    filter { "configurations:debug" }    
        local libPath = getLLVMLibraryPath(llvmBuildPath, "Debug")
        libdirs { libPath }
        -- We need to vary this depending on type
        links(findLibraries(libPath, "clang*", isClangLibraryName))
        links(findLibraries(libPath, "LLVM*", isLLVMLibraryName))
        
    filter { "configurations:release" }    
        local libPath = getLLVMLibraryPath(llvmBuildPath, "Release")
        libdirs { libPath }
        -- We need to vary this depending on type
        links(findLibraries(libPath, "clang*", isClangLibraryName))
        links(findLibraries(libPath, "LLVM*", isLLVMLibraryName)) 

