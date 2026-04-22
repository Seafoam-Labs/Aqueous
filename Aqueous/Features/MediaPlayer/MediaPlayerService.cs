using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using Aqueous.Bindings.AstalGTK4.Services;
using Aqueous.Bindings.AstalMpris;

namespace Aqueous.Features.MediaPlayer
{
    public unsafe class MediaPlayerService
    {
        // GObject signal helpers
        [DllImport("libgobject-2.0.so.0")]
        private static extern ulong g_signal_connect_data(
            IntPtr instance, IntPtr detailed_signal, IntPtr c_handler,
            IntPtr data, IntPtr destroy_data, int connect_flags);

        [DllImport("libgobject-2.0.so.0")]
        private static extern void g_signal_handler_disconnect(IntPtr instance, ulong handler_id);

        // AstalMpris direct P/Invoke
        [DllImport("libastal-mpris.so")]
        private static extern IntPtr astal_mpris_mpris_get_default();

        [DllImport("libastal-mpris.so")]
        private static extern IntPtr astal_mpris_mpris_get_players(IntPtr self);

        [DllImport("libastal-mpris.so")]
        private static extern IntPtr astal_mpris_player_get_title(IntPtr self);

        [DllImport("libastal-mpris.so")]
        private static extern IntPtr astal_mpris_player_get_artist(IntPtr self);

        [DllImport("libastal-mpris.so")]
        private static extern int astal_mpris_player_get_playback_status(IntPtr self);

        [DllImport("libastal-mpris.so")]
        private static extern void astal_mpris_player_play_pause(IntPtr self);

        [DllImport("libastal-mpris.so")]
        private static extern void astal_mpris_player_next(IntPtr self);

        [DllImport("libastal-mpris.so")]
        private static extern void astal_mpris_player_previous(IntPtr self);

        // AstalCava direct P/Invoke
        [DllImport("libastal-cava.so")]
        private static extern IntPtr astal_cava_cava_get_default();

        [DllImport("libastal-cava.so")]
        private static extern void astal_cava_cava_set_bars(IntPtr self, int bars);

        [DllImport("libastal-cava.so")]
        private static extern void astal_cava_cava_set_active(IntPtr self, int active);

        [DllImport("libastal-cava.so")]
        private static extern IntPtr astal_cava_cava_get_values(IntPtr self);

