#include "nixbadge_utils.h"

#include <sys/time.h>
#include <time.h>

int64_t nixbadge_ts() {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return (tv.tv_sec * 1000LL + (tv.tv_usec / 1000LL));
}
