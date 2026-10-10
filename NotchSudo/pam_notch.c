//
//  pam_notch.c
//  NotchSudo
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  A PAM module that lets Face Unlock approve sudo. When Face Unlock for
//  sudo is turned on, /etc/pam.d/sudo_local lists this module first, and
//  sudo calls it before asking for a password.
//
//  The module asks NotchHelper, over a Unix socket in the user's
//  Application Support folder, to have Notch recognize the user. It only
//  succeeds when the helper says "allow", and only after checking that the
//  process on the other end of the socket really is NotchHelper, by its
//  code signature. Everything else (Notch not running, a socket someone
//  else put there, a timeout) returns PAM_IGNORE, so sudo goes on to the
//  usual password prompt.
//
//  This runs inside sudo as root, so it's deliberately small and careful:
//  every buffer is bounded, every failure falls through to the password,
//  and nothing here can stop sudo from working.
//

#include <errno.h>
#include <poll.h>
#include <pwd.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <sys/time.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>

#define PAM_SM_AUTH
#include <security/pam_appl.h>
#include <security/pam_modules.h>
#include <security/openpam.h>

#include "pam_notch.h"

/// Where NotchHelper listens, relative to the user's home folder.
static const char *const kSocketPath = "Library/Application Support/theboringteam.boringnotch/sudo.sock";
/// The code requirement NotchHelper must satisfy, written when the user
/// turns the feature on.
static const char *const kRequirementPath = "/usr/local/etc/notch-sudo.requirement";

/// Long enough for a face scan plus time to confirm, short enough that a
/// stuck helper can't hold sudo for long.
static const int kTimeoutSeconds = 60;

// MARK: - Small helpers

static double now_seconds(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
}

/// Reads a small text file. With `require_root_owned`, the file must be a
/// regular file owned by root that no one else can write, since whoever
/// controls it decides which program sudo trusts.
static char *read_requirement(const char *path, bool require_root_owned) {
    struct stat st;
    if (lstat(path, &st) != 0 || !S_ISREG(st.st_mode) || st.st_size <= 0 || st.st_size > 4096) {
        return NULL;
    }
    if (require_root_owned && (st.st_uid != 0 || (st.st_mode & (S_IWGRP | S_IWOTH)) != 0)) {
        return NULL;
    }
    FILE *file = fopen(path, "r");
    if (file == NULL) {
        return NULL;
    }
    char *text = calloc(1, (size_t)st.st_size + 1);
    size_t length = text ? fread(text, 1, (size_t)st.st_size, file) : 0;
    fclose(file);
    if (text == NULL || length == 0) {
        free(text);
        return NULL;
    }
    text[length] = '\0';
    while (length > 0 && (text[length - 1] == '\n' || text[length - 1] == ' ')) {
        text[--length] = '\0';
    }
    return text;
}

/// Whether the socket's peer is the program the requirement describes,
/// checked through the kernel's audit token for that process, so it can't
/// be faked by whoever created the socket file.
static bool peer_satisfies_requirement(int fd, uid_t uid, const char *requirement_text) {
    struct xucred cred;
    socklen_t cred_length = sizeof(cred);
    if (getsockopt(fd, SOL_LOCAL, LOCAL_PEERCRED, &cred, &cred_length) != 0 || cred.cr_uid != uid) {
        return false;
    }
    audit_token_t token;
    socklen_t token_length = sizeof(token);
    if (getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &token_length) != 0) {
        return false;
    }

    bool satisfied = false;
    CFStringRef text = CFStringCreateWithCString(NULL, requirement_text, kCFStringEncodingUTF8);
    SecRequirementRef requirement = NULL;
    CFDataRef token_data = CFDataCreate(NULL, (const UInt8 *)&token, sizeof(token));
    CFDictionaryRef attributes = NULL;
    SecCodeRef code = NULL;

    if (text && token_data &&
        SecRequirementCreateWithString(text, kSecCSDefaultFlags, &requirement) == errSecSuccess) {
        const void *keys[] = { kSecGuestAttributeAudit };
        const void *values[] = { token_data };
        attributes = CFDictionaryCreate(NULL, keys, values, 1,
                                        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        if (attributes &&
            SecCodeCopyGuestWithAttributes(NULL, attributes, kSecCSDefaultFlags, &code) == errSecSuccess) {
            satisfied = SecCodeCheckValidity(code, kSecCSDefaultFlags, requirement) == errSecSuccess;
        }
    }

    if (code) CFRelease(code);
    if (attributes) CFRelease(attributes);
    if (requirement) CFRelease(requirement);
    if (token_data) CFRelease(token_data);
    if (text) CFRelease(text);
    return satisfied;
}

