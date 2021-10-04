#include <stdio.h>
#include <stdlib.h>

#include <llvm/ADT/StringRef.h>

int main(int argc, const char** argv)
{
    llvm::StringRef s("Hello!");

    const char* chars = s.begin();  
    int comp = s.compare_numeric(s);

    printf("%s %i\n", chars, comp); 

    return 0;   
}  