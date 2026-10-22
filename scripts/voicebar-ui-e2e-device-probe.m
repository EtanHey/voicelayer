// Negative probes run with the guard BEFORE any actual device API can execute.
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <CoreAudio/CoreAudio.h>
#include <spawn.h>
#include <unistd.h>
#include <string.h>
#include <dlfcn.h>
extern char **environ;
int main(int argc, char **argv) {
    int (*version)(void) = dlsym(RTLD_DEFAULT, "voicebar_no_device_guard_version");
    if (!version || version() != 1 || argc != 2) return 87;
    const char *op = argv[1];
    if (!strcmp(op, "init")) (void)[[AVAudioEngine alloc] init];
    else if (!strcmp(op, "inputNode")) (void)[[AVAudioEngine alloc] inputNode];
    else if (!strcmp(op, "prepare")) [[AVAudioEngine alloc] prepare];
    else if (!strcmp(op, "startAndReturnError:")) [[AVAudioEngine alloc] startAndReturnError:nil];
    else if (!strcmp(op, "requestAccessForMediaType:completionHandler:"))
        [AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio completionHandler:^(BOOL granted) {}];
    else if (!strcmp(op, "defaultDeviceWithMediaType:")) (void)[AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeAudio];
    else if (!strcmp(op, "devicesWithMediaType:")) (void)[AVCaptureDevice devicesWithMediaType:AVMediaTypeAudio];
    else if (!strcmp(op, "AudioDeviceStart")) AudioDeviceStart(0, NULL);
    else if (!strcmp(op, "AudioOutputUnitStart")) AudioOutputUnitStart(NULL);
    else if (!strcmp(op, "AudioUnitInitialize")) AudioUnitInitialize(NULL);
    else if (!strcmp(op, "AudioObjectGetPropertyData")) AudioObjectGetPropertyData(0, NULL, 0, NULL, NULL, NULL);
    else if (!strcmp(op, "AudioObjectGetPropertyDataSize")) AudioObjectGetPropertyDataSize(0, NULL, 0, NULL, NULL);
    else if (!strcmp(op, "AudioObjectSetPropertyData")) AudioObjectSetPropertyData(0, NULL, 0, NULL, 0, NULL);
    else if (!strcmp(op, "posix_spawn") || !strcmp(op, "posix_spawnp")) {
        pid_t pid; char *args[] = {"/usr/bin/false", NULL};
        if (!strcmp(op, "posix_spawn")) posix_spawn(&pid, args[0], NULL, NULL, args, environ);
        else posix_spawnp(&pid, args[0], NULL, NULL, args, environ);
    } else if (!strcmp(op, "execve")) {
        char *args[] = {"/usr/bin/false", NULL}; execve(args[0], args, environ);
    } else if (!strcmp(op, "NSTask")) {
        NSTask *task = [NSTask new]; task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/false"];
        [task launchAndReturnError:nil]; [task waitUntilExit];
    } else if (!strcmp(op, "mute-check")) {
        NSTask *task = [NSTask new]; task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/osascript"];
        task.arguments = @[@"-e", @"output muted of (get volume settings)"];
        if (![task launchAndReturnError:nil]) return 89;
        [task waitUntilExit]; return task.terminationStatus;
    } else return 87;
    return 88; // Every invoked path must exit through the tripwire, never return.
}
