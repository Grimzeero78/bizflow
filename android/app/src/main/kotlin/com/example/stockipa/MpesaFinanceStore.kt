package com.example.stockipa

import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale

internal object MpesaFinanceStore {
    private const val DATABASE_NAME = "bizflow_finance.db"
    private const val DATABASE_VERSION = 1

    private class Helper(context: Context) :
        SQLiteOpenHelper(context, DATABASE_NAME, null, DATABASE_VERSION) {

        override fun onCreate(db: SQLiteDatabase) {
            createTables(db)
        }

        override fun onUpgrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) {
            if (oldVersion < 1) createTables(db)
        }
    }

    private data class Parsed(
        val code: String,
        val category: String,
        val subtype: String,
        val amount: Double,
        val fee: Double?,
        val balance: Double?,
        val name: String?,
        val phone: String?,
        val fuliza: Double?,
        val jumbeId: String?,
        val date: String,
        val time: String,
    )

    fun persistIfValid(context: Context, message: String, receivedAt: Long): Boolean {
        val parsed = parse(message, receivedAt) ?: return false
        val helper = Helper(context.applicationContext)
        var inserted = false
        try {
            helper.writableDatabase.use { db ->
                db.beginTransaction()
                try {
                    db.execSQL(
                        """
                    INSERT OR IGNORE INTO transactions (
                      transaction_code, category, sub_type, amount, fee, balance_after,
                      counterparty_name, counterparty_phone, fuliza_balance, jumbe_id,
                      transaction_date, transaction_time, raw_sms, created_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """.trimIndent(),
                        arrayOf(
                            parsed.code,
                            parsed.category,
                            parsed.subtype,
                            parsed.amount,
                            parsed.fee,
                            parsed.balance,
                            parsed.name,
                            parsed.phone,
                            parsed.fuliza,
                            parsed.jumbeId,
                            parsed.date,
                            parsed.time,
                            message,
                            SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS", Locale.US)
                                .format(Date()),
                        ),
                    )
                    inserted =
                        db.compileStatement("SELECT changes()").simpleQueryForLong() > 0
                    if (inserted) {
                        db.execSQL(
                            """
                        INSERT OR REPLACE INTO daily_summaries (
                          date, total_income, total_expense, total_savings, transaction_count
                        )
                        SELECT transaction_date,
                          SUM(CASE WHEN category = 'MONEY_IN' THEN amount ELSE 0 END),
                          SUM(CASE WHEN category = 'EXPENSE' THEN amount ELSE 0 END),
                          SUM(CASE WHEN category = 'SAVINGS' THEN amount ELSE 0 END),
                          COUNT(*)
                        FROM transactions
                        WHERE transaction_date = ?
                        GROUP BY transaction_date
                        """.trimIndent(),
                            arrayOf(parsed.date),
                        )
                    }
                    db.setTransactionSuccessful()
                } finally {
                    db.endTransaction()
                }
            }
        } finally {
            helper.close()
        }
        return inserted
    }

    private fun parse(message: String, receivedAt: Long): Parsed? {
        val normalized = message.trim()
        if (normalized.isEmpty()) return null
        val lower = normalized.lowercase(Locale.ROOT)
        if (listOf(
                "cancelled the reversal",
                "canceled the reversal",
                "cancelled reversal",
                "canceled reversal",
                "failed",
                "declined",
                "unsuccessful",
                "mini statement",
                "mini-statement",
                "balance inquiry",
                "check balance",
            ).any(lower::contains)
        ) return null
        if ("jumbeid" in lower && "new m-pesa balance" !in lower) return null

        val anchor = Regex(
            """^\s*([A-Z0-9]{9,10})\s+(?:Confirmed|Imethibitishwa)\.""",
            RegexOption.IGNORE_CASE,
        ).find(normalized)
        val hasStandaloneAccountNotice = ("fuliza" in lower &&
            ("limit" in lower || "outstanding" in lower)) ||
            ("m-shwari" in lower &&
                ("overdue" in lower || "interest earned" in lower || "loan" in lower))
        if (anchor == null && !lower.startsWith("imethibitishwa.") && !hasStandaloneAccountNotice) {
            return null
        }

        val subtype = when {
            "jumbeid" in lower -> "jumbe_notification"
            ("reversal" in lower || "reversed" in lower) &&
                ("successfully reversed" in lower || "has been reversed" in lower) ->
                if ("deducted from your account" in lower ||
                    "received transaction has been reversed" in lower
                ) "reversal_out" else "reversal_in"
            "interest earned" in lower -> "interest_earned"
            "loan" in lower && ("overdue" in lower || "loan is overdue" in lower) -> "loan_overdue"
            "loan" in lower && ("credited" in lower || "disbursed" in lower) -> "loan_disbursement"
            "fuliza m-pesa amount" in lower -> "fuliza_usage"
            "fuliza" in lower && ("limit" in lower || "outstanding" in lower) -> "fuliza_liability"
            "m-shwari" in lower && "transferred" in lower && "to your m-shwari account" in lower ->
                "m_shwari_deposit"
            "m-shwari" in lower && "transferred" in lower && "from your m-shwari account" in lower ->
                "m_shwari_withdrawal"
            "loan repayment" in lower || "repayment to m-shwari" in lower -> "loan_repayment"
            "umepokea" in lower || "you have received" in lower || "received from" in lower ->
                "money_in"
            "deposited to your account" in lower -> "agent_deposit"
            "paybill" in lower -> "paybill"
            "withdrawn at" in lower || "umetoa" in lower -> "withdrawal"
            "airtime" in lower && "bought" in lower -> "airtime"
            "paid to" in lower || "umelipa" in lower -> "buy_goods"
            "sent to" in lower || "umetuma" in lower -> "send_money"
            else -> return null
        }
        val moneyMatch = Regex(
            """(?:Fuliza\s+M-PESA\s+amount\s+is\s+(?:(?:Ksh|KES)\s*)?|(?:Ksh|KES)\s*)([\d,]+(?:\.\d{1,2})?)""",
            RegexOption.IGNORE_CASE,
        ).find(normalized) ?: return null
        val amount = moneyMatch.groupValues[1].replace(",", "").toDoubleOrNull()
            ?: return null
        if (amount <= 0) return null

        fun extract(pattern: String): Double? =
            Regex(pattern, RegexOption.IGNORE_CASE).find(normalized)
                ?.groupValues?.getOrNull(1)?.replace(",", "")?.toDoubleOrNull()

        val dateMatch = Regex(
            """\b(\d{1,2})/(\d{1,2})/(\d{2,4})\s+(?:(?:at|saa)\s+)?(\d{1,2}):(\d{2})\s*(AM|PM)?\b""",
            RegexOption.IGNORE_CASE,
        ).find(normalized)
        val calendar = Calendar.getInstance().apply { timeInMillis = receivedAt }
        if (dateMatch != null) {
            val fields = dateMatch.groupValues
            var year = fields[3].toInt()
            if (year < 100) year += 2000
            var hour = fields[4].toInt()
            val minute = fields[5].toInt()
            if (fields[6].equals("PM", true) && hour < 12) hour += 12
            if (fields[6].equals("AM", true) && hour == 12) hour = 0
            if (fields[1].toInt() !in 1..31 || fields[2].toInt() !in 1..12 ||
                hour !in 0..23 || minute !in 0..59
            ) return null
            calendar.set(year, fields[2].toInt() - 1, fields[1].toInt(), hour, minute, 0)
            calendar.set(Calendar.MILLISECOND, 0)
        }
        val transactionDate = SimpleDateFormat("yyyy-MM-dd", Locale.US).format(calendar.time)
        val transactionTime = SimpleDateFormat("HH:mm:ss", Locale.US).format(calendar.time)

        val phone = Regex("""\b\d{4}[\d*]{3,6}\d{0,4}\b""").find(normalized)?.value
        val namePattern = when (subtype) {
            "money_in" -> Regex("""(?:\bfrom\b|\bkutoka\b)\s+(.+?)(?=\s+on\s+\d{1,2}/|\s+tarehe\b|$)""", RegexOption.IGNORE_CASE)
            "send_money" -> Regex("""(?:sent\s+to|umetuma\s+pesa\s+kwa)\s+(.+?)(?=\s+on\s+\d{1,2}/|\s+kiasi\b|$)""", RegexOption.IGNORE_CASE)
            "paybill" -> Regex("""sent\s+to\s+(.+?)\s+Paybill\b""", RegexOption.IGNORE_CASE)
            "buy_goods" -> Regex("""(?:paid\s+to|umelipa)\s+(.+?)(?=\s+on\s+\d{1,2}/|$)""", RegexOption.IGNORE_CASE)
            "withdrawal" -> Regex("""(?:withdrawn\s+at|umetoa)\s+(.+?)(?=\s+on\s+\d{1,2}/|$)""", RegexOption.IGNORE_CASE)
            else -> null
        }
        val name = namePattern?.find(normalized)?.groupValues?.getOrNull(1)
            ?.replace(Regex("""\b\d{4}[\d*]{3,6}\d{0,4}\b"""), "")
            ?.trim()
            ?.takeIf { it.isNotEmpty() }
        val category = when (subtype) {
            "money_in", "agent_deposit", "reversal_in" -> "MONEY_IN"
            "m_shwari_deposit", "m_shwari_withdrawal", "interest_earned" -> "SAVINGS"
            "loan_overdue", "loan_disbursement", "fuliza_liability", "jumbe_notification" ->
                "LIABILITY"
            else -> "EXPENSE"
        }

        return Parsed(
            code = anchor?.groupValues?.getOrNull(1)?.uppercase(Locale.ROOT)
                ?: "SMS-$receivedAt",
            category = category,
            subtype = subtype,
            amount = amount,
            fee = extract("""(?:Transaction\s+cost|Ada)[,\s]*(?:Ksh|KES)\s*([\d,]+(?:\.\d{1,2})?)"""),
            balance = extract("""(?:New\s+M-PESA\s+balance\s+is|Baki\s+yako\s+ya\s+M-PESA\s+ni)\s*(?:Ksh|KES)\s*([\d,]+(?:\.\d{1,2})?)"""),
            name = name,
            phone = phone,
            fuliza = extract("""outstanding\s+Fuliza\s+balance\s+is\s*(?:Ksh|KES)\s*([\d,]+(?:\.\d{1,2})?)"""),
            jumbeId = Regex("""\bJumbeID\s*[:#]?\s*([A-Z0-9_-]+)""", RegexOption.IGNORE_CASE)
                .find(normalized)?.groupValues?.getOrNull(1),
            date = transactionDate,
            time = transactionTime,
        )
    }

    private fun createTables(db: SQLiteDatabase) {
        db.execSQL(
            """
            CREATE TABLE IF NOT EXISTS transactions (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              transaction_code TEXT NOT NULL UNIQUE,
              category TEXT NOT NULL,
              sub_type TEXT NOT NULL,
              amount REAL NOT NULL,
              fee REAL,
              balance_after REAL,
              counterparty_name TEXT,
              counterparty_phone TEXT,
              fuliza_balance REAL,
              jumbe_id TEXT,
              transaction_date TEXT NOT NULL,
              transaction_time TEXT NOT NULL,
              raw_sms TEXT NOT NULL,
              created_at TEXT NOT NULL
            )
            """.trimIndent(),
        )
        db.execSQL(
            """
            CREATE TABLE IF NOT EXISTS daily_summaries (
              date TEXT PRIMARY KEY,
              total_income REAL NOT NULL DEFAULT 0,
              total_expense REAL NOT NULL DEFAULT 0,
              total_savings REAL NOT NULL DEFAULT 0,
              transaction_count INTEGER NOT NULL DEFAULT 0
            )
            """.trimIndent(),
        )
        db.execSQL(
            """
            CREATE TABLE IF NOT EXISTS cash_scans (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              amount REAL NOT NULL,
              note TEXT NOT NULL,
              image_path TEXT NOT NULL,
              scanned_at TEXT NOT NULL
            )
            """.trimIndent(),
        )
        db.execSQL(
            "CREATE INDEX IF NOT EXISTS idx_transactions_transaction_code ON transactions(transaction_code)",
        )
        db.execSQL(
            "CREATE INDEX IF NOT EXISTS idx_transactions_transaction_date ON transactions(transaction_date)",
        )
    }
}
