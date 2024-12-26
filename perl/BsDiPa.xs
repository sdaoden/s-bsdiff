/*@ BsDiPa: perl XS interface of/to S-bsdipa.
 *@
 *@ Remarks:
 *@ - code requires ISO STD C99 (for now).
 *
 * Copyright (c) 2024 Steffen Nurpmeso <steffen@sdaoden.eu>.
 * SPDX-License-Identifier: ISC
 *
 * Permission to use, copy, modify, and/or distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 */

#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

#define s_BSDIPA_IO_READ
#define s_BSDIPA_IO_WRITE
#define s_BSDIPA_IO s_BSDIPA_IO_ZLIB
/*#define s_BSDIPA_IO_ZLIB_LEVEL 9*/
#include "c-lib/s-bsdipa-io.h"
#undef s_BSDIPA_IO
#define s_BSDIPA_IO s_BSDIPA_IO_RAW
#include "c-lib/s-bsdipa-io.h"

#include <c-lib/s-bsdiff.c>
#include <c-lib/s-bspatch.c>

#include <c-lib/libdivsufsort/divsufsort.c>
#undef lg_table
#define lg_table a_sssort_lg_table
#include <c-lib/libdivsufsort/sssort.c>
#undef lg_table
#define lg_table a_trsort_lg_table
#include <c-lib/libdivsufsort/trsort.c>

static void *a_alloc(size_t size);
static void a_free(void *vp);

static SV *a_core_diff(int what, SV *before_sv, SV *after_sv, SV *patch_sv, SV *magic_window);
static enum s_bsdipa_state a_core_diff_write(void *user_cookie, uint8_t const *dat, s_bsdipa_off_t len,
		s_bsdipa_off_t is_last);

static SV *a_core_patch(int what, SV *after_sv, SV *patch_sv, SV *before_sv);

static void *
a_alloc(size_t size){
	char *vp;

	Newx(vp, size, char);

	return vp;
}

static void
a_free(void *vp){
	Safefree(vp);
}

static SV *
a_core_diff(int what, SV *before_sv, SV *after_sv, SV *patch_sv, SV *magic_window){
	struct s_bsdipa_diff_ctx d;
	char const *emsg;
	SV *pref;
	enum s_bsdipa_state s;

	s = s_BSDIPA_INVAL;

	pref = NULL;
	if(/*!SvOK(patch_sv) ||*/ !SvROK(patch_sv))
		goto jleave;
	pref = SvRV(patch_sv);

	if(/*!SvOK(before_sv) ||*/ !SvPOK(before_sv))
		goto jleave;

	if(/*!SvOK(after_sv) ||*/ !SvPOK(after_sv))
		goto jleave;

	if(magic_window == NULL || !SvOK(magic_window))
		d.dc_magic_window = 0;
	else if(!SvIOK(magic_window))
		goto jleave;
	else{
		IV i;

		i = SvIV(magic_window);
		if(i > 4096) /* <> docu! */
			goto jleave;
		d.dc_magic_window = (s_bsdipa_off_t)i;
	}

	d.dc_mem.mc_alloc = &a_alloc;
	d.dc_mem.mc_free = &a_free;
	d.dc_before_len = SvCUR(before_sv);
	d.dc_before_dat = SvPVbyte_nolen(before_sv);
	d.dc_after_len = SvCUR(after_sv);
	d.dc_after_dat = SvPVbyte_nolen(after_sv);

	s = s_bsdipa_diff(&d);
	if(s != s_BSDIPA_OK)
		goto jdone;

	SvPVCLEAR(pref);
	if(what == s_BSDIPA_IO_ZLIB)
		s = s_bsdipa_io_write_zlib(&d, &a_core_diff_write, pref, -1);
	else /*if(what == s_BSDIPA_IO_RAW)*/{
		s_bsdipa_off_t x;

		x = sizeof(d.dc_header) + d.dc_ctrl_len + d.dc_diff_len + d.dc_extra_len +1;
		SvGROW(pref, x);
		SvCUR_set(pref, 0);
		s = s_bsdipa_io_write_raw(&d, &a_core_diff_write, pref, 0);
	}

jdone:
	s_bsdipa_diff_free(&d);

jleave:
	if(s != s_BSDIPA_OK && pref != NULL)
		sv_setsv(pref, &PL_sv_undef);

	return newSViv(s);
}

