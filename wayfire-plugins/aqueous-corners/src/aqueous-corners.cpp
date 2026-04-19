#include <wayfire/plugin.hpp>
#include <wayfire/signal-definitions.hpp>
#include <wayfire/scene.hpp>
#include <wayfire/scene-render.hpp>
#include <wayfire/core.hpp>
#include <wayfire/view.hpp>
#include <wayfire/toplevel-view.hpp>
#include <wayfire/option-wrapper.hpp>
#include <wayfire/render.hpp>
#include <wayfire/nonstd/wlroots-full.hpp>
#include <drm_fourcc.h>

#include <cmath>
#include <cstring>
#include <map>
#include <vector>
#include <memory>

namespace wf
{
namespace aqueous_corners
{

static std::vector<uint8_t> generate_corner_mask(int radius, float r, float g, float b, float a)
{
    std::vector<uint8_t> pixels(radius * radius * 4, 0);
    uint8_t cr = (uint8_t)(r * 255.0f);
    uint8_t cg = (uint8_t)(g * 255.0f);
    uint8_t cb = (uint8_t)(b * 255.0f);

    for (int y = 0; y < radius; y++)
    {
        for (int x = 0; x < radius; x++)
        {
            float dx = (float)(radius - x) - 0.5f;
            float dy = (float)(radius - y) - 0.5f;
            float dist = std::sqrt(dx * dx + dy * dy);

            float alpha_factor = 0.0f;
            if (dist > (float)radius + 0.5f)
                alpha_factor = 1.0f;
            else if (dist > (float)radius - 0.5f)
                alpha_factor = dist - ((float)radius - 0.5f);

            uint8_t ca = (uint8_t)(a * alpha_factor * 255.0f);
            int idx = (y * radius + x) * 4;
            pixels[idx + 0] = cb;
            pixels[idx + 1] = cg;
            pixels[idx + 2] = cr;
            pixels[idx + 3] = ca;
        }
    }

    return pixels;
}

static std::vector<uint8_t> flip_h(const std::vector<uint8_t>& src, int radius)
{
    std::vector<uint8_t> dst(src.size());
    for (int y = 0; y < radius; y++)
        for (int x = 0; x < radius; x++)
        {
            int si = (y * radius + x) * 4;
            int di = (y * radius + (radius - 1 - x)) * 4;
            std::memcpy(&dst[di], &src[si], 4);
        }
    return dst;
}

static std::vector<uint8_t> flip_v(const std::vector<uint8_t>& src, int radius)
{
    std::vector<uint8_t> dst(src.size());
    for (int y = 0; y < radius; y++)
        for (int x = 0; x < radius; x++)
        {
            int si = (y * radius + x) * 4;
            int di = ((radius - 1 - y) * radius + x) * 4;
            std::memcpy(&dst[di], &src[si], 4);
        }
    return dst;
}

class corner_overlay_node_t : public wf::scene::floating_inner_node_t
{
  public:
    wayfire_view view;
    wlr_texture *textures[4] = {nullptr, nullptr, nullptr, nullptr};
    int radius = 0;

    corner_overlay_node_t(wayfire_view view) :
        floating_inner_node_t(false),
        view(view)
    {}

    ~corner_overlay_node_t()
    {
        destroy_textures();
    }

    void destroy_textures()
    {
        for (int i = 0; i < 4; i++)
        {
            if (textures[i])
            {
                wlr_texture_destroy(textures[i]);
                textures[i] = nullptr;
            }
        }
    }

    void generate_textures(int new_radius, float r, float g, float b, float a)
    {
        destroy_textures();
        radius = new_radius;
        if (radius <= 0) return;

        auto renderer = wf::get_core().renderer;
        auto tl_pixels = generate_corner_mask(radius, r, g, b, a);
        auto tr_pixels = flip_h(tl_pixels, radius);
        auto bl_pixels = flip_v(tl_pixels, radius);
        auto br_pixels = flip_v(tr_pixels, radius);

        uint32_t fmt = DRM_FORMAT_ARGB8888;
        uint32_t stride = radius * 4;

        textures[0] = wlr_texture_from_pixels(renderer, fmt, stride, radius, radius, tl_pixels.data());
        textures[1] = wlr_texture_from_pixels(renderer, fmt, stride, radius, radius, tr_pixels.data());
        textures[2] = wlr_texture_from_pixels(renderer, fmt, stride, radius, radius, bl_pixels.data());
        textures[3] = wlr_texture_from_pixels(renderer, fmt, stride, radius, radius, br_pixels.data());
    }

