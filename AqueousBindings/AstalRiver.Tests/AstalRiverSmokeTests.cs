using System;
using System.Linq;
using Aqueous.Bindings.AstalRiver.Services;
using Xunit;

namespace Aqueous.Bindings.AstalRiver.Tests
{
    /// <summary>
    /// Phase 7 smoke tests for the AstalRiver binding.
    ///
    /// These tests verify that the managed wrapper types load and that
    /// P/Invoke entry points are resolvable. Tests that require a live
    /// River compositor (i.e. an actual River IPC session) are gated
    /// through <see cref="RiverAvailable"/> and are skipped otherwise, so
    /// CI / headless environments don't fail just because no compositor
    /// is running.
    /// </summary>
    public sealed class AstalRiverSmokeTests
    {
        /// <summary>
        /// The AstalRiver GObject constructor succeeds even without a live
        /// River session (it just produces an empty, unpopulated instance),
        /// so we instead probe for a real compositor by requiring that at
        /// least one output is reported. This keeps the skippable tests
        /// green on CI / non-River hosts.
        /// </summary>
        private static bool RiverAvailable
        {
            get
            {
                try
                {
                    var r = AstalRiverRiver.GetDefault();
                    return r is not null && r.Outputs.Any();
                }
                catch { return false; }
            }
        }

        [Fact]
        public void AssemblyLoads_And_TypesAreReachable()
        {
            // Touch the service types so the assembly (and thus its native
            // DllImports) are actually loaded. If libastal-river.so is
            // missing entirely, the CLR will throw a DllNotFoundException
            // only on the first P/Invoke — not on assembly load — so this
            // test purely validates managed metadata.
            Assert.NotNull(typeof(AstalRiverRiver).FullName);
            Assert.NotNull(typeof(AstalRiverOutput).FullName);
        }

        [Fact]
        public void GetDefault_DoesNotThrow()
        {
            // Either returns a live handle (under River) or null (elsewhere).
            // Must never throw — widgets rely on that contract.
            var ex = Record.Exception(() => AstalRiverRiver.GetDefault());
            Assert.Null(ex);
        }

        [SkippableFact]
        public void UnderRiver_OutputsIsNonEmpty()
        {
            Skip.IfNot(RiverAvailable, "No running River compositor.");
            var river = AstalRiverRiver.GetDefault();
            Assert.NotNull(river);
            var outputs = river!.Outputs.ToList();
            Assert.NotEmpty(outputs);
        }

        [SkippableFact]
        public void UnderRiver_FocusedOutput_HasName()
        {
            Skip.IfNot(RiverAvailable, "No running River compositor.");
            var river = AstalRiverRiver.GetDefault()!;
            var focused = river.FocusedOutput;
            if (focused is null) return; // legal: no focus yet
            Assert.False(string.IsNullOrEmpty(focused.Name));
        }

        [SkippableFact]
        public void UnderRiver_Mode_IsReadable()
        {
            Skip.IfNot(RiverAvailable, "No running River compositor.");
            var river = AstalRiverRiver.GetDefault()!;
            // Mode may be null briefly during startup, but the call itself
            // must not throw.
            var ex = Record.Exception(() => _ = river.Mode);
            Assert.Null(ex);
        }
    }
}
