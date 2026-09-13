// SPDX-License-Identifier: GPL-3.0-only
#include <assert.h>
#include <stdio.h>
#include "types/pointer_enter_serial.h"

int main(void) {
    struct pointer_enter_serials history = {0};
    assert(!pointer_enter_serials_validate(&history, 0, 0));
    pointer_enter_serials_record(&history, UINT32_MAX - 1);
    pointer_enter_serials_record(&history, UINT32_MAX - 1);
    assert(history.count == 1); // one enter sent to several pointer resources
    pointer_enter_serials_record(&history, 1);
    assert(pointer_enter_serials_validate(&history, UINT32_MAX - 1, 2));
    assert(pointer_enter_serials_validate(&history, 1, 2));
    assert(!pointer_enter_serials_validate(&history, 2, 2)); // non-enter event
    assert(!pointer_enter_serials_validate(&history, 1, 0)); // future
    assert(!pointer_enter_serials_validate(&history, 1, UINT32_C(0x80000001)));
    for (uint32_t i = 3; i <= 129; i += 2) pointer_enter_serials_record(&history, i);
    assert(history.count == 64);
    assert(!pointer_enter_serials_validate(&history, 1, 130)); // evicted
    for (uint32_t i = 3; i <= 129; i++) {
        assert(pointer_enter_serials_validate(&history, i, 130) == (i % 2 == 1));
    }
    puts("PASS exact pointer enter history: duplicates, wrap, age, eviction, event provenance");
}
