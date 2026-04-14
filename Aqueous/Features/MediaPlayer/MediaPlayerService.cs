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

        // prevent GC of delegates
        private NotifyCallback? _cavaValuesCallback;
        private PlayerChangedCallback? _playerAddedCallback;
        private PlayerChangedCallback? _playerRemovedCallback;

        private uint _pollTimer;

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
            _window.Show();

            // Setup MPRIS
            _mpris = astal_mpris_mpris_get_default();
            if (_mpris != IntPtr.Zero)
            {
                _playerAddedCallback = OnPlayerAdded;
                _playerRemovedCallback = OnPlayerRemoved;

                var id1 = ConnectSignal(_mpris, "player-added", _playerAddedCallback);
                _allSignals.Add((_mpris, id1));
                var id2 = ConnectSignal(_mpris, "player-removed", _playerRemovedCallback);
                _allSignals.Add((_mpris, id2));

                SelectActivePlayer();
            }

            // Setup Cava
            _cava = astal_cava_cava_get_default();
            if (_cava != IntPtr.Zero)
            {
                astal_cava_cava_set_bars(_cava, 20);
                astal_cava_cava_set_active(_cava, 1);

                _cavaValuesCallback = OnCavaValuesChanged;
                var id = ConnectSignal(_cava, "notify::values", _cavaValuesCallback);
                _allSignals.Add((_cava, id));
            }

            // Poll player state periodically
            _pollTimer = GLib.Functions.TimeoutAdd(0, 1000, () =>
            {
                UpdatePlayerInfo();
                return true;
            });
        }

        public void Stop()
        {
            if (_pollTimer != 0)
            {
                GLib.Functions.SourceRemove(_pollTimer);
                _pollTimer = 0;
            }

            foreach (var (instance, id) in _allSignals)
            {
                if (id > 0)
                    g_signal_handler_disconnect(instance, id);
            }
            _allSignals.Clear();

            _window?.Hide();
            _window = null;
        }

        private void OnPlayerAdded(IntPtr self, IntPtr player, IntPtr userData)
        {
            SelectActivePlayer();
        }

        private void OnPlayerRemoved(IntPtr self, IntPtr player, IntPtr userData)
        {
            SelectActivePlayer();
        }

        private void OnCavaValuesChanged(IntPtr self, IntPtr pspec, IntPtr userData)
        {
            if (_cava == IntPtr.Zero || _window == null) return;

            var garray = astal_cava_cava_get_values(_cava);
            if (garray == IntPtr.Zero) return;

            // GArray struct: { gchar *data; guint len; }
            var dataPtr = Marshal.ReadIntPtr(garray, 0);
            var len = (uint)Marshal.ReadInt32(garray, IntPtr.Size);

            if (dataPtr == IntPtr.Zero || len == 0) return;

            var values = new float[len];
            for (int i = 0; i < len; i++)
            {
                values[i] = (float)BitConverter.Int64BitsToDouble(
                    Marshal.ReadInt64(dataPtr + i * sizeof(double)));
            }

            _window.UpdateCavaValues(values);
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
        }

        private void UpdatePlayerInfo()
        {
            if (_window == null) return;

            if (_activePlayer != IntPtr.Zero)
            {
                var titlePtr = astal_mpris_player_get_title(_activePlayer);
                var artistPtr = astal_mpris_player_get_artist(_activePlayer);
                var title = titlePtr != IntPtr.Zero ? Marshal.PtrToStringAnsi(titlePtr) : null;
                var artist = artistPtr != IntPtr.Zero ? Marshal.PtrToStringAnsi(artistPtr) : null;
                var status = (AstalMprisPlaybackStatus)astal_mpris_player_get_playback_status(_activePlayer);

                _window.UpdateTrackInfo(title, artist);
                _window.UpdatePlaybackStatus(status == AstalMprisPlaybackStatus.Playing);
            }
            else
            {
                _window.UpdateTrackInfo(null, null);
                _window.UpdatePlaybackStatus(false);
            }
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
