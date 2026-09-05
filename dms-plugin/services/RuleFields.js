.pragma library
// Mirrors the Noctalia typed rule editor; unknown keys remain in the backend.
var fields = [
  {
    "key": "app_id",
    "label": "App ID",
    "type": "string"
  },
  {
    "key": "class",
    "label": "XWayland class",
    "type": "string"
  },
  {
    "key": "title",
    "label": "Title",
    "type": "string"
  },
  {
    "key": "content_type",
    "label": "Content type",
    "type": "select",
    "options": [
      "none",
      "photo",
      "video",
      "game"
    ]
  },
  {
    "key": "layout",
    "label": "Layout",
    "type": "select",
    "options": [
      "tile",
      "monocle",
      "grid",
      "rows",
      "dwindle",
      "reverse-dwindle",
      "scrolling",
      "stacking",
      "game-mode",
      "composable"
    ]
  },
  {
    "key": "output",
    "label": "Output",
    "type": "string"
  },
  {
    "key": "workspace",
    "label": "Workspace",
    "type": "number"
  },
  {
    "key": "floating",
    "label": "Freeform",
    "type": "boolean"
  },
  {
    "key": "fullscreen",
    "label": "Fullscreen",
    "type": "boolean"
  },
  {
    "key": "ignore_struts",
    "label": "Ignore reserved areas",
    "type": "boolean"
  },
  {
    "key": "width",
    "label": "Width",
    "type": "number"
  },
  {
    "key": "height",
    "label": "Height",
    "type": "number"
  },
  {
    "key": "x",
    "label": "X offset",
    "type": "number"
  },
  {
    "key": "y",
    "label": "Y offset",
    "type": "number"
  },
  {
    "key": "placement_policy",
    "label": "Placement",
    "type": "select",
    "options": [
      "cascade",
      "center",
      "under-pointer",
      "minimal-overlap"
    ]
  },
  {
    "key": "stack_layer",
    "label": "Stack layer",
    "type": "select",
    "options": [
      "below",
      "normal",
      "above"
    ]
  },
  {
    "key": "focus",
    "label": "Focus eligible",
    "type": "boolean"
  },
  {
    "key": "fixed_position",
    "label": "Fixed position",
    "type": "boolean"
  },
  {
    "key": "skip_switcher",
    "label": "Skip switcher",
    "type": "boolean"
  },
  {
    "key": "skip_taskbar",
    "label": "Skip taskbar",
    "type": "boolean"
  },
  {
    "key": "blur",
    "label": "Blur",
    "type": "boolean"
  },
  {
    "key": "opacity",
    "label": "Opacity",
    "type": "number"
  },
  {
    "key": "hdr_expand",
    "label": "HDR expansion",
    "type": "boolean"
  },
  {
    "key": "buffer_scale_policy",
    "label": "Buffer scaling",
    "type": "select",
    "options": [
      "native",
      "integer-ceil"
    ]
  },
  {
    "key": "overlay_plane",
    "label": "Overlay plane",
    "type": "select",
    "options": [
      "off",
      "prefer"
    ]
  },
  {
    "key": "anchor",
    "label": "Game anchor",
    "type": "select",
    "options": [
      "center",
      "top",
      "bottom",
      "left",
      "right"
    ]
  },
  {
    "key": "size",
    "label": "Game size",
    "type": "string"
  },
  {
    "key": "scale",
    "label": "Game scale",
    "type": "number"
  }
];
