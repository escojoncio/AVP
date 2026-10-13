// kl_vk_census.inc — the Vulkan census (KL_VK_CENSUS=1, on by default in the visionOS app).
//
// What the guest actually asks of Vulkan, written to the log once per distinct item, as the input
// to finishing VPEngine (AVP PLAN.md §5.1): API versions, instance and device extensions, every pNext
// struct of VkDeviceCreateInfo with the feature booleans it turns on, every features2 query, descriptor
// set layouts (types, counts, binding flags), push constant ranges, pipelines (sample counts, dynamic
// states, attachment formats, resolve modes), render passes and dynamic rendering, query pools,
// semaphore types, vkQueueSubmit2, image create parameters, samplers, and per shader module its SPIR-V
// capabilities, extensions, 16/64-bit types, multisampled image reads, subgroup ops and dynamic indexing
// into descriptor arrays. Every 600 guest frames a "[census] summary" line.
//
// Included by kl_vulkan.c (it shares its statics: real_gdpa, mvk_sym, kl_env_on). Every line starts
// "[census]" so a log grep gives the whole census. Lines are deduplicated by a 64-bit hash of their text
// (a set of up to 64K distinct lines; past that every line is printed, which a game never reaches).
#include <stddef.h>
#include "kl_vk_census_tables.h"

static int census_on(void) {
    static int on = -1;
    if (on < 0) on = kl_env_on("KL_VK_CENSUS", 0);
    return on;
}

