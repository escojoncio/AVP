# AVP — Plan de trabajo

Port de **Half-Life: Alyx** (build ARM64 nativa de Steam Frame) a **Apple Vision Pro**
(visionOS, objetivo principal: Vision Pro M2), con un enfoque tipo Klepton.

> Estado: **planificación**. Todavía no hay código. Este documento recoge todo lo decidido
> e investigado para poder arrancar sin repetir la investigación.

---

## 1. Objetivo

Una app de visionOS (el IPA de este proyecto) que hace **todo desde el propio Vision Pro**,
sin pasos en el PC:

1. Inicia sesión en Steam (con Steam Guard / 2FA si hace falta).
2. Pulsa **Descargar** y la app baja el juego de la propia cuenta del usuario
   (contenido + binarios ARM64) a una **carpeta accesible por el usuario**.
3. La app adapta los ficheros para que arranquen con este proyecto e incluye una
   **pre-caché completa de shaders**.
4. Un **menú de inicio** permite ajustar resolución, foveado, antialiasing y reescalado.
5. Pulsa **Jugar**.

Requisito principal: **buen rendimiento y nitidez en Vision Pro M2**, con un foveado
parecido al de Steam Frame (centro nítido, periferia reducida) y regulable.

---

## 2. Hechos verificados sobre el juego

### Depots (app 546560)
| Depot  | Contenido                          | Notas |
|--------|------------------------------------|-------|
| 546561 | Contenido común (~67 GB)           | Datos, sin código. Igual en todas las plataformas |
| 546563 | Binarios Windows                   | **Solo x86-64** (comprobado: PE `0x8664`, sin metadatos ARM64EC) |
| 546564 | Binarios Linux                     | Incluye **x86-64 y ARM64** en carpetas separadas |

La app descarga **546561 + 546564** (de este último solo se usa la parte ARM64).

### Estructura del depot Linux
```
game/hlvr.sh                         # lanzador; recrea symlinks de libs
game/bin/linuxsteamrt64/             # x86-64 (no se usa)
game/bin/linuxsteamrtarm64/          # ARM64  <-- lo que portamos
game/hlvr/bin/linuxsteamrtarm64/     # libclient.so, libserver.so, libhost.so
```
Los symlinks de librerías (pares `enlace:destino` en la función `create_symlinks` de
`hlvr.sh`) hay que recrearlos durante la preparación.

### Binarios ARM64 (comprobado)
- ELF64 **aarch64**, enlazados contra **glibc** (versión máxima requerida `GLIBC_2.38`,
  Steam Runtime). **No es Android/bionic** → Klepton necesita una capa glibc.
- Dependencias clave:
  - `hlvr` → `libmimalloc.so`, `libstdc++.so.6`, `libc.so.6`
  - `libengine2.so` → `libm`, `libstdc++`, `libuuid.so.1`, `ld-linux-aarch64.so.1`,
    `libtier0`, `libvstdlib`, **`libsteam_api.so`**, `libc`
  - `libvr.so` → **`libopenvr_api.so`** (VR por **OpenVR**, no OpenXR)
  - `librendersystemvulkan.so` → **`libxcb.so.1`** (ventana X11), carga Vulkan
    dinámicamente (0 imports `vk*` directos)
- Driver Vulkan propio incluido: `libvulkan_freedreno_hlvr.so` + ICD
  `freedreno_hlvr_icd.aarch64.json` (Turnip/Adreno, API 1.4). **Inútil en Apple** → se
  sustituye por MoltenVK apuntando el loader a otro ICD.
- Scripting: V8 (`libv8*.so`) y `libvscript.so`.

### Foveado y ajustes del motor (strings de los binarios)
El render ya implementa foveado con:
- `VK_EXT_fragment_density_map` y `VK_EXT_fragment_density_map_offset`
  ("Using VK_EXT_fragment_density_map_offset for eyetracking support")
- Flag `-vulkan_disable_ext_fragment_density_map`

