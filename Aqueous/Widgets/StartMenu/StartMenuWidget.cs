using Aqueous.Bindings.AstalGTK4.Services;
using Aqueous.Features.Settings;
using Gtk;

namespace Aqueous.Widgets.StartMenu;

public class StartMenuWidget
{
    private readonly Gtk.Button _button;
    private readonly StartMenuWindow _menuWindow;

    public Gtk.Button Button => _button;

    public StartMenuWidget(AstalApplication app, SettingsService settingsService)
    {
        _menuWindow = new StartMenuWindow(app, settingsService);

        _button = Gtk.Button.New();
        _button.AddCssClass("start-menu-button");

        var label = Gtk.Label.New("A");
        label.AddCssClass("start-menu-button-label");
        _button.SetChild(label);

        _button.OnClicked += (sender, _) =>
        {
            _menuWindow.Toggle(_button);
        };
    }
}
