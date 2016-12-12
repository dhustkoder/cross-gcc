#!/bin/bash

# set up these variables to build the GCC cross compiler

PROJECT_ROOT="$(pwd)"
BINUTILS_SRC="$PROJECT_ROOT/src/binutils-2.27.tar.gz"
KERNEL_SRC="$PROJECT_ROOT/src/linux-4.4.32.tar.gz"
GCC_SRC="$PROJECT_ROOT/src/gcc-6.2.0.tar.gz"
GLIBC_SRC="$PROJECT_ROOT/src/glibc-2.24.tar.gz"
LANGUAGES="c,c++"
TARGET=arm-none-linux-gnueabi
KERNEL_ARCH=arm
KERNEL_CONFIG=integrator_defconfig
FLOAT_MODEL=soft
KERNEL_VER="4.4.32"
GCC_VER="6.2.0"

###################################################################
##################################################################

# exit on any error
set -e

# final install directories
INSTALL_DIR="$PROJECT_ROOT/$TARGET"
SYSROOT_DIR="$INSTALL_DIR"

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

# script's log file
LOGFILE="$PROJECT_ROOT/build.log"

if [ -d "$INSTALL_DIR" ]; then
	echo "$INSTALL_DIR already exists." \
		"Delete it if you really wan't to install in this directory."
	exit
elif [ -f "$LOGFILE" ]; then
	rm -rf "$LOGFILE"
fi

function extract_sources 
{
	sources_tar_files=("$BINUTILS_SRC" "$KERNEL_SRC" "$GCC_SRC" "$GLIBC_SRC")
	sources_out_dirs=("$BINUTILS_SRC_DIR" "$KERNEL_SRC_DIR" "$GCC_SRC_DIR" "$GLIBC_SRC_DIR")
	for ((i = 0; i < ${#sources_tar_files[@]}; ++i)); do
		out_dir=${sources_out_dirs[$i]}
		
		if [ -d "$out_dir" ]; then
			rm -vrf "$out_dir"
		fi

		mkdir -pv "$out_dir"
		tar -pxvzf "${sources_tar_files[$i]}" -C "$out_dir" --strip-components=1
	done
}

function build_binutils
{
	if [ -d "$BINUTILS_BUILD_DIR" ]; then
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
	make ARCH="$KERNEL_ARCH" "$KERNEL_CONFIG"
	mkdir -pv "$SYSROOT_DIR/usr"
	make ARCH="$KERNEL_ARCH" headers_check
	make ARCH="$KERNEL_ARCH" INSTALL_HDR_PATH="$SYSROOT_DIR/usr" headers_install
}


function bootstrap_gcc
{
	if [ -d "$BOOTSTRAP_GCC_BUILD_DIR" ]; then
		rm -vrf "$BOOTSTRAP_GCC_BUILD_DIR"
	fi

	mkdir -pv "$BOOTSTRAP_GCC_BUILD_DIR"
	cd "$BOOTSTRAP_GCC_BUILD_DIR"
	
	"$GCC_SRC_DIR/configure" --target="$TARGET" --prefix="$INSTALL_DIR" \
		--without-headers --enable-boostrap --enable-languages="$LANGUAGES" \
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
	if [ -d "$GLIBC_BUILD_DIR" ]; then
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
	
	pushd "$SYSROOT_DIR/$INSTALL_DIR/usr/include"
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
	ln -s "$INSTALL_DIR/lib/gcc/$TARGET/$GCC_VER/libgcc.a" \
		"$INSTALL_DIR/lib/gcc/$TARGET/$GCC_VER/libgcc_s.a"

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
		--with-sysroot="$SYSROOT_DIR" --enable-languages="$LANGUAGES" \
		--with-gnu-as --with-gnu-ld --disable-multilib \
		--with-float="$FLOAT_MODEL" --disable-sjlj-exceptions \
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

	export PATH="$INSTALL_DIR/bin:$PATH"
	export BUILD_CC=gcc

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
		--with-sysroot="$SYSROOT_DIR" --enable-languages="$LANGUAGES" \
		--with-gnu-as --with-gnu-ld --disable-multilib \
		--with-float="$FLOAT_MODEL" --disable-sjlj-exceptions \
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

function create_compile_script
{
	if [ ! -d "$SYSROOT_DIR/home" ]; then
		mkdir -pv "$SYSROOT_DIR/home"
	fi
	
	script_file="$SYSROOT_DIR/home/compile.sh"
	
	if [ -f "$script_file" ]; then
		rm -rf "$script_file"
		touch "$script_file"		
	fi

	function write
	{
		echo $@ >> "$script_file"
	}

	write "export INSTALL_DIR=$INSTALL_DIR"
	write "export TARGET=$TARGET"
	write "export PATH=\$INSTALL_DIR/bin:\$PATH"
	write "export CC=\${TARGET}-gcc"
	write "export CXX=\"\${TARGET}-g++ -L\$INSTALL_DIR/\$TARGET/lib\""
	write "export LD=\${TARGET}-ld"
	write "export AS=\${TARGET}-as"
	write "# write your compilation commands or build system call, whatever"

	chmod +x "$script_file"
}


function log 
{
	echo $@ >> "$LOGFILE"
}


log "# BUILD LOG #"

extract_sources

log "sources extracted..."

build_binutils

log "binutils built..."

install_kernel_headers

log "kernel headers installed..."

bootstrap_gcc

log "bootstrap_gcc built..."

build_glibc

log "glibc built..."

build_gcc

log "gcc built..."

build_final_gcc

log "final gcc built..."

cleanup

log "cleaned up build environment..."

create_compile_script

log "created script for setting up development enviroment at $SYSROOT_DIR/home"

log "# COMPLETE #"