static bool write_all(int fd, const char *data, size_t length) {
    while (length > 0) {
        ssize_t written = write(fd, data, length);
        if (written < 0 && errno == EINTR) continue;
        if (written <= 0) return false;
        data += written;
        length -= (size_t)written;
    }
    return true;
}

/// Reads one line (without its newline) before `deadline`. False on
/// timeout, error or end of file. A signal (Control-C, if sudo catches it)
/// also stops the wait, so sudo moves on to the password straight away.
static bool read_line(int fd, char *line, size_t capacity, double deadline) {
    size_t length = 0;
    while (length + 1 < capacity) {
        int remaining_ms = (int)((deadline - now_seconds()) * 1000);
        if (remaining_ms <= 0) return false;
        struct pollfd pfd = { .fd = fd, .events = POLLIN };
        int ready = poll(&pfd, 1, remaining_ms);
        if (ready <= 0) return false;
        char c;
        ssize_t got = read(fd, &c, 1);
        if (got < 0 && errno == EINTR) continue;
        if (got <= 0) return false;
        if (c == '\n') {
            line[length] = '\0';
            return true;
        }
        line[length++] = c;
    }
    return false;
}

// MARK: - The request

notch_result notch_request_approval(const notch_request *request) {
    char path[sizeof(((struct sockaddr_un *)0)->sun_path)];
    int printed = snprintf(path, sizeof(path), "%s/%s", request->home, kSocketPath);
    if (printed < 0 || (size_t)printed >= sizeof(path)) {
        return NOTCH_UNAVAILABLE;
    }

    const char *requirement_path = request->requirement_path ? request->requirement_path : kRequirementPath;
    char *requirement = read_requirement(requirement_path, request->require_root_owned_requirement);
    if (requirement == NULL) {
        return NOTCH_UNAVAILABLE;
    }

    notch_result result = NOTCH_UNAVAILABLE;
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) {
        free(requirement);
        return NOTCH_UNAVAILABLE;
    }
    int on = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof(on));

    struct sockaddr_un address = { .sun_family = AF_UNIX };
    strlcpy(address.sun_path, path, sizeof(address.sun_path));
    if (connect(fd, (struct sockaddr *)&address, sizeof(address)) != 0) {
        goto done;
    }
    if (!peer_satisfies_requirement(fd, request->uid, requirement)) {
        goto done;
    }

    // The request: a version line, then the command on one line.
    char message[1100];
    printed = snprintf(message, sizeof(message), "notch-sudo 1\n%s\n", request->command ? request->command : "sudo");
    if (printed < 0 || !write_all(fd, message, strlen(message))) {
        goto done;
    }

    double deadline = now_seconds() + kTimeoutSeconds;
    char line[64];
    while (read_line(fd, line, sizeof(line), deadline)) {
        if (strcmp(line, "scanning") == 0) {
            if (request->info) request->info(request->context, "Notch: look at the camera to approve, or wait for the password prompt.");
        } else if (strcmp(line, "allow") == 0) {
            result = NOTCH_ALLOW;
            break;
        } else if (strcmp(line, "deny") == 0) {
            result = NOTCH_DENY;
            break;
        }
    }

done:
    close(fd);
    free(requirement);
    return result;
}

