<#
    HitmanVRFoveationFix v1.5

    v1.5 adds two things to v1.4:

      - A SECOND view-count site. The game sets up its 1/2/4 view count in two
        places; v1.3 found one of them. The other kept pushing 2 and left an
        oval black mask on one eye, with Instinct outlines smearing into it.
        Found by sweeping the 27 unpatched readers of the foveation flag, in two
        rounds. Same instruction shape and same safety argument as the first.

      - The ~1 ms renderer guard now repairs on its own thread. It still only
        rewrites bytes the validated transaction already owns, but it no longer
        waits for the WinForms queue first. On a fast machine the renderer could
        build its GPU state inside that window, which is what produced black
        circles after loading a save for some people and not for others.

    v1.4, unchanged and still here:

      - Refraction-depth copies use the two physical eye views while the
        geometry/visibility renderer keeps its required four logical views.
        This fixes stereo glass, water, bottles and affected lights without
        reintroducing geometry pop-in.

    WHAT IT DOES
      HITMAN renders VR with foveation: four layers per frame, two wide ones at
      half resolution covering the whole field of view, and two narrow ones at
      full resolution covering only a small circle in the centre. Everything
      outside that circle is upscaled from the half-resolution layer, which is
      why it looks like mush on a high resolution headset.

      This tool switches the game to two layers at full resolution instead,
      covering the whole field of view. That is twice the pixel work - four
      quarter-sized slices against two full-sized ones - but the density is what
      matters: 936 px across the old ~49 degree circle is 19.1 px per degree,
      1872 px across the full 99 degrees is 18.9. About a percent apart. You get
      the old sweet-spot sharpness, everywhere.

    HOW TO USE IT
      1. Start this tool
      2. Start HITMAN - however you like, including straight into VR
      3. Play

    BUILD HANDLING
      Build 3.270.1 uses the exact addresses and instruction contexts that were
      developed and tested. Other builds retain the conservative v1.3 pattern
      path: every base and refraction hook pattern must be unique, mutually
      consistent and in its original state or the tool refuses to write.

    SUPPORTED HEADSETS
      Both VR backends the game speaks are supported:

        Oculus  - Quest 2, Quest 3, Quest 3S, Quest Pro, Rift S, via Link or
                  Air Link
        SteamVR - anything that presents itself through OpenVR, including Quest
                  headsets connected with Steam Link or Virtual Desktop

      The device layout turned out to be identical between the two, so the same
      values work for both. The code is not quite identical though: each backend
      has its own device class with its own copy of one function, so that one is
      patched twice, once per class. HITMAN has no OpenXR backend at all, so
      launching through an OpenXR runtime lands on SteamVR anyway.

    WHAT IT TOUCHES
      No game file or setting is modified. The tool writes a small
      foveationfix.log next to itself for diagnostics. All renderer changes are
      made in the memory of the running process and are gone the moment you
      close HITMAN.

      It does write to the memory of a game that has an online connection. That
      is said plainly because you should know it. Use at your own discretion.

    Project page: https://github.com/RealChrizzl/hitman-vr-foveation-fix
    MIT licensed. Made by RealChrizzl.
#>

[CmdletBinding()]
param([string]$ProcessName = "HITMAN3")

$ErrorActionPreference = "Stop"

$FIX_VERSION = "1.5"
$MODE_INFO = [pscustomobject]@{
    Short="v1.5"
    Title="HitmanVRFoveationFix v1.5"
    Warning=""
    UsesHook=$true
    HookKinds=@("Outer","CopyA","CopyB")
    OuterChangesCount=$false
    CopyFrom=4
    CopyTo=2
    UsesMesh4=$false
}

