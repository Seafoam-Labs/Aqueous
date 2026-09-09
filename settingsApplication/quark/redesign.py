# Executed by prepare.py with the pinned source, destination, and replace helper.
# Preserve application-supplied semantic IDs through navigation and reflow.
for file in ('Widget/Text.zig','Widget/Column.zig','Widget/Row.zig','Widget/Button.zig'):
    p=dst/file; p.write_text(__import__('re').sub(r'(?m)^(\w+:)',r'tone: u8 = 0,\n\1',p.read_text(),count=1))
p=dst/'Font.zig'; p.write_text(p.read_text()+ '\npub fn bundledRegular() []const u8 { return @embedFile("Font/Regular.woff2"); }\npub fn bundledBold() []const u8 { return @embedFile("Font/Bold.woff2"); }\n')
for tag, variable in [('button','b'),('textfield','t'),('checkbox','c'),('dropdown','d')]:
    replace('layout/engine.zig', f'.{tag} => |*{variable}| {variable}.id = id,', f'.{tag} => |*{variable}| {{ if ({variable}.id == 0) {variable}.id = id; }},')

# Shared clipping works on generated vertices, retaining SDF bounds and UVs.
replace('layout/engine.zig', '                    try tf.setText(state.text);', '                    if (!std.mem.eql(u8, tf.getText(), state.text)) continue;\n                    tf.focused = window.state.focused_textfield_id == tf.id;')
p = dst / 'Components/Rectangle.zig'
text = p.read_text()
text = text.replace('x: f32,', 'clip: ?@import("../Layout.zig") = null,\nx: f32,', 1)
text = text.replace('    return x >= self.x', '    if (self.clip) |c| { if (x < c.x or x > c.x + c.width or y < c.y or y > c.y + c.height) return false; }\n    return x >= self.x', 1)
text += '''
pub threadlocal var render_clip: ?@import("../Layout.zig") = null;
pub fn intersection(a: @import("../Layout.zig"), b: @import("../Layout.zig")) @import("../Layout.zig") {
    const x = @max(a.x, b.x); const y = @max(a.y, b.y);
    return .{ .x=x, .y=y, .width=@max(0, @min(a.x+a.width,b.x+b.width)-x), .height=@max(0, @min(a.y+a.height,b.y+b.height)-y) };
}
pub fn clipVertices(vertices: *[4]Vertex, rect: @This(), w: f32, h: f32) bool {
    var clip = render_clip;
    if (rect.clip) |c| clip = if (clip) |old| intersection(old,c) else c;
    const c = clip orelse return true;
    if (rect.width <= 0 or rect.height <= 0) return false;
    const x1 = @max(rect.x,c.x); const y1 = @max(rect.y,c.y);
    const x2 = @min(rect.x+rect.width,c.x+c.width); const y2 = @min(rect.y+rect.height,c.y+c.height);
    if (x2 <= x1 or y2 <= y1) return false;
    for (vertices, 0..) |*v,i| {
        const x = if (i==0 or i==3) x1 else x2;
        const y = if (i<2) y1 else y2;
        v.pos = .{x/w*2-1,y/h*2-1}; v.pos_px=.{x,y};
        if (v.tex_index >= 0) v.uv=.{(x-rect.x)/rect.width,(y-rect.y)/rect.height};
    }
    return true;
}
'''
p.write_text(text)
for method in ('toVertices','toImageVertices'):
    replace('vulkan/Renderer.zig', f'    const verts4 = rect.{method}(window_width, window_height);', f'    var verts4 = rect.{method}(window_width, window_height);\n    if (!Rectangle.clipVertices(&verts4, rect, window_width, window_height)) return;')
