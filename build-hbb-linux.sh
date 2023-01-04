OS=linux
PLATFORM=$1
CONFIGURATION=$2

CURL_CA_BUNDLE=external/slang-binaries/certificate/linux/ca-bundle.crt
export CURL_CA_BUNDLE

PREMAKE=external/slang-binaries/premake/premake-5.0.0-alpha16/bin/centos-7-x64/premake5
chmod u+x ${PREMAKE}
${PREMAKE} gmake --deps=true --no-progress=true

make config=${CONFIGURATION}_${PLATFORM} -j`nproc`