# Reading another process's memory needs administrator rights. If we do not
# have them, ask Windows for them once and restart ourselves.
$me = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $me.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $self = $PSCommandPath
    if (-not $self) { $self = $MyInvocation.MyCommand.Definition }
    try {
        Start-Process -FilePath "powershell.exe" -Verb RunAs -ArgumentList @(
            "-NoProfile","-ExecutionPolicy","Bypass","-WindowStyle","Hidden",
            "-File","`"$self`"","-ProcessName","`"$ProcessName`"")
    } catch {
        Add-Type -AssemblyName System.Windows.Forms
        [Windows.Forms.MessageBox]::Show(
            "This tool needs administrator rights to read the game's memory.`n`nPlease allow the prompt, or right-click the file and choose 'Run as administrator'.",
            "HitmanVRFoveationFix","OK","Warning") | Out-Null
    }
    exit
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
if (-not [Environment]::Is64BitProcess) {
    [Windows.Forms.MessageBox]::Show(
        "HitmanVRFoveationFix v1.5 requires 64-bit Windows PowerShell so live code changes can be verified safely.",
        "HitmanVRFoveationFix","OK","Warning") | Out-Null
    exit
}

# Two instances can both observe stock code before either writes it, then each
# believe it owns the patch. A named mutex closes that race before any game
# handle is opened.
$script:instanceMutex=New-Object Threading.Mutex($false,"Local\HitmanVRFoveationFix")
$script:mutexOwned=$false
try { $script:mutexOwned=$script:instanceMutex.WaitOne(0,$false) }
catch [Threading.AbandonedMutexException] { $script:mutexOwned=$true }
if (-not $script:mutexOwned) {
    [Windows.Forms.MessageBox]::Show(
        "HitmanVRFoveationFix is already running in this Windows session.",
        "HitmanVRFoveationFix","OK","Information") | Out-Null
    $script:instanceMutex.Dispose()
    exit
}

if (-not ("HmFix" -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows.Forms;
using Microsoft.Win32.SafeHandles;
public static class HmFix {
    // A 1 ms Wait timeout is only as accurate as the system timer resolution,
    // which is ~15.6 ms unless something raised it - and since Windows 10 2004
    // another process raising it no longer helps this one. A high-resolution
    // waitable timer is the documented way to actually get single-digit
    // milliseconds without touching the global timer period.
    public const uint CREATE_WAITABLE_TIMER_HIGH_RESOLUTION = 0x00000002;
    public const uint TIMER_ALL_ACCESS = 0x001F0003;
    [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
    public static extern IntPtr CreateWaitableTimerExW(IntPtr attributes, string name, uint flags, uint access);
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool SetWaitableTimer(IntPtr timer, ref long dueTime, int period,
        IntPtr routine, IntPtr arg, bool resume);
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern IntPtr OpenProcess(uint a, bool i, int p);
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool ReadProcessMemory(IntPtr h, IntPtr addr, byte[] buf, int size, out IntPtr read);
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool WriteProcessMemory(IntPtr h, IntPtr addr, byte[] buf, int size, out IntPtr written);
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool FlushInstructionCache(IntPtr h, IntPtr addr, UIntPtr size);
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern IntPtr VirtualAllocEx(IntPtr h, IntPtr addr, UIntPtr size, uint allocationType, uint protect);
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool VirtualProtectEx(IntPtr h, IntPtr addr, UIntPtr size, uint newProtect, out uint oldProtect);
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern IntPtr OpenThread(uint access, bool inheritHandle, uint threadId);
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern uint SuspendThread(IntPtr thread);
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern uint ResumeThread(IntPtr thread);
    [DllImport("kernel32.dll", EntryPoint="GetThreadContext", SetLastError=true)]
    private static extern bool GetThreadContextNative(IntPtr thread, IntPtr context);
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool GetProcessMitigationPolicy(IntPtr process, uint policy, out uint buffer, UIntPtr length);
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);
    [DllImport("kernel32.dll")]
    public static extern bool CloseHandle(IntPtr h);

    // AMD64 CONTEXT is 16-byte aligned. ContextFlags is at +48 and RIP at
    // +248. CONTEXT_CONTROL is sufficient and keeps this helper independent
    // of the large floating-point/vector tail of the structure.
    public static bool TryGetThreadRip(IntPtr thread, out ulong rip, out int error) {
        const int SIZE = 0x4D0;
        rip = 0; error = 0;
        if (!Environment.Is64BitProcess) { error = 193; return false; }
        IntPtr raw = Marshal.AllocHGlobal(SIZE + 15);
        try {
            long alignedValue = (raw.ToInt64() + 15L) & ~15L;
            IntPtr aligned = new IntPtr(alignedValue);
            for (int i = 0; i < SIZE; i += 8) Marshal.WriteInt64(aligned, i, 0L);
            Marshal.WriteInt32(aligned, 0x30, unchecked((int)0x00100001u));
            if (!GetThreadContextNative(thread, aligned)) {
                error = Marshal.GetLastWin32Error(); return false;
            }
            rip = unchecked((ulong)Marshal.ReadInt64(aligned, 0xF8));
            return true;
        } finally { Marshal.FreeHGlobal(raw); }
    }
}

// The fast renderer guard watches the 16-byte scale and 8-byte mask fields on a
// 1 ms thread. Once PowerShell has established ownership of those fields it arms
// the guard, and from then on a mismatch is repaired ON THE GUARD THREAD instead
// of waiting for the WinForms message queue. That is the whole point: on a fast
// machine the renderer can finish building its GPU state inside the window that
// BeginInvoke plus a PowerShell tick costs.
//
// The 1 ms is real, not hoped for. A high-resolution waitable timer is used when
// the OS provides one, and the loop measures its own interval, so the log says
// whether the guard actually ran at 1 ms on this machine or fell back to the
// system timer resolution. A high-resolution timer still does not make the
// scheduler exact; that is precisely why the interval is measured rather than
// assumed.
//
// The repair is deliberately the weakest possible write:
//   - armed only after the validated transaction wrote BOTH fields for this
//     device and read them back clean
//   - the device pointer and the device vtable are re-checked before writing
//   - field of view, scale and mask are re-validated against exactly the same
//     plausibility bounds the PowerShell transaction uses, so a device block that
//     is mid-rebuild or half-constructed is left alone
//   - it never captures stock values, never rolls back, never initialises
//   - it rewrites nothing but the exact fix bytes it was given
//   - it takes the same lock PowerShell uses, and only with TryEnter
//   - it reads back after every write attempt, including a failed or short one,
//     and distinguishes "took", "did not take" and "unknown". An unknown state
//     disarms the guard and raises a fault instead of trying again
//   - a repair is counted only when a field really changed, so contention with
//     PowerShell cannot inflate the counter or trip the reload latch
//
// The transition value is sampled by the guard itself, immediately after a
// successful write. Reading it later on the WinForms thread would be a race: the
// renderer can leave transition 3 before the callback is dispatched.
public sealed class RendererValueGuard : IDisposable {
    private const int FIELD_OK        = 0;   // already correct, nothing done
    private const int FIELD_WRITTEN   = 1;   // changed by us and verified
    private const int FIELD_SKIPPED   = 2;   // not read, or not plausible: untouched
    private const int FIELD_UNCHANGED = 3;   // write did not take; memory as before
    private const int FIELD_UNKNOWN   = 4;   // state after a write attempt is unknown

    private readonly IntPtr process;
    private readonly long device;
    private readonly long devicePointer;
    private readonly long expectedVtable;
    private readonly long fovOffset;
    private readonly long scaleOffset;
    private readonly long maskOffset;
    private readonly long transitionOffset;
    private readonly byte[] expectedScale;
    private readonly byte[] expectedMask;
    private readonly Control dispatcher;
    private readonly Action<RendererValueGuard> callback;
    private readonly object gate;
    private readonly ManualResetEvent stop = new ManualResetEvent(false);
    private readonly ManualResetEvent ready = new ManualResetEvent(false);
    private readonly Thread thread;
    private int signalPending;
    private int stopped;
    private int armed;
    private int transition3Repair;
    private int partialWrite;
    private int highResolution;
    private long reads;
    private long mismatches;
    private long readFailures;
    private long repairs;
    private long repairFailures;
    private long slowIntervals;
    private long maxIntervalMicroseconds;

    public RendererValueGuard(IntPtr process, long device, long devicePointer,
        long expectedVtable, long fovOffset, long scaleOffset, long maskOffset,
        long transitionOffset, byte[] expectedScale, byte[] expectedMask,
        Control dispatcher, Action<RendererValueGuard> callback, object gate) {
        if (process == IntPtr.Zero) throw new ArgumentException("process");
        if (device == 0) throw new ArgumentException("device");
        if (devicePointer == 0) throw new ArgumentException("devicePointer");
        // No silent downgrade: without a vtable to compare against, the guard has
        // no way to notice a released device and must not run at all.
        if (expectedVtable == 0) throw new ArgumentException("expectedVtable");
        if (expectedScale == null || expectedScale.Length != 16) throw new ArgumentException("scale");
        if (expectedMask == null || expectedMask.Length != 8) throw new ArgumentException("mask");
        if (dispatcher == null || callback == null || gate == null) throw new ArgumentNullException();
        this.process = process;
        this.device = device;
        this.devicePointer = devicePointer;
        this.expectedVtable = expectedVtable;
        this.fovOffset = fovOffset;
        this.scaleOffset = scaleOffset;
        this.maskOffset = maskOffset;
        this.transitionOffset = transitionOffset;
        this.expectedScale = (byte[])expectedScale.Clone();
        this.expectedMask = (byte[])expectedMask.Clone();
        this.dispatcher = dispatcher;
        this.callback = callback;
        this.gate = gate;
        thread = new Thread(Run);
        thread.IsBackground = true;
        thread.Name = "HitmanVR renderer guard";
    }

    public long Device { get { return device; } }
    public bool IsRunning { get { return Volatile.Read(ref stopped) == 0 && thread.IsAlive; } }
    public long Reads { get { return Interlocked.Read(ref reads); } }
    public long Mismatches { get { return Interlocked.Read(ref mismatches); } }
    public long ReadFailures { get { return Interlocked.Read(ref readFailures); } }
    public long Repairs { get { return Interlocked.Read(ref repairs); } }
    public long RepairFailures { get { return Interlocked.Read(ref repairFailures); } }
    public long SlowIntervals { get { return Interlocked.Read(ref slowIntervals); } }
    public long MaxIntervalMicroseconds { get { return Interlocked.Read(ref maxIntervalMicroseconds); } }
    public bool HighResolutionTimer { get { return Volatile.Read(ref highResolution) != 0; } }
    public bool IsArmed { get { return Volatile.Read(ref armed) != 0; } }

    public void Arm() { Interlocked.Exchange(ref armed, 1); }
    public void Disarm() { Interlocked.Exchange(ref armed, 0); }

    // True once, if a repair landed while the renderer was at transition 3.
    public bool ConsumeTransition3Repair() {
        return Interlocked.Exchange(ref transition3Repair, 0) != 0;
    }

    // True once, if a write left a field in a state that is neither the value we
    // wanted nor the value that was there before. The guard has disarmed itself.
    public bool ConsumePartialWriteFault() {
        return Interlocked.Exchange(ref partialWrite, 0) != 0;
    }

    // Non-consuming, for the PowerShell transaction to test while it holds the
    // shared lock. The guard sets the fault while it holds that same lock, so
    // whoever acquires it next is guaranteed to see it and can refuse to write.
    public bool HasFault { get { return Volatile.Read(ref partialWrite) != 0; } }

    // Blocks briefly so HighResolutionTimer is meaningful straight afterwards.
    public void Start() {
        thread.Start();
        try { ready.WaitOne(500); } catch { }
    }

    private static bool EqualBytes(byte[] left, byte[] right) {
        if (left.Length != right.Length) return false;
        for (int i = 0; i < left.Length; i++) if (left[i] != right[i]) return false;
        return true;
    }

    // Exactly the bounds Sync-RenderValuesCore uses. A device block that is being
    // rebuilt can hold zeroes or garbage, and that state is deliberately not ours.
    private static bool FloatsInRange(byte[] b, int count, float lo, float hi) {
        for (int i = 0; i < count; i++) {
            float f = BitConverter.ToSingle(b, i * 4);
            if (float.IsNaN(f) || float.IsInfinity(f) || f < lo || f > hi) return false;
        }
        return true;
    }

    private bool ReadExact(long address, byte[] buffer) {
        IntPtr read;
        return HmFix.ReadProcessMemory(process, new IntPtr(address), buffer,
            buffer.Length, out read) && read.ToInt64() == buffer.Length;
    }

    private bool WriteExact(long address, byte[] buffer) {
        IntPtr written;
        return HmFix.WriteProcessMemory(process, new IntPtr(address), buffer,
            buffer.Length, out written) && written.ToInt64() == buffer.Length;
    }

    private bool ReadInt64(long address, byte[] scratch8, out long value) {
        value = 0;
        if (!ReadExact(address, scratch8)) return false;
        value = BitConverter.ToInt64(scratch8, 0);
        return true;
    }

    // The guard holds an address captured when it started. Between a device being
    // released and the 15 ms loop noticing, that address could belong to nothing.
    private bool DeviceStillCurrent(byte[] scratch8) {
        long current;
        if (!ReadInt64(devicePointer, scratch8, out current)) return false;
        if (current != device) return false;
        long vtable;
        if (!ReadInt64(device, scratch8, out vtable)) return false;
        return vtable == expectedVtable;
    }

    // The bytes checked for plausibility are the ones read here, immediately
    // before the write - not the ones sampled a few microseconds earlier in
    // TryRepair. That closes the window where a rebuild starts in between.
    private int RepairField(long address, byte[] expected, byte[] scratch, byte[] before,
                            int floatCount, float lo, float hi, byte[] scratch8) {
        if (!ReadExact(address, scratch)) return FIELD_SKIPPED;
        Buffer.BlockCopy(scratch, 0, before, 0, scratch.Length);
        if (EqualBytes(scratch, expected)) return FIELD_OK;
        if (!FloatsInRange(scratch, floatCount, lo, hi)) return FIELD_SKIPPED;
        // Last look before touching anything.
        if (!DeviceStillCurrent(scratch8)) return FIELD_SKIPPED;
        // The return value is deliberately ignored: WriteProcessMemory can modify
        // a prefix and still report a short write, so only a read-back is truth.
        WriteExact(address, expected);
        // A readback that fails AFTER a write attempt is not a harmless read
        // error - the memory is in a state nobody has seen. Fail closed.
        if (!ReadExact(address, scratch)) return FIELD_UNKNOWN;
        if (EqualBytes(scratch, expected)) return FIELD_WRITTEN;
        if (EqualBytes(scratch, before)) return FIELD_UNCHANGED;
        return FIELD_UNKNOWN;
    }

    private void Fault() {
        Interlocked.Exchange(ref partialWrite, 1);
        Interlocked.Exchange(ref armed, 0);
        Interlocked.Increment(ref repairFailures);
    }

    private void TryRepair(byte[] fov, byte[] scale, byte[] mask,
                           byte[] beforeScale, byte[] beforeMask, byte[] scratch8, byte[] scratch4) {
        if (Volatile.Read(ref armed) == 0) return;
        if (!Monitor.TryEnter(gate)) return;
        try {
            if (Volatile.Read(ref armed) == 0 || stop.WaitOne(0)) return;
            if (!DeviceStillCurrent(scratch8)) return;

            // PREFLIGHT: all of it, or none of it. A block that is half built can
            // have a plausible mask next to an all-zero scale, and writing just the
            // mask would be exactly the thing this guard is not allowed to do.
            // Field of view is only ever a gate here; it is never written.
            if (!ReadExact(device + fovOffset, fov)     || !FloatsInRange(fov,   4,  0.2f,  3.0f)) return;
            if (!ReadExact(device + scaleOffset, scale) || !FloatsInRange(scale, 4, 0.05f, 20.0f)) return;
            if (!ReadExact(device + maskOffset, mask)   || !FloatsInRange(mask,  2, -0.01f, 4.0f)) return;

            // RepairField validates again on the bytes it reads itself, immediately
            // before each write. The two checks are not redundant: this one decides
            // whether a repair may happen at all, that one closes the gap between
            // the decision and the write.
            int rs = RepairField(device + scaleOffset, expectedScale, scale, beforeScale,
                                 4, 0.05f, 20.0f, scratch8);
            bool wrote = (rs == FIELD_WRITTEN);
            int rm = FIELD_SKIPPED;
            // Only OK or WRITTEN may continue. If scale was skipped, something
            // changed under us between the preflight and the write, and the mask
            // is not touched either.
            if (rs == FIELD_OK || rs == FIELD_WRITTEN) {
                rm = RepairField(device + maskOffset, expectedMask, mask, beforeMask,
                                 2, -0.01f, 4.0f, scratch8);
                wrote = wrote || (rm == FIELD_WRITTEN);
            }

            // Anything we really wrote is recorded BEFORE a fault can return, so a
            // verified write is never lost because the other field went wrong.
            if (wrote) {
                Interlocked.Increment(ref repairs);
                // Sampled here, not on the WinForms thread later.
                if (ReadExact(device + transitionOffset, scratch4) &&
                    BitConverter.ToUInt32(scratch4, 0) == 3) {
                    Interlocked.Exchange(ref transition3Repair, 1);
                }
            }

            if (rs == FIELD_UNKNOWN || rm == FIELD_UNKNOWN) { Fault(); return; }
            if (rs == FIELD_UNCHANGED || rm == FIELD_UNCHANGED) {
                Interlocked.Increment(ref repairFailures);
            }
        } catch {
            Interlocked.Increment(ref repairFailures);
        } finally {
            Monitor.Exit(gate);
        }
    }

    private ManualResetEvent CreateTick() {
        IntPtr raw = HmFix.CreateWaitableTimerExW(IntPtr.Zero, null,
            HmFix.CREATE_WAITABLE_TIMER_HIGH_RESOLUTION, HmFix.TIMER_ALL_ACCESS);
        if (raw == IntPtr.Zero) return null;
        long due = -10000;   // 1 ms, relative
        if (!HmFix.SetWaitableTimer(raw, ref due, 1, IntPtr.Zero, IntPtr.Zero, false)) {
            new SafeWaitHandle(raw, true).Dispose();
            return null;
        }
        ManualResetEvent tick = new ManualResetEvent(false);
        tick.SafeWaitHandle = new SafeWaitHandle(raw, true);
        Interlocked.Exchange(ref highResolution, 1);
        return tick;
    }

    private void Run() {
        byte[] fov = new byte[16];
        byte[] scale = new byte[16];
        byte[] mask = new byte[8];
        byte[] beforeScale = new byte[16];
        byte[] beforeMask = new byte[8];
        byte[] scratch8 = new byte[8];
        byte[] scratch4 = new byte[4];
        ManualResetEvent tick = null;
        WaitHandle[] waits = null;
        Stopwatch watch = Stopwatch.StartNew();
        long last = 0;
        try {
            try { tick = CreateTick(); } catch { tick = null; }
            if (tick != null) waits = new WaitHandle[] { stop, tick };
            ready.Set();
            // Start the interval clock here, so timer creation and thread start-up
            // are not reported as a slow poll.
            last = watch.ElapsedTicks;
            while (true) {
                if (waits != null) {
                    if (WaitHandle.WaitAny(waits) == 0) break;
                } else {
                    if (stop.WaitOne(1)) break;
                }

                long now = watch.ElapsedTicks;
                long us = (now - last) * 1000000L / Stopwatch.Frequency;
                last = now;
                if (us > 4000) Interlocked.Increment(ref slowIntervals);
                if (us > Interlocked.Read(ref maxIntervalMicroseconds)) {
                    Interlocked.Exchange(ref maxIntervalMicroseconds, us);
                }

                bool scaleRead = ReadExact(device + scaleOffset, scale);
                bool maskRead = scaleRead && ReadExact(device + maskOffset, mask);
                if (!scaleRead || !maskRead) {
                    Interlocked.Increment(ref readFailures);
                    continue;
                }
                Interlocked.Increment(ref reads);
                if (EqualBytes(scale, expectedScale) && EqualBytes(mask, expectedMask)) continue;
                Interlocked.Increment(ref mismatches);
                TryRepair(fov, scale, mask, beforeScale, beforeMask, scratch8, scratch4);
                if (Interlocked.CompareExchange(ref signalPending, 1, 0) != 0) continue;
                try {
                    if (stop.WaitOne(0) || dispatcher.IsDisposed || !dispatcher.IsHandleCreated) {
                        Interlocked.Exchange(ref signalPending, 0);
                        continue;
                    }
                    dispatcher.BeginInvoke(callback, new object[] { this });
                } catch {
                    Interlocked.Exchange(ref signalPending, 0);
                }
            }
        } finally {
            Interlocked.Exchange(ref stopped, 1);
            ready.Set();
            if (tick != null) { try { tick.Close(); } catch { } }
        }
    }

    public void CompleteSignal() { Interlocked.Exchange(ref signalPending, 0); }

    public bool Stop(int milliseconds) {
        stop.Set();
        if (Thread.CurrentThread == thread) return false;
        bool joined = !thread.IsAlive || thread.Join(milliseconds);
        if (joined) Interlocked.Exchange(ref stopped, 1);
        return joined;
    }

    public void Dispose() {
        Stop(2000);
        stop.Dispose();
        ready.Dispose();
    }
}
'@ -ReferencedAssemblies @("System.Windows.Forms")
}

# ===========================================================================
#  VERIFIED PATH - build 3.270.1; v1.3 base plus the confirmed v1.4 W fix
# ===========================================================================
$VERIFIED_TIMESTAMP    = 1781013974
$VERIFIED_SHA256       = "B4FB04F460FD67E67F21264D7AD0D64BC081FBA62EC71E36B898D04DB9E8620D"
$MANAGER_RVA           = 0x03225D20L
$MANAGER_VTABLE_RVA    = 0x01EF5398L
$MANAGER_DEVICE_OFFSET = 0x141A0L
$OCULUS_VTABLE_RVA     = 0x01F016C0L    # ZRenderVRDeviceOculus
$OPENVR_VTABLE_RVA     = 0x01EFE020L    # ZRenderVRDeviceOpenVR - same layout, verified by probe
$VERIFIED_WNO_OFF      = 0x31BL

$VERIFIED_WNO_WRITERS = @(
  [pscustomobject]@{ Name="v1.3 WNO writer A"
                     RVA=0x011D8B9EL
                     Stock=[byte[]](0x0F,0x94,0xC1)
                     Fix  =[byte[]](0xB1,0x00,0x90) }
  [pscustomobject]@{ Name="v1.3 WNO writer B"
                     RVA=0x011D8BC1L
                     Stock=[byte[]](0x0F,0x94,0xC0)
                     Fix  =[byte[]](0xB0,0x00,0x90) }
)

$VERIFIED_PRIMARY_DEPTH_CB = @(
  [pscustomobject]@{ Name="v1.3 depth flag Oculus"
                     RVA=0x012C1EACL          # primary depth/tile CB flag, Oculus
                     Stock=[byte[]](0x0F,0xB6,0x87,0x1B,0x03,0x00,0x00)
                     Fix  =[byte[]](0xB8,0x01,0x00,0x00,0x00,0x90,0x90) }
  [pscustomobject]@{ Name="v1.3 depth flag OpenVR"
                     RVA=0x012499CCL          # primary depth/tile CB flag, OpenVR
                     Stock=[byte[]](0x0F,0xB6,0x87,0x1B,0x03,0x00,0x00)
                     Fix  =[byte[]](0xB8,0x01,0x00,0x00,0x00,0x90,0x90) }
)

$VERIFIED_VIEW_COUNT =
  [pscustomobject]@{ Name="v1.3 view count"
                     RVA=0x01161FE9L
                     Stock=[byte[]](0x80,0xB8,0x1B,0x03,0x00,0x00,0x00)
                     Fix  =[byte[]](0x48,0x85,0xE4,0x90,0x90,0x90,0x90) }

# The same 1/2/4 view count is set up in a SECOND place. v1.3 patched one of
# them; the other kept pushing 2 and produced the oval mask on one eye. Same
# instruction shape, same reasoning, same fix - see HOW-IT-WORKS.md section 3.
$VERIFIED_VIEW_COUNT_2 =
  [pscustomobject]@{ Name="v1.5 view count 2"
                     RVA=0x01162E3CL
                     Stock=[byte[]](0x80,0xB9,0x1B,0x03,0x00,0x00,0x00)
                     Fix  =[byte[]](0x48,0x85,0xE4,0x90,0x90,0x90,0x90) }

# Most experimental sites below take one locally WNO-dependent producer or
# consumer down the stock WNO=1 path while the device itself remains in v1.3's
# two-slice state. `test rsp,rsp` plus NOPs makes ZF=0 without changing control
# flow or using new executable memory. CopyRefractionDepth is the one exception:
# its three-byte load is replaced with a same-size base-slice-zero assignment.
$REFRACTION_DEPTH_ZERO =
  [pscustomobject]@{ Name="CopyRefractionDepth base slice zero"
                     RVA=0x0128FF20L
                     Stock=[byte[]](0x8B,0x6E,0x20)
                     Fix  =[byte[]](0x31,0xED,0x90) }

$CAMERA_STATE_4 =
  [pscustomobject]@{ Name="extended camera state"
                     RVA=0x011B4625L
                     Stock=[byte[]](0x44,0x38,0xB9,0x1B,0x03,0x00,0x00)
                     Fix  =[byte[]](0x48,0x85,0xE4,0x90,0x90,0x90,0x90) }

$ASSAO_DEPTH_4 =
  [pscustomobject]@{ Name="four-view ASSAO depth preparation"
                     RVA=0x012886DAL
                     Stock=[byte[]](0x80,0xB8,0x1B,0x03,0x00,0x00,0x00)
                     Fix  =[byte[]](0x48,0x85,0xE4,0x90,0x90,0x90,0x90) }

$CAMERA_RECORDS_4 =
  [pscustomobject]@{ Name="four-view camera records"
                     RVA=0x0129297EL
                     Stock=[byte[]](0x80,0xB8,0x1B,0x03,0x00,0x00,0x00)
                     Fix  =[byte[]](0x48,0x85,0xE4,0x90,0x90,0x90,0x90) }

$OCCLUDER_STATE_4 = @(
  [pscustomobject]@{ Name="occluder matrix preprocess"
                     RVA=0x01298B1DL
                     Stock=[byte[]](0x44,0x38,0xA8,0x1B,0x03,0x00,0x00)
                     Fix  =[byte[]](0x48,0x85,0xE4,0x90,0x90,0x90,0x90) }
  [pscustomobject]@{ Name="occluder matrix restore"
                     RVA=0x0129987CL
                     Stock=[byte[]](0x80,0xB8,0x1B,0x03,0x00,0x00,0x00)
                     Fix  =[byte[]](0x48,0x85,0xE4,0x90,0x90,0x90,0x90) }
)

$SSR_FRUSTA_4 =
  [pscustomobject]@{ Name="four-view SSR frusta"
                     RVA=0x0129DE92L
                     Stock=[byte[]](0x80,0xB8,0x1B,0x03,0x00,0x00,0x00)
                     Fix  =[byte[]](0x48,0x85,0xE4,0x90,0x90,0x90,0x90) }

$CORE_DRAW_GATES_4 = @(
  [pscustomobject]@{ Name="core DrawGate A"
                     RVA=0x01296BEFL
                     Stock=[byte[]](0x40,0x38,0xB0,0x1B,0x03,0x00,0x00)
                     Fix  =[byte[]](0x48,0x85,0xE4,0x90,0x90,0x90,0x90) }
  [pscustomobject]@{ Name="core DrawGate B"
                     RVA=0x0129706CL
                     Stock=[byte[]](0x80,0xB8,0x1B,0x03,0x00,0x00,0x00)
                     Fix  =[byte[]](0x48,0x85,0xE4,0x90,0x90,0x90,0x90) }
)

# With the global render-context count left at two, this changes only the
# instance-multiplier constant consumed by CullScatter's visibility shader.
# CullScatter's other two tests distinguish one view from more than one, so
# their behaviour is identical for the two-view and four-view profiles.
$CULL_SCATTER_4 =
  [pscustomobject]@{ Name="CullScatter instance multiplier four"
                     RVA=0x0127AABBL
                     Stock=[byte[]](0x41,0x8B,0x46,0x14,0x41,0x8B,0x0C,0x86)
                     Fix  =[byte[]](0xB9,0x04,0x00,0x00,0x00,0x90,0x90,0x90) }

# v1.4 redirects only exact instruction blocks. Every replacement uses a
# normal indirect CALL followed by an inline jump over its 64-bit pointer. The
# private wrapper returns normally, so Windows shadow-stack/CET CALL/RET symmetry
# is retained. No replacement consumes another engine context-stack slot.
$TRANSPARENT_PASS_CALL =
  [pscustomobject]@{ Name="DrawRefractiveAndTransparent camera call"
                     Kind="Outer"
                     RVA=0x011B892AL
                     TargetRVA=0x01290220L
                     ContinuationRVA=0x011B893CL
                     UnitOffset=0x000L
                     Stock=[byte[]](0x48,0x8B,0x8C,0x24,0xC0,0x00,0x00,0x00,0x48,0x89,0x44,0x24,0x20,0xE8,0xE4,0x78,0x0D,0x00) }

$COPY_DEPTH_CALL_A =
  [pscustomobject]@{ Name="CopyRefractionDepth call A"
                     Kind="CopyA"
                     RVA=0x01290BA2L
                     TargetRVA=0x0128FE20L
                     ContinuationRVA=0x01290BB7L
                     UnitOffset=0x400L
                     CounterOffset=0x60L
                     Stock=[byte[]](0x4D,0x8B,0xC4,0x8B,0x41,0x04,0x44,0x8B,0x09,0x48,0x8B,0xCE,0x89,0x44,0x24,0x20,0xE8,0x69,0xF2,0xFF,0xFF) }

$COPY_DEPTH_CALL_B =
  [pscustomobject]@{ Name="CopyRefractionDepth call B"
                     Kind="CopyB"
                     RVA=0x01291386L
                     TargetRVA=0x0128FE20L
                     ContinuationRVA=0x0129139BL
                     UnitOffset=0x600L
                     CounterOffset=0x80L
                     Stock=[byte[]](0x4D,0x8B,0xC4,0x8B,0x41,0x04,0x44,0x8B,0x09,0x48,0x8B,0xCE,0x89,0x44,0x24,0x20,0xE8,0x85,0xEA,0xFF,0xFF) }

$MESH_COUNT_HOOK =
  [pscustomobject]@{ Name="transparent indexed-mesh instance multiplier"
                     Kind="Mesh"
                     RVA=0x0121C91AL
                     ContinuationRVA=0x0121C92BL
                     UnitOffset=0x200L
                     Stock=[byte[]](0x8B,0x41,0x14,0x41,0x8B,0xE9,0x45,0x8B,0xF0,0x8B,0xF2,0x48,0x8B,0xD9,0x8B,0x3C,0x81) }

# The old water wrapper and the unrelated particle-lighting multiplier are
# stock-only guards. Test S already proved that the water wrapper adds nothing;
# reverse engineering proved the sprite multiplier runs before this pass.
$WATER_PASS_CALL =
  [pscustomobject]@{ Name="DrawWaterRefractive camera call"
                     Kind="WaterGuard"
                     RVA=0x011B83CAL
                     TargetRVA=0x0127E260L
                     ContinuationRVA=0x011B83E1L
                     Stock=[byte[]](0x48,0x8D,0x84,0x24,0xE0,0x01,0x00,0x00,0x48,0x89,0x5C,0x24,0x28,0x48,0x89,0x44,0x24,0x20,0xE8,0x7F,0x5E,0x0C,0x00) }
$SPRITE_COUNT_GUARD =
  [pscustomobject]@{ Name="unrelated particle-lighting instance multiplier"
                     Kind="SpriteGuard"
                     RVA=0x012EB2B4L
                     Stock=[byte[]](0x48,0x8B,0xCB,0x44,0x8D,0x42,0x14,0x0F,0xB7,0x74,0xC7,0x32,0x8B,0x43,0x14,0x0F,0xAF,0x34,0x83) }

# Publish all inner blocks first and the outer camera entry last. Reverse
# rollback therefore removes the entry gate first even on a partial failure.
$ALL_HOOK_SITES=@($COPY_DEPTH_CALL_A,$COPY_DEPTH_CALL_B,$MESH_COUNT_HOOK,$TRANSPARENT_PASS_CALL)

# Exact on-disk instruction contexts for every profile-sensitive site. Each
# sequence is unique in build 3.270.1.
$VERIFIED_DIAGNOSTIC_CONTEXTS = @(
  [pscustomobject]@{ RVA=0x012499A0L
                     Bytes=[byte[]](0x50,0x09,0x00,0x00,0x45,0x33,0xC0,0x4C,0x8B,0x8E,0xC8,0x7A,0x00,0x00,0x48,0x8B,0xD3,0x48,0x89,0x6C,0x24,0x28,0x48,0x89,0x6C,0x24,0x20,0x48,0x8B,0x01,0xFF,0x50,0x28,0x48,0x8B,0xCB,0xE8,0x57,0x66,0xFD,0xFF,0xFF,0x4B,0x14,0x0F,0xB6,0x87,0x1B,0x03,0x00,0x00) }
  [pscustomobject]@{ RVA=0x012C1E80L
                     Bytes=[byte[]](0xC0,0x08,0x00,0x00,0x45,0x33,0xC0,0x4C,0x8B,0x8E,0xC8,0x7A,0x00,0x00,0x48,0x8B,0xD3,0x48,0x89,0x6C,0x24,0x28,0x48,0x89,0x6C,0x24,0x20,0x48,0x8B,0x01,0xFF,0x50,0x28,0x48,0x8B,0xCB,0xE8,0x77,0xE1,0xF5,0xFF,0xFF,0x4B,0x14,0x0F,0xB6,0x87,0x1B,0x03,0x00,0x00) }
  [pscustomobject]@{ RVA=0x01296BEAL
                     Bytes=[byte[]](0xB9,0x03,0x00,0x00,0x00,0x40,0x38,0xB0,0x1B,0x03,0x00,0x00,0x41,0x0F,0x44,0xCF,0x44,0x3B,0xC9,0x0F,0x83) }
  [pscustomobject]@{ RVA=0x01297067L
                     Bytes=[byte[]](0xB9,0x03,0x00,0x00,0x00,0x80,0xB8,0x1B,0x03,0x00,0x00,0x00,0x41,0x0F,0x44,0xC9,0x3B,0xF1,0x0F,0x83) }
  [pscustomobject]@{ RVA=0x0128FF16L
                     Bytes=[byte[]](0x48,0x8B,0xB0,0xE0,0x00,0x00,0x00,0x8B,0x47,0x14,0x8B,0x6E,0x20,0x44,0x8B,0xFD,0x8D,0x4D,0xFF,0x03,0x4E,0x24,0x83,0x3C,0x87,0x01,0x44,0x0F,0x46,0xF9,0x48,0x85,0xDB) }
  [pscustomobject]@{ RVA=0x011B4619L
                     Bytes=[byte[]](0x48,0x8B,0x0D,0xA0,0x58,0x08,0x02,0x8B,0xD6,0x48,0x8B,0x01,0x44,0x38,0xB9,0x1B,0x03,0x00,0x00,0x0F,0x84,0x6C,0x01,0x00,0x00,0xFF,0x90,0x30,0x01,0x00,0x00,0x0F,0x10,0x40,0x40) }
  [pscustomobject]@{ RVA=0x01292963L
                     Bytes=[byte[]](0xBB,0x04,0x00,0x00,0x00,0x48,0x8B,0x05,0x51,0x75,0xFA,0x01,0x0F,0x28,0x3D,0xEA,0x19,0x9B,0x00,0xB9,0x02,0x00,0x00,0x00,0x0F,0x28,0xEE,0x80,0xB8,0x1B,0x03,0x00,0x00,0x00,0x0F,0x29,0xB5,0xE0,0x07,0x00,0x00,0x0F,0x10,0x96,0x90,0x02,0x00,0x00,0x0F,0x44,0xD9,0x89,0x9D,0xA0,0x0B,0x00,0x00,0x0F,0x29,0x95,0xF0,0x07) }
  [pscustomobject]@{ RVA=0x012886DAL
                     Bytes=[byte[]](0x80,0xB8,0x1B,0x03,0x00,0x00,0x00,0x0F,0x84,0x32,0x03,0x00,0x00,0xF3,0x44,0x0F,0x10,0x05,0xF8,0x49,0x32,0x03) }
  [pscustomobject]@{ RVA=0x01298B11L
                     Bytes=[byte[]](0x48,0x8B,0x05,0xA8,0x13,0xFA,0x01,0xB9,0x03,0x00,0x00,0x00,0x44,0x38,0xA8,0x1B,0x03,0x00,0x00,0x0F,0x44,0xCF,0x44,0x3B,0xC1,0x73,0x79,0x41,0x8D,0x50,0x01,0x41,0x8B,0xC0,0x8B) }
  [pscustomobject]@{ RVA=0x01299870L
                     Bytes=[byte[]](0x48,0x8B,0x05,0x49,0x06,0xFA,0x01,0xB9,0x03,0x00,0x00,0x00,0x80,0xB8,0x1B,0x03,0x00,0x00,0x00,0x0F,0x44,0xCB,0x44,0x3B,0xE9,0x73,0x4D,0x41,0x8D,0x55,0x01,0x41,0x8B,0xCD,0x48) }
  [pscustomobject]@{ RVA=0x0129DE80L
                     Bytes=[byte[]](0x48,0x8B,0x05,0x39,0xC0,0xF9,0x01,0xB9,0x02,0x00,0x00,0x00,0x41,0xBE,0x04,0x00,0x00,0x00,0x80,0xB8,0x1B,0x03,0x00,0x00,0x00,0x44,0x0F,0x44,0xF1,0x44,0x0F,0x28,0x25,0x6B,0xC7,0xCB,0x00) }
  [pscustomobject]@{ RVA=0x0127AAABL
                     Bytes=[byte[]](0x74,0x0E,0xF3,0x0F,0x10,0x84,0x24,0x28,0x01,0x00,0x00,0xF3,0x0F,0x11,0x04,0x38,0x41,0x8B,0x46,0x14,0x41,0x8B,0x0C,0x86,0x8B,0x82,0x60,0x61,0x00,0x00,0x89,0x8C,0x24,0x28,0x01,0x00,0x00,0x49,0x3B,0xC0,0x74,0x0E,0xF3,0x0F,0x10,0x84,0x24,0x28) }
  [pscustomobject]@{ RVA=0x0121C90AL
                     Bytes=[byte[]](0x48,0x89,0x74,0x24,0x18,0x48,0x89,0x7C,0x24,0x20,0x41,0x56,0x48,0x83,0xEC,0x30,0x8B,0x41,0x14,0x41,0x8B,0xE9,0x45,0x8B,0xF0,0x8B,0xF2,0x48,0x8B,0xD9,0x8B,0x3C,0x81,0xE8,0x80,0x64,0x00,0x00,0x48,0x8B,0x8B,0xF8,0x16,0x00,0x00,0xE8,0x24,0x40,0xFC,0xFF,0x48,0x8B,0x8B,0x00,0x17,0x00,0x00) }
  [pscustomobject]@{ RVA=0x01290220L
                     Bytes=[byte[]](0x4C,0x89,0x4C,0x24,0x20,0x48,0x89,0x4C,0x24,0x08,0x55,0x53,0x56,0x57,0x41,0x54,0x41,0x56,0x41,0x57,0x48,0x81,0xEC,0xB0,0x01,0x00,0x00) }
  [pscustomobject]@{ RVA=0x01291BC2L
                     Bytes=[byte[]](0x0F,0x28,0xBD,0x30,0x01,0x00,0x00,0x44,0x0F,0x28,0x85,0x20,0x01,0x00,0x00,0x44,0x0F,0x28,0x8D,0x10,0x01,0x00,0x00,0x48,0x8D,0xA5,0x50,0x01,0x00,0x00,0x41,0x5F,0x41,0x5E,0x41,0x5C,0x5F,0x5E,0x5B,0x5D,0xC3) }
  [pscustomobject]@{ RVA=0x0127E260L
                     Bytes=[byte[]](0x4C,0x89,0x4C,0x24,0x20,0x4C,0x89,0x44,0x24,0x18,0x41,0x55,0x41,0x57) }
  [pscustomobject]@{ RVA=0x0127FA73L
                     Bytes=[byte[]](0x48,0x81,0xC4,0x78,0x02,0x00,0x00,0x41,0x5F,0x41,0x5D,0xC3) }
  [pscustomobject]@{ RVA=0x011B892AL
                     Bytes=[byte[]](0x48,0x8B,0x8C,0x24,0xC0,0x00,0x00,0x00,0x48,0x89,0x44,0x24,0x20,0xE8,0xE4,0x78,0x0D,0x00,0x48,0x8D,0x8C,0x24,0x60,0x02,0x00,0x00) }
  [pscustomobject]@{ RVA=0x011B83CAL
                     Bytes=[byte[]](0x48,0x8D,0x84,0x24,0xE0,0x01,0x00,0x00,0x48,0x89,0x5C,0x24,0x28,0x48,0x89,0x44,0x24,0x20,0xE8,0x7F,0x5E,0x0C,0x00,0x48,0x85,0xDB,0x74,0x45) }
  [pscustomobject]@{ RVA=0x01290B90L
                     Bytes=[byte[]](0x48,0x8B,0x8D,0xB0,0x01,0x00,0x00,0x48,0x8D,0x95,0xD0,0x01,0x00,0x00,0x89,0x44,0x24,0x28,0x4D,0x8B,0xC4,0x8B,0x41,0x04,0x44,0x8B,0x09,0x48,0x8B,0xCE,0x89,0x44,0x24,0x20,0xE8,0x69,0xF2,0xFF,0xFF,0x48,0x8B,0x9D,0xD0,0x01,0x00,0x00,0x48,0x8B,0xF8,0x48,0x8B,0x0D,0xD8,0x92,0xFA,0x01,0x4C,0x8D,0x0D,0xB1,0xF3,0xC6,0x00) }
  [pscustomobject]@{ RVA=0x01291374L
                     Bytes=[byte[]](0x48,0x8B,0x8D,0xB0,0x01,0x00,0x00,0x48,0x8D,0x95,0xD0,0x01,0x00,0x00,0x89,0x44,0x24,0x28,0x4D,0x8B,0xC4,0x8B,0x41,0x04,0x44,0x8B,0x09,0x48,0x8B,0xCE,0x89,0x44,0x24,0x20,0xE8,0x85,0xEA,0xFF,0xFF,0x48,0x8B,0x9D,0xD0,0x01,0x00,0x00,0x48,0x8B,0xF8,0x48,0x8B,0x85,0xB0,0x01,0x00,0x00,0x4C,0x8B,0x40,0x60,0x4D,0x85,0xC0) }
  [pscustomobject]@{ RVA=0x012EB2A4L
                     Bytes=[byte[]](0x80,0x00,0x00,0x00,0xBA,0x01,0x00,0x00,0x00,0x4C,0x8B,0x4F,0x20,0x48,0x03,0xC0,0x48,0x8B,0xCB,0x44,0x8D,0x42,0x14,0x0F,0xB7,0x74,0xC7,0x32,0x8B,0x43,0x14,0x0F,0xAF,0x34,0x83,0xE8,0x14,0x47,0xF3,0xFF,0x4C,0x8B,0x83,0x38,0x0F,0x00,0x00,0x33,0xC9,0x4D,0x85,0xC0,0x74,0x05,0x4D,0x8B,0x00,0xEB,0x03) }
  [pscustomobject]@{ RVA=0x0128FE20L
                     Bytes=[byte[]](0x48,0x89,0x5C,0x24,0x10,0x48,0x89,0x6C,0x24,0x18,0x56,0x57,0x41,0x54,0x41,0x56,0x41,0x57,0x48,0x81,0xEC,0xA0,0x00,0x00,0x00,0x48,0x8B,0x05,0x60,0xA0,0xFA,0x01) }
)

$COMMON_TWO_LAYER_CODE = @($VERIFIED_WNO_WRITERS) + @($VERIFIED_PRIMARY_DEPTH_CB)
$BASELINE_CODE = @($COMMON_TWO_LAYER_CODE) + @($VERIFIED_VIEW_COUNT) + @($VERIFIED_VIEW_COUNT_2)
$CORE_VIEW_EXTENSION = @($CAMERA_RECORDS_4) + @($CORE_DRAW_GATES_4) + @($OCCLUDER_STATE_4)
$LEGACY_TESTKIT3_SITES = @($REFRACTION_DEPTH_ZERO) + @($CAMERA_STATE_4) + @($ASSAO_DEPTH_4) + @($SSR_FRUSTA_4) + @($CORE_VIEW_EXTENSION)
$ALL_PROFILE_SITES = @($VERIFIED_VIEW_COUNT) + @($CULL_SCATTER_4) + @($LEGACY_TESTKIT3_SITES)
$VERIFIED_CODE = @($BASELINE_CODE)

# Every earlier experimental site remains stock-only. Selected v1.4 call blocks
# are owned by the atomic hook transaction; every unselected block is a guard.
$VERIFIED_GUARDS = @($ALL_PROFILE_SITES) + @($WATER_PASS_CALL) + @($SPRITE_COUNT_GUARD)
$selectedRvas=@($VERIFIED_CODE | ForEach-Object { [Int64]$_.RVA })
$VERIFIED_GUARDS=@($VERIFIED_GUARDS | Where-Object { $selectedRvas -notcontains [Int64]$_.RVA })
foreach ($hookCall in $ALL_HOOK_SITES) {
    if ($MODE_INFO.HookKinds -notcontains $hookCall.Kind) {
        $VERIFIED_GUARDS += $hookCall
    }
}
$profileRvas=@($VERIFIED_CODE | ForEach-Object { [Int64]$_.RVA }) +
             @($VERIFIED_GUARDS | ForEach-Object { [Int64]$_.RVA }) +
             @($ALL_HOOK_SITES | Where-Object { $MODE_INFO.HookKinds -contains $_.Kind } | ForEach-Object { [Int64]$_.RVA })
if (@($profileRvas | Sort-Object -Unique).Count -ne $profileRvas.Count) {
    throw "Internal v1.4 profile error: duplicate code/guard RVA." }
foreach ($site in $VERIFIED_CODE) {
    if ($site.Stock.Length -ne $site.Fix.Length) {
        throw ("Internal v1.4 profile error: unequal patch length at 0x{0:X}." -f $site.RVA) } }

# ===========================================================================
#  PATTERN PATH - used only when the build is not the verified one
# ===========================================================================
$SIGS = @(
  [pscustomobject]@{ Hit=9;  Fix=[byte[]](0xB1,0x00,0x90)
    Pattern="8B 97 D8 04 00 00 83 FA 01 0F 94 C1 88 8F 1B 03 00 00"
    What="two layers instead of four (writer A)" }
  [pscustomobject]@{ Hit=9;  Fix=[byte[]](0xB0,0x00,0x90)
    Pattern="8B 97 D8 04 00 00 83 FA 01 0F 94 C0 88 87 1B 03 00 00"
    What="two layers instead of four (writer B)" }
  [pscustomobject]@{ Hit=44; Fix=[byte[]](0xB8,0x01,0x00,0x00,0x00,0x90,0x90)
    Pattern="C0 08 00 00 45 33 C0 4C 8B 8E C8 7A 00 00 48 8B D3 48 89 6C 24 28 48 89 6C 24 20 48 8B 01 FF 50 28 48 8B CB E8 ?? ?? ?? ?? FF 4B 14 0F B6 87 1B 03 00 00"
    What="full field of view, Oculus device" }
  [pscustomobject]@{ Hit=44; Fix=[byte[]](0xB8,0x01,0x00,0x00,0x00,0x90,0x90)
    Pattern="50 09 00 00 45 33 C0 4C 8B 8E C8 7A 00 00 48 8B D3 48 89 6C 24 28 48 89 6C 24 20 48 8B 01 FF 50 28 48 8B CB E8 ?? ?? ?? ?? FF 4B 14 0F B6 87 1B 03 00 00"
    What="full field of view, OpenVR device" }
  [pscustomobject]@{ Hit=12; Fix=[byte[]](0x48,0x85,0xE4,0x90,0x90,0x90,0x90)
    Pattern="74 16 49 8B 85 A0 41 01 00 41 8B CF 80 B8 1B 03 00 00 00 0F 45 CF"
    What="view count 4 - without this, geometry disappears" }
  [pscustomobject]@{ Hit=9;  Fix=[byte[]](0x48,0x85,0xE4,0x90,0x90,0x90,0x90)
    Pattern="49 8B 8D A0 41 01 00 74 1A 80 B9 1B 03 00 00 00 BF 02 00 00"
    What="view count 4, second site - without this, one eye keeps an oval mask" }
)

# The production transparency fix is located independently of the five v1.3
# sites. The relative CALL displacement is wildcarded and decoded after the
# whole surrounding sequence is proven unique. Both inner calls must resolve to
# the same CopyRefractionDepth function or the untested build is rejected.
$HOOK_SIGS = @(
  [pscustomobject]@{ Name="DrawRefractiveAndTransparent camera call"; Kind="Outer"
    Hit=0; Length=18; CallOffset=13; UnitOffset=0x000L; CounterOffset=0L
    Pattern="48 8B 8C 24 C0 00 00 00 48 89 44 24 20 E8 ?? ?? ?? ?? 48 8D 8C 24 60 02 00 00" }
  [pscustomobject]@{ Name="CopyRefractionDepth call A"; Kind="CopyA"
    Hit=18; Length=21; CallOffset=16; UnitOffset=0x400L; CounterOffset=0x60L
    Pattern="48 8B 8D B0 01 00 00 48 8D 95 D0 01 00 00 89 44 24 28 4D 8B C4 8B 41 04 44 8B 09 48 8B CE 89 44 24 20 E8 ?? ?? ?? ?? 48 8B 9D D0 01 00 00 48 8B F8 48 8B 0D ?? ?? ?? ?? 4C 8D 0D ?? ?? ?? ??" }
  [pscustomobject]@{ Name="CopyRefractionDepth call B"; Kind="CopyB"
    Hit=18; Length=21; CallOffset=16; UnitOffset=0x600L; CounterOffset=0x80L
    Pattern="48 8B 8D B0 01 00 00 48 8D 95 D0 01 00 00 89 44 24 28 4D 8B C4 8B 41 04 44 8B 09 48 8B CE 89 44 24 20 E8 ?? ?? ?? ?? 48 8B 9D D0 01 00 00 48 8B F8 48 8B 85 B0 01 00 00 4C 8B 40 60 4D 85 C0" }
)
# Locator only, never patched.
$SIG_DEVICE_PAT = "48 8B 0D ?? ?? ?? ?? 8B D6 48 8B 01 44 38 B9 1B 03 00 00 0F 84"
$SIG_DEVICE_REL = 3
$SIG_DEVICE_DSP = 15

# --- device field offsets --------------------------------------------------
$OFF_ACTIVE=0x319L; $OFF_TRANS=0x4D8L; $OFF_W=0x510L; $OFF_H=0x514L
$OFF_LAYERS=0x520L; $OFF_TEX=0x530L
$OFF_FOV=0x420L; $OFF_SCALE=0x490L; $OFF_MASK=0x4C0L
[UInt32[]]$SCALE_FIX    = 0x3F800000,0x3F800000,0x3F800000,0x3F800000
[UInt32[]]$SCALE_STOCK  = 0x3EDF2BF0,0x3ECE8B44,0x4012D426,0x401EA625
[byte[]]$MASK_FIX       = 0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00
[byte[]]$MASK_STOCK     = 0x3D,0x2D,0x66,0x3F, 0xDA,0xB9,0x4D,0x3E

$SELF_DIR =
    if ($PSScriptRoot) { $PSScriptRoot }
    elseif ($MyInvocation.MyCommand.Path) { Split-Path -Parent $MyInvocation.MyCommand.Path }
    else { Split-Path -Parent ([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName) }
$LOG_PATH = Join-Path $SELF_DIR "foveationfix.log"

# --- helpers ---------------------------------------------------------------
function RB { param([IntPtr]$h,[Int64]$a,[int]$n)
    $b = New-Object byte[] $n; $r = [IntPtr]::Zero
    if (-not [HmFix]::ReadProcessMemory($h,[IntPtr]$a,$b,$n,[ref]$r) -or $r.ToInt64() -ne $n) {
        throw ("read failed at 0x{0:X}" -f $a) }
    return ,$b }
function Same { param([byte[]]$A,[byte[]]$B)
    if ($null -eq $A -or $null -eq $B -or $A.Length -ne $B.Length) { return $false }
    for ($i=0;$i -lt $A.Length;$i++){ if ($A[$i] -ne $B[$i]) { return $false } }; return $true }
function WB { param([IntPtr]$h,[Int64]$a,[byte[]]$b)
    $w = [IntPtr]::Zero
    if (-not [HmFix]::WriteProcessMemory($h,[IntPtr]$a,$b,$b.Length,[ref]$w) -or $w.ToInt64() -ne $b.Length) {
        throw ("write failed at 0x{0:X}" -f $a) }
    if (-not [HmFix]::FlushInstructionCache($h,[IntPtr]$a,[UIntPtr]::op_Explicit($b.Length))) {
        throw ("instruction-cache flush failed at 0x{0:X}" -f $a) } }
function U8  { param($h,$a) (RB $h $a 1)[0] }
function U16 { param($h,$a) [BitConverter]::ToUInt16((RB $h $a 2),0) }
function U32 { param($h,$a) [BitConverter]::ToUInt32((RB $h $a 4),0) }
function I64 { param($h,$a) [BitConverter]::ToInt64((RB $h $a 8),0) }
function W2B { param([UInt32[]]$W)
    $o = New-Object byte[] ($W.Length*4)
    for ($i=0;$i -lt $W.Length;$i++){ [Array]::Copy([BitConverter]::GetBytes($W[$i]),0,$o,$i*4,4) }
    return ,$o }
function Hex-Bytes { param([string]$Text)
    $tokens=@($Text -split '\s+' | Where-Object { $_ })
    $out=New-Object byte[] $tokens.Count
    for ($i=0;$i -lt $tokens.Count;$i++) { $out[$i]=[Convert]::ToByte($tokens[$i],16) }
    return ,$out }
function Join-Bytes { param([object[]]$Parts)
    $length=0
    foreach ($part in $Parts) { $length += ([byte[]]$part).Length }
    $out=New-Object byte[] $length; $offset=0
    foreach ($part in $Parts) {
        $bytes=[byte[]]$part
        [Array]::Copy($bytes,0,$out,$offset,$bytes.Length)
        $offset += $bytes.Length }
    return ,$out }
function U64B { param([UInt64]$Value) return ,[BitConverter]::GetBytes($Value) }

# v1.4's owner-aware wrapper blobs are built declaratively below. Labels
# and RIP-relative data references are resolved after emission, avoiding hand-
# maintained branch displacements while retaining deterministic byte images.
function New-ByteBuilder { param([Int64]$Origin)
    [pscustomobject]@{ Origin=$Origin; Bytes=New-Object 'System.Collections.Generic.List[byte]'; Labels=@{}; Branches=New-Object System.Collections.ArrayList } }
function Emit-Bytes { param($Builder,[byte[]]$Bytes) foreach($x in $Bytes){$Builder.Bytes.Add($x)} }
function Emit-Hex { param($Builder,[string]$Text) Emit-Bytes $Builder (Hex-Bytes $Text) }
function Mark-Label { param($Builder,[string]$Name) if($Builder.Labels.ContainsKey($Name)){throw "duplicate wrapper label"};$Builder.Labels[$Name]=$Builder.Bytes.Count }
function Emit-J8 { param($Builder,[byte]$Opcode,[string]$Target)
    $Builder.Bytes.Add($Opcode);$p=$Builder.Bytes.Count;$Builder.Bytes.Add(0)
    [void]$Builder.Branches.Add([pscustomobject]@{Position=$p;Size=1;Target=$Target}) }
function Emit-J32 { param($Builder,[byte[]]$Opcode,[string]$Target)
    Emit-Bytes $Builder $Opcode;$p=$Builder.Bytes.Count
    1..4|ForEach-Object{$Builder.Bytes.Add(0)}
    [void]$Builder.Branches.Add([pscustomobject]@{Position=$p;Size=4;Target=$Target}) }
function Emit-Rip32 { param($Builder,[byte[]]$Prefix,[Int64]$Target) Emit-Bytes $Builder $Prefix;$next=$Builder.Origin+$Builder.Bytes.Count+4L;$d=$Target-$next;if($d -lt [Int32]::MinValue -or $d -gt [Int32]::MaxValue){throw "wrapper RIP target out of range"};Emit-Bytes $Builder ([BitConverter]::GetBytes([Int32]$d)) }
function Finish-ByteBuilder { param($Builder)
    foreach($j in $Builder.Branches){
        if(-not $Builder.Labels.ContainsKey($j.Target)){throw "missing wrapper label"}
        $d=[Int64]$Builder.Labels[$j.Target]-([Int64]$j.Position+[Int64]$j.Size)
        if($j.Size -eq 1){
            if($d -lt -128 -or $d -gt 127){throw "short wrapper branch out of range"}
            $Builder.Bytes[$j.Position]=[byte]([sbyte]$d)
        } else {
            if($d -lt [Int32]::MinValue -or $d -gt [Int32]::MaxValue){throw "near wrapper branch out of range"}
            $raw=[BitConverter]::GetBytes([Int32]$d)
            for($i=0;$i -lt 4;$i++){$Builder.Bytes[$j.Position+$i]=$raw[$i]}
        }
    }
    return ,$Builder.Bytes.ToArray() }

function Build-OuterUnit { param([Int64]$Unit,[Int64]$Target,[bool]$ChangeCount)
    $data=$Unit+0x1000L
    $b=New-ByteBuilder $Unit

    # Proven TestKit-6 ABI frame plus an owner scope. ownerCtx is the atomic
    # gate; ownerTid is published only after acquisition. Local byte +5C uses
    # bit 0 for ownership and bit 1 for a count change.
    Emit-Hex $b 'F3 0F 1E FA'
    Emit-Rip32 $b (Hex-Bytes 'F0 48 FF 05') ($data+0x30L)
    Emit-Hex $b @'
48 8B 8C 24 C8 00 00 00
48 89 44 24 28
48 83 EC 78
4C 8B 9C 24 A0 00 00 00 4C 89 5C 24 20
4C 8B 9C 24 A8 00 00 00 4C 89 5C 24 28
4C 8B 9C 24 B0 00 00 00 4C 89 5C 24 30
4C 8B 9C 24 B8 00 00 00 4C 89 5C 24 38
4C 8B 9C 24 C0 00 00 00 4C 89 5C 24 40
4C 8B 9C 24 C8 00 00 00 4C 89 5C 24 48
48 89 4C 24 50
C7 44 24 5C 00 00 00 00
'@
    Emit-Rip32 $b (Hex-Bytes 'F0 48 FF 05') ($data+0x00L)
    Emit-Hex $b '8B 41 14 89 44 24 58'
    Emit-Rip32 $b (Hex-Bytes '3B 05') ($data+0x24L)
    Emit-J8 $b 0x76 'max_top_ok'
    Emit-Rip32 $b (Hex-Bytes '89 05') ($data+0x24L)
    Mark-Label $b 'max_top_ok'
    Emit-Hex $b '83 F8 04'
    Emit-J8 $b 0x77 'bad_count'
    Emit-Hex $b '44 8B 14 81'
    Emit-Rip32 $b (Hex-Bytes '44 89 15') ($data+0x20L)
    Emit-Hex $b '41 83 FA 04'
    Emit-J8 $b 0x74 'count_four'
    Emit-Hex $b '41 83 FA 01'
    Emit-J32 $b (Hex-Bytes '0F 84') 'call_target'
    Emit-Hex $b '41 83 FA 02'
    Emit-J8 $b 0x74 'count_two'
    Mark-Label $b 'bad_count'
    Emit-Rip32 $b (Hex-Bytes 'F0 48 FF 05') ($data+0x18L)
    Emit-J32 $b (Hex-Bytes 'E9') 'call_target'

    # Count two is ordinary only when no owner exists. A nonzero owner means
    # re-entry or another thread observed the temporary shared state.
    Mark-Label $b 'count_two'
    Emit-Rip32 $b (Hex-Bytes '4C 8B 1D') ($data+0x40L)
    Emit-Hex $b '4D 85 DB'
    Emit-J8 $b 0x74 'call_target'
    Emit-J32 $b (Hex-Bytes 'E9') 'owner_conflict'

    Mark-Label $b 'count_four'
    Emit-Rip32 $b (Hex-Bytes '4C 8B 1D') ($data+0x30L)
    Emit-Hex $b '49 83 FB 01'
    Emit-J8 $b 0x75 'owner_conflict'
    Emit-Hex $b '33 C0'
    Emit-Rip32 $b (Hex-Bytes 'F0 48 0F B1 0D') ($data+0x40L)
    Emit-J8 $b 0x75 'owner_conflict'
    Emit-Hex $b '65 4C 8B 14 25 48 00 00 00'
    Emit-Rip32 $b (Hex-Bytes '4C 89 15') ($data+0x38L)
    Emit-Hex $b '80 4C 24 5C 01'
    Emit-Rip32 $b (Hex-Bytes 'F0 48 FF 05') ($data+0x48L)
    if($ChangeCount){
        Emit-Hex $b '8B 44 24 58 C7 04 81 02 00 00 00 80 4C 24 5C 02'
        Emit-Rip32 $b (Hex-Bytes 'F0 48 FF 05') ($data+0x08L)
    }
    Emit-J32 $b (Hex-Bytes 'E9') 'call_target'

    Mark-Label $b 'owner_conflict'
    Emit-Rip32 $b (Hex-Bytes 'F0 48 FF 05') ($data+0x28L)

    Mark-Label $b 'call_target'
    Emit-Hex $b '48 B8'
    Emit-Bytes $b (U64B ([UInt64]$Target))
    Emit-Hex $b 'FF D0 48 89 44 24 60'

    Emit-Hex $b 'F6 44 24 5C 02'
    Emit-J8 $b 0x74 'after_restore'
    Emit-Hex $b '48 8B 4C 24 50 8B 44 24 58 83 F8 04'
    Emit-J8 $b 0x77 'restore_bad'
    Emit-Hex $b '83 3C 81 02'
    Emit-J8 $b 0x75 'restore_bad'
    Emit-Hex $b 'C7 04 81 04 00 00 00'
    Emit-Rip32 $b (Hex-Bytes 'F0 48 FF 05') ($data+0x10L)
    Emit-Hex $b '39 41 14'
    Emit-J8 $b 0x75 'restore_bad'
    Emit-J8 $b 0xEB 'after_restore'
    Mark-Label $b 'restore_bad'
    Emit-Rip32 $b (Hex-Bytes 'F0 48 FF 05') ($data+0x28L)

    Mark-Label $b 'after_restore'
    Emit-Hex $b 'F6 44 24 5C 01'
    Emit-J8 $b 0x74 'finish'
    Emit-Hex $b '48 8B 4C 24 50'
    Emit-Rip32 $b (Hex-Bytes '4C 8B 1D') ($data+0x40L)
    Emit-Hex $b '4C 3B D9'
    Emit-J8 $b 0x75 'release_bad'
    Emit-Hex $b '65 4C 8B 14 25 48 00 00 00'
    Emit-Rip32 $b (Hex-Bytes '4C 3B 15') ($data+0x38L)
    Emit-J8 $b 0x75 'release_bad'
    Emit-Rip32 $b (Hex-Bytes '4C 8B 1D') ($data+0x30L)
    Emit-Hex $b '49 83 FB 01'
    Emit-J8 $b 0x75 'release_bad'
    # Emit-Rip32 targets the end of its displacement field, so avoid a
    # RIP-relative store with a trailing imm32 and clear through R10 instead.
    Emit-Hex $b '45 33 D2'
    Emit-Rip32 $b (Hex-Bytes '4C 89 15') ($data+0x38L)
    Emit-Hex $b '48 8B C1'
    Emit-Rip32 $b (Hex-Bytes 'F0 4C 0F B1 15') ($data+0x40L)
    Emit-J8 $b 0x75 'release_bad'
    Emit-Rip32 $b (Hex-Bytes 'F0 48 FF 05') ($data+0x50L)
    Emit-J8 $b 0xEB 'finish'
    Mark-Label $b 'release_bad'
    Emit-Rip32 $b (Hex-Bytes 'F0 48 FF 05') ($data+0x28L)

    Mark-Label $b 'finish'
    Emit-Rip32 $b (Hex-Bytes 'F0 48 FF 0D') ($data+0x30L)
    Emit-Hex $b '48 8B 44 24 60 48 83 C4 78 C3'
    Finish-ByteBuilder $b
}

function Emit-OwnerChecks { param($Builder,[Int64]$Data,[string]$NoOwnerLabel,[string]$MismatchLabel,[string]$ContextRegister)
    Emit-Rip32 $Builder (Hex-Bytes '4C 8B 1D') ($Data+0x40L)
    Emit-Hex $Builder '4D 85 DB'
    Emit-J8 $Builder 0x74 $NoOwnerLabel
    if($ContextRegister -eq 'rcx'){Emit-Hex $Builder '4C 3B D9'}
    elseif($ContextRegister -eq 'rbx'){Emit-Hex $Builder '4C 3B DB'}
    else{throw 'unsupported owner context register'}
    Emit-J8 $Builder 0x75 $MismatchLabel
    Emit-Hex $Builder '65 4C 8B 14 25 48 00 00 00'
    Emit-Rip32 $Builder (Hex-Bytes '4C 3B 15') ($Data+0x38L)
    Emit-J8 $Builder 0x75 $MismatchLabel
}

function Build-MeshUnit { param([Int64]$Unit)
    # Mesh lives at cave+200; all wrappers deliberately share cave+1000 data.
    $data=$Unit+0xE00L
    $b=New-ByteBuilder $Unit
    Emit-Hex $b @'
F3 0F 1E FA
8B 41 14 41 8B E9 45 8B F0 8B F2 48 8B D9 8B 3C 81
'@
    # This helper is global: absent or mismatched ownership remains stock.
    Emit-OwnerChecks $b $data 'done' 'done' 'rbx'
    Emit-Rip32 $b (Hex-Bytes '4C 8B 15') ($data+0x30L)
    Emit-Hex $b '49 83 FA 01'
    Emit-J8 $b 0x75 'bad'
    Emit-Hex $b '83 FF 02'
    Emit-J8 $b 0x75 'bad'
    Emit-Hex $b 'BF 04 00 00 00'
    Emit-Rip32 $b (Hex-Bytes 'F0 48 FF 05') ($data+0x58L)
    Emit-J8 $b 0xEB 'done'
    Mark-Label $b 'bad'
    Emit-Rip32 $b (Hex-Bytes 'F0 48 FF 05') ($data+0x28L)
    Mark-Label $b 'done'
    Emit-Hex $b 'C3'
    Finish-ByteBuilder $b
}

function Build-CopyUnit { param($Call,[Int64]$Unit,[Int64]$Target,[int]$FromCount,[int]$ToCount)
    if(($FromCount -ne 4 -or $ToCount -ne 2) -and ($FromCount -ne 2 -or $ToCount -ne 4)){
        throw 'unsupported CopyRefractionDepth count scope'}
    [Int64]$counterOffset=[Int64]$Call.CounterOffset
    if($counterOffset -ne 0x60L -and $counterOffset -ne 0x80L){throw 'invalid copy telemetry block'}
    $data=$Unit+(0x1000L-[Int64]$Call.UnitOffset)
    $b=New-ByteBuilder $Unit
    Emit-Hex $b 'F3 0F 1E FA'
    Emit-Rip32 $b (Hex-Bytes 'F0 48 FF 05') ($data+$counterOffset+0x18L)

    # Replay the common 21-byte setup/call block. The old caller's sixth
    # argument moves from new [rsp+88] to the wrapper call's [rsp+28].
    Emit-Hex $b @'
4D 8B C4
8B 41 04
44 8B 09
48 8B CE
48 83 EC 58
4C 8B 9C 24 88 00 00 00
4C 89 5C 24 28
89 44 24 20
48 89 4C 24 38
C7 44 24 34 00 00 00 00
'@
    Emit-Rip32 $b (Hex-Bytes 'F0 48 FF 05') ($data+$counterOffset)
    Emit-Hex $b '8B 41 14 89 44 24 30'
    Emit-Rip32 $b (Hex-Bytes '3B 05') ($data+0x24L)
    Emit-J8 $b 0x76 'max_top_ok'
    Emit-Rip32 $b (Hex-Bytes '89 05') ($data+0x24L)
    Mark-Label $b 'max_top_ok'
    Emit-Hex $b '83 F8 04'
    Emit-J8 $b 0x77 'bad_count'
    Emit-Hex $b '44 8B 1C 81'
    Emit-Rip32 $b (Hex-Bytes '44 89 1D') ($data+0x20L)

    # Preserve R11D (observed count). owner zero with current 1/2 is a stock
    # desktop/unselected path; owner zero with current 4 is unexpected here.
    Emit-Rip32 $b (Hex-Bytes '48 8B 05') ($data+0x40L)
    Emit-Hex $b '48 85 C0'
    Emit-J8 $b 0x74 'no_owner'
    Emit-Hex $b '48 3B C1'
    Emit-J8 $b 0x75 'owner_bad'
    Emit-Hex $b '65 4C 8B 14 25 48 00 00 00'
    Emit-Rip32 $b (Hex-Bytes '4C 3B 15') ($data+0x38L)
    Emit-J8 $b 0x75 'owner_bad'
    Emit-Rip32 $b (Hex-Bytes '48 8B 05') ($data+0x30L)
    Emit-Hex $b '48 83 F8 01'
    Emit-J8 $b 0x75 'owner_bad'
    Emit-J8 $b 0xEB 'owner_ok'
    Mark-Label $b 'no_owner'
    Emit-Hex $b '41 83 FB 01'
    Emit-J8 $b 0x74 'call_target'
    Emit-Hex $b '41 83 FB 02'
    Emit-J8 $b 0x74 'call_target'
    Emit-J8 $b 0xEB 'owner_bad'
    Mark-Label $b 'owner_ok'
    Emit-Hex $b '8B 44 24 30'

    Emit-Hex $b ('41 83 FB {0:X2}' -f $FromCount)
    Emit-J8 $b 0x74 'change_count'
    Emit-J8 $b 0xEB 'bad_count'
    Mark-Label $b 'change_count'
    Emit-Hex $b ('C7 04 81 {0:X2} 00 00 00 C6 44 24 34 01' -f $ToCount)
    Emit-Rip32 $b (Hex-Bytes 'F0 48 FF 05') ($data+$counterOffset+0x08L)
    Emit-J8 $b 0xEB 'call_target'
    Mark-Label $b 'bad_count'
    Emit-Rip32 $b (Hex-Bytes 'F0 48 FF 05') ($data+0x18L)
    Emit-J8 $b 0xEB 'call_target'
    Mark-Label $b 'owner_bad'
    Emit-Rip32 $b (Hex-Bytes 'F0 48 FF 05') ($data+0x28L)

    Mark-Label $b 'call_target'
    Emit-Hex $b '48 B8'
    Emit-Bytes $b (U64B ([UInt64]$Target))
    Emit-Hex $b 'FF D0 48 89 44 24 40'
    Emit-Hex $b '80 7C 24 34 01'
    Emit-J8 $b 0x75 'finish'
    Emit-Hex $b '48 8B 4C 24 38 8B 44 24 30 83 F8 04'
    Emit-J8 $b 0x77 'restore_bad'
    Emit-Hex $b ('83 3C 81 {0:X2}' -f $ToCount)
    Emit-J8 $b 0x75 'restore_bad'
    Emit-Hex $b ('C7 04 81 {0:X2} 00 00 00' -f $FromCount)
    Emit-Rip32 $b (Hex-Bytes 'F0 48 FF 05') ($data+$counterOffset+0x10L)
    Emit-Hex $b '39 41 14'
    Emit-J8 $b 0x75 'restore_bad'
    Emit-J8 $b 0xEB 'finish'
    Mark-Label $b 'restore_bad'
    Emit-Rip32 $b (Hex-Bytes 'F0 48 FF 05') ($data+0x28L)

    Mark-Label $b 'finish'
    Emit-Rip32 $b (Hex-Bytes 'F0 48 FF 0D') ($data+$counterOffset+0x18L)
    Emit-Hex $b '48 8B 44 24 40 48 83 C4 58 C3'
    Finish-ByteBuilder $b
}

function Build-CallPatch { param($Call,[Int64]$Cave)
    $length=$Call.Stock.Length
    if ($length -lt 16 -or $length -gt 127) { throw "invalid hook patch-block length" }
    $out=New-Object byte[] $length
    for ($i=0;$i -lt $length;$i++) { $out[$i]=0x90 }
    [byte[]]$head=0xFF,0x15,0x02,0x00,0x00,0x00,0xEB,[byte]($length-8)
    [Array]::Copy($head,0,$out,0,$head.Length)
    [Array]::Copy((U64B ([UInt64]($Cave+[Int64]$Call.UnitOffset))),0,$out,8,8)
    return ,$out
}

function Allocate-HookMemory {
    $allocated=[HmFix]::VirtualAllocEx($script:handle,[IntPtr]::Zero,[UIntPtr]::op_Explicit(0x2000),0x3000,0x04)
    if ($allocated -eq [IntPtr]::Zero) { return 0L }
    return $allocated.ToInt64()
}
function Suspend-GameThreads {
    if ($script:unsafeCodeState) {
        throw "the game is deliberately suspended after an unverified code rollback" }
    if ($script:suspendedHandles.Count -gt 0 -and -not (Resume-GameThreads @())) {
        throw "a previously suspended game thread could not be resumed" }
    $held=@(); $seen=@{}
    try {
        for ($round=0;$round -lt 3;$round++) {
            $added=0
            $script:process.Refresh()
            foreach ($thread in @($script:process.Threads)) {
                $tid=[UInt32]$thread.Id
                if ($seen.ContainsKey($tid)) { continue }
                $handle=[HmFix]::OpenThread(0x0010000A,$false,$tid) # SYNCHRONIZE | SUSPEND_RESUME | GET_CONTEXT
                if ($handle -eq [IntPtr]::Zero) {
                    $openError=[Runtime.InteropServices.Marshal]::GetLastWin32Error()
                    if ($openError -eq 87) { continue } # thread ended between snapshot and OpenThread
                    throw ("could not open game thread {0} (Windows error {1})" -f $tid,$openError) }
                $previous=[HmFix]::SuspendThread($handle)
                if ($previous -eq [UInt32]::MaxValue) {
                    $ended=([HmFix]::WaitForSingleObject($handle,0) -eq 0)
                    [HmFix]::CloseHandle($handle) | Out-Null
                    if ($ended) { continue }
                    throw ("could not suspend game thread {0}" -f $tid) }
                $held += [pscustomobject]@{ Id=$tid; Handle=$handle }
                $seen[$tid]=$true; $added++ }
            if ($added -eq 0) { return $held }
            Start-Sleep -Milliseconds 5 }
        $script:process.Refresh()
        foreach ($thread in @($script:process.Threads)) {
            if (-not $seen.ContainsKey([UInt32]$thread.Id)) { throw "game thread list did not become stable" } }
        return $held
    } catch {
        Resume-GameThreads $held | Out-Null
        throw
    }
}
function Resume-GameThreads { param([object[]]$Held)
    if ($script:unsafeCodeState) { return $false }
    $ok=$true
    $pending=@($script:suspendedHandles)+@($Held)
    $script:suspendedHandles=@()
    $seenHandles=@{}
    foreach ($item in @($pending)) {
        if ($null -eq $item -or $null -eq $item.Handle -or $item.Handle -isnot [IntPtr]) { $ok=$false; continue }
        $key=$item.Handle.ToInt64().ToString("X")
        if ($seenHandles.ContainsKey($key)) { continue }
        $seenHandles[$key]=$true
        $released=$false
        for ($attempt=0;$attempt -lt 3 -and -not $released;$attempt++) {
            try {
                if ([HmFix]::ResumeThread($item.Handle) -ne [UInt32]::MaxValue) { $released=$true; break }
                if ([HmFix]::WaitForSingleObject($item.Handle,0) -eq 0) { $released=$true; break }
            } catch {}
            if (-not $released) { Start-Sleep -Milliseconds 2 } }
        if ($released) {
            try { [HmFix]::CloseHandle($item.Handle) | Out-Null } catch { $ok=$false } }
        else {
            $script:suspendedHandles += $item
            $ok=$false } }
    return $ok
}
function Threads-AreOutsidePatchRanges { param([object[]]$Held,[object[]]$Ranges)
    foreach ($item in @($Held)) {
        if ($null -eq $item -or $null -eq $item.Handle -or $item.Handle -isnot [IntPtr]) {
            throw "the suspended-thread list has an invalid shape" }
        [UInt64]$rip=0
        [Int32]$contextError=0
        if (-not [HmFix]::TryGetThreadRip($item.Handle,[ref]$rip,[ref]$contextError)) {
            throw ("could not verify the instruction pointer of game thread {0} (Windows error {1})" -f $item.Id,$contextError) }
        foreach ($range in @($Ranges)) {
            if ($rip -ge [UInt64]$range.Start -and $rip -lt [UInt64]$range.End) { return $false } }
    }
    return $true
}
function Log { param($t)
    try { Add-Content -Path $LOG_PATH -Value ("{0}  [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"),$MODE_INFO.Short,$t) -Encoding UTF8 } catch {} }

# --- PE parsing / pattern search (pattern path only) -----------------------
function Read-PE { param([string]$path)
    $b = [IO.File]::ReadAllBytes($path)
    $pe = [BitConverter]::ToInt32($b,0x3C)
    $stamp   = [BitConverter]::ToInt32($b,$pe+8)
    $nsec    = [BitConverter]::ToUInt16($b,$pe+6)
    $optSize = [BitConverter]::ToUInt16($b,$pe+20)
    $tRVA=0; $tOff=0; $tSize=0
    for ($i=0;$i -lt $nsec;$i++) {
        $o = $pe+24+$optSize+$i*40
        $name = [Text.Encoding]::ASCII.GetString($b,$o,8).TrimEnd([char]0)
        if ($name -eq ".text") {
            $tSize=[BitConverter]::ToInt32($b,$o+16)
            $tRVA =[BitConverter]::ToInt32($b,$o+12)
            $tOff =[BitConverter]::ToInt32($b,$o+20); break } }
    if ($tRVA -eq 0) { throw "no .text section" }
    $text = New-Object byte[] $tSize
    [Array]::Copy($b,$tOff,$text,0,$tSize)
    return [pscustomobject]@{ Stamp=$stamp; TextRVA=$tRVA; Text=$text } }

function Find-Sig { param([byte[]]$hay,[string]$pat)
    $tok=$pat.Split(" "); $n=$tok.Count
    $val=New-Object int[] $n
    for ($i=0;$i -lt $n;$i++) {
        if ($tok[$i] -eq "??") { $val[$i]=-1 } else { $val[$i]=[Convert]::ToInt32($tok[$i],16) } }
    $a=0; while ($a -lt $n -and $val[$a] -lt 0) { $a++ }
    $first=[byte]$val[$a]
    $hits=@(); $limit=$hay.Length-$n
    for ($p=0; $p -le $limit; $p++) {
        if ($hay[$p+$a] -ne $first) { continue }
        $ok=$true
        for ($i=0;$i -lt $n;$i++) {
            if ($val[$i] -ge 0 -and $hay[$p+$i] -ne $val[$i]) { $ok=$false; break } }
        if ($ok) { $hits+=$p; if ($hits.Count -gt 1) { return $hits } } }
    return $hits }

# --- state -----------------------------------------------------------------
$script:handle=[IntPtr]::Zero; $script:gamePid=0; $script:process=$null; $script:base=0L
$script:mode=""            # verified | scanned
$script:sites=@()
$script:guardSites=@()       # verified-only preconditions; never written/restored
$script:writtenSites=@()    # only sites this instance owns and may restore
$script:hookDescriptors=@() # verified or uniquely pattern-located v1.4 call blocks
$script:hookSites=@()       # dynamic indirect-CALL blocks owned by this instance
$script:hookCave=0L; $script:hookPrepared=$false
$script:lastHookLog=[DateTime]::MinValue
$script:lastHookIntegrityCheck=[DateTime]::MinValue
$script:hookProgress=@{}
$script:lastPatchBusyLog=[DateTime]::MinValue
$script:suspendedHandles=@()
$script:unsafeCodeState=$false
$script:devSlot=0L         # pattern path: RVA of the device pointer
$script:wnoOff=$OFF_ACTIVE
$script:patched=$false
$script:dev=0L; $script:lastTrans=-1L; $script:needRel=$false
$script:pendingValueWrite=$false
$script:stableReady=0; $script:stableSince=0L
$script:scaleStock=$null; $script:maskStock=$null
$script:scaleTouched=$false; $script:maskTouched=$false
$script:deviceRestoreUncertain=$false
$script:runtimeLoaded=$false; $script:lastRuntimeCheck=0L
$script:lastWriteLog=[DateTime]::MinValue; $script:lastUi=""
$script:fatal=""; $script:stopped=$false
$script:renderSyncGate=New-Object object
$script:rendererGuard=$null
$script:guardWritePending=$false
$script:guardDirectRepair=$false
$script:lastGuardRepairs=0L
$script:guardReloadLatch=$false; $script:guardReloadSawNon3=$false
$script:guardError=""; $script:lastGuardWriteLog=[DateTime]::MinValue

function Stop-RendererGuard {
    $guard=$script:rendererGuard
    if ($null -eq $guard) { return $true }
    try {
        try { $guard.Disarm() } catch {}
        if (-not $guard.Stop(2000)) {
            $script:fatal="The continuous renderer guard did not stop in time. Close HITMAN before continuing."
            return $false }
        Log ("renderer guard stopped; reads={0}, mismatches={1}, repairs={2}, repairFailures={3}, readFailures={4}, highResTimer={5}, slowIntervals={6}, maxInterval={7} us" -f $guard.Reads,$guard.Mismatches,$guard.Repairs,$guard.RepairFailures,$guard.ReadFailures,$guard.HighResolutionTimer,$guard.SlowIntervals,$guard.MaxIntervalMicroseconds)
        $script:rendererGuard=$null
        $guard.Dispose()
        return $true
    } catch {
        $script:fatal=("The continuous renderer guard could not be stopped safely: {0}. Close HITMAN." -f $_.Exception.Message)
        return $false
    }
}

# The guard's own bookkeeping must not depend on BeginInvoke arriving. While a
# callback is running, signalPending stays set and a second repair queues no
# second callback - and if the values are correct afterwards there may never be
# another mismatch to trigger one. So this drains the counters, and the 15 ms
# loop calls it every tick regardless of whether a callback happened.
function Update-RendererGuardState {
    $g=$script:rendererGuard
    if ($null -eq $g) { return }
    try {
        if ($g.ConsumePartialWriteFault()) {
            $script:guardError="A renderer value was left in an unknown state after a partial write. Close HITMAN."
            return }
        $r=$g.Repairs
        $observed=($r -ne $script:lastGuardRepairs)
        if ($observed) {
            $script:lastGuardRepairs=$r
            $script:guardDirectRepair=$true }
        if ($g.ConsumeTransition3Repair()) {
            $script:guardReloadLatch=$true
            $script:guardReloadSawNon3=$false }
        if ($observed) {
            $now=Get-Date
            if (($now-$script:lastGuardWriteLog).TotalSeconds -ge 1) {
                Log ("1 ms renderer guard repaired directly; repairs={0}, repairFailures={1}" -f $r,$g.RepairFailures)
                $script:lastGuardWriteLog=$now } }
    } catch {}
}

function Invoke-RendererGuardSignal { param([RendererValueGuard]$Source)
    try {
        if ($null -eq $Source -or -not [Object]::ReferenceEquals($Source,$script:rendererGuard)) { return }
        if ($script:handle -eq [IntPtr]::Zero -or $script:dev -eq 0 -or $Source.Device -ne $script:dev) { return }
        if (-not (Game-IsAlive)) { return }
        $current=Get-Dev
        if ($current -ne $script:dev) { return }

        # This is intentionally the complete v1.3 transaction, not a guard-
        # specific write shortcut. It validates FOV/scale/mask, captures
        # ownership, verifies both writes and rolls back failures.
        # Direct-repair bookkeeping lives in one place and does not depend on this
        # callback running at all.
        Update-RendererGuardState
        if ($script:guardError) { return }

        # What is left here is the fallback: whatever the guard could not fix on
        # its own thread goes through the full validated transaction.
        $sync=Sync-RenderValues $script:dev
        if ($sync.Wrote) {
            try { $transition=U32 $script:handle ($script:dev+$OFF_TRANS) }
            catch { $transition=-1 }
            # Only a write PowerShell just made may be classified with the
            # transition PowerShell just read.
            $script:guardWritePending=$true
            if ($transition -eq 3) {
                $script:guardReloadLatch=$true
                $script:guardReloadSawNon3=$false }
            $now=Get-Date
            if (($now-$script:lastWriteLog).TotalSeconds -ge 1) {
                Log ("renderer guard fallback wrote values, transition={0}" -f $transition)
                $script:lastWriteLog=$now } }
        if ($sync.Error) {
            $script:guardError=$sync.Error
            return
        }
    } catch {
        if (Game-IsAlive) { $script:guardError=$_.Exception.Message }
    } finally {
        if ($null -ne $Source) { try { $Source.CompleteSignal() } catch {} }
    }
}

function Ensure-RendererGuard { param([Int64]$Device)
    if ($Device -eq 0 -or $script:handle -eq [IntPtr]::Zero) { return $false }
    if ($null -ne $script:rendererGuard) {
        if ($script:rendererGuard.Device -eq $Device -and $script:rendererGuard.IsRunning) { return $true }
        if (-not (Stop-RendererGuard)) { return $false }
    }
    try {
        [Action[RendererValueGuard]]$callback={ param([RendererValueGuard]$source) Invoke-RendererGuardSignal $source }
        # The address that HOLDS the device pointer, and the vtable value the
        # device must still have. The guard re-checks both before it writes, so a
        # device released between two 15 ms ticks cannot be written to.
        if ($script:mode -eq "verified") {
            $devicePointer=$script:base+$MANAGER_RVA+$MANAGER_DEVICE_OFFSET
        } else {
            $devicePointer=$script:base+$script:devSlot }
        # Fail closed: without a vtable to compare against, the guard cannot
        # notice a released device, so it does not run at all rather than run
        # with one safety check quietly switched off.
        $expectedVtable=0L
        try { $expectedVtable=I64 $script:handle $Device } catch { $expectedVtable=0L }
        if ($expectedVtable -eq 0) {
            $script:rendererGuard=$null
            $script:guardError="The VR device vtable could not be read, so the renderer guard was not started."
            return $false }

        $guard=[RendererValueGuard]::new(
            $script:handle,$Device,$devicePointer,$expectedVtable,
            $OFF_FOV,$OFF_SCALE,$OFF_MASK,$OFF_TRANS,(W2B $SCALE_FIX),$MASK_FIX,
            $form,$callback,$script:renderSyncGate)
        $script:rendererGuard=$guard
        $script:lastGuardRepairs=0L
        $guard.Start()
        Log ("continuous 1 ms renderer guard started for device 0x{0:X}, highResTimer={1}" -f $Device,$guard.HighResolutionTimer)
        return $true
    } catch {
        $script:rendererGuard=$null
        $script:guardError=("Continuous renderer guard could not start: {0}" -f $_.Exception.Message)
        return $false
    }
}

function Reset-DeviceState { param([bool]$OwnershipBecameUncertain=$false)
    if (-not (Stop-RendererGuard)) { throw $script:fatal }
    if ($OwnershipBecameUncertain -and ($script:scaleTouched -or $script:maskTouched)) {
        $script:deviceRestoreUncertain=$true }
    $script:dev=0L; $script:lastTrans=-1L; $script:needRel=$false
    $script:pendingValueWrite=$false
    $script:stableReady=0; $script:stableSince=0L
    $script:scaleStock=$null; $script:maskStock=$null
    $script:scaleTouched=$false; $script:maskTouched=$false
    $script:runtimeLoaded=$false; $script:lastRuntimeCheck=0L
    $script:lastWriteLog=[DateTime]::MinValue
    $script:guardWritePending=$false; $script:guardDirectRepair=$false
    $script:guardReloadLatch=$false; $script:guardReloadSawNon3=$false
    $script:guardError=""; $script:lastGuardWriteLog=[DateTime]::MinValue }

function Advance-Lifecycle {
    param([Int64]$LastTransition,[bool]$NeedReload,[UInt32]$Transition,[bool]$ValuesWritten)
    $changed=($LastTransition -ne [Int64]$Transition)
    if ($Transition -ne 3) { $NeedReload=$false }
    elseif ($ValuesWritten) { $NeedReload=$true }
    return [pscustomobject]@{
        LastTransition=[Int64]$Transition
        NeedReload=$NeedReload
        TransitionChanged=$changed
        ResetStable=($changed -or $ValuesWritten) }
}

function Apply-GuardReloadLatch { param($Lifecycle,[UInt32]$Transition)
    if (-not $script:guardReloadLatch) { return $Lifecycle }
    if ($Transition -ne 3) {
        $script:guardReloadSawNon3=$true
        $Lifecycle.NeedReload=$true
    } elseif ($script:guardReloadSawNon3) {
        $script:guardReloadLatch=$false
        $script:guardReloadSawNon3=$false
        $Lifecycle.NeedReload=$false
    } else {
        $Lifecycle.NeedReload=$true
    }
    return $Lifecycle
}

function Detach {
    Stop-RendererGuard | Out-Null
    foreach ($item in @($script:suspendedHandles)) {
        try { [HmFix]::CloseHandle($item.Handle) | Out-Null } catch {} }
    $script:suspendedHandles=@()
    if ($script:handle -ne [IntPtr]::Zero) { [HmFix]::CloseHandle($script:handle) | Out-Null }
    $script:handle=[IntPtr]::Zero; $script:gamePid=0; $script:process=$null; $script:base=0L
    $script:mode=""; $script:sites=@(); $script:guardSites=@(); $script:writtenSites=@(); $script:hookDescriptors=@(); $script:hookSites=@()
    $script:hookCave=0L; $script:hookPrepared=$false; $script:lastHookLog=[DateTime]::MinValue
    $script:lastHookIntegrityCheck=[DateTime]::MinValue; $script:hookProgress=@{}
    $script:lastPatchBusyLog=[DateTime]::MinValue
    $script:unsafeCodeState=$false
    $script:devSlot=0L; $script:patched=$false
    $script:dev=0L; $script:lastTrans=-1L; $script:needRel=$false
    $script:pendingValueWrite=$false
    $script:stableReady=0; $script:stableSince=0L
    $script:scaleStock=$null; $script:maskStock=$null
    $script:scaleTouched=$false; $script:maskTouched=$false
    $script:deviceRestoreUncertain=$false
    $script:runtimeLoaded=$false; $script:lastRuntimeCheck=0L
    $script:lastWriteLog=[DateTime]::MinValue; $script:lastUi=""
    $script:guardWritePending=$false; $script:guardDirectRepair=$false
    $script:guardReloadLatch=$false; $script:guardReloadSawNon3=$false
    $script:guardError=""; $script:lastGuardWriteLog=[DateTime]::MinValue }

function Game-IsAlive {
    if ($script:handle -eq [IntPtr]::Zero) { return $false }
    try {
        $wait=[HmFix]::WaitForSingleObject($script:handle,0)
        if ($wait -eq 0) { return $false }       # WAIT_OBJECT_0: process exited
        return $true                            # WAIT_TIMEOUT or failure: fail closed
    } catch { return $true }
}

# A return from the wrapper intentionally lands in the dynamic call block.  It
# is therefore unsafe to rewrite that block while HITMAN can still have a thread
# at the call or inside the wrapper.  Unknown/unreadable bytes fail closed too.
function Hook-PatchMayBeLive {
    if (-not $MODE_INFO.UsesHook -or $script:hookSites.Count -eq 0) { return $false }
    if ($script:patched) { return $true }
    foreach ($site in $script:hookSites) {
        try {
            $cur=RB $script:handle ($script:base+$site.RVA) $site.Stock.Length
            if (Same $cur $site.Fix) { return $true }
            if (-not (Same $cur $site.Stock)) { return $true }
        } catch { return $true }
    }
    return $false
}

function Changes-MayBeLive {
    if ($script:patched -or $script:writtenSites.Count -gt 0 -or
        $script:scaleTouched -or $script:maskTouched -or $script:deviceRestoreUncertain -or
        $script:suspendedHandles.Count -gt 0 -or $script:unsafeCodeState) { return $true }
    return (Hook-PatchMayBeLive)
}

# --- window ----------------------------------------------------------------
$form=New-Object Windows.Forms.Form
$form.Text="HitmanVRFoveationFix v1.5"
$form.ClientSize=New-Object Drawing.Size(520,318)
$form.FormBorderStyle="FixedSingle"; $form.MaximizeBox=$false
$form.StartPosition="CenterScreen"
$form.Font=New-Object Drawing.Font("Segoe UI",9)

$title=New-Object Windows.Forms.Label
$title.Location=New-Object Drawing.Point(20,18); $title.Size=New-Object Drawing.Size(480,28)
$title.Text=$MODE_INFO.Title
$title.Font=New-Object Drawing.Font("Segoe UI",13,[Drawing.FontStyle]::Bold)
$form.Controls.Add($title)

$dot=New-Object Windows.Forms.Label
$dot.Location=New-Object Drawing.Point(20,64); $dot.Size=New-Object Drawing.Size(22,22)
$dot.Text=[char]0x25CF; $dot.Font=New-Object Drawing.Font("Segoe UI",16)
$dot.ForeColor=[Drawing.Color]::Gray
$form.Controls.Add($dot)

$state=New-Object Windows.Forms.Label
$state.Location=New-Object Drawing.Point(46,62); $state.Size=New-Object Drawing.Size(456,28)
$state.Font=New-Object Drawing.Font("Segoe UI",12,[Drawing.FontStyle]::Bold)
$form.Controls.Add($state)

$detail=New-Object Windows.Forms.Label
$detail.Location=New-Object Drawing.Point(22,96); $detail.Size=New-Object Drawing.Size(478,74)
$detail.Font=New-Object Drawing.Font("Segoe UI",9)
$form.Controls.Add($detail)

$note=New-Object Windows.Forms.Label
$note.Location=New-Object Drawing.Point(22,176); $note.Size=New-Object Drawing.Size(478,36)
$note.Font=New-Object Drawing.Font("Segoe UI",9,[Drawing.FontStyle]::Bold)
$note.ForeColor=[Drawing.Color]::FromArgb(190,110,0)
$form.Controls.Add($note)

$steps=New-Object Windows.Forms.Label
$steps.Location=New-Object Drawing.Point(22,214); $steps.Size=New-Object Drawing.Size(478,34)
$steps.Font=New-Object Drawing.Font("Segoe UI",9)
$steps.ForeColor=[Drawing.Color]::FromArgb(90,90,90)
$steps.Text="Start this tool before HITMAN. Leave the window open while you play."
$form.Controls.Add($steps)

$btnStop=New-Object Windows.Forms.Button
$btnStop.Location=New-Object Drawing.Point(22,252); $btnStop.Size=New-Object Drawing.Size(200,36)
$btnStop.Text="Turn off and restore"; $btnStop.Enabled=$false
$form.Controls.Add($btnStop)

$link=New-Object Windows.Forms.LinkLabel
$link.Location=New-Object Drawing.Point(240,260); $link.Size=New-Object Drawing.Size(260,22)
$link.Text="v1.5 - project page"
$link.LinkArea=New-Object Windows.Forms.LinkArea(0,4)
$link.TextAlign="MiddleRight"
$link.Add_LinkClicked({ Start-Process "https://github.com/RealChrizzl/hitman-vr-foveation-fix" })
$form.Controls.Add($link)

function Show-State { param($colour,$head,$body,$warn="")
    $uiKey=$colour+"`n"+$head+"`n"+$body+"`n"+$warn
    if ($script:lastUi -eq $uiKey) { return }
    $script:lastUi=$uiKey
    $dot.ForeColor = switch ($colour) {
        "green" { [Drawing.Color]::FromArgb(0,150,60) }
        "amber" { [Drawing.Color]::FromArgb(220,140,0) }
        "red"   { [Drawing.Color]::Firebrick }
        default { [Drawing.Color]::Gray } }
    $state.Text=$head; $detail.Text=$body; $note.Text=$warn }

Show-State "grey" "Waiting for HITMAN" "Start HITMAN after this tool. It will apply the fix before VR starts."

# --- attach ----------------------------------------------------------------
function Try-Attach {
    $procs=@()
    foreach ($candidate in @(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue)) {
        try { if (-not $candidate.HasExited) { $procs += $candidate } } catch {} }
    if ($procs.Count -eq 0) { return $false }
    if ($procs.Count -gt 1) { $script:fatal="More than one HITMAN process is running. Close them all and start the game once."; return $false }
    $p=$procs[0]
    try { if ($p.HasExited) { return $false } } catch { return $false }
    try { $path=$p.MainModule.FileName; $b=$p.MainModule.BaseAddress.ToInt64() } catch { return $false }

    try { $peCheck=Read-PE $path }
    catch { $script:fatal="Could not verify the game executable's code section."; return $false }
    $stamp=$peCheck.Stamp
    try { $exeHash=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToUpperInvariant() }
    catch { $script:fatal="Could not verify the game executable."; return $false }

    $sites=@(); $guards=@(); $hooks=@(); $mode=""; $slot=0L; $wno=0x31BL
    if ($stamp -eq $VERIFIED_TIMESTAMP) {
        if ($exeHash -ne $VERIFIED_SHA256) {
            Log ("refused executable hash {0}" -f $exeHash)
            $script:fatal="This executable has the verified build number but different code. Nothing was changed."
            return $false }
        foreach ($ctx in $VERIFIED_DIAGNOSTIC_CONTEXTS) {
            $offset=[int64]$ctx.RVA-[int64]$peCheck.TextRVA
            if ($offset -lt 0 -or ($offset+$ctx.Bytes.Length) -gt $peCheck.Text.Length) {
                $script:fatal="A verified instruction context falls outside the code section. Nothing was changed."
                return $false }
            $actual=New-Object byte[] $ctx.Bytes.Length
            [Array]::Copy($peCheck.Text,[int]$offset,$actual,0,$actual.Length)
            if (-not (Same $actual $ctx.Bytes)) {
                Log ("refused context mismatch at RVA 0x{0:X}" -f $ctx.RVA)
                $script:fatal="A verified instruction context does not match the executable. Nothing was changed."
                return $false } }

        $mode="verified"
        foreach ($c in $VERIFIED_CODE) {
            $sites += [pscustomobject]@{ Name=$c.Name; RVA=$c.RVA; Stock=$c.Stock; Fix=$c.Fix } }
        foreach ($g in $VERIFIED_GUARDS) {
            $guards += [pscustomobject]@{ Name=$g.Name; RVA=$g.RVA; Stock=$g.Stock } }
        $hooks=@($COPY_DEPTH_CALL_A,$COPY_DEPTH_CALL_B,$TRANSPARENT_PASS_CALL)
        $wno=$VERIFIED_WNO_OFF
    } else {
        $mode="scanned"
        foreach ($sig in $SIGS) {
            $hits=@(Find-Sig $peCheck.Text $sig.Pattern)
            if ($hits.Count -ne 1) {
                $script:fatal="The code for '" + $sig.What + "' could not be located uniquely in this build. Nothing was changed."
                return $false }
            $stock=New-Object byte[] $sig.Fix.Length
            [Array]::Copy($peCheck.Text,$hits[0]+$sig.Hit,$stock,0,$stock.Length)
            $sites += [pscustomobject]@{ Name=$sig.What; RVA=[int64]($peCheck.TextRVA+$hits[0]+$sig.Hit); Stock=$stock; Fix=$sig.Fix } }

        foreach ($sig in $HOOK_SIGS) {
            $hits=@(Find-Sig $peCheck.Text $sig.Pattern)
            if ($hits.Count -ne 1) {
                $script:fatal="The v1.4 refraction code for '" + $sig.Name + "' could not be located uniquely. Nothing was changed."
                return $false }
            $siteOffset=[int]($hits[0]+$sig.Hit)
            $stock=New-Object byte[] $sig.Length
            [Array]::Copy($peCheck.Text,$siteOffset,$stock,0,$stock.Length)
            if ($stock[$sig.CallOffset] -ne 0xE8) {
                $script:fatal="A located v1.4 refraction call has an unexpected instruction shape. Nothing was changed."
                return $false }
            $rel=[BitConverter]::ToInt32($stock,$sig.CallOffset+1)
            $rva=[int64]($peCheck.TextRVA+$siteOffset)
            $target=[int64]($rva+$sig.CallOffset+5L+$rel)
            if ($target -lt $peCheck.TextRVA -or $target -ge ($peCheck.TextRVA+$peCheck.Text.Length)) {
                $script:fatal="A located v1.4 refraction target falls outside executable code. Nothing was changed."
                return $false }
            $hooks += [pscustomobject]@{
                Name=$sig.Name; Kind=$sig.Kind; RVA=$rva; TargetRVA=$target
                ContinuationRVA=[int64]($rva+$sig.Length); UnitOffset=[int64]$sig.UnitOffset
                CounterOffset=[int64]$sig.CounterOffset; Stock=$stock }
        }
        $copyTargets=@($hooks | Where-Object {$_.Kind -like "Copy*"} | ForEach-Object {[int64]$_.TargetRVA} | Sort-Object -Unique)
        if ($copyTargets.Count -ne 1) {
            $script:fatal="The two located refraction-depth calls do not share one target. Nothing was changed."
            return $false }

        $hits=@(Find-Sig $peCheck.Text $SIG_DEVICE_PAT)
        if ($hits.Count -ne 1) {
            $script:fatal="The VR device reference could not be located uniquely in this build. Nothing was changed."
            return $false }
        $at=$hits[0]
        $rel=[BitConverter]::ToInt32($peCheck.Text,$at+$SIG_DEVICE_REL)
        $slot=[int64]($peCheck.TextRVA+$at+7+$rel)
        $wno=[int64][BitConverter]::ToUInt32($peCheck.Text,$at+$SIG_DEVICE_DSP)
        if ($wno -le 0 -or $wno -gt 0x4000) {
            $script:fatal="Implausible device layout in this build. Nothing was changed."
            return $false }
    }

    $hnd=[HmFix]::OpenProcess(0x1F0FFF,$false,$p.Id)
    if ($hnd -eq [IntPtr]::Zero) {
        try { if ($p.HasExited) { return $false } } catch { return $false }
        $script:fatal="Access denied. Close this tool and start it as administrator."
        return $false }

    if ($MODE_INFO.UsesHook) {
        [UInt32]$shadowPolicy=0
        if (-not [HmFix]::GetProcessMitigationPolicy($hnd,15,[ref]$shadowPolicy,[UIntPtr]::op_Explicit(4))) {
            [HmFix]::CloseHandle($hnd) | Out-Null
            $script:fatal="Windows' hardware shadow-stack state could not be verified. The v1.4 hook was not installed."
            return $false }
        if (($shadowPolicy -band 1) -ne 0) {
            [HmFix]::CloseHandle($hnd) | Out-Null
            $script:fatal="Hardware-enforced stack protection is active for HITMAN. This v1.4 hook is conservatively refused."
            return $false } }

    $script:handle=$hnd; $script:gamePid=$p.Id; $script:process=$p; $script:base=$b
    $script:mode=$mode; $script:sites=$sites; $script:guardSites=$guards; $script:hookDescriptors=$hooks
    $script:devSlot=$slot; $script:wnoOff=$wno
    Log ("attached pid {0}, build {1}, mode {2}, base sites {3}, guards {4}, v1.4 calls {5}" -f $p.Id,$stamp,$mode,$sites.Count,$guards.Count,$hooks.Count)
    Log ("writes: " + ((@($sites | ForEach-Object { "{0}=0x{1:X}" -f $(if($_.Name){$_.Name}else{"site"}),$_.RVA })) -join ", "))
    Log ("guards: " + ((@($guards | ForEach-Object { "{0}=0x{1:X}" -f $(if($_.Name){$_.Name}else{"site"}),$_.RVA })) -join ", "))
    return $true }

# --- device access, mode aware ---------------------------------------------
function Dev-Plausible { param([Int64]$d)
    if ($d -lt 0x10000 -or $d -gt 0x7FFFFFFFFFFF) { return $false }
    try {
        $fb = RB $script:handle ($d+$OFF_FOV) 16
        for ($i=0;$i -lt 4;$i++) {
            $f=[BitConverter]::ToSingle($fb,$i*4)
            if ($f -lt 0.2 -or $f -gt 3.0) { return $false } }
        $a = U8 $script:handle ($d+$OFF_ACTIVE)
        if ($a -gt 1) { return $false }
    } catch { return $false }
    return $true }

# returns 0 = no device yet, -1 = wrong backend, otherwise the device address
function Get-Dev {
    if ($script:mode -eq "verified") {
        $mgr=$script:base+$MANAGER_RVA
        if ((I64 $script:handle $mgr) -ne ($script:base+$MANAGER_VTABLE_RVA)) { return 0L }
        $d=I64 $script:handle ($mgr+$MANAGER_DEVICE_OFFSET)
        if ($d -eq 0) { return 0L }
        $vt = I64 $script:handle $d
        if ($vt -ne ($script:base+$OCULUS_VTABLE_RVA) -and
            $vt -ne ($script:base+$OPENVR_VTABLE_RVA)) { return -1L }
        return $d
    }
    try { $d = I64 $script:handle ($script:base+$script:devSlot) } catch { return 0L }
    if (-not (Dev-Plausible $d)) { return 0L }
    return $d }

# 0 = safely not running, 1 = running, -1 = state could not be proven.
function Get-VRStartState {
    try { $d = Get-Dev } catch { return -1 }
    if ($d -eq -1L) { return -1 }
    if ($d -eq 0L) { return 0 }
    try {
        $active=U8 $script:handle ($d+$OFF_ACTIVE)
        if ($active -eq 0) { return 0 }
        if ($active -eq 1) { return 1 }
        return -1
    } catch { return -1 } }

# Either backend is fine - the device layout is identical, verified on both.
function VR-Runtime-Loaded {
    try {
        # Process.Modules is cached by System.Diagnostics.Process. Refresh is
        # required or a runtime loaded after the first check is never observed.
        $script:process.Refresh()
        foreach ($m in $script:process.Modules) {
            if ($m.ModuleName -like "LibOVRRT*" -or $m.ModuleName -like "openvr_api*") { return $true } } } catch {}
    return $false }

# Read and neutralise the device values as soon as its geometry block is valid.
# In particular this runs before +0x319 becomes active.  OpenVR rebuilds the
# shader/constant-buffer state during mission and save-game loads; changing these
# fields only after that rebuild leaves the old centre mask cached on the GPU.
function Sync-RenderValuesCore { param([Int64]$d)
    $result=[pscustomobject]@{ Initialized=$false; Fixed=$false; Wrote=$false; Error="" }

    $fb=RB $script:handle ($d+$OFF_FOV) 16
    for ($i=0;$i -lt 4;$i++) {
        $f=[BitConverter]::ToSingle($fb,$i*4)
        if ([Single]::IsNaN($f) -or [Single]::IsInfinity($f) -or $f -lt 0.2 -or $f -gt 3.0) {
            return $result } }

    $sb=RB $script:handle ($d+$OFF_SCALE) 16
    for ($i=0;$i -lt 4;$i++) {
        $f=[BitConverter]::ToSingle($sb,$i*4)
        # All-zero scale fields mean the device builder has not reached this
        # block yet.  Do not capture or overwrite partially constructed data.
        if ([Single]::IsNaN($f) -or [Single]::IsInfinity($f) -or $f -lt 0.05 -or $f -gt 20.0) {
            return $result } }

    $mb=RB $script:handle ($d+$OFF_MASK) 8
    for ($i=0;$i -lt 2;$i++) {
        $f=[BitConverter]::ToSingle($mb,$i*4)
        if ([Single]::IsNaN($f) -or [Single]::IsInfinity($f) -or $f -lt -0.01 -or $f -gt 4.0) {
            return $result } }

    $result.Initialized=$true
    $scaleFixBytes=W2B $SCALE_FIX
    $sOk=Same $sb $scaleFixBytes
    $mOk=Same $mb $MASK_FIX

    if (-not $sOk) {
        $wasTouched=$script:scaleTouched
        if (-not $wasTouched) { $script:scaleStock=$sb }
        # Claim ownership before the call. WriteProcessMemory may modify a prefix
        # (or even all bytes) and still report failure/a short write.
        $script:scaleTouched=$true; $result.Wrote=$true
        try { WB $script:handle ($d+$OFF_SCALE) $scaleFixBytes } catch {}
        try { $after=RB $script:handle ($d+$OFF_SCALE) 16 }
        catch {
            $script:deviceRestoreUncertain=$true
            $result.Error="Scale write could not be verified. Close HITMAN if this repeats."
            return $result }
        if (-not (Same $after $scaleFixBytes)) {
            $rolledBack=Same $after $sb
            if (-not $rolledBack) {
                try {
                    WB $script:handle ($d+$OFF_SCALE) $sb
                    $rolledBack=Same (RB $script:handle ($d+$OFF_SCALE) 16) $sb }
                catch { $rolledBack=$false } }
            if ($rolledBack -and -not $wasTouched) {
                $script:scaleTouched=$false; $script:scaleStock=$null }
            if (-not $rolledBack) { $script:deviceRestoreUncertain=$true }
            $result.Error=if($rolledBack){"Scale write failed and was rolled back; retrying."}else{"Scale write left an unknown value. Close HITMAN."}
            return $result } }
    if (-not $mOk) {
        $wasTouched=$script:maskTouched
        if (-not $wasTouched) { $script:maskStock=$mb }
        $script:maskTouched=$true; $result.Wrote=$true
        try { WB $script:handle ($d+$OFF_MASK) $MASK_FIX } catch {}
        try { $after=RB $script:handle ($d+$OFF_MASK) 8 }
        catch {
            $script:deviceRestoreUncertain=$true
            $result.Error="Mask write could not be verified. Close HITMAN if this repeats."
            return $result }
        if (-not (Same $after $MASK_FIX)) {
            $rolledBack=Same $after $mb
            if (-not $rolledBack) {
                try {
                    WB $script:handle ($d+$OFF_MASK) $mb
                    $rolledBack=Same (RB $script:handle ($d+$OFF_MASK) 8) $mb }
                catch { $rolledBack=$false } }
            if ($rolledBack -and -not $wasTouched) {
                $script:maskTouched=$false; $script:maskStock=$null }
            if (-not $rolledBack) { $script:deviceRestoreUncertain=$true }
            $result.Error=if($rolledBack){"Mask write failed and was rolled back; retrying."}else{"Mask write left an unknown value. Close HITMAN."}
            return $result } }

    # A failed or immediately overwritten value must not result in a green
    # status.  A later tick retries it during the same loading transition.
    try {
        $result.Fixed = (Same (RB $script:handle ($d+$OFF_SCALE) 16) $scaleFixBytes) -and
                        (Same (RB $script:handle ($d+$OFF_MASK) 8) $MASK_FIX) }
    catch {
        # Preserve Wrote=true so a write made after transition 3 still latches
        # the required reload even when this final verification read is lost.
        $result.Error="Render values were written but the final verification read failed; retrying."
        return $result }
    return $result }

function Sync-RenderValues { param([Int64]$d)
    [Threading.Monitor]::Enter($script:renderSyncGate)
    try {
        # The guard raises its fault while holding this same lock, so anyone who
        # acquires it afterwards is guaranteed to see it. That is what makes the
        # unknown-state case genuinely fail closed rather than usually closed.
        $g=$script:rendererGuard
        if ($null -ne $g) {
            $faulted=$false
            try { $faulted=$g.HasFault } catch {}
            if ($faulted) {
                return [pscustomobject]@{ Initialized=$false; Fixed=$false; Wrote=$false
                    Error="A renderer value was left in an unknown state after a partial write. Close HITMAN." } } }
        return (Sync-RenderValuesCore $d)
    } finally { [Threading.Monitor]::Exit($script:renderSyncGate) }
}

function Prepare-HookCave {
    if (-not $MODE_INFO.UsesHook) { return $true }
    if ($script:hookPrepared) { return $true }
    try {
        $cave=Allocate-HookMemory
        if ($cave -eq 0) { throw "the private v1.4 wrapper allocation failed" }
        $dynamic=@()
        foreach ($call in $script:hookDescriptors) {
            if ([Int64]$call.ContinuationRVA -ne ([Int64]$call.RVA+[Int64]$call.Stock.Length)) {
                throw ("{0} call block does not end at its verified continuation" -f $call.Kind) }
            if($call.Kind -ne "Mesh") {
                $originalCallOffset=if($call.Kind -eq "Outer"){13}else{16}
                if ($call.Stock[$originalCallOffset] -ne 0xE8) { throw ("{0} original call opcode is missing" -f $call.Kind) }
                $originalRel=[BitConverter]::ToInt32($call.Stock,$originalCallOffset+1)
                $decodedTarget=[Int64]$call.RVA+$originalCallOffset+5L+$originalRel
                if ($decodedTarget -ne [Int64]$call.TargetRVA) {
                    throw ("{0} target RVA does not match the original direct call" -f $call.Kind) }
            }
            $unitAddress=$cave+[Int64]$call.UnitOffset
            if($call.Kind -eq "Outer"){$wrapper=Build-OuterUnit $unitAddress ($script:base+[Int64]$call.TargetRVA) ([bool]$MODE_INFO.OuterChangesCount)}
            elseif($call.Kind -eq "Mesh"){$wrapper=Build-MeshUnit $unitAddress}
            else{$wrapper=Build-CopyUnit $call $unitAddress ($script:base+[Int64]$call.TargetRVA) ([int]$MODE_INFO.CopyFrom) ([int]$MODE_INFO.CopyTo)}
            $expectedWrapperLength=
                if($call.Kind -eq "Outer"){if([bool]$MODE_INFO.OuterChangesCount){498}else{474}}
                elseif($call.Kind -eq "Mesh"){98}
                else{311}
            if ($wrapper.Length -ne $expectedWrapperLength -or ([Int64]$call.UnitOffset+$wrapper.Length) -gt 0x1000L) {
                throw ("{0} wrapper shape changed unexpectedly" -f $call.Kind) }
            WB $script:handle $unitAddress $wrapper
            $fix=Build-CallPatch $call $cave
            if ([BitConverter]::ToUInt64($fix,8) -ne [UInt64]$unitAddress) {
                throw ("{0} call block does not point at its wrapper" -f $call.Kind) }
            $dynamic += [pscustomobject]@{
                Name=$call.Name; Kind=$call.Kind; RVA=[Int64]$call.RVA
                Stock=[byte[]]$call.Stock; Fix=[byte[]]$fix
                WrapperAddress=$unitAddress; Wrapper=[byte[]]$wrapper }
        }
        if ($dynamic.Count -ne $MODE_INFO.HookKinds.Count) { throw "not every selected pass wrapper was built" }
        $magic=[Text.Encoding]::ASCII.GetBytes("HMFIX-V1.4-W")
        WB $script:handle ($cave+0x1400L) $magic
        [UInt32]$oldProtect=0
        if (-not [HmFix]::VirtualProtectEx($script:handle,[IntPtr]$cave,[UIntPtr]::op_Explicit(0x1000),0x20,[ref]$oldProtect)) {
            throw "could not make the verified hook page executable" }
        if (-not [HmFix]::FlushInstructionCache($script:handle,[IntPtr]$cave,[UIntPtr]::op_Explicit(0x1000))) {
            throw "could not flush the verified hook page" }
        foreach ($site in $dynamic) {
            if (-not (Same (RB $script:handle $site.WrapperAddress $site.Wrapper.Length) $site.Wrapper)) { throw "wrapper readback failed" }
            if ($site.Fix.Length -ne $site.Stock.Length) { throw "invalid dynamic call-block length" } }
        if (-not (Same (RB $script:handle ($cave+0x1400L) $magic.Length) $magic)) { throw "hook ownership marker readback failed" }
        $script:hookCave=$cave; $script:hookSites=$dynamic; $script:hookPrepared=$true
        Log ("v1.4 refraction cave prepared at 0x{0:X}; calls {1}" -f $cave,(($dynamic | ForEach-Object {$_.Kind}) -join ","))
        return $true
    } catch {
        $script:fatal=("The v1.4 refraction hook could not be prepared safely: {0}. Nothing was hooked." -f $_.Exception.Message)
        return $false }
}

function Read-HookTelemetry { param($Site)
    if (-not $script:hookPrepared -or $script:hookCave -eq 0) { return $null }
    $bytes=RB $script:handle ($script:hookCave+0x1000L) 0xA0
    return [pscustomobject]@{
        Kind=$Site.Kind
        Calls=[BitConverter]::ToUInt64($bytes,0x00)
        Changed=[BitConverter]::ToUInt64($bytes,0x08)
        Restored=[BitConverter]::ToUInt64($bytes,0x10)
        BadCount=[BitConverter]::ToUInt64($bytes,0x18)
        LastOld=[BitConverter]::ToUInt32($bytes,0x20)
        MaxTop=[BitConverter]::ToUInt32($bytes,0x24)
        BadState=[BitConverter]::ToUInt64($bytes,0x28)
        Active=[BitConverter]::ToUInt64($bytes,0x30)
        OwnerTid=[BitConverter]::ToUInt64($bytes,0x38)
        OwnerCtx=[BitConverter]::ToUInt64($bytes,0x40)
        OwnerAcquired=[BitConverter]::ToUInt64($bytes,0x48)
        OwnerReleased=[BitConverter]::ToUInt64($bytes,0x50)
        MeshOverrides=[BitConverter]::ToUInt64($bytes,0x58)
        CopyACalls=[BitConverter]::ToUInt64($bytes,0x60)
        CopyAChanged=[BitConverter]::ToUInt64($bytes,0x68)
        CopyARestored=[BitConverter]::ToUInt64($bytes,0x70)
        CopyAActive=[BitConverter]::ToUInt64($bytes,0x78)
        CopyBCalls=[BitConverter]::ToUInt64($bytes,0x80)
        CopyBChanged=[BitConverter]::ToUInt64($bytes,0x88)
        CopyBRestored=[BitConverter]::ToUInt64($bytes,0x90)
        CopyBActive=[BitConverter]::ToUInt64($bytes,0x98) }
}

function Read-AllHookTelemetry {
    if (-not $script:hookPrepared -or $script:hookCave -eq 0) { return $null }
    $bytes=RB $script:handle ($script:hookCave+0x1000L) 0xA0
    return [pscustomobject]@{
        Calls=[BitConverter]::ToUInt64($bytes,0x00); Changed=[BitConverter]::ToUInt64($bytes,0x08)
        Restored=[BitConverter]::ToUInt64($bytes,0x10); BadCount=[BitConverter]::ToUInt64($bytes,0x18)
        LastOld=[BitConverter]::ToUInt32($bytes,0x20); MaxTop=[BitConverter]::ToUInt32($bytes,0x24)
        BadState=[BitConverter]::ToUInt64($bytes,0x28); Active=[BitConverter]::ToUInt64($bytes,0x30)
        OwnerTid=[BitConverter]::ToUInt64($bytes,0x38); OwnerCtx=[BitConverter]::ToUInt64($bytes,0x40)
        OwnerAcquired=[BitConverter]::ToUInt64($bytes,0x48); OwnerReleased=[BitConverter]::ToUInt64($bytes,0x50)
        MeshOverrides=[BitConverter]::ToUInt64($bytes,0x58)
        CopyACalls=[BitConverter]::ToUInt64($bytes,0x60); CopyAChanged=[BitConverter]::ToUInt64($bytes,0x68)
        CopyARestored=[BitConverter]::ToUInt64($bytes,0x70); CopyAActive=[BitConverter]::ToUInt64($bytes,0x78)
        CopyBCalls=[BitConverter]::ToUInt64($bytes,0x80); CopyBChanged=[BitConverter]::ToUInt64($bytes,0x88)
        CopyBRestored=[BitConverter]::ToUInt64($bytes,0x90); CopyBActive=[BitConverter]::ToUInt64($bytes,0x98) }
}

function Get-HookTelemetryState {
    $result=[pscustomobject]@{ Ready=(-not $MODE_INFO.UsesHook); Error=""; Summary="" }
    if (-not $MODE_INFO.UsesHook) { return $result }
    $parts=@(); $allReady=$true; $now=Get-Date
    try {
        $checkIntegrity=(($now-$script:lastHookIntegrityCheck).TotalSeconds -ge 2)
        foreach ($site in $script:hookSites) {
            if ($checkIntegrity) {
                if (-not (Same (RB $script:handle ($script:base+$site.RVA) $site.Fix.Length) $site.Fix)) {
                    throw ("{0} call block no longer matches the installed v1.4 fix" -f $site.Kind) }
                if (-not (Same (RB $script:handle $site.WrapperAddress $site.Wrapper.Length) $site.Wrapper)) {
                    throw ("{0} wrapper code no longer matches its verified image" -f $site.Kind) } }
        }
        $t=Read-AllHookTelemetry
        if ($null -eq $t) { throw "hook telemetry is unavailable" }
        if ($t.BadCount -ne 0 -or $t.BadState -ne 0 -or $t.MaxTop -gt 4) {
            throw ("a wrapper rejected an unexpected owner/count state (badCount={0}, badState={1}, maxTop={2})" -f $t.BadCount,$t.BadState,$t.MaxTop) }
        $stableSample=$null
        if ($t.Active -eq 0 -and $t.CopyAActive -eq 0 -and $t.CopyBActive -eq 0) {
            $second=Read-AllHookTelemetry
            if($null -ne $second -and $second.Active -eq 0 -and $second.CopyAActive -eq 0 -and $second.CopyBActive -eq 0 -and
               $second.Calls -eq $t.Calls -and $second.Changed -eq $t.Changed -and $second.Restored -eq $t.Restored -and
               $second.CopyACalls -eq $t.CopyACalls -and $second.CopyAChanged -eq $t.CopyAChanged -and $second.CopyARestored -eq $t.CopyARestored -and
               $second.CopyBCalls -eq $t.CopyBCalls -and $second.CopyBChanged -eq $t.CopyBChanged -and $second.CopyBRestored -eq $t.CopyBRestored -and
               $second.OwnerTid -eq $t.OwnerTid -and $second.OwnerCtx -eq $t.OwnerCtx){$stableSample=$second}
        }
        if ($null -ne $stableSample) {
            if($t.OwnerTid -ne 0 -or $t.OwnerCtx -ne 0){throw "the transparent-pass owner marker stayed set"}
            if($t.OwnerAcquired -ne $t.OwnerReleased){throw "transparent-pass owner acquisition was not balanced"}
            if($t.Changed -ne $t.Restored -or $t.CopyAChanged -ne $t.CopyARestored -or $t.CopyBChanged -ne $t.CopyBRestored){throw "a local count change was not restored"}
        }
        if($t.OwnerAcquired -eq 0){$allReady=$false}
        if($t.CopyAChanged -eq 0 -or $t.CopyBChanged -eq 0){$allReady=$false}
        foreach($unitName in @("Outer","CopyA","CopyB")){
            $isActive=if($unitName -eq "Outer"){$t.Active}elseif($unitName -eq "CopyA"){$t.CopyAActive}else{$t.CopyBActive}
            $progressValue=if($unitName -eq "Outer"){$t.Calls+$t.Restored}elseif($unitName -eq "CopyA"){$t.CopyACalls+$t.CopyARestored}else{$t.CopyBCalls+$t.CopyBRestored}
            $progress=$script:hookProgress[$unitName]
            if($isActive -eq 0){$script:hookProgress.Remove($unitName)|Out-Null}
            elseif($null -eq $progress -or $progress.Value -ne $progressValue){$script:hookProgress[$unitName]=[pscustomobject]@{Value=$progressValue;Since=$now}}
            elseif(($now-$progress.Since).TotalSeconds -ge 10){throw ("{0} wrapper stayed active without progress for ten seconds" -f $unitName)}
        }
        $parts += ("outer calls={0}, owner={1}/{2}, changed={3}/{4}, mesh4={5}, copyA={6}/{7}/{8}, copyB={9}/{10}/{11}, active={12}/{13}/{14}" -f $t.Calls,$t.OwnerAcquired,$t.OwnerReleased,$t.Changed,$t.Restored,$t.MeshOverrides,$t.CopyACalls,$t.CopyAChanged,$t.CopyARestored,$t.CopyBCalls,$t.CopyBChanged,$t.CopyBRestored,$t.Active,$t.CopyAActive,$t.CopyBActive)
        if ($checkIntegrity) {
            foreach($s in $script:sites){if(-not (Same (RB $script:handle ($script:base+$s.RVA) $s.Fix.Length) $s.Fix)){throw ("base fix changed at RVA 0x{0:X}" -f $s.RVA)}}
            foreach($g in $script:guardSites){if(-not (Same (RB $script:handle ($script:base+$g.RVA) $g.Stock.Length) $g.Stock)){throw ("stock guard changed at RVA 0x{0:X}" -f $g.RVA)}}
            $magic=[Text.Encoding]::ASCII.GetBytes("HMFIX-V1.4-W")
            if (-not (Same (RB $script:handle ($script:hookCave+0x1400L) $magic.Length) $magic)) {
                throw "the v1.4 wrapper ownership marker changed" }
            $script:lastHookIntegrityCheck=$now }
        $result.Ready=$allReady; $result.Summary=($parts -join "; ")
        if (((Get-Date)-$script:lastHookLog).TotalSeconds -ge 5) {
            Log ("pass telemetry: " + $result.Summary)
            $script:lastHookLog=Get-Date }
    } catch { $result.Error=$_.Exception.Message }
    return $result
}

function Apply-Code {
    foreach ($g in $script:guardSites) {
        $cur = RB $script:handle ($script:base+$g.RVA) $g.Stock.Length
        if (-not (Same $cur $g.Stock)) {
            $script:fatal="A guarded renderer site is not in its original state. Close HITMAN and every fix window, then start v1.5 again."
            return $false } }

    $allFix=$true; $allStock=$true
    foreach ($s in $script:sites) {
        $cur = RB $script:handle ($script:base+$s.RVA) $s.Fix.Length
        if (-not (Same $cur $s.Fix))   { $allFix=$false }
        if (-not (Same $cur $s.Stock)) { $allStock=$false } }
    if ($allFix) {
        $script:fatal="HITMAN was already patched before this tool attached. Close every fix window and HITMAN, then start this tool again."
        return $false }
    if (-not $allStock) {
        $script:fatal="The game code is not in its original state. Close HITMAN, start it again, then this tool."
        return $false }

    $vrStartState=Get-VRStartState
    if ($vrStartState -lt 0) {
        $script:fatal="The pre-VR renderer state could not be proven safely. Close HITMAN and retry; nothing was changed."
        return $false }
    if ($vrStartState -eq 1) {
        $script:fatal="VR was already running when this tool attached. Close HITMAN, start this tool first, then the game."
        return $false }

    if ($MODE_INFO.UsesHook) {
        foreach ($call in $script:hookDescriptors) {
            if (-not (Same (RB $script:handle ($script:base+$call.RVA) $call.Stock.Length) $call.Stock)) {
                $script:fatal="A v1.4 refraction call is not in its original state. Close HITMAN and every fix window, then start v1.5 again."
                return $false } }
        if (-not (Prepare-HookCave)) { return $false } }

    $held=@()
    try { $held=@(Suspend-GameThreads) }
    catch {
        $script:fatal=("The game could not be paused safely for the atomic patch transaction: {0}. Nothing was changed." -f $_.Exception.Message)
        return $false }

    # Multi-instruction call blocks must never be replaced while a suspended
    # thread is parked anywhere inside them.  The same conservative check is
    # applied to the small v1.3 sites.  On a busy frame we simply resume and
    # retry on a later timer tick without writing a byte.
    try {
        $ranges=@()
        foreach ($s in @($script:sites)+@($script:hookSites)) {
            $start=[UInt64]($script:base+[Int64]$s.RVA)
            $ranges += [pscustomobject]@{ Start=$start; End=[UInt64]($start+[UInt64]$s.Stock.Length) } }
        foreach ($s in @($script:hookSites)) {
            $start=[UInt64]$s.WrapperAddress
            $ranges += [pscustomobject]@{ Start=$start; End=[UInt64]($start+[UInt64]$s.Wrapper.Length) } }
        $telemetry=Read-AllHookTelemetry
        if ($null -eq $telemetry -or $telemetry.Active -ne 0 -or $telemetry.CopyAActive -ne 0 -or $telemetry.CopyBActive -ne 0 -or
            $telemetry.Calls -ne 0 -or $telemetry.OwnerTid -ne 0 -or $telemetry.OwnerCtx -ne 0 -or
            $telemetry.CopyACalls -ne 0 -or $telemetry.CopyBCalls -ne 0 -or $telemetry.MeshOverrides -ne 0) {
            throw "the fresh v1.4 wrapper data page did not have a clean zero state" }
        $rangesClear=Threads-AreOutsidePatchRanges $held $ranges
    }
    catch {
        $resumeOk=Resume-GameThreads $held; $held=@()
        $script:fatal=("The patch was not installed because thread positions could not be verified safely: {0}. Nothing was changed." -f $_.Exception.Message)
        if (-not $resumeOk) { $script:fatal += " One or more game threads could not be resumed; close HITMAN." }
        return $false }
    if (-not $rangesClear) {
        $resumeOk=Resume-GameThreads $held; $held=@()
        if (-not $resumeOk) {
            $script:fatal="A game thread could not be resumed after a deferred patch attempt. Close HITMAN; nothing was written."
            return $false }
        if (((Get-Date)-$script:lastPatchBusyLog).TotalSeconds -ge 2) {
            Log "patch transaction deferred because a render thread was inside a target instruction block"
            $script:lastPatchBusyLog=Get-Date }
        Start-Sleep -Milliseconds 50
        return $false }

    $written=@(); $hookWritten=@(); $applyOk=$false; $rollbackOk=$true; $failure=""
    try {
        # Recheck every precondition while all target threads are stopped.
        $suspendedVrState=Get-VRStartState
        if ($suspendedVrState -ne 0) {
            if ($suspendedVrState -eq 1) { throw "VR became active before the suspended patch transaction" }
            throw "the renderer state became uncertain before the suspended patch transaction" }
        if ($script:mode -eq "verified") {
            foreach ($ctx in $VERIFIED_DIAGNOSTIC_CONTEXTS) {
                if (-not (Same (RB $script:handle ($script:base+$ctx.RVA) $ctx.Bytes.Length) $ctx.Bytes)) {
                    throw ("a loaded verified code context changed at RVA 0x{0:X}" -f $ctx.RVA) } } }
        foreach ($g in $script:guardSites) {
            if (-not (Same (RB $script:handle ($script:base+$g.RVA) $g.Stock.Length) $g.Stock)) {
                throw "a guarded renderer site changed before the suspended transaction" } }
        foreach ($s in $script:sites) {
            if (-not (Same (RB $script:handle ($script:base+$s.RVA) $s.Stock.Length) $s.Stock)) {
                throw "a base site changed before the suspended transaction" } }
        foreach ($s in $script:hookSites) {
            if (-not (Same (RB $script:handle ($script:base+$s.RVA) $s.Stock.Length) $s.Stock)) {
                throw "a selected pass call changed before the suspended transaction" } }

        foreach ($s in $script:sites) {
            # Include the site before attempting the write: WriteProcessMemory
            # can modify a prefix and still report a short/failed write.
            $written += $s
            WB $script:handle ($script:base+$s.RVA) $s.Fix }
        foreach ($s in $script:hookSites) {
            $hookWritten += $s
            WB $script:handle ($script:base+$s.RVA) $s.Fix }
        foreach ($s in $script:sites) {
            if (-not (Same (RB $script:handle ($script:base+$s.RVA) $s.Fix.Length) $s.Fix)) {
                throw "verification failed" } }
        foreach ($s in $script:hookSites) {
            if (-not (Same (RB $script:handle ($script:base+$s.RVA) $s.Fix.Length) $s.Fix)) {
                throw "hook verification failed" } }
        foreach ($g in $script:guardSites) {
            if (-not (Same (RB $script:handle ($script:base+$g.RVA) $g.Stock.Length) $g.Stock)) {
                throw "a guarded renderer site changed during patch" } }
        $applyOk=$true
    } catch {
        $failure=$_.Exception.Message
        # Never leave the game with only a subset of this mode's instructions
        # patched.  Roll back every site written by this attempt immediately.
        for ($i=$hookWritten.Count-1;$i -ge 0;$i--) {
            $s=$hookWritten[$i]
            try {
                WB $script:handle ($script:base+$s.RVA) $s.Stock
                if (-not (Same (RB $script:handle ($script:base+$s.RVA) $s.Stock.Length) $s.Stock)) { $rollbackOk=$false } }
            catch { $rollbackOk=$false } }
        foreach ($s in $written) {
            try {
                WB $script:handle ($script:base+$s.RVA) $s.Stock
                if (-not (Same (RB $script:handle ($script:base+$s.RVA) $s.Stock.Length) $s.Stock)) {
                    $rollbackOk=$false } }
            catch { $rollbackOk=$false } }
    } finally {
        if (-not $applyOk -and -not $rollbackOk) {
            # A failed rollback can leave a partially rewritten instruction or
            # call block.  Never let a target thread execute that uncertainty.
            # Keep every handle suspended until the user terminates HITMAN;
            # process exit is the only operation that discards this state.
            $script:unsafeCodeState=$true
            $script:suspendedHandles += @($held)
            $held=@()
        } elseif (-not (Resume-GameThreads $held)) {
            $applyOk=$false; $rollbackOk=$false
            if (-not $failure) { $failure="one or more game threads could not be resumed" } } }

    if (-not $applyOk) {
        $script:writtenSites=if($rollbackOk){@()}else{@($written)}
        if ($rollbackOk) {
            $script:fatal=("A patch transaction failed ({0}) and was rolled back. Restart HITMAN before retrying." -f $failure) }
        elseif ($script:unsafeCodeState) {
            $script:fatal=("A patch transaction failed ({0}) and its rollback could not be verified. HITMAN remains deliberately suspended. End HITMAN in Task Manager; do not resume it." -f $failure) }
        else {
            $script:fatal=("A patch transaction failed ({0}) and could not be made safe. Close HITMAN now; every change disappears when the game exits." -f $failure) }
        return $false }
    $script:writtenSites=$written
    $script:patched=$true
    Log ("v1.5 code patched, base sites {0}, refraction calls {1}" -f $written.Count,$hookWritten.Count)
    return $true }

# Restore renderer ownership and every code block while HITMAN is still live.
# The dynamic CALL blocks can only be rewritten while all game threads are
# suspended, no wrapper is active, and no RIP is inside a block or wrapper.
# The executable cave itself remains allocated until process exit; this avoids
# a stale-instruction or stale-return-address lifetime race.
function Restore-RendererValues {
    $ok=-not $script:deviceRestoreUncertain
    if ($script:dev -eq 0) { return $ok }
    $deviceCurrent=$false
    try { $deviceCurrent=((Get-Dev) -eq $script:dev) } catch {}
    if (-not $deviceCurrent -and ($script:scaleTouched -or $script:maskTouched)) { return $false }
    if (-not $deviceCurrent) { return $ok }

    if ($script:scaleTouched) {
        $stock=$script:scaleStock; if ($null -eq $stock) { $stock=W2B $SCALE_STOCK }
        try {
            $cur=RB $script:handle ($script:dev+$OFF_SCALE) 16
            if (Same $cur (W2B $SCALE_FIX)) {
                if ((Get-Dev) -ne $script:dev) { throw "device changed during scale restore" }
                WB $script:handle ($script:dev+$OFF_SCALE) $stock
                if (-not (Same (RB $script:handle ($script:dev+$OFF_SCALE) 16) $stock)) { $ok=$false } }
            elseif (-not (Same $cur $stock)) { $ok=$false } }
        catch { $ok=$false }
    }
    if ($script:maskTouched) {
        $stock=$script:maskStock; if ($null -eq $stock) { $stock=$MASK_STOCK }
        try {
            $cur=RB $script:handle ($script:dev+$OFF_MASK) 8
            if (Same $cur $MASK_FIX) {
                if ((Get-Dev) -ne $script:dev) { throw "device changed during mask restore" }
                WB $script:handle ($script:dev+$OFF_MASK) $stock
                if (-not (Same (RB $script:handle ($script:dev+$OFF_MASK) 8) $stock)) { $ok=$false } }
            elseif (-not (Same $cur $stock)) { $ok=$false } }
        catch { $ok=$false }
    }
    return $ok
}

function Restore {
    if (-not (Stop-RendererGuard)) { return $false }
    if ($script:handle -eq [IntPtr]::Zero) { return $true }
    if (-not (Game-IsAlive)) { return $true }
    if ($script:unsafeCodeState) { return $false }

    [Threading.Monitor]::Enter($script:renderSyncGate)
    try {
        $held=@(); $safeSnapshot=$false
        for ($attempt=0;$attempt -lt 20 -and -not $safeSnapshot;$attempt++) {
            try { $held=@(Suspend-GameThreads) }
            catch { $script:fatal=$_.Exception.Message; return $false }
            try {
                $ranges=@()
                foreach ($s in @($script:writtenSites)+@($script:hookSites)) {
                    $start=[UInt64]($script:base+[Int64]$s.RVA)
                    $ranges += [pscustomobject]@{Start=$start;End=[UInt64]($start+[UInt64]$s.Stock.Length)} }
                foreach ($s in @($script:hookSites)) {
                    $start=[UInt64]$s.WrapperAddress
                    $ranges += [pscustomobject]@{Start=$start;End=[UInt64]($start+[UInt64]$s.Wrapper.Length)} }
                $telemetry=Read-AllHookTelemetry
                $inactive=($null -eq $telemetry -or
                    ($telemetry.Active -eq 0 -and $telemetry.CopyAActive -eq 0 -and $telemetry.CopyBActive -eq 0 -and
                     $telemetry.OwnerTid -eq 0 -and $telemetry.OwnerCtx -eq 0))
                $safeSnapshot=$inactive -and (Threads-AreOutsidePatchRanges $held $ranges)
            } catch {
                Resume-GameThreads $held | Out-Null; $held=@()
                $script:fatal=("Live restoration could not verify game-thread positions: {0}" -f $_.Exception.Message)
                return $false
            }
            if (-not $safeSnapshot) {
                if (-not (Resume-GameThreads $held)) { return $false }
                $held=@(); Start-Sleep -Milliseconds 50 }
        }
        if (-not $safeSnapshot) {
            $script:fatal="The refraction pass stayed busy. Try Turn off again, or close HITMAN. Nothing was restored."
            return $false
        }

        $restoreOrder=@()
        for ($i=$script:hookSites.Count-1;$i -ge 0;$i--) { $restoreOrder += $script:hookSites[$i] }
        $restoreOrder += @($script:writtenSites)
        $restored=@(); $codeOk=$false; $rollbackOk=$true; $failure=""
        try {
            foreach ($s in $restoreOrder) {
                $cur=RB $script:handle ($script:base+$s.RVA) $s.Fix.Length
                if (-not (Same $cur $s.Fix)) {
                    if (Same $cur $s.Stock) { continue }
                    throw ("foreign bytes at RVA 0x{0:X}" -f $s.RVA) }
                $restored += $s
                WB $script:handle ($script:base+$s.RVA) $s.Stock
                if (-not (Same (RB $script:handle ($script:base+$s.RVA) $s.Stock.Length) $s.Stock)) {
                    throw ("restore verification failed at RVA 0x{0:X}" -f $s.RVA) }
            }
            $codeOk=$true
        } catch {
            $failure=$_.Exception.Message
            for ($i=$restored.Count-1;$i -ge 0;$i--) {
                $s=$restored[$i]
                try {
                    WB $script:handle ($script:base+$s.RVA) $s.Fix
                    if (-not (Same (RB $script:handle ($script:base+$s.RVA) $s.Fix.Length) $s.Fix)) { $rollbackOk=$false } }
                catch { $rollbackOk=$false }
            }
        }

        if (-not $codeOk) {
            if (-not $rollbackOk) {
                $script:unsafeCodeState=$true
                $script:suspendedHandles += @($held); $held=@()
                $script:fatal=("Live restoration failed ({0}) and rollback was not verifiable. HITMAN remains suspended. End it in Task Manager; do not resume it." -f $failure)
            } else {
                Resume-GameThreads $held | Out-Null; $held=@()
                $script:fatal=("Live restoration failed ({0}) and was rolled back safely. Close HITMAN or try again." -f $failure)
            }
            return $false
        }

        $valuesOk=Restore-RendererValues
        $resumeOk=Resume-GameThreads $held; $held=@()
        if (-not $resumeOk) {
            $script:fatal="The fix was restored, but one or more HITMAN threads could not be resumed. Close HITMAN."
            return $false }

        $script:patched=$false; $script:writtenSites=@()
        if ($valuesOk) {
            $script:scaleTouched=$false; $script:maskTouched=$false
            $script:scaleStock=$null; $script:maskStock=$null
            $script:deviceRestoreUncertain=$false
            Log "restored"
            return $true
        }
        $script:fatal="Code was restored, but a renderer value could not be restored safely. Closing HITMAN always discards it."
        Log "restore incomplete - close HITMAN"
        return $false
    } finally {
        if ($held.Count -gt 0 -and -not $script:unsafeCodeState) {
            Resume-GameThreads $held | Out-Null }
        [Threading.Monitor]::Exit($script:renderSyncGate)
    }
}

# --- main loop -------------------------------------------------------------
$timer=New-Object Windows.Forms.Timer
$timer.Interval=15
$timer.Add_Tick({
    try {
        if ($script:stopped) { return }

        if ($script:handle -ne [IntPtr]::Zero) {
            $gameClosed=(-not (Game-IsAlive))
            if ($gameClosed) {
                Log "game closed"; Detach; $script:fatal=""
                Show-State "grey" "Waiting for HITMAN" "The game was closed. Start it again and v1.5 will apply automatically."
                $btnStop.Enabled=$false; return } }

        if ($script:suspendedHandles.Count -gt 0) {
            if ($script:unsafeCodeState) {
                Show-State "red" "End HITMAN in Task Manager" "A failed code rollback could not be verified. HITMAN is deliberately kept suspended so the uncertain instruction can never execute. Force-close the game process; do not resume it."
                return }
            if (Resume-GameThreads @()) { Log "previously suspended game threads were resumed on retry" }
            else {
                Show-State "red" "Close HITMAN" "One or more game threads could not be resumed after three retries. End HITMAN from Task Manager; no further write will be attempted."
                return } }

        if ($script:fatal) { Show-State "red" "Not active" $script:fatal; return }

        if ($script:handle -eq [IntPtr]::Zero) {
            if (-not (Try-Attach)) { if ($script:fatal) { Show-State "red" "Not active" $script:fatal }; return } }

        $warn=""
        if ($script:mode -eq "scanned") {
            $warn="Untested build - every code pattern was unique, but please check the image carefully." }
        $ready="v1.5 is patched. Put on your headset, start VR as usual, then load a mission."

        if (-not $script:patched) {
            if (-not (Apply-Code)) { return }
            $btnStop.Enabled=$true
            Show-State "amber" "Ready - start VR" $ready $warn
            return }

        $hookState=Get-HookTelemetryState
        if ($hookState.Error) {
            Stop-RendererGuard | Out-Null
            $script:fatal=("The pass-local safety monitor detected an unexpected state: {0}. Close HITMAN now; do not continue this run." -f $hookState.Error)
            Show-State "red" "Stop this run" $script:fatal $warn
            return }

        if ($script:guardError) {
            Stop-RendererGuard | Out-Null
            $script:fatal=("The continuous renderer guard stopped after a validated sync error: {0}" -f $script:guardError)
            Show-State "red" "Renderer guard stopped" $script:fatal $warn
            return }

        $d = Get-Dev
        if ($d -eq -1L) {
            if ($script:dev -ne 0) { Reset-DeviceState $true }
            Show-State "red" "Unsupported backend" "The active VR device is neither the Oculus nor the SteamVR one this tool was verified against."
            return }
        if ($d -eq 0L) {
            if ($script:dev -ne 0) {
                Log "VR device became unavailable"
                Reset-DeviceState $true }
            Show-State "amber" "Ready - start VR" $ready $warn; return }
        if ($d -ne $script:dev) {
            if ($script:dev -ne 0) { Reset-DeviceState $true } else { Reset-DeviceState }
            $script:dev=$d
            $backend="unknown"
            try {
                $vt=I64 $script:handle $d
                if ($vt -eq ($script:base+$OCULUS_VTABLE_RVA)) { $backend="Oculus" }
                elseif ($vt -eq ($script:base+$OPENVR_VTABLE_RVA)) { $backend="SteamVR/OpenVR" } }
            catch {}
            Log ("VR device found at 0x{0:X}, backend {1}" -f $d,$backend) }

        $active=U8  $script:handle ($d+$OFF_ACTIVE)
        $wno   =U8  $script:handle ($d+$script:wnoOff)
        $trans =U32 $script:handle ($d+$OFF_TRANS)
        $layers=U16 $script:handle ($d+$OFF_LAYERS)
        $tex   =I64 $script:handle ($d+$OFF_TEX)
        $w     =U32 $script:handle ($d+$OFF_W)
        $h     =U32 $script:handle ($d+$OFF_H)

        if ($script:mode -eq "scanned" -and -not $script:runtimeLoaded) {
            $runtimeNow=[Diagnostics.Stopwatch]::GetTimestamp()
            $runtimeAge=if($script:lastRuntimeCheck -eq 0){[double]::PositiveInfinity}else{($runtimeNow-$script:lastRuntimeCheck)*1000.0/[Diagnostics.Stopwatch]::Frequency}
            if ($runtimeAge -ge 500) {
                $script:runtimeLoaded=VR-Runtime-Loaded
                $script:lastRuntimeCheck=$runtimeNow }
        }
        if ($script:mode -eq "scanned" -and -not $script:runtimeLoaded) {
            $script:stableReady=0; $script:stableSince=0L
            $script:lastTrans=-1L; $script:needRel=$false
            if ($active -eq 1) {
                Show-State "red" "No VR runtime" "Neither the Oculus nor the SteamVR runtime is loaded in the game." }
            else { Show-State "amber" "Ready - start VR" $ready $warn }
            return }

        if ($active -eq 1 -and $wno -ne 0) {
            $script:stableReady=0; $script:stableSince=0L
            Show-State "red" "Not active" "VR started before the patch could take effect. Close HITMAN, start this tool first, then the game."
            return }

        $sync=Sync-RenderValues $d
        if (-not $sync.Error -and $sync.Initialized -and $sync.Fixed) {
            Ensure-RendererGuard $d | Out-Null
            # Only now may the guard write on its own thread: both fields are
            # owned, were written by the validated transaction and read back
            # clean. The guard never does anything but restore these bytes.
            if ($null -ne $script:rendererGuard -and $script:scaleTouched -and $script:maskTouched) {
                try { $script:rendererGuard.Arm() } catch {} } }
        if ($sync.Wrote) {
            $script:pendingValueWrite=$true
            # Close the read/write race: classify the write using a fresh state
            # sample. The renderer may have reached transition 3 while the two
            # value groups were being written.
            $active=U8  $script:handle ($d+$OFF_ACTIVE)
            $wno   =U8  $script:handle ($d+$script:wnoOff)
            $trans =U32 $script:handle ($d+$OFF_TRANS)
            $layers=U16 $script:handle ($d+$OFF_LAYERS)
            $tex   =I64 $script:handle ($d+$OFF_TEX)
            $w     =U32 $script:handle ($d+$OFF_W)
            $h     =U32 $script:handle ($d+$OFF_H) }

        if ($active -eq 1 -and $wno -ne 0) {
            $script:stableReady=0; $script:stableSince=0L
            Show-State "red" "Not active" "VR started before the patch could take effect. Close HITMAN, start this tool first, then the game."
            return }

        # Every tick, whether or not a callback arrived.
        Update-RendererGuardState
        if ($script:guardError) {
            Stop-RendererGuard | Out-Null
            $script:fatal=("The continuous renderer guard stopped after a validated sync error: {0}" -f $script:guardError)
            Show-State "red" "Renderer guard stopped" $script:fatal $warn
            return }
        if ($script:guardWritePending) {
            $script:pendingValueWrite=$true
            $script:guardWritePending=$false }

        # A direct repair disturbs the image, so the stable countdown restarts -
        # but it is NOT fed to Advance-Lifecycle, because its transition was
        # sampled by the guard and may no longer be the one we can read now.
        if ($script:guardDirectRepair) {
            $script:stableReady=0; $script:stableSince=0L
            $script:guardDirectRepair=$false }

        $life=Advance-Lifecycle $script:lastTrans $script:needRel $trans $script:pendingValueWrite

        # A guard repair classified at transition 3 must survive the gap to the
        # 15 ms lifecycle sample. Keep it latched through the following non-3
        # rebuild phase and clear it only once that cycle reaches transition 3.
        $life=Apply-GuardReloadLatch $life $trans
        if ($life.TransitionChanged) {
            Log ("transition {0} -> {1}" -f $script:lastTrans,$trans) }
        $script:lastTrans=$life.LastTransition
        $script:needRel=$life.NeedReload
        $script:pendingValueWrite=$false
        if ($life.ResetStable) { $script:stableReady=0; $script:stableSince=0L }

        if ($sync.Wrote) {
            $now=Get-Date
            if (($now-$script:lastWriteLog).TotalSeconds -ge 1) {
                Log ("values synchronised, transition={0}, active={1}" -f $trans,$active)
                $script:lastWriteLog=$now } }

        if ($sync.Error) {
            $script:stableReady=0; $script:stableSince=0L
            Show-State "red" "Renderer write failed" $sync.Error $warn
            return }

        if ($active -ne 1) {
            $script:stableReady=0; $script:stableSince=0L
            Show-State "amber" "Ready - start VR" $ready $warn; return }

        if (-not $sync.Initialized -or -not $sync.Fixed) {
            $script:stableReady=0; $script:stableSince=0L
            Show-State "amber" "Waiting for the VR renderer" "The device is still initialising. The fix will arm before its render state is built." $warn
            return }

        if ($trans -ne 3 -or $layers -ne 2 -or $tex -eq 0) {
            $script:stableReady=0; $script:stableSince=0L
            Show-State "amber" "Waiting for a mission" "VR is running in two-layer mode. Load a mission and the fix becomes active." $warn
            return }

        if (-not $hookState.Ready) {
            $script:stableReady=0; $script:stableSince=0L
            Show-State "amber" "Waiting for the scene renderer" "The refraction wrapper and guard are installed. Load a mission so the glass/water pass runs once." $warn
            return }

        if ($script:needRel) {
            $script:stableReady=0; $script:stableSince=0L
            Show-State "amber" "Reload this mission once" "The fix is set, but this mission was already running when it was applied. Reload it once and the image will be sharp everywhere." $warn
        } else {
            $stableNow=[Diagnostics.Stopwatch]::GetTimestamp()
            if ($script:stableSince -eq 0) { $script:stableSince=$stableNow }
            if ($script:stableReady -lt 3) { $script:stableReady++ }
            $stableMs=($stableNow-$script:stableSince)*1000.0/[Diagnostics.Stopwatch]::Frequency
            if ($script:stableReady -lt 3 -or $stableMs -lt 250) {
                Show-State "amber" "Finishing the mission load" "The render values are correct. Waiting briefly to make sure they remain stable." $warn
            } else {
                Show-State "green" "Active" ("Sharp from edge to edge at {0} x {1} per eye. Glass, water and refraction use the corrected two-eye copy path; the 1 ms save-load guard is running." -f $w,$h) $warn } }
    } catch {
        Show-State "red" "Something went wrong" ($_.Exception.Message + "  Close HITMAN and try again.") }
})
$timer.Start()

$btnStop.Add_Click({
    if ($script:unsafeCodeState -and (Game-IsAlive)) {
        Show-State "red" "End HITMAN in Task Manager" "The failed rollback remains deliberately suspended. Force-close the HITMAN process; do not resume it." $MODE_INFO.Warning
        return }
    $restored=Restore
    if (-not $restored) {
        if ($script:unsafeCodeState) {
            Show-State "red" "End HITMAN in Task Manager" $script:fatal
        } else {
            Show-State "amber" "Close HITMAN or retry" $script:fatal }
        return }
    Detach
    $script:stopped=$true; $script:fatal=""
    $btnStop.Enabled=$false
    Show-State "grey" "Turned off" "Everything owned by v1.5 was restored. Close and reopen this tool to use the fix again." })

$form.Add_FormClosing({ param($sender,$eventArgs)
    if ($script:unsafeCodeState -and (Game-IsAlive)) {
        $eventArgs.Cancel=$true
        Show-State "red" "End HITMAN in Task Manager" "The failed rollback remains deliberately suspended. Force-close the HITMAN process; do not resume it." $MODE_INFO.Warning
        Log "window close deferred while an unsafe rollback state remains suspended"
        return }
    $timer.Stop()
    if ((Game-IsAlive) -and (Changes-MayBeLive) -and -not (Restore)) {
        $eventArgs.Cancel=$true
        $timer.Start()
        if ($script:unsafeCodeState) {
            Show-State "red" "End HITMAN in Task Manager" $script:fatal
        } else {
            Show-State "amber" "Close HITMAN or retry" $script:fatal }
        Log "window close deferred because live restoration was incomplete"
        return }
    Detach
    if ($script:handle -ne [IntPtr]::Zero) { [HmFix]::CloseHandle($script:handle) | Out-Null }
    if ($script:mutexOwned) {
        try { $script:instanceMutex.ReleaseMutex() } catch {}
        $script:mutexOwned=$false }
    try { $script:instanceMutex.Dispose() } catch {}
    Log "closed" })

[void]$form.ShowDialog()
