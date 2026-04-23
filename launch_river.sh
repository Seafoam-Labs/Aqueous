#!/bin/bash
# Automatically generated launch script for Rider
# This script launches a nested River session running Aqueous.WM and Aqueous

# Rider sets the working directory to the project root, so we can use relative paths
AQUEOUS_RIVER_WM=1 WAYLAND_DEBUG=1 river -c "sh -c '$(pwd)/Aqueous.WM/bin/Debug/net10.0/Aqueous.WM & sleep 1; $(pwd)/Aqueous/bin/Debug/net10.0/Aqueous'"