// ---- the dedupe set ------------------------------------------------------------------------------
enum { KLC_SLOTS = 1 << 16 };
static uint64_t g_klc_seen[KLC_SLOTS];
static pthread_mutex_t g_klc_mu = PTHREAD_MUTEX_INITIALIZER;
static _Atomic unsigned g_klc_lines;
static uint64_t klc_hash(const char *s) {
    uint64_t h = 1469598103934665603ULL;
    for (; *s; s++) h = (h ^ (unsigned char)*s) * 1099511628211ULL;
    return h ? h : 1;
}
// 1 when the line is new (and records it).
static int klc_first(const char *line) {
    uint64_t h = klc_hash(line);
    pthread_mutex_lock(&g_klc_mu);
    uint32_t i = (uint32_t)(h ^ (h >> 32)) & (KLC_SLOTS - 1);
    int fresh = 1;
    for (unsigned probe = 0; probe < KLC_SLOTS; probe++, i = (i + 1) & (KLC_SLOTS - 1)) {
        if (g_klc_seen[i] == h) { fresh = 0; break; }
        if (!g_klc_seen[i]) { g_klc_seen[i] = h; break; }
    }
    pthread_mutex_unlock(&g_klc_mu);
    return fresh;
}
static void klc_emit(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void klc_emit(const char *fmt, ...) {
    char line[2048];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(line, sizeof line, fmt, ap);
    va_end(ap);
    if (!klc_first(line)) return;
    g_klc_lines++;
    fprintf(stderr, "[census] %s\n", line);
}

// ---- running counters for the summary line -------------------------------------------------------
static _Atomic unsigned g_klc_modules, g_klc_gpipes, g_klc_cpipes, g_klc_layouts, g_klc_images, g_klc_samplers,
                        g_klc_rpasses, g_klc_submit2, g_klc_timeline, g_klc_qpools, g_klc_dynidx, g_klc_bindless;

// A small string builder.
typedef struct { char b[1900]; size_t n; } klc_sb;
static void sb_add(klc_sb *s, const char *fmt, ...) __attribute__((format(printf, 2, 3)));
static void sb_add(klc_sb *s, const char *fmt, ...) {
    if (s->n >= sizeof s->b - 1) return;
    va_list ap;
    va_start(ap, fmt);
    int w = vsnprintf(s->b + s->n, sizeof s->b - s->n, fmt, ap);
    va_end(ap);
    if (w > 0) s->n += (size_t)w;
    if (s->n >= sizeof s->b) s->n = sizeof s->b - 1;
}

static const klc_struct *klc_find(VkStructureType st) {
    for (const klc_struct *k = klc_structs; k->name; k++)
        if (k->stype == st) return k;
    return NULL;
}

// One feature struct's VK_TRUE booleans: "<Struct>: a b c" (or "(none)").
static void klc_feature_struct(const char *what, const VkBaseInStructure *b) {
    const klc_struct *k = klc_find(b->sType);
    klc_sb s = {{0}, 0};
    if (!k) {
        klc_emit("%s pNext sType %d (not a known feature struct)", what, (int)b->sType);
        return;
    }
    unsigned on = 0;
    for (unsigned i = 0; i < k->nbools; i++)
        if (*(const VkBool32 *)((const char *)b + k->bools[i].off)) { sb_add(&s, " %s", k->bools[i].name); on++; }
    klc_emit("%s %s:%s", what, k->name, on ? s.b : " (none true)");
}
static void klc_base_feature_list(const char *what, const VkPhysicalDeviceFeatures *f) {
    klc_sb s = {{0}, 0};
    unsigned on = 0;
    for (size_t i = 0; i < sizeof klc_base_features / sizeof *klc_base_features; i++)
        if (*(const VkBool32 *)((const char *)f + klc_base_features[i].off)) { sb_add(&s, " %s", klc_base_features[i].name); on++; }
    klc_emit("%s VkPhysicalDeviceFeatures:%s", what, on ? s.b : " (none true)");
}

// ---- instance / device -----------------------------------------------------------------------------
static void klc_version(const char *what, uint32_t v) {
    klc_emit("%s apiVersion %u.%u.%u", what, VK_API_VERSION_MAJOR(v), VK_API_VERSION_MINOR(v), VK_API_VERSION_PATCH(v));
}
static void census_instance(const VkInstanceCreateInfo *ci) {
    if (!census_on() || !ci) return;
    klc_version("instance", ci->pApplicationInfo ? ci->pApplicationInfo->apiVersion : VK_API_VERSION_1_0);
    if (ci->pApplicationInfo)
        klc_emit("instance application '%s' v%u engine '%s' v%u",
                 ci->pApplicationInfo->pApplicationName ? ci->pApplicationInfo->pApplicationName : "",
                 ci->pApplicationInfo->applicationVersion,
                 ci->pApplicationInfo->pEngineName ? ci->pApplicationInfo->pEngineName : "",
                 ci->pApplicationInfo->engineVersion);
    for (uint32_t i = 0; i < ci->enabledExtensionCount; i++) klc_emit("instance extension %s", ci->ppEnabledExtensionNames[i]);
    for (uint32_t i = 0; i < ci->enabledLayerCount; i++) klc_emit("instance layer %s", ci->ppEnabledLayerNames[i]);
    for (const VkBaseInStructure *b = ci->pNext; b; b = b->pNext) klc_emit("instance pNext sType %d", (int)b->sType);
}
static void census_device(VkPhysicalDevice phys, const VkDeviceCreateInfo *ci) {
    if (!census_on() || !ci) return;
    if (phys && real_gipa) {
        PFN_vkGetPhysicalDeviceProperties gp =
            (PFN_vkGetPhysicalDeviceProperties)real_gipa(g_instance, "vkGetPhysicalDeviceProperties");
        if (gp) {
            VkPhysicalDeviceProperties p;
            gp(phys, &p);
            klc_emit("driver '%s' apiVersion %u.%u.%u driverVersion %#x vendor %#x device %#x", p.deviceName,
                     VK_API_VERSION_MAJOR(p.apiVersion), VK_API_VERSION_MINOR(p.apiVersion),
                     VK_API_VERSION_PATCH(p.apiVersion), p.driverVersion, p.vendorID, p.deviceID);
        }
    }
    for (uint32_t i = 0; i < ci->enabledExtensionCount; i++) klc_emit("device extension %s", ci->ppEnabledExtensionNames[i]);
    for (uint32_t i = 0; i < ci->queueCreateInfoCount; i++)
        klc_emit("device queue family %u x%u", ci->pQueueCreateInfos[i].queueFamilyIndex, ci->pQueueCreateInfos[i].queueCount);
    if (ci->pEnabledFeatures) klc_base_feature_list("device features", ci->pEnabledFeatures);
    for (const VkBaseInStructure *b = ci->pNext; b; b = b->pNext) {
        if (b->sType == VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2) {
            klc_base_feature_list("device features2", &((const VkPhysicalDeviceFeatures2 *)b)->features);
            continue;
        }
        klc_emit("device pNext sType %d%s", (int)b->sType, klc_find(b->sType) ? "" : " (unknown to the census)");
        if (klc_find(b->sType)) klc_feature_struct("device enables", b);
    }
}
static void census_features2_query(const VkPhysicalDeviceFeatures2 *f) {
    if (!census_on() || !f) return;
    klc_emit("features2 query: VkPhysicalDeviceFeatures2");
    for (const VkBaseInStructure *b = f->pNext; b; b = b->pNext) {
        const klc_struct *k = klc_find(b->sType);
        klc_emit("features2 query: %s", k ? k->name : "unknown sType");
        if (!k) klc_emit("features2 query sType %d", (int)b->sType);
    }
}
static void census_properties2_query(const VkPhysicalDeviceProperties2 *p) {
    if (!census_on() || !p) return;
    for (const VkBaseInStructure *b = p->pNext; b; b = b->pNext) klc_emit("properties2 query sType %d", (int)b->sType);
}

// ---- descriptors and layouts -------------------------------------------------------------------------
static void census_set_layout(const VkDescriptorSetLayoutCreateInfo *ci) {
    if (!census_on() || !ci) return;
    g_klc_layouts++;
    const VkDescriptorSetLayoutBindingFlagsCreateInfo *bf = NULL;
    for (const VkBaseInStructure *b = ci->pNext; b; b = b->pNext)
        if (b->sType == VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_BINDING_FLAGS_CREATE_INFO)
            bf = (const VkDescriptorSetLayoutBindingFlagsCreateInfo *)b;
    if (ci->flags) klc_emit("set layout flags %#x%s%s", ci->flags,
                            (ci->flags & VK_DESCRIPTOR_SET_LAYOUT_CREATE_UPDATE_AFTER_BIND_POOL_BIT) ? " update-after-bind-pool" : "",
                            (ci->flags & 0x1u) ? " push-descriptor" : "");
    for (uint32_t i = 0; i < ci->bindingCount; i++) {
        const VkDescriptorSetLayoutBinding *b = &ci->pBindings[i];
        VkDescriptorBindingFlags fl = bf && i < bf->bindingCount ? bf->pBindingFlags[i] : 0;
        // Counts above 64 are bucketed: the census wants the shape, not every array size.
        uint32_t c = b->descriptorCount;
        uint32_t bucket = c <= 64 ? c : c <= 1024 ? 1024 : c <= 16384 ? 16384 : 1u << 20;
        if (c > 64 || (fl & (VK_DESCRIPTOR_BINDING_VARIABLE_DESCRIPTOR_COUNT_BIT | VK_DESCRIPTOR_BINDING_PARTIALLY_BOUND_BIT)))
            g_klc_bindless++;
        klc_emit("set binding type %d count %s%u stages %#x immutable-samplers %d flags%s%s%s%s",
                 (int)b->descriptorType, c > 64 ? "<=" : "", bucket, b->stageFlags, b->pImmutableSamplers != NULL,
                 (fl & VK_DESCRIPTOR_BINDING_UPDATE_AFTER_BIND_BIT) ? " update-after-bind" : "",
                 (fl & VK_DESCRIPTOR_BINDING_UPDATE_UNUSED_WHILE_PENDING_BIT) ? " update-unused-while-pending" : "",
                 (fl & VK_DESCRIPTOR_BINDING_PARTIALLY_BOUND_BIT) ? " partially-bound" : "",
                 (fl & VK_DESCRIPTOR_BINDING_VARIABLE_DESCRIPTOR_COUNT_BIT) ? " variable-count" : "");
    }
}
static void census_pipeline_layout(const VkPipelineLayoutCreateInfo *ci) {
    if (!census_on() || !ci) return;
    klc_emit("pipeline layout with %u set(s)", ci->setLayoutCount);
    for (uint32_t i = 0; i < ci->pushConstantRangeCount; i++)
        klc_emit("push constant range stages %#x offset %u size %u", ci->pPushConstantRanges[i].stageFlags,
                 ci->pPushConstantRanges[i].offset, ci->pPushConstantRanges[i].size);
}
static void census_descriptor_pool(const VkDescriptorPoolCreateInfo *ci) {
    if (!census_on() || !ci) return;
    klc_emit("descriptor pool flags %#x%s", ci->flags,
             (ci->flags & VK_DESCRIPTOR_POOL_CREATE_UPDATE_AFTER_BIND_BIT) ? " update-after-bind" : "");
    for (uint32_t i = 0; i < ci->poolSizeCount; i++) klc_emit("descriptor pool type %d", (int)ci->pPoolSizes[i].type);
}

// ---- render passes ----------------------------------------------------------------------------------------
static void census_render_pass(const VkRenderPassCreateInfo *ci) {
    if (!census_on() || !ci) return;
    g_klc_rpasses++;
    for (uint32_t i = 0; i < ci->attachmentCount; i++) {
        const VkAttachmentDescription *a = &ci->pAttachments[i];
        klc_emit("render pass attachment format %d samples %d load %d store %d stencil-load %d stencil-store %d",
                 (int)a->format, (int)a->samples, (int)a->loadOp, (int)a->storeOp, (int)a->stencilLoadOp, (int)a->stencilStoreOp);
    }
    for (uint32_t s = 0; s < ci->subpassCount; s++) {
        const VkSubpassDescription *sp = &ci->pSubpasses[s];
        klc_emit("render pass subpass colors %u inputs %u resolves %d depth %d preserve %u", sp->colorAttachmentCount,
                 sp->inputAttachmentCount, sp->pResolveAttachments != NULL, sp->pDepthStencilAttachment != NULL,
                 sp->preserveAttachmentCount);
    }
    if (ci->subpassCount > 1) klc_emit("render pass with %u subpasses, %u dependencies", ci->subpassCount, ci->dependencyCount);
    for (const VkBaseInStructure *b = ci->pNext; b; b = b->pNext) klc_emit("render pass pNext sType %d", (int)b->sType);
}
static void census_render_pass2(const VkRenderPassCreateInfo2 *ci) {
    if (!census_on() || !ci) return;
    g_klc_rpasses++;
    for (uint32_t i = 0; i < ci->attachmentCount; i++) {
        const VkAttachmentDescription2 *a = &ci->pAttachments[i];
        klc_emit("render pass2 attachment format %d samples %d load %d store %d stencil-load %d stencil-store %d",
                 (int)a->format, (int)a->samples, (int)a->loadOp, (int)a->storeOp, (int)a->stencilLoadOp, (int)a->stencilStoreOp);
    }
    for (uint32_t s = 0; s < ci->subpassCount; s++) {
        const VkSubpassDescription2 *sp = &ci->pSubpasses[s];
        klc_emit("render pass2 subpass colors %u inputs %u resolves %d depth %d viewMask %#x", sp->colorAttachmentCount,
                 sp->inputAttachmentCount, sp->pResolveAttachments != NULL, sp->pDepthStencilAttachment != NULL, sp->viewMask);
        for (const VkBaseInStructure *b = sp->pNext; b; b = b->pNext) {
            if (b->sType == VK_STRUCTURE_TYPE_SUBPASS_DESCRIPTION_DEPTH_STENCIL_RESOLVE) {
                const VkSubpassDescriptionDepthStencilResolve *r = (const void *)b;
                klc_emit("render pass2 depth/stencil resolve depth-mode %#x stencil-mode %#x attachment %d",
                         r->depthResolveMode, r->stencilResolveMode, r->pDepthStencilResolveAttachment != NULL);
            } else klc_emit("render pass2 subpass pNext sType %d", (int)b->sType);
        }
    }
    if (ci->subpassCount > 1) klc_emit("render pass2 with %u subpasses, %u dependencies", ci->subpassCount, ci->dependencyCount);
    if (ci->correlatedViewMaskCount) klc_emit("render pass2 correlated view masks %u", ci->correlatedViewMaskCount);
    for (const VkBaseInStructure *b = ci->pNext; b; b = b->pNext) klc_emit("render pass2 pNext sType %d", (int)b->sType);
}
static void census_begin_rendering(const VkRenderingInfo *ri) {
    if (!census_on() || !ri) return;
    klc_sb s = {{0}, 0};
    for (uint32_t i = 0; i < ri->colorAttachmentCount; i++) {
        const VkRenderingAttachmentInfo *a = &ri->pColorAttachments[i];
        sb_add(&s, " c%u[load %d store %d resolve %#x]", i, (int)a->loadOp, (int)a->storeOp, (unsigned)a->resolveMode);
    }
    if (ri->pDepthAttachment && ri->pDepthAttachment->imageView)
        sb_add(&s, " depth[load %d store %d resolve %#x]", (int)ri->pDepthAttachment->loadOp,
               (int)ri->pDepthAttachment->storeOp, (unsigned)ri->pDepthAttachment->resolveMode);
    if (ri->pStencilAttachment && ri->pStencilAttachment->imageView)
        sb_add(&s, " stencil[load %d store %d resolve %#x]", (int)ri->pStencilAttachment->loadOp,
               (int)ri->pStencilAttachment->storeOp, (unsigned)ri->pStencilAttachment->resolveMode);
    klc_emit("dynamic rendering flags %#x layers %u viewMask %#x:%s", ri->flags, ri->layerCount, ri->viewMask, s.b);
    for (const VkBaseInStructure *b = ri->pNext; b; b = b->pNext) klc_emit("dynamic rendering pNext sType %d", (int)b->sType);
}

// ---- pipelines ------------------------------------------------------------------------------------------------
static void census_graphics_pipeline(const VkGraphicsPipelineCreateInfo *ci) {
    if (!census_on() || !ci) return;
    g_klc_gpipes++;
    if (ci->pMultisampleState)
        klc_emit("pipeline MSAA samples %d sample-shading %d min %.2f alpha-to-coverage %d",
                 (int)ci->pMultisampleState->rasterizationSamples, ci->pMultisampleState->sampleShadingEnable,
                 ci->pMultisampleState->minSampleShading, ci->pMultisampleState->alphaToCoverageEnable);
    if (ci->pDynamicState)
        for (uint32_t i = 0; i < ci->pDynamicState->dynamicStateCount; i++)
            klc_emit("pipeline dynamic state %d", (int)ci->pDynamicState->pDynamicStates[i]);
    if (ci->pTessellationState) klc_emit("pipeline tessellation patch %u", ci->pTessellationState->patchControlPoints);
    for (uint32_t i = 0; i < ci->stageCount; i++) {
        klc_emit("pipeline stage %#x", ci->pStages[i].stage);
        if (ci->pStages[i].pSpecializationInfo) klc_emit("pipeline specialization constants used");
        for (const VkBaseInStructure *b = ci->pStages[i].pNext; b; b = b->pNext)
            klc_emit("pipeline stage pNext sType %d", (int)b->sType);
    }
    if (ci->pRasterizationState) {
        klc_emit("pipeline raster polygon %d cull %#x depth-clamp %d depth-bias %d discard %d",
                 (int)ci->pRasterizationState->polygonMode, ci->pRasterizationState->cullMode,
                 ci->pRasterizationState->depthClampEnable, ci->pRasterizationState->depthBiasEnable,
                 ci->pRasterizationState->rasterizerDiscardEnable);
        for (const VkBaseInStructure *b = ci->pRasterizationState->pNext; b; b = b->pNext)
            klc_emit("pipeline raster pNext sType %d", (int)b->sType);
    }
    if (ci->pColorBlendState) {
        klc_emit("pipeline blend logic-op %d attachments %u", ci->pColorBlendState->logicOpEnable,
                 ci->pColorBlendState->attachmentCount);
        for (uint32_t i = 0; i < ci->pColorBlendState->attachmentCount && ci->pColorBlendState->pAttachments; i++) {
            const VkPipelineColorBlendAttachmentState *a = &ci->pColorBlendState->pAttachments[i];
            if (a->blendEnable)
                klc_emit("pipeline blend src %d dst %d op %d alpha src %d dst %d op %d", (int)a->srcColorBlendFactor,
                         (int)a->dstColorBlendFactor, (int)a->colorBlendOp, (int)a->srcAlphaBlendFactor,
                         (int)a->dstAlphaBlendFactor, (int)a->alphaBlendOp);
        }
    }
    if (ci->pDepthStencilState)
        klc_emit("pipeline depth test %d write %d op %d bounds %d stencil %d", ci->pDepthStencilState->depthTestEnable,
                 ci->pDepthStencilState->depthWriteEnable, (int)ci->pDepthStencilState->depthCompareOp,
                 ci->pDepthStencilState->depthBoundsTestEnable, ci->pDepthStencilState->stencilTestEnable);
    if (ci->pInputAssemblyState)
        klc_emit("pipeline topology %d restart %d", (int)ci->pInputAssemblyState->topology,
                 ci->pInputAssemblyState->primitiveRestartEnable);
    if (ci->pVertexInputState)
        for (uint32_t i = 0; i < ci->pVertexInputState->vertexAttributeDescriptionCount; i++)
            klc_emit("pipeline vertex attribute format %d", (int)ci->pVertexInputState->pVertexAttributeDescriptions[i].format);
    if (ci->flags) klc_emit("pipeline flags %#x", ci->flags);
    for (const VkBaseInStructure *b = ci->pNext; b; b = b->pNext) {
        if (b->sType == VK_STRUCTURE_TYPE_PIPELINE_RENDERING_CREATE_INFO) {
            const VkPipelineRenderingCreateInfo *r = (const void *)b;
            klc_sb s = {{0}, 0};
            for (uint32_t i = 0; i < r->colorAttachmentCount; i++) sb_add(&s, " %d", (int)r->pColorAttachmentFormats[i]);
            klc_emit("pipeline dynamic-rendering formats colors[%s ] depth %d stencil %d viewMask %#x", s.b,
                     (int)r->depthAttachmentFormat, (int)r->stencilAttachmentFormat, r->viewMask);
        } else klc_emit("pipeline pNext sType %d", (int)b->sType);
    }
}
static void census_compute_pipeline(const VkComputePipelineCreateInfo *ci) {
    if (!census_on() || !ci) return;
    g_klc_cpipes++;
    if (ci->flags) klc_emit("compute pipeline flags %#x", ci->flags);
    if (ci->stage.pSpecializationInfo) klc_emit("compute pipeline specialization constants used");
    for (const VkBaseInStructure *b = ci->stage.pNext; b; b = b->pNext)
        klc_emit("compute stage pNext sType %d", (int)b->sType);
    for (const VkBaseInStructure *b = ci->pNext; b; b = b->pNext) klc_emit("compute pipeline pNext sType %d", (int)b->sType);
}

// ---- images, samplers, queries, sync ---------------------------------------------------------------
static void census_image(const VkImageCreateInfo *ci) {
    if (!census_on() || !ci) return;
    g_klc_images++;
    klc_emit("image type %d format %d samples %d usage %#x flags %#x tiling %d mips>1 %d layers>1 %d",
             (int)ci->imageType, (int)ci->format, (int)ci->samples, ci->usage, ci->flags, (int)ci->tiling,
             ci->mipLevels > 1, ci->arrayLayers > 1);
    for (const VkBaseInStructure *b = ci->pNext; b; b = b->pNext) {
        if (b->sType == VK_STRUCTURE_TYPE_IMAGE_FORMAT_LIST_CREATE_INFO) {
            const VkImageFormatListCreateInfo *l = (const void *)b;
            klc_sb s = {{0}, 0};
            for (uint32_t i = 0; i < l->viewFormatCount; i++) sb_add(&s, " %d", (int)l->pViewFormats[i]);
            klc_emit("image format list %d ->%s", (int)ci->format, s.b);
        } else if (b->sType == VK_STRUCTURE_TYPE_IMAGE_STENCIL_USAGE_CREATE_INFO) {
            klc_emit("image separate stencil usage %#x", ((const VkImageStencilUsageCreateInfo *)b)->stencilUsage);
        } else klc_emit("image pNext sType %d", (int)b->sType);
    }
}
static void census_sampler(const VkSamplerCreateInfo *ci) {
    if (!census_on() || !ci) return;
    g_klc_samplers++;
    int reduction = -1;
    for (const VkBaseInStructure *b = ci->pNext; b; b = b->pNext) {
        if (b->sType == VK_STRUCTURE_TYPE_SAMPLER_REDUCTION_MODE_CREATE_INFO)
            reduction = (int)((const VkSamplerReductionModeCreateInfo *)b)->reductionMode;
        else klc_emit("sampler pNext sType %d", (int)b->sType);
    }
    klc_emit("sampler mag %d min %d mip %d address %d/%d/%d aniso %d max %.0f compare %d op %d border %d unnormalized %d reduction %d",
             (int)ci->magFilter, (int)ci->minFilter, (int)ci->mipmapMode, (int)ci->addressModeU, (int)ci->addressModeV,
             (int)ci->addressModeW, ci->anisotropyEnable, ci->anisotropyEnable ? ci->maxAnisotropy : 0.0f,
             ci->compareEnable, ci->compareEnable ? (int)ci->compareOp : -1, (int)ci->borderColor,
             ci->unnormalizedCoordinates, reduction);
}
static void census_query_pool(const VkQueryPoolCreateInfo *ci) {
    if (!census_on() || !ci) return;
    g_klc_qpools++;
    klc_emit("query pool type %d stats %#x", (int)ci->queryType, ci->pipelineStatistics);
}
static void census_semaphore(const VkSemaphoreCreateInfo *ci) {
    if (!census_on() || !ci) return;
    int type = 0;
    for (const VkBaseInStructure *b = ci->pNext; b; b = b->pNext) {
        if (b->sType == VK_STRUCTURE_TYPE_SEMAPHORE_TYPE_CREATE_INFO) type = (int)((const VkSemaphoreTypeCreateInfo *)b)->semaphoreType;
        else klc_emit("semaphore pNext sType %d", (int)b->sType);
    }
    if (type == VK_SEMAPHORE_TYPE_TIMELINE) g_klc_timeline++;
    klc_emit("semaphore type %s", type == VK_SEMAPHORE_TYPE_TIMELINE ? "timeline" : "binary");
}
static void census_submit(uint32_t n, const VkSubmitInfo *si) {
    if (!census_on() || !si) return;
    for (uint32_t i = 0; i < n; i++)
        for (const VkBaseInStructure *b = si[i].pNext; b; b = b->pNext)
            klc_emit("vkQueueSubmit pNext sType %d%s", (int)b->sType,
                     b->sType == VK_STRUCTURE_TYPE_TIMELINE_SEMAPHORE_SUBMIT_INFO ? " (timeline semaphore values)" : "");
}
static void census_submit2(uint32_t n, const VkSubmitInfo2 *si) {
    if (!census_on()) return;
    g_klc_submit2++;
    klc_emit("vkQueueSubmit2 used (synchronization2)");
    for (uint32_t i = 0; si && i < n; i++) {
        for (uint32_t w = 0; w < si[i].waitSemaphoreInfoCount; w++)
            if (si[i].pWaitSemaphoreInfos[w].value) klc_emit("vkQueueSubmit2 waits on a timeline value");
        for (const VkBaseInStructure *b = si[i].pNext; b; b = b->pNext) klc_emit("vkQueueSubmit2 pNext sType %d", (int)b->sType);
    }
}
static void census_entry(const char *name) {
    // Entry points worth knowing about the moment a guest resolves them (sync2, dynamic state 3, mesh, ...).
    if (!census_on() || !name) return;
    static const char *const watch[] = {
        "vkQueueSubmit2", "vkCmdPipelineBarrier2", "vkCmdWriteTimestamp2", "vkCmdSetEvent2", "vkCmdWaitEvents2",
        "vkWaitSemaphores", "vkSignalSemaphore", "vkGetSemaphoreCounterValue", "vkCmdBeginRendering",
        "vkCmdResolveImage2", "vkCmdBlitImage2", "vkCmdCopyImage2", "vkCmdDrawIndirectCount", "vkCmdDrawIndexedIndirectCount",
        "vkCmdDrawMeshTasksEXT", "vkCmdSetColorBlendEnableEXT", "vkCmdSetPolygonModeEXT", "vkCmdSetRasterizationSamplesEXT",
        "vkGetBufferDeviceAddress", "vkCmdBindDescriptorBuffersEXT", "vkCmdPushDescriptorSetKHR",
        "vkCmdSetFragmentShadingRateKHR", "vkCopyMemoryToImageEXT", "vkTransitionImageLayoutEXT",
        "vkCmdBeginQuery", "vkCmdWriteTimestamp", "vkGetQueryPoolResults", "vkCmdDispatchIndirect",
        "vkCmdSetRenderingAttachmentLocationsKHR", "vkCmdSetRenderingInputAttachmentIndicesKHR",
    };
    for (size_t i = 0; i < sizeof watch / sizeof *watch; i++)
        if (!strncmp(name, watch[i], strlen(watch[i]))) { klc_emit("entry point resolved %s", name); return; }
}

// ---- SPIR-V -------------------------------------------------------------------------------------------------------
// The opcodes and enums the walk needs, from the SPIR-V spec (stable numbers).
enum {
    KLS_OpExtension = 10, KLS_OpExtInstImport = 11, KLS_OpMemoryModel = 14, KLS_OpEntryPoint = 15, KLS_OpExecutionMode = 16,
    KLS_OpCapability = 17, KLS_OpTypeInt = 21, KLS_OpTypeFloat = 22, KLS_OpTypeImage = 25, KLS_OpTypeSampledImage = 27,
    KLS_OpTypeArray = 28, KLS_OpTypeRuntimeArray = 29, KLS_OpTypeStruct = 30, KLS_OpTypePointer = 32,
    KLS_OpConstant = 43, KLS_OpSpecConstant = 50, KLS_OpVariable = 59, KLS_OpLoad = 61, KLS_OpAccessChain = 65,
    KLS_OpInBoundsAccessChain = 66, KLS_OpDecorate = 71, KLS_OpImageFetch = 95, KLS_OpImageRead = 98,
    KLS_OpImageSparseFetch = 307, KLS_OpConstantComposite = 44, KLS_OpConstantNull = 46,
    KLS_OpSpecConstantComposite = 51, KLS_OpSpecConstantOp = 52,
};
enum { KLS_SC_UniformConstant = 0, KLS_SC_Uniform = 2, KLS_SC_StorageBuffer = 12 };

static const char *kls_cap_name(uint32_t c) {
    switch (c) {
    case 0: return "Matrix"; case 1: return "Shader"; case 2: return "Geometry"; case 3: return "Tessellation";
    case 4: return "Addresses"; case 5: return "Linkage"; case 6: return "Kernel"; case 9: return "Float16";
    case 10: return "Float64"; case 11: return "Int64"; case 12: return "Int64Atomics"; case 13: return "ImageBasic";
    case 17: return "Pipes"; case 18: return "Groups"; case 22: return "Int16"; case 23: return "TessellationPointSize";
    case 24: return "GeometryPointSize"; case 25: return "ImageGatherExtended"; case 27: return "StorageImageMultisample";
    case 28: return "UniformBufferArrayDynamicIndexing"; case 29: return "SampledImageArrayDynamicIndexing";
    case 30: return "StorageBufferArrayDynamicIndexing"; case 31: return "StorageImageArrayDynamicIndexing";
    case 32: return "ClipDistance"; case 33: return "CullDistance"; case 34: return "ImageCubeArray";
    case 35: return "SampleRateShading"; case 36: return "ImageRect"; case 37: return "SampledRect";
    case 39: return "Int8"; case 40: return "InputAttachment"; case 41: return "SparseResidency"; case 42: return "MinLod";
    case 43: return "Sampled1D"; case 44: return "Image1D"; case 45: return "SampledCubeArray"; case 46: return "SampledBuffer";
    case 47: return "ImageBuffer"; case 48: return "ImageMSArray"; case 49: return "StorageImageExtendedFormats";
    case 50: return "ImageQuery"; case 51: return "DerivativeControl"; case 52: return "InterpolationFunction";
    case 53: return "TransformFeedback"; case 54: return "GeometryStreams"; case 55: return "StorageImageReadWithoutFormat";
    case 56: return "StorageImageWriteWithoutFormat"; case 57: return "MultiViewport"; case 61: return "GroupNonUniform";
    case 62: return "GroupNonUniformVote"; case 63: return "GroupNonUniformArithmetic"; case 64: return "GroupNonUniformBallot";
    case 65: return "GroupNonUniformShuffle"; case 66: return "GroupNonUniformShuffleRelative";
    case 67: return "GroupNonUniformClustered"; case 68: return "GroupNonUniformQuad"; case 69: return "ShaderLayer";
    case 70: return "ShaderViewportIndex"; case 4423: return "SubgroupBallotKHR"; case 4427: return "DrawParameters";
    case 4431: return "SubgroupVoteKHR"; case 4433: return "StorageBuffer16BitAccess";
    case 4434: return "UniformAndStorageBuffer16BitAccess"; case 4435: return "StoragePushConstant16";
    case 4436: return "StorageInputOutput16"; case 4437: return "DeviceGroup"; case 4439: return "MultiView";
    case 4441: return "VariablePointersStorageBuffer"; case 4442: return "VariablePointers";
    case 4445: return "AtomicStorageOps"; case 4447: return "SampleMaskPostDepthCoverage";
    case 4448: return "StorageBuffer8BitAccess"; case 4449: return "UniformAndStorageBuffer8BitAccess";
    case 4450: return "StoragePushConstant8"; case 4464: return "DenormPreserve"; case 4465: return "DenormFlushToZero";
    case 4466: return "SignedZeroInfNanPreserve"; case 4467: return "RoundingModeRTE"; case 4468: return "RoundingModeRTZ";
    case 4471: return "RayQueryProvisionalKHR"; case 4472: return "RayQueryKHR"; case 4478: return "RayTracingKHR";
    case 5008: return "Float16ImageAMD"; case 5009: return "ImageGatherBiasLodAMD"; case 5010: return "FragmentMaskAMD";
    case 5013: return "StencilExportEXT"; case 5015: return "ImageReadWriteLodAMD"; case 5016: return "Int64ImageEXT";
    case 5055: return "ShaderClockKHR"; case 5249: return "SampleMaskOverrideCoverageNV";
    case 5251: return "GeometryShaderPassthroughNV"; case 5254: return "ShaderViewportIndexLayerEXT";
    case 5255: return "ShaderViewportMaskNV"; case 5259: return "ShaderStereoViewNV"; case 5260: return "PerViewAttributesNV";
    case 5265: return "FragmentFullyCoveredEXT"; case 5266: return "MeshShadingNV"; case 5282: return "ImageFootprintNV";
    case 5283: return "MeshShadingEXT"; case 5284: return "FragmentBarycentricKHR";
    case 5288: return "ComputeDerivativeGroupQuadsKHR"; case 5291: return "FragmentDensityEXT";
    case 5297: return "GroupNonUniformPartitionedNV"; case 5301: return "ShaderNonUniform";
    case 5302: return "RuntimeDescriptorArray"; case 5303: return "InputAttachmentArrayDynamicIndexing";
    case 5304: return "UniformTexelBufferArrayDynamicIndexing"; case 5305: return "StorageTexelBufferArrayDynamicIndexing";
    case 5306: return "UniformBufferArrayNonUniformIndexing"; case 5307: return "SampledImageArrayNonUniformIndexing";
    case 5308: return "StorageBufferArrayNonUniformIndexing"; case 5309: return "StorageImageArrayNonUniformIndexing";
    case 5310: return "InputAttachmentArrayNonUniformIndexing"; case 5311: return "UniformTexelBufferArrayNonUniformIndexing";
    case 5312: return "StorageTexelBufferArrayNonUniformIndexing"; case 5345: return "VulkanMemoryModel";
    case 5346: return "VulkanMemoryModelDeviceScope"; case 5347: return "PhysicalStorageBufferAddresses";
    case 5350: return "ComputeDerivativeGroupLinearKHR"; case 5363: return "FragmentShaderSampleInterlockEXT";
    case 5372: return "FragmentShaderShadingRateInterlockEXT"; case 5373: return "ShaderSMBuiltinsNV";
    case 5378: return "FragmentShaderPixelInterlockEXT"; case 5379: return "DemoteToHelperInvocation";
    case 6016: return "AtomicFloat32AddEXT"; case 6017: return "AtomicFloat64AddEXT";
    case 6025: return "WorkgroupMemoryExplicitLayoutKHR"; case 6033: return "AtomicFloat16AddEXT";
    default: return NULL;
    }
}

// Subgroup / group operations: OpGroupNonUniform* (333..366) and the KHR subgroup ops (4421..4432).
static int kls_is_subgroup_op(uint32_t op) { return (op >= 333 && op <= 366) || (op >= 4421 && op <= 4432); }

typedef struct { uint32_t id, kind, a, b, c; } kls_def;   // kind: opcode of the defining instruction
static void census_spirv(const uint32_t *w, size_t bytes) {
    if (!census_on() || !w || bytes < 20 || w[0] != 0x07230203u) return;
    g_klc_modules++;
    size_t nw = bytes / 4;
    uint32_t bound = w[3];
    if (bound == 0 || bound > (1u << 22)) return;
    // Per id: the defining opcode and up to three operands (type ids, storage class, constness).
    kls_def *d = calloc(bound, sizeof *d);
    if (!d) return;
    klc_emit("spirv version %u.%u generator %#x", (w[1] >> 16) & 0xff, (w[1] >> 8) & 0xff, w[2]);
    int has16 = 0, has64 = 0, has8 = 0, msread = 0, subgroup = 0, dynidx = 0, nonuniform_dec = 0;
    size_t i = 5;
    while (i < nw) {
        uint32_t op = w[i] & 0xffff, wc = w[i] >> 16;
        if (wc == 0 || i + wc > nw) break;
        const uint32_t *o = &w[i + 1];
        switch (op) {
        case KLS_OpCapability: {
            const char *n = kls_cap_name(o[0]);
            if (n) klc_emit("spirv capability %s", n); else klc_emit("spirv capability %u", o[0]);
            break;
        }
        case KLS_OpExtension: klc_emit("spirv extension %s", (const char *)o); break;
        case KLS_OpExtInstImport: klc_emit("spirv extended instruction set %s", (const char *)(o + 1)); break;
        case KLS_OpMemoryModel: klc_emit("spirv memory model addressing %u memory %u", o[0], o[1]); break;
        case KLS_OpEntryPoint: klc_emit("spirv entry point execution model %u", o[0]); break;
        case KLS_OpExecutionMode: klc_emit("spirv execution mode %u", o[1]); break;
        case KLS_OpDecorate: if (wc >= 3 && o[1] == 5300) nonuniform_dec = 1; break;   // NonUniform
        case KLS_OpTypeInt:
            if (o[0] < bound) d[o[0]] = (kls_def){o[0], op, o[1], o[2], 0};
            if (o[1] == 16) has16 = 1; else if (o[1] == 64) has64 = 1; else if (o[1] == 8) has8 = 1;
            break;
        case KLS_OpTypeFloat:
            if (o[0] < bound) d[o[0]] = (kls_def){o[0], op, o[1], 0, 0};
            if (o[1] == 16) has16 = 1; else if (o[1] == 64) has64 = 1;
            break;
        case KLS_OpTypeImage:   // result, sampled type, dim, depth, arrayed, MS, sampled, format
            if (o[0] < bound) d[o[0]] = (kls_def){o[0], op, o[2], o[5], o[6]};
            break;
        case KLS_OpTypeSampledImage:
            if (o[0] < bound) d[o[0]] = (kls_def){o[0], op, o[1], 0, 0};
            break;
        case KLS_OpTypeArray: case KLS_OpTypeRuntimeArray:
            if (o[0] < bound) d[o[0]] = (kls_def){o[0], op, o[1], 0, 0};
            break;
        case KLS_OpTypeStruct:
            if (o[0] < bound) d[o[0]] = (kls_def){o[0], op, 0, 0, 0};
            break;
        case KLS_OpTypePointer:   // result, storage class, pointee type
            if (o[0] < bound) d[o[0]] = (kls_def){o[0], op, o[1], o[2], 0};
            break;
        case KLS_OpConstant: case KLS_OpSpecConstant: case KLS_OpConstantComposite: case KLS_OpConstantNull:
        case KLS_OpSpecConstantComposite: case KLS_OpSpecConstantOp: case 41: case 42: case 48: case 49:
            // OpConstantTrue/False (41/42), OpSpecConstantTrue/False (48/49): all constants for indexing purposes
            if (wc >= 3 && o[1] < bound) d[o[1]] = (kls_def){o[1], KLS_OpConstant, o[0], 0, 0};
            break;
        case KLS_OpVariable:   // result type (pointer), result, storage class
            if (o[1] < bound) d[o[1]] = (kls_def){o[1], op, o[0], o[2], 0};
            break;
        case KLS_OpLoad:       // result type, result, pointer
            if (o[1] < bound) d[o[1]] = (kls_def){o[1], op, o[0], o[2], 0};
            break;
        case KLS_OpAccessChain: case KLS_OpInBoundsAccessChain: {
            // result type, result, base, indices... Dynamic indexing into a descriptor array: the base is a
            // variable in UniformConstant / Uniform / StorageBuffer whose pointee is an array (or runtime
            // array), and the FIRST index is not a constant.
            if (o[1] < bound) d[o[1]] = (kls_def){o[1], op, o[0], o[2], 0};
            if (wc < 5 || o[2] >= bound || d[o[2]].kind != KLS_OpVariable) break;
            uint32_t sc = d[o[2]].b, pty = d[o[2]].a;
            if (sc != KLS_SC_UniformConstant && sc != KLS_SC_Uniform && sc != KLS_SC_StorageBuffer) break;
            if (pty >= bound || d[pty].kind != KLS_OpTypePointer) break;
            uint32_t pointee = d[pty].b;
            if (pointee >= bound || (d[pointee].kind != KLS_OpTypeArray && d[pointee].kind != KLS_OpTypeRuntimeArray)) break;
            uint32_t idx = o[3];
            if (idx < bound && d[idx].kind == KLS_OpConstant) break;
            dynidx = 1;
            const char *elem = "resource";
            uint32_t et = d[pointee].a;
            if (et < bound) {
                if (d[et].kind == KLS_OpTypeImage) elem = d[et].c == 2 ? "storage image" : "image";
                else if (d[et].kind == KLS_OpTypeSampledImage) elem = "sampled image";
                else if (d[et].kind == KLS_OpTypeStruct) elem = sc == KLS_SC_StorageBuffer ? "storage buffer" : "uniform buffer";
                else if (d[et].kind == 26) elem = "sampler";   // OpTypeSampler
            }
            klc_emit("spirv dynamic indexing into a %s%s array (storage class %u)%s", elem,
                     d[pointee].kind == KLS_OpTypeRuntimeArray ? " runtime" : "", sc,
                     nonuniform_dec ? ", NonUniform decorations present" : "");
            break;
        }
        case KLS_OpImageFetch: case KLS_OpImageRead: case KLS_OpImageSparseFetch: {
            // result type, result, image: a multisampled image read when the image's type has MS = 1
            uint32_t img = o[2];
            uint32_t ty = img < bound ? d[img].a : 0;     // an OpLoad's result type
            if (ty < bound && d[ty].kind == KLS_OpTypeImage && d[ty].b == 1) msread = 1;
            break;
        }
        default:
            if (kls_is_subgroup_op(op)) { subgroup = 1; klc_emit("spirv subgroup op %u", op); }
            break;
        }
        i += wc;
    }
    if (has16) klc_emit("spirv uses 16-bit types");
    if (has64) klc_emit("spirv uses 64-bit types");
    if (has8) klc_emit("spirv uses 8-bit integers");
    if (msread) klc_emit("spirv reads a multisampled image (texelFetch on MS)");
    if (subgroup) klc_emit("spirv uses subgroup operations");
    if (dynidx) g_klc_dynidx++;
    free(d);
}

// ---- the summary line, every 600 guest frames ----------------------------------------------------------------
static void census_frame(uint64_t serial) {
    if (!census_on() || !serial || serial % 600) return;
    fprintf(stderr, "[census] summary frame %llu: %u distinct lines; %u shader modules (%u with dynamic descriptor "
            "indexing), %u graphics + %u compute pipelines, %u set layouts (%u large/partially-bound bindings), "
            "%u render passes, %u images, %u samplers, %u query pools, %u timeline semaphores, %u vkQueueSubmit2 calls\n",
            (unsigned long long)serial, (unsigned)g_klc_lines, (unsigned)g_klc_modules, (unsigned)g_klc_dynidx,
            (unsigned)g_klc_gpipes, (unsigned)g_klc_cpipes, (unsigned)g_klc_layouts, (unsigned)g_klc_bindless,
            (unsigned)g_klc_rpasses, (unsigned)g_klc_images, (unsigned)g_klc_samplers, (unsigned)g_klc_qpools,
            (unsigned)g_klc_timeline, (unsigned)g_klc_submit2);
}

// ---- wrappers for the entry points the layer did not intercept before -------------------------------------
static VkResult VKAPI_CALL klvk_census_CreateQueryPool(VkDevice dev, const VkQueryPoolCreateInfo *ci,
                                                       const VkAllocationCallbacks *a, VkQueryPool *out) {
    static PFN_vkCreateQueryPool real;
    if (!real && real_gdpa) real = (PFN_vkCreateQueryPool)real_gdpa(dev, "vkCreateQueryPool");
    census_query_pool(ci);
    return real ? real(dev, ci, a, out) : VK_ERROR_INITIALIZATION_FAILED;
}
static VkResult VKAPI_CALL klvk_census_CreateSemaphore(VkDevice dev, const VkSemaphoreCreateInfo *ci,
                                                       const VkAllocationCallbacks *a, VkSemaphore *out) {
    static PFN_vkCreateSemaphore real;
    if (!real && real_gdpa) real = (PFN_vkCreateSemaphore)real_gdpa(dev, "vkCreateSemaphore");
    census_semaphore(ci);
    return real ? real(dev, ci, a, out) : VK_ERROR_INITIALIZATION_FAILED;
}
static VkResult VKAPI_CALL klvk_census_QueueSubmit2(VkQueue q, uint32_t n, const VkSubmitInfo2 *si, VkFence f) {
    static PFN_vkQueueSubmit2 real;
    if (!real && real_gdpa && g_devs[0]) {
        real = (PFN_vkQueueSubmit2)real_gdpa(g_devs[0]->dev, "vkQueueSubmit2");
        if (!real) real = (PFN_vkQueueSubmit2)real_gdpa(g_devs[0]->dev, "vkQueueSubmit2KHR");
    }
    census_submit2(n, si);
    return real ? real(q, n, si, f) : VK_ERROR_INITIALIZATION_FAILED;
}
// Only while the census is on: these names are otherwise left to the driver untouched.
static PFN_vkVoidFunction census_ours(const char *name) {
    if (!census_on() || !name) return NULL;
    census_entry(name);
    if (!strcmp(name, "vkCreateQueryPool")) return (PFN_vkVoidFunction)klvk_census_CreateQueryPool;
    if (!strcmp(name, "vkCreateSemaphore")) return (PFN_vkVoidFunction)klvk_census_CreateSemaphore;
    if (!strcmp(name, "vkQueueSubmit2") || !strcmp(name, "vkQueueSubmit2KHR"))
        return (PFN_vkVoidFunction)klvk_census_QueueSubmit2;
    return NULL;
}
