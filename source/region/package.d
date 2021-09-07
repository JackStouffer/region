/**
 * Region allocators for allocating short lived data or data which can be all be
 * deallocated at once.
 * 
 * Derived from `std.experimental.allocator.building_blocks.region`. Original code written by 
 * Andrei Alexandrescu, with contributions from Eduard Staniloiu, Sebastian Wilzbach, Iain Buclaw, @jercaianu,
 * Steven Schveighoffer, Per Nordlöw, Vladimir Panteleev, @joakim-noah, @tsbockman,
 * Sönke Ludwig, Razvan Nitu, Kai Nacke, @berni44, Jacob Carlborg, David Abdurachmanov,
 * David Nadlinger, Brian Schott
 */
module region;

import std.traits;
import std.experimental.allocator.common;
import std.experimental.allocator.building_blocks.null_allocator;
import region.internal;

/**
A `Region` allocator allocates memory straight from one contiguous chunk.
There is no deallocation, and once the region is full, allocation requests
return `null`. Therefore, `Region`s are often used (a) in conjunction with
more sophisticated allocators; or (b) for batch-style very fast allocations
that deallocate everything at once.

The region only stores three pointers, corresponding to the current position in
the store and the limits. One allocation entails rounding up the allocation
size for alignment purposes, bumping the current pointer, and comparing it
against the limit.

If `ParentAllocator` is different from $(REF_ALTTEXT `NullAllocator`, NullAllocator, std,experimental,allocator,building_blocks,null_allocator), `Region`
deallocates the chunk of memory during destruction.

The `minAlign` parameter establishes alignment. If $(D minAlign > 1), the
sizes of all allocation requests are rounded up to a multiple of `minAlign`.
Applications aiming at maximum speed may want to choose $(D minAlign = 1) and
control alignment externally.
*/
struct Region(ParentAllocator = NullAllocator, uint minAlign = platformAlignment)
{
    static assert(minAlign.isGoodStaticAlignment);
    static assert(ParentAllocator.alignment >= minAlign);

    import std.typecons : Ternary;

    /**
    The _parent allocator. Depending on whether `ParentAllocator` holds state
    or not, this is a member variable or an alias for
    `ParentAllocator.instance`.
    */
    static if (stateSize!ParentAllocator)
    {
        ParentAllocator parent;
    }
    else
    {
        alias parent = ParentAllocator.instance;
    }

    /// The current data pointers
    void* _current, _begin, _end;

    private void* roundedBegin() const pure nothrow @trusted @nogc
    {
        return cast(void*) roundUpToAlignment(cast(size_t) _begin, alignment);
    }

    /**
    Constructs a region backed by a user-provided store.
    Assumes the memory was allocated with `ParentAllocator`
    (if different from $(REF_ALTTEXT `NullAllocator`, NullAllocator, std,experimental,allocator,building_blocks,null_allocator)).
    Params:
        store = User-provided store backing up the region. If $(D
        ParentAllocator) is different from $(REF_ALTTEXT `NullAllocator`, NullAllocator, std,experimental,allocator,building_blocks,null_allocator), memory is assumed to
        have been allocated with `ParentAllocator`.
        n = Bytes to allocate using `ParentAllocator`. This constructor is only
        defined If `ParentAllocator` is different from $(REF_ALTTEXT `NullAllocator`, NullAllocator, std,experimental,allocator,building_blocks,null_allocator). If
        `parent.allocate(n)` returns `null`, the region will be initialized
        as empty (correctly initialized but unable to allocate).
        */
    this(ubyte[] store) pure nothrow @system @nogc
    {
        _begin = store.ptr;
        _end = store.ptr + store.length;
        _current = roundedBegin();
    }

    /// Ditto
    static if (!is(ParentAllocator == NullAllocator) && !stateSize!ParentAllocator)
    this(size_t n)
    {
        this(cast(ubyte[]) (parent.allocate(n.roundUpToAlignment(alignment))));
    }

    /// Ditto
    static if (!is(ParentAllocator == NullAllocator) && stateSize!ParentAllocator)
    this(ParentAllocator parent, size_t n)
    {
        this.parent = parent;
        this(cast(ubyte[]) (parent.allocate(n.roundUpToAlignment(alignment))));
    }

    /**
    If `ParentAllocator` is not `NullAllocator` and defines `deallocate`,
    the region defines a destructor that uses `ParentAllocator.deallocate` to free the
    memory chunk.
    */
    static if (!is(ParentAllocator == NullAllocator) && hasMember!(ParentAllocator, "deallocate"))
    {
        ~this()
        {
            parent.deallocate(_begin[0 .. _end - _begin]);
        }
    }

