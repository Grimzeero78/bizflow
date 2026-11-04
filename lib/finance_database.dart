import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart' hide Transaction;

import 'models.dart';

class FinanceDatabase {
  FinanceDatabase._();

  static Database? _database;
  static Future<Database>? _opening;

  static Future<Database> get database async {
    if (_database != null) return _database!;
    final opening = _opening;
    if (opening != null) return opening;
    final future = _open();
    _opening = future;
    try {
      return await future;
    } finally {
      if (identical(_opening, future)) _opening = null;
    }
  }

  static Future<Database> _open() async {
    final path = p.join(await getDatabasesPath(), 'bizflow_finance.db');
    final database = await openDatabase(
      path,
      version: 2,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE transactions (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            transaction_code TEXT NOT NULL UNIQUE,
            source_transaction_id TEXT,
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
        ''');
        await db.execute('''
          CREATE TABLE daily_summaries (
            date TEXT PRIMARY KEY,
            total_income REAL NOT NULL DEFAULT 0,
            total_expense REAL NOT NULL DEFAULT 0,
            total_savings REAL NOT NULL DEFAULT 0,
            transaction_count INTEGER NOT NULL DEFAULT 0
          )
        ''');
        await db.execute('''
          CREATE TABLE cash_scans (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            amount REAL NOT NULL,
            note TEXT NOT NULL,
            image_path TEXT NOT NULL,
            scanned_at TEXT NOT NULL
          )
        ''');
        await db.execute(
          'CREATE INDEX idx_transactions_transaction_code ON transactions(transaction_code)',
        );
        await db.execute(
          'CREATE INDEX idx_transactions_transaction_date ON transactions(transaction_date)',
        );
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await db.execute(
            'ALTER TABLE transactions ADD COLUMN source_transaction_id TEXT',
          );
        }
      },
    );
    _database = database;
    return database;
  }

  static Future<void> saveTransactions(List<Transaction> transactions) async {
    final db = await database;
    await db.transaction((txn) async {
      final existingCreatedAt = {
        for (final row in await txn.query(
          'transactions',
          columns: ['transaction_code', 'created_at'],
        ))
          row['transaction_code'] as String: row['created_at'] as String,
      };
      await txn.delete('transactions');
      await txn.delete('daily_summaries');
      final now = DateTime.now().toIso8601String();
      for (final transaction in transactions) {
        final date = transaction.date;
        final dateString =
            '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
        final timeString =
            '${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}:${date.second.toString().padLeft(2, '0')}';
        final category = switch (transaction.type) {
          'sale' => 'MONEY_IN',
          'savings' => 'SAVINGS',
          'transfer' => 'LIABILITY',
          _ => 'EXPENSE',
        };
        await txn.rawInsert(
          '''
          INSERT OR IGNORE INTO transactions (
            transaction_code, source_transaction_id, category, sub_type,
            amount, fee, balance_after, counterparty_name, counterparty_phone,
            fuliza_balance, jumbe_id, transaction_date, transaction_time,
            raw_sms, created_at
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          ''',
          [
            transaction.sourceTransactionId ?? transaction.id,
            transaction.sourceTransactionId,
            category,
            transaction.category ?? transaction.type,
            transaction.amount,
            transaction.fee,
            transaction.balance,
            transaction.counterpartyName,
            transaction.counterpartyPhone,
            transaction.fulizaBalance,
            transaction.jumbeId,
            dateString,
            timeString,
            transaction.description,
            existingCreatedAt[
                    transaction.sourceTransactionId ?? transaction.id] ??
                now,
          ],
        );
      }

      await txn.rawInsert('''
        INSERT INTO daily_summaries (
          date, total_income, total_expense, total_savings, transaction_count
        )
        SELECT
          transaction_date,
          SUM(CASE WHEN category = 'MONEY_IN' THEN amount ELSE 0 END),
          SUM(CASE WHEN category = 'EXPENSE' THEN amount ELSE 0 END),
          SUM(CASE WHEN category = 'SAVINGS' THEN amount ELSE 0 END),
          COUNT(*)
        FROM transactions
        GROUP BY transaction_date
      ''');
    });
  }

  static Future<List<Map<String, Object?>>> getTransactions() async {
    final db = await database;
    return db.query(
      'transactions',
      orderBy: 'transaction_date DESC, transaction_time DESC',
    );
  }

  static Future<void> saveCashScan({
    required double amount,
    required String note,
    required String imagePath,
    required DateTime scannedAt,
  }) async {
    final db = await database;
    await db.insert('cash_scans', {
      'amount': amount,
      'note': note,
      'image_path': imagePath,
      'scanned_at': scannedAt.toIso8601String(),
    });
  }

  static Future<List<Map<String, Object?>>> getCashScans() async {
    final db = await database;
    return db.query('cash_scans', orderBy: 'scanned_at DESC');
  }

  static Future<List<Map<String, Object?>>> getYearlySummary(int year) async {
    final db = await database;
    final rows = await db.rawQuery(
      '''
      SELECT
        CAST(substr(date, 6, 2) AS INTEGER) AS month,
        SUM(total_income) AS total_income,
        SUM(total_expense) AS total_expense,
        SUM(total_savings) AS total_savings
      FROM daily_summaries
      WHERE substr(date, 1, 4) = ?
      GROUP BY substr(date, 6, 2)
      ORDER BY month
      ''',
      [year.toString().padLeft(4, '0')],
    );
    return rows;
  }

  static Future<void> clear() async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.delete('transactions');
      await txn.delete('daily_summaries');
      await txn.delete('cash_scans');
    });
  }
}
