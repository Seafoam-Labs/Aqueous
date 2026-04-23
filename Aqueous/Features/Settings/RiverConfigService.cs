using System;

namespace Aqueous.Features.Settings
{
    public class RiverConfigService
    {
        public static RiverConfigService Instance { get; } = new();

        public bool GetBool(string section, string key, bool defaultValue = false) => defaultValue;
        public void SetBool(string section, string key, bool value) { }

        public int GetInt(string section, string key, int defaultValue = 0) => defaultValue;
        public void SetInt(string section, string key, int value) { }

        public float GetFloat(string section, string key, float defaultValue = 0f) => defaultValue;
        public void SetFloat(string section, string key, float value) { }

        public string GetString(string section, string key, string defaultValue = "") => defaultValue;
        public void SetString(string section, string key, string value) { }

        public string GetColor(string section, string key, string defaultValue = "#000000FF") => defaultValue;
        public void SetColor(string section, string key, string value) { }

        public string GetKeybind(string section, string key, string defaultValue = "none") => defaultValue;
        public void SetKeybind(string section, string key, string value) { }

        public int GetDurationMs(string section, string key, int defaultMs = 300) => defaultMs;
        public void SetDurationMs(string section, string key, int ms, string? curve = null) { }

        public string GetDurationCurve(string section, string key, string defaultCurve = "linear") => defaultCurve;

        public void RemoveKey(string section, string key) { }
        public void Save() { }
        public void Load() { }
        public System.Collections.Generic.Dictionary<string, string> GetSectionKeys(string section) => new();
    }
}