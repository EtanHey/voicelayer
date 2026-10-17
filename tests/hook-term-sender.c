// Fixture-only SIGTERM evidence. Never persist command code or environment values.
#include <fcntl.h>
#ifdef __APPLE__
#include <libproc.h>
#include <sys/sysctl.h>
#endif
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

static char marker[1024], tree_token[128];
static pid_t tree_pid;
static int exit_on_term;
// Only a known interpreter's positional script is eligible. Never scan arguments
// for extensions: option values and inline commands can look exactly like files.
static void script_entrypoint(const char *const *argv, int argc, char *out, size_t capacity) {
    if (argc < 2) return;
    const char *interpreter = strrchr(argv[0], '/');
    interpreter = interpreter ? interpreter + 1 : argv[0];
    int python = !strncmp(interpreter, "python", 6);
    if (python) {
        for (const char *p = interpreter + 6; *p; p++)
            if ((*p < '0' || *p > '9') && *p != '.') return;
    }
    int shell = !strcmp(interpreter, "bash") || !strcmp(interpreter, "sh") || !strcmp(interpreter, "zsh");
    int node = !strcmp(interpreter, "node") || !strcmp(interpreter, "nodejs");
    int bun = !strcmp(interpreter, "bun");
    if (!python && !shell && !node && !bun) return;
    int index = 1;
    if (bun && !strcmp(argv[index], "run")) index++;
    if (index < argc && !strcmp(argv[index], "--")) index++;
    // Flags (including combined -lc, inline -c/-e and flags with values) are
    // intentionally unsupported: uncertainty must never become command logging.
    if (index >= argc || argv[index][0] == '-') return;
    for (const char *p = argv[index]; *p; p++)
        if (!((*p >= 'a' && *p <= 'z') || (*p >= 'A' && *p <= 'Z') ||
              (*p >= '0' && *p <= '9') || *p == '_' || *p == '-' || *p == '.' || *p == '/')) return;
    const char *script = strrchr(argv[index], '/');
    script = script ? script + 1 : argv[index];
    if (!*script) return;
    for (const char *p = script; *p; p++)
        if (!((*p >= 'a' && *p <= 'z') || (*p >= 'A' && *p <= 'Z') ||
              (*p >= '0' && *p <= '9') || *p == '_' || *p == '-' || *p == '.')) return;
    const char *extension = strrchr(script, '.');
    if (!extension || (python && strcmp(extension, ".py")) ||
        (shell && strcmp(extension, ".sh")) ||
        ((node || bun) && strcmp(extension, ".js") && strcmp(extension, ".mjs") &&
         strcmp(extension, ".cjs") && (!bun || (strcmp(extension, ".ts") && strcmp(extension, ".tsx"))))) return;
    if (strlen(script) < capacity) snprintf(out, capacity, "%s", script);
}
static int in_tree(pid_t pid) {
    for (int depth = 0; depth < 64; depth++) {
        if (pid == tree_pid) return 1;
        if (pid <= 1) return 0;
#ifdef __APPLE__
        struct kinfo_proc process;
        size_t size = sizeof(process);
        int mib[] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, pid};
        if (sysctl(mib, 4, &process, &size, NULL, 0) || !size) return -1;
        pid = process.kp_eproc.e_ppid;
#else
        char path[64], row[256];
        snprintf(path, sizeof(path), "/proc/%d/status", pid);
        FILE *status = fopen(path, "r");
        if (!status) return -1;
        int parent = -1;
        while (fgets(row, sizeof(row), status)) if (sscanf(row, "PPid: %d", &parent) == 1) break;
        fclose(status);
        if (parent < 0) return -1;
        pid = parent;
#endif
    }
    return -1;
}
static void received(int signum, siginfo_t *info, void *context) {
    (void)context;
    struct timespec now;
    clock_gettime(CLOCK_REALTIME, &now);
    char executable[1024] = "unknown";
#ifdef __APPLE__
    proc_pidpath(info->si_pid, executable, sizeof(executable));
#else
    char proc[64];
    snprintf(proc, sizeof(proc), "/proc/%d/exe", info->si_pid);
    ssize_t length = readlink(proc, executable, sizeof(executable) - 1);
    if (length >= 0) executable[length] = 0;
#endif
    char entrypoint[256] = "unknown";
    int belongs = in_tree(info->si_pid);
    const char *argv[256];
    int argument_count = 0;
#ifdef __APPLE__
    char arguments[16384];
    size_t argument_size = sizeof(arguments);
    int mib[] = {CTL_KERN, KERN_PROCARGS2, info->si_pid};
    if (sysctl(mib, 3, arguments, &argument_size, NULL, 0) == 0 && argument_size > sizeof(int)) {
        int argc;
        memcpy(&argc, arguments, sizeof(argc));
        size_t offset = sizeof(int);
        while (offset < argument_size && arguments[offset]) offset++;
        while (offset < argument_size && !arguments[offset]) offset++;
        for (int i = 0; i < argc && offset < argument_size; i++) {
            const char *arg = arguments + offset;
            size_t length = strnlen(arg, argument_size - offset);
            if (length == argument_size - offset) break;
            if (argument_count < 256) argv[argument_count++] = arg;
            offset += length + 1;
        }
        // Inherited identity also catches our own
        while (offset < argument_size && arguments[offset]) {
            const char *env = arguments + offset;
            size_t length = strnlen(env, argument_size - offset);
            if (length == argument_size - offset) break;
            if (strncmp(env, "HOOK_TREE_TOKEN=", 16) == 0 && strcmp(env + 16, tree_token) == 0) belongs = 1;
            offset += length + 1;
        }
    }
#else
    char path[64], environment[16384];
    snprintf(path, sizeof(path), "/proc/%d/environ", info->si_pid);
    int env_fd = open(path, O_RDONLY);
    ssize_t data_size = env_fd < 0 ? -1 : read(env_fd, environment, sizeof(environment));
    if (env_fd >= 0) close(env_fd);
    for (ssize_t offset = 0; offset < data_size;) {
        size_t length = strnlen(environment + offset, data_size - offset);
        if (length == (size_t)(data_size - offset)) break;
        if (strncmp(environment + offset, "HOOK_TREE_TOKEN=", 16) == 0 && strcmp(environment + offset + 16, tree_token) == 0) belongs = 1;
        offset += length + 1;
    }
    if ((data_size < 0 || data_size == (ssize_t)sizeof(environment)) && belongs == 0) belongs = -1;
    snprintf(path, sizeof(path), "/proc/%d/cmdline", info->si_pid);
    int cmd_fd = open(path, O_RDONLY);
    data_size = cmd_fd < 0 ? -1 : read(cmd_fd, environment, sizeof(environment));
    if (cmd_fd >= 0) close(cmd_fd);
    for (ssize_t offset = 0; offset < data_size;) {
        const char *arg = environment + offset;
        size_t length = strnlen(arg, data_size - offset);
        if (length == (size_t)(data_size - offset)) break;
        if (argument_count < 256) argv[argument_count++] = arg;
        offset += length + 1;
    }
#endif
    script_entrypoint(argv, argument_count, entrypoint, sizeof(entrypoint));
    char row[2048];
    int size = snprintf(row, sizeof(row),
        "time_ns=%lld receiver_pid=%d parent_pid=%d sender_pid=%d sender_uid=%d signal=%d sender_executable=%s sender_entrypoint=%s sender_in_run=%d\n",
        (long long)now.tv_sec * 1000000000LL + now.tv_nsec,
        getpid(), getppid(), info->si_pid, info->si_uid, signum, executable, entrypoint, belongs);
    int fd = open(marker, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW, 0600);
    if (fd >= 0) {
        if (size > 0 && size < (int)sizeof(row)) write(fd, row, size);
        close(fd);
    }
    if (exit_on_term && belongs == 1) _exit(128 + signum);
}
int hook_term_sender(const char *path, int owner, const char *token, int terminate) {
    if (strlen(path) >= sizeof(marker) || strlen(token) >= sizeof(tree_token) || owner <= 1 || !*token) return -1;
    strcpy(marker, path);
    strcpy(tree_token, token);
    tree_pid = owner;
    exit_on_term = terminate;
    struct sigaction action = {0};
    action.sa_sigaction = received;
    action.sa_flags = SA_SIGINFO;
    sigemptyset(&action.sa_mask);
    return sigaction(SIGTERM, &action, NULL);
}
