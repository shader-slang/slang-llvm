OS=linux
PLATFORM=$1
CONFIGURATION=$2

PREMAKE=external/slang-binaries/premake/premake-5.0.0-alpha16/bin/linux-64/premake5
chmod u+x ${PREMAKE}
${PREMAKE} gmake --deps=true --no-progress=true

make config=${CONFIGURATION}_${PLATFORM} -j`nproc`
