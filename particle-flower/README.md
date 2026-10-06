# Particle Herbarium · 粒子标本馆

A single-file WebGL page in which four flowers grow from GPU particles inside a wireframe specimen case: peony 牡丹, rose 玫瑰, lotus 荷花 and dandelion 蒲公英. A live JSON editor on the left regrows the flower as you type. The stage is laid out like a botanical plate, with labelled parts, dimension lines, a brush-written poem and a herbarium slip.

Open `index.html` in a recent browser with WebGL2. It loads three.js r170 from jsDelivr and its fonts from Google Fonts, so the first visit needs network access.

## What's inside

- **GPGPU simulation**: position, velocity and colour live in float textures (`GPUComputationRenderer`). Each particle is pulled toward its home point by a spring and kept moving by a divergence-free ABC flow field, wind and gusts. The pointer stirs the particles and a click sends out a shockwave.
- **Fibers**: every shape is generated as strands of 16 particles. They are drawn as soft points plus Catmull-Rom hairlines through each strand. The lines fade as a strand stretches, so fibers dissolve in flight and re-knit when they land.
- **Specimens**: each flower is built from named parts. The peony has a crown of petaloid stamens and its roots; the rose has thorns, a bud, a hip and fallen petals; the lotus stands in a rippled pool with floating and furled leaves, a bud, a seed pod and a dragonfly; the dandelion's seed clock is made of single achenes with beaks and pappus, with a bald patch where seeds have left and a stream of them riding away, beside a flowering head and a closed bud on their own stalks. Dew drops catch the light as small stars.
- **Pieces that come loose**: now and then a petal flutters to the floor and regrows, dandelion seeds lift away on the wind and out of the case, and the dragonfly takes a turn round the flower and lands again. They run on the GPU as rigid groups, each on its own timeline.
- **Growth and morphs**: strands switch on from the ground up. Changing the flower dissolves the current one into a vortex and regrows the new one in its place.
- **Light and lens**: fibers get a Kajiya-Kay sheen, with tangents taken from neighbouring particles, so highlights slide along them as the camera turns. The case stands on a black-glass floor that mirrors the flower, under a lamp with a lit beam, between glass panes and drifting dust. Post-processing adds Unreal bloom, then Neutral tone mapping, a per-specimen grade, chromatic aberration, vignette and grain in one final pass.
- **Botanical plate**: callouts name each visible part in Latin and Chinese and follow it as the view turns. A Ø line measures the bloom and an H rod the whole plant. Once the flower has opened, a classical poem about it is brushed in vertically with red seals. The herbarium slip shows the accession number, today's date, a Code 39 barcode and the days of growth. On a desktop, putting the caret on a key in `bloom.json` lights up the part it controls.
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
| `L` | Show or hide the plate labels |

The render panel (slider icon) sets bloom, exposure, point size, fiber opacity, sheen, wind, turbulence, depth of field, spin, and a particle budget from 65K to 410K. If the frame rate stays low, the page first lowers the render resolution and then steps the particle budget down. On phones the code and the render panel open as bottom sheets, one at a time.