    /**
     * Rounds the given size to a multiple of the `alignment`
     */
    size_t goodAllocSize(size_t n) const pure nothrow @safe @nogc
    {
        return n.roundUpToAlignment(alignment);
    }

    /**
     * Alignment offered.
     */
    alias alignment = minAlign;

    /**
    Allocates `n` bytes of memory. The shortest path involves an alignment
    adjustment (if $(D alignment > 1)), an increment, and a comparison.
    Params:
        n = number of bytes to allocate
    Returns:
        A properly-aligned buffer of size `n` or `null` if request could not
        be satisfied.
    */
    void[] allocate(size_t n) pure nothrow @trusted @nogc
    {
        const rounded = goodAllocSize(n);
        if (n == 0 || rounded < n || available < rounded) return null;
        auto result = _current[0 .. n];
        _current += rounded;
        return result;
    }

    /**
    Allocates `n` bytes of memory aligned at alignment `a`.
    Params:
        n = number of bytes to allocate
        a = alignment for the allocated block
    Returns:
        Either a suitable block of `n` bytes aligned at `a`, or `null`.
    */
    void[] alignedAllocate(size_t n, uint a) pure nothrow @trusted @nogc
    {
        import std.math.traits : isPowerOf2;
        assert(a.isPowerOf2);

        const rounded = goodAllocSize(n);
        if (n == 0 || rounded < n || available < rounded) return null;

        // Just bump the pointer to the next good allocation
        auto newCurrent = _current.alignUpTo(a);
        if (newCurrent < _current || newCurrent > _end)
            return null;

        auto save = _current;
        _current = newCurrent;
        auto result = allocate(n);
        if (result.ptr)
        {
            assert(result.length == n);
            return result;
        }
        // Failed, rollback
        _current = save;

        return null;
    }

    /// Allocates and returns all memory available to this region.
    void[] allocateAll() pure nothrow @trusted @nogc
    {
        auto result = _current[0 .. available];
        _current = _end;
        return result;
    }

    /**
     * Expands an allocated block in place. Expansion will succeed only if the given
     * block was the last one allocated.
     */
    bool expand(ref void[] b, size_t delta) pure nothrow @safe @nogc
    {
        assert(owns(b) == Ternary.yes || b is null);
        assert((() @trusted => b.ptr + b.length <= _current)() || b is null);
        if (b is null || delta == 0) return delta == 0;
        auto newLength = b.length + delta;
        if ((() @trusted => _current < b.ptr + b.length + alignment)())
        {
            immutable currentGoodSize = this.goodAllocSize(b.length);
            immutable newGoodSize = this.goodAllocSize(newLength);
            immutable goodDelta = newGoodSize - currentGoodSize;
            // This was the last allocation! Allocate some more and we're done.
            if (goodDelta == 0
                || (() @trusted => allocate(goodDelta).length == goodDelta)())
            {
                b = (() @trusted => b.ptr[0 .. newLength])();
                assert((() @trusted => _current < b.ptr + b.length + alignment)());
                return true;
            }
        }
        return false;
    }

    /**
        Does nothing. Use `deallocateAll` instead.
    */
    bool deallocate(void[] b) pure nothrow @safe @nogc
    {
        return false;
    }

    /**
     * Sets the `_current` data pointer back to `_begin`. All existing pointers
     * and slices to memory owned by this allocator will still point to valid
     * memory after this function is called, and can have their data change out
     * from under them when more allocations occur. Therefore, this function is `@system`.
     */
    bool deallocateAll() pure nothrow @system @nogc
    {
        _current = roundedBegin();
        return true;
    }

    /**
     * Simply copies the given memory on to the end of the region's buffer and extends
     * the size of the slice. The memory originally pointed to by the given slice
     * is still there, so any remaining slices/pointers to the old data will still appear
     * to point to valid data. Therefore, this function is `@system`.
     *
     * If `b` is `null`, this function is equivalent to `allocate(newSize)`.
     * 
     * If newSize is zero, this function will set the given slice to null.
     *
     * Params:
     *     b = The chuck of memory to reallocate
     *     newSize = the desired size of the new chunk of memory
     *
     * Returns:
     *     `true` if there was enough space in the buffer and the call succeeded,
     *     `false` otherwise.
     */
    pure nothrow @system @nogc
    bool reallocate(ref void[] b, size_t newSize) 
    {
        import core.stdc.string : memcpy;

        // C standard says this is implementation defined. Mallocator deallocates
        // and then sets the chunk to null, so follow that
        if (newSize == 0)
        {
            b = null;
            return true;
        }

        assert(owns(b) == Ternary.yes || b is null, "Given memory is not owned by this allocator");
        if (_current + newSize <= _end)
        {
            void[] newMem = allocate(newSize);

            if (b !is null)
                memcpy(newMem.ptr, b.ptr, newSize);

            b = newMem;
            return true;
        }

        return false;
    }