ConVars útiles encontradas:
```
vr_foveation_disable            vr_foveated_boundary
vr_foveated_inner_scalar        vr_foveated_outer_scalar
vr_foveated_overlap             vr_fdm_offset (+ _debug, _flip_y)
vr_msaa                         vr_msaa_submit
vr_alternating_msaa_2x          vr_force_native_resolution
vr_reprojection_cpu_auto        vr_vulkan_wait_fence_between_eyes
r_texture_stream_*              (streaming de texturas)
```

### Memoria (gameinfo.gi + binarios)
- `RenderSystem` en `game/hlvr/gameinfo.gi`: `DeckardTexturePoolSizeMB 2816` (Steam Frame =
  "Deckard": ~2,75 GB de texturas), `MinStreamingPoolSizeMB 1536`,
  `SetInitialStreamingPoolSizeFromBudget 1`, `VulkanUseStreamingTextureManager 1`.
- Presupuesto dinámico vía `VK_EXT_memory_budget` (`r_texture_budget_dynamic`,
  `r_texture_budget_threshold`), `-vr_gpu_memory_reserve_mb`, y
  `CRenderDeviceVulkan::OnLowMemoryNotification` (expulsa texturas).
- `Vr/FilterFidelityLevelsByGPUMemoryRatio 1`: descarta niveles de fidelidad que no caben.
- Estimación (no medida) del proceso en Frame: ~6–7,5 GB.
- **Vision Pro con memoria ampliada: 8133 MB disponibles para la app (medido en el
  dispositivo)**. Es el presupuesto total del proceso, GPU incluida; si se supera, jetsam
  mata la app. Plan:
  - Pool de texturas por defecto = valor de Steam Frame (2816 MB); ajustable a la baja en
    el menú (calidad de texturas). Se sabe que el juego cabe en este presupuesto.
  - MoltenVK debe reportar en `VK_EXT_memory_budget` la memoria **disponible para el
    proceso** (`os_proc_available_memory`), no la RAM total.
  - Aviso de memoria de visionOS → `OnLowMemoryNotification` del motor.
  - Contar el consumo propio (MoltenVK, textura foveada intermedia, MetalFX, runtime).

### Idioma (en los binarios ARM64)
- Parámetros de arranque: `-language`, `-textlanguage` / `-textsublanguage`; claves
  `AudioLanguage` / `AudioSubLanguage`, convar `cl_language`, search path `game_language`.
- El motor también consulta `ISteamApps::GetCurrentGameLanguage` y
  `GetAvailableGameLanguages` → el **shim de Steam** debe devolver el idioma elegido en el
  menú y la lista disponible.
- 28 idiomas de texto/subtítulos; **voces solo en inglés**. Un único selector (texto);
  el audio se fija en inglés. Lista: info de la app en Steam y/o ficheros descargados.

### Resolución dinámica: Auto-Fidelity System (en los binarios ARM64)
- `vr_fidelity_level` = nivel de una tabla (cada nivel = escala de resolución + MSAA;
  log: "Level %d: Scale = %.3f Resolution = %d x %d").
- `vr_fidelity_level_auto` ajusta el nivel según el tiempo de GPU por frame (CRITICAL /
  PREDICTIVE / MAX DROP, MIN INCREASE).
- Ajustes: `vr_fidelity_threshold_frame_percent_{min,max,critical,extrapolation}`,
  `vr_fidelity_target_extra_ms`, `vr_fidelity_target_half_rate`,
  `vr_perf_mode_max_fidelity_level`, `vr_fidelity_memory_threshold`,
  `vr_fidelity_visualizer`, `vr_spew_fidelity_data`.
- Flags: `-autofidelityconfig`, `-forcefidelitylevel`, `-noautofidelity`.
- Requisitos para AVP: el runtime OpenVR debe dar **tiempos de GPU reales** por frame
  (Metal/Compositor Services); la tabla se elige por fabricante de GPU (con MoltenVK =
  Apple) → crear **tabla de niveles propia para M2** vía `-autofidelityconfig`.
- Combina con MetalFX Spatial: resolución interna variable, salida fija.

---

## 3. Restricciones de la plataforma

