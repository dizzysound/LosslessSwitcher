#!/usr/bin/env python3
"""Turn Apple's NullAudio.c (committed unmodified as LSOutput.c) into LSOutput.c.

Idempotence is not a goal: run once on the pristine file (git checkout d20eff1 -- LSOutput.c).
Each replacement must match exactly once, so a changed sample fails loudly.
"""
import re, sys

path = sys.argv[1] if len(sys.argv) > 1 else "LSOutput.c"
src = open(path).read()

def loose(old):
    # blank lines in the pattern match lines holding only whitespace (the sample has tab-only lines)
    lines = old.split("\n")
    return "\n".join(r"[ \t]*" if l.strip() == "" else re.escape(l) for l in lines)

def sub(old, new, count=1):
    global src
    pat = re.compile(loose(old))
    n = len(pat.findall(src))
    if n != count:
        sys.exit(f"expected {count} match(es), found {n}: {old[:90]!r}")
    src = pat.sub(lambda m: new, src)

# ---------------------------------------------------------------- identity
sub('#include <sys/syslog.h>', '#include <sys/syslog.h>\n#include <os/log.h>\n#include <string.h>')
sub('"com.apple.audio.NullAudio"', '"com.dizzysound.LSOutput"')
sub('"NullAudioBox_UID"', '"LSOutputBox_UID"')
sub('"NullAudioDevice_UID"', '"LSOutput_UID"')
sub('"NullAudioDevice_ModelUID"', '"LSOutput_ModelUID"')
sub('CFSTR("Null Box")', 'CFSTR("LosslessSwitcher Box")')
sub('*((CFStringRef*)outData) = CFSTR("DeviceName");', '*((CFStringRef*)outData) = CFSTR("LosslessSwitcher Output");')
sub('*((CFStringRef*)outData) = CFSTR("ManufacturerName");', '*((CFStringRef*)outData) = CFSTR("dizzysound");', count=src.count('CFSTR("ManufacturerName")'))
sub('void*	NullAudio_Create(', 'void*	LSOutput_Create(')
# no icon resource in this bundle: don't advertise one
sub('''		case kAudioDevicePropertyZeroTimeStampPeriod:
		case kAudioDevicePropertyIcon:
		case kAudioDevicePropertyStreams:
			theAnswer = true;''', '''		case kAudioDevicePropertyZeroTimeStampPeriod:
		case kAudioDevicePropertyStreams:
		case kAudioObjectPropertyCustomPropertyInfoList:
		case kLS_RateScalar:
		case kLS_Status:
			theAnswer = true;''')

# ---------------------------------------------------------------- state
sub('''static UInt64								gDevice_AnchorHostTime			= 0;''',
'''static UInt64								gDevice_AnchorHostTime			= 0;

//	LSOutput additions.
//	Rates: the ones LosslessSwitcher switches a DAC between.
static const Float64						kLS_Rates[]						= { 44100.0, 48000.0, 88200.0, 96000.0, 176400.0, 192000.0 };
#define										kLS_NumRates					6
//	Clock: host(S) = gClock_AnchorHost + (S - gClock_AnchorSample) * gDevice_HostTicksPerFrame, where
//	gDevice_HostTicksPerFrame = nominal ticks per frame * gClock_RateScalar. A client (the renderer)
//	sets the rate scalar (custom property 'LSrs', a CFNumber, same meaning as AudioTimeStamp's
//	mRateScalar: actual host ticks per frame / nominal) so that this device runs at the DAC's pace.
//	A new scalar re-anchors the line at "now", so the sample time stays continuous.
static const AudioObjectPropertySelector	kLS_RateScalar					= 'LSrs';
static const AudioObjectPropertySelector	kLS_Status						= 'LSst';
static Float64								gClock_RateScalar				= 1.0;
static Float64								gClock_NominalTicksPerFrame		= 0.0;
static Float64								gClock_AnchorSample				= 0.0;
static Float64								gClock_AnchorHost				= 0.0;
static UInt64								gClock_Seed						= 1;
static UInt64								gClock_ScalarSets				= 0;
//	Loopback: what is mixed for the output stream at sample time S is read back on the input stream
//	at sample time S. The ring is indexed by sample time; a read clears what it read.
#define										kLoop_Frames					131072
static Float32								gLoop_Buffer[kLoop_Frames * 2];
static Float64								gLoop_LastWriteSample			= -1.0;
static Float64								gLoop_LastReadSample			= -1.0;
static UInt64								gLoop_FramesWritten				= 0;
static UInt64								gLoop_FramesRead				= 0;
static os_log_t								gLog							= NULL;

static bool LS_IsSupportedRate(Float64 inRate)
{
	for(UInt32 i = 0; i < kLS_NumRates; ++i) { if(kLS_Rates[i] == inRate) return true; }
	return false;
}

static Float64 LS_HostClockFrequency(void)
{
	struct mach_timebase_info theTimeBaseInfo;
	mach_timebase_info(&theTimeBaseInfo);
	return ((Float64)theTimeBaseInfo.denom / (Float64)theTimeBaseInfo.numer) * 1000000000.0;
}

//	Called with gDevice_IOMutex held: re-anchor at host time inNow under the current line, then
//	apply the (possibly new) ticks per frame from there.
static void LS_Reanchor(UInt64 inNow)
{
	if(gDevice_HostTicksPerFrame > 0.0)
	{
		gClock_AnchorSample += (((Float64)inNow) - gClock_AnchorHost) / gDevice_HostTicksPerFrame;
	}
	gClock_AnchorHost = (Float64)inNow;
	gDevice_HostTicksPerFrame = gClock_NominalTicksPerFrame * gClock_RateScalar;
}''')

