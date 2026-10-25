# vulkan-ash
Vulkan framework in Zig.

Aktuální první iterace obsahuje knihovní projekt `ash` a základní typ `Manager`, který pokrývá:

- načtení Vulkan loaderu přes `vulkan-zig`
- vytvoření instance a volitelného debug messengeru
- vytvoření surface přes callback (`SurfaceFactory`) nebo přes `Host`
- výběr fyzického zařízení a queue family
- vytvoření logical device a získání hlavní queue
- teardown celé Vulkan stack vrstvy
- `DesktopHost` (SDL3) + `Session` render loop pro desktop aplikace
- texture upload helpery `createTextureFromFile` a `createTextureFromRgba`

Použité závislosti:

- `https://github.com/Snektron/vulkan-zig` (větev `zig-0.17-compat`)
- `https://github.com/castholm/SDL` (SDL3 kompilované ze zdrojáků, jen desktop)
- `https://github.com/zigimg/zigimg.git`


# Dependencies

- SDL3 (window, events, Vulkan surface on desktop)
  - https://github.com/castholm/SDL.git

- vulkan-zig Vulkan API binding
  - https://github.com/Snektron/vulkan-zig.git (branch `zig-0.17-compat`)
