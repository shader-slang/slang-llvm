
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

#include "clang/Frontend/FrontendAction.h"

#include "llvm/Support/raw_ostream.h"

#include "llvm/Target/TargetMachine.h"

// Jit
#include "llvm/ExecutionEngine/JITEventListener.h"
#include "llvm/ExecutionEngine/JITLink/JITLinkMemoryManager.h"

#include "llvm/ExecutionEngine/Orc/ExecutionUtils.h"
#include "llvm/ExecutionEngine/Orc/LLJIT.h"

#include "llvm/ExecutionEngine/Orc/ThreadSafeModule.h"

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

static const char cppSource[] =
    //"#include <math.h>\n"
    "int add(int a, int b) { return a + b; } int main() { return 0; }";

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

    auto sourceBuffer = llvm::MemoryBuffer::getMemBuffer(cppSource);

    auto& invocation = clang->getInvocation();

    std::string verboseOutputString;

    // Capture all of the verbose output into a buffer, so not writen to stdout
    {
        clang->setVerboseOutputStream(std::make_unique<llvm::raw_string_ostream>(verboseOutputString));
    }

    SmallVector<char> output;
    {
        clang->setOutputStream(std::make_unique<llvm::raw_svector_ostream>(output));
    }

    frontend::ActionKind action;

    // EmitCodeGenOnly doesn't appear to actually emit anything
    // EmitLLVM outputs LLVM assembly

    action = frontend::ActionKind::EmitBC;

    //action = frontend::ActionKind::EmitLLVM;
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
    // Infer the builtin include path if unspecified.
    {
        auto& searchOpts = clang->getHeaderSearchOpts();
        if (searchOpts.UseBuiltinIncludes && searchOpts.ResourceDir.empty())
        {
            // searchOpts.ResourceDir = CompilerInvocation::GetResourcesPath(Argv0, MainAddr);
        }
    }

    // Create the actual diagnostics engine.
    clang->createDiagnostics();
    clang->setDiagnostics(diags.get());

    if (!clang->hasDiagnostics())
        return SLANG_FAIL;

    // Set an error handler, so that any LLVM backend diagnostics go through our
    // error handler.
    llvm::install_fatal_error_handler(_llvmErrorHandler, static_cast<void*>(&clang->getDiagnostics()));

    // Looks like output files can be added via
    // CompilerInstance::createOutputFileImpl/createOutputFile
    // NOTE! That this writes files by just writing directly to the file system (ie it *doesn't* appear to use the virutal file system)
    //
    {
        // Create and execute the frontend action.
        std::unique_ptr<FrontendAction> act(CreateFrontendAction(*clang));
        if (!act)
            return false;
        const bool compileSucceeded = clang->ExecuteAction(*act);

        if (!compileSucceeded || diagsBuffer.hasError())
        {
            return SLANG_FAIL;
        }
    }

    // The compiled module is not in the module cache
#if 0
    {
        InMemoryModuleCache& moduleCache = clang->getModuleCache();
        SLANG_UNUSED(moduleCache);
    }
#endif

#if 0
    {
        // Note that the FileManager can hold a virtual FileSystem.
        // The FileManager is used for identifying unique files - for example if a file is specified by two paths, but is the 
        // same (say by a symlink).

        FileManager& fileManager = clang->getFileManager();

        SLANG_UNUSED(fileManager);
        //const ArgStringMap& getResultFiles() const { return ResultFiles; }
    }
#endif

    // If we emit LLVM it actually output LLVM assembly.
    {
        auto llvmContext = std::make_unique<LLVMContext>();

        StringRef data;
        StringRef identifier;

        if (action == frontend::ActionKind::EmitLLVM)
        {
            // Add zero termination.
            // LLVM output is text.
            output.push_back(char(0));
            data = StringRef(output.begin(), output.size() - 1);
        }
        else
        {
            data = StringRef(output.begin(), output.size());
        }

        MemoryBufferRef memoryBufferRef(data, identifier);
        
        //output.

        SMDiagnostic err;
        std::unique_ptr<llvm::Module> module = llvm::parseIR(memoryBufferRef, err, *llvmContext);

        std::unique_ptr<llvm::orc::LLJIT> jit;
        {
            // Create the JIT
            Expected<std::unique_ptr< llvm::orc::LLJIT>> expectJit = LLJITBuilder().create();
            if (!expectJit)
            {
                return SLANG_FAIL;
            }
            jit = std::move(*expectJit); 
        }

        ThreadSafeModule threadSafeModule(std::move(module), std::move(llvmContext));

        jit->addIRModule(std::move(threadSafeModule));

        // Look up the JIT'd function, cast it to a function pointer, then call it.

        auto addSymExpected = jit->lookup("add");
        if (addSymExpected)
        {
            auto addSym = std::move(*addSymExpected);

            typedef int (*AddFunc)(int, int);

            AddFunc func = (AddFunc)addSym.getAddress();

            int result = func(1, 3);

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
