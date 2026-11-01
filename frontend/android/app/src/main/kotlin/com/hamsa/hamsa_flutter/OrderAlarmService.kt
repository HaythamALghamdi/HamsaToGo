package com.hamsa.hamsa_flutter

import android.app.Notification
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.MediaPlayer
import android.os.Build
import android.os.IBinder
import android.os.PowerManager

/**
 * Rings a looping alarm for incoming orders until staff accept them.
 *
 * Started/stopped from Dart (MethodChannel "hamsa/order_alarm") based on the
 * number of orders still in the "received" state: start when the first new
 * order arrives, stop when staff move it to "preparing" (received count → 0).
 *
 * Runs as a foreground service so it keeps ringing with the app backgrounded
 * or the screen off, and plays on the ALARM stream so it's audible even when
 * media volume is low. A full-screen-intent notification wakes the screen and
 * opens the dashboard.
 */
class OrderAlarmService : Service() {

    private var player: MediaPlayer? = null
    private var wakeLock: PowerManager.WakeLock? = null

    companion object {
        const val ACTION_START = "com.hamsa.hamsa_flutter.ALARM_START"
        const val ACTION_STOP = "com.hamsa.hamsa_flutter.ALARM_STOP"
        const val CHANNEL_ID = "order_alarm"
        const val NOTIF_ID = 4711
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopAlarm()
            return START_NOT_STICKY
        }
        startAlarm()
        return START_STICKY
    }

    private fun startAlarm() {
        startForeground(NOTIF_ID, buildNotification())
        if (player != null) return // already ringing

        // Keep the CPU awake for audio while the screen is off (safety timeout).
        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
        wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "hamsa:order_alarm")
            .apply { acquire(10 * 60 * 1000L) }

        val attrs = AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_ALARM)
            .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
            .build()

        try {
            val afd = resources.openRawResourceFd(R.raw.new_order)
            player = MediaPlayer().apply {
                setAudioAttributes(attrs)
                setDataSource(afd.fileDescriptor, afd.startOffset, afd.length)
                afd.close()
                isLooping = true
                prepare()
                start()
            }
        } catch (e: Exception) {
            // If audio fails, the notification still alerts; don't crash.
        }
    }

    private fun stopAlarm() {
        player?.let {
            try { it.stop() } catch (_: Exception) {}
            it.release()
        }
        player = null
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    override fun onDestroy() {
        stopAlarm()
        super.onDestroy()
    }

    private fun buildNotification(): Notification {
        val launch = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
        }
        val piFlags = PendingIntent.FLAG_UPDATE_CURRENT or
            (if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M)
                PendingIntent.FLAG_IMMUTABLE else 0)
        val pi = PendingIntent.getActivity(this, 0, launch, piFlags)

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
            Notification.Builder(this, CHANNEL_ID)
        else
            @Suppress("DEPRECATION") Notification.Builder(this)

        return builder
            .setContentTitle("🔔 New order · طلب جديد")
            .setContentText("Open to accept · افتح لبدء التحضير")
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentIntent(pi)
            .setFullScreenIntent(pi, true) // wake the screen like an incoming call
            .setOngoing(true)
            .setCategory(Notification.CATEGORY_CALL)
            .build()
    }
}
