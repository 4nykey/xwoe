# Copyright 1999-2020 Gentoo Authors
# Distributed under the terms of the GNU General Public License v2

EAPI=7

export CBUILD=${CBUILD:-${CHOST}}
export CTARGET=${CTARGET:-${CHOST}}
if [[ ${CTARGET} == ${CHOST} ]] ; then
	if [[ ${CATEGORY} == cross-* ]] ; then
		export CTARGET=${CATEGORY#cross-}
	fi
fi

MY_PN="mingw-w64"

MULTILIB_COMPAT=( abi_x86_{32,64} )
inherit flag-o-matic autotools multilib-build
if [[ -z ${PV%%*9999} ]]; then
	inherit git-r3
	EGIT_REPO_URI="https://git.code.sf.net/p/${MY_PN}/${MY_PN}"
else
	KEYWORDS="~amd64"
	SRC_URI="mirror://sourceforge/${MY_PN}/${MY_PN}/${MY_PN}-release/${MY_PN}-v${PV}.tar.bz2"
	S="${WORKDIR}/${MY_PN}-v${PV}"
fi

DESCRIPTION="Free Win32 runtime and import library definitions"
HOMEPAGE="https://mingw-w64.org"

LICENSE="ZPL GPL-2+ LGPL-2.1+ MIT"
SLOT="0"
IUSE="headers-only idl libraries tools"
REQUIRED_USE="headers-only? ( !libraries !tools )"
RESTRICT="strip"

just_headers() {
	use headers-only && [[ ${CHOST} != ${CTARGET} ]]
}

pkg_setup() {
	if [[ ${CBUILD} == ${CHOST} ]] && [[ ${CHOST} == ${CTARGET} ]] ; then
		die "Invalid configuration"
	fi
	just_headers && return
	CHOST=${CTARGET} strip-unsupported-flags
	filter-flags -march=*
	unset AR NM RANLIB
}

src_prepare() {
	local PATCHES=(
		"${FILESDIR}"/${PN}-7.0.0-fortify-only-ssp.patch
	)
	default
	just_headers && return
	sed \
		-e "/libx8632suffx=/ s:=.*:=lib32:" \
		-e "/libx8664suffx=/ s:=.*:=lib64:" \
		-i mingw-w64-crt/configure.ac
	eautoreconf
}

src_configure() {
	local myeconfargs=(
		--host=${CTARGET}
		--prefix="${EPREFIX}/usr/${CTARGET}/usr"
		--with-headers
		--with$(just_headers && echo 'out')-crt
		$(use_enable idl)
		$(use_enable abi_x86_32 lib32)
		--enable-lib64
		--enable-wildcard
		--enable-secure-api
	)

	# don't use headers from previously installed version
	if ! just_headers; then
		mkdir -p "${WORKDIR}"/headers
		cd "${WORKDIR}"/headers
		ECONF_SOURCE="${S}" \
			econf "${myeconfargs[@]}" \
			--prefix="${T}/tmproot" \
			--without-crt
	fi

	cd "${S}"
	econf "${myeconfargs[@]}" \
		$(use_with libraries libraries all) \
		$(use_with tools tools all) \
		--with-sysroot="${T}/tmproot"
}

src_compile() {
	just_headers || emake -C "${WORKDIR}/headers" install
	default
}

src_install() {
	default

	[[ ${CHOST} != ${CTARGET} ]] || return
	# gcc is configured to look at specific hard-coded paths for mingw #419601
	dosym usr /usr/${CTARGET}/mingw
	dosym usr/include /usr/${CTARGET}/include
	just_headers && return
	dosym usr/lib64 /usr/${CTARGET}/lib
	dosym usr/lib64 /usr/${CTARGET}/lib64
	if use abi_x86_32; then
		dosym ../lib32 /usr/${CTARGET}/usr/lib64/32
		dosym usr/lib32 /usr/${CTARGET}/lib32
	fi
}
