#!/bin/sh
#
# objtool wrapper for Linux 7.0+ (CONFIG_X86_KERNEL_IBT).
#
# On IBT kernels objtool always runs on the linked wl.o, ignoring
# OBJECT_FILES_NON_STANDARD. The prebuilt Broadcom blob (lib/wlc_hybrid.o_*)
# then fails with "unannotated intra-function call" and aborts the build.
# We still run the real objtool, but don't let errors from the blob fail it.
#
"$REAL_OBJTOOL" "$@" || {
    echo "objtool-wrapper: ignoring objtool errors from prebuilt Broadcom blob" >&2
    exit 0
}
