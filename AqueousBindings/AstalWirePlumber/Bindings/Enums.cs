namespace Aqueous.Bindings.AstalWirePlumber
{
    public enum AstalWpScale
    {
        Linear,
        Cubic
    }

    public enum AstalWpDeviceType
    {
        Unknown,
        Audio,
        Video
    }

    public enum AstalWpAvailable
    {
        Unknown,
        No,
        Yes
    }

    public enum AstalWpMediaClass
    {
        Unknown,
        AudioMicrophone,
        AudioSpeaker,
        AudioRecorder,
        AudioStream,
        VideoSource,
        VideoSink,
        VideoRecorder,
        VideoStream,
        AudioSourceVirtual
    }

    public enum AstalWpNodeState
    {
        Error = -1,
        Creating = 0,
        Suspended = 1,
        Idle = 2,
        Running = 3
    }

    public enum AstalWpMediaCategory
    {
        Unknown,
        Playback,
        Capture,
        Duplex,
        Monitor,
        Manager
    }

    public enum AstalWpMediaRole
    {
        Unknown,
        Movie,
        Music,
        Camera,
        Screen,
        Communication,
        Game,
        Notification,
        Dsp,
        Production,
        Accessibility,
        Test
    }

    public enum AstalWpDirection
    {
        Input,
        Output
    }
}
