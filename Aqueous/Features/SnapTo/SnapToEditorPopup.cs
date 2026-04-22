using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading;
using Aqueous.Bindings.AstalGTK4;
using Aqueous.Bindings.AstalGTK4.Services;
using Aqueous.Helpers;
using Gtk;

namespace Aqueous.Features.SnapTo
{
    public class SnapToEditorPopup
    {
        private readonly AstalApplication _app;
        private AstalWindow? _window;
        private List<ZoneLayout> _layouts;
        private int _currentLayoutIndex;
        private int _selectedZoneIndex = -1;
        private CancellationTokenSource? _debounceCts;

        // UI references for updating
        private Gtk.Fixed? _previewArea;
        private Gtk.Box? _propertyEditor;
        private Gtk.Label? _layoutLabel;
        private Gtk.Entry? _layoutNameEntry;
        private Gtk.Box? _container;

        public bool IsVisible { get; private set; }

        // Callback to notify SnapToService to reload
        public Action? OnSaved { get; set; }

        private const int PreviewW = 400;
        private const int PreviewH = 225;
        private static readonly string[] ZoneColors =
            ["#89b4fa", "#a6e3a1", "#f38ba8", "#fab387", "#cba6f7", "#f9e2af", "#94e2d5", "#f5c2e7"];

        public SnapToEditorPopup(AstalApplication app, List<ZoneLayout> layouts)
        {
            _app = app;
            _layouts = layouts.Select(l => new ZoneLayout(l.Name, l.Zones.Select(z =>
                new Zone(z.Name, z.X, z.Y, z.Width, z.Height)).ToList())).ToList();
            if (_layouts.Count == 0)
                _layouts = SnapToConfig.GetDefaults();
        }

        public void Show(string? preSelectedZone = null)
        {
            if (IsVisible) return;

            _window = new AstalWindow();
            _app.GtkApplication.AddWindow(_window.GtkWindow);
            _window.Namespace = "snapto-editor";
            _window.Layer = AstalLayer.ASTAL_LAYER_OVERLAY;
            _window.Exclusivity = AstalExclusivity.ASTAL_EXCLUSIVITY_IGNORE;
            // Pointer-only editor popup. NONE prevents compositor stealing the first click.
            _window.Keymode = AstalKeymode.ASTAL_KEYMODE_NONE;

            _container = Gtk.Box.New(Orientation.Vertical, 8);
            _container.AddCssClass("snapto-editor");
            _container.SetSizeRequest(460, -1);

            // Title bar
            var titleRow = Gtk.Box.New(Orientation.Horizontal, 8);
            var titleLabel = Gtk.Label.New("SnapTo Zone Editor");
            titleLabel.AddCssClass("section-header");
            titleLabel.Hexpand = true;
            titleLabel.Halign = Align.Start;
            titleRow.Append(titleLabel);

            var closeBtn = Gtk.Button.NewWithLabel("✕");
            closeBtn.AddCssClass("flat");
            closeBtn.OnClicked += (_, _) => Hide();
            titleRow.Append(closeBtn);
            _container.Append(titleRow);

            // Layout selector
            _container.Append(CreateLayoutSelector());

            // Preview area
            _container.Append(CreatePreview());

            // Property editor
            _propertyEditor = Gtk.Box.New(Orientation.Vertical, 4);
            _propertyEditor.AddCssClass("zone-property-editor");
            _container.Append(_propertyEditor);

            // Zone management buttons
            _container.Append(CreateZoneButtons());

            // Action buttons
            _container.Append(CreateActionButtons());

            // Escape key
            var keyController = Gtk.EventControllerKey.New();
            keyController.OnKeyPressed += (controller, args) =>
            {
                if (args.Keyval == 0xff1b)
                {
                    Hide();
                    return true;
                }
                return false;
            };
            _window.GtkWindow.AddController(keyController);

            var scrolled = Gtk.ScrolledWindow.New();
            scrolled.SetPolicy(PolicyType.Never, PolicyType.Automatic);
            scrolled.SetMaxContentHeight(600);
            scrolled.SetPropagateNaturalHeight(true);
            scrolled.SetChild(_container);

            _window.GtkWindow.SetChild(scrolled);
            _window.GtkWindow.Present();
            IsVisible = true;

            // Pre-select zone if requested
            if (preSelectedZone != null)
            {
                var layout = CurrentLayout;
                var idx = layout.Zones.FindIndex(z => z.Name == preSelectedZone);
                if (idx >= 0)
                {
                    _selectedZoneIndex = idx;
                    RefreshPreview();
                    RefreshPropertyEditor();
                }
            }
        }

