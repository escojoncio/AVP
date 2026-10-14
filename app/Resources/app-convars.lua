-- app-convars.lua: the convars file bundled in the app (tools/alyx-test/build-tf.sh). It sets NOTHING: the demo's
-- render settings reach the game as defaults through the files the app writes when missing (hlvr/cfg/deckard/video2.txt,
-- the game's own saved video settings, and the fixed fidelity table), so whatever a player then changes in Options is the
-- game's to keep. On a fresh install those give exactly FIX-demo-convars.lua's values at spawn (Mac, a1_intro_world,
-- 2026-10-03), which test scripts still push to force them. This only reads them back for a pulled log: KLCV, KLTAB,
-- KLSTREAM at each spawn.
ListenToGameEvent("player_activate", function()
  local w = Entities:First()
  if w then w:SetThink(function()
    local out = {}
    for _, k in ipairs({ "r_texturefilteringquality", "r_texture_stream_max_resolution", "volume_fog_width", "vr_aoproxy_enable",
        "r_high_quality_shadows", "vr_fidelity_level", "vr_render_target_scale" }) do out[#out + 1] = k .. "=" .. tostring(Convars:GetStr(k)) end
    Msg("KLCV " .. table.concat(out, " ") .. "\n")
    local tab = {}
    for _, k in ipairs({ "vr_msaa", "r_ssao", "r_post_bloom", "r_high_quality_shadows", "sc_disable_spotlight_shadows",
        "vr_single_light_fast_path_sun_cascade_0_texels_per_world", "vr_single_light_fast_path_sun_cascade_1_texels_per_world",
        "vr_aoproxy_enable", "vr_character_level_placeholder", "cl_enable_eye_occlusion" }) do tab[#tab + 1] = k .. "=" .. tostring(Convars:GetStr(k)) end
    Msg("KLTAB " .. table.concat(tab, " ") .. "\n")
    return nil end, "klhi", 2.0) end
end, nil)

-- Print the texture-streaming convars' current values (defaults under our video settings) at the first spawn.
ListenToGameEvent("player_activate", function()
  local w = Entities:First(); if not w then return end
  w:SetThink(function()
    for _, k in ipairs({ "r_texture_stream_max_resolution", "r_texture_stream_mip_bias", "r_texture_stream_resolution_bias",
        "r_texture_stream_resolution_bias_decrease_rate", "r_texture_stream_resolution_bias_increase_rate",
        "r_texture_stream_resolution_bias_min", "r_texture_stream_resolution_bias_update_period",
        "r_texture_stream_throttle_amount", "r_texture_stream_throttle_count", "gpu_mem_level", "mem_level" }) do
      Msg("KLSTREAM " .. k .. " = " .. tostring(Convars:GetStr(k)) .. "\n")
    end
    return nil end, "klstream", 2.0)
end, nil)

-- AVP build 27: which performance convars this build has, and their values at spawn (KLPERF; "nil" = not a convar
-- here). The next cuts of fixed GPU cost (shadow atlas, fog volume, Panorama effects) are picked from this list.
ListenToGameEvent("player_activate", function()
  local w = Entities:First(); if not w then return end
  w:SetThink(function()
    local out = {}
    for _, k in ipairs({ "r_ssao", "r_post_bloom", "sc_disable_spotlight_shadows", "r_high_quality_shadows",
        "vr_shadow_map_culling", "vr_enable_cached_lights", "vr_shadow_level_placeholder", "vr_enable_volume_fog",
        "volume_fog_enable_stereo", "volume_fog_width", "volume_fog_height", "volume_fog_depth", "vr_depth_prepass",
        "vr_stencil_hidden_pixels", "vr_multiview_instancing", "vr_character_level_placeholder", "cl_enable_eye_occlusion",
        "r_particle_max_detail_level", "cl_particle_fallback_base", "cl_particle_fallback_multiplier", "vr_fast_hologram",
        "r_light_flickering_enabled", "lb_shadow_texture_width_override", "lb_shadow_texture_height_override",
        "lb_enable_shadow_casting", "csm_max_num_cascades_override", "@panorama_max_fps", "@panorama_max_overlay_fps",
        "@panorama_experimental_fast_box_shadow", "@panorama_disable_box_shadow", "@panorama_disable_blur",
        "vr_perf_mode_override2", "vr_fidelity_level", "vr_msaa",
        -- build 31: culling and LOD state (read only; answers "is occlusion / per-draw culling on?")
        "r_occlusion_culling", "sc_perdrawculling", "sc_bounds_group_cull", "sc_no_cull", "vr_expand_cull_frustum",
        "r_size_cull_threshold", "r_size_cull_threshold_shadow", "r_worldlod", "sc_force_lod_level",
        "sc_lod_distance_scale_override", "r_stereo_true_multiview", "r_stereo_multiview_instancing" }) do
      local ok, v = pcall(Convars.GetStr, Convars, k)
      out[#out + 1] = k .. "=" .. ((ok and v ~= nil) and tostring(v) or "nil")
      if #out == 12 then Msg("KLPERF " .. table.concat(out, " ") .. "\n"); out = {} end   -- short console lines
    end
    if #out > 0 then Msg("KLPERF " .. table.concat(out, " ") .. "\n") end
    return nil end, "klperf", 3.0)
end, nil)