- **App nativa de visionOS.** AVP es siempre una app nativa propia. No se usa LiveContainer
  ni ningún otro contenedor/host; como mucho se toman técnicas como referencia.
- **Sin JIT en ningún caso.** visionOS solo ejecuta código firmado. Hay dos vías para
  cargar el motor adaptado sin JIT, y la Fase 0 decide cuál se usa:
  - **Opción 2 (preferida): firma en el dispositivo.** La app descarga los binarios ARM64,
    los adapta y los **firma en el propio Vision Pro con el certificado de desarrollo
    gratuito que SideStore genera para el Apple ID del usuario** (importado una vez en la
    app desde SideStore) antes de cargarlos. IPA limpio de Valve, todo desde la app.
    No está confirmado que visionOS lo acepte → Fase 0.
  - **Instalación:** el usuario instala IPAs con **SideStore** (Apple ID gratuito, sin
    cuenta de desarrollador de pago). Implicaciones:
    - SideStore **refresca AVP cada 7 días** como cualquier app (lo que caduca es el
      **perfil de aprovisionamiento**, no el certificado). Si el certificado no cambia, las
      `.dylib` firmadas en el casco siguen siendo válidas. Si SideStore genera uno nuevo
      (revocación, re-login, caducidad), AVP lo detecta al abrir, lo importa y **re-firma**
      (segundos; sin repetir descarga ni conversión).
    - La firma on-device solo necesita certificado + clave privada y un firmador de
      código abierto (zsign/ldid, revisar licencia). **No** se reutiliza código de
      SideStore ni se habla con Apple.
    - Límites de cuenta gratuita: **3 apps activas** (SideStore cuenta como una) y
      **10 App IDs / 7 días**. AVP debe costar solo **1 app + 1 App ID**: diseñarla
      **sin app extensions** (cada una gasta un App ID extra). Firmar las `.dylib` en el
      dispositivo y re-firmarlas no crea App IDs ni apps nuevas.
    - Lo que importa es el **App ID**: mientras siga registrado, el usuario puede
      desinstalar e instalar apps libremente para alternarlas. AVP **no necesita
      StikDebug** (sin JIT).
    - La Opción 1 también es compatible: SideStore firma el IPA con todo lo que lleve dentro.
  - **Opción 1 (respaldo): motor adaptado dentro del IPA** (forma de Klepton). Conversión al
    compilar, el código viaja firmado en la app. Funciona seguro, pero el IPA lleva código
    de Valve: se genera desde la copia del usuario y no se comparte ni se publica. El
    contenido (546561) se sigue descargando desde la app.
  - Todo lo demás (runtime OpenVR, foveado, menú, descarga de contenido, shaders) es
    idéntico en ambas opciones.
- **Sin mirada.** visionOS no expone el gaze a las apps. El foveado será **fijo, centrado**
  (no sigue los ojos). `vr_fdm_offset` queda sin uso.
- **Foveado por defecto de Compositor Services** en apps Metal inmersivas = mapa estático
  y suave. Por eso usamos un mapa propio (ver §5.3).
- **Copyright:** el IPA y el repo **no contienen nada de Valve**. Todo lo del juego lo
  descarga el usuario con su propia cuenta en su dispositivo.

---

## 4. Arquitectura

```
[GitHub Actions macOS, solo manual o con [build]]
  compila SOLO el código del proyecto (loader, runtime, MoltenVK, UI)
  -> IPA sin contenido de Valve (Opción 2) / con el motor adaptado (Opción 1, privado)

[Vision Pro, todo dentro de la app]
  1. login Steam (2FA)
  2. descarga depots 546561 + 546564 (manifests fijados a una versión probada)
     -> carpeta accesible por el usuario (app Archivos: "En mi Vision Pro > AVP")
  3. preparación: symlinks, ELF->Mach-O + firma on-device (Opción 2), pre-caché de shaders
  4. menú de inicio -> juego
```

### Carpeta del usuario
- La app expone su carpeta de datos en **Archivos** (`UIFileSharingEnabled` +
  `LSSupportsOpeningDocumentsInPlace`).
