using System;
using Gtk;

namespace Aqueous.Features.Settings.SettingsPages
{
    public class WindowRuleEditDialog : Gtk.Window
    {
        private string _ruleKey;
        private string _ruleValue;
        private Action _onSaved;
        
        private Gtk.Entry _descriptionEntry;
        private Gtk.DropDown _classConditionDropDown;
        private Gtk.Entry _classEntry;
        private Gtk.DropDown _titleConditionDropDown;
        private Gtk.Entry _titleEntry;
        
        private Gtk.CheckButton _widthEnabled;
        private Gtk.SpinButton _widthSpin;
        private Gtk.CheckButton _heightEnabled;
        private Gtk.SpinButton _heightSpin;
        
        private Gtk.CheckButton _opacityEnabled;
        private Gtk.Scale _opacityScale;
        
        public WindowRuleEditDialog(Gtk.Window parent, string ruleKey, string ruleValue, Action onSaved)
        {
            this.SetTransientFor(parent);
            this.SetModal(true);
            this.SetTitle(string.IsNullOrEmpty(ruleKey) ? "Create Window Rule" : "Edit Window Rule");
            this.SetDefaultSize(600, 400);
            
            _ruleKey = ruleKey;
            _ruleValue = ruleValue;
            _onSaved = onSaved;
            
            var mainBox = Gtk.Box.New(Orientation.Vertical, 8);
            mainBox.SetMarginTop(16);
            mainBox.SetMarginBottom(16);
            mainBox.SetMarginStart(16);
            mainBox.SetMarginEnd(16);
            
            var notebook = Gtk.Notebook.New();
            notebook.SetVexpand(true);
            mainBox.Append(notebook);
            
            // Tab 1: Matching
            var matchBox = Gtk.Box.New(Orientation.Vertical, 8);
            _descriptionEntry = Gtk.Entry.New();
            _descriptionEntry.SetText(string.IsNullOrEmpty(ruleKey) ? "New Rule" : ruleKey);
            matchBox.Append(new Gtk.Label { Label_ = "Description (Rule Key)", Xalign = 0 });
            matchBox.Append(_descriptionEntry);
            
            _classConditionDropDown = Gtk.DropDown.NewFromStrings(new[] { "Exact Match", "Substring", "Regex" });
            _classEntry = Gtk.Entry.New();
            matchBox.Append(new Gtk.Label { Label_ = "Window Class / App ID", Xalign = 0 });
            var classBox = Gtk.Box.New(Orientation.Horizontal, 8);
            classBox.Append(_classConditionDropDown);
            classBox.Append(_classEntry);
            matchBox.Append(classBox);
            
            _titleConditionDropDown = Gtk.DropDown.NewFromStrings(new[] { "Exact Match", "Substring", "Regex" });
            _titleEntry = Gtk.Entry.New();
            matchBox.Append(new Gtk.Label { Label_ = "Window Title", Xalign = 0 });
            var titleBox = Gtk.Box.New(Orientation.Horizontal, 8);
            titleBox.Append(_titleConditionDropDown);
            titleBox.Append(_titleEntry);
            matchBox.Append(titleBox);
            
            notebook.AppendPage(matchBox, new Gtk.Label { Label_ = "Matching" });
            
            // Tab 2: Size & Position
            var sizeBox = Gtk.Box.New(Orientation.Vertical, 8);
            _widthEnabled = Gtk.CheckButton.NewWithLabel("Width");
            _widthSpin = Gtk.SpinButton.NewWithRange(1, 4096, 1);
            var wBox = Gtk.Box.New(Orientation.Horizontal, 8);
            wBox.Append(_widthEnabled);
            wBox.Append(_widthSpin);
            sizeBox.Append(wBox);
            
            _heightEnabled = Gtk.CheckButton.NewWithLabel("Height");
            _heightSpin = Gtk.SpinButton.NewWithRange(1, 4096, 1);
            var hBox = Gtk.Box.New(Orientation.Horizontal, 8);
            hBox.Append(_heightEnabled);
            hBox.Append(_heightSpin);
            sizeBox.Append(hBox);
            
            notebook.AppendPage(sizeBox, new Gtk.Label { Label_ = "Size & Position" });
            
            // Tab 3: Appearance
            var appearanceBox = Gtk.Box.New(Orientation.Vertical, 8);
            _opacityEnabled = Gtk.CheckButton.NewWithLabel("Opacity");
            _opacityScale = Gtk.Scale.NewWithRange(Orientation.Horizontal, 0.1, 1.0, 0.05);
            _opacityScale.SetHexpand(true);
            var oBox = Gtk.Box.New(Orientation.Horizontal, 8);
            oBox.Append(_opacityEnabled);
            oBox.Append(_opacityScale);
            appearanceBox.Append(oBox);
            
            notebook.AppendPage(appearanceBox, new Gtk.Label { Label_ = "Appearance" });
            
            // Action buttons
            var actionBox = Gtk.Box.New(Orientation.Horizontal, 8);
            actionBox.SetHalign(Align.End);
            
            var cancelBtn = Gtk.Button.NewWithLabel("Cancel");
            cancelBtn.OnClicked += (s, e) => this.Destroy();
            
            var saveBtn = Gtk.Button.NewWithLabel("Save");
            saveBtn.AddCssClass("suggested-action");
            saveBtn.OnClicked += (s, e) => SaveAndClose();
            
            actionBox.Append(cancelBtn);
            actionBox.Append(saveBtn);
            mainBox.Append(actionBox);
            
            this.SetChild(mainBox);
            
            ParseRuleValue(_ruleValue);
        }
        
        private void ParseRuleValue(string val)
        {
            if (string.IsNullOrEmpty(val)) return;
            
            if (val.Contains("app_id is"))
            {
                int start = val.IndexOf("app_id is") + 10;
                int end = val.IndexOf('"', start + 1);
                if (start > 0 && end > start)
                {
                    _classEntry.SetText(val.Substring(start, end - start));
                }
            }
            if (val.Contains("set alpha"))
            {
                int alphaIdx = val.IndexOf("set alpha");
                string alphaStr = val.Substring(alphaIdx + 9).Trim();
                int space = alphaStr.IndexOf(' ');
                if (space > 0) alphaStr = alphaStr.Substring(0, space);
                if (double.TryParse(alphaStr, System.Globalization.NumberStyles.Any, System.Globalization.CultureInfo.InvariantCulture, out double a))
                {
                    _opacityEnabled.SetActive(true);
                    _opacityScale.SetValue(a);
                }
            }
        }
        
        private void SaveAndClose()
        {
            var wayfire = RiverConfigService.Instance;
            
            string key = _descriptionEntry.GetBuffer().GetText();
            if (string.IsNullOrEmpty(key)) key = "rule_new";
            
            string matchStr = "";
            string classVal = _classEntry.GetBuffer().GetText();
            if (!string.IsNullOrEmpty(classVal))
            {
                matchStr = $"app_id is \"{classVal}\"";
            }
            else
            {
                matchStr = "app_id is \"unknown\"";
            }
            
            string actions = "";
            if (_opacityEnabled.GetActive())
            {
                var opacityStr = _opacityScale.GetValue().ToString("0.00", System.Globalization.CultureInfo.InvariantCulture);
                actions += $"set alpha {opacityStr} ";
            }
            
            string ruleStr = $"on created if {matchStr} then {actions}".Trim();
            
            wayfire.SetString("window-rules", key, ruleStr);
            
            _onSaved?.Invoke();
            this.Destroy();
        }
    }
}