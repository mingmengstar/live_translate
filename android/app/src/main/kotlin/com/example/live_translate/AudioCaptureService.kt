package com.example.live_translate

import android.app.Service
import android.content.Intent
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.IBinder
import android.util.Log
import androidx.annotation.RequiresApi
import io.flutter.plugin.common.EventChannel
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor
import kotlin.math.max

class AudioCaptureService : Service() {

    companion object {
        const val CHANNEL_PCM = "live_translate/audio_pcm"
        const val CHANNEL_EVENT = "live_translate/audio_event"
        const val EXTRA_MEDIA_PROJECTION = "media_projection_data"
        const val NOTIFICATION_ID = 1001
        const val SAMPLE_RATE = 16000
        const val CHANNEL_CONFIG = AudioFormat.CHANNEL_IN_MONO
        const val AUDIO_FORMAT = AudioFormat.ENCODING_PCM_16BIT
        private const val TAG = "AudioCaptureService"
        // Foreground service type constants (in case ServiceInfo doesn't have them)
        const val FOREGROUND_SERVICE_TYPE_MICROPHONE = 1
        const val FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION = 8
    }

    private var mediaProjection: MediaProjection? = null
    private var audioRecord: AudioRecord? = null
    private var isRecording = false
    private var captureThread: Thread? = null
    private var pcmEventChannel: EventChannel? = null
    private var eventEventChannel: EventChannel? = null
    private var eventSink: EventChannel.EventSink? = null
    private var pcmSink: EventChannel.EventSink? = null

    override fun onCreate() {
        super.onCreate()
        val flutterEngine = FlutterEngineCache.getInstance().get("live_translate_engine")
            ?: FlutterEngine(this).also { FlutterEngineCache.getInstance().put("live_translate_engine", it) }
        if (!flutterEngine.dartExecutor.isExecutingDart) {
            flutterEngine.dartExecutor.executeDartEntrypoint(
                io.flutter.embedding.engine.dart.DartExecutor.DartEntrypoint.createDefault()
            )
        }

        pcmEventChannel = EventChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL_PCM)
        eventEventChannel = EventChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL_EVENT)

        pcmEventChannel?.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                pcmSink = events
            }
            override fun onCancel(arguments: Any?) {
                pcmSink = null
            }
        })

        eventEventChannel?.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                eventSink = events
            }
            override fun onCancel(arguments: Any?) {
                eventSink = null
            }
        })
    }

    @RequiresApi(Build.VERSION_CODES.Q)
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val notification = createNotification()
        // Use constants from companion object
        val foregroundServiceTypes = FOREGROUND_SERVICE_TYPE_MICROPHONE or FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION
        startForeground(NOTIFICATION_ID, notification, foregroundServiceTypes)

        if (intent?.hasExtra(EXTRA_MEDIA_PROJECTION) == true) {
            val projectionData = intent.getParcelableExtra<Intent>(EXTRA_MEDIA_PROJECTION)
            val mediaProjectionManager = getSystemService(MediaProjectionManager::class.java)
            mediaProjection = mediaProjectionManager.getMediaProjection(android.app.Activity.RESULT_OK, projectionData!!)
            startCapture()
        }

        return START_STICKY
    }

    private fun startCapture() {
        if (isRecording) return
        
        val minBufferSize = AudioRecord.getMinBufferSize(SAMPLE_RATE, CHANNEL_CONFIG, AUDIO_FORMAT)
        val bufferSize = max(minBufferSize * 4, SAMPLE_RATE * 2)

        val audioPlaybackCaptureConfig = android.media.AudioPlaybackCaptureConfiguration.Builder(mediaProjection!!).build()
        
        audioRecord = AudioRecord.Builder()
            .setAudioSource(MediaRecorder.AudioSource.REMOTE_SUBMIX)
            .setAudioFormat(android.media.AudioFormat.Builder()
                .setEncoding(AUDIO_FORMAT)
                .setSampleRate(SAMPLE_RATE)
                .setChannelMask(CHANNEL_CONFIG)
                .build())
            .setBufferSizeInBytes(bufferSize)
            .build()

        audioRecord?.startRecording()
        isRecording = true

        captureThread = Thread {
            val buffer = ByteArray(bufferSize)
            while (isRecording) {
                val read = audioRecord?.read(buffer, 0, bufferSize, AudioRecord.READ_BLOCKING) ?: 0
                if (read > 0) {
                    val pcmData = buffer.copyOfRange(0, read)
                    pcmSink?.success(pcmData)
                } else if (read < 0) {
                    Log.e(TAG, "AudioRecord read error: $read")
                }
            }
        }.also { it.start() }

        eventSink?.success(mapOf("event" to "started", "sampleRate" to SAMPLE_RATE))
    }

    private fun stopCapture() {
        isRecording = false
        captureThread?.interrupt()
        captureThread?.join(500)
        audioRecord?.stop()
        audioRecord?.release()
        audioRecord = null
        mediaProjection?.stop()
        mediaProjection = null
        eventSink?.success(mapOf("event" to "stopped"))
    }

    private fun createNotification(): android.app.Notification {
        val channelId = "audio_capture_channel"
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = android.app.NotificationChannel(
                channelId, "音频捕获服务", android.app.NotificationManager.IMPORTANCE_LOW
            )
            getSystemService(android.app.NotificationManager::class.java).createNotificationChannel(channel)
        }
        return android.app.Notification.Builder(this, channelId)
            .setContentTitle("实时同传 - 音频捕获中")
            .setContentText("正在捕获系统内部音频...")
            .setSmallIcon(android.R.drawable.ic_media_play)
            .setOngoing(true)
            .build()
    }

    override fun onDestroy() {
        stopCapture()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null
}