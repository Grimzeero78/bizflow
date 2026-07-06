import 'dart:convert';

import 'package:hive/hive.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';

class AppDatabase {
  AppDatabase._();

  static const String _boxName = 'bizflow';
  static const String _migrationDoneKey = 'stockipa_hive_migrated_v1';
  static const String _transactionsKey = 'transactions';
  static const String _stockItemsKey = 'stockItems';
  static const String _settingsKey = 'settings';

  static AppDatabase? _instance;
  static Box<dynamic>? _box;
  static bool _initialized = false;

  static Future<AppDatabase> open() async {
    if (_instance != null) {
      return _instance!;
    }

    if (!_initialized) {
      final dir = await getApplicationDocumentsDirectory();
      Hive.init(dir.path);
      _registerAdapters();
      _initialized = true;
    }

    if (_box == null || !_box!.isOpen) {
      _box = await Hive.openBox<dynamic>(_boxName);
    }

    _instance = AppDatabase._();
    await _instance!._runLegacyMigrationIfNeeded();
    return _instance!;
  }

  static Future<AppDatabase> get instance async => open();

  static void _registerAdapters() {
    if (!Hive.isAdapterRegistered(TransactionAdapter.typeIdValue)) {
      Hive.registerAdapter(TransactionAdapter());
    }
    if (!Hive.isAdapterRegistered(StockItemAdapter.typeIdValue)) {
      Hive.registerAdapter(StockItemAdapter());
    }
    if (!Hive.isAdapterRegistered(AppSettingsAdapter.typeIdValue)) {
      Hive.registerAdapter(AppSettingsAdapter());
    }
  }

  static Box<dynamic> get _currentBox {
    final box = _box;
    if (box == null) {
      throw StateError('Hive box has not been opened yet.');
    }
    return box;
  }

  Future<List<Transaction>> loadTransactions() async {
    await open();
    final raw = _currentBox.get(_transactionsKey);
    if (raw is List) {
      return raw.whereType<Transaction>().toList();
    }
    return <Transaction>[];
  }

  Future<List<StockItem>> loadStockItems() async {
    await open();
    final raw = _currentBox.get(_stockItemsKey);
    if (raw is List) {
      return raw.whereType<StockItem>().toList();
    }
    return <StockItem>[];
  }

  Future<AppSettings> loadSettings() async {
    await open();
    final raw = _currentBox.get(_settingsKey);
    if (raw is AppSettings) {
      return raw;
    }
    return AppSettings();
  }

  Future<void> saveAll({
    required List<Transaction> transactions,
    required List<StockItem> stockItems,
    required AppSettings settings,
  }) async {
    await open();
    await _currentBox.put(_transactionsKey, List<Transaction>.from(transactions));
    await _currentBox.put(_stockItemsKey, List<StockItem>.from(stockItems));
    await _currentBox.put(_settingsKey, settings);
  }

  Future<void> clearAllData() async {
    await open();
    await _currentBox.delete(_transactionsKey);
    await _currentBox.delete(_stockItemsKey);
    await _currentBox.delete(_settingsKey);

    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('stockipa_transactions');
    await prefs.remove('stockipa_stock');
    await prefs.remove('stockipa_settings');
    await prefs.remove('transactions');
    await prefs.remove('stock');
    await prefs.remove('settings');
  }