    /**
     * Queries whether `b` has been allocated with this region.
     *
     * Params:
     *     b = Arbitrary block of memory (`null` is allowed; `owns(null)` returns `false`).
     * Returns:
     *     `true` if `b` has been allocated with this region, `false` otherwise.
     */
    Ternary owns(const void[] b) const pure nothrow @trusted @nogc
    {
        return Ternary(b && (&b[0] >= _begin) && (&b[0] + b.length <= _end));
    }

    /**
     * Returns:
     *     `Ternary.yes` if no memory has been allocated in this region,
     *     `Ternary.no` otherwise. (Never returns `Ternary.unknown`.)
     */
    Ternary empty() const pure nothrow @safe @nogc
    {
        return Ternary(_current == roundedBegin());
    }

    /**
     * Returns:
     *     Total bytes available for allocation.
     */
    size_t available() const @safe pure nothrow @nogc
    {
        return _end - _current;
    }
}

///
@system nothrow unittest
{
    import std.algorithm.comparison : max;
    import std.experimental.allocator.building_blocks.allocator_list
        : AllocatorList;
    import std.experimental.allocator.mallocator : Mallocator;
    import std.typecons : Ternary;
    // Create a scalable list of regions. Each gets at least 1MB at a time by
    // using malloc.
    auto batchAllocator = AllocatorList!(
        (size_t n) => Region!Mallocator(max(n, 1024 * 1024))
    )();
    assert(batchAllocator.empty == Ternary.yes);
    auto b = batchAllocator.allocate(101);
    assert(b.length == 101);
    assert(batchAllocator.empty ==  Ternary.no);
    // This will cause a second allocation
    b = batchAllocator.allocate(2 * 1024 * 1024);
    assert(b.length == 2 * 1024 * 1024);
    // Destructor will free the memory
}

@system nothrow @nogc unittest
{
    import std.experimental.allocator.mallocator : Mallocator;
    import std.typecons : Ternary;

    static void testAlloc(Allocator)(ref Allocator a)
    {
        assert((() pure nothrow @safe @nogc => a.empty)() ==  Ternary.yes);
        const b = a.allocate(101);
        assert(b.length == 101);
        assert((() nothrow @safe @nogc => a.owns(b))() == Ternary.yes);

        // Ensure deallocate inherits from parent allocators
        auto c = a.allocate(42);
        assert(c.length == 42);
        assert((() nothrow @nogc => a.deallocate(c))());
        assert((() pure nothrow @safe @nogc => a.empty)() ==  Ternary.no);
    }
}

@system unittest
{
    import std.experimental.allocator.mallocator : Mallocator;

    testAllocator!(() => Region!(Mallocator)(1024 * 64));
    testAllocator!(() => Region!(Mallocator, Mallocator.alignment)(1024 * 64));
}

@system nothrow @nogc unittest
{
    import std.experimental.allocator.mallocator : Mallocator;

    auto reg = Region!(Mallocator)(1024 * 64);
    auto b = reg.allocate(101);
    assert(b.length == 101);
    assert((() pure nothrow @safe @nogc => reg.expand(b, 20))());
    assert((() pure nothrow @safe @nogc => reg.expand(b, 73))());
    assert((() pure nothrow @safe @nogc => !reg.expand(b, 1024 * 64))());
    assert((() nothrow @nogc => reg.deallocateAll())());
}

// reallocate
nothrow @nogc unittest
{
    import std.algorithm.comparison : equal;
    import std.range : repeat;
    import std.experimental.allocator : makeArray, expandArray;
    import std.experimental.allocator.mallocator : Mallocator;

    auto reg = Region!(Mallocator)(1024 * 64);
    auto arr = reg.makeArray!int(repeat(10, 10));
    assert(arr.length == 10);
    assert(reg._current - reg._begin == roundUpToAlignment(int.sizeof * 10, platformAlignment));

    immutable res = reg.expandArray(arr, repeat(20, 10));
    assert(res);
    assert(arr.length == 20);
    assert(reg._current - reg._begin == roundUpToAlignment(int.sizeof * 30, platformAlignment));

    static immutable arr1 = [10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 20, 20, 20, 20, 20, 20, 20, 20, 20, 20];
    assert(arr.equal(arr1));

    immutable shouldFail = reg.expandArray(arr, 100_000);
    assert(!shouldFail);
}
