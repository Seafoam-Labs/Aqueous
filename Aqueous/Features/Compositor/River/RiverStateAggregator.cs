using System;
using System.Collections.Generic;
using System.Collections.Immutable;
using System.Linq;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using Aqueous.Bindings.AstalRiver;
using Aqueous.Bindings.AstalRiver.Services;

namespace Aqueous.Features.Compositor.River
{
    /// <summary>
    /// Immutable snapshot of the pieces of River state Aqueous cares about.
    /// </summary>
    internal sealed record RiverSnapshot(
        ImmutableArray<CompositorOutput> Outputs,
        string? FocusedOutputName,
        string? FocusedViewTitle,
        string? Mode)
    {
        public static readonly RiverSnapshot Empty =
            new(ImmutableArray<CompositorOutput>.Empty, null, null, null);

        public CompositorOutput? FocusedOutput
        {
            get
            {
                if (FocusedOutputName is null) return null;
                foreach (var o in Outputs)
                    if (o.Name == FocusedOutputName) return o;
                return null;
            }
        }
    }

    /// <summary>
    /// Owns the <see cref="AstalRiverRiver"/> handle and translates its GObject
    /// <c>notify::*</c> signals into a single, diffed <see cref="RiverSnapshot"/>
    /// stream. Consumers subscribe to <see cref="Changed"/> and compare old/new.
    ///
    /// Threading: GLib signals dispatch on the GLib main thread, which is the
    /// GTK thread — so <see cref="Changed"/> is invoked on the UI thread and
    /// widget handlers need no extra marshaling. A lightweight <c>_gate</c>
    /// guards <see cref="Current"/> for the rare cross-thread read.
    /// </summary>
    internal sealed class RiverStateAggregator : IDisposable
    {
        private readonly AstalRiverRiver _river;
        private readonly object _gate = new();
        private RiverSnapshot _snapshot = RiverSnapshot.Empty;
        private bool _started;
        private bool _disposed;

        // Pins `this` so native callbacks can recover the managed aggregator.
        private GCHandle _selfHandle;

        // River-level signal handler ids.
        private ulong _sigFocusedOutput;
        private ulong _sigFocusedView;
        private ulong _sigMode;

        // Per-output subscriptions, keyed by native output pointer.
        private readonly Dictionary<IntPtr, OutputSubscription> _outputSubs = new();

        private sealed class OutputSubscription
        {
            public IntPtr NativePtr;
            public ulong FocusedTags;
            public ulong OccupiedTags;
            public ulong UrgentTags;
            public ulong Layout;
            public ulong Focused;
        }

        public event Action<RiverSnapshot, RiverSnapshot>? Changed;

        public RiverStateAggregator(AstalRiverRiver river)
        {
            _river = river;
        }

        public RiverSnapshot Current
        {
            get { lock (_gate) return _snapshot; }
        }

        public void Start()
        {
            if (_started || _disposed) return;
            _started = true;

            _selfHandle = GCHandle.Alloc(this, GCHandleType.Normal);
            var userData = GCHandle.ToIntPtr(_selfHandle);

            unsafe
            {
                delegate* unmanaged[Cdecl]<IntPtr, IntPtr, IntPtr, void> riverCb = &OnRiverNotify;
                var riverCbPtr = (IntPtr)riverCb;

                _sigFocusedOutput = _river.ConnectNotify("focused-output", riverCbPtr, userData);
                _sigFocusedView   = _river.ConnectNotify("focused-view",   riverCbPtr, userData);
                _sigMode          = _river.ConnectNotify("mode",           riverCbPtr, userData);
            }

            // Seed the snapshot + per-output subscriptions.
            RebuildSnapshot(raiseChanged: false);
            RebuildOutputSubscriptions();
        }

        [UnmanagedCallersOnly(CallConvs = new[] { typeof(CallConvCdecl) })]
        private static void OnRiverNotify(IntPtr gobject, IntPtr pspec, IntPtr userData)
        {
            if (userData == IntPtr.Zero) return;
            var handle = GCHandle.FromIntPtr(userData);
            if (handle.Target is RiverStateAggregator self)
                self.OnRiverPropertyChanged();
        }

        [UnmanagedCallersOnly(CallConvs = new[] { typeof(CallConvCdecl) })]
        private static void OnOutputNotify(IntPtr gobject, IntPtr pspec, IntPtr userData)
        {
            if (userData == IntPtr.Zero) return;
            var handle = GCHandle.FromIntPtr(userData);
            if (handle.Target is RiverStateAggregator self)
                self.OnOutputPropertyChanged();
        }

        private void OnRiverPropertyChanged()
        {
            // Focused-output change implies the output set may have shifted; re-wire.
            RebuildOutputSubscriptions();
            RebuildSnapshot(raiseChanged: true);
        }

