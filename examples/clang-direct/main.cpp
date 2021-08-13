// main.cpp

#include <slang.h>
#include <core/slang-string.h>

#include <stdio.h>

int main(int argc, char** argv)
{
    SlangResult res = SLANG_OK;

    Slang::String string("Hello World!");

    printf("%s\n", string.getBuffer());

    return SLANG_SUCCEEDED(res) ? 0 : -1;
}