        [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
        private delegate void NotifyCallback(IntPtr self, IntPtr pspec, IntPtr userData);

        [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
        private delegate void PlayerChangedCallback(IntPtr self, IntPtr player, IntPtr userData);

        private readonly AstalApplication _app;
        private MediaPlayerWindow? _window;
        private IntPtr _mpris;
        private IntPtr _activePlayer;
        private IntPtr _cava;

        private readonly List<(IntPtr instance, ulong id)> _allSignals = new();

        // Track the Cava notify::values handler separately so we can
        // disconnect/reconnect as the panel expands/collapses (Phase A).
        private ulong _cavaValuesHandlerId;
        private bool _cavaActive;

        // Per-player notify signal bookkeeping (Phase C).
        private readonly Dictionary<IntPtr, List<ulong>> _playerSignals = new();
        private NotifyCallback? _playerNotifyCallback;

        // Players that have emitted at least one notify::position — for them the 1 s position
        // fallback is unnecessary (the server pushes position changes natively). Populated on
        // first observed notify::position; drained when the player disappears.
        private readonly HashSet<IntPtr> _emitsPositionSignal = new();

        // Redundant-update guards — avoid per-emit string allocations + QueueDraw when nothing
        // actually changed. Signal firehoses (notify::metadata/title/artist) otherwise cause
        // per-emit allocation storms that land at random offsets vs. the compositor frame and
        // show up as external-app typing jitter.
        private string? _lastTitle;
        private string? _lastArtist;
        private bool _lastPlaying;
        private bool _hasLastState;

        // prevent GC of delegates
        private NotifyCallback? _cavaValuesCallback;
        private PlayerChangedCallback? _playerAddedCallback;
        private PlayerChangedCallback? _playerRemovedCallback;

        // Conditional fallback: only ticks while an active player is Playing and we haven't
        // seen a native notify::position signal from it. Replaces the old unconditional 1 Hz poll.
        private uint _pollTimer;

        // Reusable Cava buffers — avoid per-frame allocation at visualizer rate (20-60 Hz).
        private double[] _cavaBuf = Array.Empty<double>();
        private float[] _cavaOut = Array.Empty<float>();
        private long _cavaLastTickTicks;
        private const long CavaMinIntervalTicks = TimeSpan.TicksPerMillisecond * 16; // ~60 Hz cap

        public MediaPlayerService(AstalApplication app)
        {
            _app = app;
        }

        public void Start()
        {
            _window = new MediaPlayerWindow(_app);
            _window.OnPrevious += () => { if (_activePlayer != IntPtr.Zero) astal_mpris_player_previous(_activePlayer); };
            _window.OnPlayPause += () => { if (_activePlayer != IntPtr.Zero) astal_mpris_player_play_pause(_activePlayer); };
            _window.OnNext += () => { if (_activePlayer != IntPtr.Zero) astal_mpris_player_next(_activePlayer); };
            // The window calls us back when it expands/collapses so we can silence Cava
            // at the library level while the visualizer is off-screen (Phase A).
            _window.OnPanelVisibilityChanged += SetCavaActive;
            _window.Show();

            // Setup MPRIS
            _mpris = astal_mpris_mpris_get_default();
            if (_mpris != IntPtr.Zero)
            {
                _playerAddedCallback = OnPlayerAdded;
                _playerRemovedCallback = OnPlayerRemoved;
                _playerNotifyCallback = OnPlayerPropertyChanged;

                var id1 = ConnectSignal(_mpris, "player-added", _playerAddedCallback);
                _allSignals.Add((_mpris, id1));
                var id2 = ConnectSignal(_mpris, "player-removed", _playerRemovedCallback);
                _allSignals.Add((_mpris, id2));

                // Attach to every pre-existing player on startup.
                AttachAllExistingPlayers();
                SelectActivePlayer();
            }

            // Setup Cava — start inactive; MediaPlayerWindow.OnPanelVisibilityChanged(true)
            // will turn it on only when the expanded panel is on-screen.
            _cava = astal_cava_cava_get_default();
            if (_cava != IntPtr.Zero)
            {
                astal_cava_cava_set_bars(_cava, 20);
                astal_cava_cava_set_active(_cava, 0);
                _cavaActive = false;
                _cavaValuesCallback = OnCavaValuesChanged;
                // Handler is connected lazily by SetCavaActive(true).
            }

            // No unconditional poll. The conditional fallback in UpdatePositionFallback()
            // only arms while an active player is Playing (Phase C).
        }

        public void Stop()
        {
            StopPositionFallback();

            // Silence Cava and drop its notify::values handler.
            SetCavaActive(false);

            // Detach all per-player signals.
            foreach (var kv in _playerSignals)
                foreach (var id in kv.Value)
                    if (id > 0) g_signal_handler_disconnect(kv.Key, id);
            _playerSignals.Clear();

            foreach (var (instance, id) in _allSignals)
            {
                if (id > 0)
                    g_signal_handler_disconnect(instance, id);
            }
            _allSignals.Clear();

            _window?.Hide();
            _window = null;
        }

        /// <summary>
        /// Turn Cava emission on/off and connect/disconnect the notify::values handler.
        /// Called by MediaPlayerWindow as the panel expands/collapses so that while the
        /// visualizer isn't visible we don't spin the main loop at 20-60 Hz.
        /// </summary>
        public void SetCavaActive(bool active)
        {
            if (_cava == IntPtr.Zero) return;
            if (active == _cavaActive) return;
            _cavaActive = active;

            if (active)
            {
                if (_cavaValuesHandlerId == 0 && _cavaValuesCallback != null)
                    _cavaValuesHandlerId = ConnectSignal(_cava, "notify::values", _cavaValuesCallback);
                astal_cava_cava_set_active(_cava, 1);
            }
            else
            {
                astal_cava_cava_set_active(_cava, 0);
                if (_cavaValuesHandlerId != 0)
                {
                    g_signal_handler_disconnect(_cava, _cavaValuesHandlerId);
                    _cavaValuesHandlerId = 0;
                }
            }
        }

        private void OnPlayerAdded(IntPtr self, IntPtr player, IntPtr userData)
        {
            AttachPlayer(player);
            SelectActivePlayer();
        }

        private void OnPlayerRemoved(IntPtr self, IntPtr player, IntPtr userData)
        {
            DetachPlayer(player);
            SelectActivePlayer();
        }

        private void AttachAllExistingPlayers()
        {
            var listPtr = astal_mpris_mpris_get_players(_mpris);
            var cur = listPtr;
            while (cur != IntPtr.Zero)
            {
                var data = Marshal.ReadIntPtr(cur, 0);
                if (data != IntPtr.Zero) AttachPlayer(data);
                cur = Marshal.ReadIntPtr(cur, IntPtr.Size);
            }
        }

        private void AttachPlayer(IntPtr player)
        {
            if (player == IntPtr.Zero || _playerNotifyCallback == null) return;
            if (_playerSignals.ContainsKey(player)) return;

            var ids = new List<ulong>
            {
                ConnectSignal(player, "notify::playback-status", _playerNotifyCallback),
                ConnectSignal(player, "notify::metadata",        _playerNotifyCallback),
                ConnectSignal(player, "notify::title",           _playerNotifyCallback),
                ConnectSignal(player, "notify::artist",          _playerNotifyCallback),
                // Subscribe to notify::position so we can mark the player as self-reporting
                // the first time it pushes a position update — at which point we disarm the
                // 1 Hz fallback for that player (Plan C.2 EmitsPositionSignal opt-out).
                ConnectSignal(player, "notify::position",        _playerNotifyCallback),
            };
            _playerSignals[player] = ids;
        }

        private void DetachPlayer(IntPtr player)
        {
            if (!_playerSignals.TryGetValue(player, out var ids)) return;
            foreach (var id in ids)
                if (id > 0) g_signal_handler_disconnect(player, id);
            _playerSignals.Remove(player);
            _emitsPositionSignal.Remove(player);
        }

        private void OnPlayerPropertyChanged(IntPtr self, IntPtr pspec, IntPtr userData)
        {
            // Best-effort read of the property name so we can detect notify::position and mark
            // this player as self-reporting (opt-out of the 1 Hz fallback). pspec layout is a
            // GParamSpec — its name is at a fixed offset (4 * sizeof(pointer)) in GLib >= 2.26.
            if (pspec != IntPtr.Zero)
            {
                try
                {
                    var namePtr = Marshal.ReadIntPtr(pspec, 4 * IntPtr.Size);
                    var name = namePtr != IntPtr.Zero ? Marshal.PtrToStringAnsi(namePtr) : null;
                    if (name == "position")
                    {
                        _emitsPositionSignal.Add(self);
                        if (self == _activePlayer) UpdatePositionFallback();
                        return; // position-only update, no metadata refresh needed
                    }
                }
                catch { /* best-effort — fall through to normal handling */ }
            }

            // If our active player's status changed, re-evaluate (may need to switch actives
            // and re-arm / stop the position fallback).
            if (self == _activePlayer)
            {
                UpdatePlayerInfo();
                UpdatePositionFallback();
            }
            else
            {
                // Another player started playing — promote it.
                var status = (AstalMprisPlaybackStatus)astal_mpris_player_get_playback_status(self);
                if (status == AstalMprisPlaybackStatus.Playing)
                    SelectActivePlayer();
            }
        }

        private void UpdatePositionFallback()
        {
            bool needsFallback = _activePlayer != IntPtr.Zero &&
                !_emitsPositionSignal.Contains(_activePlayer) &&
                (AstalMprisPlaybackStatus)astal_mpris_player_get_playback_status(_activePlayer)
                    == AstalMprisPlaybackStatus.Playing;

            if (needsFallback && _pollTimer == 0)
            {
                _pollTimer = GLib.Functions.TimeoutAdd(0, 1000, () =>
                {
                    UpdatePlayerInfo();
                    return true;
                });
            }
            else if (!needsFallback && _pollTimer != 0)
            {
                StopPositionFallback();
            }
        }

        private void StopPositionFallback()
        {
            if (_pollTimer != 0)
            {
                GLib.Functions.SourceRemove(_pollTimer);
                _pollTimer = 0;
            }
        }

        private void OnCavaValuesChanged(IntPtr self, IntPtr pspec, IntPtr userData)
        {
            if (_cava == IntPtr.Zero || _window == null) return;

            // Skip all work while the player panel is collapsed — no one will see the bars,
            // and requesting frames from a hidden surface still puts Aqueous on the compositor's
            // critical path, which is the system-wide typing lag signature we're fixing.
            if (!_window.IsPanelVisible) return;

            // Gate on playback state — Cava keeps emitting even when nothing is playing,
            // which would otherwise cause a continuous redraw + allocation storm.
            if (_activePlayer == IntPtr.Zero) return;
            var status = (AstalMprisPlaybackStatus)astal_mpris_player_get_playback_status(_activePlayer);
            if (status != AstalMprisPlaybackStatus.Playing) return;

            // Throttle to ~60 Hz so the compositor never redraws faster than display rate.
            var nowTicks = DateTime.UtcNow.Ticks;
            if (nowTicks - _cavaLastTickTicks < CavaMinIntervalTicks) return;
            _cavaLastTickTicks = nowTicks;

            var garray = astal_cava_cava_get_values(_cava);
            if (garray == IntPtr.Zero) return;

            // GArray struct: { gchar *data; guint len; }
            var dataPtr = Marshal.ReadIntPtr(garray, 0);
            var len = (uint)Marshal.ReadInt32(garray, IntPtr.Size);

            if (dataPtr == IntPtr.Zero || len == 0) return;

            var n = (int)len;
            if (_cavaBuf.Length < n) _cavaBuf = new double[n];
            if (_cavaOut.Length < n) _cavaOut = new float[n];

            // Single bulk copy instead of per-element Marshal.ReadInt64 + Int64BitsToDouble.
            Marshal.Copy(dataPtr, _cavaBuf, 0, n);
            for (int i = 0; i < n; i++)
                _cavaOut[i] = (float)_cavaBuf[i];

            // If the consumer retains the array, we still hand out a correctly-sized view;
            // UpdateCavaValues copies for rendering so sharing the pooled buffer is safe here.
            if (_cavaOut.Length == n)
                _window.UpdateCavaValues(_cavaOut);
            else
            {
                var slice = new float[n];
                Array.Copy(_cavaOut, slice, n);
                _window.UpdateCavaValues(slice);
            }
        }

        private void SelectActivePlayer()
        {
            // Walk GList to find a playing player, or fall back to first
            IntPtr firstPlayer = IntPtr.Zero;
            IntPtr playingPlayer = IntPtr.Zero;

            var playersPtr = astal_mpris_mpris_get_players(_mpris);
            var current = playersPtr;
            while (current != IntPtr.Zero)
            {
                var data = Marshal.ReadIntPtr(current, 0);
                if (data != IntPtr.Zero)
                {
                    if (firstPlayer == IntPtr.Zero)
                        firstPlayer = data;
                    var status = (AstalMprisPlaybackStatus)astal_mpris_player_get_playback_status(data);
                    if (status == AstalMprisPlaybackStatus.Playing)
                    {
                        playingPlayer = data;
                        break;
                    }
                }
                current = Marshal.ReadIntPtr(current, IntPtr.Size);
            }

            _activePlayer = playingPlayer != IntPtr.Zero ? playingPlayer : firstPlayer;
            UpdatePlayerInfo();
            UpdatePositionFallback();
        }

        private void UpdatePlayerInfo()
        {
            if (_window == null) return;

            string? title;
            string? artist;
            bool playing;

            if (_activePlayer != IntPtr.Zero)
            {
                var titlePtr = astal_mpris_player_get_title(_activePlayer);
                var artistPtr = astal_mpris_player_get_artist(_activePlayer);
                title = titlePtr != IntPtr.Zero ? Marshal.PtrToStringAnsi(titlePtr) : null;
                artist = artistPtr != IntPtr.Zero ? Marshal.PtrToStringAnsi(artistPtr) : null;
                playing = (AstalMprisPlaybackStatus)astal_mpris_player_get_playback_status(_activePlayer)
                          == AstalMprisPlaybackStatus.Playing;
            }
            else
            {
                title = null;
                artist = null;
                playing = false;
            }

            // Redundant-update guard: MPRIS notify::metadata + notify::title + notify::artist
            // often fire in rapid succession with the same values. Skip the GTK SetLabel calls
            // (which allocate + QueueDraw) when nothing changed.
            if (_hasLastState && title == _lastTitle && artist == _lastArtist && playing == _lastPlaying)
                return;

            _lastTitle = title;
            _lastArtist = artist;
            _lastPlaying = playing;
            _hasLastState = true;

            _window.UpdateTrackInfo(title, artist);
            _window.UpdatePlaybackStatus(playing);
        }

        private static ulong ConnectSignal<TDelegate>(IntPtr instance, string signalName, TDelegate callback) where TDelegate : Delegate
        {
            var namePtr = Marshal.StringToHGlobalAnsi(signalName);
            try
            {
                return g_signal_connect_data(
                    instance, namePtr,
                    Marshal.GetFunctionPointerForDelegate(callback),
                    IntPtr.Zero, IntPtr.Zero, 0);
            }
            finally
            {
                Marshal.FreeHGlobal(namePtr);
            }
        }
    }
}
