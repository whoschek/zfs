// SPDX-License-Identifier: CDDL-1.0

#include <err.h>
#include <libzfs_core.h>
#include <stdlib.h>
#include <string.h>
#include <sysexits.h>
#include <sys/nvpair.h>

int
main(int argc, char **argv)
{
	int error;
	nvlist_t *bookmarks;

	if (argc < 2)
		errx(EX_USAGE, "usage: %s bookmark ...", argv[0]);

	error = libzfs_core_init();
	if (error != 0)
		errx(EX_OSERR, "libzfs_core_init: %s", strerror(error));

	bookmarks = fnvlist_alloc();
	for (int i = 1; i < argc; i++)
		fnvlist_add_boolean(bookmarks, argv[i]);

	error = lzc_destroy_bookmarks(bookmarks, NULL);
	fnvlist_free(bookmarks);
	libzfs_core_fini();

	if (error != 0)
		errx(EX_OSERR, "lzc_destroy_bookmarks: %s", strerror(error));

	return (EXIT_SUCCESS);
}