replace('Font.zig', 'pub const Text = struct {', 'pub const Text = struct {\n    clip: ?@import("Layout.zig") = null,')
replace('layout/instantiate.zig', 'if (bounds.y < clip.y or bounds.y + bounds.height > clip.y + clip.height) return;', 'if (bounds.y + bounds.height <= clip.y or bounds.y >= clip.y + clip.height) return;')
replace('layout/instantiate.zig', 'window.state.instantiate_clip = sv.layout;', 'window.state.instantiate_clip = if (old_clip) |c| components.Rectangle.intersection(c, sv.layout) else sv.layout;')
# Assign clips at each scope only to components in that scope's layer; menus
# deliberately render above their scroll viewport.
fields = [('buttons','button'),('textfields','textfield'),('checkboxes','checkbox'),('sliders','slider'),('canvases','canvas'),('images','image'),('texts','text')]
prefix = '\n'.join(f'    const start_{plural} = window.state.{plural}.items.len;' for plural,_ in fields)
suffix = '\n'.join(f'''        for (window.state.{plural}.items[start_{plural}..], start_{plural}..) |*item,i| {{
            if (window.state.{singular}_layers.items[i] != layer) continue;
            const ptr = &item.{'clip' if plural=='texts' else 'rect.clip'};
            ptr.* = if (ptr.*) |old| components.Rectangle.intersection(old,c) else c;
        }}''' for plural,singular in fields)
replace('layout/instantiate.zig', '    window.state.max_layer = @max(window.state.max_layer, layer);', '    window.state.max_layer = @max(window.state.max_layer, layer);\n'+prefix+'\n    defer { if (window.state.instantiate_clip) |c| {\n'+suffix+'\n    } }')
for plural,singular in fields:
    # Locate the renderer owning this component loop (labels are in labels.zig).
    matches = [p for p in (dst/'renderer').rglob('*.zig') if f'window.state.{plural}.items, 0..' in p.read_text()]
    for p in matches:
        text=p.read_text()
        marker=f'if (window.state.{singular}_layers.items[i] != layer) continue;'
        if marker not in text: continue
        import re
        variable=re.search(r'window.state\.'+plural+r'\.items, 0\.\.\) \|\*?(\w+), i\|',text).group(1)
        clip=f'{variable}.clip' if plural=='texts' else f'{variable}.rect.clip'
        text=text.replace(marker,marker+f'\n        @import("'+('../Components/Rectangle.zig' if p.parent==dst/'renderer' else '../../Components/Rectangle.zig')+f'").render_clip = {clip};\n        defer @import("'+('../Components/Rectangle.zig' if p.parent==dst/'renderer' else '../../Components/Rectangle.zig')+'").render_clip = null;')
        p.write_text(text)
# Textfield glyph clipping must clip partial glyphs as well as whole glyphs.
replace('renderer/text.zig', '    const cx2 = clip.x + clip.width;', '''    const Rectangle = @import("../Components/Rectangle.zig");
    const old_clip = Rectangle.render_clip;
    const bounds: @import("../Layout.zig") = .{.x=clip.x,.y=clip.y,.width=clip.width,.height=clip.height};
    Rectangle.render_clip = if (old_clip) |old| Rectangle.intersection(old,bounds) else bounds;
    defer Rectangle.render_clip = old_clip;
    const cx2 = clip.x + clip.width;''')

# Wrapped labels share one line-breaking routine for measurement and drawing.
p=dst/'Widget/Text.zig'
text=p.read_text().replace('text: []const u8,','wrap: bool = false,\ntext: []const u8,',1)
text=text.replace('pub const Options = struct {','pub const Options = struct {\n    wrap: bool = false,')
text=text.replace('.text = allocator.dupe(u8, opts.text) catch unreachable,','.wrap = opts.wrap,\n        .text = allocator.dupe(u8, opts.text) catch unreachable,')
text=text.replace('    const text_height = font_to_use.getTextHeight();','''    var text_height = font_to_use.getTextHeight();
    if (self.wrap) {
        var cursor: usize = 0; var lines: usize = 0;
        while (cursor < self.text.len) { cursor = try lineEnd(font_to_use,self.text,cursor,constraints.max_width); lines += 1; }
        text_height = @as(f32,@floatFromInt(@max(1,lines))) * text_height;
    }''')