void notch_current_command(char *buffer, size_t capacity) {
    if (capacity == 0) return;
    strlcpy(buffer, "sudo", capacity);

    int max_args = 0;
    size_t size = sizeof(max_args);
    int argmax_mib[] = { CTL_KERN, KERN_ARGMAX };
    if (sysctl(argmax_mib, 2, &max_args, &size, NULL, 0) != 0 || max_args <= 0) return;

    char *args = malloc((size_t)max_args);
    if (args == NULL) return;
    size = (size_t)max_args;
    int mib[] = { CTL_KERN, KERN_PROCARGS2, getpid() };
    if (sysctl(mib, 3, args, &size, NULL, 0) != 0 || size < sizeof(int)) {
        free(args);
        return;
    }

    // Layout: argc, the executable path, padding NULs, then argv.
    int argc;
    memcpy(&argc, args, sizeof(argc));
    char *cursor = args + sizeof(argc);
    char *end = args + size;
    while (cursor < end && *cursor != '\0') cursor++;   // executable path
    while (cursor < end && *cursor == '\0') cursor++;   // padding

    size_t length = 0;
    buffer[0] = '\0';
    for (int i = 0; i < argc && cursor < end; i++) {
        char *argument = cursor;
        while (cursor < end && *cursor != '\0') cursor++;
        if (i == 0) {
            // Show "sudo", not the full path it was started with.
            char *slash = strrchr(argument, '/');
            if (slash) argument = slash + 1;
        }
        for (const char *c = (i > 0) ? " " : ""; *c && length + 1 < capacity; c++) buffer[length++] = *c;
        for (char *c = argument; c < cursor && *c && length + 1 < capacity; c++) {
            // One line on the wire: control characters become spaces.
            buffer[length++] = ((unsigned char)*c < 0x20 || *c == 0x7f) ? ' ' : *c;
        }
        cursor++;
    }
    buffer[length] = '\0';
    if (length == 0) strlcpy(buffer, "sudo", capacity);
    free(args);
}

// MARK: - PAM entry points

static void pam_info_message(void *context, const char *message) {
    pam_info((pam_handle_t *)context, "%s", message);
}

PAM_EXTERN int pam_sm_authenticate(pam_handle_t *pamh, int flags, int argc, const char *argv[]) {
    (void)argc;
    (void)argv;

    const char *user = NULL;
    if (pam_get_user(pamh, &user, NULL) != PAM_SUCCESS || user == NULL) {
        return PAM_IGNORE;
    }
    struct passwd pwd;
    struct passwd *found = NULL;
    char storage[4096];
    if (getpwnam_r(user, &pwd, storage, sizeof(storage), &found) != 0 || found == NULL) {
        return PAM_IGNORE;
    }
    // Only when you're proving you are you: the person running sudo has to
    // be the account being authenticated (not root's or a target user's
    // password, as with sudo's rootpw or targetpw options).
    if (getuid() != pwd.pw_uid || pwd.pw_dir == NULL) {
        return PAM_IGNORE;
    }

    char command[1024];
    notch_current_command(command, sizeof(command));

    notch_request request = {
        .uid = pwd.pw_uid,
        .home = pwd.pw_dir,
        .command = command,
        .requirement_path = NULL,
        .require_root_owned_requirement = true,
        .info = (flags & PAM_SILENT) ? NULL : pam_info_message,
        .context = pamh,
    };
    switch (notch_request_approval(&request)) {
    case NOTCH_ALLOW:
        return PAM_SUCCESS;
    case NOTCH_DENY:
        return PAM_AUTH_ERR;
    case NOTCH_UNAVAILABLE:
        return PAM_IGNORE;
    }
    return PAM_IGNORE;
}

PAM_EXTERN int pam_sm_setcred(pam_handle_t *pamh, int flags, int argc, const char *argv[]) {
    (void)pamh;
    (void)flags;
    (void)argc;
    (void)argv;
    return PAM_SUCCESS;
}