    wf::geometry_t get_bounding_box() override
    {
        if (!view || !view->is_mapped()) return {0, 0, 0, 0};
        auto toplevel = wf::toplevel_cast(view);
        if (toplevel)
        {
            auto geom = toplevel->get_geometry();
            auto bbox = view->get_bounding_box();
            return {geom.x - bbox.x, geom.y - bbox.y, geom.width, geom.height};
        }
        return {0, 0, view->get_bounding_box().width, view->get_bounding_box().height};
    }

    std::string stringify() const override
    {
        return "aqueous-corner-overlay";
    }

    void gen_render_instances(
        std::vector<wf::scene::render_instance_uptr>& instances,
        wf::scene::damage_callback push_damage,
        wf::output_t *output) override;
};

class corner_render_instance_t : public wf::scene::render_instance_t
{
    std::shared_ptr<corner_overlay_node_t> self;
    wf::scene::damage_callback push_damage;
    wf::signal::connection_t<wf::scene::node_damage_signal> on_damage;

  public:
    corner_render_instance_t(corner_overlay_node_t *node,
        wf::scene::damage_callback push_damage, wf::output_t*)
    {
        this->self = std::dynamic_pointer_cast<corner_overlay_node_t>(
            node->shared_from_this());
        this->push_damage = push_damage;
        on_damage = [this] (wf::scene::node_damage_signal *ev)
        {
            this->push_damage(ev->region);
        };
        node->connect(&on_damage);
    }

    void schedule_instructions(
        std::vector<wf::scene::render_instruction_t>& instructions,
        const wf::render_target_t& target,
        wf::region_t& damage) override
    {
        auto toplevel = wf::toplevel_cast(self->view);
        wf::geometry_t global_bbox = toplevel ? toplevel->get_geometry() : self->view->get_bounding_box();
        
        auto our_damage = damage & global_bbox;
        if (!our_damage.empty())
        {
            instructions.push_back(wf::scene::render_instruction_t{
                .instance = this,
                .target = target,
                .damage = our_damage,
            });
        }
    }

    void render(const wf::scene::render_instruction_t& data) override
    {
        if (!self->view || !self->view->is_mapped() || self->radius <= 0)
            return;

        auto toplevel = wf::toplevel_cast(self->view);
        wf::geometry_t bbox = toplevel ? toplevel->get_geometry() : self->view->get_bounding_box();
        int r = self->radius;

        wf::geometry_t positions[4] = {
            {bbox.x, bbox.y, r, r},
            {bbox.x + bbox.width - r, bbox.y, r, r},
            {bbox.x, bbox.y + bbox.height - r, r, r},
            {bbox.x + bbox.width - r, bbox.y + bbox.height - r, r, r},
        };

        auto pass = data.pass->get_wlr_pass();
        wlr_fbox src_box = {0, 0, (double)r, (double)r};

        for (int i = 0; i < 4; i++)
        {
            if (!self->textures[i]) continue;

            auto fb_box = data.target.framebuffer_box_from_geometry_box(
                wlr_fbox{(double)positions[i].x, (double)positions[i].y,
                          (double)positions[i].width, (double)positions[i].height});

            wlr_box dst = {
                (int)fb_box.x, (int)fb_box.y,
                (int)fb_box.width, (int)fb_box.height
            };

            auto clip = data.damage & positions[i];

            wlr_render_texture_options opts = {};
            opts.texture = self->textures[i];
            opts.src_box = src_box;
            opts.dst_box = dst;
            opts.clip = clip.to_pixman();
            opts.filter_mode = WLR_SCALE_FILTER_BILINEAR;
            opts.blend_mode = WLR_RENDER_BLEND_MODE_PREMULTIPLIED;

            wlr_render_pass_add_texture(pass, &opts);
        }
    }
};

void corner_overlay_node_t::gen_render_instances(
    std::vector<wf::scene::render_instance_uptr>& instances,
    wf::scene::damage_callback push_damage,
    wf::output_t *output)
{
    instances.push_back(std::make_unique<corner_render_instance_t>(
        this, push_damage, output));
}

class aqueous_corners_t : public wf::plugin_interface_t
{
    wf::option_wrapper_t<int> corner_radius{"aqueous-corners/corner_radius"};
    wf::option_wrapper_t<wf::color_t> corner_color{"aqueous-corners/corner_color"};
    wf::option_wrapper_t<bool> enabled{"aqueous-corners/enabled"};
    wf::option_wrapper_t<bool> exclude_maximized{"aqueous-corners/exclude_maximized"};

