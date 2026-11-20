#include <gc.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <dlfcn.h>
#include <os/log.h>
#include <os/signpost.h>

/* TSV sources: 1=GC collection enum, 2=GC thread enum (actor is Mach port),
 * 3=phase marker (type 2*phase begin, 2*phase+1 end; value is run id),
 * 5=worker map (actor is Mach port, value is native TID).  Phase 1 is read;
 * phase 2 is one mark call.  mark is the mark index or UINT32_MAX. */
#define EVENT_CAPACITY 65536

typedef struct {
  uint64_t mach_ticks;
  uint64_t actor;
  uint64_t value;
  uint32_t source;
  int32_t type;
  uint32_t slot;
  uint32_t mark;
} CompactJSONGCProbeEvent;

enum {
  SOURCE_COLLECTION = 1,
  SOURCE_THREAD = 2,
  SOURCE_MARKER = 3,
  SOURCE_THREAD_MAP = 5,
};

enum {
  PHASE_READ = 1,
  PHASE_MARK = 2,
};

static CompactJSONGCProbeEvent *events;
static _Atomic uint64_t event_count;
static _Atomic uint64_t dropped_count;
static mach_timebase_info_data_t timebase;
static os_log_t signpost_log;

static void append_event(uint32_t source, int32_t type, uint64_t actor,
                         uint64_t value, uint32_t slot, uint32_t mark) {
  uint64_t index = atomic_fetch_add_explicit(&event_count, 1, memory_order_relaxed);
  if (index >= EVENT_CAPACITY) {
    atomic_fetch_add_explicit(&dropped_count, 1, memory_order_relaxed);
    return;
  }
  events[index] = (CompactJSONGCProbeEvent){
      mach_absolute_time(), actor, value, source, type, slot, mark};
}

static uint64_t current_tid(void) {
  uint64_t tid = 0;
  pthread_threadid_np(NULL, &tid);
  return tid;
}

static void on_collection(GC_EventType event) {
  append_event(SOURCE_COLLECTION, (int32_t)event, 0, 0, UINT32_MAX, UINT32_MAX);
}

static void on_thread(GC_EventType event, void *thread_id) {
  append_event(SOURCE_THREAD, (int32_t)event,
               (uint64_t)(uintptr_t)thread_id, 0, UINT32_MAX, UINT32_MAX);
}

void gcprobe_install(void) {
  if (events != NULL) return;
  events = calloc(EVENT_CAPACITY, sizeof(*events));
  if (events == NULL) abort();
  mach_timebase_info(&timebase);
  signpost_log = os_log_create("com.crystal.click.compact-json-gc-probe",
                               OS_LOG_CATEGORY_POINTS_OF_INTEREST);
  GC_init();
  GC_set_on_collection_event(on_collection);
  GC_set_on_thread_event(on_thread);
}

void gcprobe_register_current_thread(uint32_t slot) {
  uint64_t tid = current_tid();
  uint64_t port = (uint64_t)pthread_mach_thread_np(pthread_self());
  append_event(SOURCE_THREAD_MAP, 0, port, tid, slot, UINT32_MAX);
}

uint64_t gcprobe_signpost_begin(uint32_t phase, uint64_t run_id,
                                uint32_t worker_slot, uint32_t mark_index) {
  os_signpost_id_t signpost_id = os_signpost_id_generate(signpost_log);
  uint64_t tid = current_tid();
  append_event(SOURCE_MARKER, (int32_t)(phase * 2), tid, run_id,
               worker_slot, mark_index);
  if (phase == PHASE_READ) {
    os_signpost_interval_begin(signpost_log, signpost_id, "read",
                               "run=%{public}llu", run_id);
  } else if (phase == PHASE_MARK) {
    os_signpost_interval_begin(signpost_log, signpost_id, "mark",
                               "run=%{public}llu slot=%{public}u mark=%{public}u", run_id,
                               worker_slot, mark_index);
  } else {
    os_signpost_interval_begin(signpost_log, signpost_id, "other",
                               "run=%{public}llu", run_id);
  }
  return (uint64_t)signpost_id;
}

void gcprobe_signpost_end(uint32_t phase, uint64_t signpost_id_value,
                          uint64_t run_id, uint32_t worker_slot,
                          uint32_t mark_index) {
  os_signpost_id_t signpost_id = (os_signpost_id_t)signpost_id_value;
  uint64_t tid = current_tid();
  append_event(SOURCE_MARKER, (int32_t)(phase * 2 + 1), tid, run_id,
               worker_slot, mark_index);
  if (phase == PHASE_READ) {
    os_signpost_interval_end(signpost_log, signpost_id, "read",
                             "run=%{public}llu", run_id);
  } else if (phase == PHASE_MARK) {
    os_signpost_interval_end(signpost_log, signpost_id, "mark",
                             "run=%{public}llu slot=%{public}u mark=%{public}u", run_id,
                             worker_slot, mark_index);
  } else {
    os_signpost_interval_end(signpost_log, signpost_id, "other",
                             "run=%{public}llu", run_id);
  }
}

void gcprobe_dump_events(void) {
  if (events == NULL) return;
  Dl_info info = {0};
  (void)dladdr((void *)(uintptr_t)GC_get_version, &info);
  unsigned version = GC_get_version();
  uint64_t count = atomic_load_explicit(&event_count, memory_order_relaxed);
  uint64_t dropped = atomic_load_explicit(&dropped_count, memory_order_relaxed);
  if (count > EVENT_CAPACITY) count = EVENT_CAPACITY;

  fprintf(stderr,
          "GCBOEHM_META\tschema=compact_json_gc_trace_v1\tclock=mach_absolute_time"
          "\ttimebase_numer=%u\ttimebase_denom=%u\tlibgc_version=%u.%u.%u"
          "\tlibgc_base=%p\tlibgc_path=%s\tdropped=%llu\n",
          timebase.numer, timebase.denom, version >> 16, (version >> 8) & 0xff,
          version & 0xff, info.dli_fbase, info.dli_fname ? info.dli_fname : "unknown",
          (unsigned long long)dropped);
  fprintf(stderr,
          "GCBOEHM_EVENT\tmach_ticks\tsource\ttype\tactor\tvalue\tslot\tmark\n");
  for (uint64_t i = 0; i < count; ++i) {
    CompactJSONGCProbeEvent event = events[i];
    fprintf(stderr, "GCBOEHM_EVENT\t%llu\t%u\t%d\t%llu\t%llu\t%u\t%u\n",
            (unsigned long long)event.mach_ticks, event.source, event.type,
            (unsigned long long)event.actor, (unsigned long long)event.value,
            event.slot, event.mark);
  }
}
