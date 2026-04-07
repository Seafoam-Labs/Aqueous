using System;
using System.Collections.Generic;
using System.Threading.Tasks;
using Tmds.DBus;

namespace Aqueous.Features.SystemTray
{
    [DBusInterface("org.kde.StatusNotifierItem")]
    public interface IStatusNotifierItem : IDBusObject
    {
        Task ActivateAsync(int x, int y);
        Task SecondaryActivateAsync(int x, int y);
        Task ScrollAsync(int delta, string orientation);
        Task ContextMenuAsync(int x, int y);
        Task<T> GetAsync<T>(string prop);
        Task<IDictionary<string, object>> GetAllAsync();
        Task<IDisposable> WatchNewIconAsync(Action handler, Action<Exception>? onError = null);
        Task<IDisposable> WatchNewTitleAsync(Action handler, Action<Exception>? onError = null);
        Task<IDisposable> WatchNewStatusAsync(Action<string> handler, Action<Exception>? onError = null);
        Task<IDisposable> WatchNewToolTipAsync(Action handler, Action<Exception>? onError = null);
    }
}