# Initialize: nominal ticks per frame + log
sub('''	gDevice_HostTicksPerFrame = theHostClockFrequency / gDevice_SampleRate;
	
Done:
	return theAnswer;
}

static OSStatus	NullAudio_CreateDevice(''', '''	gDevice_HostTicksPerFrame = theHostClockFrequency / gDevice_SampleRate;
	gClock_NominalTicksPerFrame = gDevice_HostTicksPerFrame;
	gLog = os_log_create("com.dizzysound.LSOutput", "driver");
	os_log(gLog, "LSOutput: initialized, %.0f Hz", gDevice_SampleRate);
	
Done:
	return theAnswer;
}

static OSStatus	NullAudio_CreateDevice(''')

# ---------------------------------------------------------------- rates
sub('FailWithAction((inChangeAction != 44100) && (inChangeAction != 48000), theAnswer',
    'FailWithAction(!LS_IsSupportedRate((Float64)inChangeAction), theAnswer')
sub('''	gDevice_HostTicksPerFrame = theHostClockFrequency / gDevice_SampleRate;

	//	unlock the state mutex
	pthread_mutex_unlock(&gPlugIn_StateMutex);''', '''	pthread_mutex_lock(&gDevice_IOMutex);
	gClock_NominalTicksPerFrame = theHostClockFrequency / gDevice_SampleRate;
	gDevice_HostTicksPerFrame = gClock_NominalTicksPerFrame * gClock_RateScalar;
	//	new rate, new time line
	gDevice_NumberTimeStamps = 0;
	gClock_AnchorSample = 0.0;
	gClock_AnchorHost = (Float64)mach_absolute_time();
	++gClock_Seed;
	memset(gLoop_Buffer, 0, sizeof(gLoop_Buffer));
	pthread_mutex_unlock(&gDevice_IOMutex);
	os_log(gLog, "LSOutput: rate %.0f Hz (scalar %.9f)", gDevice_SampleRate, gClock_RateScalar);

	//	unlock the state mutex
	pthread_mutex_unlock(&gPlugIn_StateMutex);''')

sub('''		case kAudioDevicePropertyAvailableNominalSampleRates:
			*outDataSize = 2 * sizeof(AudioValueRange);
			break;''', '''		case kAudioDevicePropertyAvailableNominalSampleRates:
			*outDataSize = kLS_NumRates * sizeof(AudioValueRange);
			break;

		case kAudioObjectPropertyCustomPropertyInfoList:
			*outDataSize = 2 * sizeof(AudioServerPlugInCustomPropertyInfo);
			break;

		case kLS_RateScalar:
		case kLS_Status:
			*outDataSize = sizeof(CFPropertyListRef);
			break;''')

