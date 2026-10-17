// Injected ONLY into the isolated QA app. Never linked into VoiceBar/release.
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <CoreAudio/CoreAudio.h>
#import <objc/runtime.h>
#include <spawn.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdlib.h>
#include <string.h>

static int active;
static void receipt(const char *event) {
    const char *path = getenv("VOICEBAR_UIE2E_GUARD_RECEIPT");
    if (!path) _exit(87);
    int fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0600);
    if (fd < 0) _exit(87);
    dprintf(fd, "%s\n", event);
    close(fd);
}
__attribute__((noreturn)) static void trip(const char *event) {
    receipt(event);
    dprintf(STDERR_FILENO, "QA DEVICE TRIPWIRE: %s\n", event);
    _exit(86);
}
static id forbidden(id receiver, SEL selector, ...) {
    trip(sel_getName(selector));
}
static void hook(Class cls, const char *name, int classMethod) {
    Method method = classMethod ? class_getClassMethod(cls, sel_registerName(name))
                               : class_getInstanceMethod(cls, sel_registerName(name));
    if (!method) trip("missing-required-objc-tripwire");
    method_setImplementation(method, (IMP)forbidden);
}
__attribute__((constructor)) static void install(void) {
    if (!getenv("VOICEBAR_UIE2E_GUARD_RECEIPT")) return;
    // An allowed mute-check child inherits DYLD settings; never guard another app.
    if (strcmp(getprogname(), "VoiceBar") && strcmp(getprogname(), "device-guard-probe")) return;
    hook([AVAudioEngine class], "init", 0);
    hook([AVAudioEngine class], "inputNode", 0);
    hook([AVAudioEngine class], "prepare", 0);
    hook([AVAudioEngine class], "startAndReturnError:", 0);
    hook([AVCaptureDevice class], "requestAccessForMediaType:completionHandler:", 1);
    hook([AVCaptureDevice class], "defaultDeviceWithMediaType:", 1);
    hook([AVCaptureDevice class], "devicesWithMediaType:", 1);
    active = 1;
    receipt("voicebar-no-device-guard-v1:installed");
}
// The QA Swift host requires this before building any model or panel.
int voicebar_no_device_guard_version(void) { return active ? 1 : 0; }

#define INTERPOSE(replacement, original) \
  __attribute__((used)) static struct { const void *replacement; const void *original; } \
  interpose_##original __attribute__((section("__DATA,__interpose"))) = \
    { (const void *)&replacement, (const void *)&original };

static OSStatus guardedDeviceStart(AudioDeviceID device, AudioDeviceIOProcID proc) {
    if (active) trip("AudioDeviceStart");
    return AudioDeviceStart(device, proc);
}
INTERPOSE(guardedDeviceStart, AudioDeviceStart)
static OSStatus guardedOutputStart(AudioUnit unit) {
    if (active) trip("AudioOutputUnitStart");
    return AudioOutputUnitStart(unit);
}
INTERPOSE(guardedOutputStart, AudioOutputUnitStart)
static OSStatus guardedUnitInitialize(AudioUnit unit) {
    if (active) trip("AudioUnitInitialize");
    return AudioUnitInitialize(unit);
}
INTERPOSE(guardedUnitInitialize, AudioUnitInitialize)
static OSStatus guardedGet(AudioObjectID obj, const AudioObjectPropertyAddress *addr,
    UInt32 qualifierSize, const void *qualifier, UInt32 *size, void *data) {
    if (active) trip("AudioObjectGetPropertyData");
    return AudioObjectGetPropertyData(obj, addr, qualifierSize, qualifier, size, data);
}
INTERPOSE(guardedGet, AudioObjectGetPropertyData)
static OSStatus guardedSize(AudioObjectID obj, const AudioObjectPropertyAddress *addr,
    UInt32 qualifierSize, const void *qualifier, UInt32 *size) {
    if (active) trip("AudioObjectGetPropertyDataSize");
    return AudioObjectGetPropertyDataSize(obj, addr, qualifierSize, qualifier, size);
}
INTERPOSE(guardedSize, AudioObjectGetPropertyDataSize)
static OSStatus guardedSet(AudioObjectID obj, const AudioObjectPropertyAddress *addr,
    UInt32 qualifierSize, const void *qualifier, UInt32 size, const void *data) {
    if (active) trip("AudioObjectSetPropertyData");
    return AudioObjectSetPropertyData(obj, addr, qualifierSize, qualifier, size, data);
}
INTERPOSE(guardedSet, AudioObjectSetPropertyData)
static int muteCheck(const char *path, char *const argv[]) {
    return path && !strcmp(path, "/usr/bin/osascript") && argv && argv[0] && argv[1] && argv[2]
        && !argv[3] && !strcmp(argv[1], "-e")
        && !strcmp(argv[2], "output muted of (get volume settings)");
}
static int guardedSpawn(pid_t *pid, const char *path, const posix_spawn_file_actions_t *actions,
    const posix_spawnattr_t *attr, char *const argv[], char *const env[]) {
    if (active && !muteCheck(path, argv)) trip("posix_spawn");
    return posix_spawn(pid, path, actions, attr, argv, env);
}
INTERPOSE(guardedSpawn, posix_spawn)
static int guardedSpawnp(pid_t *pid, const char *path, const posix_spawn_file_actions_t *actions,
    const posix_spawnattr_t *attr, char *const argv[], char *const env[]) {
    if (active) trip("posix_spawnp");
    return posix_spawnp(pid, path, actions, attr, argv, env);
}
INTERPOSE(guardedSpawnp, posix_spawnp)
static int guardedExec(const char *path, char *const argv[], char *const env[]) {
    if (active) trip("execve");
    return execve(path, argv, env);
}
INTERPOSE(guardedExec, execve)
