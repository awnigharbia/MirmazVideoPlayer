package com.jhomlala.better_player

import android.annotation.SuppressLint
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.os.Process
import com.jhomlala.better_player.DataSourceUtils.getUserAgent
import com.jhomlala.better_player.DataSourceUtils.isHTTP
import com.jhomlala.better_player.DataSourceUtils.getDataSourceFactory
import io.flutter.plugin.common.EventChannel
import io.flutter.view.TextureRegistry.SurfaceTextureEntry
import io.flutter.plugin.common.MethodChannel
import com.google.android.exoplayer2.trackselection.DefaultTrackSelector
import com.google.android.exoplayer2.ui.PlayerNotificationManager
import android.support.v4.media.session.MediaSessionCompat
import com.google.android.exoplayer2.drm.DrmSessionManager
import androidx.work.WorkManager
import androidx.work.WorkInfo
import com.google.android.exoplayer2.drm.HttpMediaDrmCallback
import com.google.android.exoplayer2.upstream.DefaultHttpDataSource
import com.google.android.exoplayer2.drm.DefaultDrmSessionManager
import com.google.android.exoplayer2.drm.FrameworkMediaDrm
import com.google.android.exoplayer2.drm.UnsupportedDrmException
import com.google.android.exoplayer2.drm.DummyExoMediaDrm
import com.google.android.exoplayer2.drm.LocalMediaDrmCallback
import com.google.android.exoplayer2.source.MediaSource
import com.google.android.exoplayer2.source.ClippingMediaSource
import com.google.android.exoplayer2.ui.PlayerNotificationManager.MediaDescriptionAdapter
import com.google.android.exoplayer2.ui.PlayerNotificationManager.BitmapCallback
import androidx.work.OneTimeWorkRequest
import android.support.v4.media.session.PlaybackStateCompat
import android.support.v4.media.MediaMetadataCompat
import android.util.Log
import android.view.PixelCopy
import android.view.Surface
import androidx.annotation.RequiresApi
import androidx.lifecycle.Observer
import com.google.android.exoplayer2.source.smoothstreaming.SsMediaSource
import com.google.android.exoplayer2.source.smoothstreaming.DefaultSsChunkSource
import com.google.android.exoplayer2.source.dash.DashMediaSource
import com.google.android.exoplayer2.source.dash.DefaultDashChunkSource
import com.google.android.exoplayer2.source.hls.HlsMediaSource
import com.google.android.exoplayer2.source.ProgressiveMediaSource
import com.google.android.exoplayer2.extractor.DefaultExtractorsFactory
import io.flutter.plugin.common.EventChannel.EventSink
import androidx.work.Data
import com.google.android.exoplayer2.*
import com.google.android.exoplayer2.audio.AudioAttributes
import com.google.android.exoplayer2.drm.DrmSessionManagerProvider
import com.google.android.exoplayer2.ext.mediasession.MediaSessionConnector
import com.google.android.exoplayer2.trackselection.TrackSelectionOverride
import com.google.android.exoplayer2.upstream.DataSource
import com.google.android.exoplayer2.upstream.DefaultDataSource
import com.google.android.exoplayer2.util.Util
import java.io.ByteArrayOutputStream
import java.io.File
import java.lang.Exception
import java.lang.IllegalStateException
import java.util.*
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.max
import kotlin.math.min

