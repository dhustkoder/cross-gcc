#!/bin/bash

# set up these variables to build the GCC cross compiler

PROJECT_ROOT=""
BINUTILS_SRC=""
KERNEL_SRC=""
GCC_SRC=""
GLIBC_SRC=""
TARGET=
KERNEL_VER=""
GCC_VER=""

###################################################################
##################################################################

# exit on any error
set -e

# final install directories
INSTALL_DIR="$PROJECT_ROOT/$TARGET"
SYSROOT_DIR="$INSTALL_DIR/sysroot"

# temporary build directories 
BUILD_DIR="$INSTALL_DIR/build"
BINUTILS_BUILD_DIR="$BUILD_DIR/binutils-build"
BOOTSTRAP_GCC_BUILD_DIR="$BUILD_DIR/bootstrap-gcc"
GCC_BUILD_DIR="$BUILD_DIR/gcc-build"
FINAL_GCC_BUILD_DIR="$BUILD_DIR/final-gcc"
GLIBC_BUILD_DIR="$BUILD_DIR/glibc-build"

# temporary src directories
SRC_DIR="$INSTALL_DIR/src"
BINUTILS_SRC_DIR="$SRC_DIR/binutils"
GCC_SRC_DIR="$SRC_DIR/gcc"
GLIBC_SRC_DIR="$SRC_DIR/glibc"
KERNEL_SRC_DIR="$SRC_DIR/linux"


