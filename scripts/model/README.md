# Regenerating the head model

`src/robot/model.ts` is generated from the head of EMA Labs' sculpt,
https://www.printables.com/model/212558 (file `Head-normal.stl`), licensed
[CC BY 4.0](https://creativecommons.org/licenses/by/4.0/). Adapted: re-oriented, rescaled, cut into a cranium
and a jaw at the mouth line, the neck removed, decimated, and its eye bowls located.

1. Download `Head-normal.stl` from the model's files page.
2. Cut, decimate and export it with Blender (4.2+), headless:

   ```sh
   P='{"mouth":20.6,"jaw":6.4,"width":18.98,"hingeZ":7.5,"hingeY":0,"headTris":3200,"chinTris":700,"eyes":[4.3,8.4,3.0],"neckR":8.6,"neckTop":-0.8}'
   /Applications/Blender.app/Contents/MacOS/Blender -b --python scripts/model/ema_export.py -- Head-normal.stl model.json "$P"
   ```

   All lengths are mm in the sculpt: `mouth` is the mouth line's height above the bottom of the file, `jaw` the
   jaw band's depth below it, `width` the cranium's width (it becomes 0.6 head units), `eyes` the bowls'
   `[x, height above the mouth line, radius]`, `neckR`/`neckTop` the neck that is cut out of the jaw piece.
   Faces whose outward rays hit the same part again are marked as inside (drawn dark).
3. Encode it: `python3 scripts/model/build-model.py model.json src/robot/model.ts`.

`export.py`, `assemble.py` and `common.py` built the earlier head from ChelsCCT's sculpt
(https://www.printables.com/model/13478, CC BY 4.0); kept for reference.
