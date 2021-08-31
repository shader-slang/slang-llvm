Slang LLVM/Clang Library
========================

NOTE! The [Slang LLVM/Clang library](https://github.com/shader-slang/slang-llvm) project is currently *not functional*! 

The purpose of this project is to use the LLVM/Clang infrastructure to provide features for the [Slang language compiler](https://github.com/shader-slang/slang/). 

These features may include

* Use as a replacement for a file based downstream C++ compiler for CPU targets
* Allow the 'host-callable' to generate in memory executable code directly
* Allow parsing of C/C++ code 
* Compile Slang code to bitcode 
* JIT execution of bitcode

Building
========

Once this repo has been cloned, it is neccessary to get the dependencies needed via

```
% git submodule update --init
```

NOTE! Currently LLVM is *NOT* a submodule, and has to be built locally from source code from the [LLVM project](https://github.com/llvm/). The process of building LLVM is described in a later section.

Limitiations
============

* At the moment only contains a sample 'clang-direct' that compiles from some source to object
* Only works on Visual Studio

Building LLVM/Clang
===================

The follow the instructions for building on from source on windows. In additional to that the following need to be set

The root of the project for CMAKE is actually the llvm directory in the `root` directory. Set the directory for the binaries to be `build.vs` in the `root` directory for windows. Currently the premake file assumes this name for the binaries/libs/built includes.

We want a 64 bit environment it may be necessary to specify on command line

```
-Thost=x64
```

We want to try and force the use of the x64 linker (as the x86 linker fails)

```
LLVM_ENABLE_PROJECTS            clang
```

Ideally we'd have LLVM/Clang not use a dll CRT, but for the moment this doesn't work. An attempt to make it work by enabling

```
LLVM_USE_CRT_DEBUG              MTd
LLVM_USE_CRT_MINSIZEREL         MT
LLVM_USE_CRT_RELEASE            MT
LLVM_USE_CRT_RELWITHDEBINFO     MTd
```

These might be of importance

```
LLVM_STATIC_LINK_CXX_STDLIB
LIBCLANG_BUILD_STATIC
```

Led to issues with multiply defined CRT symbols when building, so for now we use with dll CRT.