static enum s_bsdipa_state
a_core_diff_write(void *user_cookie, uint8_t const *dat, s_bsdipa_off_t len, s_bsdipa_off_t is_last){
	char *cp;
	s_bsdipa_off_t l;
	SV *p;
	enum s_bsdipa_state rv;

	if(is_last >= 0 && len <= 0)
		goto jok;

	p = (SV*)user_cookie;

	/* Buffer takeover? */
	if(is_last < 0){
		l = len;
		sv_usepvn_flags(p, (char*)dat, len, SV_SMAGIC | SV_HAS_TRAILING_NUL);
	}else{
		l = (s_bsdipa_off_t)SvCUR(p);

		cp = SvGROW(p, l + len +1);
		if(cp == NULL){
			rv = s_BSDIPA_NOMEM;
			goto jleave;
		}

		memcpy(&cp[(unsigned long)l], dat, len);
		l += len;
		cp[(unsigned long)l] = '\0'; /* mumble */
		SvCUR_set(p, l);
		SvPOK_only(p);
		SvSETMAGIC(p);
	}

jok:
	rv = s_BSDIPA_OK;
jleave:
	return rv;
}

static SV *
a_core_patch(int what, SV *after_sv, SV *patch_sv, SV *before_sv){
	return newSViv(s_BSDIPA_INVAL);
}

MODULE = BsDiPa PACKAGE = BsDiPa
VERSIONCHECK: DISABLE

SV *
VERSION()
CODE:
	RETVAL = newSVpv(s_BSDIPA_VERSION, sizeof(s_BSDIPA_VERSION) -1);
OUTPUT:
	RETVAL

SV *
CONTACT()
CODE:
	RETVAL = newSVpv(s_BSDIPA_CONTACT, sizeof(s_BSDIPA_CONTACT) -1);
OUTPUT:
	RETVAL

SV *
COPYRIGHT()
CODE:
	RETVAL = newSVpv(s_BSDIPA_COPYRIGHT, sizeof(s_BSDIPA_COPYRIGHT) -1);
OUTPUT:
	RETVAL

SV *
OK()
CODE:
	RETVAL = newSViv(s_BSDIPA_OK);
OUTPUT:
	RETVAL

SV *
FBIG()
CODE:
	RETVAL = newSViv(s_BSDIPA_FBIG);
OUTPUT:
	RETVAL

SV *
NOMEM()
CODE:
	RETVAL = newSViv(s_BSDIPA_NOMEM);
OUTPUT:
	RETVAL

SV *
INVAL()
CODE:
	RETVAL = newSViv(s_BSDIPA_INVAL);
OUTPUT:
	RETVAL

SV *
core_diff_raw(before_sv, after_sv, patch_sv, magic_window=NULL)
	SV *before_sv
	SV *after_sv
	SV *patch_sv
	SV *magic_window
CODE:
	RETVAL = a_core_diff(s_BSDIPA_IO_RAW, before_sv, after_sv, patch_sv, magic_window);
OUTPUT:
	RETVAL

SV *
core_diff_zlib(before_sv, after_sv, patch_sv, magic_window=NULL)
	SV *before_sv
	SV *after_sv
	SV *patch_sv
	SV *magic_window
CODE:
	RETVAL = a_core_diff(s_BSDIPA_IO_ZLIB, before_sv, after_sv, patch_sv, magic_window);
OUTPUT:
	RETVAL

SV *
core_patch_raw(after_sv, patch_sv, before_sv)
	SV *after_sv
	SV *patch_sv
	SV *before_sv
CODE:
	RETVAL = a_core_patch(s_BSDIPA_IO_RAW, after_sv, patch_sv, before_sv);
OUTPUT:
	RETVAL

SV *
core_patch_zlib(after_sv, patch_sv, before_sv)
	SV *after_sv
	SV *patch_sv
	SV *before_sv
CODE:
	RETVAL = a_core_patch(s_BSDIPA_IO_ZLIB, after_sv, patch_sv, before_sv);
OUTPUT:
	RETVAL
