# Particle Herbarium · 粒子标本馆

A single-file WebGL page in which four flowers grow from GPU particles inside a wireframe specimen case: peony 牡丹, rose 玫瑰, lotus 荷花 and dandelion 蒲公英. A live JSON editor on the left regrows the flower as you type.

Open `index.html` in a recent browser with WebGL2. It loads three.js r170 from jsDelivr, so the first visit needs network access.

## What's inside

- **GPGPU simulation**: position, velocity and colour live in float textures (`GPUComputationRenderer`). Each particle is pulled toward its home point by a spring and kept moving by a divergence-free ABC flow field. The pointer stirs the particles and a click sends out a shockwave.
- **Fibers**: every shape is generated as strands of 16 particles. They are drawn as soft points plus hairline segments that fade as a strand stretches, so fibers dissolve in flight and re-knit when they land.
- **Growth and morphs**: strands switch on from the ground up. Changing the flower dissolves the current one into a vortex and regrows the new one in its place.
- **Look**: additive sprites with depth-of-field-sized point size, a depth fade, rim-lit petal edges, Unreal bloom, Neutral tone mapping, and a lens pass with chromatic aberration, vignette and grain.
- **Live config**: `bloom.json` accepts `//` comments. Edits rebuild the shape in a Web Worker. Hold Alt (Option on a Mac) and drag over a number to scrub it. The `flow.frag` and `particle.vert` tabs show the shaders the page actually runs.

## Controls

| Input | Action |
| --- | --- |
| Drag / scroll | Orbit / zoom |
| Move the pointer over the flower | Stir the particles |
| Click | Shockwave |
| `1`–`4` | Switch flower |
| `Space` | Toggle auto-rotate |
| `B` / `G` | Burst / regrow |
| `C` / `H` / `F` | Code panel / hide UI / fullscreen |

The render panel (slider icon) sets bloom, exposure, point size, fiber opacity, wind, turbulence, depth of field, spin, and a particle budget from 65K to 410K. If the frame rate stays low, the page steps the particle budget down on its own.