- Ahí se instalan los ficheros descargados y ahí el usuario puede **colocar sus propios
  ficheros legales ya adaptados** para el arranque con este proyecto (alternativa a la
  descarga/adaptación automática). La app detecta lo que hay y solo hace lo que falte.
- Estructura propuesta:
  ```
  AVP/
    game/            # depots tal cual (contenido + ARM64)
    adapted/         # binarios convertidos y firmados (generados o aportados)
    cache/shaders/   # MSL compilado + MTLBinaryArchive
    config/          # ajustes del menú + cfg generados para el juego
    logs/
  ```
- Los manifests quedan **fijados** a una versión probada para que una actualización de
  Valve no rompa el juego; actualizar a una versión nueva es una acción explícita.

### Componentes
1. **Loader** — fork de Klepton con "personalidad" Linux/glibc: ELF→Mach-O (ejecutable
   **en el dispositivo**), `ld-linux`, `libc`/`libm`/`libstdc++`/`libuuid` shims, TLS, `x18`
   (Darwin lo pone a cero en cada excepción: revisar si el código de Valve lo usa).
2. **Firma on-device** (solo Opción 2) — importar el certificado de SideStore y firmar los
   Mach-O generados (y re-firmarlos cuando el certificado se renueve), dentro de AVP.
3. **Vulkan** — MoltenVK (evaluar también KosmicKrisp si está maduro). Stub de `libxcb`.
4. **Runtime OpenVR propio** (`libopenvr_api` sustituto) sobre **Compositor Services + ARKit**:
   - `VR_InitInternal`, `VR_GetGenericInterface`, `VR_ShutdownInternal`, etc.
   - `IVRSystem` (proyecciones, `GetRecommendedRenderTargetSize` = palanca de resolución real)
   - `IVRCompositor` (submit por ojo → drawable, timing, pose prediction)
   - `IVRInput` (mandos: PS VR2 Sense / mandos de juego vía GameController; manos vía ARKit)
5. **Foveado** — traducción FDM → `MTLRasterizationRateMap` propio (§5.3).
6. **Shim de Steam** — `libsteam_api` mínimo, solo para la copia del usuario.
7. **Cliente Steam en Swift** — login (2FA/Steam Guard, refresh token en Keychain),
   licencias, manifests, claves de depot, CDN, descarga reanudable.
8. **App visionOS** — SwiftUI: login, descarga, preparación, menú, lanzamiento.

---

## 5. Diseño de la app

### 5.1 Flujo
Login → Descargar (progreso, reanudable, comprobación de espacio libre ~70 GB+) →
Preparar (adaptación + firma + shaders; puede tardar del orden de 10–15 min) → Menú → Jugar.

### 5.2 Pre-caché de shaders
- Recorrer los shaders Vulkan del contenido (SPIR-V en VPK), traducir **todos** a MSL y
  compilarlos (`MTLLibrary`) tras la descarga.
- Los PSO (combinaciones de estado) no se pueden precalcular al 100 %: guardar en
  `MTLBinaryArchive` la primera vez y reutilizar.
- El contenido trae `shaders_vulkan_*.vpk` (~1,25 GB) y una caché de pipelines Fossilize
  (`vulkan_shader_cache.foz`, referenciada en `gameinfo.gi` como
  `VulkanAdditionalShaderCache`) → reproducirla para precompilar también PSOs.
- Invalidar caché si cambia el manifest o la versión de MoltenVK.

### 5.3 Foveado (objetivo: parecido a Steam Frame, pero fijo)
- Renderizar a una **textura intermedia** con un `MTLRasterizationRateMap` propio y luego
  componer en el drawable de Compositor Services.
- Alimentar también las convars `vr_foveated_*` para que el motor reparta igual.