sub('''			if(theNumberItemsToFetch > 2)
			{
				theNumberItemsToFetch = 2;
			}

			//	fill out the return array
			if(theNumberItemsToFetch > 0)
			{
				((AudioValueRange*)outData)[0].mMinimum = 44100.0;
				((AudioValueRange*)outData)[0].mMaximum = 44100.0;
			}
			if(theNumberItemsToFetch > 1)
			{
				((AudioValueRange*)outData)[1].mMinimum = 48000.0;
				((AudioValueRange*)outData)[1].mMaximum = 48000.0;
			}''', '''			if(theNumberItemsToFetch > kLS_NumRates)
			{
				theNumberItemsToFetch = kLS_NumRates;
			}

			//	fill out the return array
			for(theItemIndex = 0; theItemIndex < theNumberItemsToFetch; ++theItemIndex)
			{
				((AudioValueRange*)outData)[theItemIndex].mMinimum = kLS_Rates[theItemIndex];
				((AudioValueRange*)outData)[theItemIndex].mMaximum = kLS_Rates[theItemIndex];
			}''')

sub('''FailWithAction((*((const Float64*)inData) != 44100.0) && (*((const Float64*)inData) != 48000.0), theAnswer''',
    '''FailWithAction(!LS_IsSupportedRate(*((const Float64*)inData)), theAnswer''')
sub('''FailWithAction((((const AudioStreamBasicDescription*)inData)->mSampleRate != 44100.0) && (((const AudioStreamBasicDescription*)inData)->mSampleRate != 48000.0), theAnswer''',
    '''FailWithAction(!LS_IsSupportedRate(((const AudioStreamBasicDescription*)inData)->mSampleRate), theAnswer''')

sub('''		case kAudioStreamPropertyAvailableVirtualFormats:
		case kAudioStreamPropertyAvailablePhysicalFormats:
			*outDataSize = 2 * sizeof(AudioStreamRangedDescription);''', '''		case kAudioStreamPropertyAvailableVirtualFormats:
		case kAudioStreamPropertyAvailablePhysicalFormats:
			*outDataSize = kLS_NumRates * sizeof(AudioStreamRangedDescription);''')

# stream format list: replace the two hand-written entries with a loop
m = re.search(r'''			if\(theNumberItemsToFetch > 2\)
			\{
				theNumberItemsToFetch = 2;
			\}
[ \t]*
			//	fill out the return array
			if\(theNumberItemsToFetch > 0\)
			\{
				\(\(AudioStreamRangedDescription\*\)outData\)\[0\]\.mFormat\.mSampleRate = 44100\.0;.*?mSampleRateRange\.mMaximum = 48000\.0;
			\}''', src, re.S)
if not m:
    sys.exit("stream format list not found")
src = src[:m.start()] + '''			if(theNumberItemsToFetch > kLS_NumRates)
			{
				theNumberItemsToFetch = kLS_NumRates;
			}

			//	fill out the return array
			for(UInt32 theIndex = 0; theIndex < theNumberItemsToFetch; ++theIndex)
			{
				AudioStreamRangedDescription* theItem = &((AudioStreamRangedDescription*)outData)[theIndex];
				theItem->mFormat.mSampleRate = kLS_Rates[theIndex];
				theItem->mFormat.mFormatID = kAudioFormatLinearPCM;
				theItem->mFormat.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked;
				theItem->mFormat.mBytesPerPacket = 8;
				theItem->mFormat.mFramesPerPacket = 1;
				theItem->mFormat.mBytesPerFrame = 8;
				theItem->mFormat.mChannelsPerFrame = 2;
				theItem->mFormat.mBitsPerChannel = 32;
				theItem->mFormat.mReserved = 0;
				theItem->mSampleRateRange.mMinimum = kLS_Rates[theIndex];
				theItem->mSampleRateRange.mMaximum = kLS_Rates[theIndex];
			}''' + src[m.end():]

# ---------------------------------------------------------------- custom properties on the device
sub('''		case kAudioDevicePropertyNominalSampleRate:
			*outIsSettable = true;
			break;

		default:
			theAnswer = kAudioHardwareUnknownPropertyError;
			break;
	};

Done:
	return theAnswer;
}

static OSStatus	NullAudio_GetDevicePropertyDataSize(''', '''		case kAudioObjectPropertyCustomPropertyInfoList:
		case kLS_Status:
			*outIsSettable = false;
			break;

		case kAudioDevicePropertyNominalSampleRate:
		case kLS_RateScalar:
			*outIsSettable = true;
			break;

		default:
			theAnswer = kAudioHardwareUnknownPropertyError;
			break;
	};

Done:
	return theAnswer;
}

static OSStatus	NullAudio_GetDevicePropertyDataSize(''')

