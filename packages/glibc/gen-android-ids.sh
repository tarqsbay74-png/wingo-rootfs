#!/usr/bin/bash

set -e

OUTPUT_FILE="$GITHUB_WORKSPACE/packages/glibc/glibc-2.44/nss/android_ids.h"
READ_FILE="$GITHUB_WORKSPACE/packages/glibc/android_system_user_ids.h"

cat > "$OUTPUT_FILE" <<EOF
#ifndef _ANDROID_IDS
#define _ANDROID_IDS

#include "android_system_user_ids.h"

#define AID_USER_OFFSET 100000
#define AID_OVERFLOWUID 65534
#define AID_ISOLATED_START 99000
#define AID_ISOLATED_END 99999
#define AID_APP_START 10000
#define AID_APP_END 19999
#define AID_CACHE_GID_START 20000
#define AID_CACHE_GID_END 29999
#define AID_EXT_GID_START 30000
#define AID_EXT_GID_END 39999
#define AID_EXT_CACHE_GID_START 40000
#define AID_EXT_CACHE_GID_END 49999
#define AID_SHARED_GID_START 50000
#define AID_SHARED_GID_END 59999

#define AID_OEM_RESERVED_START 2900
#define AID_OEM_RESERVED_END 2999
#define AID_OEM_RESERVED_2_START 5000
#define AID_OEM_RESERVED_2_END 5999

struct IdRange {
    id_t start;
    id_t end;
};

static struct IdRange user_ranges[] = {
    { AID_APP_START, AID_APP_END },
    { AID_ISOLATED_START, AID_ISOLATED_END },
};

static struct IdRange group_ranges[] = {
    { AID_APP_START, AID_APP_END },
    { AID_CACHE_GID_START, AID_CACHE_GID_END },
    { AID_EXT_GID_START, AID_EXT_GID_END },
    { AID_EXT_CACHE_GID_START, AID_EXT_CACHE_GID_END },
    { AID_SHARED_GID_START, AID_SHARED_GID_END },
    { AID_ISOLATED_START, AID_ISOLATED_END },
};

struct android_id_info {
    const char *name;
    unsigned aid;
};

static struct android_id_info android_ids[] = {
EOF

awk '{printf "    { \"" $2 "\", " $2 ", },\n"}' "$READ_FILE" |
    sed -e 's/"AID_\(.*\)"/"\L\1"/' >> "$OUTPUT_FILE"

cat >> "$OUTPUT_FILE" <<'EOF'

};

#define android_id_count \
    (sizeof(android_ids) / sizeof(android_ids[0]))

#define APP_HOME_DIR "/home"
#define APP_PREFIX_DIR "/usr"

#endif
EOF