        private void OnOutputPropertyChanged()
        {
            RebuildSnapshot(raiseChanged: true);
        }

        private void RebuildOutputSubscriptions()
        {
            if (_disposed) return;
            var userData = GCHandle.ToIntPtr(_selfHandle);

            // Gather current output handles.
            var currentPtrs = new HashSet<IntPtr>();
            foreach (var o in _river.Outputs)
                currentPtrs.Add(o.NativePtr);

            // Disconnect subs for outputs that no longer exist.
            var toRemove = new List<IntPtr>();
            foreach (var (ptr, sub) in _outputSubs)
            {
                if (!currentPtrs.Contains(ptr))
                {
                    DisconnectOutputSub(ptr, sub);
                    toRemove.Add(ptr);
                }
            }
            foreach (var ptr in toRemove) _outputSubs.Remove(ptr);

            // Connect subs for newly-seen outputs.
            unsafe
            {
                delegate* unmanaged[Cdecl]<IntPtr, IntPtr, IntPtr, void> cb = &OnOutputNotify;
                var cbPtr = (IntPtr)cb;

                foreach (var o in _river.Outputs)
                {
                    if (_outputSubs.ContainsKey(o.NativePtr)) continue;
                    var sub = new OutputSubscription { NativePtr = o.NativePtr };
                    sub.FocusedTags  = o.ConnectNotify("focused-tags",  cbPtr, userData);
                    sub.OccupiedTags = o.ConnectNotify("occupied-tags", cbPtr, userData);
                    sub.UrgentTags   = o.ConnectNotify("urgent-tags",   cbPtr, userData);
                    sub.Layout       = o.ConnectNotify("layout",        cbPtr, userData);
                    sub.Focused      = o.ConnectNotify("focused",       cbPtr, userData);
                    _outputSubs[o.NativePtr] = sub;
                }
            }
        }

        private static void DisconnectOutputSub(IntPtr outputPtr, OutputSubscription sub)
        {
            // Output may already be gone native-side; be defensive.
            try { AstalRiverInterop.g_signal_handler_disconnect(outputPtr, sub.FocusedTags);  } catch { }
            try { AstalRiverInterop.g_signal_handler_disconnect(outputPtr, sub.OccupiedTags); } catch { }
            try { AstalRiverInterop.g_signal_handler_disconnect(outputPtr, sub.UrgentTags);   } catch { }
            try { AstalRiverInterop.g_signal_handler_disconnect(outputPtr, sub.Layout);       } catch { }
            try { AstalRiverInterop.g_signal_handler_disconnect(outputPtr, sub.Focused);      } catch { }
        }

        private void RebuildSnapshot(bool raiseChanged)
        {
            RiverSnapshot old;
            RiverSnapshot @new;

            try
            {
                var outputs = ImmutableArray.CreateBuilder<CompositorOutput>();
                foreach (var o in _river.Outputs)
                {
                    outputs.Add(new CompositorOutput(
                        Name: o.Name ?? string.Empty,
                        Focused: o.Focused,
                        FocusedTags: o.FocusedTags,
                        OccupiedTags: o.OccupiedTags,
                        UrgentTags: o.UrgentTags,
                        Layout: o.Layout));
                }

                string? focusedOutputName = null;
                foreach (var o in outputs)
                    if (o.Focused) { focusedOutputName = o.Name; break; }

                @new = new RiverSnapshot(
                    outputs.ToImmutable(),
                    focusedOutputName,
                    _river.FocusedView,
                    _river.Mode);
            }
            catch
            {
                // Native read failed (e.g. compositor disappeared); keep current snapshot.
                return;
            }

            lock (_gate)
            {
                old = _snapshot;
                _snapshot = @new;
            }

            if (raiseChanged && !_disposed)
            {
                try { Changed?.Invoke(old, @new); }
                catch
                {
                    // Downstream handlers must never kill the signal dispatcher.
                }
            }
        }

        public void Dispose()
        {
            if (_disposed) return;
            _disposed = true;

            // Disconnect river-level signals first.
            try { _river.Disconnect(_sigFocusedOutput); } catch { }
            try { _river.Disconnect(_sigFocusedView);   } catch { }
            try { _river.Disconnect(_sigMode);          } catch { }

            // Then per-output signals.
            foreach (var (ptr, sub) in _outputSubs)
                DisconnectOutputSub(ptr, sub);
            _outputSubs.Clear();

            // Finally free the GCHandle — any lingering native callbacks after
            // this point will see a zeroed target and return early.
            if (_selfHandle.IsAllocated) _selfHandle.Free();
        }
    }
}
