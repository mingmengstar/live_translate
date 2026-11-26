package com.example.live_translate

import android.app.Activity
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioPlaybackCaptureConfiguration
import android.media.AudioRecord
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.EventChannel
import java.util.ArrayDeque

/**
 * 系统音频内录前台服务（自研实现，替代损坏的 system_audio_recorder 插件）。
 *
 * 关键点（Android 14 强制要求，顺序不能颠倒）：
 * 1. `startForeground()` 必须先于 `getMediaProjection()` —— 否则 SecurityException。
 * 2. `startForeground()` 必须带 `FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION` 类型 —— 否则 MissingForegroundServiceTypeException。
 * 3. 通知必须有合法 smallIcon —— 否则 Invalid notification。
 * 4. 清单必须声明 `android:foregroundServiceType="mediaProjection"`。
 *
 * 采集流程：MediaProjection → AudioPlaybackCaptureConfiguration → AudioRecord → PCM16 回调。
 */
class AudioCaptureService : Service() {

    companion object {
        private const val TAG = "AudioCaptureService"
        private const val CHANNEL_ID = "live_translate_capture"
        private const val CHANNEL_NAME = "实时翻译"
        private const val NOTIFICATION_ID = 4711

        private const val EXTRA_RESULT_CODE = "result_code"
        private const val EXTRA_RESULT_DATA = "result_data"
        private const val EXTRA_SAMPLE_RATE = "sample_rate"

        /** 屏幕录制授权返回的临时凭证（由 MainActivity 写入） */
        @Volatile
        var grantedResultCode: Int = Activity.RESULT_CANCELED
        @Volatile
        var grantedResultData: Intent? = null

        @Volatile
        private var eventSink: EventChannel.EventSink? = null

        private val mainHandler = Handler(Looper.getMainLooper())
        private val pendingChunks = ArrayDeque<ByteArray>()
        private const val MAX_PENDING = 100

        @Volatile
        var isCapturing: Boolean = false
            private set

        /** EventChannel 监听建立/断开时调用；建立时把积压数据补发出去 */
        fun attachSink(sink: EventChannel.EventSink?) {
            eventSink = sink
            if (sink == null) {
                synchronized(pendingChunks) { pendingChunks.clear() }
                return
            }
            mainHandler.post {
                synchronized(pendingChunks) {
                    while (pendingChunks.isNotEmpty()) {
                        sink.success(pendingChunks.pollFirst())
                    }
                }
            }
        }

        /** 把 PCM 块投递到 Dart 侧（主线程回调） */
        fun emit(pcm: ByteArray) {
            if (pcm.isEmpty()) return
            mainHandler.post {
                val sink = eventSink
                if (sink != null) {
                    sink.success(pcm)
                } else {
                    synchronized(pendingChunks) {
                        if (pendingChunks.size >= MAX_PENDING) pendingChunks.pollFirst()
                        pendingChunks.addLast(pcm)
                    }
                }
            }
        }

        /** 启动前台服务并开始内录 */
        fun startCapture(context: Context, sampleRate: Int): Boolean {
            val code = grantedResultCode
            val data = grantedResultData
            if (code != Activity.RESULT_OK || data == null) {
                Log.w(TAG, "startCapture: 缺少有效的屏幕录制授权凭证")
                return false
            }
            val intent = Intent(context, AudioCaptureService::class.java).apply {
                putExtra(EXTRA_RESULT_CODE, code)
                putExtra(EXTRA_RESULT_DATA, data)
                putExtra(EXTRA_SAMPLE_RATE, sampleRate)
            }
            return try {
                ContextCompat.startForegroundService(context, intent)
                true
            } catch (e: Exception) {
                Log.e(TAG, "startCapture 失败: ${e.message}", e)
                false
            }
        }

        fun stopCapture(context: Context) {
            try {
                context.stopService(Intent(context, AudioCaptureService::class.java))
            } catch (e: Exception) {
                Log.w(TAG, "stopCapture 失败: ${e.message}")
            }
        }
    }

    private var mediaProjection: MediaProjection? = null
    private var audioRecord: AudioRecord? = null
    private var recordThread: Thread? = null

    @Volatile
    private var recording = false

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // 1) 先无条件提升为前台服务，满足 Android 的 5 秒窗口 + 类型校验
        if (!enterForeground()) {
            stopSelf()
            return START_NOT_STICKY
        }

        if (intent == null) {
            stopSelf()
            return START_NOT_STICKY
        }

