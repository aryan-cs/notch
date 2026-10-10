//
//  harness.c
//  pam_notch-tests
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Runs the sudo module's request logic against a fake or real helper and
//  checks the result, without going through sudo or installing anything.
//
//  Usage: harness <home> <requirement file> <expected: allow|deny|unavailable>
//

#include <stdio.h>
#include <string.h>
#include <unistd.h>

#include "pam_notch.h"

static void info(void *context, const char *message) {
    (void)context;
    printf("    (sudo would print: %s)\n", message);
}

int main(int argc, char **argv) {
    if (argc != 4) return 2;
    notch_request request = {
        .uid = getuid(),
        .home = argv[1],
        .command = "sudo true",
        .requirement_path = argv[2],
        .require_root_owned_requirement = false,
        .info = info,
    };
    const char *names[] = { "allow", "deny", "unavailable" };
    const char *got = names[notch_request_approval(&request)];
    if (strcmp(got, argv[3]) != 0) {
        printf("    expected %s, got %s\n", argv[3], got);
        return 1;
    }
    return 0;
}