        public void Hide()
        {
            if (!IsVisible || _window == null) return;
            BackdropHelper.DestroyWindow(ref _window);
            IsVisible = false;
        }

        private ZoneLayout CurrentLayout => _layouts[_currentLayoutIndex];

        private Gtk.Box CreateLayoutSelector()
        {
            var row = Gtk.Box.New(Orientation.Horizontal, 4);
            row.AddCssClass("snapto-editor-layout-row");

            var label = Gtk.Label.New("Layout:");
            label.Halign = Align.Start;
            row.Append(label);

            var prevBtn = Gtk.Button.NewWithLabel("◄");
            prevBtn.AddCssClass("flat");
            prevBtn.OnClicked += (_, _) =>
            {
                _currentLayoutIndex = (_currentLayoutIndex - 1 + _layouts.Count) % _layouts.Count;
                _selectedZoneIndex = -1;
                RefreshLayoutLabel();
                RefreshPreview();
                RefreshPropertyEditor();
            };
            row.Append(prevBtn);

            _layoutLabel = Gtk.Label.New(CurrentLayout.Name);
            _layoutLabel.Hexpand = true;
            row.Append(_layoutLabel);

            var nextBtn = Gtk.Button.NewWithLabel("►");
            nextBtn.AddCssClass("flat");
            nextBtn.OnClicked += (_, _) =>
            {
                _currentLayoutIndex = (_currentLayoutIndex + 1) % _layouts.Count;
                _selectedZoneIndex = -1;
                RefreshLayoutLabel();
                RefreshPreview();
                RefreshPropertyEditor();
            };
            row.Append(nextBtn);

            var addLayoutBtn = Gtk.Button.NewWithLabel("+");
            addLayoutBtn.AddCssClass("flat");
            addLayoutBtn.OnClicked += (_, _) =>
            {
                _layouts.Add(new ZoneLayout("New Layout", new List<Zone>()));
                _currentLayoutIndex = _layouts.Count - 1;
                _selectedZoneIndex = -1;
                RefreshLayoutLabel();
                RefreshPreview();
                RefreshPropertyEditor();
            };
            row.Append(addLayoutBtn);

            var delLayoutBtn = Gtk.Button.NewWithLabel("🗑");
            delLayoutBtn.AddCssClass("flat");
            delLayoutBtn.OnClicked += (_, _) =>
            {
                if (_layouts.Count <= 1) return;
                _layouts.RemoveAt(_currentLayoutIndex);
                _currentLayoutIndex = Math.Min(_currentLayoutIndex, _layouts.Count - 1);
                _selectedZoneIndex = -1;
                RefreshLayoutLabel();
                RefreshPreview();
                RefreshPropertyEditor();
            };
            row.Append(delLayoutBtn);

            // Layout name entry
            _layoutNameEntry = Gtk.Entry.New();
            _layoutNameEntry.SetText(CurrentLayout.Name);
            _layoutNameEntry.SetSizeRequest(140, -1);
            var nameBuffer = _layoutNameEntry.GetBuffer();
            nameBuffer.OnInsertedText += (_, _) => DebounceUpdateLayoutName(nameBuffer.GetText());
            nameBuffer.OnDeletedText += (_, _) => DebounceUpdateLayoutName(nameBuffer.GetText());
            row.Append(_layoutNameEntry);

            return row;
        }

        private Gtk.Box CreatePreview()
        {
            var box = Gtk.Box.New(Orientation.Vertical, 0);
            box.AddCssClass("snapto-preview-container");

            _previewArea = Gtk.Fixed.New();
            _previewArea.SetSizeRequest(PreviewW, PreviewH);
            _previewArea.AddCssClass("snapto-preview");

            RenderZonesToPreview();

            box.Append(_previewArea);
            return box;
        }