sub('''				*((CFURLRef*)outData) = theURL;
				*outDataSize = sizeof(CFURLRef);
			}
			break;

		default:''', '''				*((CFURLRef*)outData) = theURL;
				*outDataSize = sizeof(CFURLRef);
			}
			break;

		case kAudioObjectPropertyCustomPropertyInfoList:
			theNumberItemsToFetch = inDataSize / sizeof(AudioServerPlugInCustomPropertyInfo);
			if(theNumberItemsToFetch > 2)
			{
				theNumberItemsToFetch = 2;
			}
			if(theNumberItemsToFetch > 0)
			{
				((AudioServerPlugInCustomPropertyInfo*)outData)[0].mSelector = kLS_RateScalar;
				((AudioServerPlugInCustomPropertyInfo*)outData)[0].mPropertyDataType = kAudioServerPlugInCustomPropertyDataTypeCFPropertyList;
				((AudioServerPlugInCustomPropertyInfo*)outData)[0].mQualifierDataType = kAudioServerPlugInCustomPropertyDataTypeNone;
			}
			if(theNumberItemsToFetch > 1)
			{
				((AudioServerPlugInCustomPropertyInfo*)outData)[1].mSelector = kLS_Status;
				((AudioServerPlugInCustomPropertyInfo*)outData)[1].mPropertyDataType = kAudioServerPlugInCustomPropertyDataTypeCFPropertyList;
				((AudioServerPlugInCustomPropertyInfo*)outData)[1].mQualifierDataType = kAudioServerPlugInCustomPropertyDataTypeNone;
			}
			*outDataSize = theNumberItemsToFetch * sizeof(AudioServerPlugInCustomPropertyInfo);
			break;

		case kLS_RateScalar:
			{
				FailWithAction(inDataSize < sizeof(CFPropertyListRef), theAnswer = kAudioHardwareBadPropertySizeError, Done, "LSOutput: no room for the rate scalar");
				pthread_mutex_lock(&gDevice_IOMutex);
				Float64 theScalar = gClock_RateScalar;
				pthread_mutex_unlock(&gDevice_IOMutex);
				*((CFPropertyListRef*)outData) = CFNumberCreate(NULL, kCFNumberFloat64Type, &theScalar);
				*outDataSize = sizeof(CFPropertyListRef);
			}
			break;

		case kLS_Status:
			{
				//	A snapshot for clients that measure the clock and the loopback:
				//	now, the time line at now, the zero time stamp count, loopback positions.
				FailWithAction(inDataSize < sizeof(CFPropertyListRef), theAnswer = kAudioHardwareBadPropertySizeError, Done, "LSOutput: no room for the status");
				Float64 theValues[11];
				pthread_mutex_lock(&gDevice_IOMutex);
				UInt64 theNow = mach_absolute_time();
				theValues[0] = (Float64)theNow;
				theValues[1] = (gDevice_HostTicksPerFrame > 0.0) ? gClock_AnchorSample + (((Float64)theNow) - gClock_AnchorHost) / gDevice_HostTicksPerFrame : 0.0;
				theValues[2] = gClock_RateScalar;
				theValues[3] = gDevice_HostTicksPerFrame;
				theValues[4] = (Float64)gDevice_NumberTimeStamps;
				theValues[5] = (Float64)gClock_Seed;
				theValues[6] = gLoop_LastWriteSample;
				theValues[7] = gLoop_LastReadSample;
				theValues[8] = (Float64)gLoop_FramesWritten;
				theValues[9] = (Float64)gLoop_FramesRead;
				theValues[10] = (Float64)gClock_ScalarSets;
				pthread_mutex_unlock(&gDevice_IOMutex);
				CFStringRef theKeys[11] = { CFSTR("hostNow"), CFSTR("sampleNow"), CFSTR("rateScalar"), CFSTR("ticksPerFrame"), CFSTR("zeroStamps"), CFSTR("seed"), CFSTR("lastWrite"), CFSTR("lastRead"), CFSTR("framesWritten"), CFSTR("framesRead"), CFSTR("scalarSets") };
				CFNumberRef theNumbers[11];
				for(UInt32 i = 0; i < 11; ++i) { theNumbers[i] = CFNumberCreate(NULL, kCFNumberFloat64Type, &theValues[i]); }
				CFDictionaryRef theDict = CFDictionaryCreate(NULL, (const void**)theKeys, (const void**)theNumbers, 11, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
				for(UInt32 i = 0; i < 11; ++i) { CFRelease(theNumbers[i]); }
				*((CFPropertyListRef*)outData) = theDict;
				*outDataSize = sizeof(CFPropertyListRef);
			}
			break;

		default:''')

