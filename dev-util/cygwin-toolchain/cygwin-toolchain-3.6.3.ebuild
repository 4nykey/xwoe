# Copyright 2022-2025 Gentoo Authors
# Distributed under the terms of the GNU General Public License v2

EAPI=8

inherit edo flag-o-matic toolchain-funcs autotools

BINUTILS_PV=2.44
GCC_PV=15.1.0
W32_PV=12.0.0
MY_PN=${PN%-*}
MY_P=${MY_PN}-${PV}

DESCRIPTION="All-in-one cygwin cross toolchain"
HOMEPAGE="https://cygwin.org"
SRC_URI="
	mirror://githubcl/${MY_PN}/${MY_PN}/tar.gz/${MY_P} -> ${P}.tar.gz
	mirror://cygwin/x86_64/release/${MY_PN}/${MY_PN}-devel/${MY_PN}-devel-${PV}-1-x86_64.tar.xz
	mirror://githubcl/mingw-w64/mingw-w64/tar.gz/v${W32_PV} -> mingw-w64-v${W32_PV}.tar.gz
	mirror://gnu/binutils/binutils-${BINUTILS_PV}.tar.xz
"
SRC_URI+="
	mirror://cygwin/x86_64/release/w32api-headers/w32api-headers-${W32_PV}-1.tar.xz
	mirror://cygwin/x86_64/release/w32api-runtime/w32api-runtime-${W32_PV}-1.tar.xz
"
if [[ ${GCC_PV} == *-* ]]; then
	SRC_URI+=" mirror://gcc/snapshots/${GCC_PV}/gcc-${GCC_PV}.tar.xz"
else
	SRC_URI+="
		mirror://gcc/gcc-${GCC_PV}/gcc-${GCC_PV}.tar.xz
		mirror://gnu/gcc/gcc-${GCC_PV}/gcc-${GCC_PV}.tar.xz
	"
fi
S="${WORKDIR}"

LICENSE="
	GPL-3+
	LGPL-3+ || ( GPL-3+ libgcc libstdc++ gcc-runtime-library-exception-3.1 )
	ZPL BSD BSD-2 ISC LGPL-2+ LGPL-2.1+ NEWLIB LGPL-3+
"
SLOT="0"
KEYWORDS="-* ~amd64"
IUSE="custom-cflags debug"

RDEPEND="
	dev-libs/gmp:=
	dev-libs/mpc:=
	dev-libs/mpfr:=
	sys-libs/zlib:=
	virtual/libiconv
"
DEPEND="
	${RDEPEND}
"

QA_CONFIG_IMPL_DECL_SKIP=(
	strerror_r # libstdc++ test using -Wimplicit+error
)

pkg_pretend() {
	[[ ${MERGE_TYPE} == binary ]] && return

	tc-is-cross-compiler &&
		die "cross-compilation of the toolchain itself is unsupported"
}

pkg_setup() {
	filter-lto
	use custom-cflags || strip-flags
}