    wf::signal::connection_t<wf::view_mapped_signal> on_view_mapped;
    wf::signal::connection_t<wf::view_unmapped_signal> on_view_unmapped;

    std::map<uint32_t, std::shared_ptr<corner_overlay_node_t>> overlays;
    std::map<uint32_t, bool> excluded_views;


  public:
    void init() override
    {

        on_view_mapped = [this] (wf::view_mapped_signal *ev)
        {
            if (ev->view->role == wf::VIEW_ROLE_TOPLEVEL && (bool)enabled)
                attach_overlay(ev->view);
        };

        on_view_unmapped = [this] (wf::view_unmapped_signal *ev)
        {
            detach_overlay(ev->view);
        };

        wf::get_core().connect(&on_view_mapped);
        wf::get_core().connect(&on_view_unmapped);

        corner_radius.set_callback([this] () { regenerate_all_textures(); });
        corner_color.set_callback([this] () { regenerate_all_textures(); });
        enabled.set_callback([this] ()
        {
            if ((bool)enabled)
            {
                for (auto& view : wf::get_core().get_all_views())
                {
                    if (view->role == wf::VIEW_ROLE_TOPLEVEL && view->is_mapped())
                        attach_overlay(view);
                }
            }
            else
            {
                detach_all();
            }
        });

        if ((bool)enabled)
        {
            for (auto& view : wf::get_core().get_all_views())
            {
                if (view->role == wf::VIEW_ROLE_TOPLEVEL && view->is_mapped())
                    attach_overlay(view);
            }
        }
    }

    void fini() override
    {
        detach_all();
        on_view_mapped.disconnect();
        on_view_unmapped.disconnect();
    }

    bool should_skip_view(wayfire_view view)
    {
        if (!view) return true;

        auto id = view->get_id();
        if (excluded_views.count(id)) return true;

        if (exclude_maximized)
        {
            auto toplevel = wf::toplevel_cast(view);
            if (toplevel)
            {
                if (toplevel->pending_fullscreen())
                    return true;
                if (toplevel->pending_tiled_edges() == (uint32_t)0xF)
                    return true;
            }
        }

        return false;
    }

    void attach_overlay(wayfire_view view)
    {
        if (should_skip_view(view)) return;

        auto id = view->get_id();
        if (overlays.count(id)) return;

        auto node = std::make_shared<corner_overlay_node_t>(view);
        auto color = (wf::color_t)corner_color;
        node->generate_textures(corner_radius, color.r, color.g, color.b, color.a);

        auto root = view->get_root_node();
        auto children = root->get_children();
        children.push_back(node);
        root->set_children_list(children);

        overlays[id] = node;
    }

    void detach_overlay(wayfire_view view)
    {
        if (!view) return;
        auto id = view->get_id();
        auto it = overlays.find(id);
        if (it == overlays.end()) return;

        auto root = view->get_root_node();
        auto children = root->get_children();
        children.erase(
            std::remove_if(children.begin(), children.end(),
                [&](auto& c) { return c.get() == it->second.get(); }),
            children.end());
        root->set_children_list(children);

        overlays.erase(it);
    }

    void detach_all()
    {
        for (auto& view : wf::get_core().get_all_views())
        {
            auto id = view->get_id();
            if (overlays.count(id))
                detach_overlay(view);
        }

        overlays.clear();
    }

    void regenerate_all_textures()
    {
        auto color = (wf::color_t)corner_color;
        for (auto& [id, node] : overlays)
        {
            node->generate_textures(corner_radius, color.r, color.g, color.b, color.a);
            wf::scene::node_damage_signal ev;
            ev.region |= node->get_bounding_box();
            node->emit(&ev);
        }
    }

};

} // namespace aqueous_corners
} // namespace wf

DECLARE_WAYFIRE_PLUGIN(wf::aqueous_corners::aqueous_corners_t);
