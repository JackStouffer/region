# Region

A region allocator (a.k.a arena, area, zone) for D's allocator interface. This is 
`std.experimental.allocator.building_blocks.region.Region` with two modifications

* `deallocate` now does nothing, even if it's trying to deallocate the last allocation
* Added a simple `reallocate` implementation

## Why

Region allocators are best when used for short-lived tasks or objects that you know have
a very short lifetime. For example, we know that all of the objects allocated when handling
an HTTP request  

To that end, the default implementation had two flaws. First, implementing deallocate at all
goes against the idea of the relying on a fast batch deallocate when the task/job is over.
Second, not having a `reallocate` implementation meant that it couldn't be used for arrays,
only for linked lists.