function extract_sources 
{
	sources_tar_files=("$BINUTILS_SRC" "$KERNEL_SRC" "$GCC_SRC" "$GLIBC_SRC")
	sources_out_dirs=("$BINUTILS_SRC_DIR" "$KERNEL_SRC_DIR" "$GCC_SRC_DIR" "$GLIBC_SRC_DIR")
	for ((i = 0; i < ${#sources_tar_files[@]}; ++i)); do
		out_dir=${sources_out_dirs[$i]}
		
		if [ -f "$out_dir" ]; then
			rm -vrf "$out_dir"
		fi

		mkdir -pv "$out_dir"
		tar -pxvzf "${sources_tar_files[$i]}" -C "$out_dir" --strip-components=1
	done
}

function build_binutils
{
	if [ -f "$BINUTILS_BUILD_DIR" ]; then
		rm -vrf "$BINUTILS_BUILD_DIR"
	fi

	mkdir -pv "$BINUTILS_BUILD_DIR"
	cd "$BINUTILS_BUILD_DIR"

	"$BINUTILS_SRC_DIR/configure" --disable-werror --target="$TARGET" \
		--prefix="$INSTALL_DIR" --with-sysroot="$SYSROOT_DIR"
	make -j 3
	make install
}


function install_kernel_headers
{	
	cd "$KERNEL_SRC_DIR"
	make mrproper
	make ARCH=arm integrator_defconfig
	mkdir -pv "$INSTALL_DIR/sysroot/usr"
	make ARCH=arm headers_check
	make ARCH=arm INSTALL_HDR_PATH="$INSTALL_DIR/sysroot/usr" headers_install
}


function bootstrap_gcc
{
	if [ -f "$BOOTSTRAP_GCC_BUILD_DIR" ]; then
		rm -vrf "$BOOTSTRAP_GCC_BUILD_DIR"
	fi

	mkdir -pv "$BOOTSTRAP_GCC_BUILD_DIR"
	cd "$BOOTSTRAP_GCC_BUILD_DIR"
	
	"$GCC_SRC_DIR/configure" --target="$TARGET" --prefix="$INSTALL_DIR" \
		--without-headers --enable-boostrap --enable-languages="c" \
		--disable-threads --enable-__cxa_atexit --disable-libmudflap \
		--with-gnu-ld --with-gnu-as --disable-libssp --disable-libgomp \
		--disable-nls --disable-shared

	make all-gcc install-gcc
	make all-target-libgcc install-target-libgcc

	ln -s "$INSTALL_DIR/lib/gcc/$TARGET/$GCC_VER/libgcc.a" \
		"$INSTALL_DIR/lib/gcc/$TARGET/$GCC_VER/libgcc_sh.a"
}


function build_glibc
{
	# installing headers
	if [ -f "$GLIBC_BUILD_DIR" ]; then
		rm -vrf "$GLIBC_BUILD_DIR"
	fi

	mkdir -pv "$GLIBC_BUILD_DIR"
	cd "$GLIBC_BUILD_DIR"
	
	echo "libc_cv_forced_unwind=yes" > config.cache
	echo "libc_cv_c_cleanup=yes" >> config.cache
	
	export PATH="$INSTALL_DIR/bin:$PATH"
	export CROSS="$TARGET"
	export CC="${CROSS}-gcc"
	export LD="${CROSS}-ld"
	export AS="${CROSS}-as"

	"$GLIBC_SRC_DIR/configure" --host="$TARGET" --prefix="$SYSROOT_DIR/usr" \
		--with-headers="$SYSROOT_DIR/usr/include" --config-cache --enable-kernel="$KERNEL_VER"

	make -k install-headers cross_compiling=yes install_root="$SYSROOT_DIR"

	# *** We need to move some files ***
	
	pushd "$SYSROOT_DIR/$INSTALL_DIR/sysroot/usr/include"
	cp -rv * "$SYSROOT_DIR/usr/include/"
	popd

	ln -s "$INSTALL_DIR/lib/gcc/$TARGET/$GCC_VER/libgcc.a" \
		"$INSTALL_DIR/lib/gcc/$TARGET/$GCC_VER/libgcc_eh.a"

	cd "$BUILD_DIR"

	# building

	rm -vrf "$GLIBC_BUILD_DIR"
	mkdir -pv "$GLIBC_BUILD_DIR"
	cd "$GLIBC_BUILD_DIR"
	echo "libc_cv_forced_unwind=yes" > config.cache
	echo "libc_cv_c_cleanup=yes" >> config.cache

	export PATH="$INSTALL_DIR/bin:$PATH"
	export CROSS="$TARGET"
	export CC="${CROSS}-gcc"
	export LD="${CROSS}-ld"
	export AS="${CROSS}-as"

	"$GLIBC_SRC_DIR/configure" --host="$TARGET" --prefix=/usr \
		--with-headers="$SYSROOT_DIR/usr/include" \
		--config-cache --enable-kernel="$KERNEL_VER"

	make -k install-headers cross_compiling=yes install_root="$SYSROOT_DIR"
	ln -s "$INSTALL_DIR/lib/gcc/arm-none-linux-gnueabi/$GCC_VER/libgcc.a" \
		"$INSTALL_DIR/lib/gcc/arm-none-linux-gnueabi/$GCC_VER/libgcc_s.a"

	make -j 3
	make install_root=$SYSROOT_DIR install
}

function build_gcc
{
	# *** unset CC, LD, and AS. We do not want to xcompile the xcompiler :-) ***
	unset CC
	unset LD
	unset AS
	export PATH="$INSTALL_DIR/bin:$PATH"

	# *** delete gcc-x.x.x and re-install it ***
	cd "$SRC_DIR"
	rm -vrf "$GCC_SRC_DIR"
	mkdir -pv "$GCC_SRC_DIR"

	tar -pxvzf "$GCC_SRC" -C "$GCC_SRC_DIR" --strip-components=1
	cd "$GCC_SRC_DIR"
	"./contrib/download_prerequisites"
	
	mkdir -pv "$GCC_BUILD_DIR"
	cd "$GCC_BUILD_DIR"
	
	echo "libc_cv_forced_unwind=yes" > config.cache
	echo "libc_cv_c_cleanup=yes" >> config.cache
	
	export BUILD_CC=gcc
	
	"$GCC_SRC_DIR/configure" --target="$TARGET" --prefix="$INSTALL_DIR" \
		--with-sysroot="$SYSROOT_DIR" --enable-languages="c" \
		--with-gnu-as --with-gnu-ld --disable-multilib \
		--with-float=soft --disable-sjlj-exceptions \
		--disable-nls --enable-threads=posix --enable-long-longx

	make all-gcc
	make install-gcc
}


function build_final_gcc
{
	# *** make sure these are still unset ***
	unset CC
	unset LD
	unset AS

	# *** delete gcc-x.x.x and re-install it ***
	cd "$SRC_DIR"
	rm -vrf "$GCC_SRC_DIR"
	mkdir -pv "$GCC_SRC_DIR"

	tar -pxvzf "$GCC_SRC" -C "$GCC_SRC_DIR" --strip-components=1
	cd "$GCC_SRC_DIR"
	"./contrib/download_prerequisites"
	
	mkdir -pv "$FINAL_GCC_BUILD_DIR"
	cd "$FINAL_GCC_BUILD_DIR"
	
	echo "libc_cv_forced_unwind=yes" > config.cache
	echo "libc_cv_c_cleanup=yes" >> config.cache
	
	"$GCC_SRC_DIR/configure" --target="$TARGET" --prefix="$INSTALL_DIR" \
		--with-sysroot="$SYSROOT_DIR" --enable-languages="c" \
		--with-gnu-as --with-gnu-ld --disable-multilib \
		--with-float=soft --disable-sjlj-exceptions \
		--disable-nls --enable-threads=posix \
		--disable-libmudflap --disable-libssp \
		--enable-long-longx --with-shared

	make -j 3
	make install
}

function cleanup
{
	rm -vrf "$SRC_DIR"
	rm -vrf "$BUILD_DIR"
}

LOGFILE="$PROJECT_ROOT/build.log"

echo "# BUILD LOG #" > "$LOGFILE"

extract_sources

echo "sources extracted..." >> "$LOGFILE"

build_binutils

echo "binutils built..." >> "$LOGFILE"

install_kernel_headers

echo "kernel headers installed..." >> "$LOGFILE"

bootstrap_gcc

echo "bootstrap_gcc built..." >> "$LOGFILE"

build_glibc

echo "glibc built..." >> "$LOGFILE"

build_gcc

echo "gcc built..." >> "$LOGFILE"

build_final_gcc

echo "final gcc built..." >> "$LOGFILE"

cleanup

echo "cleaned up build environment..." >> "$LOGFILE"

echo "# COMPLETE #" >> "$LOGFILE"

