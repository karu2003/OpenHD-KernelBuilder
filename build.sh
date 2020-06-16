#!/bin/bash


PLATFORM=$1
DISTRO=$2
ISA=$3


PI_TOOLS_REPO=https://github.com/raspberrypi/tools.git
PI_TOOLS_BRANCH=master

# Fixed at v5.2.20 until 5.3.4 works for injection
RTL_8812AU_REPO=https://github.com/aircrack-ng/rtl8812au.git
RTL_8812AU_BRANCH=v5.2.20

V4L2LOOPBACK_REPO=https://github.com/OpenHD/v4l2loopback.git
V4L2LOOPBACK_BRANCH=openhd1




CONFIGS=$(pwd)/configs

J_CORES=$(nproc)

PACKAGE_DIR=$(pwd)/package

rm -rf ${PACKAGE_DIR}

mkdir -p ${PACKAGE_DIR}/boot/overlays
mkdir -p ${PACKAGE_DIR}/lib/modules


if [[ "${PLATFORM}" == "pi" ]]; then
    if [ ! -d $(pwd)/tools ]; then
        echo "Downloading Raspberry Pi toolchain"
        git clone --depth=1 -b ${PI_TOOLS_BRANCH} ${PI_TOOLS_REPO} $(pwd)/tools
        export PATH=$(pwd)/tools/arm-bcm2708/gcc-linaro-arm-linux-gnueabihf-raspbian-x64/bin:${PATH}
        echo "Path: ${PATH}"
    fi

    ARCH=arm
    PACKAGE_ARCH=armhf
    CROSS_COMPILE=arm-linux-gnueabihf-
    KERNEL_REPO=https://github.com/OpenHD/linux.git
fi


# load the builder configuration 
source $(pwd)/kernels/${PLATFORM}-${DISTRO}-${ISA}


LINUX_DIR=linux-${PLATFORM}-${KERNEL_BRANCH}

fetch_pi_source() {
    if [[ ! -d "${LINUX_DIR}" ]]; then
        echo "Download the pi kernel source"
        git clone -b ${KERNEL_BRANCH} ${KERNEL_REPO} ${LINUX_DIR}
    fi

    pushd ${LINUX_DIR}
        git reset --hard
        git pull
        git checkout ${KERNEL_COMMIT}
    popd
}


fetch_rtl8812_driver() {
    echo "Download the rtl8812au driver"

    rm -r rtl8812au > /dev/null 2>&1
    git clone --depth=1 -b ${RTL_8812AU_BRANCH} ${RTL_8812AU_REPO}


    pushd rtl8812au
        if [[ "${PLATFORM}" == "pi" ]]; then
            sudo sed -i 's/CONFIG_PLATFORM_I386_PC = y/CONFIG_PLATFORM_I386_PC = n/' Makefile
            sudo sed -i 's/CONFIG_PLATFORM_ARM_RPI = n/CONFIG_PLATFORM_ARM_RPI = y/' Makefile
        fi

        # per justins request commented out
        # sudo sed -i 's/CONFIG_USB2_EXTERNAL_POWER = n/CONFIG_USB2_EXTERNAL_POWER = y/' Makefile
        sudo sed -i 's/export TopDIR ?= $(shell pwd)/export TopDIR2 ?= $(shell pwd)/' Makefile
        sudo sed -i '/export TopDIR2 ?= $(shell pwd)/a export TopDIR := $(TopDIR2)/drivers/net/wireless/realtek/rtl8812au/' Makefile

        pushd core
            # Change the STBC value to make all antennas send with awus036ACH
            sudo sed -i 's/u8 fixed_rate = MGN_1M, sgi = 0, bwidth = 0, ldpc = 0, stbc = 0;/u8 fixed_rate = MGN_1M, sgi = 0, bwidth = 0, ldpc = 0, stbc = 1;/' rtw_xmit.c
        popd

    popd

    echo "Merge the RTL8812 driver into the kernel"
    cp -a rtl8812au/. ${LINUX_DIR}/drivers/net/wireless/realtek/rtl8812au/
}


fetch_v4l2loopback_driver() {
    echo "Download the v4l2loopback driver"
    rm -r v4l2loopback > /dev/null 2>&1
    git clone --depth=1 -b ${V4L2LOOPBACK_BRANCH} ${V4L2LOOPBACK_REPO}

    echo "Merge the v4l2loopback driver into the kernel"
    cp -a v4l2loopback/. ${LINUX_DIR}/drivers/media/v4l2loopback/

}


build_pi_kernel() {
    echo "Building pi kernel"

    pushd ${LINUX_DIR}

        echo "Set kernel config"
        cp "${CONFIGS}/.config-${KERNEL_BRANCH}-${ISA}" ./.config || exit 1

        make clean

        yes "" | KERNEL=${KERNEL} ARCH=${ARCH} CROSS_COMPILE=${CROSS_COMPILE} make oldconfig || exit 1

        KERNEL=${KERNEL} ARCH=${ARCH} CROSS_COMPILE=${CROSS_COMPILE} make -j $J_CORES zImage modules dtbs || exit 1

        echo "Copy kernel"
        cp arch/arm/boot/zImage "${PACKAGE_DIR}/boot/${KERNEL}.img" || exit 1

        echo "Copy kernel modules"
        make -j $J_CORES ARCH=${ARCH} CROSS_COMPILE=${CROSS_COMPILE}  INSTALL_MOD_PATH="${PACKAGE_DIR}" modules_install || exit 1

        echo "Copy DTBs"
        sudo cp arch/arm/boot/dts/*.dtb "${PACKAGE_DIR}/boot/" || exit 1
        sudo cp arch/arm/boot/dts/overlays/*.dtb* "${PACKAGE_DIR}/boot/overlays/" || exit 1
        sudo cp arch/arm/boot/dts/overlays/README "${PACKAGE_DIR}/boot/overlays/" || exit 1

        # prevents the inclusion of firmware that can conflict with normal firmware packages, dpkg will complain. there
        # should be a kernel config to stop installing this into the package dir in the first place
        rm -r "${PACKAGE_DIR}/lib/firmware"
    popd
}


package() {
    PACKAGE_NAME=openhd-linux-${PLATFORM}-${ISA}

    VERSION=$(git describe --tags | sed 's/\(.*\)-.*/\1/')

    fpm -a ${PACKAGE_ARCH} -s dir -t deb -n ${PACKAGE_NAME} -v ${VERSION} -C ${PACKAGE_DIR} -p ${PACKAGE_NAME}_VERSION_ARCH.deb || exit 1

    cloudsmith push deb openhd/openhd/raspbian/${DISTRO} ${PACKAGE_NAME}_${VERSION}_${PACKAGE_ARCH}.deb
}


if [[ "${PLATFORM}" == "pi" ]]; then
    fetch_pi_source
fi

fetch_rtl8812_driver
fetch_v4l2loopback_driver


if [[ "${PLATFORM}" == "pi" ]]; then
    build_pi_kernel
fi

package
