using System;

namespace Aqueous.Features.Compositor
{
    /// <summary>
    /// Process-wide service locator for the active <see cref="ICompositorBackend"/>.
    ///
    /// Aqueous doesn't use a DI container today, so a small static accessor is the
    /// lowest-churn way to let widgets and services depend on the interface instead
    /// of calling <c>WayfireIpc</c> statics directly. <see cref="Set"/> is called
    /// once at startup from <c>Program.cs</c>.
    /// </summary>
    public static class CompositorBackend
    {
        private static ICompositorBackend? _current;

        /// <summary>The active backend. Throws if accessed before <see cref="Set"/>.</summary>
        public static ICompositorBackend Current =>
            _current ?? throw new InvalidOperationException(
                "CompositorBackend.Current accessed before Set() was called.");

        /// <summary>True once a backend has been installed.</summary>
        public static bool IsInitialized => _current is not null;

        /// <summary>Installs the backend. Idempotent for the same instance.</summary>
        public static void Set(ICompositorBackend backend)
        {
            if (ReferenceEquals(_current, backend)) return;
            _current?.Dispose();
            _current = backend;
        }
    }
}
