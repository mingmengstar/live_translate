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

    /** 请求的目标采样率（ASR 侧固定按 16kHz 解码） */
    private var targetSampleRate = 16000

    /**
     * AudioRecord **实际**使用的采样率。
     *
     * ## 为什么必须单独记这一项（P0，上一版识别乱码的根因）
     *
     * `AudioRecord.Builder` 里 `setSampleRate(16000)` 只是「请求」。
     * `AudioPlaybackCapture`（系统内录）走的是 AudioFlinger 混音输出，
     * 硬件通常固定在 48000Hz，部分 ROM 会**静默忽略**我们请求的 16000
     * 并按 48000 返回数据 —— `record.state` 依然是 INITIALIZED，
     * 没有任何异常，只有 `record.sampleRate` 会如实反映真实值。
     *
     * 后果：把 48kHz 的 PCM 标称成 16kHz 喂给 sherpa-onnx，
     * 音频在时间轴上被拉长 3 倍（等于 1/3 速慢放），识别器听到的是
     * 完全失真的信号，于是吐出阿拉伯字母之类的乱码，并"听不全"。
     *
     * 所以：**必须读回真实采样率并重采样**，不能相信请求值。
     */
    private var actualSampleRate = 16000

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
        targetSampleRate = if (sampleRate > 0) sampleRate else 16000
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
                .setSampleRate(targetSampleRate)
                .setChannelMask(AudioFormat.CHANNEL_IN_MONO)
                .build()

            val minBuffer = AudioRecord.getMinBufferSize(
                targetSampleRate,
                AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT
            )
            // 至少 4 × 20ms 的缓冲，避免 read 过短导致丢帧
            val bufferSize = maxOf(minBuffer, targetSampleRate / 50 * 2 * 4)

            val record = AudioRecord.Builder()
                .setAudioFormat(format)
                .setBufferSizeInBytes(bufferSize)
                .setAudioPlaybackCaptureConfig(captureConfig)
                .build()

            if (record.state != AudioRecord.STATE_INITIALIZED) {
                record.release()
                throw IllegalStateException("AudioRecord 初始化失败 state=${record.state}")
            }

            // ---- 关键：读回真实采样率 ----
            //
            // 内录路径上系统经常无视请求值（详见 actualSampleRate 注释）。
            // 这里必须相信 record.sampleRate，而不是我们认为请求成功的 targetSampleRate。
            actualSampleRate = record.sampleRate.takeIf { it > 0 } ?: targetSampleRate

            audioRecord = record
            record.startRecording()
            recording = true
            isCapturing = true

            // 每块的「输出」字节数固定按目标采样率算：20ms 的 PCM16 单声道
            val chunkBytes = targetSampleRate / 50 * 2
            recordThread = Thread(
                { readLoop(record, chunkBytes) },
                "LiveTranslate-AudioCapture"
            ).also { it.start() }

            Log.i(
                TAG,
                "系统内录已启动: 请求=${targetSampleRate}Hz 实际=${actualSampleRate}Hz " +
                    "mono pcm16, outChunk=${chunkBytes}B, " +
                    "resample=${actualSampleRate != targetSampleRate}"
            )
        } catch (e: Exception) {
            Log.e(TAG, "beginCapture 失败: ${e.message}", e)
            releaseAll()
            stopSelf()
        }
    }

    /**
     * 采集循环
     *
     * 按 **实际采样率** 读取，再重采样到 [targetSampleRate] 后按固定块长
     * 投递给 Dart 侧。这样 ASR 收到的永远是「20ms @ 16kHz」的规格，
     * 与它 `acceptWaveform(sampleRate = 16000)` 的声明一致。
     *
     * @param outChunkBytes 每次投递的字节数（20ms @ 目标采样率）
     */
    private fun readLoop(record: AudioRecord, outChunkBytes: Int) {
        val srcSamplesPerChunk = (actualSampleRate / 50).coerceAtLeast(1)
        // 按实际采样率读，留 2 倍余量应对调度抖动
        val srcBuffer = ShortArray(srcSamplesPerChunk * 2)
        val pending = ShortArray(outChunkBytes / 2)
        var pendingCount = 0

        val sameRate = actualSampleRate == targetSampleRate
        val ratio = actualSampleRate.toDouble() / targetSampleRate.toDouble()

        // 下一个输出样本在「本块源样本」中的位置。
        // 块结束后减去 read，因此可能为负 —— 负数表示落在
        // 「上一块最后一个样本 ~ 本块第 0 个样本」之间。
        var nextSrcPos = 0.0
        var prevSample = 0

        try {
            while (recording) {
                val read = record.read(srcBuffer, 0, srcBuffer.size)
                if (read <= 0) {
                    if (read < 0) {
                        Log.w(TAG, "AudioRecord.read 错误码: $read")
                        break
                    }
                    continue
                }

                if (sameRate) {
                    // 无需重采样：直接按 outChunkBytes 切块投递
                    var offset = 0
                    while (offset < read) {
                        val take = minOf(pending.size - pendingCount, read - offset)
                        System.arraycopy(srcBuffer, offset, pending, pendingCount, take)
                        pendingCount += take
                        offset += take
                        if (pendingCount == pending.size) {
                            emit(shortsToBytes(pending, pending.size))
                            pendingCount = 0
                        }
                    }
                    continue
                }

                // ---- 线性插值重采样 ----
                //
                // 这是一个标准的「输出驱动 + 相位累加」实现：
                // nextSrcPos 是下一个输出点在源样本中的浮点位置，
                // 每输出一个样本前进 ratio 个源样本。
                while (true) {
                    val idx: Int
                    val frac: Double
                    if (nextSrcPos < 0.0) {
                        // 落在上一块的尾巴与本块首样本之间
                        idx = -1
                        frac = nextSrcPos + 1.0
                    } else {
                        idx = nextSrcPos.toInt()
                        if (idx >= read - 1) break // 本块不够，留给下一块
                        frac = nextSrcPos - idx
                    }

                    val a: Int = if (idx < 0) prevSample else srcBuffer[idx].toInt()
                    val b: Int = if (idx < 0) srcBuffer[0].toInt() else srcBuffer[idx + 1].toInt()
                    pending[pendingCount++] =
                        interpolate(a, b, frac).toShort()

                    if (pendingCount == pending.size) {
                        emit(shortsToBytes(pending, pending.size))
                        pendingCount = 0
                    }

                    nextSrcPos += ratio
                }

                prevSample = srcBuffer[read - 1].toInt()
                nextSrcPos -= read.toDouble()
            }
        } catch (e: Exception) {
            Log.e(TAG, "读取音频失败: ${e.message}", e)
        }
    }

    private fun interpolate(a: Int, b: Int, frac: Double): Int {
        val v = a + (b - a) * frac.coerceIn(0.0, 1.0)
        return v.toInt().coerceIn(Short.MIN_VALUE.toInt(), Short.MAX_VALUE.toInt())
    }

    private fun shortsToBytes(samples: ShortArray, count: Int): ByteArray {
        val out = ByteArray(count * 2)
        for (i in 0 until count) {
            val s = samples[i].toInt()
            out[i * 2] = (s and 0xFF).toByte()
            out[i * 2 + 1] = ((s shr 8) and 0xFF).toByte()
        }
        return out
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