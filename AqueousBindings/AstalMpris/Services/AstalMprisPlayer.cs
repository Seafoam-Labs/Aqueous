using System;
using System.Runtime.InteropServices;
using Aqueous.Bindings.AstalMpris;
namespace Aqueous.Bindings.AstalMpris.Services
{
    public unsafe class AstalMprisPlayer
    {
        private _AstalMprisPlayer* _handle;
        internal _AstalMprisPlayer* Handle => _handle;
        internal AstalMprisPlayer(_AstalMprisPlayer* handle)
        {
            _handle = handle;
        }
        public AstalMprisPlayer(string name)
        {
            var ptr = (sbyte*)Marshal.StringToHGlobalAnsi(name);
            try
            {
                _handle = AstalMprisInterop.astal_mpris_player_new(ptr);
            }
            finally
            {
                Marshal.FreeHGlobal((IntPtr)ptr);
            }
        }
        public void Raise() => AstalMprisInterop.astal_mpris_player_raise(_handle);
        public void Quit() => AstalMprisInterop.astal_mpris_player_quit(_handle);
        public void ToggleFullscreen() => AstalMprisInterop.astal_mpris_player_toggle_fullscreen(_handle);
        public void Next() => AstalMprisInterop.astal_mpris_player_next(_handle);
        public void Previous() => AstalMprisInterop.astal_mpris_player_previous(_handle);
        public void Pause() => AstalMprisInterop.astal_mpris_player_pause(_handle);
        public void PlayPause() => AstalMprisInterop.astal_mpris_player_play_pause(_handle);
        public void Stop() => AstalMprisInterop.astal_mpris_player_stop(_handle);
        public void Play() => AstalMprisInterop.astal_mpris_player_play(_handle);
        public void Loop() => AstalMprisInterop.astal_mpris_player_loop(_handle);
        public void Shuffle() => AstalMprisInterop.astal_mpris_player_shuffle(_handle);
        public void OpenUri(string uri)
        {
            var ptr = (sbyte*)Marshal.StringToHGlobalAnsi(uri);
            try
            {
                AstalMprisInterop.astal_mpris_player_open_uri(_handle, ptr);
            }
            finally
            {
                Marshal.FreeHGlobal((IntPtr)ptr);
            }
        }
        public string? BusName => Marshal.PtrToStringAnsi((IntPtr)AstalMprisInterop.astal_mpris_player_get_bus_name(_handle));
        public bool Available => AstalMprisInterop.astal_mpris_player_get_available(_handle) != 0;
        public bool CanQuit => AstalMprisInterop.astal_mpris_player_get_can_quit(_handle) != 0;
        public bool Fullscreen => AstalMprisInterop.astal_mpris_player_get_fullscreen(_handle) != 0;
        public bool CanSetFullscreen => AstalMprisInterop.astal_mpris_player_get_can_set_fullscreen(_handle) != 0;
        public bool CanRaise => AstalMprisInterop.astal_mpris_player_get_can_raise(_handle) != 0;
        public string? Identity => Marshal.PtrToStringAnsi((IntPtr)AstalMprisInterop.astal_mpris_player_get_identity(_handle));
        public string? Entry => Marshal.PtrToStringAnsi((IntPtr)AstalMprisInterop.astal_mpris_player_get_entry(_handle));
        public AstalMprisLoop LoopStatus
        {
            get => (AstalMprisLoop)AstalMprisInterop.astal_mpris_player_get_loop_status(_handle);
            set => AstalMprisInterop.astal_mpris_player_set_loop_status(_handle, (int)value);
        }
        public AstalMprisShuffle ShuffleStatus
        {
            get => (AstalMprisShuffle)AstalMprisInterop.astal_mpris_player_get_shuffle_status(_handle);
            set => AstalMprisInterop.astal_mpris_player_set_shuffle_status(_handle, (int)value);
        }
        public double Rate
        {
            get => AstalMprisInterop.astal_mpris_player_get_rate(_handle);
            set => AstalMprisInterop.astal_mpris_player_set_rate(_handle, value);
        }
        public double Volume
        {
            get => AstalMprisInterop.astal_mpris_player_get_volume(_handle);
            set => AstalMprisInterop.astal_mpris_player_set_volume(_handle, value);
        }
        public double Position
        {
            get => AstalMprisInterop.astal_mpris_player_get_position(_handle);
            set => AstalMprisInterop.astal_mpris_player_set_position(_handle, value);
        }
        public AstalMprisPlaybackStatus PlaybackStatus => (AstalMprisPlaybackStatus)AstalMprisInterop.astal_mpris_player_get_playback_status(_handle);
        public double MinimumRate => AstalMprisInterop.astal_mpris_player_get_minimum_rate(_handle);
        public double MaximumRate => AstalMprisInterop.astal_mpris_player_get_maximum_rate(_handle);
        public bool CanGoNext => AstalMprisInterop.astal_mpris_player_get_can_go_next(_handle) != 0;
        public bool CanGoPrevious => AstalMprisInterop.astal_mpris_player_get_can_go_previous(_handle) != 0;
        public bool CanPlay => AstalMprisInterop.astal_mpris_player_get_can_play(_handle) != 0;
        public bool CanPause => AstalMprisInterop.astal_mpris_player_get_can_pause(_handle) != 0;
        public bool CanSeek => AstalMprisInterop.astal_mpris_player_get_can_seek(_handle) != 0;
        public bool CanControl => AstalMprisInterop.astal_mpris_player_get_can_control(_handle) != 0;
        public string? Trackid => Marshal.PtrToStringAnsi((IntPtr)AstalMprisInterop.astal_mpris_player_get_trackid(_handle));
        public double Length => AstalMprisInterop.astal_mpris_player_get_length(_handle);
        public string? ArtUrl => Marshal.PtrToStringAnsi((IntPtr)AstalMprisInterop.astal_mpris_player_get_art_url(_handle));
        public string? Album => Marshal.PtrToStringAnsi((IntPtr)AstalMprisInterop.astal_mpris_player_get_album(_handle));
        public string? AlbumArtist => Marshal.PtrToStringAnsi((IntPtr)AstalMprisInterop.astal_mpris_player_get_album_artist(_handle));
        public string? Artist => Marshal.PtrToStringAnsi((IntPtr)AstalMprisInterop.astal_mpris_player_get_artist(_handle));
        public string? Lyrics => Marshal.PtrToStringAnsi((IntPtr)AstalMprisInterop.astal_mpris_player_get_lyrics(_handle));
        public string? Title => Marshal.PtrToStringAnsi((IntPtr)AstalMprisInterop.astal_mpris_player_get_title(_handle));
        public string? Composer => Marshal.PtrToStringAnsi((IntPtr)AstalMprisInterop.astal_mpris_player_get_composer(_handle));
        public string? Comments => Marshal.PtrToStringAnsi((IntPtr)AstalMprisInterop.astal_mpris_player_get_comments(_handle));
        public string? CoverArt => Marshal.PtrToStringAnsi((IntPtr)AstalMprisInterop.astal_mpris_player_get_cover_art(_handle));
    }
}
