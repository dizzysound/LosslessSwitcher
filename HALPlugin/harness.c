// Loads LSOutput.driver in-process and exercises its AudioServerPlugInDriverInterface with a fake
// host, so the plug-in can be checked before it is installed into coreaudiod.
// Build: clang -O1 -o harness harness.c -framework CoreAudio -framework CoreFoundation
#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach_time.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <dlfcn.h>
#include <math.h>
#include <dispatch/dispatch.h>

static int gFail = 0;
#define CHECK(c, ...) do { if(!(c)) { printf("FAIL: " __VA_ARGS__); printf("\n"); gFail++; } else { printf("ok: " __VA_ARGS__); printf("\n"); } } while(0)

static UInt64 gRequestedChange = 0;
static OSStatus H_PropertiesChanged(AudioServerPlugInHostRef h, AudioObjectID o, UInt32 n, const AudioObjectPropertyAddress* a) { return 0; }
static OSStatus H_Copy(AudioServerPlugInHostRef h, CFStringRef k, CFPropertyListRef* d) { *d = NULL; return 0; }
static OSStatus H_Write(AudioServerPlugInHostRef h, CFStringRef k, CFPropertyListRef d) { return 0; }
static OSStatus H_Delete(AudioServerPlugInHostRef h, CFStringRef k) { return 0; }
static OSStatus H_Request(AudioServerPlugInHostRef h, AudioObjectID d, UInt64 action, void* info) { gRequestedChange = action; return 0; }
static AudioServerPlugInHostInterface gHost = { H_PropertiesChanged, H_Copy, H_Write, H_Delete, H_Request };

enum { kDev = 3, kIn = 4, kOut = 8 };

static double gTicksPerSec;

