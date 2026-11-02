package com.hamsa.hamsa_flutter

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.MediaPlayer
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import com.google.firebase.firestore.FirebaseFirestore
import com.google.firebase.firestore.ListenerRegistration

/**
 * Rings a looping alarm for incoming orders until staff accept them — and keeps
 * working with the app minimized or closed.
 *
 * It's a foreground service that listens to Firestore DIRECTLY (not through the
 * Flutter UI), so detection doesn't depend on the app being open: while any
 * order is in the "received" state it loops the alarm; once staff move them all
 * to "preparing" (received count → 0) it goes quiet but keeps listening.
 *
 * Started when a staff member signs in (app in foreground, so starting the
 * foreground service is allowed) and stopped on sign-out. The sound plays on
 * the ALARM stream so it's audible with media volume low, and a full-screen
 * notification wakes the screen like an incoming call.
 */
class OrderAlarmService : Service() {

    private var player: MediaPlayer? = null
    private var wakeLock: PowerManager.WakeLock? = null
    private var listener: ListenerRegistration? = null
    private var ringing = false

    companion object {
        const val ACTION_START = "com.hamsa.hamsa_flutter.ALARM_START"
        const val ACTION_STOP = "com.hamsa.hamsa_flutter.ALARM_STOP"
        const val LISTEN_CHANNEL = "order_listening"
        const val ALARM_CHANNEL = "order_alarm"
        const val FG_ID = 4710
        const val ALARM_ID = 4711
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopEverything()
            return START_NOT_STICKY
        }
        startListening()
        return START_STICKY // the system restarts it if it's ever killed
    }

    private fun startListening() {
        ensureChannels()
        startForeground(FG_ID, listeningNotification())
        if (listener != null) return // already listening
        listener = FirebaseFirestore.getInstance()
            .collection("orders")
            .whereEqualTo("status", "received")
            .addSnapshotListener { snap, err ->
                if (err != null) return@addSnapshotListener
                if ((snap?.size() ?: 0) > 0) startRinging() else stopRinging()
            }
    }

    private fun startRinging() {
        if (ringing) return
        ringing = true

        getSystemService(NotificationManager::class.java)
            .notify(ALARM_ID, alarmNotification())

        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
        wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "hamsa:order_alarm")
            .apply { acquire(60 * 60 * 1000L) } // safety cap

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
        } catch (_: Exception) {
            // If audio fails the full-screen notification still alerts.
        }
    }

    private fun stopRinging() {
        if (!ringing) return
        ringing = false
        player?.let {
            try { it.stop() } catch (_: Exception) {}
            it.release()
        }
        player = null
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
        getSystemService(NotificationManager::class.java).cancel(ALARM_ID)
    }

    private fun stopEverything() {
        listener?.remove()
        listener = null
        stopRinging()
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    override fun onDestroy() {
        stopEverything()
        super.onDestroy()
    }

    // ─── Notifications ──────────────────────────────────────────
    private fun openAppIntent(): PendingIntent {
        val launch = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
        }
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or
            (if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M)
                PendingIntent.FLAG_IMMUTABLE else 0)
        return PendingIntent.getActivity(this, 0, launch, flags)
    }

    private fun listeningNotification(): Notification {
        val b = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
            Notification.Builder(this, LISTEN_CHANNEL)
        else
            @Suppress("DEPRECATION") Notification.Builder(this)
        return b
            .setContentTitle("همسة · استقبال الطلبات")
            .setContentText("Listening for new orders")
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentIntent(openAppIntent())
            .setOngoing(true)
            .build()
    }

    private fun alarmNotification(): Notification {
        val b = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
            Notification.Builder(this, ALARM_CHANNEL)
        else
            @Suppress("DEPRECATION") Notification.Builder(this)
        return b
            .setContentTitle("🔔 New order · طلب جديد")
            .setContentText("Open to start preparing · افتح لبدء التحضير")
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentIntent(openAppIntent())
            .setFullScreenIntent(openAppIntent(), true) // wake the screen
            .setOngoing(true)
            .setCategory(Notification.CATEGORY_CALL)
            .build()
    }

    private fun ensureChannels() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val nm = getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(
            NotificationChannel(
                LISTEN_CHANNEL, "Order listener", NotificationManager.IMPORTANCE_LOW
            ).apply {
                setSound(null, null)
                setShowBadge(false)
            }
        )
        nm.createNotificationChannel(
            NotificationChannel(
                ALARM_CHANNEL, "Incoming order alarm", NotificationManager.IMPORTANCE_HIGH
            ).apply {
                setSound(null, null) // the service plays the looping sound itself
                enableVibration(true)
                setBypassDnd(true)   // best-effort: ring through Do Not Disturb
            }
        )
    }
}