  Future<void> _runLegacyMigrationIfNeeded() async {
    final prefs = await SharedPreferences.getInstance();
    final alreadyMigrated = prefs.getBool(_migrationDoneKey) ?? false;
    if (alreadyMigrated) return;

    final hasCurrentData = _currentBox.containsKey(_transactionsKey) ||
        _currentBox.containsKey(_stockItemsKey) ||
        _currentBox.containsKey(_settingsKey);

    if (hasCurrentData) {
      await prefs.setBool(_migrationDoneKey, true);
      return;
    }

    final legacyTransactionsJson =
        prefs.getString('stockipa_transactions') ?? prefs.getString('transactions');
    final legacyStockJson =
        prefs.getString('stockipa_stock') ?? prefs.getString('stock');
    final legacySettingsJson =
        prefs.getString('stockipa_settings') ?? prefs.getString('settings');

    final transactions = <Transaction>[];
    final stockItems = <StockItem>[];
    AppSettings? settings;

    if (legacyTransactionsJson != null && legacyTransactionsJson.isNotEmpty) {
      try {
        final decoded = jsonDecode(legacyTransactionsJson);
        if (decoded is List) {
          for (final item in decoded) {
            if (item is Map) {
              transactions.add(_transactionFromLegacyJson(
                Map<String, dynamic>.from(item),
              ));
            }
          }
        }
      } catch (_) {
        // Ignore malformed legacy data; don't block startup.
      }
    }

    if (legacyStockJson != null && legacyStockJson.isNotEmpty) {
      try {
        final decoded = jsonDecode(legacyStockJson);
        if (decoded is List) {
          for (final item in decoded) {
            if (item is Map) {
              stockItems.add(_stockFromLegacyJson(
                Map<String, dynamic>.from(item),
              ));
            }
          }
        }
      } catch (_) {
        // Ignore malformed legacy data; don't block startup.
      }
    }

    if (legacySettingsJson != null && legacySettingsJson.isNotEmpty) {
      try {
        final decoded = jsonDecode(legacySettingsJson);
        if (decoded is Map) {
          settings = _settingsFromLegacyJson(
            Map<String, dynamic>.from(decoded),
          );
        }
      } catch (_) {
        // Ignore malformed legacy data; don't block startup.
      }
    }

    if (transactions.isNotEmpty) {
      await _currentBox.put(_transactionsKey, transactions);
    }
    if (stockItems.isNotEmpty) {
      await _currentBox.put(_stockItemsKey, stockItems);
    }
    if (settings != null) {
      await _currentBox.put(_settingsKey, settings);
    }

    await prefs.setBool(_migrationDoneKey, true);
  }

  static Transaction _transactionFromLegacyJson(Map<String, dynamic> json) {
    return Transaction(
      id: json['id'] as String? ?? DateTime.now().millisecondsSinceEpoch.toString(),
      type: json['type'] as String? ?? 'sale',
      amount: (json['amount'] as num?)?.toDouble() ?? 0.0,
      description: json['description'] as String? ?? '',
      quantity: (json['quantity'] as num?)?.toInt() ?? 1,
      stockItemId: json['stockItemId'] as String?,
      date: json['date'] != null
          ? DateTime.tryParse(json['date'].toString()) ?? DateTime.now()
          : DateTime.now(),
      balance: (json['balance'] as num?)?.toDouble(),
      category: json['category'] as String?,
      sourceTransactionId: json['sourceTransactionId'] as String?,
    );
  }

  static StockItem _stockFromLegacyJson(Map<String, dynamic> json) {
    return StockItem(
      id: json['id'] as String? ?? DateTime.now().millisecondsSinceEpoch.toString(),
      name: json['name'] as String? ?? '',
      quantity: (json['quantity'] as num?)?.toInt() ?? 0,
      initialQuantity: ((json['initialQuantity'] ?? json['quantity'] ?? 0) as num).toInt(),
      buyingPrice: (json['buyingPrice'] as num?)?.toDouble() ?? 0.0,
      sellingPrice: (json['sellingPrice'] as num?)?.toDouble() ?? 0.0,
      mode: json['mode'] as String? ?? 'countable',
      lowStockLimit: (json['lowStockLimit'] as num?)?.toInt(),
      expectedTotalSales: (json['expectedTotalSales'] as num?)?.toDouble(),
      totalBuyingCost: (json['totalBuyingCost'] as num?)?.toDouble(),
      dateAdded: json['dateAdded'] != null
          ? DateTime.tryParse(json['dateAdded'].toString()) ?? DateTime.now()
          : DateTime.now(),
    );
  }

  static AppSettings _settingsFromLegacyJson(Map<String, dynamic> json) {
    return AppSettings(
      language: json['language'] as String? ?? 'en',
      currency: json['currency'] as String? ?? 'CNY',
      darkMode: json['darkMode'] as bool? ?? false,
    );
  }
}
