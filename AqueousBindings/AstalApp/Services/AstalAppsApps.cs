using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using Aqueous.Bindings.AstalApp;

namespace Aqueous.Bindings.AstalApp.Services
{
    public unsafe class AstalAppsApps
    {
        private _AstalAppsApps* _handle;

        public AstalAppsApps() : this(AstalAppsInterop.astal_apps_apps_new())
        {
        }

        internal AstalAppsApps(_AstalAppsApps* handle)
        {
            _handle = handle;
        }

        public IEnumerable<AstalAppsApplication> List
        {
            get
            {
                var listPtr = AstalAppsInterop.astal_apps_apps_get_list(_handle);
                return WrapGList(listPtr);
            }
        }

        public void Reload() => AstalAppsInterop.astal_apps_apps_reload(_handle);

        public IEnumerable<AstalAppsApplication> FuzzyQuery(string query)
        {
            var queryPtr = (sbyte*)Marshal.StringToHGlobalAnsi(query);
            try
            {
                var listPtr = AstalAppsInterop.astal_apps_apps_fuzzy_query(_handle, queryPtr);
                return WrapGList(listPtr);
            }
            finally
            {
                Marshal.FreeHGlobal((IntPtr)queryPtr);
            }
        }

        public IEnumerable<AstalAppsApplication> ExactQuery(string query)
        {
            var queryPtr = (sbyte*)Marshal.StringToHGlobalAnsi(query);
            try
            {
                var listPtr = AstalAppsInterop.astal_apps_apps_exact_query(_handle, queryPtr);
                return WrapGList(listPtr);
            }
            finally
            {
                Marshal.FreeHGlobal((IntPtr)queryPtr);
            }
        }

        public double FuzzyScore(string query, AstalAppsApplication app)
        {
            var queryPtr = (sbyte*)Marshal.StringToHGlobalAnsi(query);
            try
            {
                return AstalAppsInterop.astal_apps_apps_fuzzy_score(_handle, queryPtr, app.Handle);
            }
            finally
            {
                Marshal.FreeHGlobal((IntPtr)queryPtr);
            }
        }

        public double ExactScore(string query, AstalAppsApplication app)
        {
            var queryPtr = (sbyte*)Marshal.StringToHGlobalAnsi(query);
            try
            {
                return AstalAppsInterop.astal_apps_apps_exact_score(_handle, queryPtr, app.Handle);
            }
            finally
            {
                Marshal.FreeHGlobal((IntPtr)queryPtr);
            }
        }

        public bool ShowHidden
        {
            get => AstalAppsInterop.astal_apps_apps_get_show_hidden(_handle) != 0;
            set => AstalAppsInterop.astal_apps_apps_set_show_hidden(_handle, value ? 1 : 0);
        }

        public double MinScore
        {
            get => AstalAppsInterop.astal_apps_apps_get_min_score(_handle);
            set => AstalAppsInterop.astal_apps_apps_set_min_score(_handle, value);
        }

        public double NameMultiplier
        {
            get => AstalAppsInterop.astal_apps_apps_get_name_multiplier(_handle);
            set => AstalAppsInterop.astal_apps_apps_set_name_multiplier(_handle, value);
        }

        public double EntryMultiplier
        {
            get => AstalAppsInterop.astal_apps_apps_get_entry_multiplier(_handle);
            set => AstalAppsInterop.astal_apps_apps_set_entry_multiplier(_handle, value);
        }

        public double ExecutableMultiplier
        {
            get => AstalAppsInterop.astal_apps_apps_get_executable_multiplier(_handle);
            set => AstalAppsInterop.astal_apps_apps_set_executable_multiplier(_handle, value);
        }

        public double DescriptionMultiplier
        {
            get => AstalAppsInterop.astal_apps_apps_get_description_multiplier(_handle);
            set => AstalAppsInterop.astal_apps_apps_set_description_multiplier(_handle, value);
        }

        public double KeywordsMultiplier
        {
            get => AstalAppsInterop.astal_apps_apps_get_keywords_multiplier(_handle);
            set => AstalAppsInterop.astal_apps_apps_set_keywords_multiplier(_handle, value);
        }

        public double CategoriesMultiplier
        {
            get => AstalAppsInterop.astal_apps_apps_get_categories_multiplier(_handle);
            set => AstalAppsInterop.astal_apps_apps_set_categories_multiplier(_handle, value);
        }

        private IEnumerable<AstalAppsApplication> WrapGList(_GList* listPtr)
        {
            var results = new List<AstalAppsApplication>();
            var current = listPtr;
            while (current != null)
            {
                // In GList, data is at the beginning.
                // struct _GList { gpointer data; GList *next; GList *prev; }
                void* data = *(void**)current;
                results.Add(new AstalAppsApplication((_AstalAppsApplication*)data));
                
                // next is the second pointer
                current = *(_GList**)((byte*)current + sizeof(void*));
            }
            return results;
        }
    }
}
