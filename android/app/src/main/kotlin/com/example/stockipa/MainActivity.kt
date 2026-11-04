package com.example.stockipa

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONException
import org.json.JSONObject
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private lateinit var smsChannel: MethodChannel

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        smsChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL_NAME)
        activeChannel = smsChannel
        smsChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "getStoredTransactions" -> smsExecutor.execute {
                    try {
                        recoverMissedMessages(applicationContext)
                        val messages = readPendingMessages(applicationContext)
                        mainHandler.post { result.success(messages) }
                    } catch (error: Exception) {
                        android.util.Log.e(TAG, "Could not sync stored M-Pesa messages.", error)
                        mainHandler.post {
                            result.error(
                                "sms_recovery_failed",
                                "Could not recover stored SMS messages.",
                                error.message,
                            )
                        }
                    }
                }
                "setNotificationsEnabled" -> {
                    val enabled = call.arguments as? Boolean
                    if (enabled == null) {
                        result.error(
                            "invalid_arguments",
                            "Expected a notification enabled flag.",
                            null,
                        )
                    } else {
                        getSharedPreferences(PREFERENCES_NAME, Context.MODE_PRIVATE)
                            .edit()
                            .putBoolean(NOTIFICATIONS_ENABLED_KEY, enabled)
                            .apply()
                        result.success(null)
                    }
                }
                "ackStoredTransactions" -> {
                    val ids = call.arguments as? List<*>
                    if (ids == null || ids.any { it !is String }) {
                        result.error("invalid_arguments", "Expected a list of message IDs.", null)
                    } else {
                        acknowledgeMessages(this, ids.filterIsInstance<String>().toSet())
                        result.success(null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onDestroy() {
        if (activeChannel === smsChannel) activeChannel = null
        super.onDestroy()
    }

    companion object {
        private const val CHANNEL_NAME = "stockipa/sms"
        private const val PREFERENCES_NAME = "stockipa_sms"
        private const val PENDING_MESSAGES_KEY = "pending_mpesa_messages"
        private const val LAST_SMS_SCAN_AT_KEY = "last_sms_scan_at"
        private const val LAST_SMS_SCAN_ID_KEY = "last_sms_scan_id"
        private const val NOTIFICATIONS_ENABLED_KEY = "notifications_enabled"
        private const val MPESA_NOTIFICATION_CHANNEL_ID = "mpesa_transactions_v1"
        private const val TAG = "MainActivity"
        private const val INITIAL_SMS_LOOKBACK_MILLIS =
            7L * 24 * 60 * 60 * 1000
        private val mainHandler = Handler(Looper.getMainLooper())
        private val smsExecutor = Executors.newSingleThreadExecutor { runnable ->
            Thread(runnable, "mpesa-sms-recovery")
        }

        @Volatile
        private var activeChannel: MethodChannel? = null

        internal fun showSmsNotification(context: Context, timestamp: Long) {
            if (activeChannel != null) return

            val appContext = context.applicationContext
            val preferences =
                appContext.getSharedPreferences(PREFERENCES_NAME, Context.MODE_PRIVATE)
            if (!preferences.getBoolean(NOTIFICATIONS_ENABLED_KEY, true)) return
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
                ContextCompat.checkSelfPermission(
                    appContext,
                    Manifest.permission.POST_NOTIFICATIONS,
                ) != PackageManager.PERMISSION_GRANTED
            ) {
                return
            }
            val notificationManager = NotificationManagerCompat.from(appContext)
            if (!notificationManager.areNotificationsEnabled()) return

            val systemManager =
                appContext.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                systemManager.createNotificationChannel(
                    NotificationChannel(
                        MPESA_NOTIFICATION_CHANNEL_ID,
                        "M-PESA transactions",
                        NotificationManager.IMPORTANCE_DEFAULT,
                    ).apply {
                        description = "Alerts when a new M-PESA transaction is imported"
                    },
                )
                if (systemManager.getNotificationChannel(MPESA_NOTIFICATION_CHANNEL_ID)
                        ?.importance == NotificationManager.IMPORTANCE_NONE
                ) {
                    return
                }
            }

            val launchIntent =
                appContext.packageManager.getLaunchIntentForPackage(appContext.packageName)
                    ?: return
            val immutableFlag = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                PendingIntent.FLAG_IMMUTABLE
            } else {
                0
            }
            val pendingIntentFlags = PendingIntent.FLAG_UPDATE_CURRENT or immutableFlag
            val contentIntent = PendingIntent.getActivity(
                appContext,
                timestamp.hashCode(),
                launchIntent,
                pendingIntentFlags,
            )
            val notification = NotificationCompat.Builder(
                appContext,
                MPESA_NOTIFICATION_CHANNEL_ID,
            )
                .setSmallIcon(R.drawable.ic_stat_notification)
                .setContentTitle("M-PESA transaction received")
                .setContentText("Open BizFlow to view the imported transaction.")
                .setCategory("transaction")
                .setPriority(NotificationCompat.PRIORITY_DEFAULT)
                .setAutoCancel(true)
                .setContentIntent(contentIntent)
                .build()

            try {
                notificationManager.notify(timestamp.hashCode(), notification)
            } catch (error: SecurityException) {
                android.util.Log.e(TAG, "Notification permission is not available.", error)
            }
        }

        internal fun saveAndDispatch(context: Context, message: Map<String, Any>): Boolean {
            synchronized(PENDING_MESSAGES_KEY) {
                val preferences = context.getSharedPreferences(PREFERENCES_NAME, Context.MODE_PRIVATE)
                val pending = readPendingMessages(context).toMutableList()
                val id = message["id"] as String
                if (pending.none { it["id"] == id }) {
                    pending.add(message)
                    val encoded = JSONArray()
                    pending.takeLast(MAX_PENDING_MESSAGES).forEach { encoded.put(JSONObject(it)) }
                    if (!preferences.edit().putString(PENDING_MESSAGES_KEY, encoded.toString()).commit()) {
                        android.util.Log.e(TAG, "Could not persist an incoming M-Pesa message.")
                        return false
                    }
                }
            }
            mainHandler.post {
                activeChannel?.invokeMethod("onTransactionCaptured", message)
            }
            return true
        }

        private fun recoverMissedMessages(context: Context) {
            if (context.checkSelfPermission(Manifest.permission.READ_SMS) !=
                PackageManager.PERMISSION_GRANTED
            ) {
                return
            }

            val preferences = context.getSharedPreferences(PREFERENCES_NAME, Context.MODE_PRIVATE)
            val now = System.currentTimeMillis()
            val lastScanAt = preferences.getLong(
                LAST_SMS_SCAN_AT_KEY,
                now - INITIAL_SMS_LOOKBACK_MILLIS,
            )
            val lastScanId = preferences.getLong(LAST_SMS_SCAN_ID_KEY, -1L)
            val cursor = try {
                context.contentResolver.query(
                    Uri.parse("content://sms/inbox"),
                    arrayOf("_id", "address", "body", "date"),
                    "date > ? OR (date = ? AND _id > ?)",
                    arrayOf(lastScanAt.toString(), lastScanAt.toString(), lastScanId.toString()),
                    "date ASC, _id ASC",
                )
            } catch (error: Exception) {
                android.util.Log.e(TAG, "Could not scan the SMS inbox for missed messages.", error)
                return
            }
            if (cursor == null) {
                android.util.Log.e(TAG, "SMS inbox query returned no cursor.")
                return
            }

            var lastScannedAt = lastScanAt
            var lastScannedId = lastScanId
            var recoveredCount = 0
            try {
                cursor.use {
                    val idColumn = it.getColumnIndexOrThrow("_id")
                    val senderColumn = it.getColumnIndexOrThrow("address")
                    val bodyColumn = it.getColumnIndexOrThrow("body")
                    val dateColumn = it.getColumnIndexOrThrow("date")

                    while (it.moveToNext()) {
                        val smsId = it.getLong(idColumn)
                        val sender = it.getString(senderColumn).orEmpty()
                        val body = it.getString(bodyColumn).orEmpty().trim()
                        val timestamp = it.getLong(dateColumn)
                        lastScannedAt = timestamp
                        lastScannedId = smsId

                        if (body.isEmpty() || !isLikelyMpesa(sender, body)) continue
                        MpesaFinanceStore.persistIfValid(context, body, timestamp)
                        val stored = saveAndDispatch(
                            context,
                            mapOf(
                                "id" to "sms_inbox_$smsId",
                                "sender" to sender,
                                "message" to body,
                                "timestamp" to timestamp,
                            ),
                        )
                        if (!stored) return
                        recoveredCount++
                    }
                }
            } catch (error: Exception) {
                android.util.Log.e(TAG, "Could not recover missed M-Pesa messages.", error)
                return
            }

            if (lastScannedAt == lastScanAt && lastScannedId == lastScanId) {
                lastScannedAt = now
                lastScannedId = -1L
            }
            if (!preferences.edit()
                    .putLong(LAST_SMS_SCAN_AT_KEY, lastScannedAt)
                    .putLong(LAST_SMS_SCAN_ID_KEY, lastScannedId)
                    .commit()
            ) {
                android.util.Log.e(TAG, "Could not save the SMS inbox scan position.")
                return
            }
            if (recoveredCount > 0) {
                android.util.Log.i(TAG, "Recovered $recoveredCount missed M-Pesa SMS message(s).")
            }
        }

        private fun isLikelyMpesa(sender: String, body: String): Boolean {
            val senderName = sender.uppercase()
            return senderName.contains("MPESA") ||
                senderName.contains("M-PESA") ||
                senderName.contains("SAFARICOM") ||
                body.contains("M-PESA", ignoreCase = true) ||
                body.contains("M-SHWARI", ignoreCase = true) ||
                body.contains("FULIZA", ignoreCase = true)
        }

        private fun readPendingMessages(context: Context): List<Map<String, Any>> {
            val raw = context.getSharedPreferences(PREFERENCES_NAME, Context.MODE_PRIVATE)
                .getString(PENDING_MESSAGES_KEY, null) ?: return emptyList()
            return try {
                val json = JSONArray(raw)
                (0 until json.length()).mapNotNull { index ->
                    val item = json.optJSONObject(index) ?: return@mapNotNull null
                    buildMap {
                        item.keys().forEach { key ->
                            item.opt(key)?.takeUnless { it == JSONObject.NULL }?.let { put(key, it) }
                        }
                    }
                }
            } catch (error: JSONException) {
                android.util.Log.e(TAG, "Could not read pending M-Pesa messages.", error)
                emptyList()
            }
        }

        private fun acknowledgeMessages(context: Context, ids: Set<String>) {
            synchronized(PENDING_MESSAGES_KEY) {
                val preferences = context.getSharedPreferences(PREFERENCES_NAME, Context.MODE_PRIVATE)
                val remaining = readPendingMessages(context).filterNot { it["id"] in ids }
                val encoded = JSONArray()
                remaining.forEach { encoded.put(JSONObject(it)) }
                preferences.edit().putString(PENDING_MESSAGES_KEY, encoded.toString()).apply()
            }
        }

        private const val MAX_PENDING_MESSAGES = 500
    }
}