text += '''
pub fn lineEnd(font: *Font, text: []const u8, start: usize, width: f32) !usize {
    var end = start; var space: ?usize = null;
    while (end < text.len) {
        if (text[end]=='\\n') return end+1;
        const step = std.unicode.utf8ByteSequenceLength(text[end]) catch 1;
        const next = @min(text.len,end+step);
        if (end>start and try font.getTextWidth(text[start..next]) > @max(1,width)) return space orelse end;
        end=next; if (text[end-1]==' ') space=end;
    }
    return end;
}
'''
p.write_text(text)
replace('layout/instantiate.zig', '''            try appendText(
                window,
                layer,
                txt.text,
                txt.layout.x,''', '''            if (txt.wrap) {
                var cursor: usize = 0; var line: usize = 0;
                while (cursor < txt.text.len) : (line += 1) {
                    const end = try @import("../Widget/Text.zig").lineEnd(font,txt.text,cursor,txt.layout.width);
                    try appendText(window,layer,std.mem.trimEnd(u8,txt.text[cursor..end]," \\n\\r"),txt.layout.x,txt.layout.y+font.getLineMetrics().ascent+@as(f32,@floatFromInt(line))*font.getTextHeight(),text_theme.color,font);
                    cursor=end;
                }
                return;
            }
            try appendText(
                window,
                layer,
                txt.text,
                txt.layout.x,''')

replace('State.zig','keyboard_focus_id: ?u32 = null,','keyboard_focus_id: ?u32 = null,\nsearch_requested: bool = false,\nescape_requested: bool = false,')
replace('input.zig','            var textfield: ?*components.TextField = null;', '''            if (key_event.mods.ctrl and (key_event.char == 'f' or key_event.char == 'F')) { window.state.search_requested=true; return null; }
            if (key_event.key_code == .escape) { window.state.escape_requested=true; }
            if (key_event.char == ' ' and window.state.focused_textfield_id == null) {
                for(window.state.checkboxes.items) |*cb| if(window.state.keyboard_focus_id == cb.id) { cb.checked = !cb.checked; return .{.checkbox_toggled=.{.id=cb.id,.checked=cb.checked}}; };
            }
            var textfield: ?*components.TextField = null;''')
