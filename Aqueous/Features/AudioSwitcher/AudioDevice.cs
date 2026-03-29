namespace Aqueous.Features.AudioSwitcher
{
    public enum AudioDeviceType { Sink, Source }

    public record AudioDevice(
        int Id,
        string Name,
        string Description,
        bool IsDefault,
        AudioDeviceType Type,
        int Volume
    );
}
