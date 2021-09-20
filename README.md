Slang LLVM/Clang Library
========================

NOTE! The [Slang LLVM/Clang library](https://github.com/shader-slang/slang-llvm) project is currently entirely *not functional*! 

The purpose of this project is to use the [LLVM/Clang infrastructure](https://github.com/shader-slang/llvm-project/) to provide features for the [Slang language compiler](https://github.com/shader-slang/slang/). 

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

NOTE! Currently LLVM is *NOT* a submodule. It can be built locally, but it's probably easier to just use the binaries from releasese of [Slang's LLVM repo]( https://github.com/shader-slang/llvm-project/).

## Premake

Slang-llvm uses the tool [`premake5`](https://premake.github.io/) in order to generate projects that can be built on different targets. On Linux premake will generate Makefile/s and on windows it will generate a Visual Studio solution. Information on invoking premake for different kinds of targets can be found [here](https://github.com/premake/premake-core/wiki/Using-Premake).

It is currently necessary to specify the the llvm project path. This can be achieved with

```
premake vs2019 --llvm-path=path_to_llvm
```

The project currently builds two things

* slang-llvm project which builds a slang-llvm shared library, which can be used for 'host callable' compilations for CPU
* clang-direct is an example project which shows how to compile C code into something that can run on LLVM JIT.

Limitiations
============
 
* Only works on Visual Studio

Building LLVM/Clang
===================

The [Slang LLVM repo]( https://github.com/shader-slang/llvm-project/) contains github actions to build LLVM into suitable libraries for linux and windows. The most up to date information will therefore be in the `.github\workflows` directory. These builds currently do not contain LLVM library that can target all binary targets, but just x64/x86/ARM. They also only contain the headers and static c runtime libraries.  

Due to the size of builds which contain debug information, it is not possible to build LLVM debug releases via github actions. 
