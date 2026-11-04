package com.example.stockipa

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.provider.Telephony
import java.util.UUID
import java.util.concurrent.Executors

class MpesaSmsReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Telephony.Sms.Intents.SMS_RECEIVED_ACTION) return

        val messages = Telephony.Sms.Intents.getMessagesFromIntent(intent)
        if (messages.isEmpty()) return

        val pendingResult = goAsync()
        receiverExecutor.execute {
            try {
                val groupedMessages = messages.groupBy { it.originatingAddress.orEmpty() }
                groupedMessages.forEach { (sender, parts) ->
                    val body = parts.joinToString(separator = "") { it.messageBody.orEmpty() }.trim()
                    if (body.isEmpty() || !isLikelyMpesa(sender, body)) return@forEach

                    val timestamp = parts.minOf { it.timestampMillis }
                    var imported = false
                    try {
                        imported = MpesaFinanceStore.persistIfValid(
                            context.applicationContext,
                            body,
                            timestamp,
                        )
                    } catch (error: Exception) {
                        android.util.Log.e(
                            "MpesaSmsReceiver",
                            "Could not save parsed M-Pesa SMS.",
                            error,
                        )
                    }
                    if (imported) {
                        MainActivity.showSmsNotification(
                            context.applicationContext,
                            timestamp,
                        )
                    }
                    val stored = MainActivity.saveAndDispatch(
                        context.applicationContext,
                        mapOf(
                            "id" to "${timestamp}_${UUID.randomUUID()}",
                            "sender" to sender,
                            "message" to body,
                            "timestamp" to timestamp,
                        ),
                    )
                    if (!stored) {
                        android.util.Log.e(
                            "MpesaSmsReceiver",
                            "Could not queue an incoming M-Pesa SMS for app import.",
                        )
                    }
                }
            } catch (error: Exception) {
                android.util.Log.e("MpesaSmsReceiver", "Could not process received SMS.", error)
            } finally {
                pendingResult.finish()
            }
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

    companion object {
        private val receiverExecutor = Executors.newSingleThreadExecutor { runnable ->
            Thread(runnable, "mpesa-sms-receiver")
        }
    }
}
