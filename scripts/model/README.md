# Regenerating the head model

`src/robot/model.ts` is generated from a sculpt by ChelsCCT (Chelsey Creates Things),
https://www.printables.com/model/13478, licensed [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).
We use three of its parts (`head`, `chin`, `head-fin`), assembled, decimated, rescaled and re-oriented.

1. Download those three STLs from the model's files page into a folder, e.g. `stl/`.
2. Assemble, decimate and export them with Blender (4.2+), headless:

   ```sh
   P='{"finX":0,"finY":0,"finProud":3,"pivotY":10,"pivotZ":11,"headTris":3000,"chinTris":800,"finTris":480}'
   /Applications/Blender.app/Contents/MacOS/Blender -b --python scripts/model/export.py -- stl/ model.json "$P"
   ```

   `pivotY`/`pivotZ` place the jaw's hinge pins (mm, in the sculpt's frame); the `*Tris` values are the
   triangle budgets per part.
3. Encode it: `python3 scripts/model/build-model.py model.json src/robot/model.ts`.
