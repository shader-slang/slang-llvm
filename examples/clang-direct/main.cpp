
#include "clang/Basic/Stack.h"
#include "clang/Basic/TargetOptions.h"
#include "clang/CodeGen/ObjectFilePCHContainerOperations.h"
#include "clang/Config/config.h"
#include "clang/Driver/DriverDiagnostic.h"
#include "clang/Driver/Options.h"
#include "clang/Frontend/CompilerInstance.h"
#include "clang/Frontend/CompilerInvocation.h"
#include "clang/Frontend/FrontendDiagnostic.h"
#include "clang/Frontend/TextDiagnosticBuffer.h"
#include "clang/Frontend/TextDiagnosticPrinter.h"
#include "clang/Frontend/Utils.h"
#include "clang/FrontendTool/Utils.h"

#include "clang/Frontend/FrontendAction.h"
#include "clang/CodeGen/CodeGenAction.h"
#include "clang/Basic/Version.h"

#include "llvm/ADT/Statistic.h"
#include "llvm/Config/llvm-config.h"
#include "llvm/LinkAllPasses.h"
#include "llvm/Option/Arg.h"
#include "llvm/Option/ArgList.h"
#include "llvm/Option/OptTable.h"
#include "llvm/Support/BuryPointer.h"
#include "llvm/Support/Compiler.h"
#include "llvm/Support/ErrorHandling.h"
#include "llvm/Support/ManagedStatic.h"
#include "llvm/Support/Path.h"
#include "llvm/Support/Process.h"
#include "llvm/Support/Signals.h"
#include "llvm/Support/TargetRegistry.h"
#include "llvm/Support/TargetSelect.h"
#include "llvm/Support/TimeProfiler.h"
#include "llvm/Support/Timer.h"

#include "llvm/Support/raw_ostream.h"

#include "llvm/Target/TargetMachine.h"

// Jit
#include "llvm/ExecutionEngine/JITEventListener.h"
#include "llvm/ExecutionEngine/JITLink/JITLinkMemoryManager.h"

#include "llvm/ExecutionEngine/Orc/ExecutionUtils.h"
#include "llvm/ExecutionEngine/Orc/LLJIT.h"

#include "llvm/ExecutionEngine/Orc/ThreadSafeModule.h"

#include "llvm/ExecutionEngine/JITSymbol.h"

#include "llvm/IR/LLVMContext.h"
#include "llvm/IRReader/IRReader.h"

// Slang

#include <slang.h>
#include <slang-com-helper.h>
#include <slang-com-ptr.h>

#include <core/slang-list.h>
#include <core/slang-string.h>


// Slang core

#include <core/slang-string.h>

#include <stdio.h>

// We want to make math functions available to the JIT
#if SLANG_GCC_FAMILY && __GNUC__ < 6
#   include <cmath>
#   define SLANG_PRELUDE_STD std::
#else
#   include <math.h>
#   define SLANG_PRELUDE_STD
#endif

namespace slang_clang {

using namespace clang;

using namespace llvm::opt;
using namespace llvm;
using namespace llvm::orc;

static void _ensureSufficientStack() {}

static void _llvmErrorHandler(void* userData, const std::string& message, bool genCrashDiag)
{
    DiagnosticsEngine& diags = *static_cast<DiagnosticsEngine*>(userData);
    diags.Report(diag::err_fe_error_backend) << message;

    // Run the interrupt handlers to make sure any special cleanups get done, in
    // particular that we remove files registered with RemoveFileOnSignal.
    llvm::sys::RunInterruptHandlers();

    // We cannot recover from llvm errors.  (!)
    // 
    // Returning nothing, will still cause LLVM to exit the process.
}

class BufferedDiagnosticConsumer : public clang::DiagnosticConsumer
{
public:
    struct Entry
    {
        DiagnosticsEngine::Level level;
        SourceLocation location;
        Slang::String text;
    };

    void HandleDiagnostic(DiagnosticsEngine::Level level, const Diagnostic& info) override
    {
        Entry entry;

        SmallString<100> text;
        info.FormatDiagnostic(text);

        entry.level = level;
        entry.location = info.getLocation();
        entry.text = text.c_str();

        // Work out what the location is
        auto& sourceManager = info.getSourceManager();

        // Gets the file/line number 
        const bool useLineDirectives = true;
        const PresumedLoc presumedLoc = sourceManager.getPresumedLoc(entry.location, useLineDirectives);

        m_entries.add(entry);
    }

