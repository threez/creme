# ===========================================================================
# ObjectPool(T): a reusable-object pool for hot allocation sites (see
# Interpreter#apply's per-call VM, eval/vm.cr) whose objects need per-use
# *isolation*, not a per-use *lifetime* — so instead of allocating one per
# call and discarding it, we hand out a reset object and take it back.
#
# Policy (all three requested behaviours):
#   - min size   — `min` objects are pre-created and the free list never
#                  declines below them, so a steady baseline working set is
#                  always warm (no cold-start reallocation).
#   - growth     — unbounded: acquire allocates a fresh object whenever the
#                  free list is empty, so a demand spike is never blocked.
#   - slow decline — every DECAY_INTERVAL acquires, shed only a FRACTION of
#                  the surplus that stayed idle across the whole interval
#                  (tracked as `idle_low`, the free list's low-water mark),
#                  never below `min`. A burst is absorbed by growth and then
#                  handed back gradually rather than dumped at once, so
#                  bursty-but-steady load doesn't thrash the allocator.
#
# Not fiber-safe by construction: acquire/release do a bare Array push/pop,
# which is atomic only under Crystal's default single-thread cooperative
# scheduler (no preemption between yields). A pool shared across threads
# (preview_mt) would need external synchronisation.
module Scheme
  class ObjectPool(T)
    DECAY_INTERVAL = 1024
    DECAY_FRACTION =    4

    def initialize(@min : Int32, @reset : T -> Nil, &@factory : -> T)
      @free = [] of T
      @min.times { @free << @factory.call }
      @idle_low = @free.size
      @since_decay = 0
    end

    def acquire : T
      obj = @free.pop? || @factory.call
      @idle_low = @free.size if @free.size < @idle_low
      @since_decay += 1
      decay if @since_decay >= DECAY_INTERVAL
      obj
    end

    def release(obj : T) : Nil
      @reset.call(obj)
      @free << obj
    end

    # Test/introspection: current idle count.
    def idle : Int32
      @free.size
    end

    private def decay : Nil
      surplus = @idle_low - @min
      if surplus > 0
        shed = Math.max(1, surplus // DECAY_FRACTION)
        shed.times do
          break unless @free.size > @min
          @free.pop
        end
      end
      @idle_low = @free.size
      @since_decay = 0
    end
  end
end