replace('layout/instantiate.zig','            textfield.font = tf.font;','            textfield.font = tf.font;\n            textfield.focused = window.state.focused_textfield_id == tf.id;')
# Toggle rendering reuses the existing checkbox action and keyboard path.
replace('Components/CheckBox.zig','.width = 20.0,','.width = 44.0,')
replace('Components/CheckBox.zig','.height = 20.0,','.height = 24.0,')
replace('Widget/CheckBox.zig','const width = size + 5 +','const width = size * 2.2 + 5 +')
p=dst/'renderer/widgets/checkboxes.zig'
p.write_text('''const Rectangle=@import("../../Components/Rectangle.zig");
pub fn draw(window: anytype,layer: u16) !void {
    for(window.state.checkboxes.items,0..) |*cb,i| {
        if(window.state.checkbox_layers.items[i]!=layer) continue;
        Rectangle.render_clip=cb.rect.clip; defer Rectangle.render_clip=null;
        const color=if(cb.checked) cb.checked_color else cb.border_color;
        try window.state.renderer.drawRect(.{.x=cb.rect.x,.y=cb.rect.y,.width=44,.height=24,.border_radius=12,.color=color},window.width(),window.height());
        try window.state.renderer.drawRect(.{.x=cb.rect.x+(if(cb.checked) @as(f32,23) else 3),.y=cb.rect.y+3,.width=18,.height=18,.border_radius=9,.color=window.theme.Text.color},window.width(),window.height());
        if(window.state.keyboard_focus_id==cb.id) try @import("../border.zig").drawBorder(window,cb.rect.x-3,cb.rect.y-3,50,30,cb.hovered_border_color,2);
    }
}
''')
# Collect semantic widgets, including offscreen controls; scrolling reveals focus.
p=dst/'input.zig'; text=p.read_text(); start=text.index('fn focusNext('); end=text.index('pub fn handleKeyDown(',start)
text=text[:start]+'''const FocusCandidate=struct { id:u32,x:f32,y:f32 };
fn collectFocus(window:anytype,node:*@import("widget.zig").Widget,list:*[1024]FocusCandidate,count:*usize) void {
    switch(node.*) {
        .column=>|*w| for(w.children.items) |*child| collectFocus(window,&child.widget,list,count),
        .row=>|*w| for(w.children.items) |*child| collectFocus(window,&child.widget,list,count),
        .scrollview=>|*w| collectFocus(window,w.child,list,count),
        .modal=>|*w| collectFocus(window,w.child,list,count),
        .button,.textfield,.dropdown,.checkbox,.slider=>|w| {
            if(count.*==list.len or !isInteractionAllowed(window,w.layout.x,w.layout.y)) return;
            list[count.*]=.{.id=w.id,.x=w.layout.x,.y=w.layout.y}; count.*+=1;
        },
        else=>{},
    }
}
fn revealFocus(window:anytype,node:*@import("widget.zig").Widget,id:u32) ?Layout {
    switch(node.*) {
        .column=>|*w| { for(w.children.items) |*child| if(revealFocus(window,&child.widget,id)) |bounds| return bounds; },
        .row=>|*w| { for(w.children.items) |*child| if(revealFocus(window,&child.widget,id)) |bounds| return bounds; },
        .scrollview=>|*w| { if(revealFocus(window,w.child,id)) |bounds| {
            if(bounds.y<w.layout.y or bounds.y+bounds.height>w.layout.y+w.layout.height) {
                w.scroll_y=@max(0,@min(w.child_layout.height-w.layout.height,w.scroll_y+bounds.y-w.layout.y-12)); window.state.layout_dirty=true;
            }
            return w.layout;
        } },
        .modal=>|*w| return revealFocus(window,w.child,id),
        .button,.textfield,.dropdown,.checkbox,.slider=>|w| { if(w.id==id) return w.layout; },
        else=>{},
    }
    return null;
}
fn focusNext(window:anytype,backwards:bool) void {
    var list:[1024]FocusCandidate=undefined; var count:usize=0;
    if(window.state.root_widget) |*root| collectFocus(window,root,&list,&count);
    if(count==0) return;
    // Tree order follows sidebar then page content then the persistent actions.
    const current=window.state.keyboard_focus_id orelse window.state.focused_textfield_id;
    var target:usize=if(backwards) count-1 else 0;
    for(list[0..count],0..) |item,i| if(current==item.id) { target=if(backwards) (i+count-1)%count else (i+1)%count; break; };
    const id=list[target].id; window.state.keyboard_focus_id=id; window.state.focused_textfield_id=null;
    if(window.state.root_widget) |*root| {
        _=revealFocus(window,root,id);
        // Find text inputs even if the component will only appear after scrolling.
        setTextFocus(window,root,id);
    }
    for(window.state.textfields.items) |*tf| tf.focused=tf.id==window.state.focused_textfield_id;
}
fn setTextFocus(window:anytype,node:*@import("widget.zig").Widget,id:u32) void {
    switch(node.*) {
        .textfield=>|w| { if(w.id==id) window.state.focused_textfield_id=id; },
        .column=>|*w| for(w.children.items) |*child| setTextFocus(window,&child.widget,id),
        .row=>|*w| for(w.children.items) |*child| setTextFocus(window,&child.widget,id),
        .scrollview=>|*w| setTextFocus(window,w.child,id),
        .modal=>|*w| setTextFocus(window,w.child,id),
        else=>{},
    }
}

'''+text[end:]; text=text.replace('.button,.textfield,.dropdown,.checkbox,.slider=>|w|','.button,.textfield,.dropdown,.checkbox,.slider=>|w|')
# Tagged union payloads differ; inline prongs specialize each widget type.
text=text.replace('.button,.textfield,.dropdown,.checkbox,.slider=>|w|','inline .button,.textfield,.dropdown,.checkbox,.slider=>|w|')
p.write_text(text)

