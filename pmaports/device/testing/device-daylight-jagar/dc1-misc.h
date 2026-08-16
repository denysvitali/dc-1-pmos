/* dc1-misc.h -- shared, fail-closed resolution of the DC-1 `misc` partition,
 * plus the two tiny string helpers every device tool needs.
 *
 * Extracted from dc1-reboot-fastboot.c so that it and dc1-slotctl.c use the
 * same PARTNAME=misc resolver (rule 19: one safety invariant, not one per
 * tool). `misc` holds the bootloader_control block that decides the A/B slot;
 * a wrong write there makes BOTH slots unbootable, so resolving it by GPT name
 * -- required unique, required small -- is what keeps a moved mapping from
 * pointing the write at something boot-critical.
 *
 * Test hooks, same spirit as partlib.sh: DC1_SYSBLOCK overrides
 * /sys/class/block and DC1_DEVDIR overrides /dev.
 */
#ifndef DC1_MISC_H
#define DC1_MISC_H

#include <stddef.h>

/* Real misc is well under a megabyte. A big device under PARTNAME=misc means
 * the mapping is not what we think it is, and the next write would land in
 * something that matters. 16 MiB in 512-byte sectors. */
#define DC1_MISC_MAX_SECTORS	32768UL

/* env var value or fallback, with an empty string treated as unset. */
const char *dc1_env_or(const char *name, const char *fallback);

/* snprintf that treats truncation as an error (a silently shortened device
 * name would name a different partition). */
int dc1_fmt(char *dst, size_t n, const char *f, const char *a, const char *b);

/* Resolve PARTNAME=misc to a /dev path. Returns 0 and fills out on success,
 * -1 (with a diagnostic on stderr) otherwise. out must hold at least PATH_MAX
 * bytes. */
int dc1_resolve_misc(char *out, size_t n);

#endif /* DC1_MISC_H */
