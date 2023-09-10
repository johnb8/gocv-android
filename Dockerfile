ARG DEBIAN_RELEASE=bookworm

FROM debian:${DEBIAN_RELEASE}

ARG DEBIAN_RELEASE
ENV DEBIAN_RELEASE=${DEBIAN_RELEASE}

ARG LLVM_VERSION=16
ENV LLVM_VERSION=${LLVM_VERSION}

ARG OPENCV_VERSION=4.8.0
ENV OPENCV_VERSION=${OPENCV_VERSION}

ARG CROSS_TRIPLE
ENV CROSS_TRIPLE ${CROSS_TRIPLE}
RUN test -n "${CROSS_TRIPLE}"

# Have to duplicate CROSS_TRIPLE because there's no way to uppercase & ENV in docker
ARG CROSS_TRIPLE_UPPER
ENV CROSS_TRIPLE_UPPER ${CROSS_TRIPLE_UPPER}
RUN test -n "${CROSS_TRIPLE_UPPER}"

# Have to duplicate CROSS_TRIPLE because of #161 (shell dashes in env)
ARG CROSS_TRIPLE_UNDERSCORED
ENV CROSS_TRIPLE_UNDERSCORED ${CROSS_TRIPLE_UNDERSCORED}
RUN test -n "${CROSS_TRIPLE_UNDERSCORED}"

# Debian libxxx:${PACKAGE_ARCH} package arch that matches the cross triple
ARG PACKAGE_ARCH
ENV PACKAGE_ARCH ${PACKAGE_ARCH}
RUN test -n "${PACKAGE_ARCH}"

# Debian /usr/lib/${CROSS_TRIPLE} paths
ARG DEBIAN_CROSS_TRIPLE
ENV DEBIAN_CROSS_TRIPLE ${DEBIAN_CROSS_TRIPLE}
RUN test -n "${DEBIAN_CROSS_TRIPLE}"

ENV ANDROID_HOME=/opt/android-sdk

ARG ANDROID_SDK_TOOLS_VERSION
ENV ANDROID_SDK_TOOLS_VERSION=${ANDROID_SDK_TOOLS_VERSION}

ARG ANDROID_SDK_BUILD_TOOLS_VERSION
ENV ANDROID_SDK_BUILD_TOOLS_VERSION=${ANDROID_SDK_BUILD_TOOLS_VERSION}

ARG ANDROID_NATIVE_API_LEVEL
ENV ANDROID_NATIVE_API_LEVEL=${ANDROID_NATIVE_API_LEVEL}

# See https://developer.android.com/ndk/guides/cmake#android_abi
ARG ANDROID_ABI
ENV ANDROID_ABI ${ANDROID_ABI}

ENV BUILD_USER builder

WORKDIR /work

# Enable multi-arch debian system libraries
RUN dpkg --add-architecture ${PACKAGE_ARCH}

# Required packages for container build
RUN apt-get update && apt-get install -y \
    sudo \
    wget curl git gnupg unzip \
    cmake make pkg-config dpkg-dev \
    gcc-multilib g++-multilib

# Setup our user, with sudo permissions
RUN adduser --disabled-password --gecos '' $BUILD_USER
RUN adduser $BUILD_USER sudo
RUN echo "%sudo ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers
RUN sudo chown $BUILD_USER -R /work
USER $BUILD_USER

ENV PKG_CONFIG_ALLOW_CROSS 1
ENV PKG_CONFIG_PATH_${CROSS_TRIPLE_UNDERSCORED} /usr/lib/${DEBIAN_CROSS_TRIPLE}/pkgconfig

# go install
RUN wget -q -O ~/go.tar.gz https://go.dev/dl/go1.21.0.linux-amd64.tar.gz
RUN sudo tar -C /usr/local -xzf ~/go.tar.gz
ENV PATH=$PATH:/usr/local/go/bin
RUN go version