int main(int argc, char** argv)
{
    mach_timebase_info_data_t tb; mach_timebase_info(&tb);
    gTicksPerSec = 1e9 * tb.denom / tb.numer;
    const char* path = argc > 1 ? argv[1] : "LSOutput.driver";
    char exe[1024]; snprintf(exe, sizeof exe, "%s/Contents/MacOS/LSOutput", path);
    void* lib = dlopen(exe, RTLD_NOW | RTLD_LOCAL);
    CHECK(lib != NULL, "bundle loads (%s)", lib ? "" : dlerror());
    if(!lib) return 1;
    void* (*factory)(CFAllocatorRef, CFUUIDRef) = dlsym(lib, "LSOutput_Create");
    CHECK(factory != NULL, "factory LSOutput_Create found");
    AudioServerPlugInDriverRef drv = factory(NULL, kAudioServerPlugInTypeUUID);
    CHECK(drv != NULL, "driver ref");
    AudioServerPlugInDriverInterface* I = *drv;
    CHECK(I->Initialize(drv, &gHost) == 0, "Initialize");

    AudioObjectPropertyAddress a = { kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    CFStringRef name = NULL; UInt32 sz = sizeof(name);
    CHECK(I->GetPropertyData(drv, kDev, 0, &a, 0, NULL, sz, &sz, &name) == 0, "device name");
    char buf[256] = ""; if(name) CFStringGetCString(name, buf, sizeof buf, kCFStringEncodingUTF8);
    printf("   name = %s\n", buf);

    a.mSelector = kAudioDevicePropertyAvailableNominalSampleRates;
    CHECK(I->GetPropertyDataSize(drv, kDev, 0, &a, 0, NULL, &sz) == 0 && sz == 6 * sizeof(AudioValueRange), "6 rates (size %u)", sz);
    AudioValueRange rates[8]; I->GetPropertyData(drv, kDev, 0, &a, 0, NULL, sz, &sz, rates);
    printf("   rates:"); for(UInt32 i = 0; i < sz / sizeof(AudioValueRange); i++) printf(" %.0f", rates[i].mMinimum); printf("\n");

    a.mSelector = kAudioStreamPropertyAvailablePhysicalFormats;
    CHECK(I->GetPropertyDataSize(drv, kOut, 0, &a, 0, NULL, &sz) == 0 && sz == 6 * sizeof(AudioStreamRangedDescription), "6 stream formats");
    AudioStreamRangedDescription fm[6]; I->GetPropertyData(drv, kOut, 0, &a, 0, NULL, sz, &sz, fm);
    CHECK(fm[5].mFormat.mSampleRate == 192000 && fm[5].mFormat.mChannelsPerFrame == 2 && fm[5].mFormat.mBytesPerFrame == 8, "output format 6 is 192k 2ch");
    I->GetPropertyData(drv, kIn, 0, &a, 0, NULL, sz, &sz, fm);
    CHECK(fm[0].mFormat.mChannelsPerFrame == 4 && fm[0].mFormat.mBytesPerFrame == 16, "input formats are 4ch (1-2 Music, 3-4 others)");
    {
        AudioStreamBasicDescription vf; UInt32 vz = sizeof vf; AudioObjectPropertyAddress va = { kAudioStreamPropertyVirtualFormat, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
        I->GetPropertyData(drv, kIn, 0, &va, 0, NULL, vz, &vz, &vf); UInt32 inCh = vf.mChannelsPerFrame;
        I->GetPropertyData(drv, kOut, 0, &va, 0, NULL, vz, &vz, &vf);
        CHECK(inCh == 4 && vf.mChannelsPerFrame == 2, "virtual formats: input %u ch, output %u ch", inCh, vf.mChannelsPerFrame);
        AudioObjectPropertyAddress la = { kAudioDevicePropertyPreferredChannelLayout, kAudioObjectPropertyScopeInput, kAudioObjectPropertyElementMain };
        UInt32 lz = 0; I->GetPropertyDataSize(drv, kDev, 0, &la, 0, NULL, &lz);
        char lb[256]; UInt32 lz2 = sizeof lb; I->GetPropertyData(drv, kDev, 0, &la, 0, NULL, lz2, &lz2, lb);
        UInt32 inN = ((AudioChannelLayout*)lb)->mNumberChannelDescriptions;
        la.mScope = kAudioObjectPropertyScopeOutput; lz2 = sizeof lb; I->GetPropertyData(drv, kDev, 0, &la, 0, NULL, lz2, &lz2, lb);
        CHECK(inN == 4 && ((AudioChannelLayout*)lb)->mNumberChannelDescriptions == 2 && lz == lz2 + 2 * sizeof(AudioChannelDescription), "channel layouts: input %u, output %u", inN, ((AudioChannelLayout*)lb)->mNumberChannelDescriptions);
    }

    a.mSelector = kAudioDevicePropertyIcon;
    CHECK(!I->HasProperty(drv, kDev, 0, &a), "no icon advertised");

    a.mSelector = kAudioObjectPropertyCustomPropertyInfoList;
    CHECK(I->HasProperty(drv, kDev, 0, &a), "custom property list");
    AudioServerPlugInCustomPropertyInfo ci[6]; sz = 0; I->GetPropertyDataSize(drv, kDev, 0, &a, 0, NULL, &sz);
    CHECK(sz == sizeof ci && (I->GetPropertyData(drv, kDev, 0, &a, 0, NULL, sz, &sz, ci), ci[5].mSelector == 'LSlt'), "6 custom properties, the 6th 'LSlt'");
    {   // 'LSlt': the output reports it as its latency; the input doesn't
        AudioObjectPropertyAddress la = { 'LSlt', kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
        SInt32 fr = 15435; CFNumberRef nn = CFNumberCreate(NULL, kCFNumberSInt32Type, &fr);
        CHECK(I->SetPropertyData(drv, kDev, 0, &la, 0, NULL, sizeof nn, &nn) == 0, "set 'LSlt' 15435"); CFRelease(nn);
        AudioObjectPropertyAddress lat = { kAudioDevicePropertyLatency, kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain };
        UInt32 lo = 9, li = 9, lz = 4; I->GetPropertyData(drv, kDev, 0, &lat, 0, NULL, lz, &lz, &lo);
        lat.mScope = kAudioObjectPropertyScopeInput; lz = 4; I->GetPropertyData(drv, kDev, 0, &lat, 0, NULL, lz, &lz, &li);
        CHECK(lo == 15435 && li == 0, "latency: output %u, input %u", lo, li);
        fr = 0; nn = CFNumberCreate(NULL, kCFNumberSInt32Type, &fr); I->SetPropertyData(drv, kDev, 0, &la, 0, NULL, sizeof nn, &nn); CFRelease(nn);
    }
    CHECK(I->GetPropertyData(drv, kDev, 0, &a, 0, NULL, sz, &sz, ci) == 0 && ci[0].mSelector == 'LSrs' && ci[1].mSelector == 'LSst' && ci[4].mSelector == 'LSmx', "custom properties LSrs, LSst, ..., LSmx");

    // rate change: set -> request -> perform
    a.mSelector = kAudioDevicePropertyNominalSampleRate;
    Float64 r = 96000; UInt32 nChanged = 0; AudioObjectPropertyAddress changed[2];
    CHECK(I->SetPropertyData(drv, kDev, 0, &a, 0, NULL, sizeof r, &r) == 0, "set 96k accepted");
    usleep(100000);
    CHECK(gRequestedChange == 96000, "config change requested (%llu)", gRequestedChange);
    CHECK(I->PerformDeviceConfigurationChange(drv, kDev, 96000, NULL) == 0, "perform 96k");
    sz = sizeof r; I->GetPropertyData(drv, kDev, 0, &a, 0, NULL, sz, &sz, &r);
    CHECK(r == 96000, "nominal rate now %.0f", r);
    r = 22050; CHECK(I->SetPropertyData(drv, kDev, 0, &a, 0, NULL, sizeof r, &r) != 0, "22.05k refused");

    // clock at scalar 1
    CHECK(I->StartIO(drv, kDev, 1) == 0, "StartIO");
    Float64 s0; UInt64 h0, seed; UInt64 t0 = mach_absolute_time();
    I->GetZeroTimeStamp(drv, kDev, 1, &s0, &h0, &seed);
    double ticksPerFrame = gTicksPerSec / 96000.0;
    // walk the zero time stamps for ~1.2 s (period 16384 frames = 0.17 s at 96k)
    Float64 sPrev = s0; UInt64 hPrev = h0; int steps = 0; double maxErr = 0;
    while(mach_absolute_time() - t0 < 1.2 * gTicksPerSec) {
        Float64 s; UInt64 h; I->GetZeroTimeStamp(drv, kDev, 1, &s, &h, &seed);
        if(s != sPrev) {
            double expect = (s - sPrev) * ticksPerFrame; double err = fabs((double)(h - hPrev) - expect);
            if(err > maxErr) maxErr = err;
            CHECK(s - sPrev == 16384, "zero stamp step %.0f frames", s - sPrev);
            sPrev = s; hPrev = h; steps++;
        }
        usleep(2000);
    }
    CHECK(steps >= 6 && maxErr < 2, "%d zero stamps at nominal pace (max err %.2f ticks)", steps, maxErr);

    // steer: scalar 1.0005 (500 ppm slow) -> host ticks per period grow by 500 ppm
    a.mSelector = 'LSrs';
    double sc = 1.0005; CFNumberRef n = CFNumberCreate(NULL, kCFNumberFloat64Type, &sc);
    CHECK(I->SetPropertyData(drv, kDev, 0, &a, 0, NULL, sizeof(CFPropertyListRef), &n) == 0, "set rate scalar 1.0005");
    CFRelease(n);
    CFPropertyListRef got = NULL; sz = sizeof got;
    CHECK(I->GetPropertyData(drv, kDev, 0, &a, 0, NULL, sz, &sz, &got) == 0, "get rate scalar");
    double back = 0; CFNumberGetValue(got, kCFNumberFloat64Type, &back); CFRelease(got);
    CHECK(back == 1.0005, "rate scalar reads back %.9f", back);
    // sample-time continuity at the change: the timeline has to pass through "now" smoothly
    Float64 sA; UInt64 hA; I->GetZeroTimeStamp(drv, kDev, 1, &sA, &hA, &seed);
    int steps2 = 0; double maxErr2 = 0; sPrev = -1; t0 = mach_absolute_time();
    while(mach_absolute_time() - t0 < 1.2 * gTicksPerSec) {
        Float64 s; UInt64 h; I->GetZeroTimeStamp(drv, kDev, 1, &s, &h, &seed);
        if(sPrev >= 0 && s != sPrev) {
            double expect = (s - sPrev) * ticksPerFrame * 1.0005; double err = fabs((double)(h - hPrev) - expect);
            if(err > maxErr2) maxErr2 = err;
            steps2++;
        }
        if(s != sPrev) { sPrev = s; hPrev = h; }
        usleep(2000);
    }
    CHECK(steps2 >= 5 && maxErr2 < 2, "%d zero stamps at scalar 1.0005 (max err %.2f ticks)", steps2, maxErr2);
    double bad = 1.2; n = CFNumberCreate(NULL, kCFNumberFloat64Type, &bad);
    CHECK(I->SetPropertyData(drv, kDev, 0, &a, 0, NULL, sizeof(CFPropertyListRef), &n) != 0, "scalar 1.2 refused");
    CFRelease(n);

    // status
    a.mSelector = 'LSst'; got = NULL; sz = sizeof got;
    CHECK(I->GetPropertyData(drv, kDev, 0, &a, 0, NULL, sz, &sz, &got) == 0 && got && CFGetTypeID(got) == CFDictionaryGetTypeID(), "status dictionary");
    double sn = 0; CFNumberGetValue(CFDictionaryGetValue(got, CFSTR("sampleNow")), kCFNumberFloat64Type, &sn);
    printf("   sampleNow %.1f\n", sn); CFRelease(got);

    // loopback: write a random 24-bit-exact signal, read it back at the same sample times, incl. wrap
    const UInt32 frames = 512; float out[frames * 2], in[frames * 4];
    AudioServerPlugInIOCycleInfo cyc; memset(&cyc, 0, sizeof cyc);
    int mismatches = 0; UInt32 wrapTested = 0;
    srandom(1);
    Float64 starts[] = { 0, 512, 131072 - 100, 131072 * 3 + 7, 1000000.0 };
    for(unsigned k = 0; k < sizeof starts / sizeof starts[0]; k++) {
        for(UInt32 i = 0; i < frames * 2; i++) out[i] = (float)((int)(random() % 16777216) - 8388608) / 8388608.0f;
        cyc.mOutputTime.mSampleTime = starts[k];
        I->DoIOOperation(drv, kDev, kOut, 1, kAudioServerPlugInIOOperationWriteMix, frames, &cyc, out, NULL);
        cyc.mInputTime.mSampleTime = starts[k];
        memset(in, 0xff, sizeof in);
        I->DoIOOperation(drv, kDev, kIn, 1, kAudioServerPlugInIOOperationReadInput, frames, &cyc, in, NULL);
        for(UInt32 i = 0; i < frames; i++) if(memcmp(&in[i * 4], &out[i * 2], 8) != 0 || in[i * 4 + 2] != 0 || in[i * 4 + 3] != 0) { mismatches++; break; }
        if(fmod(starts[k], 131072) + frames > 131072) wrapTested++;
        // read again: cleared -> zeros
        I->DoIOOperation(drv, kDev, kIn, 1, kAudioServerPlugInIOOperationReadInput, frames, &cyc, in, NULL);
        int nz = 0; for(UInt32 i = 0; i < frames * 4; i++) if(in[i] != 0) nz++;
        if(nz) mismatches++;
    }
    CHECK(mismatches == 0 && wrapTested == 1, "loopback bit-exact incl. wrap, cleared after read (mismatches %d, wraps %u)", mismatches, wrapTested);
    cyc.mInputTime.mSampleTime = -300;
    memset(in, 0xff, sizeof in);
    I->DoIOOperation(drv, kDev, kIn, 1, kAudioServerPlugInIOOperationReadInput, frames, &cyc, in, NULL);
    int nz = 0; for(UInt32 i = 0; i < frames * 4; i++) if(in[i] != 0) nz++;
    CHECK(nz == 0, "negative input sample time -> silence (4 ch)");

    // ---- Music only ('LSmx'): per-client ProcessOutput, as coreaudiod would call it: every client's
    // own buffer, then the HAL's mix of the (processed) buffers into WriteMix.
    {
        AudioObjectPropertyAddress ma = { 'LSmx', kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
        Boolean st = 0; I->IsPropertySettable(drv, kDev, 0, &ma, &st);
        CHECK(I->HasProperty(drv, kDev, 0, &ma) && st, "'LSmx' present and settable");
        Boolean wd = 0, wip = 0; I->WillDoIOOperation(drv, kDev, 0, kAudioServerPlugInIOOperationProcessOutput, &wd, &wip);
        CHECK(wd && wip, "will do ProcessOutput in place");
        AudioServerPlugInClientInfo music = { 11, 500, false, NULL }, music2 = { 14, 500, false, NULL }, web = { 12, 600, false, NULL }, fb = { 13, 700, false, NULL };
        I->AddDeviceClient(drv, kDev, &music); I->AddDeviceClient(drv, kDev, &music2); I->AddDeviceClient(drv, kDev, &web); I->AddDeviceClient(drv, kDev, &fb);
        #define SETMX(p) do { SInt32 v_ = (p); CFNumberRef n_ = CFNumberCreate(NULL, kCFNumberSInt32Type, &v_); mxs = I->SetPropertyData(drv, kDev, 0, &ma, 0, NULL, sizeof n_, &n_); CFRelease(n_); } while(0)
        OSStatus mxs;
        float m[frames * 2], m2[frames * 2], w[frames * 2], f[frames * 2], mix[frames * 2], wCopy[frames * 2], fCopy[frames * 2];
        // one cycle: ProcessOutput per client (in place), the HAL sums them, WriteMix, then read back
        #define CYCLE(t) do { \
            cyc.mOutputTime.mSampleTime = (t); cyc.mInputTime.mSampleTime = (t); \
            I->DoIOOperation(drv, kDev, kOut, 11, kAudioServerPlugInIOOperationProcessOutput, frames, &cyc, m, NULL); \
            I->DoIOOperation(drv, kDev, kOut, 14, kAudioServerPlugInIOOperationProcessOutput, frames, &cyc, m2, NULL); \
            I->DoIOOperation(drv, kDev, kOut, 12, kAudioServerPlugInIOOperationProcessOutput, frames, &cyc, w, NULL); \
            I->DoIOOperation(drv, kDev, kOut, 13, kAudioServerPlugInIOOperationProcessOutput, frames, &cyc, f, NULL); \
            for(UInt32 i_ = 0; i_ < frames * 2; i_++) mix[i_] = w[i_] + m[i_] + f[i_] + m2[i_]; \
            I->DoIOOperation(drv, kDev, kOut, 0, kAudioServerPlugInIOOperationWriteMix, frames, &cyc, mix, NULL); \
            memset(in, 0xff, sizeof in); \
            I->DoIOOperation(drv, kDev, kIn, 1, kAudioServerPlugInIOOperationReadInput, frames, &cyc, in, NULL); \
        } while(0)
        #define FILL() do { for(UInt32 i_ = 0; i_ < frames * 2; i_++) { \
            m[i_] = (float)((int)(random() % 16777216) - 8388608) / 8388608.0f; m2[i_] = 0.0f; \
            w[i_] = (float)((int)(random() % 16777216) - 8388608) / 16777216.0f; f[i_] = (float)((int)(random() % 65536) - 32768) / 131072.0f; \
            wCopy[i_] = w[i_]; fCopy[i_] = f[i_]; } } while(0)
        float mCopy[frames * 2];
        SETMX(500); CHECK(mxs == 0, "set 'LSmx' = 500 (Music)");
        int badMusic = 0, badOthers = 0, notZeroed = 0, wraps = 0;
        Float64 ts[] = { 4096, 131072 - 200, 131072 * 5 + 33 };
        for(unsigned k = 0; k < 3; k++) {
            FILL(); memcpy(mCopy, m, sizeof m);
            CYCLE(ts[k]);
            for(UInt32 i = 0; i < frames * 2; i++) if(w[i] != 0 || f[i] != 0) { notZeroed++; break; }
            for(UInt32 i = 0; i < frames; i++) {
                if(memcmp(&in[i * 4], &mCopy[i * 2], 8) != 0) { badMusic++; break; }
            }
            for(UInt32 i = 0; i < frames; i++) {
                if(in[i * 4 + 2] != wCopy[i * 2] + fCopy[i * 2] || in[i * 4 + 3] != wCopy[i * 2 + 1] + fCopy[i * 2 + 1]) { badOthers++; break; }
            }
            if(fmod(ts[k], 131072) + frames > 131072) wraps++;
        }
        CHECK(badMusic == 0 && wraps == 1, "Music only: ch 1-2 bit-exact Music (2 Music clients, 2 others playing; incl. wrap)");
        CHECK(notZeroed == 0, "others' buffers zeroed before the mix");
        CHECK(badOthers == 0, "ch 3-4 = the sum of the two other apps");
        // a lap later with nobody reading: the first other client of a cycle replaces the old lap
        FILL(); cyc.mOutputTime.mSampleTime = 8192;
        I->DoIOOperation(drv, kDev, kOut, 12, kAudioServerPlugInIOOperationProcessOutput, frames, &cyc, w, NULL);
        FILL(); cyc.mOutputTime.mSampleTime = 8192 + 131072;
        I->DoIOOperation(drv, kDev, kOut, 12, kAudioServerPlugInIOOperationProcessOutput, frames, &cyc, w, NULL);
        cyc.mInputTime.mSampleTime = 8192 + 131072; memset(in, 0xff, sizeof in);
        I->DoIOOperation(drv, kDev, kIn, 1, kAudioServerPlugInIOOperationReadInput, frames, &cyc, in, NULL);
        int stale = 0; for(UInt32 i = 0; i < frames; i++) if(in[i * 4 + 2] != wCopy[i * 2]) { stale++; break; }
        CHECK(stale == 0, "an unread earlier lap is replaced, not summed");
        // two other apps whose ProcessOutput times differ by 8 frames in one cycle, one of them silent
        // (1.1.4 replaced on each "new" time and lost the audible one: pastor Mac, YouTube silent)
        {
            float silentBuf[frames * 2]; memset(silentBuf, 0, sizeof silentBuf);
            FILL(); Float64 t0 = 50000;
            cyc.mOutputTime.mSampleTime = t0;
            I->DoIOOperation(drv, kDev, kOut, 12, kAudioServerPlugInIOOperationProcessOutput, frames, &cyc, w, NULL);
            cyc.mOutputTime.mSampleTime = t0 + 8;
            I->DoIOOperation(drv, kDev, kOut, 13, kAudioServerPlugInIOOperationProcessOutput, frames, &cyc, silentBuf, NULL);
            cyc.mInputTime.mSampleTime = t0; memset(in, 0xff, sizeof in);
            I->DoIOOperation(drv, kDev, kIn, 1, kAudioServerPlugInIOOperationReadInput, frames, &cyc, in, NULL);
            int lost = 0; for(UInt32 i = 0; i < frames; i++) if(in[i * 4 + 2] != wCopy[i * 2] || in[i * 4 + 3] != wCopy[i * 2 + 1]) { lost++; }
            CHECK(lost == 0, "clients at different sample times in one cycle: the audible one survives a silent one (%d frames lost)", lost);
        }
        a.mSelector = 'LSst'; got = NULL; sz = sizeof got; I->GetPropertyData(drv, kDev, 0, &a, 0, NULL, sz, &sz, &got);
        double calls = 0, mcalls = 0, moved = 0, mpid = 0;
        CFNumberGetValue(CFDictionaryGetValue(got, CFSTR("processOutputCalls")), kCFNumberFloat64Type, &calls);
        CFNumberGetValue(CFDictionaryGetValue(got, CFSTR("musicClientCalls")), kCFNumberFloat64Type, &mcalls);
        CFNumberGetValue(CFDictionaryGetValue(got, CFSTR("othersFramesMoved")), kCFNumberFloat64Type, &moved);
        CFNumberGetValue(CFDictionaryGetValue(got, CFSTR("musicPID")), kCFNumberFloat64Type, &mpid); CFRelease(got);
        CHECK(calls == 16 && mcalls == 6 && moved == 10 * frames && mpid == 500, "status counts per-client calls (%.0f calls, %.0f Music, %.0f frames moved, pid %.0f)", calls, mcalls, moved, mpid);
        // 'LSmx' = 0: as 1.1.3, everything mixed on ch 1-2, 3-4 silent, buffers untouched
        SETMX(0); CHECK(mxs == 0, "set 'LSmx' = 0");
        FILL(); CYCLE(20000);
        int bad0 = 0; for(UInt32 i = 0; i < frames * 2; i++) if(w[i] != wCopy[i] || f[i] != fCopy[i]) { bad0++; break; }
        for(UInt32 i = 0; i < frames; i++) if(memcmp(&in[i * 4], &mix[i * 2], 8) != 0 || in[i * 4 + 2] != 0 || in[i * 4 + 3] != 0) { bad0++; break; }
        CHECK(bad0 == 0, "'LSmx' = 0: the whole mix on ch 1-2, ch 3-4 silent, buffers untouched");
        SETMX(-1); CHECK(mxs != 0, "negative pid refused");
        I->RemoveDeviceClient(drv, kDev, &music); I->RemoveDeviceClient(drv, kDev, &music2); I->RemoveDeviceClient(drv, kDev, &web); I->RemoveDeviceClient(drv, kDev, &fb);
    }

    // ---- holds
    AudioObjectPropertyAddress ha = { 'LShd', kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    #define SETHOLD(m) do { SInt32 v_ = (m); CFNumberRef n_ = CFNumberCreate(NULL, kCFNumberSInt32Type, &v_); hs = I->SetPropertyData(drv, kDev, 0, &ha, 0, NULL, sizeof(CFPropertyListRef), &n_); CFRelease(n_); } while(0)
    OSStatus hs;
    // freeze: zero stamps stop advancing; after release the time line continues from the frozen sample
    Float64 fs0; UInt64 fh0, fseed0; I->GetZeroTimeStamp(drv, kDev, 1, &fs0, &fh0, &fseed0);
    SETHOLD(1); CHECK(hs == 0, "freeze accepted");
    SETHOLD(2); CHECK(hs != 0, "second hold refused while frozen");
    usleep(600000);   // > 3 zero-stamp periods at 96k
    Float64 fs1; UInt64 fh1, fseed1; I->GetZeroTimeStamp(drv, kDev, 1, &fs1, &fh1, &fseed1);
    CHECK(fs1 <= fs0 + 16384, "frozen: zero stamp did not run on (%.0f -> %.0f)", fs0, fs1);
    SETHOLD(0); CHECK(hs == 0, "freeze released");
    a.mSelector = 'LSst'; got = NULL; sz = sizeof got; I->GetPropertyData(drv, kDev, 0, &a, 0, NULL, sz, &sz, &got);
    double snow = 0, lastHold = 0, seedNow = 0; CFNumberGetValue(CFDictionaryGetValue(got, CFSTR("sampleNow")), kCFNumberFloat64Type, &snow);
    CFNumberGetValue(CFDictionaryGetValue(got, CFSTR("lastHoldSeconds")), kCFNumberFloat64Type, &lastHold);
    CFNumberGetValue(CFDictionaryGetValue(got, CFSTR("seed")), kCFNumberFloat64Type, &seedNow); CFRelease(got);
    CHECK(lastHold > 0.55 && lastHold < 0.8, "freeze lasted %.3f s", lastHold);
    printf("   after freeze: sampleNow %.0f (frozen near %.0f), seed %.0f (was %llu)\n", snow, fs0, seedNow, fseed0);
    CHECK(seedNow > fseed0, "seed bumped after freeze");
    // config hold: request, then Perform blocks until released
    gRequestedChange = 0; SETHOLD(2); CHECK(hs == 0, "config hold accepted");
    usleep(100000); CHECK(gRequestedChange == 1, "config change (hold) requested (%llu)", gRequestedChange);
    __block double performSecs = -1;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(0, 0), ^{ UInt64 t = mach_absolute_time(); I->PerformDeviceConfigurationChange(drv, kDev, 1, NULL); performSecs = (mach_absolute_time() - t) / gTicksPerSec; dispatch_semaphore_signal(done); });
    usleep(400000);
    // property reads work while it blocks
    a.mSelector = kAudioDevicePropertyNominalSampleRate; sz = sizeof r;
    CHECK(I->GetPropertyData(drv, kDev, 0, &a, 0, NULL, sz, &sz, &r) == 0, "nominal rate readable during the hold");
    SETHOLD(0);
    dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC));
    CHECK(performSecs > 0.35 && performSecs < 0.6, "config hold blocked %.3f s until released", performSecs);
    // armed: the next rate change blocks until released
    SETHOLD(3); CHECK(hs == 0, "armed");
    performSecs = -1;
    dispatch_async(dispatch_get_global_queue(0, 0), ^{ UInt64 t = mach_absolute_time(); I->PerformDeviceConfigurationChange(drv, kDev, 48000, NULL); performSecs = (mach_absolute_time() - t) / gTicksPerSec; dispatch_semaphore_signal(done); });
    usleep(300000);
    a.mSelector = kAudioDevicePropertyNominalSampleRate; sz = sizeof r;
    CHECK(I->GetPropertyData(drv, kDev, 0, &a, 0, NULL, sz, &sz, &r) == 0 && r == 48000, "rate already 48k while held (%.0f)", r);
    SETHOLD(0);
    dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC));
    CHECK(performSecs > 0.25 && performSecs < 0.5, "armed rate change blocked %.3f s until released", performSecs);
    ha.mSelector = 'LShd'; got = NULL; sz = sizeof got; I->GetPropertyData(drv, kDev, 0, &ha, 0, NULL, sz, &sz, &got);
    int hstate = -1; CFNumberGetValue(got, kCFNumberSInt32Type, &hstate); CFRelease(got);
    CHECK(hstate == 0, "hold state back to 0");

    // names and the default-device gate ('LSac')
    {
        AudioObjectPropertyAddress na = { kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
        CFStringRef nm = NULL; UInt32 nsz = sizeof nm; char nb[256] = "";
        I->GetPropertyData(drv, kDev, 0, &na, 0, NULL, nsz, &nsz, &nm); if(nm) CFStringGetCString(nm, nb, sizeof nb, kCFStringEncodingUTF8);
        CHECK(strcmp(nb, "LosslessSwitcher") == 0, "device name is LosslessSwitcher (%s)", nb);
        na.mSelector = kAudioObjectPropertyElementName; na.mElement = 1; nm = NULL; nsz = sizeof nm; nb[0] = 0;
        I->GetPropertyData(drv, kDev, 0, &na, 0, NULL, nsz, &nsz, &nm); if(nm) CFStringGetCString(nm, nb, sizeof nb, kCFStringEncodingUTF8);
        CHECK(strcmp(nb, "Left") == 0, "channel 1 is Left (%s)", nb);
        AudioObjectPropertyAddress cb = { kAudioDevicePropertyDeviceCanBeDefaultDevice, kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain };
        UInt32 v = 9, vsz = sizeof v;
        #define CANBE(scope) (cb.mScope = (scope), cb.mSelector = kAudioDevicePropertyDeviceCanBeDefaultDevice, v = 9, vsz = sizeof v, I->GetPropertyData(drv, kDev, 0, &cb, 0, NULL, vsz, &vsz, &v), v)
        CHECK(CANBE(kAudioObjectPropertyScopeOutput) == 0, "not default-able while no renderer is attached");
        AudioObjectPropertyAddress aa = { 'LSac', kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
        Boolean st = 0; I->IsPropertySettable(drv, kDev, 0, &aa, &st);
        CHECK(I->HasProperty(drv, kDev, 0, &aa) && st, "'LSac' present and settable");
        SInt32 pid = 4242; CFNumberRef n = CFNumberCreate(NULL, kCFNumberSInt32Type, &pid);
        CHECK(I->SetPropertyData(drv, kDev, 0, &aa, 0, NULL, sizeof n, &n) == 0, "attach pid 4242");
        CFRelease(n);
        CHECK(CANBE(kAudioObjectPropertyScopeOutput) == 1, "default-able output while attached");
        CHECK(CANBE(kAudioObjectPropertyScopeInput) == 0, "never the default input");
        cb.mScope = kAudioObjectPropertyScopeOutput; cb.mSelector = kAudioDevicePropertyDeviceCanBeDefaultSystemDevice; v = 9; vsz = sizeof v;
        I->GetPropertyData(drv, kDev, 0, &cb, 0, NULL, vsz, &vsz, &v);
        CHECK(v == 0, "never the system (alert) device");
        AudioServerPlugInClientInfo other = { 1, 999, false, NULL }, mine = { 2, 4242, false, NULL };
        I->AddDeviceClient(drv, kDev, &mine);
        I->RemoveDeviceClient(drv, kDev, &other);
        CHECK(CANBE(kAudioObjectPropertyScopeOutput) == 1, "another client leaving keeps it");
        I->RemoveDeviceClient(drv, kDev, &mine);
        CHECK(CANBE(kAudioObjectPropertyScopeOutput) == 1, "right after its last client leaves it is still attached (grace)");
        usleep(500000);
        I->AddDeviceClient(drv, kDev, &mine);   // a reconfiguration re-adds the client
        sleep(4);
        CHECK(CANBE(kAudioObjectPropertyScopeOutput) == 1, "client back within the grace: still attached after 4 s");
        I->RemoveDeviceClient(drv, kDev, &mine);
        sleep(4);
        CHECK(CANBE(kAudioObjectPropertyScopeOutput) == 0, "no client for 3 s (a crash): cleared");
        AudioObjectPropertyAddress bl = { kAudioPlugInPropertyDeviceList, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
        UInt32 bz = 0; I->GetPropertyDataSize(drv, kAudioObjectPlugInObject, 0, &bl, 0, NULL, &bz);
        CHECK(bz == 0, "device withdrawn after the crash-detach (device list size %u)", bz);
        sleep(3);
        bz = 0; I->GetPropertyDataSize(drv, kAudioObjectPlugInObject, 0, &bl, 0, NULL, &bz);
        CHECK(bz == sizeof(AudioObjectID), "device back 2 s later (device list size %u)", bz);
        AudioObjectPropertyAddress ol = { kAudioObjectPropertyOwnedObjects, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
        AudioObjectID objs[16]; UInt32 oz = sizeof objs; I->GetPropertyData(drv, kDev, 0, &ol, 0, NULL, oz, &oz, objs);
        UInt32 dz = 0; I->GetPropertyDataSize(drv, kDev, 0, &ol, 0, NULL, &dz);
        CHECK(oz == 4 * sizeof(AudioObjectID) && dz == oz && objs[0] == 4 && objs[1] == 8 && objs[2] == 9 && objs[3] == 10, "device publishes 2 streams + output volume/mute only");
        ol.mSelector = kAudioObjectPropertyControlList; oz = sizeof objs; I->GetPropertyData(drv, kDev, 0, &ol, 0, NULL, oz, &oz, objs);
        CHECK(oz == 2 * sizeof(AudioObjectID) && objs[0] == 9 && objs[1] == 10, "controls: output volume + mute");
        {   // the volume control applies no gain, so it must never read above 0 dB; linear in dB like the engine
            AudioObjectPropertyAddress va = { kAudioLevelControlPropertyDecibelValue, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
            Float32 f = 99; UInt32 fz = sizeof f;
            I->GetPropertyData(drv, 9, 0, &va, 0, NULL, fz, &fz, &f);
            CHECK(f == 0.0f, "volume at full scale reads 0 dB (read %.2f)", f);
            AudioValueRange r = { 0, 0 }; UInt32 rz = sizeof r; va.mSelector = kAudioLevelControlPropertyDecibelRange;
            I->GetPropertyData(drv, 9, 0, &va, 0, NULL, rz, &rz, &r);
            CHECK(r.mMinimum == -64.0 && r.mMaximum == 0.0, "volume range -64..0 dB (%.1f..%.1f)", r.mMinimum, r.mMaximum);
            va.mSelector = kAudioLevelControlPropertyConvertScalarToDecibels; f = 0.6641f; fz = sizeof f;
            I->GetPropertyData(drv, 9, 0, &va, 0, NULL, fz, &fz, &f);
            CHECK(fabsf(f + 21.5f) < 0.01f, "scalar 0.6641 -> -21.5 dB, the engine's mapping (%.2f)", f);
            va.mSelector = kAudioLevelControlPropertyConvertDecibelsToScalar; f = 6.0f; fz = sizeof f;
            I->GetPropertyData(drv, 9, 0, &va, 0, NULL, fz, &fz, &f);
            CHECK(f == 1.0f, "+6 dB clamps to scalar 1 (0 dB) (%.4f)", f);
            va.mSelector = kAudioLevelControlPropertyScalarValue; f = 0.5f;
            I->SetPropertyData(drv, 9, 0, &va, 0, NULL, sizeof f, &f);
            va.mSelector = kAudioLevelControlPropertyDecibelValue; fz = sizeof f;
            I->GetPropertyData(drv, 9, 0, &va, 0, NULL, fz, &fz, &f);
            CHECK(f == -32.0f, "scalar 0.5 reads -32 dB (%.2f)", f);
            va.mSelector = kAudioLevelControlPropertyScalarValue; f = 1.0f;
            I->SetPropertyData(drv, 9, 0, &va, 0, NULL, sizeof f, &f);
        }
        pid = 4242; n = CFNumberCreate(NULL, kCFNumberSInt32Type, &pid); I->SetPropertyData(drv, kDev, 0, &aa, 0, NULL, sizeof n, &n); CFRelease(n);
        pid = 0; n = CFNumberCreate(NULL, kCFNumberSInt32Type, &pid); I->SetPropertyData(drv, kDev, 0, &aa, 0, NULL, sizeof n, &n); CFRelease(n);
        CHECK(CANBE(kAudioObjectPropertyScopeOutput) == 0, "detach (0) clears it");
    }

    CHECK(I->StopIO(drv, kDev, 1) == 0, "StopIO");
    printf(gFail ? "\n%d FAILED\n" : "\nall passed\n", gFail);
    return gFail != 0;
}
