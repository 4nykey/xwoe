# Copyright 1999-2021 Gentoo Authors
# Distributed under the terms of the GNU General Public License v2

EAPI=7

MULTILIB_COMPAT=( abi_x86_{32,64} )
inherit autotools flag-o-matic vcs-snapshot multilib-minimal

export CBUILD=${CBUILD:-${CHOST}}
export CTARGET=${CTARGET:-${CHOST}}
if [[ ${CTARGET} == ${CHOST} ]] ; then
	if [[ ${CATEGORY/cross-} != ${CATEGORY} ]] ; then
		export CTARGET=${CATEGORY#cross-}
	fi
fi

DESCRIPTION="Linux-like environment for Windows"
HOMEPAGE="https://cygwin.com/"
MY_PV="05cfd1a"
MY_PVB="$(ver_cut 1-3)"
if [[ -n ${PV%%*_p*} ]]; then
	MY_PV="${PN}-$(ver_cut 1-3 ${PV//./_})-release"
	MY_PVB+="-1"
else
	MY_PVB+="-$(ver_cut 5)"
fi
SRC_URI="
	!headers-only? (
		mirror://githubcl/${PN}/${PN}/tar.gz/${MY_PV}
		-> ${P}.tar.gz
	)
	headers-only? (
		abi_x86_32? (
			mirror://cygwin/x86/release/${PN}/${PN}-devel/${PN}-devel-${MY_PVB}.tar.xz
			-> ${P}-x86.tar.xz
		)
		abi_x86_64? (
			mirror://cygwin/x86_64/release/${PN}/${PN}-devel/${PN}-devel-${MY_PVB}.tar.xz
			-> ${P}-amd64.tar.xz
		)
	)
"

LICENSE="NEWLIB LGPL-3+"
SLOT="0"
KEYWORDS="~amd64 ~x86"
IUSE="headers-only"
RESTRICT="strip primaryuri"
BDEPEND="
	virtual/perl-Getopt-Long
"
PATCHES=(
	"${FILESDIR}"/${PN}-multilib.diff
	"${FILESDIR}"/${PN}-ssp.diff
)

just_headers() {
	use headers-only && [[ ${CHOST} != ${CTARGET} ]]
}

pkg_setup() {
	if [[ ${CBUILD} == ${CHOST} ]] && [[ ${CHOST} == ${CTARGET} ]] ; then
		die "Invalid configuration; do not emerge this directly"
	fi

	if just_headers; then
		S="${WORKDIR}"
		PATCHES=()
		return
	fi

	CHOST=${CTARGET} strip-unsupported-flags
	filter-flags -march=*
	strip-flags
	append-cppflags -DMISSING_SYSCALL_NAMES -U_FORTIFY_SOURCE
	append-flags -fno-stack-protector
	local _b
	for _b in ar as dlltool ld nm obj{copy,dump} ranlib strip wind{mc,res}; do
		export ${_b^^}_FOR_TARGET=${CTARGET}-${_b}
	done
}

src_prepare() {
	default

	if just_headers; then
		cd ${P}-amd64
		eapply -p3 "${FILESDIR}"/${PN}-ssp.diff
		return
	fi

	sed \
		-e '/^SUBDIRS/ s:=.*:=cygwin:' \
		-e 's:cygdoc_DATA = :&#:' \
		-i winsup/Makefile.am
	sed \
		-e 's:-Werror::' \
		-i winsup/cygwin/Makefile.am
	cd winsup
	eautoreconf
}

multilib_src_configure() {
	just_headers && return
	local myeconfargs=(
		--disable-werror
		--disable-silent-rules
		--with-cross-bootstrap
		--infodir="${EPREFIX}/usr/${CTARGET}/usr/share/info"
		--with-windows-headers="${EPREFIX}/usr/${CTARGET}/usr/include/w32api"
		--with-windows-libs="${EPREFIX}/usr/${CTARGET}/usr/$(get_abi_LIBDIR)/w32api"
		--disable-multilib
		--target=${CHOST%%-*}-${CTARGET#*-}
	)

	ECONF_SOURCE="${S}" \
	CC_FOR_TARGET="${CTARGET}-gcc $(get_abi_CFLAGS)" \
	CXX_FOR_TARGET="${CTARGET}-g++ $(get_abi_CFLAGS)" \
	CFLAGS_FOR_TARGET="${CPPFLAGS} ${CFLAGS}" \
	econf "${myeconfargs[@]}"
}

multilib_src_compile() {
	just_headers && return
	emake \
		CCWRAP_VERBOSE=1
}

multilib_src_install() {
	if just_headers; then
		# install prebuilt libs because of circular dep gcc(+cxx) <-> cygwin
		insinto /usr/${CTARGET}/usr/$(get_abi_LIBDIR)
		doins -r "${S}"/${P}-${ABI}/lib/.
	else
		dodir /usr/${CTARGET}/usr/lib
		# parallel install may overwrite winsup headers with newlib ones
		emake \
			-j1 \
			DESTDIR="${ED}" \
			ABI=${ABI} \
			tooldir="${EPREFIX}/usr/${CTARGET}/usr" \
			libdir=$(get_abi_LIBDIR) \
			install
	fi
}

multilib_src_install_all() {
	if just_headers; then
		insinto /usr/${CTARGET}/usr
		doins -r ${P}-amd64/include
	fi
	# help gcc find its way
	use abi_x86_32 && dosym usr/${LIBDIR_x86} /usr/${CTARGET}/${LIBDIR_x86}
	dosym usr/${LIBDIR_amd64} /usr/${CTARGET}/${LIBDIR_amd64}
	dosym usr/${LIBDIR_amd64} /usr/${CTARGET}/lib
	dosym usr/include /usr/${CTARGET}/include
}
