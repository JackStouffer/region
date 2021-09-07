/**
 * A whole bunch of functions from `std.experimental.allocator.common`
 * that were marked as `package`, so I needed to copy them over. I make
 * no guarantees as to their quality.
 */
module region.internal;

import std.traits;
import std.experimental.allocator.common;

/**
 * Is x a power of 2?
 */
bool isGoodStaticAlignment(uint x) @safe @nogc nothrow pure
{
    import std.math.traits : isPowerOf2;
    return x.isPowerOf2;
}

/**
Returns: `n` rounded up to a multiple of alignment, which must be a power of 2.
*/
@safe @nogc nothrow pure
package size_t roundUpToAlignment(size_t n, uint alignment)
{
    import std.math.traits : isPowerOf2;
    assert(alignment.isPowerOf2);
    immutable uint slack = cast(uint) n & (alignment - 1);
    const result = slack
        ? n + alignment - slack
        : n;
    assert(result >= n);
    return result;
}

/**
Aligns a pointer down to a specified alignment. The resulting pointer is less
than or equal to the given pointer.
*/
@nogc nothrow pure
package void* alignDownTo(void* ptr, uint alignment)
{
    import std.math.traits : isPowerOf2;
    assert(alignment.isPowerOf2);
    return cast(void*) (cast(size_t) ptr & ~(alignment - 1UL));
}

///
@safe @nogc nothrow pure
unittest
{
    assert(10.roundUpToAlignment(4) == 12);
    assert(11.roundUpToAlignment(2) == 12);
    assert(12.roundUpToAlignment(8) == 16);
    assert(118.roundUpToAlignment(64) == 128);
}

/**
Returns: `n` rounded down to a multiple of alignment, which must be a power of 2.
*/
@safe @nogc nothrow pure
package size_t roundDownToAlignment(size_t n, uint alignment)
{
    import std.math.traits : isPowerOf2;
    assert(alignment.isPowerOf2);
    return n & ~size_t(alignment - 1);
}

///
@safe @nogc nothrow pure
unittest
{
    assert(10.roundDownToAlignment(4) == 8);
    assert(11.roundDownToAlignment(2) == 10);
    assert(12.roundDownToAlignment(8) == 8);
    assert(63.roundDownToAlignment(64) == 0);
}

@nogc nothrow pure
void* alignUpTo(void* ptr, uint alignment)
{
    import std.math.traits : isPowerOf2;
    assert(alignment.isPowerOf2);
    immutable uint slack = cast(size_t) ptr & (alignment - 1U);
    return slack ? ptr + alignment - slack : ptr;
}

@safe @nogc nothrow pure
size_t roundUpToMultipleOf(size_t s, uint base)
{
    assert(base);
    auto rem = s % base;
    return rem ? s + base - rem : s;
}

@nogc nothrow pure
bool alignedAt(T)(T* ptr, uint alignment)
{
    return cast(size_t) ptr % alignment == 0;
}