    bool hasError() const
    {
        for (const auto& entry : m_entries)
        {
            if (entry.level == DiagnosticsEngine::Level::Fatal ||
                entry.level == DiagnosticsEngine::Level::Error)
            {
                return true;
            }
        }

        return false;
    }

    Slang::List<Entry> m_entries;
};

/*
* If I define all the functions in such a way that I can test here, then that might be handy. Actually doing that
* means I don't have to put anything inside of the prelude, because I could just generate code to add the prototypes.
*/



/*
* So a question is how to make the prototypes available for these functions. They would need to be defined before the
* the prelude - or potentially in the prelude.
*
* That I could have a define that handled this in the prelude - such as SLANG_LLVM_JIT (say), and in doing so remove
* the whole definition issue.
*
* Note that inside this file - we do need to have the special handling to be able to access said functions. 
*/

struct NameAndFunc
{
    typedef void (*Func)();

    const char* name;
    Func func;
};

#define SLANG_LLVM_EXPAND(x) x

#define SLANG_LLVM_FUNC(name, cppName, retType, paramTypes) NameAndFunc{ #name, (NameAndFunc::Func)static_cast<retType (*) paramTypes>(&SLANG_LLVM_EXPAND(cppName)) },

// Implementations of maths functions available to JIT
static float F32_frexp(float x, float* e)
{
    int ei;
    float m = ::frexpf(x, &ei);
    *e = float(ei);
    return m;
}

static double F64_frexp(double x, double* e)
{
    int ei;
    double m = ::frexp(x, &ei);
    *e = float(ei);
    return m;
}

// These are only the functions that cannot be implemented with 'reasonable performance' in the prelude.
// It is assumed that calling from JIT to C function whilst not super expensive, is an issue. 

// name, cppName, retType, paramTypes
#define SLANG_LLVM_FUNCS(x) \
    x(F64_ceil, ceil, double, (double)) \
    x(F64_floor, floor, double, (double)) \
    x(F64_round, round, double, (double)) \
    x(F64_sin, sin, double, (double)) \
    x(F64_cos, cos, double, (double)) \
    x(F64_tan, tan, double, (double)) \
    x(F64_asin, asin, double, (double)) \
    x(F64_acos, acos, double, (double)) \
    x(F64_atan, atan, double, (double)) \
    x(F64_sinh, sinh, double, (double)) \
    x(F64_cosh, cosh, double, (double)) \
    x(F64_tanh, tanh, double, (double)) \
    x(F64_log2, log2, double, (double)) \
    x(F64_log, log, double, (double)) \
    x(F64_log10, log10, double, (double)) \
    x(F64_exp2, exp2, double, (double)) \
    x(F64_exp, exp, double, (double)) \
    x(F64_fabs, fabs, double, (double)) \
    x(F64_trunc, trunc, double, (double)) \
    x(F64_sqrt, sqrt, double, (double)) \
    \
    x(F64_isnan, SLANG_PRELUDE_STD isnan, bool, (double)) \
    x(F64_isfinite, SLANG_PRELUDE_STD isfinite, bool, (double)) \
    x(F64_isinf, SLANG_PRELUDE_STD isinf, bool, (double)) \
    \
    x(F64_atan2, atan2, double, (double, double)) \
    \
    x(F64_frexp, F64_frexp, double, (double, double*)) \
    x(F64_pow, pow, double, (double, double)) \
    \
    x(F64_modf, modf, double, (double, double*)) \
    x(F64_fmod, fmod, double, (double, double)) \
    x(F64_remainder, remainder, double, (double, double)) \
    \
    x(F32_ceil, ceilf, float, (float)) \
    x(F32_floor, floorf, float, (float)) \
    x(F32_round, roundf, float, (float)) \
    x(F32_sin, sinf, float, (float)) \
    x(F32_cos, cosf, float, (float)) \
    x(F32_tan, tanf, float, (float)) \
    x(F32_asin, asinf, float, (float)) \
    x(F32_acos, acosf, float, (float)) \
    x(F32_atan, atanf, float, (float)) \
    x(F32_sinh, sinhf, float, (float)) \
    x(F32_cosh, coshf, float, (float)) \
    x(F32_tanh, tanhf, float, (float)) \
    x(F32_log2, log2f, float, (float)) \
    x(F32_log, logf, float, (float)) \
    x(F32_log10, log10f, float, (float)) \
    x(F32_exp2, exp2f, float, (float)) \
    x(F32_exp, expf, float, (float)) \
    x(F32_fabs, fabsf, float, (float)) \
    x(F32_trunc, truncf, float, (float)) \
    x(F32_sqrt, sqrtf, float, (float)) \
    \
    x(F32_isnan, SLANG_PRELUDE_STD isnan, bool, (float)) \
    x(F32_isfinite, SLANG_PRELUDE_STD isfinite, bool, (float)) \
    x(F32_isinf, SLANG_PRELUDE_STD isinf, bool, (float)) \
    \
    x(F32_atan2, atan2f, float, (float, float)) \
    \
    x(F32_frexp, F32_frexp, float, (float, float*)) \
    x(F32_pow, powf, float, (float, float)) \
    \
    x(F32_modf, modff, float, (float, float*)) \
    x(F32_fmod, fmodf, float, (float, float)) \
    x(F32_remainder, remainderf, float, (float, float)) 

static void _appendBuiltinPrototypes(Slang::StringBuilder& out)
{
    // Make all function names unmangled that are implemented externally.
    out << "extern \"C\" { \n";

#define SLANG_LLVM_APPEND_PROTOTYPE(name, cppName, retType, paramTypes)     out << #retType << " " << #name << #paramTypes << ";\n";
    SLANG_LLVM_FUNCS(SLANG_LLVM_APPEND_PROTOTYPE)

    out << "}\n\n";
}

static const char cppSource[] =
    "extern \"C\" double doSin(double f) { return F64_sin(f); }\n"
    "extern \"C\" int add(int a, int b) { return a + b; } int main() { return 0; }";

static SlangResult _compile()
{
    _ensureSufficientStack();

    std::unique_ptr<CompilerInstance> clang(new CompilerInstance());
    IntrusiveRefCntPtr<DiagnosticIDs> diagID(new DiagnosticIDs());

    // Register the support for object-file-wrapped Clang modules.
    auto pchOps = clang->getPCHContainerOperations();
    pchOps->registerWriter(std::make_unique<ObjectFilePCHContainerWriter>());
    pchOps->registerReader(std::make_unique<ObjectFilePCHContainerReader>());

    // Initialize targets first, so that --version shows registered targets.
#if 0
    llvm::InitializeAllTargets();
    llvm::InitializeAllTargetMCs();
    llvm::InitializeAllAsmPrinters();
    llvm::InitializeAllAsmParsers();
#else
    // Just initialize items needed for this target.

    llvm::InitializeNativeTarget();
    llvm::InitializeNativeTargetAsmPrinter();
    llvm::InitializeNativeTargetAsmParser();

    llvm::InitializeNativeTargetDisassembler();
#endif

    IntrusiveRefCntPtr<DiagnosticOptions> diagOpts = new DiagnosticOptions();

    // TODO(JS): We might just want this to talk directly to the listener.
    // For now we just buffer up. 
    BufferedDiagnosticConsumer diagsBuffer;

    IntrusiveRefCntPtr<DiagnosticsEngine> diags = new DiagnosticsEngine(diagID, diagOpts, &diagsBuffer, false);

    Slang::StringBuilder source;
    _appendBuiltinPrototypes(source);
    source << "\n\n";
    source << cppSource;

    StringRef sourceStringRef(source.getBuffer(), source.getLength());

    auto sourceBuffer = llvm::MemoryBuffer::getMemBuffer(sourceStringRef);

    auto& invocation = clang->getInvocation();

    std::string verboseOutputString;

    // Capture all of the verbose output into a buffer, so not writen to stdout
    clang->setVerboseOutputStream(std::make_unique<llvm::raw_string_ostream>(verboseOutputString));
    
    SmallVector<char> output;
    clang->setOutputStream(std::make_unique<llvm::raw_svector_ostream>(output));
    
    frontend::ActionKind action = frontend::ActionKind::EmitLLVMOnly;

    // EmitCodeGenOnly doesn't appear to actually emit anything
    // EmitLLVM outputs LLVM assembly
    // EmitLLVMOnly doesn't 'emit' anything, but the IR that is produced is accessible, from the 'action'.

    action = frontend::ActionKind::EmitLLVMOnly;

    //action = frontend::ActionKind::EmitBC;
    //action = frontend::ActionKind::EmitLLVM;
    // 
    //action = frontend::ActionKind::EmitCodeGenOnly;
    //action = frontend::ActionKind::EmitObj;
    //action = frontend::ActionKind::EmitAssembly;

    {
        auto& opts = invocation.getFrontendOpts();

        // Add the source
        // TODO(JS): For the moment this kind of include does *NOT* show a input source filename
        // not super surprising as one isn't set, but it's not clear how one would be set when the input is a memory buffer.
        // For Slang usage, this probably isn't an issue, because it's *output* typically holds #line directives.
        {
            InputKind inputKind(Language::CXX, InputKind::Format::Source);
            FrontendInputFile inputFile(*sourceBuffer, inputKind);

            opts.Inputs.push_back(inputFile);
        }

        opts.ProgramAction = action;
    }

    {
        auto opts = invocation.getLangOpts();
        opts->Bool = 1;
        opts->CPlusPlus = 1;
        opts->LangStd = LangStandard::Kind::lang_cxx11;
    }

    {
        auto& opts = invocation.getHeaderSearchOpts();

        opts.UseBuiltinIncludes = true;
        opts.UseStandardSystemIncludes = true;
        opts.UseStandardCXXIncludes = true;

        /// Use libc++ instead of the default libstdc++.
        opts.UseLibcxx = true;
    }

    llvm::Triple targetTriple;
    {
        auto& opts = invocation.getTargetOpts();

        opts.Triple = LLVM_DEFAULT_TARGET_TRIPLE;

        // A code model isn't set by default, "default" seems to fit the bill here 
        opts.CodeModel = "default";

        targetTriple = llvm::Triple(opts.Triple);
    }

    {
        auto& opts = invocation.getCodeGenOpts();

        // Set to -O0 initially
        opts.OptimizationLevel = 0;

        // Copy over the targets CodeModel
        opts.CodeModel = invocation.getTargetOpts().CodeModel;
    }
 
    //const llvm::opt::OptTable& opts = clang::driver::getDriverOptTable();

    // TODO(JS): Need a way to find in system search paths, for now we just don't bother
    //
    // The system search paths are for includes for compiler intrinsics it seems. 
    // Infer the builtin include path if unspecified.
#if 0
    {
        auto& searchOpts = clang->getHeaderSearchOpts();
        if (searchOpts.UseBuiltinIncludes && searchOpts.ResourceDir.empty())
        {
            // TODO(JS): Hack - hard coded path such that we can test out the
            // resource directory functionality.

            StringRef binaryPath = "F:/dev/llvm-12.0/llvm-project-llvmorg-12.0.1/build.vs/Release/bin";

            // Dir is bin/ or lib/, depending on where BinaryPath is.

            // On Windows, libclang.dll is in bin/.
            // On non-Windows, libclang.so/.dylib is in lib/.
            // With a static-library build of libclang, LibClangPath will contain the
            // path of the embedding binary, which for LLVM binaries will be in bin/.
            // ../lib gets us to lib/ in both cases.
            SmallString<128> path = llvm::sys::path::parent_path(binaryPath);
            llvm::sys::path::append(path, Twine("lib") + CLANG_LIBDIR_SUFFIX, "clang", CLANG_VERSION_STRING);
        
            searchOpts.ResourceDir = path.c_str();
        }
    }
#endif

    // Create the actual diagnostics engine.
    clang->createDiagnostics();
    clang->setDiagnostics(diags.get());

    if (!clang->hasDiagnostics())
        return SLANG_FAIL;

    //
    clang->createFileManager();
    clang->createSourceManager(clang->getFileManager());

    // Set an error handler, so that any LLVM backend diagnostics go through our
    // error handler.
    llvm::install_fatal_error_handler(_llvmErrorHandler, static_cast<void*>(&clang->getDiagnostics()));

    std::unique_ptr<LLVMContext> llvmContext = std::make_unique<LLVMContext>();

    clang::CodeGenAction* codeGenAction = nullptr;
    std::unique_ptr<FrontendAction> act;

    {
        // If we are going to just emit IR, we need to have access to the underlying type
        if (action == frontend::ActionKind::EmitLLVMOnly)
        {
            EmitLLVMOnlyAction* llvmOnlyAction = new EmitLLVMOnlyAction(llvmContext.get());
            codeGenAction = llvmOnlyAction;
            // Make act the owning ptr
            act = std::unique_ptr<FrontendAction>(llvmOnlyAction);
        }
        else
        {
            act = CreateFrontendAction(*clang);
        }

        if (!act)
        {
            return SLANG_FAIL;
        }

        const bool compileSucceeded = clang->ExecuteAction(*act);

        if (!compileSucceeded || diagsBuffer.hasError())
        {
            return SLANG_FAIL;
        }
    }

    std::unique_ptr<llvm::Module> module;
       
    switch (action)
    {
        case frontend::ActionKind::EmitLLVM:
        {
            
            // LLVM output is text, that must be zero terminated
            output.push_back(char(0));

            StringRef identifier;
            StringRef data(output.begin(), output.size() - 1);

            MemoryBufferRef memoryBufferRef(data, identifier);

            SMDiagnostic err;
            module = llvm::parseIR(memoryBufferRef, err, *llvmContext);
            break;
        }
        case frontend::ActionKind::EmitBC:
        {
            StringRef identifier;
            StringRef data(output.begin(), output.size());

            MemoryBufferRef memoryBufferRef(data, identifier);

            SMDiagnostic err;
            module = llvm::parseIR(memoryBufferRef, err, *llvmContext);
            break;
        }
        case frontend::ActionKind::EmitLLVMOnly:
        {
            // Get the module produced by the action
            module = codeGenAction->takeModule();
            break;
        }
    }

    // Try running something in the module on the JIT
    {
        std::unique_ptr<llvm::orc::LLJIT> jit;
        {
            // Create the JIT

            LLJITBuilder jitBuilder;

            Expected<std::unique_ptr< llvm::orc::LLJIT>> expectJit = jitBuilder.create();
            if (!expectJit)
            {
                return SLANG_FAIL;
            }
            jit = std::move(*expectJit); 
        }

        // Used the following link to test this out
        // https://www.llvm.org/docs/ORCv2.html
        // https://www.llvm.org/docs/ORCv2.html#processandlibrarysymbols

        {
            auto& es = jit->getExecutionSession();

            const DataLayout& dl = jit->getDataLayout();
            MangleAndInterner mangler(es, dl);

            // The name of the lib must be unique. Should be here as we are only thing adding libs
            auto& stdcLibExpected = es.createJITDylib("stdc");

            if (stdcLibExpected)
            {
                auto& stdcLib = *stdcLibExpected;

                // Add all the symbolmap
                SymbolMap symbolMap;

                //symbolMap.insert(std::make_pair(mangler("sin"), JITEvaluatedSymbol::fromPointer(static_cast<double (*)(double)>(&sin))));

                const NameAndFunc funcs[] =
                {
                    SLANG_LLVM_FUNCS(SLANG_LLVM_FUNC)
                };

                for (auto& func : funcs)
                {
                    symbolMap.insert(std::make_pair(mangler(func.name), JITEvaluatedSymbol::fromPointer(func.func)));
                }

                stdcLib.define(absoluteSymbols(symbolMap));

                // Required or the symbols won't be found
                jit->getMainJITDylib().addToLinkOrder(stdcLib);
            }
        }

        ThreadSafeModule threadSafeModule(std::move(module), std::move(llvmContext));

        jit->addIRModule(std::move(threadSafeModule));

        // Look up the JIT'd function, cast it to a function pointer, then call it.

        auto addExpected = jit->lookup("add");
        if (addExpected)
        {
            auto add = std::move(*addExpected);
            typedef int (*Func)(int, int);

            Func func = (Func)add.getAddress();
            int result = func(1, 3);

            SLANG_ASSERT(result == 4);
        }

        auto doSinExpected = jit->lookup("doSin");
        if (doSinExpected)
        {
            auto doSin = std::move(*doSinExpected);
            typedef double (*Func)(double);
            Func func = (Func)doSin.getAddress();

            double result = func(0.5);

            SLANG_ASSERT(result == ::sin(0.5));
        }
    }

    return SLANG_OK;
}

} // namespace slang_clang

int main(const char* const* argv, int argc)
{
    auto res = slang_clang::_compile();

    return SLANG_SUCCEEDED(res) ? 0 : 1;
}
