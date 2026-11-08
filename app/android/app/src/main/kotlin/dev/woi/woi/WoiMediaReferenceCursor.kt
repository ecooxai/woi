package dev.woi.woi

/**
 * Align once per real playback epoch, then preserve sample order. Android's
 * AudioRecord/AudioTrack timestamps can jitter by tens of milliseconds even
 * while the actual PCM clocks remain stable. Re-evaluating their offset for
 * every block duplicates/skips samples and prevents the echo filter converging.
 *
 * The owner explicitly resets this cursor for a new/flush/resumed AudioTrack or
 * an observed playback underrun. No timestamp jitter estimator or periodic
 * re-seeking is needed for the shared hardware clocks measured on Android.
 */
internal class WoiMediaReferenceCursor {
    private var nextFrame: Long? = null

    fun next(prediction: Long?, count: Int): Long? {
        require(count > 0)
        val first = nextFrame ?: prediction ?: return null
        nextFrame = first + count
        return first
    }

    fun reset() { nextFrame = null }
}
