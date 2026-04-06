using Aqueous.Bindings.AstalGTK4.Services;

namespace Aqueous.Features.Bar
{
    public class BarService
    {
        private readonly AstalApplication _app;
        public BarWindow? Window { get; private set; }

        public BarService(AstalApplication app)
        {
            _app = app;
        }

        public void Start()
        {
            Window = new BarWindow(_app);
            Window.Show();
        }

        public void Stop()
        {
            Window?.Destroy();
            Window = null;
        }
    }
}