src_prepare() {
	# rename directories to simplify both patching and the ebuild
	mv binutils{-${BINUTILS_PV},} || die
	mv gcc{-${GCC_PV},} || die
	mv mingw-w64-${W32_PV} mingw64 || die
	mv ${MY_PN}{-${MY_P},} || die

	mv usr/lib/w32api/*.a usr/lib
	rm -rf usr/lib/w32api
	ln -s . usr/lib/w32api

	default

	cd ${MY_PN}/winsup
	sed \
		-e '/^SUBDIRS/ s:=.*:=cygwin:' \
		-e 's:cygdoc_DATA = :&#:' \
		-i Makefile.am
	sed \
		-e 's:-Werror::' \
		-i cygwin/Makefile.am
	eautoreconf
}

src_compile() {
	CTARGET=x86_64-pc-cygwin

	MWT_D=${T}/root
	local mwtdir=/usr/lib/${PN}
	local prefix=${EPREFIX}${mwtdir}
	local sysroot=${MWT_D}${prefix}
	local -x \
		CPPFLAGS_FOR_TARGET="-I${sysroot}/usr/include/w32api -Wno-narrowing" \
		CFLAGS_FOR_TARGET="${CFLAGS_FOR_TARGET:-}" \
		CXXFLAGS_FOR_TARGET="${CXXFLAGS_FOR_TARGET:-}" \
		LDFLAGS_FOR_TARGET="${LDFLAGS_FOR_TARGET:-} -L${sysroot}/usr/lib/w32api" \
		PATH=${sysroot}/bin:${PATH}

	mkdir -p "${sysroot}"
	mv -f "${S}"/usr "${sysroot}"
	ln -s usr "${sysroot}"/${CTARGET}
	ln -s usr/include "${sysroot}"/include
	ln -s usr/include/w32api "${sysroot}"/sys-include

	# global configure flags
	local conf=(
		--build=${CBUILD:-${CHOST}}
		--target=${CTARGET}
		--prefix="${prefix}"
		--{doc,info,man}dir=/.skip # let individual packages handle docs
		--disable-werror
		--disable-silent-rules
		--disable-multilib
		--disable-nls
	)

	# binutils
	local conf_binutils=(
		--host=${CHOST}
		--disable-cet
		--disable-default-execstack
		--with-system-zlib
		--without-debuginfod
		--without-msgpack
		--without-zstd
	)

	# gcc (minimal -- if need more, disable only in stage1 / enable in stage3)
	local conf_gcc=(
		--host=${CHOST}
		--enable-languages=c,c++
		--disable-libstdcxx-pch
		--disable-bootstrap
		--disable-cet
		--disable-gcov #843989
		--disable-libsanitizer
		--disable-werror
		--with-gcc-major-version-only
		--with-system-zlib
		--without-isl
		--without-zstd
		--with-newlib
		--disable-lto
		--disable-pie
		--disable-ssp
		--with-sysroot="${sysroot}"
		--with-build-sysroot="${sysroot}"
	)

	local conf_gcc_stage1=(
	)

	local conf_cygwin=(
		--with-cross-bootstrap
	)

	local conf_mingw64=(
		--host=${CTARGET}
		--prefix="${prefix}/usr"
		--with-sysroot="${sysroot}"
		--with-{crt,headers}
		--disable-lib32
		--enable-lib64
		--enable-w32api
	)

	# mwt-build [-x] <path/package-name> [stage-name]
	# -> ./configure && make && make install && mwt-package() && mwt-package_stage()
	# passes conf, conf_package, and conf_package_stage arrays to configure, and
	# users can add options through environment with e.g.
	#	MWT_BINUTILS_CONF="--some-option"
	#	MWT_GCC_STAGE1_CONF="--some-gcc-stage1-only-option"
	#	MWT_WIDL_CONF="--some-other-option"
	#	EXTRA_ECONF="--global-option" (generic naming for if not reading this)
	mwt-build() {
		if [[ ${1} == -x ]]; then
			(
				# cross-compiling, cleanup and let ./configure handle it
				local _b
				for _b in ar as cpp dlltool ld nm obj{copy,dump} ranlib strip wind{mc,res}; do
					export ${_b^^}_FOR_TARGET=${CTARGET}-${_b}
				done
				export CC_FOR_TARGET=${CTARGET}-gcc
				export CXX_FOR_TARGET=${CTARGET}-g++
				CPPFLAGS="${CPPFLAGS_FOR_TARGET}"
				CFLAGS="${CFLAGS_FOR_TARGET}"
				CXXFLAGS="${CXXFLAGS_FOR_TARGET}"
				LDFLAGS="${LDFLAGS_FOR_TARGET}"
				filter-flags '-fuse-ld=*'
				filter-flags '-mfunction-return=thunk*' #878849
				strip-unsupported-flags
				mwt-build "${@:2}"
			)
			return
		fi

		local id=${1##*/}
		local build_dir=${WORKDIR}/${1}${2+_${2}}-build

		# econf is not allowed in src_compile and its defaults are
		# mostly unused here, so use configure directly
		local conf=( "${WORKDIR}/${1}"/configure "${conf[@]}" )

		local -n conf_id=conf_${id} conf_id2=conf_${id}_${2}
		[[ ${conf_id@a} == *a* ]] && conf+=( "${conf_id[@]}" )
		[[ ${2} && ${conf_id2@a} == *a* ]] && conf+=( "${conf_id2[@]}" )

		local -n extra_id=MWT_${id^^}_CONF extra_id2=MWT_${id^^}_${2^^}_CONF
		conf+=( ${EXTRA_ECONF} ${extra_id} ${2+${extra_id2}} )

		einfo "Building ${id}${2+ ${2}} in ${build_dir} ..."

		mkdir -p "${build_dir}" || die
		pushd "${build_dir}" >/dev/null || die

		edo "${conf[@]}"
		emake
		emake DESTDIR="${MWT_D}" install

		declare -f mwt-${id} >/dev/null && edo mwt-${id}
		declare -f mwt-${id}_${2} >/dev/null && edo mwt-${id}_${2}

		popd >/dev/null || die
	}

	mwt-build binutils
	mwt-build gcc stage1
	mwt-build -x ${MY_PN} runtime
	mwt-build -x mingw64 runtime
	mwt-build gcc stage2

	# portage doesn't know the right strip executable to use for CTARGET
	# and it can lead to .a mangling, notably with 32bit (breaks toolchain)
	dostrip -x ${mwtdir}/{${CTARGET}/lib{,32},lib/gcc/${CTARGET}}

	# ... and instead do it here given this saves ~60MB
	if use !debug; then
		einfo "Stripping ${CTARGET} libraries ..."
		find "${sysroot}"/{,lib/gcc/}${CTARGET} -type f -name '*.a' \
			-exec ${CTARGET}-strip --strip-unneeded {} + || die
		find "${sysroot}"/usr -type f -iregex '.*\.\(a\|dll\)' \
			-exec ${CTARGET}-strip --strip-unneeded {} + || die
		${CTARGET}-strip --strip-unneeded "${sysroot}"/bin/cygwin1.dll || die
	fi
}

src_install() {
	mv "${MWT_D}${EPREFIX}"/* "${ED}" || die

	find "${ED}" -type f -name '*.la' -delete || die
}
