package com.example.xpos_camera

import android.media.AudioManager
import android.media.MediaActionSound
import android.media.ToneGenerator
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channelName = "xpos_camera/audio"
    private val mainHandler by lazy { Handler(Looper.getMainLooper()) }
    private val shutterSound: MediaActionSound by lazy {
        MediaActionSound().apply { load(MediaActionSound.SHUTTER_CLICK) }
    }

    private fun playToneClick(volume: Float): Boolean {
        val toneVolume = (volume * 100f).toInt().coerceIn(1, 100)
        return try {
            val tone = ToneGenerator(AudioManager.STREAM_MUSIC, toneVolume)
            val started = tone.startTone(ToneGenerator.TONE_PROP_BEEP, 90)
            if (started) {
                mainHandler.postDelayed({
                    try {
                        tone.release()
                    } catch (_: Exception) {
                    }
                }, 120)
            } else {
                tone.release()
            }
            started
        } catch (_: Exception) {
            false
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "playShutter" -> {
                        val arg = call.argument<Double>("volume")
                        val volume = (arg ?: 1.0).toFloat().coerceIn(0f, 1f)
                        if (volume <= 0.001f) {
                            result.success(true)
                            return@setMethodCallHandler
                        }

                        val playedTone = playToneClick(volume)
                        if (playedTone) {
                            result.success(true)
                            return@setMethodCallHandler
                        }

                        // ToneGenerator가 실패하는 기기에서는 기존 셔터음을 백업으로 사용.
                        try {
                            shutterSound.play(MediaActionSound.SHUTTER_CLICK)
                            result.success(true)
                        } catch (fallback: Exception) {
                            result.error("play_failed", fallback.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    override fun onDestroy() {
        mainHandler.removeCallbacksAndMessages(null)
        try {
            shutterSound.release()
        } catch (_: Exception) {
        }
        super.onDestroy()
    }
}