sub('''				dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{ gPlugIn_Host->RequestDeviceConfigurationChange(gPlugIn_Host, kObjectID_Device, theNewSampleRate, NULL); });
			}
			break;

		default:
			theAnswer = kAudioHardwareUnknownPropertyError;
			break;
	};

Done:
	return theAnswer;
}

#pragma mark Stream Property Operations''', '''				dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{ gPlugIn_Host->RequestDeviceConfigurationChange(gPlugIn_Host, kObjectID_Device, theNewSampleRate, NULL); });
			}
			break;

		case kLS_RateScalar:
			{
				FailWithAction(inDataSize != sizeof(CFPropertyListRef), theAnswer = kAudioHardwareBadPropertySizeError, Done, "LSOutput: wrong size for the rate scalar");
				CFPropertyListRef theValue = *((const CFPropertyListRef*)inData);
				FailWithAction(theValue == NULL || CFGetTypeID(theValue) != CFNumberGetTypeID(), theAnswer = kAudioHardwareIllegalOperationError, Done, "LSOutput: the rate scalar must be a CFNumber");
				Float64 theScalar = 0.0;
				CFNumberGetValue((CFNumberRef)theValue, kCFNumberFloat64Type, &theScalar);
				//	a DAC's clock is within a few hundred ppm of nominal; refuse anything wild
				FailWithAction(!(theScalar > 0.99 && theScalar < 1.01), theAnswer = kAudioHardwareIllegalOperationError, Done, "LSOutput: rate scalar out of range");
				pthread_mutex_lock(&gDevice_IOMutex);
				gClock_RateScalar = theScalar;
				LS_Reanchor(mach_absolute_time());
				++gClock_ScalarSets;
				pthread_mutex_unlock(&gDevice_IOMutex);
				*outNumberPropertiesChanged = 1;
				outChangedAddresses[0].mSelector = kLS_RateScalar;
				outChangedAddresses[0].mScope = kAudioObjectPropertyScopeGlobal;
				outChangedAddresses[0].mElement = kAudioObjectPropertyElementMain;
			}
			break;

		default:
			theAnswer = kAudioHardwareUnknownPropertyError;
			break;
	};

Done:
	return theAnswer;
}

#pragma mark Stream Property Operations''')

# ---------------------------------------------------------------- IO
sub('''		gDevice_IOIsRunning = 1;
		gDevice_NumberTimeStamps = 0;
		gDevice_AnchorSampleTime = 0;
		gDevice_AnchorHostTime = mach_absolute_time();''', '''		gDevice_IOIsRunning = 1;
		pthread_mutex_lock(&gDevice_IOMutex);
		gDevice_NumberTimeStamps = 0;
		gDevice_AnchorSampleTime = 0;
		gDevice_AnchorHostTime = mach_absolute_time();
		gClock_AnchorSample = 0.0;
		gClock_AnchorHost = (Float64)gDevice_AnchorHostTime;
		gDevice_HostTicksPerFrame = gClock_NominalTicksPerFrame * gClock_RateScalar;
		gLoop_LastWriteSample = -1.0;
		gLoop_LastReadSample = -1.0;
		memset(gLoop_Buffer, 0, sizeof(gLoop_Buffer));
		pthread_mutex_unlock(&gDevice_IOMutex);
		os_log(gLog, "LSOutput: IO start, %.0f Hz, scalar %.9f", gDevice_SampleRate, gClock_RateScalar);''')

sub('''		//	We need to stop the hardware, which in this case means that there's nothing to do.
		gDevice_IOIsRunning = 0;''', '''		//	We need to stop the hardware, which in this case means that there's nothing to do.
		gDevice_IOIsRunning = 0;
		os_log(gLog, "LSOutput: IO stop, written %llu read %llu frames", gLoop_FramesWritten, gLoop_FramesRead);''')