# LLVM toolchain for building C++
RUN wget -q -O - https://apt.llvm.org/llvm-snapshot.gpg.key | sudo apt-key add -
RUN echo "deb http://apt.llvm.org/bookworm/ llvm-toolchain-bookworm-${LLVM_VERSION} main" | sudo tee -a /etc/apt/sources.list
RUN echo "deb-src http://apt.llvm.org/bookworm/ llvm-toolchain-bookworm-${LLVM_VERSION} main" | sudo tee -a /etc/apt/sources.list
RUN sudo apt-get update && sudo apt-get install -y \
    llvm-${LLVM_VERSION} clang-${LLVM_VERSION} lld-${LLVM_VERSION} \
    llvm-${LLVM_VERSION}-dev libclang-${LLVM_VERSION}-dev
RUN sudo ln -sf /usr/bin/ld.lld-${LLVM_VERSION} /usr/bin/ld
ENV CC=/usr/bin/clang-${LLVM_VERSION} \
    CPP=/usr/bin/clang++-${LLVM_VERSION} \
    CXX=/usr/bin/clang++-${LLVM_VERSION} \
    LLVM_CONFIG=/usr/bin/llvm-config-${LLVM_VERSION} \
    LLVM_CONFIG_PATH=/usr/bin/llvm-config-${LLVM_VERSION}

# C++ stdlib - use the gnu version
RUN sudo apt-get update && sudo apt-get install -y libstdc++-11-dev:${PACKAGE_ARCH}

# The LLVM toolchain will still depend on libgcc_s
RUN sudo apt-get update && sudo apt-get install -y libgcc-11-dev:${PACKAGE_ARCH}

# CMake toolchain that sets up our LLVM & enables cross-compiling
COPY ./build/Toolchain.cmake /usr/local/lib/cmake/${CROSS_TRIPLE}/Toolchain.cmake
ENV CMAKE_TOOLCHAIN_FILE /usr/local/lib/cmake/${CROSS_TRIPLE}/Toolchain.cmake

# If we're building for android, install the NDK
ADD ./build/install-android-ndk.sh install-android-ndk.sh
RUN ./install-android-ndk.sh && rm -rf install-android-ndk.sh
ENV ANDROID_TOOLCHAIN_FILE ${ANDROID_HOME}/ndk/25.2.9519653/build/cmake/android.toolchain.cmake

# OpenCV
RUN sudo apt-get update && sudo apt-get install -y \
    libavformat-dev:${PACKAGE_ARCH} libavcodec-dev:${PACKAGE_ARCH} libswscale-dev:${PACKAGE_ARCH} \
    libjpeg-dev:${PACKAGE_ARCH} libopenjp2-7:${PACKAGE_ARCH} libopenjp2-7-dev:${PACKAGE_ARCH} libpng-dev:${PACKAGE_ARCH} \
    libtiff-dev:${PACKAGE_ARCH} libwebp-dev:${PACKAGE_ARCH} \
    zlib1g-dev:${PACKAGE_ARCH} libopenexr-dev:${PACKAGE_ARCH} libtbb-dev:${PACKAGE_ARCH} libopenblas-dev:${PACKAGE_ARCH}
RUN git clone https://github.com/opencv/opencv_contrib.git --branch ${OPENCV_VERSION} --depth=1 -c advice.detachedHead=false
RUN git clone https://github.com/opencv/opencv.git --branch ${OPENCV_VERSION} --depth=1 -c advice.detachedHead=false
ADD ./build/install-opencv.sh install-opencv.sh
RUN ./install-opencv.sh && rm -rf opencv opencv_contrib install-opencv.sh

RUN go install golang.org/x/mobile/cmd/gomobile@latest
ENV PATH=$PATH:/home/builder/go/bin
RUN gomobile init

RUN sudo apt-get install -y libopenjp2-7-dev
RUN sudo apt-get update && sudo apt-get install -y dumb-init

ENV CGO_CPPFLAGS="-I/usr/local/sdk/native/jni/include"
ENV CGO_LDFLAGS="-L/opt/android-sdk/ndk/25.2.9519653/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/lib/x86_64-linux-android \
    -L/usr/local/sdk/native/staticlibs/x86_64 -L/usr/lib/x86_64-linux-gnu -l:libm.a -lopencv_core -lopencv_face \
    -lopencv_videoio -lopencv_imgproc -lopencv_highgui -lopencv_imgcodecs -lopencv_objdetect -lopencv_features2d -lopencv_video -lopencv_dnn -lopencv_xfeatures2d"

ENTRYPOINT ["dumb-init", "--"]