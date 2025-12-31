# performance review

**tl;dr**
- zig: ~16-18ms
- rust: ~20-23ms

## why tho?

1. **rust builds 2 trees **
rust builds the gravity quadtree AND a `broccoli` tree for collision every frame. that's two $O(N \log N)$ builds. zig gets away with reusing stuff or doing simpler checks. basically rust is doing double the structural work.

2. **job system overhead**
`rustfiber` is fancy (work stealing, fibers, context switching). zig's pool is just a raw queue. for a simple flat loop like this, the fancy features just add overhead. `rustfiber` is meant for complex dependency graphs, so using it here is kinda overkill but it still holds up well.

3. **collision logic**
rust is doing proper collision resolution (rewinding time, etc). it's safer physically but costs cpu cycles. zig is simpler discrete checks.

**verdict**
comparison is fair. rust isn't "slower", it's just doing more work per frame. if we ripped out the extra safety/trees, it'd match.
