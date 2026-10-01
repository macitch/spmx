// A native fixture avoids forking the multithreaded Swift test process.
// Even with a broken runner, alarm bounds its lifetime so the test can fail.
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/types.h>
#include <unistd.h>

int main(int argc, char **argv) {
    if (argc != 2) return 1;
    pid_t child = fork();
    if (child < 0) return 2;
    if (child == 0) {
        if (setsid() < 0) _exit(3);
        signal(SIGTERM, SIG_IGN);
        alarm(8);
        FILE *ready = fopen(argv[1], "w");
        if (!ready) _exit(4);
        fprintf(ready, "%d\n", getpid());
        fclose(ready);
        for (;;) pause();
    }
    // Exit before the child closes either inherited output pipe.
    return 0;
}