sub('''	//	calculate the next host time
	theHostTicksPerRingBuffer = gDevice_HostTicksPerFrame * ((Float64)kDevice_RingBufferSize);
	theHostTickOffset = ((Float64)(gDevice_NumberTimeStamps + 1)) * theHostTicksPerRingBuffer;
	theNextHostTime = gDevice_AnchorHostTime + ((UInt64)theHostTickOffset);

	//	go to the next time if the next host time is less than the current time
	if(theNextHostTime <= theCurrentHostTime)
	{
		++gDevice_NumberTimeStamps;
	}

	//	set the return values
	*outSampleTime = gDevice_NumberTimeStamps * kDevice_RingBufferSize;
	*outHostTime = gDevice_AnchorHostTime + (((Float64)gDevice_NumberTimeStamps) * theHostTicksPerRingBuffer);
	*outSeed = 1;''', '''	//	calculate the next host time on the (steerable) time line
	theHostTicksPerRingBuffer = gDevice_HostTicksPerFrame * ((Float64)kDevice_RingBufferSize);
	theHostTickOffset = (((Float64)((gDevice_NumberTimeStamps + 1) * kDevice_RingBufferSize)) - gClock_AnchorSample) * gDevice_HostTicksPerFrame;
	theNextHostTime = (UInt64)(gClock_AnchorHost + theHostTickOffset);

	//	go to the next time if the next host time is less than the current time
	if(theNextHostTime <= theCurrentHostTime)
	{
		++gDevice_NumberTimeStamps;
	}

	//	set the return values
	*outSampleTime = gDevice_NumberTimeStamps * kDevice_RingBufferSize;
	*outHostTime = (UInt64)(gClock_AnchorHost + ((((Float64)(gDevice_NumberTimeStamps * kDevice_RingBufferSize)) - gClock_AnchorSample) * gDevice_HostTicksPerFrame));
	*outSeed = gClock_Seed;
	(void)theHostTicksPerRingBuffer;''')

sub('''	//	clear the buffer if this iskAudioServerPlugInIOOperationReadInput
	if(inOperationID == kAudioServerPlugInIOOperationReadInput)
	{
		//	we are always dealing with a 2 channel 32 bit float buffer
		memset(ioMainBuffer, 0, inIOBufferFrameSize * 8);
	}''', '''	//	Loopback, indexed by sample time. Both operations run on this device's IO thread.
	//	We are always dealing with a 2 channel 32 bit float buffer.
	if(inOperationID == kAudioServerPlugInIOOperationWriteMix && inIOCycleInfo->mOutputTime.mSampleTime >= 0.0)
	{
		Float64 theSampleTime = inIOCycleInfo->mOutputTime.mSampleTime;
		UInt64 theStart = (UInt64)theSampleTime % kLoop_Frames;
		UInt32 theFirst = (UInt32)(kLoop_Frames - theStart);
		if(theFirst > inIOBufferFrameSize) theFirst = inIOBufferFrameSize;
		memcpy(&gLoop_Buffer[theStart * 2], ioMainBuffer, theFirst * 8);
		if(theFirst < inIOBufferFrameSize)
		{
			memcpy(gLoop_Buffer, ((Float32*)ioMainBuffer) + theFirst * 2, (inIOBufferFrameSize - theFirst) * 8);
		}
		gLoop_LastWriteSample = theSampleTime;
		gLoop_FramesWritten += inIOBufferFrameSize;
	}
	else if(inOperationID == kAudioServerPlugInIOOperationReadInput && inIOCycleInfo->mInputTime.mSampleTime < 0.0)
	{
		memset(ioMainBuffer, 0, inIOBufferFrameSize * 8);
	}
	else if(inOperationID == kAudioServerPlugInIOOperationReadInput)
	{
		Float64 theSampleTime = inIOCycleInfo->mInputTime.mSampleTime;
		UInt64 theStart = (UInt64)theSampleTime % kLoop_Frames;
		UInt32 theFirst = (UInt32)(kLoop_Frames - theStart);
		if(theFirst > inIOBufferFrameSize) theFirst = inIOBufferFrameSize;
		memcpy(ioMainBuffer, &gLoop_Buffer[theStart * 2], theFirst * 8);
		memset(&gLoop_Buffer[theStart * 2], 0, theFirst * 8);
		if(theFirst < inIOBufferFrameSize)
		{
			memcpy(((Float32*)ioMainBuffer) + theFirst * 2, gLoop_Buffer, (inIOBufferFrameSize - theFirst) * 8);
			memset(gLoop_Buffer, 0, (inIOBufferFrameSize - theFirst) * 8);
		}
		gLoop_LastReadSample = theSampleTime;
		gLoop_FramesRead += inIOBufferFrameSize;
	}''')

# the IO operation's cycle info is used now
sub('#pragma unused(inClientID, inIOCycleInfo, ioSecondaryBuffer)', '#pragma unused(inClientID, ioSecondaryBuffer)')

open(path, "w").write(src)
print("patched", path)