p=dst/"components.zig"; p.write_text(p.read_text()+'\npub const Rectangle = @import("Components/Rectangle.zig");\n')
# Account for gaps between every row child before assigning proportional widths.
p=dst/'Widget/Row.zig'; text=p.read_text(); start=text.index('    if (self.children.items.len - flexible_count - portion_children > 1)'); end=text.index('    // Calculate the available space',start)
text=text[:start]+'''    if (self.children.items.len>1) used_width += @as(f32,@floatFromInt(self.children.items.len-1))*self.spacing;

'''+text[end:]; p.write_text(text)
replace('layout/engine.zig','                    slider.value = state.value;','                    if (state.dragging) slider.value = state.value;')

# Keyboard sliders and pointer clipping share the same component bounds.
replace('input.zig', '                    if (code == .enter and textfield == null) {', """                    for (window.state.sliders.items) |*slider| {
                        if (slider.id != id) continue;
                        if (code == .left or code == .right or code == .up or code == .down or code == .home or code == .end) {
                            const step = if (slider.step > 0) slider.step else (slider.max_value-slider.min_value)/100;
                            slider.setValue(if(code == .home) slider.min_value else if(code == .end) slider.max_value else slider.value + (if(code == .left or code == .down) -step else step));
                            return .{.slider_changed=.{.id=id,.value=slider.value}};
                        }
                    }
                    if (code == .enter and textfield == null) {""")
replace('input.zig', '        const trigger_hit = dd.layout.contains(mx, my);', """        var trigger_hit = false;
        for (window.state.buttons.items) |button| if (button.id == dd.id) { trigger_hit = button.rect.contains(mx,my); break; };""")
for method in ('containsHandle','containsTrack'):
    replace('Components/Slider.zig', f'pub fn {method}(self: *const @This(), x: f32, y: f32) bool {{', f'pub fn {method}(self: *const @This(), x: f32, y: f32) bool {{\n    if (self.rect.clip) |c| {{ if (!c.contains(x,y)) return false; }}')
p=dst/'renderer/widgets/sliders.zig'
text=p.read_text();text=text.replace('if (slider.hovered)', 'if (slider.hovered or window.state.keyboard_focus_id == slider.id)');p.write_text(text)

# A Wayland dispatch can deliver several key presses while a result list is
# rebuilding. Queue them instead of overwriting the single last-event slot.
p=dst/'platforms/wayland.zig'; text=p.read_text()
text=text.replace('    last_key_event: ?input.KeyEvent = null,','    key_events: std.ArrayList(input.KeyEvent) = .empty,')
import re
text,n=re.subn(r'data.last_key_event = input.KeyEvent\{(.*?)\n(\s*)\};',r'data.key_events.append(data.allocator, input.KeyEvent{\1\n\2}) catch {};',text,flags=re.S)
assert n==2
text=text.replace('                data.last_key_event = null;','')
text=text.replace('            if (self.last_key_event) |key_event| {\n                self.last_key_event = null;\n                return .{ .key_event = key_event };\n            }','            if (self.key_events.items.len > 0) return .{ .key_event = self.key_events.orderedRemove(0) };')
text=text.replace('        self.clipboard_text.deinit(self.allocator);','        self.clipboard_text.deinit(self.allocator);\n        self.key_events.deinit(self.allocator);')
p.write_text(text)
# setLayout replaces callback contexts. Refresh the registry before dispatching
# queued input against the new tree, rather than calling freed old contexts.
replace('window.zig','    State.beginFrame(&window.state, window.allocator);', '''    State.beginFrame(&window.state, window.allocator);
    if (window.state.layout_dirty) {
        @import("layout/engine.zig").performLayout(window) catch return null;
        window.state.layout_dirty = false;
        State.restoreFocusedTextField(&window.state);
    }''')