        val resultCode = intent.getIntExtra(EXTRA_RESULT_CODE, Activity.RESULT_CANCELED)
        val data: Intent? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            intent.getParcelableExtra(EXTRA_RESULT_DATA, Intent::class.java)
        } else {
            @Suppress("DEPRECATION")
            intent.getParcelableExtra(EXTRA_RESULT_DATA)
        }
        val sampleRate = intent.getIntExtra(EXTRA_SAMPLE_RATE, 16000)

        if (resultCode != Activity.RESULT_OK || data == null) {
            Log.w(TAG, "onStartCommand: 授权凭证无效")
            stopSelf()
            return START_NOT_STICKY
        }

        // 2) 前台服务已就绪，现在才允许获取 MediaProjection
        beginCapture(resultCode, data, sampleRate)
        return START_NOT_STICKY
    }

    /** 提升为前台服务；失败返回 false（此时必须 stopSelf，否则会崩溃） */
    private fun enterForeground(): Boolean {
        return try {
            createNotificationChannel()
            val notification = buildNotification()
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(
                    NOTIFICATION_ID,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION
                )
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
            true
        } catch (e: Exception) {
            Log.e(TAG, "enterForeground 失败: ${e.message}", e)
            false
        }
    }

    private fun createNotificationChannel() {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            CHANNEL_NAME,
            NotificationManager.IMPORTANCE_LOW
        ).apply {
            description = "录制系统音频用于实时翻译"
            setShowBadge(false)
        }
        manager.createNotificationChannel(channel)
    }

    private fun buildNotification(): android.app.Notification {
        val contentIntent = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_SINGLE_TOP
            },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("实时翻译")
            .setContentText("正在录制系统音频")
            .setSmallIcon(R.drawable.ic_notification_translate)
            .setContentIntent(contentIntent)
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .build()
    }

    private fun beginCapture(resultCode: Int, data: Intent, sampleRate: Int) {
        if (isCapturing) {
            Log.i(TAG, "beginCapture: 已在采集中，忽略重复启动")
            return
        }
        try {
            val manager = getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
            val projection = manager.getMediaProjection(resultCode, data)
                ?: throw IllegalStateException("getMediaProjection 返回 null")

            projection.registerCallback(object : MediaProjection.Callback() {
                override fun onStop() {
                    Log.i(TAG, "MediaProjection 已被系统停止")
                }
            }, mainHandler)
            mediaProjection = projection

            val captureConfig = AudioPlaybackCaptureConfiguration.Builder(projection)
                .addMatchingUsage(AudioAttributes.USAGE_MEDIA)
                .addMatchingUsage(AudioAttributes.USAGE_GAME)
                .addMatchingUsage(AudioAttributes.USAGE_UNKNOWN)
                .build()

            val format = AudioFormat.Builder()
                .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                .setSampleRate(sampleRate)
                .setChannelMask(AudioFormat.CHANNEL_IN_MONO)
                .build()

            val minBuffer = AudioRecord.getMinBufferSize(
                sampleRate,
                AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT
            )
            // 至少 4 × 20ms 的缓冲，避免 read 过短导致丢帧
            val bufferSize = maxOf(minBuffer, sampleRate / 50 * 2 * 4)

            val record = AudioRecord.Builder()
                .setAudioFormat(format)
                .setBufferSizeInBytes(bufferSize)
                .setAudioPlaybackCaptureConfig(captureConfig)
                .build()

            if (record.state != AudioRecord.STATE_INITIALIZED) {
                record.release()
                throw IllegalStateException("AudioRecord 初始化失败 state=${record.state}")
            }

            audioRecord = record
            record.startRecording()
            recording = true
            isCapturing = true

            val chunkBytes = sampleRate / 50 * 2 // 20ms 的 PCM16 单声道
            recordThread = Thread({ readLoop(record, chunkBytes) }, "LiveTranslate-AudioCapture")
                .also { it.start() }

            Log.i(TAG, "系统内录已启动: ${sampleRate}Hz mono pcm16, chunk=${chunkBytes}B")
        } catch (e: Exception) {
            Log.e(TAG, "beginCapture 失败: ${e.message}", e)
            releaseAll()
            stopSelf()
        }
    }

    private fun readLoop(record: AudioRecord, chunkBytes: Int) {
        val buffer = ByteArray(chunkBytes)
        try {
            while (recording) {
                val read = record.read(buffer, 0, buffer.size)
                if (read > 0) {
                    emit(buffer.copyOf(read))
                } else if (read < 0) {
                    Log.w(TAG, "AudioRecord.read 错误码: $read")
                    break
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "读取音频失败: ${e.message}", e)
        }
    }

    private fun releaseAll() {
        recording = false
        isCapturing = false

        recordThread?.let { thread ->
            try {
                thread.join(500)
            } catch (_: InterruptedException) {
            }
        }
        recordThread = null

        try {
            audioRecord?.let {
                if (it.recordingState == AudioRecord.RECORDSTATE_RECORDING) it.stop()
                it.release()
            }
        } catch (e: Exception) {
            Log.w(TAG, "释放 AudioRecord 失败: ${e.message}")
        }
        audioRecord = null

        try {
            mediaProjection?.stop()
        } catch (e: Exception) {
            Log.w(TAG, "释放 MediaProjection 失败: ${e.message}")
        }
        mediaProjection = null

        grantedResultCode = Activity.RESULT_CANCELED
        grantedResultData = null
    }

    override fun onDestroy() {
        Log.i(TAG, "onDestroy")
        releaseAll()
        stopForeground(STOP_FOREGROUND_REMOVE)
        super.onDestroy()
    }
}