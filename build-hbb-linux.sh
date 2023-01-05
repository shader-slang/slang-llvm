# This script is designed to build 
# https://github.com/phusion/holy-build-box

# We want to build with shared libraries/-fPIC
source /hbb_shlib/activate

OS=linux
PLATFORM=$1
CONFIGURATION=$2

# We use centos binary for premake, because it allows setting of crt bundles. 
# Without that HBB is not able to grab the dependencies via https

CURL_CA_BUNDLE=external/slang-binaries/certificate/linux/ca-bundle.crt
export CURL_CA_BUNDLE

PREMAKE=external/slang-binaries/premake/premake-5.0.0-alpha16/bin/centos-7-x64/premake5
chmod u+x ${PREMAKE}
${PREMAKE} gmake --deps=true --no-progress=true

make config=${CONFIGURATION}_${PLATFORM} -j`nproc`
