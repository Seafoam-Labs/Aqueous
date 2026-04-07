using System;
using System.Collections.Generic;
using System.Threading.Tasks;
using Tmds.DBus;

namespace Aqueous.Features.SystemTray
{
    [DBusInterface("org.kde.StatusNotifierWatcher")]
    public interface IStatusNotifierWatcher : IDBusObject
    {
        Task RegisterStatusNotifierItemAsync(string service);
        Task RegisterStatusNotifierHostAsync(string service);
        Task<T> GetAsync<T>(string prop);
        Task<IDictionary<string, object>> GetAllAsync();
        Task<IDisposable> WatchStatusNotifierItemRegisteredAsync(Action<string> handler, Action<Exception>? onError = null);
        Task<IDisposable> WatchStatusNotifierItemUnregisteredAsync(Action<string> handler, Action<Exception>? onError = null);
        Task<IDisposable> WatchStatusNotifierHostRegisteredAsync(Action handler, Action<Exception>? onError = null);
    }

    public class StatusNotifierWatcher : IStatusNotifierWatcher
    {
        private readonly List<string> _items = new();
        private bool _hostRegistered;

        public event Action<string>? ItemRegistered;
        public event Action<string>? ItemUnregistered;

        public IReadOnlyList<string> RegisteredItems => _items;
        public bool IsHostRegistered => _hostRegistered;

        public ObjectPath ObjectPath => new("/StatusNotifierWatcher");

        public Task RegisterStatusNotifierItemAsync(string service)
        {
            if (!_items.Contains(service))
            {
                _items.Add(service);
                ItemRegistered?.Invoke(service);
            }
            return Task.CompletedTask;
        }

        public Task RegisterStatusNotifierHostAsync(string service)
        {
            _hostRegistered = true;
            return Task.CompletedTask;
        }

        public Task<T> GetAsync<T>(string prop)
        {
            object result = prop switch
            {
                "RegisteredStatusNotifierItems" => _items.ToArray(),
                "IsStatusNotifierHostRegistered" => _hostRegistered,
                "ProtocolVersion" => 0,
                _ => throw new ArgumentException($"Unknown property: {prop}")
            };
            return Task.FromResult((T)result);
        }

        public Task<IDictionary<string, object>> GetAllAsync()
        {
            var dict = new Dictionary<string, object>
            {
                ["RegisteredStatusNotifierItems"] = _items.ToArray(),
                ["IsStatusNotifierHostRegistered"] = _hostRegistered,
                ["ProtocolVersion"] = 0
            };
            return Task.FromResult<IDictionary<string, object>>(dict);
        }

        public Task<IDisposable> WatchStatusNotifierItemRegisteredAsync(Action<string> handler, Action<Exception>? onError = null)
        {
            ItemRegistered += handler;
            return Task.FromResult<IDisposable>(new SignalDisposable(() => ItemRegistered -= handler));
        }

        public Task<IDisposable> WatchStatusNotifierItemUnregisteredAsync(Action<string> handler, Action<Exception>? onError = null)
        {
            ItemUnregistered += handler;
            return Task.FromResult<IDisposable>(new SignalDisposable(() => ItemUnregistered -= handler));
        }

        public Task<IDisposable> WatchStatusNotifierHostRegisteredAsync(Action handler, Action<Exception>? onError = null)
        {
            return Task.FromResult<IDisposable>(new SignalDisposable(() => { }));
        }

        public void RemoveItem(string service)
        {
            if (_items.Remove(service))
            {
                ItemUnregistered?.Invoke(service);
            }
        }

        private class SignalDisposable : IDisposable
        {
            private readonly Action _onDispose;
            public SignalDisposable(Action onDispose) => _onDispose = onDispose;
            public void Dispose() => _onDispose();
        }
    }
}
