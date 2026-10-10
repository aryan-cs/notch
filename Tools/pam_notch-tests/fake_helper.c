//
//  fake_helper.c
//  pam_notch-tests
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Stands in for NotchHelper: listens on the socket path it's given and
//  answers one request the way the mode says. Gives up after a few seconds
//  if nobody connects, since the module refusing to talk to it is one of
//  the outcomes being tested.
//
//  Usage: fake_helper <socket path> allow|deny|garbage
//

#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

int main(int argc, char **argv) {
    if (argc != 3) return 2;
    const char *path = argv[1];
    const char *mode = argv[2];
    alarm(5);
    unlink(path);
    int listener = socket(AF_UNIX, SOCK_STREAM, 0);
    struct sockaddr_un address = { .sun_family = AF_UNIX };
    strlcpy(address.sun_path, path, sizeof(address.sun_path));
    if (bind(listener, (struct sockaddr *)&address, sizeof(address)) != 0 || listen(listener, 1) != 0) {
        perror("fake_helper");
        return 1;
    }
    int client = accept(listener, NULL, NULL);
    char request[2048];
    ssize_t length = read(client, request, sizeof(request) - 1);
    (void)length;
    const char *reply = "scanning\nallow\n";
    if (strcmp(mode, "deny") == 0) reply = "scanning\ndeny\n";
    if (strcmp(mode, "garbage") == 0) reply = "this line is far too long for the module to accept as an answer, so it gives up\n";
    write(client, reply, strlen(reply));
    sleep(1);
    close(client);
    close(listener);
    unlink(path);
    return 0;
}
