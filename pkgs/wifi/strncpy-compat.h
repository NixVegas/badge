/*
 * kernel 7.2 dropped strncpy from <linux/string.h> (deprecated in favour of
 * strscpy), but the aic8800 vendor driver still calls it -- always-compiled uses
 * like rwnx_send_dbg_trigger_req(), plus byte-count copies in rwnx_platform.c that
 * rely on strncpy's exact semantics (copy up to n, then NUL-pad). Under GCC 15 the
 * missing declaration is a hard error (-Werror=implicit-function-declaration).
 *
 * Provide a local, self-contained strncpy with the real semantics so no call site
 * needs editing and there is no dependency on a kernel strncpy symbol still
 * existing. Force-included into every driver TU via KCFLAGS (see aic8800.nix). A
 * blanket strncpy->strscpy substitution is NOT equivalent: strscpy stops at the
 * buffer and does not NUL-pad, which would change the platform NVRAM/parse copies.
 */
#ifndef _AIC8800_STRNCPY_COMPAT_H
#define _AIC8800_STRNCPY_COMPAT_H

#include <linux/string.h>
#include <linux/types.h>

#ifdef strncpy
#undef strncpy
#endif

static inline char *strncpy(char *dest, const char *src, size_t n)
{
	size_t i;

	for (i = 0; i < n && src[i] != '\0'; i++)
		dest[i] = src[i];
	for (; i < n; i++)
		dest[i] = '\0';

	return dest;
}

#endif /* _AIC8800_STRNCPY_COMPAT_H */