### 5.4 Menú de inicio (ajustes guardados, aplicados en cada arranque)
| Ajuste | Opciones |
|--------|----------|
| **Resolución real** | % sobre nativa (vía `GetRecommendedRenderTargetSize` + cfg del juego) |
| **Resolución dinámica** | On/Off · rango mín–máx · objetivo de margen (estable ↔ nítido) |
| **Calidad de texturas** | Tamaño del pool de streaming (mín. 1536 MB; por defecto 2816 MB) |
| **Idioma** | 28 idiomas de texto/subtítulos (voces siempre en inglés, único idioma con audio) |
| **Foveado** | Desactivado / Suave / Medio (≈Steam Frame) / Fuerte / Personalizado |
| ↳ Personalizado | Tamaño zona nítida · Calidad periferia · Suavidad transición |
| **Antialiasing** | Off / MSAA 2x / MSAA 2x alterno (`vr_alternating_msaa_2x`) / MSAA 4x |
| **Reescalado** | Ninguno / MetalFX Spatial / MetalFX Temporal (*experimental*) |
| **Nitidez** | Slider (solo con MetalFX) |

- Esquema visual del reparto de calidad por ojo y **coste estimado** de la combinación.
- MetalFX Temporal necesita vectores de movimiento que Alyx no genera (nunca tuvo TAA):
  aproximarlos con profundidad + pose de cabeza → ghosting en objetos móviles. Desactivado
  por defecto. Si se activa, el menú **desactiva MSAA** automáticamente.
- MSAA + MetalFX Spatial: combinación válida (AA primero, reescalado después).
- Los valores se escriben en los ficheros de configuración del propio juego + parámetros
  del runtime.

---

## 6. Fases

### Fase 0 — Verificar la firma on-device (bloqueante, barata)
Prototipo mínimo nativo en visionOS, instalado con SideStore: importar el certificado
desde SideStore, descargar un `.dylib`, firmarlo en el casco y cargarlo con `dlopen`, sin JIT.
- **Funciona** → Opción 2 (todo desde la app, IPA sin nada de Valve).
- **No funciona** → Opción 1 (motor adaptado dentro del IPA, ver §3).

### Fase 1 — Que arranque y se juegue bien (prioridad)
1. Scaffold del proyecto Xcode/visionOS + workflow CI (reglas de minutos, §7).
2. Carpeta accesible en Archivos; el usuario coloca ahí los ficheros del juego.
3. Fork de Klepton + capa glibc + conversión y firma on-device; cargar
   `libtier0` → `libengine2` → `hlvr`.
4. MoltenVK + stub `libxcb`; primer frame.
5. Runtime OpenVR sobre Compositor Services/ARKit; estéreo + pose de cabeza.
6. Input (mandos y/o manos).
7. Foveado propio (§5.3) y menú de ajustes (§5.4).
8. Pruebas y perfilado en Vision Pro M2.

### Fase 2 — Experiencia "descargar y jugar"
1. Cliente Steam en Swift (login + 2FA, Keychain).
2. Descarga de 546561 + 546564 fijada al manifest, reanudable, a la carpeta del usuario.
3. Preparación automática + pre-caché completa de shaders.

---

## 7. Contenido de Valve
- **Nada de Valve** en git, releases ni artefactos (ver `.gitignore`). Con la Opción 2 el
  IPA no contiene nada de Valve y el repo podría hacerse público (revisar historial antes).
  Con la Opción 1 el IPA se genera solo de forma privada.

---

## 8. Preguntas abiertas
- ¿Funciona en visionOS la importación del certificado de SideStore + firma on-device +
  `dlopen` sin JIT? (Fase 0)
- Mandos objetivo: PS VR2 Sense vía GameController, mandos genéricos, o hand tracking.
- Formato exacto de los shaders Vulkan en los VPK y si el build ARM64 trae caché propia.
- Si Klepton upstream añade soporte glibc o JIT entretanto.
- Uso de `x18` en el código de Valve (compilado para Linux, puede usarlo como registro libre).
- Espacio: ~67 GB de contenido + binarios + caché de shaders en el Vision Pro.

---

## 9. Créditos técnicos a considerar
Klepton · zsign (firma on-device, referencia) · MoltenVK · SPIRV-Cross ·
OpenVR (headers) · SteamKit2 / DepotDownloader (referencia de protocolo) ·
Apple Compositor Services / ARKit / MetalFX.
