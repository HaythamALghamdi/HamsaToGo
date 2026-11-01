package com.hamsa.hamsa_flutter

import android.app.NotificationChannel
import android.app.NotificationManager
import android.media.AudioAttributes
import android.net.Uri
import android.os.Build
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity

class MainActivity : FlutterActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        createNotificationChannels()
    }

    // Android 8+ plays the sound attached to the notification channel, not
    // the one in the FCM payload — so each order status gets its own channel
    // with its own sound from res/raw. Channel settings are immutable once
    // created; changing a sound later requires shipping a new channel id.
    private fun createNotificationChannels() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return

        val manager = getSystemService(NotificationManager::class.java)
        val audioAttributes = AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_NOTIFICATION)
            .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
            .build()

        fun buildChannel(id: String, name: String, soundRes: String?) =
            NotificationChannel(id, name, NotificationManager.IMPORTANCE_HIGH).apply {
                if (soundRes != null) {
                    setSound(
                        Uri.parse("android.resource://$packageName/raw/$soundRes"),
                        audioAttributes
                    )
                }
            }

        manager.createNotificationChannels(listOf(
            // Default channel (system sound) — used for cancellations.
            buildChannel("orders", "Order updates", null),
            buildChannel("order_being_prepared", "Order being prepared", "order_being_prepared"),
            buildChannel("order_ready", "Order ready", "order_ready"),
            buildChannel("order_picked_up", "Order picked up", "order_picked_up"),
            // Staff-only: alert for every new incoming order.
            buildChannel("new_order", "New orders", "new_order"),
        ))
    }
}