        private void RenderZonesToPreview()
        {
            if (_previewArea == null) return;

            // Remove all children
            var child = _previewArea.GetFirstChild();
            while (child != null)
            {
                var next = child.GetNextSibling();
                _previewArea.Remove(child);
                child = next;
            }

            var layout = CurrentLayout;
            for (int i = 0; i < layout.Zones.Count; i++)
            {
                var zone = layout.Zones[i];
                var idx = i;

                var zoneBtn = Gtk.Button.New();
                var zoneW = Math.Max(20, (int)(zone.Width * PreviewW));
                var zoneH = Math.Max(14, (int)(zone.Height * PreviewH));
                zoneBtn.SetSizeRequest(zoneW, zoneH);

                var zoneLabel = Gtk.Label.New(zone.Name);
                zoneLabel.Ellipsize = Pango.EllipsizeMode.End;
                zoneBtn.SetChild(zoneLabel);

                zoneBtn.AddCssClass("snapto-preview-zone");
                if (idx == _selectedZoneIndex)
                    zoneBtn.AddCssClass("selected");

                // Apply zone color via inline CSS
                var color = ZoneColors[i % ZoneColors.Length];
                var cssProvider = Gtk.CssProvider.New();
                cssProvider.LoadFromString(
                    $"button {{ background-color: alpha({color}, 0.3); border: 2px solid {color}; border-radius: 4px; padding: 2px; color: #cdd6f4; font-size: 10px; min-height: 0; min-width: 0; }}");
                zoneBtn.GetStyleContext().AddProvider(cssProvider, Gtk.Constants.STYLE_PROVIDER_PRIORITY_APPLICATION);

                zoneBtn.OnClicked += (_, _) =>
                {
                    _selectedZoneIndex = idx;
                    RefreshPreview();
                    RefreshPropertyEditor();
                };

                _previewArea.Put(zoneBtn, zone.X * PreviewW, zone.Y * PreviewH);
            }
        }

        private Gtk.Box CreateZoneButtons()
        {
            var row = Gtk.Box.New(Orientation.Horizontal, 8);

            var addBtn = Gtk.Button.NewWithLabel("Add Zone");
            addBtn.AddCssClass("suggested-action");
            addBtn.OnClicked += (_, _) =>
            {
                var zones = CurrentLayout.Zones;
                zones.Add(new Zone("New Zone", 0, 0, 0.25, 0.25));
                _selectedZoneIndex = zones.Count - 1;
                RefreshPreview();
                RefreshPropertyEditor();
            };
            row.Append(addBtn);

            var delBtn = Gtk.Button.NewWithLabel("Delete Zone");
            delBtn.AddCssClass("destructive-action");
            delBtn.OnClicked += (_, _) =>
            {
                if (_selectedZoneIndex < 0 || _selectedZoneIndex >= CurrentLayout.Zones.Count) return;
                CurrentLayout.Zones.RemoveAt(_selectedZoneIndex);
                _selectedZoneIndex = Math.Min(_selectedZoneIndex, CurrentLayout.Zones.Count - 1);
                RefreshPreview();
                RefreshPropertyEditor();
            };
            row.Append(delBtn);

            return row;
        }

        private Gtk.Box CreateActionButtons()
        {
            var row = Gtk.Box.New(Orientation.Horizontal, 8);

            var resetBtn = Gtk.Button.NewWithLabel("Reset to Defaults");
            resetBtn.OnClicked += (_, _) =>
            {
                _layouts = SnapToConfig.GetDefaults();
                _currentLayoutIndex = 0;
                _selectedZoneIndex = -1;
                RefreshLayoutLabel();
                RefreshPreview();
                RefreshPropertyEditor();
            };
            row.Append(resetBtn);

            var spacer = Gtk.Box.New(Orientation.Horizontal, 0);
            spacer.Hexpand = true;
            row.Append(spacer);

            var saveBtn = Gtk.Button.NewWithLabel("Save");
            saveBtn.AddCssClass("suggested-action");
            saveBtn.OnClicked += (_, _) =>
            {
                // Validate: no empty layouts
                var hasEmpty = _layouts.Any(l => l.Zones.Count == 0);
                if (hasEmpty)
                {
                    // Remove empty layouts or warn — just remove them
                    _layouts.RemoveAll(l => l.Zones.Count == 0);
                    if (_layouts.Count == 0)
                        _layouts = SnapToConfig.GetDefaults();
                    _currentLayoutIndex = Math.Min(_currentLayoutIndex, _layouts.Count - 1);
                }

                SnapToConfig.Save(_layouts);
                OnSaved?.Invoke();
                Hide();
            };
            row.Append(saveBtn);

            return row;
        }

        private void RefreshLayoutLabel()
        {
            _layoutLabel?.SetText(CurrentLayout.Name);
            _layoutNameEntry?.SetText(CurrentLayout.Name);
        }

        private void RefreshPreview()
        {
            RenderZonesToPreview();
        }

