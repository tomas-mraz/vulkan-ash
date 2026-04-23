# vulkan-ash
Vulkan framework in Zig.

Aktuální první iterace obsahuje knihovní projekt `ash` a základní typ `Manager`, který pokrývá:

- načtení Vulkan loaderu přes `vulkan-zig`
- vytvoření instance a volitelného debug messengeru
- vytvoření surface přes callback nebo GLFW convenience init
- výběr fyzického zařízení a queue family
- vytvoření logical device a získání hlavní queue
- teardown celé Vulkan stack vrstvy
- `DesktopHost` + `Session` render loop pro desktop GLFW aplikace
- texture upload helpery `createTextureFromFile` a `createTextureFromRgba`

Použité závislosti:

- `https://github.com/tomas-mraz/vulkan-zig`
- `../glfw-zig` z `https://github.com/tomas-mraz/glfw-zig`
- `https://github.com/zigimg/zigimg.git`


# Dependencies

- glfw binding
  - https://github.com/tomas-mraz/glfw-zig.git
  - /home/tomas/git-osobni-github/glfw-zig

- vulkan-zig Vulkan API binding
  - https://github.com/tomas-mraz/vulkan-zig.git
  - /home/tomas/git-osobni-github/vulkan-zig
