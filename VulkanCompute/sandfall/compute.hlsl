// A simple compute shader to square input values.

// The buffer that we will read from and write to.
RWStructuredBuffer<float> buffer : register(u0);

// Thread group size. We use 32x1x1 here.
[numthreads(32, 1, 1)]
void main(uint3 dtid : SV_DispatchThreadID)
{
    // Simply square the value at the current index.
    // In a real app, you'd want bounds checking here (if dtid.x < bufferSize).
    float val = buffer[dtid.x];
    buffer[dtid.x] = val * val;
}