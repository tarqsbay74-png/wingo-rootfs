#!/usr/bin/bash

set -e

OUTPUT_FILE="${1:-android_ids.h}"

cat > "$OUTPUT_FILE" <<'EOF'
#ifndef _SYSTEM_IDS_H
#define _SYSTEM_IDS_H

#include <sys/types.h>

struct IdRange {
    id_t start;
    id_t end;
};

static const struct IdRange user_ranges[] = {
};

static const struct IdRange group_ranges[] = {
};

#define user_range_count \
    (sizeof(user_ranges) / sizeof(user_ranges[0]))

#define group_range_count \
    (sizeof(group_ranges) / sizeof(group_ranges[0]))

struct system_id_info {
    const char *name;
    unsigned id;
};

static const struct system_id_info system_ids[] = {
};

#define system_id_count \
    (sizeof(system_ids) / sizeof(system_ids[0]))

#endif
EOF

echo "Generated: $OUTPUT_FILE"