package void testAllocator(alias make)()
{
    import std.conv : text;
    import std.math.traits : isPowerOf2;
    import std.stdio : writeln, stderr;
    import std.typecons : Ternary;
    alias A = typeof(make());
    scope(failure) stderr.writeln("testAllocator failed for ", A.stringof);

    auto a = make();

    // Test alignment
    static assert(A.alignment.isPowerOf2);

    // Test goodAllocSize
    assert(a.goodAllocSize(1) >= A.alignment,
            text(a.goodAllocSize(1), " < ", A.alignment));
    assert(a.goodAllocSize(11) >= 11.roundUpToMultipleOf(A.alignment));
    assert(a.goodAllocSize(111) >= 111.roundUpToMultipleOf(A.alignment));

    // Test allocate
    assert(a.allocate(0) is null);

    auto b1 = a.allocate(1);
    assert(b1.length == 1);
    auto b2 = a.allocate(2);
    assert(b2.length == 2);
    assert(b2.ptr + b2.length <= b1.ptr || b1.ptr + b1.length <= b2.ptr);

    // Test allocateZeroed
    static if (hasMember!(A, "allocateZeroed"))
    {{
        auto b3 = a.allocateZeroed(8);
        if (b3 !is null)
        {
            assert(b3.length == 8);
            foreach (e; cast(ubyte[]) b3)
                assert(e == 0);
        }
    }}

    // Test alignedAllocate
    static if (hasMember!(A, "alignedAllocate"))
    {{
         auto b3 = a.alignedAllocate(1, 256);
         assert(b3.length <= 1);
         assert(b3.ptr.alignedAt(256));
         assert(a.alignedReallocate(b3, 2, 512));
         assert(b3.ptr.alignedAt(512));
         static if (hasMember!(A, "alignedDeallocate"))
         {
             a.alignedDeallocate(b3);
         }
     }}
    else
    {
        static assert(!hasMember!(A, "alignedDeallocate"));
        // This seems to be a bug in the compiler:
        //static assert(!hasMember!(A, "alignedReallocate"), A.stringof);
    }

    static if (hasMember!(A, "allocateAll"))
    {{
         auto aa = make();
         if (aa.allocateAll().ptr)
         {
             // Can't get any more memory
             assert(!aa.allocate(1).ptr);
         }
         auto ab = make();
         const b4 = ab.allocateAll();
         assert(b4.length);
         // Can't get any more memory
         assert(!ab.allocate(1).ptr);
     }}

    static if (hasMember!(A, "expand"))
    {{
         assert(a.expand(b1, 0));
         auto len = b1.length;
         if (a.expand(b1, 102))
         {
             assert(b1.length == len + 102, text(b1.length, " != ", len + 102));
         }
         auto aa = make();
         void[] b5 = null;
         assert(aa.expand(b5, 0));
         assert(b5 is null);
         assert(!aa.expand(b5, 1));
         assert(b5.length == 0);
     }}

    void[] b6 = null;
    assert(a.reallocate(b6, 0));
    assert(b6.length == 0);
    assert(a.reallocate(b6, 1));
    assert(b6.length == 1, text(b6.length));
    assert(a.reallocate(b6, 2));
    assert(b6.length == 2);

    // Test owns
    static if (hasMember!(A, "owns"))
    {{
         assert(a.owns(null) == Ternary.no);
         assert(a.owns(b1) == Ternary.yes);
         assert(a.owns(b2) == Ternary.yes);
         assert(a.owns(b6) == Ternary.yes);
     }}

    static if (hasMember!(A, "resolveInternalPointer"))
    {{
         void[] p;
         assert(a.resolveInternalPointer(null, p) == Ternary.no);
         Ternary r = a.resolveInternalPointer(b1.ptr, p);
         assert(p.ptr is b1.ptr && p.length >= b1.length);
         r = a.resolveInternalPointer(b1.ptr + b1.length / 2, p);
         assert(p.ptr is b1.ptr && p.length >= b1.length);
         r = a.resolveInternalPointer(b2.ptr, p);
         assert(p.ptr is b2.ptr && p.length >= b2.length);
         r = a.resolveInternalPointer(b2.ptr + b2.length / 2, p);
         assert(p.ptr is b2.ptr && p.length >= b2.length);
         r = a.resolveInternalPointer(b6.ptr, p);
         assert(p.ptr is b6.ptr && p.length >= b6.length);
         r = a.resolveInternalPointer(b6.ptr + b6.length / 2, p);
         assert(p.ptr is b6.ptr && p.length >= b6.length);
         static int[10] b7 = [ 1, 2, 3 ];
         assert(a.resolveInternalPointer(b7.ptr, p) == Ternary.no);
         assert(a.resolveInternalPointer(b7.ptr + b7.length / 2, p) == Ternary.no);
         assert(a.resolveInternalPointer(b7.ptr + b7.length, p) == Ternary.no);
         int[3] b8 = [ 1, 2, 3 ];
         assert(a.resolveInternalPointer(b8.ptr, p) == Ternary.no);
         assert(a.resolveInternalPointer(b8.ptr + b8.length / 2, p) == Ternary.no);
         assert(a.resolveInternalPointer(b8.ptr + b8.length, p) == Ternary.no);
     }}
}