# Center the slider track in its allotted row; make the row a usable hit target.
replace('layout/instantiate.zig','            slider.rect.width = sl.layout.width;', '''            slider.rect.width = sl.layout.width;
            slider.rect.y = sl.layout.y + (sl.layout.height - slider.track_height) / 2;''')
replace('Components/Slider.zig','        y >= self.rect.y and\n        y <= self.rect.y + self.track_height;', '        y >= self.rect.y - 10 and\n        y <= self.rect.y + self.track_height + 10;')
# Do not remeasure explicitly sized expanding widgets with the leftover width.
replace('Widget/Row.zig', '    for (self.children.items) |*child| {\n        if (child.widget.isExpandingWidth()) {', '''    for (self.children.items) |*child| {
        if (child.constraint) |constraint| { if (constraint.portion != null or constraint.getFixed() != null) continue; }
        if (child.widget.isExpandingWidth()) {''')
# Modal overlays must not consume their parent's ordinary content height.
replace('Widget/Column.zig','    var used_height: f32 = self.padding * 2;', '    var modal_count: usize = 0;\n    var used_height: f32 = self.padding * 2;')
replace('Widget/Column.zig','        const child_widget = &child.widget;', '''        const child_widget = &child.widget;
        if (child_widget.* == .modal) {
            child_widget.setLayout(try child_widget.measureSize(allocator,inner_constraints,font_obj));
            modal_count += 1;
            continue;
        }''')
replace('Widget/Column.zig','    if (self.children.items.len > 1) {','    if (self.children.items.len - modal_count > 1) {')
replace('Widget/Column.zig','            self.children.items.len - 1,','            self.children.items.len - modal_count - 1,')
replace('Widget/Modal.zig', '''        constraints,
        font_obj,
    );''', '''        constraints.withMaxWidth(@min(640, constraints.max_width)).withMaxHeight(@max(1, constraints.max_height-32)),
        font_obj,
    );''')
replace('Widget/ScrollView.zig','id: u32 = 0,','id: u32 = 0,\nshrink: bool = false,')
replace('Widget/ScrollView.zig','        .height = constraints.max_height,','        .height = if (self.shrink) @min(constraints.max_height,child_size.height) else constraints.max_height,')
# Traversal stays inside a modal, including controls below its scroll viewport.
p=dst/'input.zig'; text=p.read_text()
text=text.replace('list:*[1024]FocusCandidate,count:*usize) void {','list:*[1024]FocusCandidate,count:*usize,in_modal:bool) void {')
text=text.replace('collectFocus(window,&child.widget,list,count)','collectFocus(window,&child.widget,list,count,in_modal)')
text=text.replace('.scrollview=>|*w| collectFocus(window,w.child,list,count)', '.scrollview=>|*w| collectFocus(window,w.child,list,count,in_modal)')
text=text.replace('.modal=>|*w| collectFocus(window,w.child,list,count)', '.modal=>|*w| collectFocus(window,w.child,list,count,true)')
text=text.replace('if(count.*==list.len or !isInteractionAllowed(window,w.layout.x,w.layout.y)) return;', 'if(count.*==list.len or (window.state.modals.items.len>0 and !in_modal)) return;')
text=text.replace('collectFocus(window,root,&list,&count);','collectFocus(window,root,&list,&count,false);')
p.write_text(text)

# Offer every physical key (including modifiers, function and media keys) to the
# application's recorder before normal text handling or local shortcuts.
replace('platforms/wayland.zig', '        .key => |ev| {', '''        .key => |ev| {
            if (aq_shortcut_key(@ptrCast(data.xkb_state), ev.key, ev.state == .pressed) != 0) return;''')
p=dst/'platforms/wayland.zig'
p.write_text(p.read_text()+'\nextern fn aq_shortcut_key(state: ?*anyopaque, key: u32, down: bool) c_int;\n')
