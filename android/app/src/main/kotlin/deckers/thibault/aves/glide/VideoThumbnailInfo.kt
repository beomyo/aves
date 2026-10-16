package deckers.thibault.aves.glide

import android.util.LruCache

// Durations probed while extracting a video thumbnail, keyed by the URI the
// retriever was opened on. This lets other callers (the media fetch channel)
// read the duration of a video that was just thumbnailed, without opening the
// file a second time. Process-local by design: the Dart side persists whatever
// it reads, so the cost of a miss after a restart is bounded.
object VideoThumbnailInfo {
    private const val MAX_ENTRIES = 2048

    private val durations = LruCache<String, Long>(MAX_ENTRIES)

    fun putDuration(uri: String, durationMillis: Long) {
        if (uri.isEmpty() || durationMillis <= 0) return
        durations.put(uri, durationMillis)
    }

    fun duration(uri: String): Long? = durations.get(uri)
}