        private void RefreshPropertyEditor()
        {
            if (_propertyEditor == null) return;

            // Clear existing children
            var child = _propertyEditor.GetFirstChild();
            while (child != null)
            {
                var next = child.GetNextSibling();
                _propertyEditor.Remove(child);
                child = next;
            }

            if (_selectedZoneIndex < 0 || _selectedZoneIndex >= CurrentLayout.Zones.Count)
                return;

            var zone = CurrentLayout.Zones[_selectedZoneIndex];

            var header = Gtk.Label.New($"Zone: \"{zone.Name}\"");
            header.AddCssClass("section-header");
            header.Halign = Align.Start;
            _propertyEditor.Append(header);

            // Name
            var nameRow = Gtk.Box.New(Orientation.Horizontal, 8);
            nameRow.AddCssClass("zone-property-row");
            nameRow.Append(Gtk.Label.New("Name:"));
            var nameEntry = Gtk.Entry.New();
            nameEntry.SetText(zone.Name);
            nameEntry.Hexpand = true;
            var nb = nameEntry.GetBuffer();
            nb.OnInsertedText += (_, _) => UpdateSelectedZone(name: nb.GetText());
            nb.OnDeletedText += (_, _) => UpdateSelectedZone(name: nb.GetText());
            nameRow.Append(nameEntry);
            _propertyEditor.Append(nameRow);

            // X / Width
            var xwRow = Gtk.Box.New(Orientation.Horizontal, 8);
            xwRow.AddCssClass("zone-property-row");
            xwRow.Append(Gtk.Label.New("X:"));
            var xSpin = CreateSpinButton(zone.X, val => UpdateSelectedZone(x: val));
            xwRow.Append(xSpin);
            xwRow.Append(Gtk.Label.New("W:"));
            var wSpin = CreateSpinButton(zone.Width, val => UpdateSelectedZone(width: val));
            xwRow.Append(wSpin);
            _propertyEditor.Append(xwRow);

            // Y / Height
            var yhRow = Gtk.Box.New(Orientation.Horizontal, 8);
            yhRow.AddCssClass("zone-property-row");
            yhRow.Append(Gtk.Label.New("Y:"));
            var ySpin = CreateSpinButton(zone.Y, val => UpdateSelectedZone(y: val));
            yhRow.Append(ySpin);
            yhRow.Append(Gtk.Label.New("H:"));
            var hSpin = CreateSpinButton(zone.Height, val => UpdateSelectedZone(height: val));
            yhRow.Append(hSpin);
            _propertyEditor.Append(yhRow);
        }

        private Gtk.SpinButton CreateSpinButton(double value, Action<double> onChange)
        {
            var spin = Gtk.SpinButton.NewWithRange(0.0, 1.0, 0.01);
            spin.Value = value;
            spin.Digits = 2;
            spin.Hexpand = true;
            spin.OnValueChanged += (_, _) =>
            {
                onChange(spin.Value);
            };
            return spin;
        }

        private void UpdateSelectedZone(string? name = null, double? x = null, double? y = null,
            double? width = null, double? height = null)
        {
            if (_selectedZoneIndex < 0 || _selectedZoneIndex >= CurrentLayout.Zones.Count) return;

            var old = CurrentLayout.Zones[_selectedZoneIndex];
            var newX = Math.Clamp(x ?? old.X, 0, 1);
            var newY = Math.Clamp(y ?? old.Y, 0, 1);
            var newW = Math.Clamp(width ?? old.Width, 0.01, 1.0 - newX);
            var newH = Math.Clamp(height ?? old.Height, 0.01, 1.0 - newY);

            CurrentLayout.Zones[_selectedZoneIndex] = new Zone(
                name ?? old.Name, newX, newY, newW, newH);

            RefreshPreview();
        }

        private void DebounceUpdateLayoutName(string newName)
        {
            _debounceCts?.Cancel();
            _debounceCts = new CancellationTokenSource();
            var token = _debounceCts.Token;

            System.Threading.Tasks.Task.Run(async () =>
            {
                try
                {
                    await System.Threading.Tasks.Task.Delay(150, token);
                    if (token.IsCancellationRequested) return;
                    GLib.Functions.IdleAdd(0, () =>
                    {
                        _layouts[_currentLayoutIndex] = new ZoneLayout(newName, CurrentLayout.Zones);
                        _layoutLabel?.SetText(newName);
                        return false;
                    });
                }
                catch (OperationCanceledException) { }
            }, token);
        }
    }
}
