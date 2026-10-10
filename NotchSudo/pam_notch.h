//
//  pam_notch.h
//  NotchSudo
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  The part of the PAM module that talks to NotchHelper, kept separate from
//  the PAM entry points so it can be exercised without installing anything.
//

#ifndef PAM_NOTCH_H
#define PAM_NOTCH_H

#include <stdbool.h>
#include <stddef.h>
#include <sys/types.h>

typedef enum {
    /// Notch recognized the user and they approved.
    NOTCH_ALLOW,
    /// Notch was asked and said no: not recognized, or "Use Password".
    NOTCH_DENY,
    /// Notch couldn't be asked: not running, not set up, or not trusted.
    NOTCH_UNAVAILABLE,
} notch_result;

typedef struct {
    /// The user to recognize, and their home folder (where the socket is).
    uid_t uid;
    const char *home;
    /// The command line shown in the approval prompt.
    const char *command;
    /// The code requirement file; NULL for the installed one.
    const char *requirement_path;
    /// Refuse a requirement file root doesn't own. Always true inside sudo.
    bool require_root_owned_requirement;
    /// Shows a line of text to the user (in the terminal), or NULL.
    void (*info)(void *context, const char *message);
    void *context;
} notch_request;

/// Asks Notch to approve the request. Blocks until it answers, gives up,
/// or a minute passes.
notch_result notch_request_approval(const notch_request *request);

/// This process's command line, as one line of text ("sudo rm -rf build").
void notch_current_command(char *buffer, size_t capacity);

#endif