internal class BetterPlayer(
    context: Context,
    private val eventChannel: EventChannel,
    private val textureEntry: SurfaceTextureEntry,
    customDefaultLoadControl: CustomDefaultLoadControl?,
    result: MethodChannel.Result
) {
    private val exoPlayer: ExoPlayer?
    private val eventSink = QueuingEventSink()
    private val trackSelector: DefaultTrackSelector = DefaultTrackSelector(context)
    private val loadControl: LoadControl
    private var isInitialized = false
    private var surface: Surface? = null
    private var key: String? = null
    private var playerNotificationManager: PlayerNotificationManager? = null
    private var refreshHandler: Handler? = null
    private var refreshRunnable: Runnable? = null
    private var exoPlayerEventListener: Player.Listener? = null
    private var bitmap: Bitmap? = null
    private var mediaSession: MediaSessionCompat? = null
    private var drmSessionManager: DrmSessionManager? = null
    private val workManager: WorkManager
    private val workerObserverMap: HashMap<UUID, Observer<WorkInfo?>>
    private val customDefaultLoadControl: CustomDefaultLoadControl =
        customDefaultLoadControl ?: CustomDefaultLoadControl()
    private var lastSendBufferedPosition = 0L

    @Volatile
    private var isDisposed = false
    private val frameCaptureMainHandler = Handler(Looper.getMainLooper())
    private var frameCaptureHandler: Handler? = null
    private var pendingFrameCapture: FrameCaptureRequest? = null

    init {
        val loadBuilder = DefaultLoadControl.Builder()
        loadBuilder.setBufferDurationsMs(
            this.customDefaultLoadControl.minBufferMs,
            this.customDefaultLoadControl.maxBufferMs,
            this.customDefaultLoadControl.bufferForPlaybackMs,
            this.customDefaultLoadControl.bufferForPlaybackAfterRebufferMs
        )
        loadControl = loadBuilder.build()
        exoPlayer = ExoPlayer.Builder(context)
            .setTrackSelector(trackSelector)
            .setLoadControl(loadControl)
            .build()
        workManager = WorkManager.getInstance(context)
        workerObserverMap = HashMap()
        setupVideoPlayer(eventChannel, textureEntry, result)
    }

    fun setDataSource(
        context: Context,
        key: String?,
        dataSource: String?,
        formatHint: String?,
        result: MethodChannel.Result,
        headers: Map<String, String>?,
        useCache: Boolean,
        maxCacheSize: Long,
        maxCacheFileSize: Long,
        overriddenDuration: Long,
        licenseUrl: String?,
        drmHeaders: Map<String, String>?,
        cacheKey: String?,
        clearKey: String?
    ) {
        this.key = key
        isInitialized = false
        val uri = Uri.parse(dataSource)
        var dataSourceFactory: DataSource.Factory?
        val userAgent = getUserAgent(headers)
        if (licenseUrl != null && licenseUrl.isNotEmpty()) {
            val httpMediaDrmCallback =
                HttpMediaDrmCallback(licenseUrl, DefaultHttpDataSource.Factory())
            if (drmHeaders != null) {
                for ((drmKey, drmValue) in drmHeaders) {
                    httpMediaDrmCallback.setKeyRequestProperty(drmKey, drmValue)
                }
            }
            if (Util.SDK_INT < 18) {
                Log.e(TAG, "Protected content not supported on API levels below 18")
                drmSessionManager = null
            } else {
                val drmSchemeUuid = Util.getDrmUuid("widevine")
                if (drmSchemeUuid != null) {
                    drmSessionManager = DefaultDrmSessionManager.Builder()
                        .setUuidAndExoMediaDrmProvider(
                            drmSchemeUuid
                        ) { uuid: UUID? ->
                            try {
                                val mediaDrm = FrameworkMediaDrm.newInstance(uuid!!)
                                // Force L3.
                                mediaDrm.setPropertyString("securityLevel", "L3")
                                return@setUuidAndExoMediaDrmProvider mediaDrm
                            } catch (e: UnsupportedDrmException) {
                                return@setUuidAndExoMediaDrmProvider DummyExoMediaDrm()
                            }
                        }
                        .setMultiSession(false)
                        .build(httpMediaDrmCallback)
                }
            }
        } else if (clearKey != null && clearKey.isNotEmpty()) {
            drmSessionManager = if (Util.SDK_INT < 18) {
                Log.e(TAG, "Protected content not supported on API levels below 18")
                null
            } else {
                DefaultDrmSessionManager.Builder()
                    .setUuidAndExoMediaDrmProvider(
                        C.CLEARKEY_UUID,
                        FrameworkMediaDrm.DEFAULT_PROVIDER
                    ).build(LocalMediaDrmCallback(clearKey.toByteArray()))
            }
        } else {
            drmSessionManager = null
        }
        if (isHTTP(uri)) {
            dataSourceFactory = getDataSourceFactory(userAgent, headers)
            if (useCache && maxCacheSize > 0 && maxCacheFileSize > 0) {
                dataSourceFactory = CacheDataSourceFactory(
                    context,
                    maxCacheSize,
                    maxCacheFileSize,
                    dataSourceFactory
                )
            }
        } else {
            dataSourceFactory = DefaultDataSource.Factory(context)
        }
        val mediaSource = buildMediaSource(uri, dataSourceFactory, formatHint, cacheKey, context)
        if (overriddenDuration != 0L) {
            val clippingMediaSource = ClippingMediaSource(mediaSource, 0, overriddenDuration * 1000)
            exoPlayer?.setMediaSource(clippingMediaSource)
        } else {
            exoPlayer?.setMediaSource(mediaSource)
        }
        exoPlayer?.prepare()
        result.success(null)
    }

    fun setupPlayerNotification(
        context: Context, title: String, author: String?,
        imageUrl: String?, notificationChannelName: String?,
        activityName: String
    ) {
        val mediaDescriptionAdapter: MediaDescriptionAdapter = object : MediaDescriptionAdapter {
            override fun getCurrentContentTitle(player: Player): String {
                return title
            }

            @SuppressLint("UnspecifiedImmutableFlag")
            override fun createCurrentContentIntent(player: Player): PendingIntent? {
                val packageName = context.applicationContext.packageName
                val notificationIntent = Intent()
                notificationIntent.setClassName(
                    packageName,
                    "$packageName.$activityName"
                )
                notificationIntent.flags = (Intent.FLAG_ACTIVITY_CLEAR_TOP
                        or Intent.FLAG_ACTIVITY_SINGLE_TOP)
                return PendingIntent.getActivity(
                    context, 0,
                    notificationIntent,
                    PendingIntent.FLAG_IMMUTABLE
                )
            }

            override fun getCurrentContentText(player: Player): String? {
                return author
            }

            override fun getCurrentLargeIcon(
                player: Player,
                callback: BitmapCallback
            ): Bitmap? {
                if (imageUrl == null) {
                    return null
                }
                if (bitmap != null) {
                    return bitmap
                }
                val imageWorkRequest = OneTimeWorkRequest.Builder(ImageWorker::class.java)
                    .addTag(imageUrl)
                    .setInputData(
                        Data.Builder()
                            .putString(BetterPlayerPlugin.URL_PARAMETER, imageUrl)
                            .build()
                    )
                    .build()
                workManager.enqueue(imageWorkRequest)
                val workInfoObserver = Observer { workInfo: WorkInfo? ->
                    try {
                        if (workInfo != null) {
                            val state = workInfo.state
                            if (state == WorkInfo.State.SUCCEEDED) {
                                val outputData = workInfo.outputData
                                val filePath =
                                    outputData.getString(BetterPlayerPlugin.FILE_PATH_PARAMETER)
                                //Bitmap here is already processed and it's very small, so it won't
                                //break anything.
                                bitmap = BitmapFactory.decodeFile(filePath)
                                bitmap?.let { bitmap ->
                                    callback.onBitmap(bitmap)
                                }
                            }
                            if (state == WorkInfo.State.SUCCEEDED || state == WorkInfo.State.CANCELLED || state == WorkInfo.State.FAILED) {
                                val uuid = imageWorkRequest.id
                                val observer = workerObserverMap.remove(uuid)
                                if (observer != null) {
                                    workManager.getWorkInfoByIdLiveData(uuid)
                                        .removeObserver(observer)
                                }
                            }
                        }
                    } catch (exception: Exception) {
                        Log.e(TAG, "Image select error: $exception")
                    }
                }
                val workerUuid = imageWorkRequest.id
                workManager.getWorkInfoByIdLiveData(workerUuid)
                    .observeForever(workInfoObserver)
                workerObserverMap[workerUuid] = workInfoObserver
                return null
            }
        }
        var playerNotificationChannelName = notificationChannelName
        if (notificationChannelName == null) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val importance = NotificationManager.IMPORTANCE_LOW
                val channel = NotificationChannel(
                    DEFAULT_NOTIFICATION_CHANNEL,
                    DEFAULT_NOTIFICATION_CHANNEL, importance
                )
                channel.description = DEFAULT_NOTIFICATION_CHANNEL
                val notificationManager = context.getSystemService(
                    NotificationManager::class.java
                )
                notificationManager.createNotificationChannel(channel)
                playerNotificationChannelName = DEFAULT_NOTIFICATION_CHANNEL
            }
        }

        playerNotificationManager = PlayerNotificationManager.Builder(
            context, NOTIFICATION_ID,
            playerNotificationChannelName!!
        ).setMediaDescriptionAdapter(mediaDescriptionAdapter).build()

        playerNotificationManager?.apply {

            exoPlayer?.let {
                setPlayer(ForwardingPlayer(exoPlayer))
                setUseNextAction(false)
                setUsePreviousAction(false)
                setUseStopAction(false)
            }

            setupMediaSession(context)?.let {
                setMediaSessionToken(it.sessionToken)
            }
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
            refreshHandler = Handler(Looper.getMainLooper())
            refreshRunnable = Runnable {
                val playbackState: PlaybackStateCompat = if (exoPlayer?.isPlaying == true) {
                    PlaybackStateCompat.Builder()
                        .setActions(PlaybackStateCompat.ACTION_SEEK_TO)
                        .setState(PlaybackStateCompat.STATE_PLAYING, position, 1.0f)
                        .build()
                } else {
                    PlaybackStateCompat.Builder()
                        .setActions(PlaybackStateCompat.ACTION_SEEK_TO)
                        .setState(PlaybackStateCompat.STATE_PAUSED, position, 1.0f)
                        .build()
                }
                mediaSession?.setPlaybackState(playbackState)
                refreshHandler?.postDelayed(refreshRunnable!!, 1000)
            }
            refreshHandler?.postDelayed(refreshRunnable!!, 0)
        }
        exoPlayerEventListener = object : Player.Listener {
            override fun onPlaybackStateChanged(playbackState: Int) {
                mediaSession?.setMetadata(
                    MediaMetadataCompat.Builder()
                        .putLong(MediaMetadataCompat.METADATA_KEY_DURATION, getDuration())
                        .build()
                )
            }
        }
        exoPlayerEventListener?.let { exoPlayerEventListener ->
            exoPlayer?.addListener(exoPlayerEventListener)
        }
        exoPlayer?.seekTo(0)
    }

    fun disposeRemoteNotifications() {
        exoPlayerEventListener?.let { exoPlayerEventListener ->
            exoPlayer?.removeListener(exoPlayerEventListener)
        }
        if (refreshHandler != null) {
            refreshHandler?.removeCallbacksAndMessages(null)
            refreshHandler = null
            refreshRunnable = null
        }
        if (playerNotificationManager != null) {
            playerNotificationManager?.setPlayer(null)
        }
        bitmap = null
    }

    private fun buildMediaSource(
        uri: Uri,
        mediaDataSourceFactory: DataSource.Factory,
        formatHint: String?,
        cacheKey: String?,
        context: Context
    ): MediaSource {
        val type: Int
        if (formatHint == null) {
            type = Util.inferContentType(uri)
        } else {
            type = when (formatHint) {
                FORMAT_SS -> C.CONTENT_TYPE_SS
                FORMAT_DASH -> C.CONTENT_TYPE_DASH
                FORMAT_HLS -> C.CONTENT_TYPE_HLS
                FORMAT_OTHER -> C.CONTENT_TYPE_OTHER
                else -> -1
            }
        }
        val mediaItemBuilder = MediaItem.Builder()
        mediaItemBuilder.setUri(uri)
        if (cacheKey != null && cacheKey.isNotEmpty()) {
            mediaItemBuilder.setCustomCacheKey(cacheKey)
        }
        val mediaItem = mediaItemBuilder.build()
        var drmSessionManagerProvider: DrmSessionManagerProvider? = null
        drmSessionManager?.let { drmSessionManager ->
            drmSessionManagerProvider = DrmSessionManagerProvider { drmSessionManager }
        }
        return when (type) {
            C.CONTENT_TYPE_SS -> SsMediaSource.Factory(
                DefaultSsChunkSource.Factory(mediaDataSourceFactory),
                DefaultDataSource.Factory(context, mediaDataSourceFactory)
            )
                .apply {
                    if (drmSessionManagerProvider != null) {
                        setDrmSessionManagerProvider(drmSessionManagerProvider!!)
                    }
                }
                .createMediaSource(mediaItem)
            C.CONTENT_TYPE_DASH -> DashMediaSource.Factory(
                DefaultDashChunkSource.Factory(mediaDataSourceFactory),
                DefaultDataSource.Factory(context, mediaDataSourceFactory)
            )
                .apply {
                    if (drmSessionManagerProvider != null) {
                        setDrmSessionManagerProvider(drmSessionManagerProvider!!)
                    }
                }
                .createMediaSource(mediaItem)
            C.CONTENT_TYPE_HLS -> HlsMediaSource.Factory(mediaDataSourceFactory)
                .apply {
                    if (drmSessionManagerProvider != null) {
                        setDrmSessionManagerProvider(drmSessionManagerProvider!!)
                    }
                }
                .createMediaSource(mediaItem)
            C.CONTENT_TYPE_OTHER -> ProgressiveMediaSource.Factory(
                mediaDataSourceFactory,
                DefaultExtractorsFactory()
            )
                .apply {
                    if (drmSessionManagerProvider != null) {
                        setDrmSessionManagerProvider(drmSessionManagerProvider!!)
                    }
                }
                .createMediaSource(mediaItem)
            else -> {
                throw IllegalStateException("Unsupported type: $type")
            }
        }
    }

    private fun setupVideoPlayer(
        eventChannel: EventChannel, textureEntry: SurfaceTextureEntry, result: MethodChannel.Result
    ) {
        eventChannel.setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(o: Any?, sink: EventSink) {
                    eventSink.setDelegate(sink)
                }

                override fun onCancel(o: Any?) {
                    eventSink.setDelegate(null)
                }
            })
        surface = Surface(textureEntry.surfaceTexture())
        exoPlayer?.setVideoSurface(surface)
        setAudioAttributes(exoPlayer, true)
        exoPlayer?.addListener(object : Player.Listener {
            override fun onPlaybackStateChanged(playbackState: Int) {
                when (playbackState) {
                    Player.STATE_BUFFERING -> {
                        sendBufferingUpdate(true)
                        val event: MutableMap<String, Any> = HashMap()
                        event["event"] = "bufferingStart"
                        eventSink.success(event)
                    }
                    Player.STATE_READY -> {
                        if (!isInitialized) {
                            isInitialized = true
                            sendInitialized()
                        }
                        val event: MutableMap<String, Any> = HashMap()
                        event["event"] = "bufferingEnd"
                        eventSink.success(event)
                    }
                    Player.STATE_ENDED -> {
                        val event: MutableMap<String, Any?> = HashMap()
                        event["event"] = "completed"
                        event["key"] = key
                        eventSink.success(event)
                    }
                    Player.STATE_IDLE -> {
                        //no-op
                    }
                }
            }

            override fun onPlayerError(error: PlaybackException) {
                // Surface the real cause chain: ExoPlayer's own message is just
                // "Source error"; the HTTP status / IOException lives in causes.
                val details = StringBuilder()
                details.append("code=").append(error.errorCodeName)
                var cause: Throwable? = error.cause
                var depth = 0
                while (cause != null && depth < 5) {
                    details.append(" <- ").append(cause.javaClass.simpleName)
                    if (cause is com.google.android.exoplayer2.upstream.HttpDataSource.InvalidResponseCodeException) {
                        details.append("(http ").append(cause.responseCode).append(")")
                    } else if (!cause.message.isNullOrBlank()) {
                        details.append("(").append(cause.message).append(")")
                    }
                    cause = cause.cause
                    depth++
                }
                eventSink.error("VideoError", "Video player had error $error", details.toString())
            }
        })
        val reply: MutableMap<String, Any> = HashMap()
        reply["textureId"] = textureEntry.id()
        result.success(reply)
    }

    fun sendBufferingUpdate(isFromBufferingStart: Boolean) {
        val bufferedPosition = exoPlayer?.bufferedPosition ?: 0L
        if (isFromBufferingStart || bufferedPosition != lastSendBufferedPosition) {
            val event: MutableMap<String, Any> = HashMap()
            event["event"] = "bufferingUpdate"
            val range: List<Number?> = listOf(0, bufferedPosition)
            // iOS supports a list of buffered ranges, so here is a list with a single range.
            event["values"] = listOf(range)
            eventSink.success(event)
            lastSendBufferedPosition = bufferedPosition
        }
    }

    @Suppress("DEPRECATION")
    private fun setAudioAttributes(exoPlayer: ExoPlayer?, mixWithOthers: Boolean) {
        val audioComponent = exoPlayer?.audioComponent ?: return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
            audioComponent.setAudioAttributes(
                AudioAttributes.Builder().setContentType(C.AUDIO_CONTENT_TYPE_MOVIE).build(),
                !mixWithOthers
            )
        } else {
            audioComponent.setAudioAttributes(
                AudioAttributes.Builder().setContentType(C.AUDIO_CONTENT_TYPE_MUSIC).build(),
                !mixWithOthers
            )
        }
    }

    fun play() {
        exoPlayer?.playWhenReady = true
    }

    fun pause() {
        exoPlayer?.playWhenReady = false
    }

    fun setLooping(value: Boolean) {
        exoPlayer?.repeatMode = if (value) Player.REPEAT_MODE_ALL else Player.REPEAT_MODE_OFF
    }

    fun setVolume(value: Double) {
        val bracketedValue = max(0.0, min(1.0, value))
            .toFloat()
        exoPlayer?.volume = bracketedValue
    }

    fun setSpeed(value: Double) {
        val bracketedValue = value.toFloat()
        val playbackParameters = PlaybackParameters(bracketedValue)
        exoPlayer?.playbackParameters = playbackParameters
    }

    fun setTrackParameters(width: Int, height: Int, bitrate: Int) {
        val parametersBuilder = trackSelector.buildUponParameters()
        if (width != 0 && height != 0) {
            parametersBuilder.setMaxVideoSize(width, height)
        }
        if (bitrate != 0) {
            parametersBuilder.setMaxVideoBitrate(bitrate)
        }
        if (width == 0 && height == 0 && bitrate == 0) {
            parametersBuilder.clearVideoSizeConstraints()
            parametersBuilder.setMaxVideoBitrate(Int.MAX_VALUE)
        }
        trackSelector.setParameters(parametersBuilder)
    }

    fun seekTo(location: Int) {
        exoPlayer?.seekTo(location.toLong())
    }

    val position: Long
        get() = exoPlayer?.currentPosition ?: 0L

    val absolutePosition: Long
        get() {
            val timeline = exoPlayer?.currentTimeline
            timeline?.let {
                if (!timeline.isEmpty) {
                    val windowStartTimeMs =
                        timeline.getWindow(0, Timeline.Window()).windowStartTimeMs
                    val pos = exoPlayer?.currentPosition ?: 0L
                    return windowStartTimeMs + pos
                }
            }
            return exoPlayer?.currentPosition ?: 0L
        }

    private fun sendInitialized() {
        if (isInitialized) {
            val event: MutableMap<String, Any?> = HashMap()
            event["event"] = "initialized"
            event["key"] = key
            event["duration"] = getDuration()
            if (exoPlayer?.videoFormat != null) {
                val videoFormat = exoPlayer.videoFormat
                var width = videoFormat?.width
                var height = videoFormat?.height
                val rotationDegrees = videoFormat?.rotationDegrees
                // Switch the width/height if video was taken in portrait mode
                if (rotationDegrees == 90 || rotationDegrees == 270) {
                    width = exoPlayer.videoFormat?.height
                    height = exoPlayer.videoFormat?.width
                }
                event["width"] = width
                event["height"] = height
            }
            eventSink.success(event)
        }
    }

    private fun getDuration(): Long = exoPlayer?.duration ?: 0L

    /**
     * Create media session which will be used in notifications, pip mode.
     *
     * @param context                - android context
     * @return - configured MediaSession instance
     */
    @SuppressLint("InlinedApi")
    fun setupMediaSession(context: Context?): MediaSessionCompat? {
        mediaSession?.release()
        context?.let {

            val mediaButtonIntent = Intent(Intent.ACTION_MEDIA_BUTTON)
            val pendingIntent = PendingIntent.getBroadcast(
                context,
                0, mediaButtonIntent,
                PendingIntent.FLAG_IMMUTABLE
            )
            val mediaSession = MediaSessionCompat(context, TAG, null, pendingIntent)
            mediaSession.setCallback(object : MediaSessionCompat.Callback() {
                override fun onSeekTo(pos: Long) {
                    sendSeekToEvent(pos)
                    super.onSeekTo(pos)
                }
            })
            mediaSession.isActive = true
            val mediaSessionConnector = MediaSessionConnector(mediaSession)
            mediaSessionConnector.setPlayer(exoPlayer)
            this.mediaSession = mediaSession
            return mediaSession
        }
        return null

    }

    fun onPictureInPictureStatusChanged(inPip: Boolean) {
        val event: MutableMap<String, Any> = HashMap()
        event["event"] = if (inPip) "pipStart" else "pipStop"
        eventSink.success(event)
    }

    fun disposeMediaSession() {
        if (mediaSession != null) {
            mediaSession?.release()
        }
        mediaSession = null
    }

    fun setAudioTrack(name: String, index: Int) {
        try {
            val mappedTrackInfo = trackSelector.currentMappedTrackInfo
            if (mappedTrackInfo != null) {
                for (rendererIndex in 0 until mappedTrackInfo.rendererCount) {
                    if (mappedTrackInfo.getRendererType(rendererIndex) != C.TRACK_TYPE_AUDIO) {
                        continue
                    }
                    val trackGroupArray = mappedTrackInfo.getTrackGroups(rendererIndex)
                    var hasElementWithoutLabel = false
                    var hasStrangeAudioTrack = false
                    for (groupIndex in 0 until trackGroupArray.length) {
                        val group = trackGroupArray[groupIndex]
                        for (groupElementIndex in 0 until group.length) {
                            val format = group.getFormat(groupElementIndex)
                            if (format.label == null) {
                                hasElementWithoutLabel = true
                            }
                            if (format.id != null && format.id == "1/15") {
                                hasStrangeAudioTrack = true
                            }
                        }
                    }
                    for (groupIndex in 0 until trackGroupArray.length) {
                        val group = trackGroupArray[groupIndex]
                        for (groupElementIndex in 0 until group.length) {
                            val label = group.getFormat(groupElementIndex).label
                            if (name == label && index == groupIndex) {
                                setAudioTrack(rendererIndex, groupIndex, groupElementIndex)
                                return
                            }

                            ///Fallback option
                            if (!hasStrangeAudioTrack && hasElementWithoutLabel && index == groupIndex) {
                                setAudioTrack(rendererIndex, groupIndex, groupElementIndex)
                                return
                            }
                            ///Fallback option
                            if (hasStrangeAudioTrack && name == label) {
                                setAudioTrack(rendererIndex, groupIndex, groupElementIndex)
                                return
                            }
                        }
                    }
                }
            }
        } catch (exception: Exception) {
            Log.e(TAG, "setAudioTrack failed$exception")
        }
    }

    private fun setAudioTrack(rendererIndex: Int, groupIndex: Int, groupElementIndex: Int) {
        val mappedTrackInfo = trackSelector.currentMappedTrackInfo
        if (mappedTrackInfo != null) {
            val builder = trackSelector.parameters.buildUpon()
                .setRendererDisabled(rendererIndex, false)
                .addOverride(TrackSelectionOverride(mappedTrackInfo.getTrackGroups(rendererIndex)
                    .get(groupIndex), rendererIndex)
                )
                .build()

            trackSelector.parameters = builder
        }
    }

    private fun sendSeekToEvent(positionMs: Long) {
        exoPlayer?.seekTo(positionMs)
        val event: MutableMap<String, Any> = HashMap()
        event["event"] = "seek"
        event["position"] = positionMs
        eventSink.success(event)
    }

    fun setMixWithOthers(mixWithOthers: Boolean) {
        setAudioAttributes(exoPlayer, mixWithOthers)
    }

    /**
     * Replies with the frame currently on the video surface as JPEG bytes. Has to be called on
     * the main thread; copying and encoding run on a background thread so playback is not held up.
     */
    fun captureFrame(watermarkText: String?, result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N) {
            result.error(
                FRAME_CAPTURE_ERROR_UNSUPPORTED, "Frame capture requires Android 7.0 or newer", null
            )
            return
        }
        if (isDisposed || pendingFrameCapture != null) {
            result.error(
                FRAME_CAPTURE_ERROR_UNAVAILABLE,
                "Player is disposed or a frame capture is already in progress",
                null
            )
            return
        }
        val captureSurface = surface
        val size = computeFrameCaptureSize()
        if (captureSurface == null || !captureSurface.isValid || size == null) {
            result.error(FRAME_CAPTURE_ERROR_UNAVAILABLE, "No video frame is available yet", null)
            return
        }
        val request = FrameCaptureRequest(
            captureSurface, size, watermarkText, result, obtainFrameCaptureHandler()
        )
        pendingFrameCapture = request
        request.handler.post { requestPixelCopy(request) }
    }

    private fun obtainFrameCaptureHandler(): Handler {
        frameCaptureHandler?.let { return it }
        val thread = HandlerThread(FRAME_CAPTURE_THREAD_NAME, Process.THREAD_PRIORITY_BACKGROUND)
        thread.start()
        return Handler(thread.looper).also { frameCaptureHandler = it }
    }

    private fun computeFrameCaptureSize(): FrameSize? {
        val videoSize = exoPlayer?.videoSize ?: return null
        //Decoder buffers hold stored pixels, so the pixel aspect ratio has to be applied here for
        //anamorphic video to come out with its display proportions.
        val width = Math.round(videoSize.width * videoSize.pixelWidthHeightRatio)
        val height = videoSize.height
        if (width <= 0 || height <= 0) {
            return null
        }
        val longerSide = max(width, height)
        if (longerSide <= FRAME_CAPTURE_MAX_SIDE) {
            return FrameSize(width, height)
        }
        //Keeps the bitmap small for 4K sources, which would otherwise need about 33 MB.
        val scale = FRAME_CAPTURE_MAX_SIDE.toFloat() / longerSide
        return FrameSize(max(1, Math.round(width * scale)), max(1, Math.round(height * scale)))
    }

    //PixelCopy reads the last queued buffer without dequeuing it, so the decoder is never
    //blocked. On older releases the call itself blocks, hence the capture thread.
    @RequiresApi(Build.VERSION_CODES.N)
    private fun requestPixelCopy(request: FrameCaptureRequest) {
        if (isDisposed || !request.surface.isValid) {
            replyFrameCaptureError(
                request, FRAME_CAPTURE_ERROR_UNAVAILABLE, "Video surface is no longer available"
            )
            return
        }
        try {
            val bitmap = request.bitmap ?: Bitmap.createBitmap(
                request.size.width, request.size.height, Bitmap.Config.ARGB_8888
            ).also { request.bitmap = it }
            PixelCopy.request(
                request.surface,
                bitmap,
                PixelCopy.OnPixelCopyFinishedListener { copyResult ->
                    onPixelCopyFinished(request, bitmap, copyResult)
                },
                request.handler
            )
        } catch (throwable: Throwable) {
            //PixelCopy throws when the surface is released underneath it and the bitmap
            //allocation can run out of memory.
            failFrameCapture(request, throwable)
        }
    }

    @RequiresApi(Build.VERSION_CODES.N)
    private fun onPixelCopyFinished(request: FrameCaptureRequest, bitmap: Bitmap, copyResult: Int) {
        if (isDisposed) {
            replyFrameCaptureError(request, FRAME_CAPTURE_ERROR_UNAVAILABLE, "Player was disposed")
            return
        }
        when (copyResult) {
            PixelCopy.SUCCESS -> replyWithEncodedFrame(request, bitmap)
            PixelCopy.ERROR_SOURCE_NO_DATA -> retryPixelCopy(request)
            else -> replyFrameCaptureError(
                request,
                pixelCopyErrorCode(copyResult, request.surface),
                "PixelCopy failed with result $copyResult"
            )
        }
    }

    //The surface has no queued buffer right after start or a seek; the next frame is usually
    //only a few milliseconds away.
    @RequiresApi(Build.VERSION_CODES.N)
    private fun retryPixelCopy(request: FrameCaptureRequest) {
        val scheduled = request.retriesLeft-- > 0 && request.handler.postDelayed(
            { requestPixelCopy(request) }, FRAME_CAPTURE_RETRY_DELAY_MS
        )
        if (!scheduled) {
            replyFrameCaptureError(
                request, FRAME_CAPTURE_ERROR_UNAVAILABLE, "No video frame has been rendered yet"
            )
        }
    }

    @RequiresApi(Build.VERSION_CODES.N)
    private fun pixelCopyErrorCode(copyResult: Int, source: Surface): String {
        return when (copyResult) {
            //Reported both for protected (DRM) buffers and for a surface destroyed during the
            //copy, so the surface state is the only way to tell the two apart.
            PixelCopy.ERROR_SOURCE_INVALID ->
                if (isDisposed || !source.isValid) {
                    FRAME_CAPTURE_ERROR_UNAVAILABLE
                } else {
                    FRAME_CAPTURE_ERROR_PROTECTED_CONTENT
                }
            else -> FRAME_CAPTURE_ERROR_COPY_FAILED
        }
    }

    private fun replyWithEncodedFrame(request: FrameCaptureRequest, bitmap: Bitmap) {
        try {
            val jpeg = encodeFrame(bitmap, request.watermarkText)
            request.recycleBitmap()
            postFrameCaptureReply(request) { it.success(jpeg) }
        } catch (throwable: Throwable) {
            failFrameCapture(request, throwable)
        }
    }

    private fun encodeFrame(bitmap: Bitmap, watermarkText: String?): ByteArray {
        drawWatermark(bitmap, watermarkText)
        val output = ByteArrayOutputStream()
        check(bitmap.compress(Bitmap.CompressFormat.JPEG, FRAME_CAPTURE_JPEG_QUALITY, output)) {
            "JPEG compression failed"
        }
        return output.toByteArray()
    }

    private fun drawWatermark(bitmap: Bitmap, text: String?) {
        if (text.isNullOrBlank()) {
            return
        }
        val textSize = max(
            WATERMARK_MIN_TEXT_SIZE, WATERMARK_TEXT_SIZE_RATIO * min(bitmap.width, bitmap.height)
        )
        val paint = Paint(Paint.ANTI_ALIAS_FLAG)
        paint.color = Color.argb(WATERMARK_ALPHA, 255, 255, 255)
        paint.textSize = textSize
        paint.textAlign = Paint.Align.CENTER
        paint.setShadowLayer(textSize / 8, 0f, 0f, Color.argb(WATERMARK_ALPHA, 0, 0, 0))
        //Text is positioned by its baseline, so shift it to put the glyphs' middle on the centre.
        val baseline = bitmap.height / 2f - (paint.ascent() + paint.descent()) / 2f
        Canvas(bitmap).drawText(text, bitmap.width / 2f, baseline, paint)
    }

    private fun failFrameCapture(request: FrameCaptureRequest, cause: Throwable) {
        Log.e(TAG, "Frame capture failed: $cause")
        val code =
            if (isDisposed) FRAME_CAPTURE_ERROR_UNAVAILABLE else FRAME_CAPTURE_ERROR_COPY_FAILED
        replyFrameCaptureError(request, code, cause.toString())
    }

    private fun replyFrameCaptureError(
        request: FrameCaptureRequest, code: String, message: String
    ) {
        request.recycleBitmap()
        postFrameCaptureReply(request) { it.error(code, message, null) }
    }

    private fun postFrameCaptureReply(
        request: FrameCaptureRequest, reply: (MethodChannel.Result) -> Unit
    ) {
        frameCaptureMainHandler.post { completeFrameCapture(request, reply) }
    }

    //Runs on the main thread only. A capture can finish after dispose() has already answered
    //it, and replying to the same channel call twice throws.
    private fun completeFrameCapture(
        request: FrameCaptureRequest, reply: (MethodChannel.Result) -> Unit
    ) {
        if (!request.replied.compareAndSet(false, true)) {
            return
        }
        if (pendingFrameCapture === request) {
            pendingFrameCapture = null
        }
        reply(request.result)
    }

    private fun disposeFrameCapture() {
        pendingFrameCapture?.let { request ->
            completeFrameCapture(request) {
                it.error(FRAME_CAPTURE_ERROR_UNAVAILABLE, "Player was disposed", null)
            }
        }
        //The capture thread only ever exists on API 24+. Quitting safely lets a running copy
        //finish instead of making the main thread wait for it.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            frameCaptureHandler?.looper?.quitSafely()
        }
        frameCaptureHandler = null
    }

    fun dispose() {
        isDisposed = true
        disposeFrameCapture()
        disposeMediaSession()
        disposeRemoteNotifications()
        if (isInitialized) {
            exoPlayer?.stop()
        }
        textureEntry.release()
        eventChannel.setStreamHandler(null)
        surface?.release()
        exoPlayer?.release()
    }

    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other == null || javaClass != other.javaClass) return false
        val that = other as BetterPlayer
        if (if (exoPlayer != null) exoPlayer != that.exoPlayer else that.exoPlayer != null) return false
        return if (surface != null) surface == that.surface else that.surface == null
    }

    override fun hashCode(): Int {
        var result = exoPlayer?.hashCode() ?: 0
        result = 31 * result + if (surface != null) surface.hashCode() else 0
        return result
    }

    private class FrameSize(val width: Int, val height: Int)

    //State of a single captureFrame call. bitmap and retriesLeft are only touched on the
    //capture thread.
    private class FrameCaptureRequest(
        val surface: Surface,
        val size: FrameSize,
        val watermarkText: String?,
        val result: MethodChannel.Result,
        val handler: Handler
    ) {
        val replied = AtomicBoolean(false)
        var bitmap: Bitmap? = null
        var retriesLeft = FRAME_CAPTURE_MAX_RETRIES

        fun recycleBitmap() {
            bitmap?.recycle()
            bitmap = null
        }
    }

    companion object {
        private const val TAG = "BetterPlayer"
        private const val FORMAT_SS = "ss"
        private const val FORMAT_DASH = "dash"
        private const val FORMAT_HLS = "hls"
        private const val FORMAT_OTHER = "other"
        private const val DEFAULT_NOTIFICATION_CHANNEL = "BETTER_PLAYER_NOTIFICATION"
        private const val NOTIFICATION_ID = 20772077
        private const val FRAME_CAPTURE_THREAD_NAME = "BetterPlayerFrameCapture"
        private const val FRAME_CAPTURE_MAX_SIDE = 1920
        private const val FRAME_CAPTURE_JPEG_QUALITY = 90
        private const val FRAME_CAPTURE_MAX_RETRIES = 2
        private const val FRAME_CAPTURE_RETRY_DELAY_MS = 80L
        private const val FRAME_CAPTURE_ERROR_UNSUPPORTED = "unsupported"
        private const val FRAME_CAPTURE_ERROR_PROTECTED_CONTENT = "protected_content"
        private const val FRAME_CAPTURE_ERROR_COPY_FAILED = "copy_failed"
        private const val FRAME_CAPTURE_ERROR_UNAVAILABLE = "unavailable"
        private const val WATERMARK_MIN_TEXT_SIZE = 14f
        private const val WATERMARK_TEXT_SIZE_RATIO = 0.035f
        //45% opacity.
        private const val WATERMARK_ALPHA = 115

        //Clear cache without accessing BetterPlayerCache.
        fun clearCache(context: Context?, result: MethodChannel.Result) {
            try {
                context?.let { context ->
                    val file = File(context.cacheDir, "betterPlayerCache")
                    deleteDirectory(file)
                }
                result.success(null)
            } catch (exception: Exception) {
                Log.e(TAG, exception.toString())
                result.error("", "", "")
            }
        }

        private fun deleteDirectory(file: File) {
            if (file.isDirectory) {
                val entries = file.listFiles()
                if (entries != null) {
                    for (entry in entries) {
                        deleteDirectory(entry)
                    }
                }
            }
            if (!file.delete()) {
                Log.e(TAG, "Failed to delete cache dir.")
            }
        }

        //Start pre cache of video. Invoke work manager job and start caching in background.
        fun preCache(
            context: Context?, dataSource: String?, preCacheSize: Long,
            maxCacheSize: Long, maxCacheFileSize: Long, headers: Map<String, String?>,
            cacheKey: String?, result: MethodChannel.Result
        ) {
            val dataBuilder = Data.Builder()
                .putString(BetterPlayerPlugin.URL_PARAMETER, dataSource)
                .putLong(BetterPlayerPlugin.PRE_CACHE_SIZE_PARAMETER, preCacheSize)
                .putLong(BetterPlayerPlugin.MAX_CACHE_SIZE_PARAMETER, maxCacheSize)
                .putLong(BetterPlayerPlugin.MAX_CACHE_FILE_SIZE_PARAMETER, maxCacheFileSize)
            if (cacheKey != null) {
                dataBuilder.putString(BetterPlayerPlugin.CACHE_KEY_PARAMETER, cacheKey)
            }
            for (headerKey in headers.keys) {
                dataBuilder.putString(
                    BetterPlayerPlugin.HEADER_PARAMETER + headerKey,
                    headers[headerKey]
                )
            }
            if (dataSource != null && context != null) {
                val cacheWorkRequest = OneTimeWorkRequest.Builder(CacheWorker::class.java)
                    .addTag(dataSource)
                    .setInputData(dataBuilder.build()).build()
                WorkManager.getInstance(context).enqueue(cacheWorkRequest)
            }
            result.success(null)
        }

        //Stop pre cache of video with given url. If there's no work manager job for given url, then
        //it will be ignored.
        fun stopPreCache(context: Context?, url: String?, result: MethodChannel.Result) {
            if (url != null && context != null) {
                WorkManager.getInstance(context).cancelAllWorkByTag(url)
            }
            result.success(null)
        }
    }

}